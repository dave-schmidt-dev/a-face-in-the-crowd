import XCTest
import SQLite3
@testable import AFITCCore

struct DecisionFixture {
    let root: URL
    let catalog: CatalogRepository
    let photos: [PhotoIdentity]
    var first: FaceKey { FaceKey(photo: photos[0], face: photos[0].analysis.faces[0]) }
    var second: FaceKey { FaceKey(photo: photos[0], face: photos[0].analysis.faces[1]) }
    var duplicate: FaceKey { FaceKey(photo: photos[1], face: photos[1].analysis.faces[0]) }
    static func make(_ test: XCTestCase) async throws -> DecisionFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let catalog = try CatalogRepository(directory: root.appendingPathComponent("db"), cacheDirectory: root.appendingPathComponent("cache"))
        let faces = [FaceGeometry(rectangle: [0.1, 0.1, 0.2, 0.3], landmarks: []), FaceGeometry(rectangle: [0.6, 0.4, 0.2, 0.3], landmarks: [])]
        let photos = [PhotoIdentity(relativePath: "a.jpg", analysis: FaceAnalysisState(status: .successful, faces: faces)),
                      PhotoIdentity(relativePath: "copy/a.jpg", analysis: FaceAnalysisState(status: .successful, faces: [FaceGeometry(rectangle: faces[0].rectangle, landmarks: [])]))]
        for photo in photos { try await catalog.save(photo, progress: ScanProgress()) }
        return DecisionFixture(root: root, catalog: catalog, photos: photos)
    }
    func snapshot() async throws -> PeopleSnapshot { try await catalog.peopleSnapshot() }
    func named(_ name: String = "Fixture A", face: FaceKey? = nil) async throws -> PersonRecord {
        _ = try await catalog.applyDecision(.name(face: face ?? first, displayName: name))
        return try await snapshot().people.last!.person
    }
}

final class DecisionDurabilityTests: XCTestCase {
    func testNamingOnlySelectedFaceAndDuplicateNamesSeparate() async throws {
        let fixture = try await DecisionFixture.make(self)
        let first = try await fixture.named()
        var snapshot = try await fixture.snapshot()
        XCTAssertEqual(snapshot.people.count, 1)
        XCTAssertEqual(snapshot.faces.filter { $0.state.personID == first.id }.count, 1)
        XCTAssertNil(snapshot.faces.first { $0.key == fixture.second }?.state.personID)
        let second = try await fixture.named(face: fixture.second)
        snapshot = try await fixture.snapshot()
        XCTAssertNotEqual(first.id, second.id); XCTAssertEqual(first.displayName, second.displayName)
        XCTAssertEqual(snapshot.people.map(\.confirmedPhotoCount), [1, 1])
    }
    func testPairNegativeAndUnsureSurviveReopenAndOtherConfirmation() async throws {
        let fixture = try await DecisionFixture.make(self)
        let personA = try await fixture.named()
        let personB = try await fixture.named("Fixture B", face: fixture.second)
        _ = try await fixture.catalog.applyDecision(.reject(face: fixture.first, personID: personA.id))
        _ = try await fixture.catalog.applyDecision(.unsure(face: fixture.first, personID: personA.id))
        _ = try await fixture.catalog.applyDecision(.confirm(face: fixture.first, personID: personB.id))
        let reopened = try CatalogRepository(directory: fixture.root.appendingPathComponent("db"), cacheDirectory: fixture.root.appendingPathComponent("cache"))
        let snapshot = try await reopened.peopleSnapshot()
        let state = try XCTUnwrap(snapshot.faces.first { $0.key == fixture.first }?.state)
        XCTAssertEqual(state.personID, personB.id); XCTAssertTrue(state.rejectedPeople.contains(personA.id))
        XCTAssertTrue(state.deferredPeople.contains(personA.id)); XCTAssertFalse(state.rejectedPeople.contains(personB.id))
        XCTAssertEqual(snapshot.people.first { $0.id == personA.id }?.confirmedPhotoCount, 0)
        XCTAssertEqual(snapshot.people.first { $0.id == personB.id }?.confirmedPhotoCount, 1)
        // Unchanged source checkpoint saves retain the exact face key and decisions.
        try await reopened.save(fixture.photos[0], progress: ScanProgress())
        let after = try await reopened.peopleSnapshot()
        XCTAssertEqual(after.faces.first { $0.key == fixture.first }?.state, state)
    }
    func testGenerationDetectorStatusMissingAndUnknownKeysCannotConfirm() async throws {
        let fixture = try await DecisionFixture.make(self), person = try await fixture.named()
        let bad = [FaceKey(photoID: UUID(), contentVersion: 1, detectorVersion: fixture.first.detectorVersion, faceID: fixture.first.faceID),
                   FaceKey(photoID: fixture.first.photoID, contentVersion: 2, detectorVersion: fixture.first.detectorVersion, faceID: fixture.first.faceID),
                   FaceKey(photoID: fixture.first.photoID, contentVersion: 1, detectorVersion: "wrong", faceID: fixture.first.faceID),
                   FaceKey(photoID: fixture.first.photoID, contentVersion: 1, detectorVersion: fixture.first.detectorVersion, faceID: UUID())]
        for key in bad {
            do { _ = try await fixture.catalog.applyDecision(.confirm(face: key, personID: person.id)); XCTFail("Stale key accepted") }
            catch { XCTAssertEqual(error as? DecisionError, .staleFace) }
        }
        for status in [AnalysisStatus.pending, .skipped, .failed] {
            let photo = PhotoIdentity(id: fixture.photos[0].id, relativePath: fixture.photos[0].relativePath,
                analysis: FaceAnalysisState(status: status, faces: fixture.photos[0].analysis.faces))
            try await fixture.catalog.save(photo, progress: ScanProgress())
            do { _ = try await fixture.catalog.applyDecision(.confirm(face: fixture.first, personID: person.id)); XCTFail("Incomplete index accepted") }
            catch { XCTAssertEqual(error as? DecisionError, .staleFace) }
        }
        var missing = fixture.photos[0]; missing.missing = true
        try await fixture.catalog.save(missing, progress: ScanProgress())
        let snapshot = try await fixture.snapshot()
        XCTAssertEqual(snapshot.people[0].confirmedPhotoCount, 0)
        do { _ = try await fixture.catalog.applyDecision(.confirm(face: fixture.first, personID: person.id)); XCTFail("Missing accepted") }
        catch { XCTAssertEqual(error as? DecisionError, .staleFace) }
    }
    func testChangedGenerationCannotInheritDecisionsOrAnchors() async throws {
        let fixture = try await DecisionFixture.make(self), person = try await fixture.named()
        _ = try await fixture.catalog.applyDecision(.reject(face: fixture.second, personID: person.id))
        let changed = PhotoIdentity(id: fixture.photos[0].id, relativePath: fixture.photos[0].relativePath, contentVersion: 2,
            analysis: FaceAnalysisState(status: .successful, contentVersion: 2, faces: fixture.photos[0].analysis.faces))
        try await fixture.catalog.save(changed, progress: ScanProgress())
        let snapshot = try await fixture.snapshot()
        XCTAssertEqual(snapshot.people[0].confirmedPhotoCount, 0)
        XCTAssertGreaterThan(snapshot.people[0].person.exemplarRevision, person.exemplarRevision)
        XCTAssertTrue(snapshot.faces.filter { $0.key.photoID == changed.id }.allSatisfy {
            $0.state.personID == nil && !$0.state.isAnchor && $0.state.rejectedPeople.isEmpty
        })
        do { _ = try await fixture.catalog.applyDecision(.confirm(face: fixture.first, personID: person.id)); XCTFail("Old face inherited") }
        catch { XCTAssertEqual(error as? DecisionError, .staleFace) }
    }
    func testDuplicateCopiesIndependentAndRepeatedFacesCountOnce() async throws {
        let fixture = try await DecisionFixture.make(self), person = try await fixture.named()
        _ = try await fixture.catalog.applyDecision(.confirm(face: fixture.second, personID: person.id))
        var snapshot = try await fixture.snapshot()
        XCTAssertEqual(snapshot.people[0].confirmedPhotoCount, 1)
        XCTAssertNil(snapshot.faces.first { $0.key == fixture.duplicate }?.state.personID)
        _ = try await fixture.catalog.applyDecision(.confirm(face: fixture.duplicate, personID: person.id))
        snapshot = try await fixture.snapshot(); XCTAssertEqual(snapshot.people[0].confirmedPhotoCount, 2)
        let lease = try await fixture.catalog.claimLease()
        _ = try await fixture.catalog.markMissing(except: [fixture.photos[0].relativePath], progress: ScanProgress(), lease: lease)
        snapshot = try await fixture.snapshot(); XCTAssertEqual(snapshot.people[0].confirmedPhotoCount, 1)
    }
    func testSchemaTwoBackfillAndTransactionalMigrationFailure() async throws {
        let fixture = try await DecisionFixture.make(self)
        let file = fixture.root.appendingPathComponent("legacy.sqlite")
        var handle: OpaquePointer?; XCTAssertEqual(sqlite3_open(file.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        try CatalogSchema.migrate(db, target: 2)
        try PeopleSQL.run(db, "INSERT INTO photos VALUES(?,?,?)", strings: [fixture.photos[0].id.uuidString, fixture.photos[0].relativePath], data: JSONEncoder().encode(fixture.photos[0]))
        let failing = CatalogSchema.Migration(version: 3, sql: PeopleSQL.schema, backfill: { db in
            try PeopleSQL.backfill(db); throw DecisionError.injectedFailure
        })
        XCTAssertThrowsError(try CatalogSchema.migrate(db, registry: [failing], target: 3))
        XCTAssertEqual(try CatalogSchema.version(db), 2)
        XCTAssertEqual(try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM photos"), 1)
        var statement: OpaquePointer?
        XCTAssertNotEqual(sqlite3_prepare_v2(db, "SELECT * FROM current_faces", -1, &statement, nil), SQLITE_OK)
        sqlite3_finalize(statement)
        try CatalogSchema.migrate(db)
        XCTAssertEqual(try CatalogSchema.version(db), CatalogSchema.currentVersion)
        XCTAssertEqual(try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM current_faces"), 2)
        let legacy: [PhotoIdentity] = try PeopleSQL.rows(db, "SELECT payload FROM photos")
        XCTAssertEqual(legacy, [fixture.photos[0]])
        sqlite3_close(db)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".migration-snapshot"))
    }
}
