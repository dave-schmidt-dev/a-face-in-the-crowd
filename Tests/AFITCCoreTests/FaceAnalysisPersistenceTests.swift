import XCTest
import SQLite3
@testable import AFITCCore

final class FaceAnalysisPersistenceTests: XCTestCase {
    private let manifest = ModelManifest.openCVSFace2021December
    private let detector = "opencv-yunet-2023mar"

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AFITCTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeVector(seed: Float = 0.1) -> EmbeddingVector {
        var values = [Float](repeating: seed, count: 128)
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        for i in 0..<values.count { values[i] /= norm }
        return EmbeddingVector(modelIdentifier: manifest.identifier, values: values)
    }

    func testReopenPreservesFaceVectorsAndRecords() async throws {
        let dir = try temporaryDirectory()
        let dbDir = dir.appendingPathComponent("db")
        let cacheDir = dir.appendingPathComponent("cache")

        let photoID = UUID()
        let faceID = UUID()
        let geometry = FaceGeometry(rectangle: [0.1, 0.1, 0.2, 0.2], landmarks: [])
        let photo = PhotoIdentity(id: photoID, relativePath: "a.jpg",
                                  analysis: FaceAnalysisState(status: .successful, detectorVersion: detector, faces: [geometry]),
                                  contentHash: String(repeating: "1", count: 64))

        var repo: CatalogRepository? = try CatalogRepository(directory: dbDir, cacheDirectory: cacheDir)
        _ = try await repo!.acquireSource(identity: "source-a", confirmed: true)
        try await repo!.save(photo, progress: ScanProgress())

        let fence = try await repo!.captureFaceAnalysisPersistenceFence(photo: photo, sourceIdentity: "source-a")
        let faceKey = FaceKey(photo: photo, face: geometry)
        let vector = makeVector(seed: 0.2)

        let result = try await repo!.saveFixtureFaceBatch(vectors: [(key: faceKey, vector: vector)],
                                                             fence: fence, manifest: manifest, reason: nil)
        XCTAssertEqual(result, .inserted(1))

        let vectorsBefore = try await repo!.faceVectorRows()
        XCTAssertEqual(vectorsBefore.count, 1)
        XCTAssertEqual(vectorsBefore[0].faceKey, faceKey)
        XCTAssertEqual(vectorsBefore[0].photoID, photoID)
        XCTAssertEqual(vectorsBefore[0].contentVersion, 1)
        XCTAssertEqual(vectorsBefore[0].contentHash, photo.contentHash)
        XCTAssertEqual(vectorsBefore[0].firstAnalysisSequence, 1)
        XCTAssertEqual(vectorsBefore[0].vector.count, 128)

        let statusBefore = try await repo!.photoAnalysisStatus(photoID: photoID, contentVersion: 1,
                                                               contentHash: photo.contentHash!, manifest: manifest)
        XCTAssertEqual(statusBefore, .completed)
        let observed58 = try await repo!.satisfiesAnalysisReuse(photo: photo, manifest: manifest)
        XCTAssertTrue(observed58)

        repo = nil

        let reopened = try CatalogRepository(directory: dbDir, cacheDirectory: cacheDir)
        let vectorsAfter = try await reopened.faceVectorRows()
        XCTAssertEqual(vectorsAfter.count, 1)
        XCTAssertEqual(vectorsAfter[0].faceKey, faceKey)
        XCTAssertEqual(vectorsAfter[0].vector, vectorsBefore[0].vector)
        XCTAssertEqual(vectorsAfter[0].firstAnalysisSequence, 1)

        let statusAfter = try await reopened.photoAnalysisStatus(photoID: photoID, contentVersion: 1,
                                                                contentHash: photo.contentHash!, manifest: manifest)
        XCTAssertEqual(statusAfter, .completed)
        let observed72 = try await reopened.satisfiesAnalysisReuse(photo: photo, manifest: manifest)
        XCTAssertTrue(observed72)
    }

    func testStaleBatchRejectionOnContentVersionAdvance() async throws {
        let dir = try temporaryDirectory()
        let repo = try CatalogRepository(directory: dir.appendingPathComponent("db"), cacheDirectory: dir.appendingPathComponent("cache"))
        _ = try await repo.acquireSource(identity: "source-a", confirmed: true)

        let photoID = UUID()
        let geometry = FaceGeometry(rectangle: [0.1, 0.1, 0.2, 0.2], landmarks: [])
        let photoV1 = PhotoIdentity(id: photoID, relativePath: "a.jpg", contentVersion: 1,
                                    analysis: FaceAnalysisState(status: .successful, detectorVersion: detector, contentVersion: 1, faces: [geometry]),
                                    contentHash: String(repeating: "1", count: 64))
        try await repo.save(photoV1, progress: ScanProgress())

        let fenceV1 = try await repo.captureFaceAnalysisPersistenceFence(photo: photoV1, sourceIdentity: "source-a")

        let photoV2 = PhotoIdentity(id: photoID, relativePath: "a.jpg", contentVersion: 2,
                                    analysis: FaceAnalysisState(status: .successful, detectorVersion: detector, contentVersion: 2, faces: [geometry]),
                                    contentHash: String(repeating: "2", count: 64))
        try await repo.save(photoV2, progress: ScanProgress())

        let faceKey = FaceKey(photo: photoV1, face: geometry)
        let vector = makeVector(seed: 0.3)

        let rejected = try await repo.saveFixtureFaceBatch(vectors: [(key: faceKey, vector: vector)],
                                                          fence: fenceV1, manifest: manifest, reason: nil)
        XCTAssertEqual(rejected, .stale)
        let saved = try await repo.faceVectorRows()
        XCTAssertTrue(saved.isEmpty)
    }

    func testStaleGenerationsCleanedOnNewWrite() async throws {
        let dir = try temporaryDirectory()
        let repo = try CatalogRepository(directory: dir.appendingPathComponent("db"), cacheDirectory: dir.appendingPathComponent("cache"))
        _ = try await repo.acquireSource(identity: "source-a", confirmed: true)

        let photoID = UUID()
        let geometry = FaceGeometry(rectangle: [0.1, 0.1, 0.2, 0.2], landmarks: [])
        let photoV1 = PhotoIdentity(id: photoID, relativePath: "a.jpg", contentVersion: 1,
                                    analysis: FaceAnalysisState(status: .successful, detectorVersion: detector, contentVersion: 1, faces: [geometry]),
                                    contentHash: String(repeating: "1", count: 64))
        try await repo.save(photoV1, progress: ScanProgress())
        let fenceV1 = try await repo.captureFaceAnalysisPersistenceFence(photo: photoV1, sourceIdentity: "source-a")
        let keyV1 = FaceKey(photo: photoV1, face: geometry)
        _ = try await repo.saveFixtureFaceBatch(vectors: [(key: keyV1, vector: makeVector(seed: 0.1))],
                                                    fence: fenceV1, manifest: manifest, reason: nil)

        let photoV2 = PhotoIdentity(id: photoID, relativePath: "a.jpg", contentVersion: 2,
                                    analysis: FaceAnalysisState(status: .successful, detectorVersion: detector, contentVersion: 2, faces: [geometry]),
                                    contentHash: String(repeating: "2", count: 64))
        try await repo.save(photoV2, progress: ScanProgress())
        let fenceV2 = try await repo.captureFaceAnalysisPersistenceFence(photo: photoV2, sourceIdentity: "source-a")
        let keyV2 = FaceKey(photo: photoV2, face: geometry)
        _ = try await repo.saveFixtureFaceBatch(vectors: [(key: keyV2, vector: makeVector(seed: 0.2))],
                                                    fence: fenceV2, manifest: manifest, reason: nil, maxCapacity: 1)

        let all = try await repo.faceVectorRows()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].contentVersion, 2)
        XCTAssertEqual(all[0].faceKey, keyV2)
    }

    func testEmptyAttemptsAndStatusTracking() async throws {
        let dir = try temporaryDirectory()
        let repo = try CatalogRepository(directory: dir.appendingPathComponent("db"), cacheDirectory: dir.appendingPathComponent("cache"))
        _ = try await repo.acquireSource(identity: "source-a", confirmed: true)

        let photo = PhotoIdentity(relativePath: "empty.jpg",
                                  analysis: FaceAnalysisState(status: .successful, detectorVersion: detector, faces: []),
                                  contentHash: String(repeating: "3", count: 64))
        try await repo.save(photo, progress: ScanProgress())
        let fence = try await repo.captureFaceAnalysisPersistenceFence(photo: photo, sourceIdentity: "source-a")

        _ = try await repo.saveFaceAnalysisBatch(fence: fence, verifiedContentHash: fence.contentHash, vectors: [], manifest: manifest, status: .emptySuccess)
        let status = try await repo.photoAnalysisStatus(photoID: photo.id, contentVersion: photo.contentVersion,
                                                        contentHash: photo.contentHash!, manifest: manifest)
        XCTAssertEqual(status, .emptySuccess)
        let observed152 = try await repo.satisfiesAnalysisReuse(photo: photo, manifest: manifest)
        XCTAssertTrue(observed152)

        let failedPhoto = PhotoIdentity(relativePath: "failed.jpg",
                                        analysis: FaceAnalysisState(status: .successful, detectorVersion: detector, faces: []),
                                        contentHash: String(repeating: "4", count: 64))
        try await repo.save(failedPhoto, progress: ScanProgress())
        let failFence = try await repo.captureFaceAnalysisPersistenceFence(photo: failedPhoto, sourceIdentity: "source-a")
        _ = try await repo.saveFaceAnalysisBatch(fence: failFence, verifiedContentHash: failFence.contentHash, vectors: [], manifest: manifest, status: .failed, reason: "decode error")

        let failStatus = try await repo.photoAnalysisStatus(photoID: failedPhoto.id, contentVersion: failedPhoto.contentVersion,
                                                           contentHash: failedPhoto.contentHash!, manifest: manifest)
        XCTAssertEqual(failStatus, .failed)
        let observed164 = try await repo.satisfiesAnalysisReuse(photo: failedPhoto, manifest: manifest)
        XCTAssertFalse(observed164)
    }

    func testFaceCapacityLimit() async throws {
        let dir = try temporaryDirectory()
        let repo = try CatalogRepository(directory: dir.appendingPathComponent("db"), cacheDirectory: dir.appendingPathComponent("cache"))
        _ = try await repo.acquireSource(identity: "source-a", confirmed: true)

        let g1 = FaceGeometry(rectangle: [0.1, 0.1, 0.2, 0.2], landmarks: [])
        let g2 = FaceGeometry(rectangle: [0.3, 0.3, 0.2, 0.2], landmarks: [])
        let photo = PhotoIdentity(relativePath: "faces.jpg",
                                  analysis: FaceAnalysisState(status: .successful, detectorVersion: detector, faces: [g1, g2]),
                                  contentHash: String(repeating: "5", count: 64))
        try await repo.save(photo, progress: ScanProgress())
        let fence = try await repo.captureFaceAnalysisPersistenceFence(photo: photo, sourceIdentity: "source-a")

        let k1 = FaceKey(photo: photo, face: g1)
        let k2 = FaceKey(photo: photo, face: g2)

        let result = try await repo.saveFixtureFaceBatch(
            vectors: [(key: k1, vector: makeVector(seed: 0.1)), (key: k2, vector: makeVector(seed: 0.2))],
            fence: fence, manifest: manifest, reason: nil, maxCapacity: 1
        )
        XCTAssertEqual(result, .full)
        let observed188 = try await repo.faceVectorRows().isEmpty
        XCTAssertTrue(observed188)
    }

    func testMigrationFromV3ToV4() throws {
        let dir = try temporaryDirectory()
        let file = dir.appendingPathComponent("v3.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle); defer { sqlite3_close(db) }

        try CatalogSchema.migrate(db, target: 3)
        XCTAssertEqual(try CatalogSchema.version(db), 3)

        try CatalogSchema.migrate(db, target: 4)
        XCTAssertEqual(try CatalogSchema.version(db), 4)

        let vectorCount = try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM face_vectors")
        XCTAssertEqual(vectorCount, 0)
        let recordCount = try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM photo_analysis_records")
        XCTAssertEqual(recordCount, 0)
        let seq = try FaceAnalysisSQL.nextSequence(db)
        XCTAssertEqual(seq, 1)
    }

    func testFenceIndependenceFromManualNaming() async throws {
        let dir = try temporaryDirectory()
        let repo = try CatalogRepository(directory: dir.appendingPathComponent("db"), cacheDirectory: dir.appendingPathComponent("cache"))
        _ = try await repo.acquireSource(identity: "source-a", confirmed: true)

        let geometry = FaceGeometry(rectangle: [0.1, 0.1, 0.2, 0.2], landmarks: [])
        let photo = PhotoIdentity(relativePath: "person.jpg",
                                  analysis: FaceAnalysisState(status: .successful, detectorVersion: detector, faces: [geometry]),
                                  contentHash: String(repeating: "6", count: 64))
        try await repo.save(photo, progress: ScanProgress())

        let fence = try await repo.captureFaceAnalysisPersistenceFence(photo: photo, sourceIdentity: "source-a")
        let faceKey = FaceKey(photo: photo, face: geometry)

        _ = try await repo.applyDecision(.name(face: faceKey, displayName: "Alice"))

        try await repo.validateFaceAnalysisPersistenceFence(fence, sourceIdentity: "source-a",
                                                            verifiedContentHash: photo.contentHash!)

        let vector = makeVector(seed: 0.4)
        let result = try await repo.saveFixtureFaceBatch(vectors: [(key: faceKey, vector: vector)],
                                                             fence: fence, manifest: manifest, reason: nil)
        XCTAssertEqual(result, .inserted(1))
    }

    func testFaceSuppressionAndGroupSeparations() async throws {
        let dir = try temporaryDirectory()
        let repo = try CatalogRepository(directory: dir.appendingPathComponent("db"), cacheDirectory: dir.appendingPathComponent("cache"))
        _ = try await repo.acquireSource(identity: "source-a", confirmed: true)

        let g1 = FaceGeometry(rectangle: [0.1, 0.1, 0.2, 0.2], landmarks: [])
        let g2 = FaceGeometry(rectangle: [0.3, 0.3, 0.2, 0.2], landmarks: [])
        let photo = PhotoIdentity(relativePath: "group.jpg",
                                  analysis: FaceAnalysisState(status: .successful, detectorVersion: detector, faces: [g1, g2]),
                                  contentHash: String(repeating: "7", count: 64))
        try await repo.save(photo, progress: ScanProgress())

        let k1 = FaceKey(photo: photo, face: g1)
        let k2 = FaceKey(photo: photo, face: g2)

        let observed252 = try await repo.isFaceSuppressed(key: k1)
        XCTAssertFalse(observed252)
        try await repo.suppressFace(key: k1, photoID: photo.id, contentVersion: photo.contentVersion,
                                    contentHash: photo.contentHash!, sourceBinding: "source-a")
        let observed255 = try await repo.isFaceSuppressed(key: k1)
        XCTAssertTrue(observed255)

        let observed257 = try await repo.areGroupSeparated(faceKeyA: k1, faceKeyB: k2)
        XCTAssertFalse(observed257)
        try await repo.recordGroupSeparation(faceKeyA: k1, faceKeyB: k2)
        let observed259 = try await repo.areGroupSeparated(faceKeyA: k1, faceKeyB: k2)
        XCTAssertTrue(observed259)
        let observed260 = try await repo.areGroupSeparated(faceKeyA: k2, faceKeyB: k1)
        XCTAssertTrue(observed260)
        let observed261 = try await repo.groupSeparations(for: k1).contains(k2)
        XCTAssertTrue(observed261)

        try await repo.removeGroupSeparation(faceKeyA: k1, faceKeyB: k2)
        let observed264 = try await repo.areGroupSeparated(faceKeyA: k1, faceKeyB: k2)
        XCTAssertFalse(observed264)
    }
    func testMissingPhotoKeepsVectorsWhileOtherPhotoIsAnalyzedAndReopensReusable() async throws {
        let f = try await GroupFixture.make(self, photos: 2)
        try await f.persist([(f.keys[0], G.vector([0: 1]))])
        let before = try await f.catalog.faceVectorRows()
        var missing = f.photos[0]; missing.missing = true
        try await f.catalog.save(missing, progress: ScanProgress())
        try await f.persist([(f.keys[1], G.vector([1: 1]))])
        let preserved = try await f.catalog.faceVectorRows().filter { $0.photoID == missing.id }
        XCTAssertEqual(preserved, before)
        try await f.catalog.save(f.photos[0], progress: ScanProgress())
        let owner = try await CatalogSuspensionRepository.beginSuspension(catalog: f.catalog)
        try await owner.suspend()
        let reopened = try await owner.reopen().catalog
        let reuse = try await reopened.satisfiesAnalysisReuse(photo: f.photos[0], manifest: f.manifest)
        let rows = try await reopened.faceVectorRows().filter { $0.photoID == missing.id }
        XCTAssertTrue(reuse); XCTAssertEqual(rows, before)
    }
    func testOtherPhotoMalformedDerivedRowIsNotDecodedByPerPhotoWrite() async throws {
        let f = try await GroupFixture.make(self, photos: 2)
        try await f.persist([(f.keys[0], G.vector([0: 1]))])
        try await f.catalog.peopleTransaction { db in
            try PeopleSQL.run(db, "UPDATE face_vectors SET vector=?2 WHERE photo_id=?1", strings: [f.photos[0].id.uuidString], data: Data(repeating: 0xff, count: 512))
        }
        do { _ = try await f.catalog.faceVectorRows(); XCTFail("Malformed fixture was not actually decoded") }
        catch { }
        try await f.persist([(f.keys[1], G.vector([1: 1]))])
        let untouched = try await f.catalog.peopleRead { db in
            try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM face_vectors WHERE photo_id=? AND hex(vector)=?", strings: [f.photos[0].id.uuidString, String(repeating: "FF", count: 512)])
        }
        XCTAssertEqual(untouched, 1)
    }
    func testReuseReadKeepsRevisionAndAnalysisCommitAdvancesIt() async throws {
        let f = try await GroupFixture.make(self, photos: 1)
        try await f.persist([(f.keys[0], G.vector([0: 1]))])
        let first = try await f.catalog.peopleSnapshot().revision
        let reuse = try await f.catalog.satisfiesAnalysisReuse(photo: f.photos[0], manifest: f.manifest)
        XCTAssertTrue(reuse)
        let reused = try await f.catalog.peopleSnapshot().revision
        XCTAssertEqual(reused, first)
        try await f.persist([(f.keys[0], G.vector([1: 1]))])
        let changed = try await f.catalog.peopleSnapshot().revision
        XCTAssertGreaterThan(changed, first)
    }
    func testRecomputationBindsCompletionToPinnedPipelineAndCurrentSource() async throws {
        let f = try await GroupFixture.make(self, photos: 1)
        try await f.persist([(f.keys[0], G.vector([0: 1]))], manifest: G.variant(identifier: "old-fictional-pipeline"))
        let stalePipeline = try await f.catalog.recomputationNeeded(); XCTAssertTrue(stalePipeline)
        try await f.persist([(f.keys[0], G.vector([0: 1]))])
        let current = try await f.catalog.recomputationNeeded(); XCTAssertFalse(current)
        _ = try await f.catalog.acquireSource(identity: "new-fictional-source", confirmed: true)
        let rebound = try await f.catalog.recomputationNeeded(); XCTAssertTrue(rebound)
        let fence = try await f.catalog.captureFaceAnalysisPersistenceFence(photo: f.photos[0], sourceIdentity: "new-fictional-source")
        _ = try await f.catalog.saveFixtureFaceBatch(vectors: [(f.keys[0], EmbeddingVector(modelIdentifier: f.manifest.identifier, values: G.vector([0: 1])))], fence: fence, manifest: f.manifest, reason: nil)
        let recovered = try await f.catalog.recomputationNeeded(); XCTAssertFalse(recovered)
    }

    func testCapacityCleanupInvalidatesOldCompletionBeforeSourceReturns() async throws {
        let f = try await GroupFixture.make(self, photos: 2)
        try await f.persist(f.keys.map { ($0, G.vector([0: 1])) })
        _ = try await f.catalog.acquireSource(identity: "source-new", confirmed: true)
        let fence = try await f.catalog.captureFaceAnalysisPersistenceFence(photo: f.photos[0], sourceIdentity: "source-new")
        let result = try await f.catalog.saveFixtureFaceBatch(vectors: [(f.keys[0], EmbeddingVector(modelIdentifier: f.manifest.identifier, values: G.vector([0: 1])))], fence: fence, manifest: f.manifest, reason: nil, maxCapacity: 1)
        XCTAssertEqual(result, .inserted(1))
        _ = try await f.catalog.acquireSource(identity: "source-a", confirmed: true)
        let reuse = try await f.catalog.satisfiesAnalysisReuse(photo: f.photos[1], manifest: f.manifest)
        let admitted = try await f.catalog.needsAdmittedAnalysisRead(photo: f.photos[1], manifest: f.manifest)
        XCTAssertFalse(reuse); XCTAssertTrue(admitted)
        let second = try await f.catalog.captureFaceAnalysisPersistenceFence(photo: f.photos[1], sourceIdentity: "source-a")
        _ = try await f.catalog.saveFixtureFaceBatch(vectors: [(f.keys[1], EmbeddingVector(modelIdentifier: f.manifest.identifier, values: G.vector([0: 1])))], fence: second, manifest: f.manifest, reason: nil, maxCapacity: 1)
        let recovered = try await f.catalog.satisfiesAnalysisReuse(photo: f.photos[1], manifest: f.manifest)
        let rows = try await f.catalog.faceVectorRows()
        XCTAssertTrue(recovered); XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.photoID, f.photos[1].id)
    }
    func testValidMissingRowsStillEnforceRetainedStorageCap() async throws {
        let f = try await GroupFixture.make(self, photos: 2)
        try await f.persist([(f.keys[0], G.vector([0: 1]))])
        var missing = f.photos[0]; missing.missing = true
        try await f.catalog.save(missing, progress: ScanProgress())
        let fence = try await f.catalog.captureFaceAnalysisPersistenceFence(photo: f.photos[1], sourceIdentity: "source-a")
        let result = try await f.catalog.saveFixtureFaceBatch(vectors: [(f.keys[1], EmbeddingVector(modelIdentifier: f.manifest.identifier, values: G.vector([0: 1])))], fence: fence, manifest: f.manifest, reason: nil, maxCapacity: 1)
        XCTAssertEqual(result, .full)
        let rows = try await f.catalog.faceVectorRows()
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.photoID, missing.id)
        try await f.catalog.save(f.photos[0], progress: ScanProgress())
        let reuse = try await f.catalog.satisfiesAnalysisReuse(photo: f.photos[0], manifest: f.manifest)
        XCTAssertTrue(reuse)
    }

    func testZeroFaceReplacementDropsOnlyOwnObsoleteVectorsBeforeCapacityAdmission() async throws {
        let f = try await GroupFixture.make(self, photos: 2)
        try await f.persist([(f.keys[0], G.vector([0: 1]))])
        let old = f.photos[0]
        let zero = PhotoIdentity(id: old.id, relativePath: old.relativePath, dateAdded: old.dateAdded,
            contentVersion: 2, analysis: FaceAnalysisState(status: .successful, detectorVersion: "det", contentVersion: 2, faces: []),
            contentHash: String(repeating: "3", count: 64))
        try await f.catalog.save(zero, progress: ScanProgress())
        let emptyFence = try await f.catalog.captureFaceAnalysisPersistenceFence(photo: zero, sourceIdentity: "source-a")
        _ = try await f.catalog.saveFaceAnalysisBatch(fence: emptyFence, verifiedContentHash: emptyFence.contentHash,
            vectors: [], manifest: f.manifest, status: .emptySuccess, capacity: 1)
        let second = try await f.catalog.captureFaceAnalysisPersistenceFence(photo: f.photos[1], sourceIdentity: "source-a")
        let result = try await f.catalog.saveFixtureFaceBatch(vectors: [(f.keys[1], EmbeddingVector(modelIdentifier: f.manifest.identifier, values: G.vector([0: 1])))], fence: second, manifest: f.manifest, reason: nil, maxCapacity: 1)
        XCTAssertEqual(result, .inserted(1))
        let rows = try await f.catalog.faceVectorRows()
        XCTAssertEqual(rows.map(\.photoID), [f.photos[1].id])
        let reuse = try await f.catalog.satisfiesAnalysisReuse(photo: zero, manifest: f.manifest)
        XCTAssertTrue(reuse)
    }

}

// Shared fixture adapter: tests supply full FaceKeys, while the public batch API admits face IDs.
extension CatalogRepository {
    func saveFixtureFaceBatch(vectors: [(key: FaceKey, vector: EmbeddingVector)],
                              fence: FaceAnalysisPersistenceFence, manifest: ModelManifest,
                              reason: String?, maxCapacity: Int = FaceAnalysisRepository.defaultCapacity) throws -> FaceVectorBatchResult {
        try saveFaceAnalysisBatch(fence: fence, verifiedContentHash: fence.contentHash,
                                 vectors: vectors.map { (faceID: $0.key.faceID, vector: $0.vector) },
                                 manifest: manifest, reason: reason, capacity: maxCapacity)
    }
}
