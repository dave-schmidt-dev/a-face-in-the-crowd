import XCTest
import SQLite3
@testable import AFITCCore

final class FaceGroupSearchTests: XCTestCase {
    private func namedFixture(_ count: Int = 3) async throws -> (GroupFixture, UUID) {
        let f = try await GroupFixture.make(self, photos: count)
        try await f.persist(f.keys.map { ($0, G.vector([0: 1])) })
        let group = try await f.group(f.keys)
        _ = try await f.catalog.applyDecision(.nameGroup(cover: group.seed, group: group, displayName: "Fictional Ada"))
        let people = try await f.catalog.peopleSnapshot()
        return (f, try XCTUnwrap(people.people.first?.id))
    }
    func testNamedThreePhotoGroupAddsPossibleWhileDefaultStaysConfirmed() async throws {
        let (f, person) = try await namedFixture()
        let query = try PeopleQuery(mode: .any, selectedPersonIDs: [person])
        let plain = try await f.catalog.searchSnapshot(query: query)
        let grouped = try await f.catalog.faceGroupSearchSnapshot(query: query)
        XCTAssertEqual(plain.totalCount, 1)
        XCTAssertEqual(grouped.confirmed.orderedPhotoIDs, plain.orderedPhotoIDs)
        XCTAssertEqual(grouped.possibleCount, 2)
        XCTAssertEqual(Set(grouped.confirmed.orderedPhotoIDs + grouped.possibleResults.map(\.photo.id)), Set(f.photos.map(\.id)))
        XCTAssertEqual(grouped.revision, grouped.membership.revision)
        XCTAssertTrue(grouped.possibleResults.allSatisfy { $0.confirmedPersonIDs.isEmpty && $0.possiblePersonIDs == [person] })
    }
    func testTogetherAnyUsePossibleAndOnlyNeverResolvesUnknown() async throws {
        let (f, person) = try await namedFixture()
        for mode in [SearchMode.together, .any] {
            let result = try await f.catalog.faceGroupSearchSnapshot(query: PeopleQuery(mode: mode, selectedPersonIDs: [person]))
            XCTAssertEqual(result.confirmed.totalCount, 1); XCTAssertEqual(result.possibleCount, 2)
        }
        let only = try await f.catalog.faceGroupSearchSnapshot(query: PeopleQuery(mode: .only, selectedPersonIDs: [person]))
        XCTAssertEqual(only.confirmed.totalCount, 1); XCTAssertEqual(only.possibleCount, 0)
        let empty = try await f.catalog.faceGroupSearchSnapshot(query: PeopleQuery(mode: .any, selectedPersonIDs: []))
        XCTAssertEqual(empty.confirmed.totalCount, 3); XCTAssertEqual(empty.possibleCount, 0)
    }
    func testFrozenCountsPagesAndNamesSurviveLaterDecisions() async throws {
        let (f, person) = try await namedFixture()
        let query = try PeopleQuery(mode: .any, selectedPersonIDs: [person])
        let frozen = try await f.catalog.faceGroupSearchSnapshot(query: query)
        let first = try frozen.possiblePage(offset: 0, limit: 1)
        let second = try frozen.possiblePage(offset: 1, limit: 1)
        XCTAssertNotEqual(first.first?.photo.id, second.first?.photo.id)
        XCTAssertTrue(try frozen.possiblePage(offset: 2).isEmpty)
        XCTAssertThrowsError(try frozen.possiblePage(offset: -1))
        _ = try await f.catalog.applyDecision(.confirm(face: f.keys[1], personID: person))
        _ = try await f.catalog.applyDecision(.rename(personID: person, displayName: "Fictional Grace"))
        let latest = try await f.catalog.faceGroupSearchSnapshot(query: query)
        XCTAssertGreaterThan(latest.revision, frozen.revision)
        XCTAssertEqual(latest.confirmed.totalCount, 2); XCTAssertEqual(latest.possibleCount, 1)
        XCTAssertEqual(frozen.confirmed.totalCount, 1); XCTAssertEqual(frozen.possibleCount, 2)
        XCTAssertEqual(frozen.confirmed.selectedPeople.first?.displayName, "Fictional Ada")
        XCTAssertEqual(try frozen.possiblePage(offset: 1, limit: 1).first?.photo.id, second.first?.photo.id)
    }
    func testSharedMembershipReuseAndStaleRevisionRecompute() async throws {
        let (f, person) = try await namedFixture()
        let shared = try await f.membership()
        let query = try PeopleQuery(mode: .any, selectedPersonIDs: [person])
        let reused = try await f.catalog.faceGroupSearchSnapshot(query: query, sharedMembership: shared)
        XCTAssertEqual(reused.membership, shared)
        _ = try await f.catalog.applyDecision(.reject(face: f.keys[1], personID: person))
        let newer = try await f.catalog.faceGroupSearchSnapshot(query: query, sharedMembership: shared)
        XCTAssertGreaterThan(newer.revision, shared.revision)
        XCTAssertFalse(newer.possibleResults.contains { $0.photo.id == f.photos[1].id })
        XCTAssertEqual(reused.possibleCount, 2)
    }
    func testSourceRebindRemovesPossibleButPreservesConfirmed() async throws {
        let (f, person) = try await namedFixture()
        _ = try await f.catalog.acquireSource(identity: "different-fictional-source", confirmed: true)
        let result = try await f.catalog.faceGroupSearchSnapshot(query: PeopleQuery(mode: .any, selectedPersonIDs: [person]))
        XCTAssertEqual(result.confirmed.totalCount, 1); XCTAssertEqual(result.possibleCount, 0)
    }
    func testCombinedCapturePinsReadWhileOtherHandleAttemptsCommit() async throws {
        let (f, person) = try await namedFixture()
        let query = try PeopleQuery(mode: .any, selectedPersonIDs: [person])
        let databasePath = await f.catalog.directory.appendingPathComponent("catalog.sqlite").path
        let result = try await f.catalog.faceGroupSearchSnapshot(query: query, afterRevisionRead: {
            var handle: OpaquePointer?
            guard sqlite3_open(databasePath, &handle) == SQLITE_OK,
                  let handle else { throw ScanError.database }
            defer { sqlite3_close(handle) }
            guard sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw ScanError.database }
            defer { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) }
            guard sqlite3_exec(handle, "UPDATE catalog_revision SET revision=revision+1", nil, nil, nil) == SQLITE_OK else { throw ScanError.database }
            guard sqlite3_exec(handle, "COMMIT", nil, nil, nil) == SQLITE_BUSY else { throw ScanError.database }
        })
        XCTAssertEqual(result.revision, result.membership.revision)
        XCTAssertEqual(result.confirmed.totalCount, 1); XCTAssertEqual(result.possibleCount, 2)
        _ = try await f.catalog.applyDecision(.confirm(face: f.keys[1], personID: person))
        let newer = try await f.catalog.faceGroupSearchSnapshot(query: query)
        XCTAssertEqual(newer.revision, result.revision + 1)
        XCTAssertEqual(newer.confirmed.totalCount, 2)
        XCTAssertEqual(result.possibleCount, 2)
    }
    func testTwoPersonTogetherRequiresCombinedIdentitiesAndAnyAcceptsEither() async throws {
        let base = try await GroupFixture.make(self, photos: 3)
        var photos = base.photos
        let second = FaceGeometry(id: G.id(901), rectangle: [0.6, 0.1, 0.2, 0.2], landmarks: [])
        photos[1].analysis = FaceAnalysisState(status: .successful, detectorVersion: "det", faces: photos[1].analysis.faces + [second])
        try await base.catalog.save(photos[1], progress: ScanProgress())
        let extraKey = FaceKey(photo: photos[1], face: second)
        let f = GroupFixture(root: base.root, catalog: base.catalog, photos: photos, keys: base.keys + [extraKey])
        try await f.persist([(f.keys[0], G.vector([0: 1])), (f.keys[1], G.vector([0: 1])),
                             (f.keys[2], G.vector([1: 1])), (extraKey, G.vector([1: 1]))])
        _ = try await f.catalog.applyDecision(.name(face: f.keys[0], displayName: "Fictional Ada"))
        _ = try await f.catalog.applyDecision(.name(face: f.keys[2], displayName: "Fictional Grace"))
        let people = try await f.catalog.peopleSnapshot()
        let selected = Set(people.people.map(\.id))
        let together = try await f.catalog.faceGroupSearchSnapshot(query: PeopleQuery(mode: .together, selectedPersonIDs: selected))
        XCTAssertEqual(together.confirmed.totalCount, 0)
        XCTAssertEqual(together.possibleResults.map(\.photo.id), [photos[1].id])
        XCTAssertEqual(together.possibleResults.first?.possiblePersonIDs, selected)
        let ada = try XCTUnwrap(people.people.first { $0.person.displayName == "Fictional Ada" }?.id)
        _ = try await f.catalog.applyDecision(.confirm(face: f.keys[1], personID: ada))
        let mixed = try await f.catalog.faceGroupSearchSnapshot(query: PeopleQuery(mode: .together, selectedPersonIDs: selected))
        XCTAssertEqual(mixed.possibleResults.first?.confirmedPersonIDs, [ada])
        XCTAssertEqual(mixed.possibleResults.first?.possiblePersonIDs, selected.subtracting([ada]))
        let any = try await f.catalog.faceGroupSearchSnapshot(query: PeopleQuery(mode: .any, selectedPersonIDs: selected))
        XCTAssertEqual(any.confirmed.totalCount, 3)
        XCTAssertEqual(any.possibleCount, 0, "Confirmed photos never duplicate in the possible section")
        let only = try await f.catalog.faceGroupSearchSnapshot(query: PeopleQuery(mode: .only, selectedPersonIDs: selected))
        XCTAssertEqual(only.confirmed.totalCount, 0); XCTAssertEqual(only.possibleCount, 0)
    }

    func testAnalysisCommitInvalidatesSharedSearchWithoutPhotoOrManualMutation() async throws {
        let (f, person) = try await namedFixture()
        let before = try await f.membership()
        let old = try await f.catalog.faceGroupSearchSnapshot(query: PeopleQuery(mode: .any, selectedPersonIDs: [person]), sharedMembership: before)
        XCTAssertEqual(old.possibleCount, 2)
        try await f.persist([(f.keys[1], G.vector([1: 1]))])
        let after = try await f.catalog.faceGroupSearchSnapshot(query: old.confirmed.query, sharedMembership: before)
        XCTAssertGreaterThan(after.revision, before.revision)
        XCTAssertEqual(after.possibleCount, 1)
        XCTAssertEqual(old.possibleCount, 2)
    }

    func testSourceRebindInvalidatesSharedMembershipButSameSourceReuseKeepsRevision() async throws {
        let (f, person) = try await namedFixture()
        let shared = try await f.membership()
        let query = try PeopleQuery(mode: .any, selectedPersonIDs: [person])
        _ = try await f.catalog.acquireSource(identity: "source-a", confirmed: false)
        let reused = try await f.catalog.faceGroupSearchSnapshot(query: query, sharedMembership: shared)
        XCTAssertEqual(reused.revision, shared.revision); XCTAssertEqual(reused.possibleCount, 2)
        _ = try await f.catalog.acquireSource(identity: "different-fictional-source", confirmed: true)
        let rebound = try await f.catalog.faceGroupSearchSnapshot(query: query, sharedMembership: shared)
        XCTAssertGreaterThan(rebound.revision, shared.revision)
        XCTAssertEqual(rebound.confirmed.totalCount, 1); XCTAssertEqual(rebound.possibleCount, 0)
        XCTAssertTrue(rebound.membership.incomplete)
    }

}
