import Foundation
import SQLite3

// Consistent current-analysis admission and durable reload, without source reads or inference.
extension CatalogRepository {
    public func satisfiesAnalysisReuse(photo: PhotoIdentity, manifest: ModelManifest) throws -> Bool {
        try peopleRead { db in
            guard let hash = photo.contentHash, !hash.isEmpty else { return false }
            // Reuse compares the actual current catalog photo and source binding, not only the
            // supplied identity: a rebound source or changed geometry never satisfies reuse.
            let photos: [PhotoIdentity] = try PeopleSQL.rows(db, "SELECT payload FROM photos WHERE id=?",
                                                             strings: [photo.id.uuidString])
            guard photos.count == 1, let current = photos.first, current.id == photo.id,
                  current.missing != true,
                  current.relativePath == photo.relativePath,
                  current.contentVersion == photo.contentVersion,
                  current.contentHash == hash,
                  current.analysis.status == .successful,
                  current.analysis.contentVersion == current.contentVersion,
                  current.analysis.detectorVersion == photo.analysis.detectorVersion,
                  current.analysis.faces == photo.analysis.faces else { return false }
            let bindings: [String?] = try PeopleSQL.rows(db, "SELECT payload FROM source_binding WHERE singleton=1")
            guard bindings.count == 1 else { return false }
            if let record = try FaceAnalysisSQL.readPhotoStatus(db, photoID: photo.id,
                                                                contentVersion: photo.contentVersion,
                                                                contentHash: hash, model: manifest.identifier,
                                                                prep: manifest.preprocessingVersion),
               record.status == .completed || record.status == .emptySuccess,
               record.sourceBinding == bindings[0] {
                return true
            }
            if !photo.analysis.faces.isEmpty {
                let suppressed = try Self.currentSuppressedKeys(db, source: bindings[0], hashes: [photo.id: hash])
                let allSuppressed = try photo.analysis.faces.allSatisfy { face in
                    let key = FaceKey(photo: photo, face: face)
                    return suppressed.contains(key)
                }
                if allSuppressed { return true }
            }
            return false
        }
    }

    /// True when a trusted unchanged photo deserves exactly one admitted catch-up read for the
    /// missing or source-stale durable analysis. Explicit failure, pause and capacity-full are
    /// retry states and never trigger repeated source reads on ordinary scans.
    public func needsAdmittedAnalysisRead(photo: PhotoIdentity, manifest: ModelManifest) throws -> Bool {
        try peopleRead { db in
            guard let hash = photo.contentHash, !hash.isEmpty else { return false }
            let photos: [PhotoIdentity] = try PeopleSQL.rows(db, "SELECT payload FROM photos WHERE id=?",
                                                             strings: [photo.id.uuidString])
            guard photos.count == 1, let current = photos.first, current.id == photo.id,
                  current.missing != true,
                  current.relativePath == photo.relativePath,
                  current.contentVersion == photo.contentVersion,
                  current.contentHash == hash,
                  current.analysis.status == .successful,
                  current.analysis.contentVersion == current.contentVersion,
                  current.analysis.detectorVersion == photo.analysis.detectorVersion,
                  current.analysis.faces == photo.analysis.faces else { return false }
            let bindings: [String?] = try PeopleSQL.rows(db, "SELECT payload FROM source_binding WHERE singleton=1")
            guard bindings.count == 1 else { return false }
            let suppressed = try Self.currentSuppressedKeys(db, source: bindings[0], hashes: [photo.id: hash])
            if !photo.analysis.faces.isEmpty && photo.analysis.faces.allSatisfy({ suppressed.contains(FaceKey(photo: photo, face: $0)) }) { return false }
            guard let record = try FaceAnalysisSQL.readPhotoStatus(db, photoID: photo.id,
                                                                    contentVersion: photo.contentVersion,
                                                                    contentHash: hash, model: manifest.identifier,
                                                                    prep: manifest.preprocessingVersion) else {
                return true
            }
            if record.sourceBinding != bindings[0] { return true }
            return false
        }
    }

    /// Durable vectors of the current source binding, current faces and current content, for one
    /// RAM-index reload after relaunch or memory pressure. Suppressed faces are excluded.
    public func currentDurableFaceVectors(manifest: ModelManifest) throws -> [(face: FaceKey, vector: EmbeddingVector, contentHash: String)] {
        try peopleRead { db in
            let bindings: [String?] = try PeopleSQL.rows(db, "SELECT payload FROM source_binding WHERE singleton=1")
            guard bindings.count == 1 else { return [] }
            let source = bindings[0]
            let keys: [FaceKey] = try PeopleSQL.rows(db, "SELECT payload FROM current_faces")
            let currentKeys = Set(keys)
            var hashByPhoto: [UUID: String] = [:]
            let photos: [PhotoIdentity] = try PeopleSQL.rows(db, "SELECT payload FROM photos")
            for photo in photos where photo.missing != true {
                if let hash = photo.contentHash, !hash.isEmpty { hashByPhoto[photo.id] = hash }
            }
            let suppressed = try Self.currentSuppressedKeys(db, source: source, hashes: hashByPhoto)
            var result: [(face: FaceKey, vector: EmbeddingVector, contentHash: String)] = []
            for row in try FaceAnalysisSQL.allVectors(db)
            where row.modelIdentifier == manifest.identifier && row.preprocessingVersion == manifest.preprocessingVersion
                && row.sourceBinding == source && currentKeys.contains(row.faceKey) {
                guard let hash = hashByPhoto[row.faceKey.photoID], row.contentHash == hash else { continue }
                guard !suppressed.contains(row.faceKey) else { continue }
                result.append((face: row.faceKey,
                               vector: EmbeddingVector(modelIdentifier: manifest.identifier, values: row.vector),
                               contentHash: row.contentHash))
            }
            return result
        }
    }

    static func currentSuppressedKeys(_ db: OpaquePointer, source: String?,
                                              hashes: [UUID: String]) throws -> Set<FaceKey> {
        Set(try FaceAnalysisSQL.allSuppressions(db).filter {
            $0.sourceBinding == source && hashes[$0.photoID] == $0.contentHash &&
                $0.contentVersion == $0.faceKey.contentVersion
        }.map(\.faceKey))
    }

    public func photoAnalysisStatus(photoID: UUID, contentVersion: Int, contentHash: String,
                                    manifest: ModelManifest) throws -> PhotoAnalysisStatus? {
        try peopleRead { db in
            let record = try FaceAnalysisSQL.readPhotoStatus(db, photoID: photoID, contentVersion: contentVersion,
                                                            contentHash: contentHash, model: manifest.identifier,
                                                            prep: manifest.preprocessingVersion)
            return record?.status
        }
    }

    /// Explicitly admits another attempt for a current failed, paused or capacity-full photo.
    /// Ordinary scans preserve these states until this human-triggered admission occurs.
    public func admitFaceAnalysisRetry(photo: PhotoIdentity, manifest: ModelManifest) throws {
        try peopleTransaction { db in
            let photos: [PhotoIdentity] = try PeopleSQL.rows(db, "SELECT payload FROM photos WHERE id=?", strings: [photo.id.uuidString])
            guard let current = photos.first, current.missing != true,
                  current.relativePath == photo.relativePath,
                  current.contentVersion == photo.contentVersion, current.contentHash == photo.contentHash,
                  current.analysis == photo.analysis, let hash = current.contentHash else { throw FacePipelineFenceError.stale }
            let bindings: [String?] = try PeopleSQL.rows(db, "SELECT payload FROM source_binding WHERE singleton=1")
            guard bindings.count == 1 else { throw FacePipelineFenceError.ineligible }
            guard let record = try FaceAnalysisSQL.readPhotoStatus(db, photoID: photo.id, contentVersion: photo.contentVersion,
                                                                   contentHash: hash, model: manifest.identifier,
                                                                   prep: manifest.preprocessingVersion),
                  record.sourceBinding == bindings[0], [.failed, .paused, .capacityFull].contains(record.status) else { return }
            try PeopleSQL.run(db, "DELETE FROM photo_analysis_records WHERE photo_id=? AND content_version=? AND content_hash=? AND model_identifier=? AND preprocessing_version=?", strings: [photo.id.uuidString, String(photo.contentVersion), hash, manifest.identifier, manifest.preprocessingVersion])
        }
    }

}
