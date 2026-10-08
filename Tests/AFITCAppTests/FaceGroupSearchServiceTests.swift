import XCTest
@testable import AFITCApp
import AFITCCore

final class FaceGroupSearchServiceTests: XCTestCase {
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Actual App search did not finish")
    }
    @MainActor private func fixture() async throws -> (AppServices, UUID, FaceGroup) {
        SyntheticAnalysisProbe.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = try AppSessionFixture.root(in: root)
        let services = AppServices(launch: LaunchOptions(arguments: ["--uitest-synthetic-source", "--uitest-synthetic-detector", "--uitest-synthetic-faces"], ownedRoot: root))
        addTeardownBlock {
            let drained = await services.quiesceCatalogSession(); XCTAssertTrue(drained)
            if let repo = await services.privacyContext()?.0 {
                let owner = try await CatalogSuspensionRepository.beginSuspension(catalog: repo)
                try await owner.suspend(); _ = try await owner.reopen()
            }
            await services.releaseProtectedGraph()
            try? FileManager.default.removeItem(at: root)
        }
        try await wait { services.canStart && services.hasLoadedPeopleSnapshot && !services.isRestoringSource }
        services.choose(source); services.startScan(confirmedSource: true)
        try await wait { services.canStart && !services.isScanning }
        await services.refreshPeople()
        await services.faceGroups.refresh()
        let group = try XCTUnwrap(services.faceGroups.result?.groups.first { $0.members.count == 3 })
        let states = Dictionary(uniqueKeysWithValues: services.peopleSnapshot.faces.map { ($0.key, $0.state) })
        let pinned = try XCTUnwrap(group.snapshot(states: states))
        let saved = await services.decide(.nameGroup(cover: pinned.seed, group: pinned, displayName: "Fictional Ada")); XCTAssertTrue(saved)
        return (services, try XCTUnwrap(services.peopleSnapshot.people.first?.id), group)
    }
    @MainActor private func query(_ services: AppServices, person: UUID, mode: SearchMode = .any) async throws -> SearchService {
        let search = services.presentation.search
        search.search(mode: mode, selected: [person], services: services)
        try await wait { !search.searching }
        XCTAssertNil(search.error)
        return search
    }
    @MainActor private func assertNoSourceWork() {
        XCTAssertEqual(SyntheticAnalysisProbe.scanCount, 1)
        XCTAssertEqual(SyntheticAnalysisProbe.sourceReadCount, 3)
        XCTAssertEqual(SyntheticAnalysisProbe.computationCount, 3)
    }
    @MainActor func testNamingThreePhotoGroupConfirmsSearchResultsWithoutWork() async throws {
        let (services, person, _) = try await fixture()
        let shared = try XCTUnwrap(services.faceGroups.result)
        let search = try await query(services, person: person)
        XCTAssertEqual(search.snapshot?.totalCount, 3)
        XCTAssertEqual(search.groupedSnapshot?.possibleCount, 0)
        XCTAssertTrue(search.visiblePossibleResults.isEmpty)
        XCTAssertEqual(search.groupedSnapshot?.membership, shared)
        XCTAssertEqual(search.snapshot?.revision, search.groupedSnapshot?.membership.revision)
        assertNoSourceWork()
    }
    @MainActor func testExplicitBulkConfirmationAddsAnchorsAndUndoRestoresGroupNameState() async throws {
        let (services, person, group) = try await fixture()
        let before = try await query(services, person: person)
        let frozen = try XCTUnwrap(before.groupedSnapshot)
        let states = Dictionary(uniqueKeysWithValues: services.peopleSnapshot.faces.map { ($0.key, $0.state) })
        let pinned = try XCTUnwrap(group.snapshot(states: states))
        let revision = try XCTUnwrap(services.peopleSnapshot.people.first?.person.exemplarRevision)
        let saved = await services.decide(.confirmGroup(group: pinned, personID: person, exemplarRevision: revision)); XCTAssertTrue(saved)
        before.refreshIfNeeded(services: services)
        try await wait { !before.searching }
        let after = before
        XCTAssertEqual(after.snapshot?.query.mode, .any)
        XCTAssertEqual(after.snapshot?.query.selectedPersonIDs, [person])
        XCTAssertEqual(after.snapshot?.totalCount, 3); XCTAssertEqual(after.groupedSnapshot?.possibleCount, 0)
        XCTAssertEqual(frozen.confirmed.totalCount, 3); XCTAssertEqual(frozen.possibleCount, 0)
        await services.undoDecision()
        after.refreshIfNeeded(services: services)
        try await wait { !after.searching }
        let undone = after
        XCTAssertEqual(undone.snapshot?.query.mode, .any)
        XCTAssertEqual(undone.snapshot?.totalCount, 3); XCTAssertEqual(undone.groupedSnapshot?.possibleCount, 0)
        assertNoSourceWork()
    }
    @MainActor func testOnlyWithholdsPhotosWithUnresolvedFacesAfterGroupLabel() async throws {
        let (services, person, group) = try await fixture()
        let states = Dictionary(uniqueKeysWithValues: services.peopleSnapshot.faces.map { ($0.key, $0.state) })
        let pinned = try XCTUnwrap(group.snapshot(states: states))
        let revision = try XCTUnwrap(services.peopleSnapshot.people.first?.person.exemplarRevision)
        let saved = await services.decide(.confirmGroup(group: pinned, personID: person, exemplarRevision: revision)); XCTAssertTrue(saved)
        let search = try await query(services, person: person, mode: .only)
        XCTAssertEqual(search.snapshot?.totalCount, 0)
        XCTAssertEqual(search.snapshot?.coverage.unresolvedCandidatePhotoCount, 3)
        XCTAssertEqual(search.groupedSnapshot?.possibleCount, 0)
        assertNoSourceWork()
    }
    @MainActor func testLatestQueryGenerationPublishesBothSectionsTogether() async throws {
        let (services, person, _) = try await fixture()
        let search = services.presentation.search
        search.search(mode: .any, selected: [person], services: services)
        search.search(mode: .only, selected: [person], services: services)
        try await wait { !search.searching }
        XCTAssertEqual(search.snapshot?.query.mode, .only)
        XCTAssertEqual(search.groupedSnapshot?.confirmed.query.mode, .only)
        XCTAssertTrue(search.visiblePossibleResults.isEmpty)
        assertNoSourceWork()
    }
    @MainActor func testPaginationUsesFrozenSnapshotAndRetirementClearsBothSections() async throws {
        let (services, person, _) = try await fixture()
        let search = try await query(services, person: person)
        let confirmed = search.visibleResults.map(\.photo.id), possible = search.visiblePossibleResults.map(\.photo.id)
        _ = await services.decide(.rename(personID: person, displayName: "Fictional Grace"))
        search.nextPage(); search.nextPossiblePage()
        XCTAssertEqual(search.visibleResults.map(\.photo.id), confirmed)
        XCTAssertEqual(search.visiblePossibleResults.map(\.photo.id), possible)
        XCTAssertEqual(search.snapshot?.selectedPeople.first?.displayName, "Fictional Ada")
        let drained = await services.quiesceCatalogSession(); XCTAssertTrue(drained)
        search.nextPossiblePage()
        XCTAssertNil(search.snapshot); XCTAssertNil(search.groupedSnapshot)
        XCTAssertTrue(search.visibleResults.isEmpty); XCTAssertTrue(search.visiblePossibleResults.isEmpty)
        assertNoSourceWork()
    }
}
