import XCTest
import SQLite3
import CryptoKit
@testable import AFITCCore

final class FaceAnalysisRestoreTests: XCTestCase {
    private let manifest = ModelManifest.openCVSFace2021December
    private let detector = "opencv-yunet-2023mar"

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AFITCTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testExportDropsDerivedVectorsAndZeroRawMarkerBytesRemain() async throws {
        let dir = try temporaryDirectory()
        let dbDir = dir.appendingPathComponent("db")
        let cacheDir = dir.appendingPathComponent("cache")

        let repo = try CatalogRepository(directory: dbDir, cacheDirectory: cacheDir)
        _ = try await repo.acquireSource(identity: "source-a", confirmed: true)

        let geometry = FaceGeometry(rectangle: [0.1, 0.1, 0.2, 0.2], landmarks: [])
        let photo = PhotoIdentity(relativePath: "export-test.jpg",
                                  analysis: FaceAnalysisState(status: .successful, detectorVersion: detector, faces: [geometry]),
                                  contentHash: String(repeating: "e", count: 64))
        try await repo.save(photo, progress: ScanProgress())

        let faceKey = FaceKey(photo: photo, face: geometry)
        _ = try await repo.applyDecision(.name(face: faceKey, displayName: "PreservedHumanName"))

        var markerFloats = [Float](repeating: 0, count: 128)
        for i in 0..<128 { markerFloats[i] = Float(1000 + i) * 0.001 }
        let norm = sqrt(markerFloats.reduce(0) { $0 + $1 * $1 })
        for i in 0..<128 { markerFloats[i] /= norm }
        let vector = EmbeddingVector(modelIdentifier: manifest.identifier, values: markerFloats)

        let fence = try await repo.captureFaceAnalysisPersistenceFence(photo: photo, sourceIdentity: "source-a")
        let persistResult = try await repo.saveFixtureFaceBatch(vectors: [(key: faceKey, vector: vector)],
                                                                    fence: fence, manifest: manifest, reason: nil)
        XCTAssertEqual(persistResult, .inserted(1))

        let otherGeometry = FaceGeometry(rectangle: [0.3, 0.3, 0.2, 0.2], landmarks: [])
        let otherKey = FaceKey(photoID: photo.id, contentVersion: 1, detectorVersion: detector, faceID: UUID())
        try await repo.suppressFace(key: otherKey, photoID: photo.id, contentVersion: 1,
                                    contentHash: photo.contentHash!, sourceBinding: "source-a")
        try await repo.recordGroupSeparation(faceKeyA: faceKey, faceKeyB: otherKey)

        let markerBytes = try FaceAnalysisEncoding.encodeVector(markerFloats)
        XCTAssertEqual(markerBytes.count, 512)

        let liveData = try Data(contentsOf: dbDir.appendingPathComponent("catalog.sqlite"))
        XCTAssertNotNil(liveData.range(of: markerBytes), "Live database must contain the raw marker bytes before export")

        let backup = try await repo.prepareBackup()
        let exportedFile = backup.directory.appendingPathComponent("catalog.sqlite")
        let exportedData = try Data(contentsOf: exportedFile)

        XCTAssertNil(exportedData.range(of: markerBytes), "Exported SQLite file must contain zero raw marker bytes in any page")

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(exportedFile.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let db = try XCTUnwrap(handle); defer { sqlite3_close(db) }

        let vectorCount = try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM face_vectors")
        XCTAssertEqual(vectorCount, 0, "Derived face_vectors table must be empty in exported backup")

        let recordCount = try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM photo_analysis_records")
        XCTAssertEqual(recordCount, 0, "Derived photo_analysis_records table must be empty in exported backup")

        let peopleNames: [String] = try PeopleSQL.rows(db, "SELECT payload FROM people").map { (p: PersonRecord) in p.displayName }
        XCTAssertTrue(peopleNames.contains("PreservedHumanName"), "Human names must be preserved in exported backup")

        let suppCount = try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM face_suppression")
        XCTAssertEqual(suppCount, 1, "Suppression metadata must be preserved in exported backup")

        let sepCount = try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM group_separations")
        XCTAssertEqual(sepCount, 1, "Group separation metadata must be preserved in exported backup")
    }

    func testDisconnectedRestorePreservesHumanDecisionsAndReportsRecomputationNeeded() async throws {
        let dir = try temporaryDirectory()
        let liveDir = dir.appendingPathComponent("live")
        let cacheDir = dir.appendingPathComponent("cache")
        let stagingDir = dir.appendingPathComponent("staging")

        let repo = try CatalogRepository(directory: liveDir, cacheDirectory: cacheDir)
        _ = try await repo.acquireSource(identity: "source-a", confirmed: true)

        let geometry = FaceGeometry(rectangle: [0.1, 0.1, 0.2, 0.2], landmarks: [])
        let photo = PhotoIdentity(relativePath: "disconnected.jpg",
                                  analysis: FaceAnalysisState(status: .successful, detectorVersion: detector, faces: [geometry]),
                                  contentHash: String(repeating: "d", count: 64))
        try await repo.save(photo, progress: ScanProgress())

        let faceKey = FaceKey(photo: photo, face: geometry)
        _ = try await repo.applyDecision(.name(face: faceKey, displayName: "Bob"))

        let fence = try await repo.captureFaceAnalysisPersistenceFence(photo: photo, sourceIdentity: "source-a")
        var floats = [Float](repeating: 0.1, count: 128)
        floats[0] = 1.0
        let vector = EmbeddingVector(modelIdentifier: manifest.identifier, values: floats)
        _ = try await repo.saveFixtureFaceBatch(vectors: [(key: faceKey, vector: vector)],
                                                    fence: fence, manifest: manifest, reason: nil)

        let backup = try await repo.prepareBackup()
        let validator = try RestoreValidator(stagingDirectory: stagingDir)
        let validated = try await validator.validate(package: backup.directory)

        let restoreRepo = try await CatalogRestoreRepository.beginRestore(catalog: repo)
        let restored = try await restoreRepo.restore(validated)

        let vectors = try await restored.faceVectorRows()
        XCTAssertTrue(vectors.isEmpty, "Restored catalog must have empty derived vectors")

        let needsRecompute = try await restored.recomputationNeeded()
        XCTAssertTrue(needsRecompute, "Disconnected restore must report recomputation-needed state")

        let people = try await restored.peopleSnapshot().people
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people[0].person.displayName, "Bob", "Human decisions and names must be preserved")

        let query = try PeopleQuery(mode: .together, selectedPersonIDs: [people[0].id])
        let search = try await SearchRepository(catalog: restored).snapshot(query: query)
        XCTAssertEqual(search.results.count, 1, "Confirmed search must find the photo after disconnected restore")
    }

    func testV3ToV4RestoreRoundTrip() async throws {
        let dir = try temporaryDirectory()
        let packageDir = dir.appendingPathComponent("v3package")
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)
        let catalogFile = packageDir.appendingPathComponent("catalog.sqlite")

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(catalogFile.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        try CatalogSchema.migrate(db, target: 3)

        let personID = UUID()
        let person = PersonRecord(id: personID, displayName: "HistoricalV3Person")
        try PeopleSQL.writePerson(db, person)
        try CatalogSchema.execute(db, "PRAGMA user_version=3;")
        let (revision, counts) = try BackupFiles.summary(db)
        sqlite3_close(db)


        let catalogBytes = try Data(contentsOf: catalogFile).count
        let catalogSHA = SHA256.hash(data: try Data(contentsOf: catalogFile)).map { String(format: "%02x", $0) }.joined()
        let v3Manifest = BackupManifest(formatVersion: 1, schemaVersion: 3, createdAt: Date(),
                                        revision: revision, counts: counts, catalogBytes: catalogBytes,
                                        catalogSHA256: catalogSHA)
        let manifestData = try JSONEncoder().encode(v3Manifest)
        try manifestData.write(to: packageDir.appendingPathComponent("manifest.json"))

        let stagingDir = dir.appendingPathComponent("staging")
        let validator = try RestoreValidator(stagingDirectory: stagingDir)
        let validated = try await validator.validate(package: packageDir)
        XCTAssertEqual(validated.manifest.schemaVersion, 3)

        let liveDir = dir.appendingPathComponent("live")
        let cacheDir = dir.appendingPathComponent("cache")
        let liveRepo = try CatalogRepository(directory: liveDir, cacheDirectory: cacheDir)
        _ = try await liveRepo.acquireSource(identity: "source-init", confirmed: true)

        let restoreRepo = try await CatalogRestoreRepository.beginRestore(catalog: liveRepo)
        let restored = try await restoreRepo.restore(validated)

        let people = try await restored.peopleSnapshot().people
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people[0].person.displayName, "HistoricalV3Person")

        var restoredHandle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(liveDir.appendingPathComponent("catalog.sqlite").path, &restoredHandle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let restoredDB = try XCTUnwrap(restoredHandle); defer { sqlite3_close(restoredDB) }
        XCTAssertEqual(try CatalogSchema.version(restoredDB), 4, "Staged v3 catalog must be migrated to schema 4 during restore")
    }

    func testInterruptedV3RestoreRecovery() async throws {
        let dir = try temporaryDirectory()
        let stageName = "restore-" + UUID().uuidString
        let stageDir = dir.appendingPathComponent(stageName)
        let oldDir = stageDir.appendingPathComponent("old")
        let newDir = stageDir.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)

        let v3File = oldDir.appendingPathComponent("catalog.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(v3File.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        try CatalogSchema.migrate(db, target: 3)
        let person = PersonRecord(id: UUID(), displayName: "InterruptedPerson")
        try PeopleSQL.writePerson(db, person)
        try CatalogSchema.execute(db, "PRAGMA user_version=3;")
        let (revision, counts) = try BackupFiles.summary(db)
        sqlite3_close(db)

        let oldBytes = try Data(contentsOf: v3File).count
        let oldSHA = SHA256.hash(data: try Data(contentsOf: v3File)).map { String(format: "%02x", $0) }.joined()

        let oldManifest = BackupManifest(formatVersion: 1, schemaVersion: 3, createdAt: Date(),
                                         revision: revision, counts: counts, catalogBytes: oldBytes,
                                         catalogSHA256: oldSHA)
        let oldManifestData = try JSONEncoder().encode(oldManifest)
        try oldManifestData.write(to: oldDir.appendingPathComponent("manifest.json"))

        let oldRef = RestoreSnapshotReference(path: stageName + "/old", catalogBytes: oldBytes, catalogSHA256: oldSHA,
                                              manifestBytes: oldManifestData.count,
                                              manifestSHA256: SHA256.hash(data: oldManifestData).map { String(format: "%02x", $0) }.joined(),
                                              schemaVersion: 3)

        try FileManager.default.copyItem(at: v3File, to: newDir.appendingPathComponent("catalog.sqlite"))
        try oldManifestData.write(to: newDir.appendingPathComponent("manifest.json"))
        let newRef = RestoreSnapshotReference(path: stageName + "/new", catalogBytes: oldBytes, catalogSHA256: oldSHA,
                                             manifestBytes: oldManifestData.count, manifestSHA256: oldRef.manifestSHA256,
                                             schemaVersion: 3)
        let marker = RestoreMarker(version: 1, transaction: UUID(uuidString: String(stageName.dropFirst("restore-".count)))!,
                                   state: .prepared, old: oldRef, new: newRef)
        XCTAssertNoThrow(try marker.checked(), "RestoreMarker.checked must accept schemaVersion: 3")

        let liveFile = dir.appendingPathComponent("catalog.sqlite")
        try FileManager.default.copyItem(at: v3File, to: liveFile)

        let cacheDir = dir.appendingPathComponent("cache")
        try marker.encoded().write(to: dir.appendingPathComponent("restore-marker.json"))
        let recovery = try CatalogRestoreRepository(directory: dir, cacheDirectory: cacheDir, requireExisting: true)
        let repo = try await recovery.open()
        let snapshot = try await repo.peopleSnapshot()
        XCTAssertEqual(snapshot.people.first?.person.displayName, "InterruptedPerson")

        var liveHandle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(liveFile.path, &liveHandle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let liveDB = try XCTUnwrap(liveHandle); defer { sqlite3_close(liveDB) }
        XCTAssertEqual(try CatalogSchema.version(liveDB), 4, "requireExisting must upgrade v3 to v4")
    }
}
