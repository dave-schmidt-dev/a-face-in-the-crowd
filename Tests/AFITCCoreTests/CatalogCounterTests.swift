import XCTest
import SQLite3
import CoreGraphics
import CryptoKit
@testable import AFITCCore

final class CatalogCounterTests: XCTestCase {
    private func expectCounter(_ expected: CounterError, _ body: () async throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected counter rejection", file: file, line: line) }
        catch { XCTAssertEqual(error as? CounterError, expected, file: file, line: line) }
    }
    private func mutate(_ catalog: CatalogRepository, _ body: (OpaquePointer) throws -> Void) async throws {
        try await catalog.peopleRead(body)
    }
    private func state(_ catalog: CatalogRepository) async throws -> Data {
        try await catalog.peopleRead { db in
            var values: [String: [Data]] = [:]
            for table in ["photos", "people", "current_faces", "manual_faces", "pair_negatives", "deferrals", "decisions", "scan_checkpoint", "source_binding"] {
                let statement = try PeopleSQL.statement(db, "SELECT * FROM \(table) ORDER BY rowid")
                defer { sqlite3_finalize(statement) }
                var rows: [Data] = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    var row = Data()
                    for column in 0..<sqlite3_column_count(statement) {
                        let count = Int(sqlite3_column_bytes(statement, column))
                        row.append(Data("\(sqlite3_column_type(statement, column)):\(count):".utf8))
                        if let bytes = sqlite3_column_blob(statement, column) { row.append(Data(bytes: bytes, count: count)) }
                    }
                    rows.append(row)
                }
                values[table] = rows
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            return try encoder.encode(values)
        }
    }
    private func revision(_ catalog: CatalogRepository) async throws -> Int {
        try await catalog.peopleRead { try CatalogCounters.read($0, .revision) }
    }
    private func setPerson(_ catalog: CatalogRepository, id: UUID, epoch: Int) async throws {
        try await mutate(catalog) { db in
            var person = try PeopleSQL.person(db, id); person.exemplarRevision = epoch
            try PeopleSQL.writePerson(db, person)
        }
    }
    func testLeaseBeyondInt32AndMaximumAcquisitionRollback() async throws {
        let f = try await SearchFixture.make(self, personCount: 0)
        try await mutate(f.catalog) { try CatalogSchema.execute($0, "UPDATE scan_lease SET generation=2147483647") }
        let lease = try await f.catalog.claimLease()
        XCTAssertEqual(lease, Int(Int32.max) + 1)
        let second = try CatalogRepository(directory: f.root.appendingPathComponent("db"), cacheDirectory: f.root.appendingPathComponent("cache"))
        try await second.requireLease(lease)
        let bound = try await f.catalog.acquireSource(identity: "fictional-root", confirmed: true)
        XCTAssertEqual(bound, lease + 1)
        try await f.catalog.save(PhotoIdentity(relativePath: "a.jpg"), progress: ScanProgress(), lease: bound)
        try await f.catalog.storeGrant(Data([1, 2]), lease: bound)
        let cache = try await f.catalog.storePreview(Data([3, 4]), id: UUID(), lease: bound)
        try await mutate(f.catalog) { try CatalogCounters.set($0, .lease, Int.max - 1) }
        let maxLease = try await f.catalog.acquireSource(identity: "fictional-root", confirmed: true)
        XCTAssertEqual(maxLease, Int.max)
        let before = try await state(f.catalog), rev = try await revision(f.catalog)
        await expectCounter(.exhausted) { _ = try await f.catalog.acquireSource(identity: "other-root", confirmed: true) }
        await expectCounter(.exhausted) { _ = try await f.catalog.claimLease() }
        let after = try await state(f.catalog), afterRevision = try await revision(f.catalog)
        XCTAssertEqual(before, after); XCTAssertEqual(rev, afterRevision)
        let grant = try await f.catalog.loadGrant(); XCTAssertEqual(grant, Data([1, 2]))
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("cache").appendingPathComponent(cache)), Data([3, 4]))
        try await f.catalog.peopleRead { db in
            let s = try PeopleSQL.statement(db, "SELECT typeof(generation) FROM scan_lease"); defer { sqlite3_finalize(s) }
            XCTAssertEqual(sqlite3_step(s), SQLITE_ROW)
            XCTAssertEqual(String(cString: sqlite3_column_text(s, 0)), "integer")
        }
    }
    func testNonIntegerAndNegativeSingletonsRejectWithoutCoercion() async throws {
        let f = try await SearchFixture.make(self, personCount: 0)
        for stored in ["1.5", "'not-an-integer'", "-1"] {
            try await mutate(f.catalog) { try CatalogSchema.execute($0, "UPDATE scan_lease SET generation=\(stored)") }
            await expectCounter(.invalidStoredValue) { _ = try await f.catalog.claimLease() }
            await expectCounter(.invalidStoredValue) { try await f.catalog.requireLease(1) }
            try await mutate(f.catalog) { try CatalogSchema.execute($0, "UPDATE catalog_revision SET revision=\(stored)") }
            let before = try await state(f.catalog)
            await expectCounter(.invalidStoredValue) { _ = try await f.catalog.applyDecision(.rename(personID: UUID(), displayName: "Fictional")) }
            let after = try await state(f.catalog); XCTAssertEqual(before, after)
        }
    }
    func testFinalRevisionCommitsExactLedgerThenAllManualActionsRollback() async throws {
        let f = try await SearchFixture.make(self, personCount: 2)
        let photo = try await f.photo("fictional.jpg", [nil])
        let key = FaceKey(photo: photo, face: photo.analysis.faces[0])
        try await mutate(f.catalog) { try CatalogCounters.set($0, .revision, Int.max - 1) }
        let action = try await f.catalog.applyDecision(.confirm(face: key, personID: f.people[0]))
        let rev = try await revision(f.catalog); XCTAssertEqual(rev, Int.max)
        try await f.catalog.peopleRead { db in
            let records: [DecisionRecord] = try PeopleSQL.rows(db, "SELECT payload FROM decisions WHERE id=?", strings: [action.uuidString])
            XCTAssertEqual(records.first?.revision, Int.max)
        }
        let frozen = try await f.query(.any, [f.people[0]])
        let before = try await state(f.catalog)
        for decision: ManualDecision in [.name(face: key, displayName: "Extra"), .rename(personID: f.people[0], displayName: "Changed"),
            .reject(face: key, personID: f.people[0]), .unsure(face: key, personID: nil), .unassign(face: key),
            .confirm(face: key, personID: f.people[1]), .notPerson(face: key)] {
            await expectCounter(.exhausted) { _ = try await f.catalog.applyDecision(decision) }
        }
        await expectCounter(.exhausted) { try await f.catalog.undoDecision(action) }
        let replacement = PhotoIdentity(id: photo.id, relativePath: photo.relativePath, contentVersion: 2,
            analysis: FaceAnalysisState(status: .pending, contentVersion: 2))
        await expectCounter(.exhausted) { try await f.catalog.save(replacement, progress: ScanProgress()) }
        let lease = try await f.catalog.claimLease()
        await expectCounter(.exhausted) { _ = try await f.catalog.markMissing(except: [], progress: ScanProgress(), lease: lease) }
        let preview = try await f.catalog.previewMerge(source: f.people[0], survivor: f.people[1])
        await expectCounter(.exhausted) { _ = try await f.catalog.mergePeople(preview, resolutions: []) }
        let after = try await state(f.catalog); XCTAssertEqual(before, after)
        let fresh = try await f.query(.any, [f.people[0]])
        XCTAssertEqual(frozen.results.map { $0.photo.id }, fresh.results.map { $0.photo.id })
        XCTAssertEqual(frozen.revision, fresh.revision)
    }
    func testExemplarExhaustionRollsBackManualMergeAndPhotoInvalidation() async throws {
        let f = try await SearchFixture.make(self, personCount: 2)
        let photo = try await f.photo("fictional.jpg", [nil, nil])
        let first = FaceKey(photo: photo, face: photo.analysis.faces[0]), second = FaceKey(photo: photo, face: photo.analysis.faces[1])
        _ = try await f.catalog.applyDecision(.confirm(face: first, personID: f.people[0]))
        _ = try await f.catalog.applyDecision(.confirm(face: second, personID: f.people[1]))
        try await setPerson(f.catalog, id: f.people[1], epoch: Int.max)
        let before = try await state(f.catalog), rev = try await revision(f.catalog)
        for decision: ManualDecision in [.unassign(face: second), .confirm(face: second, personID: f.people[0]), .confirm(face: first, personID: f.people[1])] {
            await expectCounter(.exhausted) { _ = try await f.catalog.applyDecision(decision) }
        }
        let preview = try await f.catalog.previewMerge(source: f.people[0], survivor: f.people[1])
        await expectCounter(.exhausted) { _ = try await f.catalog.mergePeople(preview, resolutions: []) }
        let replacement = PhotoIdentity(id: photo.id, relativePath: photo.relativePath, dateAdded: photo.dateAdded,
            contentVersion: 2, analysis: FaceAnalysisState(status: .pending, contentVersion: 2))
        await expectCounter(.exhausted) { try await f.catalog.save(replacement, progress: ScanProgress()) }
        let lease = try await f.catalog.claimLease()
        await expectCounter(.exhausted) { _ = try await f.catalog.markMissing(except: [], progress: ScanProgress(), lease: lease) }
        let after = try await state(f.catalog), afterRev = try await revision(f.catalog)
        XCTAssertEqual(before, after); XCTAssertEqual(rev, afterRev)
    }
    func testImmutableHistoricalMaximumUndoRejectsWithoutLedgerRewrite() async throws {
        let f = try await SearchFixture.make(self, personCount: 1)
        let id = try await f.catalog.applyDecision(.rename(personID: f.people[0], displayName: "New fictional name"))
        try await mutate(f.catalog) { db in
            let records: [DecisionRecord] = try PeopleSQL.rows(db, "SELECT payload FROM decisions WHERE id=?", strings: [id.uuidString])
            let record = try XCTUnwrap(records.first)
            var before = record.before; before.people[0].exemplarRevision = Int.max
            let historical = DecisionRecord(id: record.id, kind: record.kind, before: before, after: record.after,
                createdPersonID: record.createdPersonID, date: record.date, revision: record.revision, undoOf: nil)
            try PeopleSQL.run(db, "UPDATE decisions SET payload=?2 WHERE id=?1", strings: [id.uuidString], data: JSONEncoder().encode(historical))
        }
        let before = try await state(f.catalog), rev = try await revision(f.catalog)
        await expectCounter(.exhausted) { try await f.catalog.undoDecision(id) }
        let after = try await state(f.catalog), afterRev = try await revision(f.catalog)
        XCTAssertEqual(before, after); XCTAssertEqual(rev, afterRev)
        // Current maximum also rejects; the preceding lawful maximum remains exactly unchanged.
        let g = try await SearchFixture.make(self, personCount: 1)
        let rename = try await g.catalog.applyDecision(.rename(personID: g.people[0], displayName: "Next"))
        try await setPerson(g.catalog, id: g.people[0], epoch: Int.max - 1)
        try await g.catalog.undoDecision(rename)
        let person = try await g.catalog.peopleRead { try PeopleSQL.person($0, g.people[0]) }
        XCTAssertEqual(person.exemplarRevision, Int.max)
        let next = try await g.catalog.applyDecision(.rename(personID: g.people[0], displayName: "Final"))
        await expectCounter(.exhausted) { try await g.catalog.undoDecision(next) }
    }
    private func jpeg(_ shade: CGFloat) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: shade, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        return try JPEGPreviewDecoder.jpeg(XCTUnwrap(context.makeImage()))
    }
    actor ReadFailure: PhotoSource {
        let error: ScanError?
        var yielded = false
        init(_ error: ScanError?) { self.error = error }
        func open() { yielded = false }
        func identity() -> String? { "capture-date-synthetic" }
        func next() -> SourceEntry? { guard !yielded else { return nil }; yielded = true; return SourceEntry(relativePath: "fictional.jpg") }
        func read(_ entry: SourceEntry) throws -> Data { if let error { throw error }; throw NSError(domain: "SyntheticRead", code: 1) }
        func close() {}
    }
    func testMaximumContentVersionReuseAndAllInvalidationErrorsPreserveAcceptedPhoto() async throws {
        let f = try await SearchFixture.make(self, personCount: 0), bytes = try jpeg(0.25)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        var photo = PhotoIdentity(relativePath: "fictional.jpg", contentVersion: Int.max,
            analysis: FaceAnalysisState(status: .successful, contentVersion: Int.max))
        photo.contentHash = hash; photo.metadata = SourceMetadata(revision: "trusted")
        photo.previewPath = try await f.catalog.storePreview(bytes, id: photo.id)
        try await f.catalog.save(photo, progress: ScanProgress())
        let detector = CaptureDateTests.Detector()
        let trusted = CaptureDateTests.Source(Data([0]), revision: "trusted")
        let a = await ScanCoordinator(repository: f.catalog).scan(source: trusted, detector: detector, confirmedSource: true) { _, _ in }
        XCTAssertEqual(a.phase, .completed); let reads = await trusted.readCount(); XCTAssertEqual(reads, 0)
        let b = await ScanCoordinator(repository: f.catalog).scan(source: CaptureDateTests.Source(bytes), detector: detector) { _, _ in }
        XCTAssertEqual(b.phase, .completed)
        let stablePhotos = try await f.catalog.photos()
        let stable = try XCTUnwrap(stablePhotos.first)
        let cacheBefore = try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("cache").path).sorted()
        let sources: [any PhotoSource] = [CaptureDateTests.Source(try jpeg(0.75)), ReadFailure(.malformed), ReadFailure(.oversized), ReadFailure(nil)]
        for source in sources {
            let result = await ScanCoordinator(repository: f.catalog).scan(source: source, detector: detector) { _, _ in }
            XCTAssertEqual(result.phase, .failed); XCTAssertEqual(result.processed, 0); XCTAssertEqual(result.skipped, 0); XCTAssertEqual(result.failed, 0)
            XCTAssertEqual(result.message, "Catalog limit reached. Accepted photos remain in the catalog.")
            let storedPhotos = try await f.catalog.photos()
            let stored = try XCTUnwrap(storedPhotos.first)
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            XCTAssertEqual(try encoder.encode(stored), try encoder.encode(stable))
        }
        let calls = await detector.count(); XCTAssertEqual(calls, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("cache").path).sorted(), cacheBefore)
    }
}
