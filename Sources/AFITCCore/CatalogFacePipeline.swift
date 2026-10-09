import Foundation

public enum FacePipelineFenceError: Error, Sendable, Equatable { case ineligible, stale }

/// Exact current face and manual domain state; this value never grants write or source authority.
public struct CatalogFacePipelineFace: Sendable, Equatable {
    public let key: FaceKey
    public let geometry: FaceGeometry
    public let manualState: ManualFaceState
    fileprivate init(key: FaceKey, geometry: FaceGeometry, manualState: ManualFaceState) {
        self.key = key; self.geometry = geometry; self.manualState = manualState
    }
}

/// Only an explicitly requested, active anchor person participates in epoch comparison.
public struct CatalogFacePipelineAnchor: Sendable, Equatable {
    public let personID: UUID
    public let exemplarRevision: Int
    fileprivate init(personID: UUID, exemplarRevision: Int) {
        self.personID = personID; self.exemplarRevision = exemplarRevision
    }
}

/// Immutable, in-process freshness evidence issued by one existing catalog actor.
/// Validation covers its read-transaction instant only. Later persisted effects must recheck
/// inside their own write transaction; source permission and App session admission remain separate.
public struct CatalogFacePipelineFence: Sendable {
    fileprivate let actorOwnerID: UUID
    fileprivate let photo: FacePipelinePhoto
    public let sourceIdentity: String?
    public let faces: [CatalogFacePipelineFace]
    public let anchor: CatalogFacePipelineAnchor?
    public var photoID: UUID { photo.id }
    public var relativePath: String { photo.path }
    public var contentVersion: Int { photo.version }
    public var contentHash: String { photo.hash }
    public var detectorVersion: String { photo.detector }
    fileprivate init(actorOwnerID: UUID, photo: FacePipelinePhoto, sourceIdentity: String?,
                     faces: [CatalogFacePipelineFace], anchor: CatalogFacePipelineAnchor?) {
        self.actorOwnerID = actorOwnerID; self.photo = photo; self.sourceIdentity = sourceIdentity
        self.faces = faces; self.anchor = anchor
    }
}

/// Excludes cache, dates and checkpoints; detector geometry has deterministic identity ordering.
fileprivate struct FacePipelinePhoto: Sendable, Equatable {
    let id: UUID
    let path: String
    let version: Int
    let hash: String
    let metadata: SourceMetadata?
    let detector: String
    let reason: String?
    let geometry: [FaceGeometry]
    init(_ photo: PhotoIdentity) throws {
        guard photo.missing != true, photo.contentVersion > 0,
              let hash = photo.contentHash, !hash.isEmpty,
              photo.analysis.status == .successful,
              photo.analysis.contentVersion == photo.contentVersion,
              !photo.analysis.detectorVersion.isEmpty,
              Set(photo.analysis.faces.map(\.id)).count == photo.analysis.faces.count else {
            throw FacePipelineFenceError.ineligible
        }
        // Mirrors PeopleSQL.syncPhoto: rectangles outside the photo never enter current_faces.
        let retained = photo.analysis.faces.filter(\.isIndexable)
        guard retained.allSatisfy({ $0.landmarks.allSatisfy { $0.allSatisfy(\.isFinite) } }) else {
            throw FacePipelineFenceError.ineligible
        }
        id = photo.id; path = photo.relativePath; version = photo.contentVersion; self.hash = hash
        metadata = photo.metadata; detector = photo.analysis.detectorVersion; reason = photo.analysis.reason
        geometry = retained.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

fileprivate enum FacePipelineSQL {
    static func capture(_ db: OpaquePointer, owner: UUID, photoID: UUID, sourceIdentity: String?,
                        anchorID: UUID?) throws -> CatalogFacePipelineFence {
        try Task.checkCancellation()
        let bindings: [String?] = try PeopleSQL.rows(db, "SELECT payload FROM source_binding WHERE singleton=1")
        guard bindings.count == 1, bindings[0] == sourceIdentity else { throw FacePipelineFenceError.ineligible }
        let photos: [PhotoIdentity] = try PeopleSQL.rows(db, "SELECT payload FROM photos WHERE id=?", strings: [photoID.uuidString])
        guard photos.count == 1, let current = photos.first, current.id == photoID else { throw FacePipelineFenceError.ineligible }
        let projection = try FacePipelinePhoto(current)
        let expected = projection.geometry.map { FaceKey(photo: current, face: $0) }
        let stored: [FaceKey] = try PeopleSQL.rows(db, "SELECT payload FROM current_faces WHERE photo_id=?", strings: [photoID.uuidString])
        guard stored.count == expected.count, Set(stored) == Set(expected) else { throw FacePipelineFenceError.ineligible }
        let faces = try zip(expected, projection.geometry).map { key, geometry in
            try Task.checkCancellation()
            guard try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM current_faces WHERE key=? AND photo_id=?",
                                       strings: [key.storageKey, photoID.uuidString]) == 1 else { throw FacePipelineFenceError.ineligible }
            let state = try PeopleSQL.faceState(db, key)
            guard state.key == key else { throw FacePipelineFenceError.ineligible }
            return CatalogFacePipelineFace(key: key, geometry: geometry, manualState: state)
        }
        var anchor: CatalogFacePipelineAnchor?
        if let anchorID {
            let people: [PersonRecord] = try PeopleSQL.rows(db, "SELECT payload FROM people WHERE id=?", strings: [anchorID.uuidString])
            guard people.count == 1, let person = people.first, person.id == anchorID,
                  person.mergedInto == nil, person.exemplarRevision > 0,
                  faces.contains(where: {
                      let state = $0.manualState
                      return state.personID == anchorID && state.isAnchor && !state.notPerson && !state.deferred &&
                          !state.rejectedPeople.contains(anchorID) && !state.deferredPeople.contains(anchorID)
                  }) else { throw FacePipelineFenceError.ineligible }
            anchor = CatalogFacePipelineAnchor(personID: anchorID, exemplarRevision: person.exemplarRevision)
        }
        return CatalogFacePipelineFence(actorOwnerID: owner, photo: projection, sourceIdentity: bindings[0], faces: faces, anchor: anchor)
    }
}

extension CatalogRepository {
    /// Captures the complete successful detector/manual projection in one actor-owned transaction.
    /// A present confirmed null source binding is allowed; an absent binding is never eligible.
    public func captureFacePipelineFence(photo captured: PhotoIdentity, sourceIdentity: String?,
                                         anchorPersonID: UUID? = nil) throws -> CatalogFacePipelineFence {
        try peopleRead { db in
            let result = try FacePipelineSQL.capture(db, owner: owner.id, photoID: captured.id,
                                                    sourceIdentity: sourceIdentity, anchorID: anchorPersonID)
            guard result.photo == (try FacePipelinePhoto(captured)) else { throw FacePipelineFenceError.ineligible }
            return result
        }
    }

    /// Rechecks this actor, actual source byte hash and the bound domain at this transaction instant.
    /// This does not authorize a later awaited publication or a separate persisted mutation.
    public func validateFacePipelineFence(_ fence: CatalogFacePipelineFence, sourceIdentity: String?,
                                          verifiedContentHash: String) throws {
        try peopleRead { db in
            try Task.checkCancellation()
            guard fence.actorOwnerID == owner.id, sourceIdentity == fence.sourceIdentity,
                  !verifiedContentHash.isEmpty, verifiedContentHash == fence.contentHash else { throw FacePipelineFenceError.stale }
            do {
                let current = try FacePipelineSQL.capture(db, owner: owner.id, photoID: fence.photoID,
                                                         sourceIdentity: sourceIdentity, anchorID: fence.anchor?.personID)
                guard current.photo == fence.photo, current.faces == fence.faces, current.anchor == fence.anchor else {
                    throw FacePipelineFenceError.stale
                }
            } catch FacePipelineFenceError.ineligible { throw FacePipelineFenceError.stale }
        }
    }

    /// Captures the minimal geometry/content/source persistence fence for model analysis.
    public func captureFaceAnalysisPersistenceFence(photo captured: PhotoIdentity,
                                                    sourceIdentity: String?) throws -> FaceAnalysisPersistenceFence {
        try peopleRead { db in
            try Task.checkCancellation()
            let bindings: [String?] = try PeopleSQL.rows(db, "SELECT payload FROM source_binding WHERE singleton=1")
            guard bindings.count == 1, bindings[0] == sourceIdentity else { throw FacePipelineFenceError.ineligible }
            let photos: [PhotoIdentity] = try PeopleSQL.rows(db, "SELECT payload FROM photos WHERE id=?", strings: [captured.id.uuidString])
            guard photos.count == 1, let current = photos.first, current.id == captured.id else { throw FacePipelineFenceError.ineligible }
            let projection = try FacePipelinePhoto(current)
            guard current.contentVersion == captured.contentVersion,
                  current.contentHash == captured.contentHash,
                  current.analysis.detectorVersion == captured.analysis.detectorVersion,
                  current.relativePath == captured.relativePath,
                  current.analysis.faces == captured.analysis.faces else {
                throw FacePipelineFenceError.ineligible
            }
            return FaceAnalysisPersistenceFence(actorOwnerID: owner.id, photoID: current.id,
                                                relativePath: projection.path, contentVersion: projection.version,
                                                contentHash: projection.hash, detectorVersion: projection.detector,
                                                sourceIdentity: bindings[0], faces: projection.geometry)
        }
    }

    public func validateFaceAnalysisPersistenceFence(_ fence: FaceAnalysisPersistenceFence, sourceIdentity: String?,
                                                     verifiedContentHash: String) throws {
        try peopleRead { db in
            try validateFaceAnalysisPersistenceFence(db, fence: fence, sourceIdentity: sourceIdentity,
                                                     verifiedContentHash: verifiedContentHash)
        }
    }

    func validateFaceAnalysisPersistenceFence(_ db: OpaquePointer, fence: FaceAnalysisPersistenceFence,
                                             sourceIdentity: String?, verifiedContentHash: String) throws {
        try Task.checkCancellation()
        guard fence.actorOwnerID == owner.id, sourceIdentity == fence.sourceIdentity,
              !verifiedContentHash.isEmpty, verifiedContentHash == fence.contentHash else {
            throw FacePipelineFenceError.stale
        }
        let bindings: [String?] = try PeopleSQL.rows(db, "SELECT payload FROM source_binding WHERE singleton=1")
        guard bindings.count == 1, bindings[0] == sourceIdentity else { throw FacePipelineFenceError.stale }
        let photos: [PhotoIdentity] = try PeopleSQL.rows(db, "SELECT payload FROM photos WHERE id=?", strings: [fence.photoID.uuidString])
        guard photos.count == 1, let current = photos.first, current.id == fence.photoID else { throw FacePipelineFenceError.stale }
        do {
            let projection = try FacePipelinePhoto(current)
            guard projection.id == fence.photoID,
                  projection.version == fence.contentVersion,
                  projection.hash == fence.contentHash,
                  projection.detector == fence.detectorVersion,
                  projection.geometry == fence.faces else {
                throw FacePipelineFenceError.stale
            }
        } catch {
            throw FacePipelineFenceError.stale
        }
    }
}

/// Minimal geometry/content/source persistence fence.
/// Human naming must not discard unchanged in-flight model analysis.
public struct FaceAnalysisPersistenceFence: Sendable, Equatable {
    public let actorOwnerID: UUID
    public let photoID: UUID
    public let relativePath: String
    public let contentVersion: Int
    public let contentHash: String
    public let detectorVersion: String
    public let sourceIdentity: String?
    public let faces: [FaceGeometry]

    public init(actorOwnerID: UUID, photoID: UUID, relativePath: String,
                contentVersion: Int, contentHash: String, detectorVersion: String,
                sourceIdentity: String?, faces: [FaceGeometry]) {
        self.actorOwnerID = actorOwnerID; self.photoID = photoID
        self.relativePath = relativePath; self.contentVersion = contentVersion
        self.contentHash = contentHash; self.detectorVersion = detectorVersion
        self.sourceIdentity = sourceIdentity
        self.faces = faces.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}
