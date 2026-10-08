import XCTest
import Combine
@testable import AFITCApp
import AFITCCore

/// Actual AppServices over generated JPEGs and persisted fictional vectors. No private media,
/// model qualification or UI acceptance is implied by these service tests.
final class FaceGroupServiceTests: XCTestCase {
    private final class ThermalStateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = ProcessInfo.ThermalState.nominal
        var value: ProcessInfo.ThermalState {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "App operation did not finish")
    }
    @MainActor private func fixture(analysisResources: FaceJobResources? = nil,
                                    observing: ((AppServices) -> Void)? = nil) async throws -> (AppServices, URL, URL) {
        SyntheticAnalysisProbe.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = try AppSessionFixture.root(in: root)
        let services = AppServices(launch: LaunchOptions(arguments: ["--uitest-synthetic-source", "--uitest-synthetic-detector", "--uitest-synthetic-faces"], ownedRoot: root),
                                   analysisResources: analysisResources ?? FaceJobResources())
        addTeardownBlock { try await self.retire(services, root: root) }
        try await wait { services.canStart && services.hasLoadedPeopleSnapshot && !services.isRestoringSource }
        observing?(services)
        services.choose(source); services.startScan(confirmedSource: true)
        try await wait { services.canStart && services.progress.phase == .completed && !services.isRefreshingPeople }
        await services.faceGroups.refresh()
        return (services, root, source)
    }
    @MainActor private func closeForRelaunch(_ services: AppServices) async throws {
        let drained = await services.quiesceCatalogSession(); XCTAssertTrue(drained)
        let owner = try await CatalogSuspensionRepository.beginSuspension(catalog: XCTUnwrap(services.privacyContext()?.0))
        try await owner.suspend(); services.releaseProtectedGraph()
        _ = try await owner.reopen()
    }
    @MainActor private func retire(_ services: AppServices, root: URL) async throws {
        let drained = await services.quiesceCatalogSession(); XCTAssertTrue(drained)
        if let repository = services.privacyContext()?.0 {
            let suspension = try await CatalogSuspensionRepository.beginSuspension(catalog: repository)
            try await suspension.suspend()
            _ = try await suspension.reopen()
        }
        services.releaseProtectedGraph()
        try? FileManager.default.removeItem(at: root)
    }
    @MainActor private func pinned(_ services: AppServices) throws -> (FaceGroup, FaceGroupSnapshot) {
        let group = try XCTUnwrap(services.faceGroups.result?.groups.first { $0.members.count > 1 })
        let states = Dictionary(uniqueKeysWithValues: services.peopleSnapshot.faces.map { ($0.key, $0.state) })
        return (group, try XCTUnwrap(group.snapshot(states: states)))
    }
    @MainActor func testFirstOrdinaryScanCreatesUnnamedSavedGroups() async throws {
        let (services, root, _) = try await fixture()
        XCTAssertEqual(SyntheticAnalysisProbe.scanCount, 1)
        XCTAssertEqual(SyntheticAnalysisProbe.sourceReadCount, 3)
        XCTAssertEqual(SyntheticAnalysisProbe.computationCount, 3)
        XCTAssertTrue(services.peopleSnapshot.people.isEmpty)
        XCTAssertEqual(services.peopleSnapshot.faces.count, 6)
        let result = try XCTUnwrap(services.faceGroups.result)
        XCTAssertTrue(result.groups.contains { $0.members.count > 1 })
        XCTAssertTrue(result.memberships.values.allSatisfy { $0.personID == nil })
        let analysis = try await XCTUnwrap(services.privacyContext()?.0).faceAnalysisSnapshot()
        XCTAssertEqual(analysis.vectors.count, 6)
        XCTAssertEqual(analysis.photoRecords.filter { $0.status == .completed }.count, 3)
        try await retire(services, root: root)
    }
    @MainActor func testNameKeepsSeedPhotosAndLabelsWholeGroupWithoutWork() async throws {
        let (services, root, _) = try await fixture()
        let (before, snapshot) = try pinned(services)
        let saved = await services.decide(.nameGroup(cover: snapshot.seed, group: snapshot, displayName: "Fictional Ada"))
        XCTAssertTrue(saved)
        let after = try XCTUnwrap(services.faceGroups.result?.groups.first { $0.id == before.id })
        XCTAssertEqual(after.members, before.members)
        let person = try XCTUnwrap(services.peopleSnapshot.people.first)
        XCTAssertEqual(person.person.displayName, "Fictional Ada")
        XCTAssertTrue(before.members.allSatisfy { key in services.peopleSnapshot.faces.first { $0.key == key }?.state.personID == person.id })
        let labeled = services.peopleSnapshot.faces.filter { $0.state.personID == person.id }
        XCTAssertEqual(labeled.count, before.members.count)
        XCTAssertEqual(labeled.filter(\.state.isAnchor).map(\.key), [snapshot.seed], "Only the chosen cover becomes an example")
        XCTAssertEqual(before.members.count, after.members.count)
        await services.faceGroups.refresh()
        _ = services.suggestions.queue
        XCTAssertEqual(SyntheticAnalysisProbe.scanCount, 1)
        XCTAssertEqual(SyntheticAnalysisProbe.sourceReadCount, 3)
        XCTAssertEqual(SyntheticAnalysisProbe.computationCount, 3)
        try await retire(services, root: root)
    }

    @MainActor func testFocusedQueueFiltersPersonAndShowAllPreservesSkippedCards() async throws {
        let (services, root, _) = try await fixture()
        let examples = services.peopleSnapshot.faces.filter { $0.photo.relativePath.hasSuffix("synthetic-0.jpg") }
        let left = try XCTUnwrap(examples.first { ($0.geometry.rectangle.first ?? 1) < 0.5 })
        let right = try XCTUnwrap(examples.first { ($0.geometry.rectangle.first ?? 0) >= 0.5 })
        let namedLeft = await services.decide(.name(face: left.key, displayName: "Fixture Ada"))
        XCTAssertTrue(namedLeft)
        let namedRight = await services.decide(.name(face: right.key, displayName: "Fixture Bob"))
        XCTAssertTrue(namedRight)
        let result = try XCTUnwrap(services.faceGroups.result)
        XCTAssertGreaterThanOrEqual(result.suggestions.count, 3)
        let peopleWithMatches = Set(result.suggestions.map(\.personID))
        XCTAssertGreaterThanOrEqual(peopleWithMatches.count, 2)
        let review = services.suggestions
        let first = try XCTUnwrap(review.queue.current)
        await review.review(.skip, card: first)
        XCTAssertEqual(review.queue.skippedCount, 1)

        let focusedID = try XCTUnwrap(result.suggestions.first { $0.personID != first.personID }?.personID)
        review.focus(on: [focusedID])
        XCTAssertEqual(review.focusedPersonIDs, [focusedID])
        XCTAssertEqual(review.queue.current?.personID, focusedID, "The focused queue must not show another person's card")
        XCTAssertFalse(review.staleNotice, "A requested person change is explicit")
        review.showAllMatches()
        XCTAssertNil(review.focusedPersonIDs)
        XCTAssertEqual(review.queue.skippedCount, 1, "Show all preserves the session's earlier skip")

        let rendered = try XCTUnwrap(review.queue.current)
        let deferred = await services.decide(.unsure(face: rendered.face, personID: rendered.personID))
        XCTAssertTrue(deferred)
        XCTAssertTrue(review.staleNotice, "An external answer must lock a replaced current card")
        review.showLatest()
        XCTAssertFalse(review.staleNotice)
        XCTAssertEqual(SyntheticAnalysisProbe.scanCount, 1)
        XCTAssertEqual(SyntheticAnalysisProbe.sourceReadCount, 3)
        XCTAssertEqual(SyntheticAnalysisProbe.computationCount, 3)
        try await retire(services, root: root)
    }
    @MainActor func testUnchangedScanReusesSavedAnalysis() async throws {
        let (services, root, _) = try await fixture()
        let before = try XCTUnwrap(services.faceGroups.result).groups
        services.startScan(confirmedSource: true)
        try await wait { services.canStart && !services.isScanning }
        await services.faceGroups.refresh()
        XCTAssertEqual(services.faceGroups.result?.groups, before)
        XCTAssertEqual(SyntheticAnalysisProbe.scanCount, 2)
        XCTAssertEqual(SyntheticAnalysisProbe.sourceReadCount, 3)
        XCTAssertEqual(SyntheticAnalysisProbe.computationCount, 3)
        try await retire(services, root: root)
    }
    @MainActor func testCorrectionUndoUsesSameSavedMembership() async throws {
        let (services, root, _) = try await fixture()
        let (before, snapshot) = try pinned(services)
        let member = try XCTUnwrap(before.members.first { $0 != before.seed })
        let saved = await services.decide(.excludeGroupMember(face: member, group: snapshot))
        XCTAssertTrue(saved)
        XCTAssertFalse(services.faceGroups.result?.groups.contains { $0.members.contains(member) && $0.members.contains(before.seed) } == true)
        await services.undoDecision()
        XCTAssertEqual(services.faceGroups.result?.groups.first { $0.id == before.id }?.members, before.members)
        XCTAssertEqual(SyntheticAnalysisProbe.sourceReadCount, 3)
        XCTAssertEqual(SyntheticAnalysisProbe.computationCount, 3)
        try await retire(services, root: root)
    }
    @MainActor func testVerifyConsumesSharedResultsAndSettlesAnswer() async throws {
        let (services, root, _) = try await fixture()
        let (_, snapshot) = try pinned(services)
        let saved = await services.decide(.name(face: snapshot.seed, displayName: "Fictional Ada"))
        XCTAssertTrue(saved)
        let suggestions = services.suggestions
        let card = try XCTUnwrap(suggestions.queue.current)
        XCTAssertNotEqual(card.face, snapshot.seed, "Verify reviews an unresolved face, never the assigned anchor")
        XCTAssertNil(card.expectedState.personID, "The card must remain an unassigned possible match")
        XCTAssertTrue(services.faceGroups.result?.suggestions.contains(card) == true)
        await suggestions.review(.yes, card: card)
        XCTAssertTrue(suggestions.canReview)
        XCTAssertEqual(services.peopleSnapshot.faces.first { $0.key == card.face }?.state.personID, card.personID)
        await services.undoDecision()
        XCTAssertEqual(services.peopleSnapshot.faces.first { $0.key == card.face }?.state.personID, nil)
        XCTAssertEqual(SyntheticAnalysisProbe.scanCount, 1)
        XCTAssertEqual(SyntheticAnalysisProbe.computationCount, 3)
        try await retire(services, root: root)
    }
    @MainActor func testReopenRetainsNamedGroupWithoutSourceOrInference() async throws {
        let (services, root, _) = try await fixture()
        let (before, snapshot) = try pinned(services)
        let saved = await services.decide(.nameGroup(cover: snapshot.seed, group: snapshot, displayName: "Fictional Ada"))
        XCTAssertTrue(saved)
        try await closeForRelaunch(services)
        let reopened = AppServices(launch: LaunchOptions(arguments: ["--uitest-synthetic-source"], ownedRoot: root))
        try await wait { reopened.canStart && reopened.hasLoadedPeopleSnapshot && !reopened.isRestoringSource }
        await reopened.faceGroups.refresh()
        XCTAssertEqual(reopened.faceGroups.result?.groups.first { $0.id == before.id }?.members, before.members)
        XCTAssertEqual(reopened.peopleSnapshot.people.first?.person.displayName, "Fictional Ada")
        XCTAssertEqual(SyntheticAnalysisProbe.scanCount, 1)
        XCTAssertEqual(SyntheticAnalysisProbe.sourceReadCount, 3)
        XCTAssertEqual(SyntheticAnalysisProbe.computationCount, 3)
        try await retire(reopened, root: root)
    }
    @MainActor func testGroupsPublishDuringScanAtAwaitedBoundaries() async throws {
        var incrementalCounts: [Int] = []
        var subscription: AnyCancellable?
        let (services, root, _) = try await fixture { services in
            subscription = services.faceGroups.$result.sink { [weak services] value in
                if services?.isScanning == true, let value, !value.memberships.isEmpty {
                    incrementalCounts.append(value.memberships.count)
                }
            }
        }
        XCTAssertTrue(incrementalCounts.contains { $0 > 0 && $0 < 6 }, "Saved analysis must publish before the full pass finishes")
        subscription?.cancel()
        try await retire(services, root: root)
    }
    @MainActor func testRetryStatesNeedExplicitAdmissionAndOnlyReadAffectedPhoto() async throws {
        let (services, root, _) = try await fixture()
        let repository = try XCTUnwrap(services.privacyContext()?.0)
        let photo = try XCTUnwrap(services.photos.first)
        let records = try await repository.faceAnalysisSnapshot().photoRecords
        let binding = try XCTUnwrap(records.first { $0.photoID == photo.id }).sourceBinding
        for (index, status) in [PhotoAnalysisStatus.failed, .paused, .capacityFull].enumerated() {
            let fence = try await repository.captureFaceAnalysisPersistenceFence(photo: photo, sourceIdentity: binding)
            _ = try await repository.saveFaceAnalysisBatch(fence: fence, verifiedContentHash: XCTUnwrap(photo.contentHash), vectors: [], manifest: .openCVSFace2021December, status: status)
            await services.faceGroups.refresh()
            XCTAssertEqual(services.faceGroups.retryablePhotos.map(\.id), [photo.id])
            let membershipBeforeRetry = try XCTUnwrap(services.faceGroups.result)
            services.startScan(confirmedSource: true)
            try await wait { services.canStart && !services.isScanning }
            XCTAssertEqual(SyntheticAnalysisProbe.sourceReadCount, 3 + index, "Ordinary scans retain the explicit retry hold for \(status)")
            XCTAssertEqual(SyntheticAnalysisProbe.computationCount, 3 + index)
            await services.retrySavedFaceAnalysis([photo])
            try await wait { services.canStart && !services.isScanning }
            try await wait { services.faceGroups.retryablePhotos.isEmpty }
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(services.faceGroups.result).revision, membershipBeforeRetry.revision)
            XCTAssertEqual(SyntheticAnalysisProbe.scanCount, 3 + index * 2)
            XCTAssertEqual(SyntheticAnalysisProbe.sourceReadCount, 4 + index)
            XCTAssertEqual(SyntheticAnalysisProbe.computationCount, 4 + index)
        }
        try await retire(services, root: root)
    }
    @MainActor func testRetryListClearsWhenThermalGatePausesGrouping() async throws {
        let thermal = ThermalStateBox()
        let resources = FaceJobResources { thermal.value }
        let (services, root, _) = try await fixture(analysisResources: resources)
        let repository = try XCTUnwrap(services.privacyContext()?.0)
        let photo = try XCTUnwrap(services.photos.first)
        let records = try await repository.faceAnalysisSnapshot().photoRecords
        let binding = try XCTUnwrap(records.first { $0.photoID == photo.id }).sourceBinding
        let fence = try await repository.captureFaceAnalysisPersistenceFence(photo: photo, sourceIdentity: binding)
        _ = try await repository.saveFaceAnalysisBatch(fence: fence, verifiedContentHash: XCTUnwrap(photo.contentHash),
            vectors: [], manifest: .openCVSFace2021December, status: .failed, reason: "safe synthetic failure")
        await services.faceGroups.refresh()
        XCTAssertEqual(services.faceGroups.retryablePhotos.map(\.id), [photo.id])

        thermal.value = .serious
        await services.retrySavedFaceAnalysis([photo])
        try await wait { services.canStart && !services.isScanning && !services.faceGroups.isComputing }

        let remainingRecords = try await repository.faceAnalysisSnapshot().photoRecords.filter { $0.photoID == photo.id }
        XCTAssertTrue(remainingRecords.isEmpty, "Retry admission clears the old marker while thermal gating prevents another attempt")
        XCTAssertTrue(services.faceGroups.retryablePhotos.isEmpty, "People must not retain a stale retry action when no retry record remains")
        XCTAssertEqual(services.faceGroups.retrySummary.untrackedIncompleteCount, 1)
        XCTAssertEqual(services.faceGroups.retrySummary.statusLine, "1 photo needs analysis: device is warm")
        XCTAssertEqual(SyntheticAnalysisProbe.computationCount, 3, "Thermal gating must not run another synthetic analysis")
        try await retire(services, root: root)
    }
    @MainActor func testRetiredSessionClearsSharedReviewWithoutLatePublication() async throws {
        let (services, root, _) = try await fixture()
        let (_, snapshot) = try pinned(services)
        let saved = await services.decide(.nameGroup(cover: snapshot.seed, group: snapshot, displayName: "Fictional Ada"))
        XCTAssertTrue(saved)
        _ = services.suggestions
        let drained = await services.quiesceCatalogSession(); XCTAssertTrue(drained)
        await services.faceGroups.refresh()
        XCTAssertNil(services.faceGroups.result)
        XCTAssertNil(services.suggestions.queue.current)
        XCTAssertEqual(SyntheticAnalysisProbe.scanCount, 1)
        try await retire(services, root: root)
    }
    @MainActor func testPersonDeletionPinsDisplayedPossibleMembersAndSuppressesThem() async throws {
        let (services, root, _) = try await fixture()
        let (before, snapshot) = try pinned(services)
        let saved = await services.decide(.nameGroup(cover: snapshot.seed, group: snapshot, displayName: "Fictional Ada"))
        XCTAssertTrue(saved)
        let person = try XCTUnwrap(services.peopleSnapshot.people.first)
        services.privacy.request(.person(person.id))
        try await wait { !services.privacy.busy }
        let confirmation = try XCTUnwrap(services.privacy.confirmation)
        XCTAssertEqual(Set(try XCTUnwrap(confirmation.group).members), Set(before.members))
        services.privacy.confirm()
        try await wait { !services.privacy.busy }
        XCTAssertTrue(services.peopleSnapshot.people.isEmpty)
        let analysis = try await XCTUnwrap(services.privacyContext()?.0).faceAnalysisSnapshot()
        XCTAssertTrue(Set(analysis.suppressions.map(\.faceKey)).isSuperset(of: before.members))
        await services.faceGroups.refresh()
        XCTAssertFalse(services.faceGroups.result?.groups.contains { $0.members.contains(before.seed) } == true)
        XCTAssertEqual(SyntheticAnalysisProbe.sourceReadCount, 3)
        try await retire(services, root: root)
    }

    @MainActor func testSavedGroupRefreshShowsCurrentAnalysisNeededWithoutSourceWork() async throws {
        let (services, _, _) = try await fixture()
        let repository = try XCTUnwrap(services.privacyContext()?.0)
        let photo = try XCTUnwrap(services.photos.first)
        let rows = try await repository.faceVectorRows()
        let source = try XCTUnwrap(rows.first?.sourceBinding)
        let fence = try await repository.captureFaceAnalysisPersistenceFence(photo: photo, sourceIdentity: source)
        let before = try XCTUnwrap(services.faceGroups.result)
        XCTAssertFalse(before.incomplete)
        _ = try await repository.saveFaceAnalysisBatch(fence: fence, verifiedContentHash: fence.contentHash,
            vectors: [], manifest: .openCVSFace2021December, status: .paused, reason: "fictional explicit retry")
        await services.faceGroups.refresh()
        let missing = try XCTUnwrap(services.faceGroups.result)
        XCTAssertGreaterThan(missing.revision, before.revision)
        XCTAssertTrue(missing.incomplete)
        XCTAssertTrue(services.faceGroups.retryablePhotos.contains { $0.id == photo.id })
        XCTAssertEqual(SyntheticAnalysisProbe.scanCount, 1)
        XCTAssertEqual(SyntheticAnalysisProbe.sourceReadCount, 3)
        XCTAssertEqual(SyntheticAnalysisProbe.computationCount, 3)
    }

}
