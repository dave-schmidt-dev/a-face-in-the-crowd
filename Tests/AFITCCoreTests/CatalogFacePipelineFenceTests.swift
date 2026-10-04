import XCTest
@testable import AFITCCore

private struct FenceFixture {
    let catalog: CatalogRepository
    let photo: PhotoIdentity
    let otherPhoto: PhotoIdentity
    static let hash = String(repeating: "a", count: 64)
    static func make(_ test: XCTestCase, identity: String? = "owned-source", bound: Bool = true,
                     zeroFaces: Bool = false) async throws -> FenceFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AFITCTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let catalog = try CatalogRepository(directory: root.appendingPathComponent("Catalog"), cacheDirectory: root.appendingPathComponent("Cache"))
        if bound { _ = try await catalog.acquireSource(identity: identity, confirmed: true) }
        let face = FaceGeometry(rectangle: [0.1, 0.2, 0.3, 0.4], landmarks: [[0.2, 0.3]])
        let photo = PhotoIdentity(relativePath: "first.jpg", analysis: FaceAnalysisState(status: .successful,
            faces: zeroFaces ? [] : [face]), metadata: SourceMetadata(revision: "v1", size: 64), contentHash: hash)
        let other = PhotoIdentity(relativePath: "other.jpg", analysis: FaceAnalysisState(status: .successful,
            faces: [FaceGeometry(rectangle: [0.2, 0.1, 0.2, 0.3], landmarks: [])]), contentHash: hash)
        try await catalog.save(photo, progress: ScanProgress()); try await catalog.save(other, progress: ScanProgress())
        return FenceFixture(catalog: catalog, photo: photo, otherPhoto: other)
    }
    var key: FaceKey { FaceKey(photo: photo, face: photo.analysis.faces[0]) }
    var otherKey: FaceKey { FaceKey(photo: otherPhoto, face: otherPhoto.analysis.faces[0]) }
    func capture(anchor: UUID? = nil) async throws -> CatalogFacePipelineFence {
        try await catalog.captureFacePipelineFence(photo: photo, sourceIdentity: "owned-source", anchorPersonID: anchor)
    }
    func validate(_ fence: CatalogFacePipelineFence) async throws {
        try await catalog.validateFacePipelineFence(fence, sourceIdentity: "owned-source", verifiedContentHash: Self.hash)
    }
    func name(_ key: FaceKey, _ name: String) async throws -> UUID {
        _ = try await catalog.applyDecision(.name(face: key, displayName: name))
        let snapshot = try await catalog.peopleSnapshot()
        return try XCTUnwrap(snapshot.faces.first { $0.key == key }?.state.personID)
    }
    func replace(version: Int? = nil, path: String? = nil) -> PhotoIdentity {
        let analysis = FaceAnalysisState(status: photo.analysis.status, detectorVersion: photo.analysis.detectorVersion,
            contentVersion: version ?? photo.contentVersion, faces: photo.analysis.faces)
        return PhotoIdentity(id: photo.id, relativePath: path ?? photo.relativePath, dateAdded: photo.dateAdded,
            contentVersion: version ?? photo.contentVersion, previewPath: photo.previewPath, analysis: analysis,
            metadata: photo.metadata, contentHash: photo.contentHash, missing: photo.missing)
    }
}

final class CatalogFacePipelineFenceTests: XCTestCase {
    private func expect(_ expected: FacePipelineFenceError, _ operation: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected fence rejection", file: file, line: line) }
        catch { XCTAssertEqual(error as? FacePipelineFenceError, expected, file: file, line: line) }
    }
    func testImmutableSuccessfulFenceAndExplicitNullSourceBindingRoundTrip() async throws {
        let f = try await FenceFixture.make(self)
        let fence = try await f.capture(); try await f.validate(fence)
        XCTAssertEqual(fence.photoID, f.photo.id); XCTAssertEqual(fence.contentVersion, 1)
        XCTAssertEqual(fence.faces.map(\.key), [f.key]); XCTAssertEqual(fence.faces[0].geometry, f.photo.analysis.faces[0])
        XCTAssertEqual(fence.faces[0].manualState, ManualFaceState(key: f.key)); XCTAssertNil(fence.anchor)
        let absent = try await FenceFixture.make(self, bound: false)
        await expect(.ineligible) { _ = try await absent.capture() }
        let null = try await FenceFixture.make(self, identity: nil, zeroFaces: true)
        let zero = try await null.catalog.captureFacePipelineFence(photo: null.photo, sourceIdentity: nil)
        try await null.catalog.validateFacePipelineFence(zero, sourceIdentity: nil, verifiedContentHash: FenceFixture.hash)
        XCTAssertTrue(zero.faces.isEmpty)
        await expect(.ineligible) {
            _ = try await null.catalog.captureFacePipelineFence(photo: null.photo, sourceIdentity: nil, anchorPersonID: UUID())
        }
    }
    func testPhotoContentHashVersionMissingPathAndSourceRebindInvalidate() async throws {
        let mutations: [(FenceFixture) -> PhotoIdentity] = [
            { f in var p = f.photo; p.contentHash = String(repeating: "b", count: 64); return p },
            { $0.replace(version: 2) }, { $0.replace(path: "renamed.jpg") },
            { f in var p = f.photo; p.metadata = SourceMetadata(revision: "v2", size: 64); return p },
            { f in var p = f.photo; p.missing = true; return p }
        ]
        for mutate in mutations {
            let f = try await FenceFixture.make(self), fence = try await f.capture()
            let changed = mutate(f)
            if changed.relativePath != f.photo.relativePath { try await f.catalog.replaceFenceFixturePath(changed) }
            else { try await f.catalog.save(changed, progress: ScanProgress()) }
            let stored = try await f.catalog.photos().first { $0.id == changed.id }
            XCTAssertEqual(stored?.relativePath, changed.relativePath)
            XCTAssertEqual(stored?.contentVersion, changed.contentVersion)
            XCTAssertEqual(stored?.analysis.contentVersion, changed.analysis.contentVersion)
            await expect(.stale) { try await f.validate(fence) }
        }
        let f = try await FenceFixture.make(self), fence = try await f.capture()
        await expect(.stale) { try await f.catalog.validateFacePipelineFence(fence, sourceIdentity: "owned-source", verifiedContentHash: "wrong") }
        await expect(.stale) { try await f.catalog.validateFacePipelineFence(fence, sourceIdentity: "other", verifiedContentHash: FenceFixture.hash) }
        _ = try await f.catalog.acquireSource(identity: "changed-source", confirmed: true)
        await expect(.stale) { try await f.validate(fence) }
    }
    func testDetectorStatusExactFaceMembershipAndGeometryInvalidate() async throws {
        let f = try await FenceFixture.make(self), fence = try await f.capture(), face = f.photo.analysis.faces[0]
        let changed = FaceGeometry(id: face.id, rectangle: [0.2, 0.2, 0.3, 0.4], landmarks: face.landmarks)
        let landmark = FaceGeometry(id: face.id, rectangle: face.rectangle, landmarks: [[0.4, 0.3]])
        let states = [FaceAnalysisState(status: .pending), FaceAnalysisState(status: .failed),
            FaceAnalysisState(status: .successful, detectorVersion: "changed", faces: [face]),
            FaceAnalysisState(status: .successful, contentVersion: 2, faces: [face]),
            FaceAnalysisState(status: .successful, faces: []),
            FaceAnalysisState(status: .successful, faces: [face, FaceGeometry(rectangle: [0, 0, 0.1, 0.1], landmarks: [])]),
            FaceAnalysisState(status: .successful, faces: [changed]), FaceAnalysisState(status: .successful, faces: [landmark])]
        for state in states {
            var photo = f.photo; photo.analysis = state
            try await f.catalog.save(photo, progress: ScanProgress())
            await expect(.stale) { try await f.validate(fence) }
            try await f.catalog.save(f.photo, progress: ScanProgress())
        }
        var invalid = f.photo
        invalid.analysis = FaceAnalysisState(status: .successful, faces: [FaceGeometry(id: face.id, rectangle: [0, 0, 0, 0], landmarks: [])])
        try await f.catalog.save(invalid, progress: ScanProgress())
        await expect(.ineligible) { _ = try await f.catalog.captureFacePipelineFence(photo: invalid, sourceIdentity: "owned-source") }
        try await f.catalog.save(f.photo, progress: ScanProgress())
        var duplicate = f.photo; duplicate.analysis = FaceAnalysisState(status: .successful, faces: [face, face])
        await expect(.ineligible) { _ = try await f.catalog.captureFacePipelineFence(photo: duplicate, sourceIdentity: "owned-source") }
        // The decoded payload alone cannot prove membership in the actual current_faces index.
        try await f.catalog.substituteFenceFixtureIndexKey(f.key)
        await expect(.ineligible) { _ = try await f.capture() }
        await expect(.stale) { try await f.validate(fence) }
    }
    func testEveryManualStateChangeInvalidatesCapturedFaces() async throws {
        for kind in 0..<6 {
            let f = try await FenceFixture.make(self)
            let first = try await f.name(f.key, "First"), second = try await f.name(f.otherKey, "Other")
            let fence = try await f.capture()
            let decisions: [ManualDecision] = [.confirm(face: f.key, personID: second), .unassign(face: f.key),
                .reject(face: f.key, personID: second), .unsure(face: f.key, personID: second),
                .unsure(face: f.key, personID: nil), .notPerson(face: f.key)]
            _ = try await f.catalog.applyDecision(decisions[kind])
            await expect(.stale) { try await f.validate(fence) }
            XCTAssertEqual(fence.faces[0].manualState.personID, first)
        }
    }
    func testOnlyRequestedAnchorEpochTracksOtherPhotoExemplarDeleteAndMerge() async throws {
        let f = try await FenceFixture.make(self), person = try await f.name(f.key, "Anchor")
        let targeted = try await f.capture(anchor: person), ordinary = try await f.capture()
        _ = try await f.catalog.applyDecision(.confirm(face: f.otherKey, personID: person))
        await expect(.stale) { try await f.validate(targeted) }; try await f.validate(ordinary)
        let after = try await f.capture(anchor: person)
        XCTAssertGreaterThan(try XCTUnwrap(after.anchor).exemplarRevision, try XCTUnwrap(targeted.anchor).exemplarRevision)
        _ = try await f.catalog.deletePerson(person)
        await expect(.stale) { try await f.validate(after) }
        let m = try await FenceFixture.make(self)
        let source = try await m.name(m.key, "Source"), survivor = try await m.name(m.otherKey, "Survivor")
        let before = try await m.capture(anchor: source)
        let preview = try await m.catalog.previewMerge(source: source, survivor: survivor)
        _ = try await m.catalog.mergePeople(preview, resolutions: [])
        await expect(.stale) { try await m.validate(before) }
    }
    func testUnrelatedPeoplePreviewAndCheckpointChangesPreserveFence() async throws {
        let f = try await FenceFixture.make(self)
        let person = try await f.name(f.key, "Anchor"), other = try await f.name(f.otherKey, "Other")
        let fence = try await f.capture(anchor: person)
        let oldRevision = try await f.catalog.peopleSnapshot().revision
        _ = try await f.catalog.applyDecision(.rename(personID: other, displayName: "Unrelated renamed"))
        _ = try await f.catalog.applyDecision(.rename(personID: person, displayName: "Anchor renamed"))
        let newRevision = try await f.catalog.peopleSnapshot().revision; XCTAssertGreaterThan(newRevision, oldRevision)
        try await f.validate(fence)
        var photo = f.photo; photo.previewPath = "new-preview.jpg"; photo.verifiedAt = Date()
        try await f.catalog.save(photo, progress: ScanProgress())
        try await f.validate(fence)
        _ = try await f.catalog.deletePerson(other); try await f.validate(fence)
    }
    func testCapturedOwnerFenceRejectsDifferentCatalogAndRetiredReopenedActor() async throws {
        let f = try await FenceFixture.make(self), fence = try await f.capture(), other = try await FenceFixture.make(self)
        await expect(.stale) { try await other.validate(fence) }
        let suspension = try await CatalogSuspensionRepository.beginSuspension(catalog: f.catalog)
        try await suspension.suspend()
        do { try await f.validate(fence); XCTFail("Retired actor admitted work") }
        catch { XCTAssertEqual(error as? CatalogLifetimeError, .retired) }
        let reopened = try await suspension.reopen().catalog
        await expect(.stale) { try await reopened.validateFacePipelineFence(fence, sourceIdentity: "owned-source", verifiedContentHash: FenceFixture.hash) }
        let fresh = try await reopened.captureFacePipelineFence(photo: f.photo, sourceIdentity: "owned-source")
        try await reopened.validateFacePipelineFence(fresh, sourceIdentity: "owned-source", verifiedContentHash: FenceFixture.hash)
    }
}

// Actual owned SQLite path mutation: public save intentionally cannot rename an existing identity.
private extension CatalogRepository {
    func substituteFenceFixtureIndexKey(_ key: FaceKey) throws {
        try peopleTransaction { db in
            try PeopleSQL.run(db, "UPDATE current_faces SET key=? WHERE key=?", strings: ["fixture-substituted-key", key.storageKey])
        }
    }
    func replaceFenceFixturePath(_ photo: PhotoIdentity) throws {
        try peopleTransaction { db in
            try PeopleSQL.run(db, "UPDATE photos SET path=?1,payload=?3 WHERE id=?2",
                strings: [photo.relativePath, photo.id.uuidString], data: JSONEncoder().encode(photo))
        }
    }
}
