import XCTest
@testable import AFITCCore

final class FaceGroupConfirmationTests: XCTestCase {
    private func fixture() async throws -> (GroupFixture, UUID, FaceGroupSnapshot, Int) {
        let f = try await GroupFixture.make(self)
        try await f.persist(f.keys.map { ($0, G.vector([0: 1])) })
        let original = try await f.group(Array(f.keys.prefix(3)))
        _ = try await f.catalog.applyDecision(.nameGroup(cover: original.seed, group: original, displayName: "Fictional Ada"))
        let people = try await f.catalog.peopleSnapshot()
        let person = try XCTUnwrap(people.people.first?.person)
        return (f, person.id, try await f.group(Array(f.keys.prefix(3))), person.exemplarRevision)
    }
    func testExplicitBatchChangesExactlyInspectedFacesAndUndoRestoresAll() async throws {
        let (f, person, group, revision) = try await fixture()
        let before = try await f.states()
        let decision = try await f.catalog.applyDecision(.confirmGroup(group: group, personID: person, exemplarRevision: revision))
        let states = try await f.states()
        XCTAssertTrue(group.members.allSatisfy { states[$0]?.personID == person && states[$0]?.isAnchor == true })
        XCTAssertEqual(states[f.keys[3]], before[f.keys[3]])
        let only = try await f.catalog.searchSnapshot(query: PeopleQuery(mode: .only, selectedPersonIDs: [person]))
        XCTAssertEqual(only.totalCount, 3)
        try await f.catalog.undoDecision(decision)
        let undone = try await f.states(); XCTAssertEqual(undone, before)
    }
    func testChangedMemberRejectsWholeBatchWithoutLedgerOrPartialWrites() async throws {
        let (f, person, group, revision) = try await fixture()
        _ = try await f.catalog.applyDecision(.notPerson(face: group.members[1]))
        let before = try await f.catalog.peopleSnapshot()
        do { _ = try await f.catalog.applyDecision(.confirmGroup(group: group, personID: person, exemplarRevision: revision)); XCTFail("stale batch accepted") }
        catch { XCTAssertEqual(error as? DecisionError, .conflict) }
        let after = try await f.catalog.peopleSnapshot()
        XCTAssertEqual(after.revision, before.revision); XCTAssertEqual(after.undoID, before.undoID)
        XCTAssertEqual(after.faces.map(\.state), before.faces.map(\.state))
    }
    func testChangedGenerationAndExemplarRefuseBatch() async throws {
        let (f, person, group, revision) = try await fixture()
        _ = try await f.catalog.applyDecision(.confirm(face: f.keys[3], personID: person))
        do { _ = try await f.catalog.applyDecision(.confirmGroup(group: group, personID: person, exemplarRevision: revision)); XCTFail("old exemplar accepted") }
        catch { XCTAssertEqual(error as? DecisionError, .conflict) }
        var photo = f.photos[1]
        photo.analysis = FaceAnalysisState(status: .successful, detectorVersion: "new-detector", faces: photo.analysis.faces)
        try await f.catalog.save(photo, progress: ScanProgress())
        let latest = try await f.catalog.peopleSnapshot()
        let current = try XCTUnwrap(latest.people.first?.person)
        do { _ = try await f.catalog.applyDecision(.confirmGroup(group: group, personID: person, exemplarRevision: current.exemplarRevision)); XCTFail("old generation accepted") }
        catch { XCTAssertEqual(error as? DecisionError, .staleFace) }
    }
    func testInjectedFailuresRollBackPersonFacesAndLedger() async throws {
        let (f, person, group, revision) = try await fixture()
        for failure in [DecisionFailurePoint.afterPersonWrite, .afterFaceWrite, .afterLedgerWrite] {
            let before = try await f.catalog.peopleSnapshot()
            do { _ = try await f.catalog.applyDecision(.confirmGroup(group: group, personID: person, exemplarRevision: revision), failure: failure); XCTFail("failure ignored") }
            catch { XCTAssertEqual(error as? DecisionError, .injectedFailure) }
            let after = try await f.catalog.peopleSnapshot()
            XCTAssertEqual(after.revision, before.revision); XCTAssertEqual(after.undoID, before.undoID)
            XCTAssertEqual(after.faces.map(\.state), before.faces.map(\.state))
            XCTAssertEqual(after.people.map(\.person), before.people.map(\.person))
        }
    }
    func testUndoRefusesChangedBatchMemberWithoutPartialRestore() async throws {
        let (f, person, group, revision) = try await fixture()
        let decision = try await f.catalog.applyDecision(.confirmGroup(group: group, personID: person, exemplarRevision: revision))
        _ = try await f.catalog.applyDecision(.notPerson(face: group.members[1]))
        let before = try await f.states()
        do { try await f.catalog.undoDecision(decision); XCTFail("stale batch undo accepted") }
        catch { XCTAssertEqual(error as? DecisionError, .conflict) }
        let after = try await f.states(); XCTAssertEqual(after, before)
    }
    func testBackupValidationPreservesBulkLedgerAndWholeBatchUndo() async throws {
        let (f, person, group, revision) = try await fixture()
        let before = try await f.states()
        let decision = try await f.catalog.applyDecision(.confirmGroup(group: group, personID: person, exemplarRevision: revision))
        let backup = try await f.catalog.prepareBackup()
        let validator = try RestoreValidator(stagingDirectory: f.root.appendingPathComponent("validation"))
        let validated = try await validator.validate(package: backup.directory)
        let restore = try await CatalogRestoreRepository.beginRestore(catalog: f.catalog)
        let restored = try await restore.restore(validated)
        let confirmed = try await restored.searchSnapshot(query: PeopleQuery(mode: .any, selectedPersonIDs: [person]))
        XCTAssertEqual(confirmed.totalCount, 3)
        try await restored.undoDecision(decision)
        let states = try await restored.peopleSnapshot().faces.map(\.state)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: states.map { ($0.key, $0) }), before)
    }

    func testNamingGroupConfirmsAllMembersAndUndoSurvivesReopenAndBackup() async throws {
        let f = try await GroupFixture.make(self)
        try await f.persist(Array(f.keys.prefix(3)).map { ($0, G.vector([0: 1])) })
        let group = try await f.group(Array(f.keys.prefix(3)))
        let before = try await f.states()
        let decision = try await f.catalog.nameGroup(cover: group.seed, group: group, displayName: "Fictional Ada")
        let named = try await f.catalog.peopleSnapshot()
        let person = try XCTUnwrap(named.people.first?.person)
        XCTAssertEqual(Set(named.faces.filter { $0.state.personID == person.id }.map(\.key)), Set(group.members))
        XCTAssertEqual(Set(named.faces.filter { $0.state.personID == person.id && $0.state.isAnchor }.map(\.key)), [group.seed])
        let query = try PeopleQuery(mode: .any, selectedPersonIDs: [person.id])
        let namedSearch = try await f.catalog.searchSnapshot(query: query)
        XCTAssertEqual(namedSearch.totalCount, 3)

        let backupDirectory = try await { () async throws -> URL in
            let reopened = try CatalogRepository(directory: f.root.appendingPathComponent("db"),
                                                 cacheDirectory: f.root.appendingPathComponent("cache"))
            let reopenedSearch = try await reopened.searchSnapshot(query: query)
            XCTAssertEqual(reopenedSearch.totalCount, 3)
            let backup = try await reopened.prepareBackup()
            return backup.directory
        }()
        let validator = try RestoreValidator(stagingDirectory: f.root.appendingPathComponent("validation"))
        let validated = try await validator.validate(package: backupDirectory)
        let restore = try await CatalogRestoreRepository.beginRestore(catalog: f.catalog)
        let restored = try await restore.restore(validated)
        let restoredSearch = try await restored.searchSnapshot(query: query)
        XCTAssertEqual(restoredSearch.totalCount, 3)
        try await restored.undoDecision(decision)
        let undone = try await restored.peopleSnapshot()
        XCTAssertTrue(undone.people.isEmpty)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: undone.faces.map { ($0.key, $0.state) }), before)
    }

    func testNamingGroupFailurePointsLeaveEveryFacePersonAndLedgerUntouched() async throws {
        let f = try await GroupFixture.make(self)
        try await f.persist(Array(f.keys.prefix(3)).map { ($0, G.vector([0: 1])) })
        let group = try await f.group(Array(f.keys.prefix(3)))
        for failure in DecisionFailurePoint.allCases {
            let before = try await f.catalog.peopleSnapshot()
            do {
                _ = try await f.catalog.applyDecision(.nameGroup(cover: group.seed, group: group,
                                                                  displayName: "Fictional Ada"), failure: failure)
                XCTFail("failure point ignored: \(failure)")
            } catch { XCTAssertEqual(error as? DecisionError, .injectedFailure) }
            let after = try await f.catalog.peopleSnapshot()
            XCTAssertEqual(after.revision, before.revision)
            XCTAssertEqual(after.undoID, before.undoID)
            XCTAssertEqual(after.people.map(\.person), before.people.map(\.person))
            XCTAssertEqual(after.faces.map(\.state), before.faces.map(\.state))
        }
    }

    func testExistingPersonGroupLabelConfirmsAllMembersWithOneNewAnchorAndAtomicUndo() async throws {
        let f = try await GroupFixture.make(self)
        try await f.persist(Array(f.keys.prefix(3)).map { ($0, G.vector([0: 1])) })
        _ = try await f.catalog.applyDecision(.name(face: f.keys[0], displayName: "Fictional Ada"))
        let namedSnapshot = try await f.catalog.peopleSnapshot()
        let person = try XCTUnwrap(namedSnapshot.people.first?.person)
        let group = try await f.group(Array(f.keys.prefix(3)))
        let before = try await f.states()
        for failure in DecisionFailurePoint.allCases {
            let snapshot = try await f.catalog.peopleSnapshot()
            do {
                _ = try await f.catalog.applyDecision(.labelGroup(cover: f.keys[1], group: group,
                    personID: person.id, exemplarRevision: person.exemplarRevision), failure: failure)
                XCTFail("failure point ignored: \(failure)")
            } catch { XCTAssertEqual(error as? DecisionError, .injectedFailure) }
            let after = try await f.catalog.peopleSnapshot()
            XCTAssertEqual(after.revision, snapshot.revision)
            XCTAssertEqual(after.undoID, snapshot.undoID)
            XCTAssertEqual(after.people.map(\.person), snapshot.people.map(\.person))
            XCTAssertEqual(after.faces.map(\.state), snapshot.faces.map(\.state))
        }
        let decision = try await f.catalog.labelGroup(cover: f.keys[1], group: group, personID: person.id,
                                                      exemplarRevision: person.exemplarRevision)
        let labeled = try await f.catalog.peopleSnapshot()
        XCTAssertEqual(Set(labeled.faces.filter { $0.state.personID == person.id }.map(\.key)), Set(group.members))
        XCTAssertEqual(Set(labeled.faces.filter { $0.state.personID == person.id && $0.state.isAnchor }.map(\.key)),
                       [f.keys[0], f.keys[1]])
        XCTAssertEqual(labeled.people.first?.person.cover, f.keys[0], "a valid existing cover remains stable")
        try await f.catalog.undoDecision(decision)
        let undone = try await f.states()
        XCTAssertEqual(undone, before)
    }

    func testGroupNamingRejectsExcludedSuppressedAndSamePhotoMembers() async throws {
        let excluded = try await GroupFixture.make(self)
        try await excluded.persist(Array(excluded.keys.prefix(3)).map { ($0, G.vector([0: 1])) })
        let excludedGroup = try await excluded.group(Array(excluded.keys.prefix(3)))
        _ = try await excluded.catalog.excludeGroupMember(face: excluded.keys[1], group: excludedGroup)
        do {
            _ = try await excluded.catalog.nameGroup(cover: excludedGroup.seed, group: excludedGroup, displayName: "Excluded")
            XCTFail("a separated member was labeled")
        } catch { XCTAssertEqual(error as? DecisionError, .conflict) }
        let exclusionState = try await excluded.catalog.peopleSnapshot()
        XCTAssertTrue(exclusionState.people.isEmpty)

        let suppressed = try await GroupFixture.make(self)
        try await suppressed.persist(Array(suppressed.keys.prefix(3)).map { ($0, G.vector([0: 1])) })
        let suppressedGroup = try await suppressed.group(Array(suppressed.keys.prefix(3)))
        let photo = suppressed.photos[1]
        try await suppressed.catalog.suppressFace(key: suppressed.keys[1], photoID: photo.id,
            contentVersion: photo.contentVersion, contentHash: photo.contentHash!, sourceBinding: "source-a")
        do {
            _ = try await suppressed.catalog.nameGroup(cover: suppressedGroup.seed, group: suppressedGroup, displayName: "Suppressed")
            XCTFail("a suppressed member was labeled")
        } catch { XCTAssertEqual(error as? DecisionError, .conflict) }

        let samePhoto = try await GroupFixture.make(self)
        var photos = samePhoto.photos
        var photoWithTwoFaces = photos[0]
        let secondGeometry = FaceGeometry(id: G.id(999), rectangle: [0.6, 0.1, 0.2, 0.2], landmarks: [])
        photoWithTwoFaces.analysis = FaceAnalysisState(status: .successful, detectorVersion: "det",
            faces: photoWithTwoFaces.analysis.faces + [secondGeometry])
        try await samePhoto.catalog.save(photoWithTwoFaces, progress: ScanProgress())
        photos[0] = photoWithTwoFaces
        let secondKey = FaceKey(photo: photoWithTwoFaces, face: secondGeometry)
        let expanded = GroupFixture(root: samePhoto.root, catalog: samePhoto.catalog, photos: photos,
                                    keys: samePhoto.keys + [secondKey])
        try await expanded.persist([(samePhoto.keys[0], G.vector([0: 1])), (secondKey, G.vector([0: 1]))])
        let before = try await expanded.states()
        let unsafe = FaceGroupSnapshot(seed: samePhoto.keys[0], members: [samePhoto.keys[0], secondKey],
                                       expectedStates: [before[samePhoto.keys[0]]!, before[secondKey]!])
        do {
            _ = try await samePhoto.catalog.nameGroup(cover: unsafe.seed, group: unsafe, displayName: "Same photo")
            XCTFail("two faces from one photo were labeled as a group")
        } catch { XCTAssertEqual(error as? DecisionError, .conflict) }
    }

    func testNamedMemberExclusionLeavesSearchAndUndoConsistentAcrossReopen() async throws {
        let f = try await GroupFixture.make(self)
        try await f.persist(Array(f.keys.prefix(3)).map { ($0, G.vector([0: 1])) })
        let unnamed = try await f.group(Array(f.keys.prefix(3)))
        _ = try await f.catalog.nameGroup(cover: unnamed.seed, group: unnamed, displayName: "Fictional Ada")
        let namedSnapshot = try await f.catalog.peopleSnapshot()
        let person = try XCTUnwrap(namedSnapshot.people.first?.person)
        let namedGroup = try await f.group(Array(f.keys.prefix(3)))
        for failure in DecisionFailurePoint.allCases {
            let before = try await f.catalog.peopleSnapshot()
            do {
                _ = try await f.catalog.applyDecision(.excludeGroupMember(face: f.keys[1], group: namedGroup),
                                                      failure: failure)
                XCTFail("failure point ignored: \(failure)")
            } catch { XCTAssertEqual(error as? DecisionError, .injectedFailure) }
            let after = try await f.catalog.peopleSnapshot()
            XCTAssertEqual(after.revision, before.revision)
            XCTAssertEqual(after.undoID, before.undoID)
            XCTAssertEqual(after.people.map(\.person), before.people.map(\.person))
            XCTAssertEqual(after.faces.map(\.state), before.faces.map(\.state))
            let separations = try await f.catalog.groupSeparations(for: f.keys[1])
            XCTAssertTrue(separations.isEmpty)
        }
        let exclusion = try await f.catalog.excludeGroupMember(face: f.keys[1], group: namedGroup)
        let corrected = try PeopleQuery(mode: .any, selectedPersonIDs: [person.id])
        let correctedSearch = try await f.catalog.searchSnapshot(query: corrected)
        XCTAssertEqual(correctedSearch.totalCount, 2)
        XCTAssertEqual(Set(correctedSearch.orderedPhotoIDs), Set(namedGroup.members.map(\.photoID)).subtracting([f.photos[1].id]))
        let correctedFace = try await f.catalog.peopleSnapshot().faces.first { $0.key == f.keys[1] }?.state
        XCTAssertNil(correctedFace?.personID)
        XCTAssertTrue(correctedFace?.rejectedPeople.contains(person.id) == true)
        let savedSeparations = try await f.catalog.groupSeparations(for: f.keys[1])
        XCTAssertEqual(savedSeparations, Set([f.keys[0], f.keys[2]]))

        let reopened = try CatalogRepository(directory: f.root.appendingPathComponent("db"),
                                             cacheDirectory: f.root.appendingPathComponent("cache"))
        let separationSurvivedReopen = try await reopened.areGroupSeparated(faceKeyA: f.keys[1], faceKeyB: f.keys[2])
        XCTAssertTrue(separationSurvivedReopen)
        let reopenedSearch = try await reopened.searchSnapshot(query: corrected)
        XCTAssertEqual(reopenedSearch.totalCount, 2)
        try await reopened.undoDecision(exclusion)
        let undoneSearch = try await reopened.searchSnapshot(query: corrected)
        XCTAssertEqual(undoneSearch.totalCount, 3)
        let pairRestored = try await reopened.areGroupSeparated(faceKeyA: f.keys[1], faceKeyB: f.keys[0])
        XCTAssertFalse(pairRestored)
        let restoredMember = try await reopened.peopleSnapshot().faces.first { $0.key == f.keys[1] }?.state
        XCTAssertEqual(restoredMember?.personID, person.id)
    }

    func testOneThousandMemberGroupNameConfirmsEveryPhotoWithOneAnchor() async throws {
        let original = try await GroupFixture.make(self, photos: 1_000)
        var photos: [PhotoIdentity] = []
        photos.reserveCapacity(original.photos.count)
        for var photo in original.photos {
            let prior = try XCTUnwrap(photo.analysis.faces.first)
            let geometry = FaceGeometry(id: prior.id, rectangle: [0.05, 0.1, 0.12, 0.2], landmarks: [])
            photo.analysis = FaceAnalysisState(status: .successful, detectorVersion: "det", faces: [geometry])
            try await original.catalog.save(photo, progress: ScanProgress())
            photos.append(photo)
        }
        let f = GroupFixture(root: original.root, catalog: original.catalog, photos: photos,
                             keys: photos.map { FaceKey(photo: $0, face: $0.analysis.faces[0]) })
        try await f.persist(f.keys.map { ($0, G.vector([0: 1])) })
        let group = try await f.group(f.keys)
        XCTAssertEqual(group.members.count, 1_000)
        let decision = try await f.catalog.nameGroup(cover: group.seed, group: group, displayName: "Fictional Ada")
        let saved = try await f.catalog.peopleSnapshot()
        let person = try XCTUnwrap(saved.people.first?.person)
        XCTAssertEqual(saved.faces.filter { $0.state.personID == person.id }.count, 1_000)
        XCTAssertEqual(saved.faces.filter { $0.state.personID == person.id && $0.state.isAnchor }.count, 1)
        let search = try await f.catalog.searchSnapshot(query: PeopleQuery(mode: .any, selectedPersonIDs: [person.id]))
        XCTAssertEqual(search.totalCount, 1_000)
        try await f.catalog.undoDecision(decision)
        let undone = try await f.catalog.peopleSnapshot()
        XCTAssertTrue(undone.people.isEmpty)
    }

    func testGroupLabelRejectsThirdPersonRejectedDeferredAndNotPersonMembers() async throws {
        let f = try await GroupFixture.make(self, photos: 6)
        try await f.persist(f.keys.map { ($0, G.vector([0: 1])) })
        _ = try await f.catalog.applyDecision(.name(face: f.keys[0], displayName: "Fictional Ada"))
        let namedSnapshot = try await f.catalog.peopleSnapshot()
        let person = try XCTUnwrap(namedSnapshot.people.first?.person)
        _ = try await f.catalog.applyDecision(.name(face: f.keys[1], displayName: "Fictional Bea"))
        _ = try await f.catalog.applyDecision(.reject(face: f.keys[2], personID: person.id))
        _ = try await f.catalog.applyDecision(.unsure(face: f.keys[3], personID: nil))
        _ = try await f.catalog.applyDecision(.notPerson(face: f.keys[4]))
        let snapshot = try await f.catalog.peopleSnapshot()
        let revision = try XCTUnwrap(snapshot.people.first { $0.person.id == person.id }?.person.exemplarRevision)
        let beforeStates = Dictionary(uniqueKeysWithValues: snapshot.faces.map { ($0.key, $0.state) })
        let groups = [
            FaceGroupSnapshot(seed: f.keys[0], members: [f.keys[0], f.keys[1]], expectedStates: [beforeStates[f.keys[0]]!, beforeStates[f.keys[1]]!]),
            FaceGroupSnapshot(seed: f.keys[0], members: [f.keys[0], f.keys[2]], expectedStates: [beforeStates[f.keys[0]]!, beforeStates[f.keys[2]]!]),
            FaceGroupSnapshot(seed: f.keys[0], members: [f.keys[0], f.keys[3]], expectedStates: [beforeStates[f.keys[0]]!, beforeStates[f.keys[3]]!]),
            FaceGroupSnapshot(seed: f.keys[0], members: [f.keys[0], f.keys[4]], expectedStates: [beforeStates[f.keys[0]]!, beforeStates[f.keys[4]]!])
        ]
        for group in groups {
            let before = try await f.catalog.peopleSnapshot()
            do {
                _ = try await f.catalog.labelGroup(cover: f.keys[0], group: group, personID: person.id,
                                                   exemplarRevision: revision)
                XCTFail("unsafe group member was labeled: \(group.members.last!.faceID)")
            } catch { XCTAssertEqual(error as? DecisionError, .conflict) }
            let after = try await f.catalog.peopleSnapshot()
            XCTAssertEqual(after.revision, before.revision)
            XCTAssertEqual(after.undoID, before.undoID)
            XCTAssertEqual(after.people.map(\.person), before.people.map(\.person))
            XCTAssertEqual(after.faces.map(\.state), before.faces.map(\.state))
        }
    }

}
