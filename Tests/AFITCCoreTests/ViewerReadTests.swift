import XCTest
@testable import AFITCCore

final class ViewerReadTests: XCTestCase {
    private func catalog() throws -> CatalogRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try CatalogRepository(directory: root.appendingPathComponent("db"), cacheDirectory: root.appendingPathComponent("cache"))
    }
    private func rejected(_ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Unsafe original accepted") }
        catch { XCTAssertEqual(error as? ScanError, .unavailable) }
    }
    func testMatchingOriginalValidationPreservesLeaseRevisionAndCheckpoint() async throws {
        let repo = try catalog()
        let lease = try await repo.acquireSource(identity: "root", confirmed: true)
        let photo = PhotoIdentity(relativePath: "nested/fixture.jpg", contentHash: "known-hash")
        var progress = ScanProgress(); progress.processed = 3
        try await repo.save(photo, progress: progress, lease: lease)
        let before = try await repo.peopleSnapshot().revision
        try await repo.validateViewerPhoto(photo, sourceIdentity: "root")
        try await repo.validateViewerPhoto(photo, sourceIdentity: "root", verifiedContentHash: "known-hash")
        try await repo.requireLease(lease)
        let after = try await repo.peopleSnapshot().revision, checkpoint = try await repo.checkpoint()
        XCTAssertEqual(before, after); XCTAssertEqual(checkpoint, progress)
        let stored = try await repo.photos(); XCTAssertEqual(stored, [photo])
    }
    func testDifferentRootMissingBindingAndExplicitUnknownBinding() async throws {
        let repo = try catalog(), photo = PhotoIdentity(relativePath: "fixture.jpg", contentHash: "hash")
        try await repo.save(photo, progress: ScanProgress())
        await rejected { try await repo.validateViewerPhoto(photo, sourceIdentity: nil) }
        _ = try await repo.acquireSource(identity: nil, confirmed: true)
        // Explicitly bound unknown provider identity permits eligibility before byte IO.
        try await repo.validateViewerPhoto(photo, sourceIdentity: nil)
        await rejected { try await repo.validateViewerPhoto(photo, sourceIdentity: nil, verifiedContentHash: "wrong-byte-hash") }
        try await repo.validateViewerPhoto(photo, sourceIdentity: nil, verifiedContentHash: "hash")
        await rejected { try await repo.validateViewerPhoto(photo, sourceIdentity: "different") }
        _ = try await repo.acquireSource(identity: "known", confirmed: true)
        await rejected { try await repo.validateViewerPhoto(photo, sourceIdentity: nil) }
        await rejected { try await repo.validateViewerPhoto(photo, sourceIdentity: "different") }
    }
    func testCapturedUUIDVersionPathAndHashMustMatchCurrentGeneration() async throws {
        let repo = try catalog(); _ = try await repo.acquireSource(identity: "root", confirmed: true)
        let photo = PhotoIdentity(relativePath: "fixture.jpg", contentHash: "hash")
        try await repo.save(photo, progress: ScanProgress())
        for stale in [PhotoIdentity(relativePath: photo.relativePath, contentHash: "hash"),
                      PhotoIdentity(id: photo.id, relativePath: photo.relativePath, contentVersion: 2, contentHash: "hash"),
                      PhotoIdentity(id: photo.id, relativePath: "other.jpg", contentHash: "hash"),
                      PhotoIdentity(id: photo.id, relativePath: photo.relativePath, contentHash: "different")] {
            await rejected { try await repo.validateViewerPhoto(stale, sourceIdentity: "root") }
        }
        await rejected { try await repo.validateViewerPhoto(photo, sourceIdentity: "root", verifiedContentHash: "changed-bytes") }
        let newer = PhotoIdentity(id: photo.id, relativePath: photo.relativePath, contentVersion: 2, contentHash: "new-hash")
        try await repo.save(newer, progress: ScanProgress())
        await rejected { try await repo.validateViewerPhoto(photo, sourceIdentity: "root", verifiedContentHash: "hash") }
    }
    func testStoredPayloadUUIDMustAgreeWithPhysicalRecord() async throws {
        let repo = try catalog(); _ = try await repo.acquireSource(identity: "root", confirmed: true)
        let photo = PhotoIdentity(relativePath: "fixture.jpg", contentHash: "hash")
        try await repo.save(photo, progress: ScanProgress())
        let inconsistent = PhotoIdentity(relativePath: photo.relativePath, contentHash: "hash")
        try await repo.peopleTransaction { db in
            try PeopleSQL.run(db, "UPDATE photos SET payload=? WHERE id='\(photo.id.uuidString)'",
                              data: JSONEncoder().encode(inconsistent))
        }
        await rejected { try await repo.validateViewerPhoto(photo, sourceIdentity: "root", verifiedContentHash: "hash") }
    }
    func testMissingAndUnhashedPhotosNeverClaimOriginal() async throws {
        let repo = try catalog(); _ = try await repo.acquireSource(identity: "root", confirmed: true)
        for photo in [PhotoIdentity(relativePath: "missing.jpg", contentHash: "hash", missing: true),
                      PhotoIdentity(relativePath: "unhashed.jpg"), PhotoIdentity(relativePath: "empty.jpg", contentHash: "")] {
            try await repo.save(photo, progress: ScanProgress())
            await rejected { try await repo.validateViewerPhoto(photo, sourceIdentity: "root") }
        }
    }
}
