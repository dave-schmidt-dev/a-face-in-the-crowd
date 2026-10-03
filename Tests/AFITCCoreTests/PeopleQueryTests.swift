import XCTest
@testable import AFITCCore

final class PeopleQueryTests: XCTestCase {
    func testTogetherAnyOnlyFormalTruthTable() async throws {
        let fixture = try await SearchFixture.make(self)
        let p = fixture.people
        let configurations: [(String, [UUID?])] = [
            ("A", [p[0], p[1]]), ("B", [p[0], p[1], p[2]]), ("C", [p[0]]),
            ("D", [p[1]]), ("E", [p[0], p[1], nil]), ("G", [p[0], nil]), ("H", [p[0], p[0]])]
        for (name, identities) in configurations { _ = try await fixture.photo(name, identities) }
        let failed = try await fixture.photo("F", [p[0], p[1]])
        var failedPhoto = failed; failedPhoto.analysis = FaceAnalysisState(status: .failed, faces: failed.analysis.faces)
        try await fixture.catalog.save(failedPhoto, progress: ScanProgress())
        try await assertNames(fixture, .together, [p[0], p[1]], expected: ["A", "B", "E"])
        try await assertNames(fixture, .any, [p[0], p[1]], expected: ["A", "B", "C", "D", "E", "G", "H"])
        try await assertNames(fixture, .only, [p[0], p[1]], expected: ["A"])
        let only = try await fixture.query(.only, [p[0], p[1]])
        XCTAssertEqual(only.coverage.unresolvedCandidatePhotoCount, 2)
        XCTAssertEqual(only.coverage.extraPeopleCandidatePhotoCount, 1)
    }
    func testEmptySelectionsAndUnrelatedFailedPhotoDoNotGateSearch() async throws {
        let f = try await SearchFixture.make(self)
        _ = try await f.photo("confirmed", [f.people[0]])
        let failed = PhotoIdentity(relativePath: "failed", analysis: FaceAnalysisState(status: .failed))
        try await f.catalog.save(failed, progress: ScanProgress())
        var missing = failed; missing.missing = true
        missing = PhotoIdentity(relativePath: "missing", analysis: .pending, missing: true)
        try await f.catalog.save(missing, progress: ScanProgress())
        try await assertNames(f, .any, [], expected: ["confirmed", "failed"])
        try await assertNames(f, .together, [], expected: ["confirmed", "failed"])
        try await assertNames(f, .only, [f.people[0]], expected: ["confirmed"])
        XCTAssertThrowsError(try PeopleQuery(mode: .only, selectedPersonIDs: [])) { XCTAssertEqual($0 as? SearchError, .emptyOnlySelection) }
    }
    func testAllRawFacesBlockOnlyUntilExplicitValidFalseDetection() async throws {
        let f = try await SearchFixture.make(self)
        var photo = try await f.photo("raw", [f.people[0], nil])
        let extra = photo.analysis.faces[1]
        try await f.catalog.searchFixtureState(ManualFaceState(key: FaceKey(photo: photo, face: extra), notPerson: true, rejectedPeople: [f.people[1]]))
        try await assertNames(f, .only, [f.people[0]], expected: ["raw"])
        let invalid = FaceGeometry(rectangle: [0, 0, 0, 0.2], landmarks: [])
        photo.analysis = FaceAnalysisState(status: .successful, faces: photo.analysis.faces + [invalid])
        try await f.catalog.save(photo, progress: ScanProgress())
        try await f.catalog.searchFixtureState(ManualFaceState(key: FaceKey(photo: photo, face: invalid), notPerson: true))
        try await assertNames(f, .only, [f.people[0]], expected: [])
        try await assertNames(f, .any, [f.people[0]], expected: ["raw"])
    }
    func testContradictionsRejectOnlyTheirFaceAndUnrelatedNegativesPreserveConfirmation() async throws {
        let f = try await SearchFixture.make(self)
        let photo = try await f.photo("two", [f.people[0], f.people[1]])
        let key = FaceKey(photo: photo, face: photo.analysis.faces[0])
        for state in [ManualFaceState(key: key, personID: f.people[0], rejectedPeople: [f.people[0]]),
                      ManualFaceState(key: key, personID: f.people[0], deferredPeople: [f.people[0]]),
                      ManualFaceState(key: key, personID: f.people[0], notPerson: true),
                      ManualFaceState(key: key, personID: f.people[0], deferred: true)] {
            try await f.catalog.searchFixtureState(state)
            try await assertNames(f, .any, [f.people[0]], expected: [])
            try await assertNames(f, .any, [f.people[1]], expected: ["two"])
            try await assertNames(f, .only, [f.people[1]], expected: [])
        }
        try await f.catalog.searchFixtureState(ManualFaceState(key: key, personID: f.people[0], rejectedPeople: [f.people[2]], deferredPeople: [f.people[2]]))
        try await assertNames(f, .only, [f.people[0], f.people[1]], expected: ["two"])
    }
    func testAliasesCanonicalizeChainsAndRejectUnknownCyclesAndDanglingTargets() async throws {
        let f = try await SearchFixture.make(self)
        _ = try await f.photo("alias", [f.people[0]])
        _ = try await f.catalog.applyDecision(.rename(personID: f.people[0], displayName: "Same name"))
        _ = try await f.catalog.applyDecision(.rename(personID: f.people[1], displayName: "Same name"))
        try await assertNames(f, .any, [f.people[1]], expected: [])
        var first = PersonRecord(id: f.people[0], displayName: "Same name"); first.mergedInto = f.people[1]
        var second = PersonRecord(id: f.people[1], displayName: "Same name"); second.mergedInto = f.people[2]
        try await f.catalog.searchFixturePerson(first); try await f.catalog.searchFixturePerson(second)
        let snapshot = try await f.query(.only, [f.people[0], f.people[1], f.people[2]])
        XCTAssertEqual(snapshot.query.selectedPersonIDs, [f.people[2]])
        XCTAssertEqual(snapshot.selectedPeople.map(\.id), [f.people[2]])
        XCTAssertEqual(snapshot.totalCount, 1)
        let key = FaceKey(photo: snapshot.results[0].photo, face: snapshot.results[0].photo.analysis.faces[0])
        try await f.catalog.searchFixtureState(ManualFaceState(key: key, personID: f.people[2], rejectedPeople: [f.people[0]]))
        try await assertNames(f, .any, [f.people[2]], expected: [])
        let unknown = UUID()
        do { _ = try await f.query(.any, [unknown]); XCTFail("unknown accepted") } catch { XCTAssertEqual(error as? SearchError, .unknownPerson(unknown)) }
        second.mergedInto = first.id; try await f.catalog.searchFixturePerson(second)
        do { _ = try await f.query(.any, [first.id]); XCTFail("cycle accepted") } catch { XCTAssertEqual(error as? SearchError, .invalidAlias(first.id)) }
        first.mergedInto = unknown; try await f.catalog.searchFixturePerson(first)
        do { _ = try await f.query(.any, [first.id]); XCTFail("dangling accepted") } catch { XCTAssertEqual(error as? SearchError, .invalidAlias(first.id)) }
    }
    func testSelectionSizesReflectionsAndCopiesRemainIndependent() async throws {
        let f = try await SearchFixture.make(self, personCount: 20)
        for size in [1, 2, 5, 10, 20] {
            let ids = Array(f.people.prefix(size))
            _ = try await f.photo("size\(size)", ids.map(Optional.some) + [ids[0]])
            let q = try await f.query(.only, Set(ids))
            XCTAssertEqual(q.results.map { $0.photo.relativePath }, ["size\(size)"])
            for order in [Array(ids.reversed()), Array(ids.dropFirst()) + [ids[0]]] {
                let reordered = try await f.query(.only, Set(order))
                XCTAssertEqual(reordered.orderedPhotoIDs, q.orderedPhotoIDs)
                XCTAssertEqual(reordered.totalCount, q.totalCount)
                XCTAssertEqual(reordered.selectedPeople, q.selectedPeople)
            }
        }
        _ = try await f.photo("copy", [f.people[0]])
        _ = try await f.photo("unconfirmedCopy", [nil])
        try await assertNames(f, .only, [f.people[0]], expected: ["copy", "size1"])
    }
    func testMissingChangedAndStaleAnalysisCannotResurrectConfirmations() async throws {
        let f = try await SearchFixture.make(self)
        var photo = try await f.photo("generation", [f.people[0]])
        photo.missing = true; try await f.catalog.save(photo, progress: ScanProgress())
        try await assertNames(f, .any, [f.people[0]], expected: [])
        photo.missing = false; try await f.catalog.save(photo, progress: ScanProgress())
        try await assertNames(f, .only, [f.people[0]], expected: ["generation"])
        photo = PhotoIdentity(id: photo.id, relativePath: photo.relativePath, contentVersion: 2, analysis: photo.analysis)
        try await f.catalog.save(photo, progress: ScanProgress())
        try await assertNames(f, .any, [f.people[0]], expected: [])
        photo.analysis = FaceAnalysisState(status: .successful, contentVersion: 2, faces: photo.analysis.faces)
        try await f.catalog.save(photo, progress: ScanProgress())
        try await assertNames(f, .any, [f.people[0]], expected: [])
    }
}

struct SearchFixture {
    let catalog: CatalogRepository
    let root: URL
    let people: [UUID]
    static func make(_ test: XCTestCase, personCount: Int = 3) async throws -> SearchFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let catalog = try CatalogRepository(directory: root.appendingPathComponent("db"), cacheDirectory: root.appendingPathComponent("cache"))
        test.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let ids = (0..<personCount).map { _ in UUID() }
        for (index, id) in ids.enumerated() { try await catalog.searchFixturePerson(PersonRecord(id: id, displayName: "Fictional \(index)")) }
        return SearchFixture(catalog: catalog, root: root, people: ids)
    }
    func photo(_ name: String, _ identities: [UUID?], id: UUID = UUID(), capture: String? = nil, offset: String = "+09:00") async throws -> PhotoIdentity {
        let faces = identities.map { _ in FaceGeometry(rectangle: [0.1, 0.1, 0.2, 0.2], landmarks: []) }
        let photo = PhotoIdentity(id: id, relativePath: name, analysis: FaceAnalysisState(status: .successful, faces: faces),
            captureDate: capture.flatMap { CaptureDateMetadata.parse(original: $0, offset: offset) })
        try await catalog.save(photo, progress: ScanProgress())
        for (face, person) in zip(faces, identities) {
            if let person { try await catalog.searchFixtureState(ManualFaceState(key: FaceKey(photo: photo, face: face), personID: person)) }
        }
        return photo
    }
    func query(_ mode: SearchMode, _ selected: Set<UUID>) async throws -> SearchSnapshot {
        try await SearchRepository(catalog: catalog).snapshot(query: PeopleQuery(mode: mode, selectedPersonIDs: selected))
    }
    func names(_ mode: SearchMode, _ selected: Set<UUID>) async throws -> [String] {
        try await query(mode, selected).results.map { $0.photo.relativePath }.sorted()
    }
}
extension CatalogRepository {
    func searchFixturePerson(_ person: PersonRecord) throws { try peopleTransaction { try PeopleSQL.writePerson($0, person) } }
    func searchFixtureState(_ state: ManualFaceState) throws { try peopleTransaction { try PeopleSQL.writeFace($0, state) } }
}

private func assertNames(_ fixture: SearchFixture, _ mode: SearchMode, _ selected: Set<UUID>, expected: [String], file: StaticString = #filePath, line: UInt = #line) async throws {
    let actual = try await fixture.names(mode, selected)
    XCTAssertEqual(actual, expected, file: file, line: line)
}
