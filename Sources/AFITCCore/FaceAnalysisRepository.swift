import Foundation
import SQLite3

public enum PhotoAnalysisStatus: String, Sendable, Codable, Equatable {
    case completed
    case emptySuccess
    case failed
    case paused
    case capacityFull
}

public struct FaceVectorRow: Sendable, Equatable {
    public let faceKey: FaceKey
    public let photoID: UUID
    public let contentVersion: Int
    public let contentHash: String
    public let sourceBinding: String?
    public let modelIdentifier: String
    public let preprocessingVersion: String
    public let detectorVersion: String
    public let firstAnalysisSequence: Int
    public let vector: [Float]

    public var vectorKey: FaceVectorKey {
        FaceVectorKey(face: faceKey, modelIdentifier: modelIdentifier,
                      preprocessingVersion: preprocessingVersion, contentHash: contentHash)
    }

    public init(faceKey: FaceKey, photoID: UUID, contentVersion: Int, contentHash: String,
                sourceBinding: String?, modelIdentifier: String, preprocessingVersion: String,
                detectorVersion: String, firstAnalysisSequence: Int, vector: [Float]) {
        self.faceKey = faceKey; self.photoID = photoID; self.contentVersion = contentVersion
        self.contentHash = contentHash; self.sourceBinding = sourceBinding
        self.modelIdentifier = modelIdentifier; self.preprocessingVersion = preprocessingVersion
        self.detectorVersion = detectorVersion; self.firstAnalysisSequence = firstAnalysisSequence
        self.vector = vector
    }
}

public struct PhotoAnalysisRecord: Sendable, Equatable {
    public let photoID: UUID
    public let contentVersion: Int
    public let contentHash: String
    public let sourceBinding: String?
    public let modelIdentifier: String
    public let preprocessingVersion: String
    public let status: PhotoAnalysisStatus
    public let reason: String?

    public init(photoID: UUID, contentVersion: Int, contentHash: String, sourceBinding: String?,
                modelIdentifier: String, preprocessingVersion: String, status: PhotoAnalysisStatus, reason: String? = nil) {
        self.photoID = photoID; self.contentVersion = contentVersion; self.contentHash = contentHash
        self.sourceBinding = sourceBinding; self.modelIdentifier = modelIdentifier
        self.preprocessingVersion = preprocessingVersion; self.status = status; self.reason = reason
    }
}

public struct FaceSuppressionRecord: Sendable, Equatable {
    public let faceKey: FaceKey
    public let photoID: UUID
    public let contentVersion: Int
    public let contentHash: String
    public let sourceBinding: String?
    public let createdAt: Date

    public init(faceKey: FaceKey, photoID: UUID, contentVersion: Int, contentHash: String, sourceBinding: String?, createdAt: Date = Date()) {
        self.faceKey = faceKey; self.photoID = photoID; self.contentVersion = contentVersion
        self.contentHash = contentHash; self.sourceBinding = sourceBinding; self.createdAt = createdAt
    }
}

public struct GroupSeparationRecord: Sendable, Equatable, Codable {
    public let faceKeyA: FaceKey
    public let faceKeyB: FaceKey
    public let createdAt: Date

    public init(faceKeyA: FaceKey, faceKeyB: FaceKey, createdAt: Date = Date()) {
        self.faceKeyA = faceKeyA; self.faceKeyB = faceKeyB; self.createdAt = createdAt
    }
}

public struct FaceAnalysisSnapshot: Sendable {
    public let vectors: [FaceVectorRow]
    public let photoRecords: [PhotoAnalysisRecord]
    public let suppressions: [FaceSuppressionRecord]
    public let separations: [GroupSeparationRecord]

    public var vectorMap: [FaceVectorKey: [Float]] {
        Dictionary(uniqueKeysWithValues: vectors.map { ($0.vectorKey, $0.vector) })
    }

    public init(vectors: [FaceVectorRow], photoRecords: [PhotoAnalysisRecord],
                suppressions: [FaceSuppressionRecord], separations: [GroupSeparationRecord]) {
        self.vectors = vectors; self.photoRecords = photoRecords
        self.suppressions = suppressions; self.separations = separations
    }
}

public struct FaceAnalysisRepository: Sendable {
    public static let defaultCapacity = 20_000
    public let catalog: CatalogRepository
    public init(catalog: CatalogRepository) { self.catalog = catalog }
    public func snapshot() async throws -> FaceAnalysisSnapshot { try await catalog.faceAnalysisSnapshot() }
}

extension CatalogRepository {
    public func faceAnalysisSnapshot() throws -> FaceAnalysisSnapshot {
        try peopleRead { db in
            let vectors = try FaceAnalysisSQL.allVectors(db)
            let photoRecords = try FaceAnalysisSQL.allPhotoRecords(db)
            let suppressions = try FaceAnalysisSQL.allSuppressions(db)
            let separations = try FaceAnalysisSQL.allSeparations(db)
            return FaceAnalysisSnapshot(vectors: vectors, photoRecords: photoRecords,
                                        suppressions: suppressions, separations: separations)
        }
    }

    public func faceVectorsSnapshot() throws -> [FaceVectorKey: [Float]] {
        try faceAnalysisSnapshot().vectorMap
    }

    public func faceVectorRows() throws -> [FaceVectorRow] {
        try faceAnalysisSnapshot().vectors
    }

    public func activeFaceVectorCount() throws -> Int {
        try peopleRead { db in
            try FaceAnalysisSQL.countCurrentVectors(db)
        }
    }

    public func saveFaceAnalysisBatch(
        fence: FaceAnalysisPersistenceFence,
        verifiedContentHash: String,
        vectors: [(faceID: UUID, vector: EmbeddingVector)],
        manifest: ModelManifest,
        status: PhotoAnalysisStatus = .completed,
        reason: String? = nil,
        capacity: Int = FaceAnalysisRepository.defaultCapacity
    ) throws -> FaceVectorBatchResult {
        try peopleTransaction { db in
            try Task.checkCancellation()
            do {
                try validateFaceAnalysisPersistenceFence(db, fence: fence,
                                                         sourceIdentity: fence.sourceIdentity,
                                                         verifiedContentHash: verifiedContentHash)
            } catch {
                return .stale
            }

            if status == .emptySuccess {
                let record = PhotoAnalysisRecord(photoID: fence.photoID, contentVersion: fence.contentVersion,
                                                 contentHash: fence.contentHash, sourceBinding: fence.sourceIdentity,
                                                 modelIdentifier: manifest.identifier, preprocessingVersion: manifest.preprocessingVersion,
                                                 status: .emptySuccess, reason: reason)
                try FaceAnalysisSQL.recordPhotoStatus(db, record: record)
                return .inserted(0)
            }

            if status != .completed {
                let record = PhotoAnalysisRecord(photoID: fence.photoID, contentVersion: fence.contentVersion,
                                                 contentHash: fence.contentHash, sourceBinding: fence.sourceIdentity,
                                                 modelIdentifier: manifest.identifier, preprocessingVersion: manifest.preprocessingVersion,
                                                 status: status, reason: reason)
                try FaceAnalysisSQL.recordPhotoStatus(db, record: record)
                return .inserted(0)
            }

            try FaceAnalysisSQL.deleteStaleGenerations(db, photoID: fence.photoID, currentVersion: fence.contentVersion)
            let currentCount = try FaceAnalysisSQL.countCurrentVectors(db)
            var newKeys: [FaceKey] = []
            var normalizedVectors: [([Float], FaceGeometry, FaceKey)] = []

            for entry in vectors {
                guard let geometry = fence.faces.first(where: { $0.id == entry.faceID }) else {
                    return .stale
                }
                let norm = try entry.vector.normalized(using: manifest).values
                let key = FaceKey(photoID: fence.photoID, contentVersion: fence.contentVersion,
                                  detectorVersion: fence.detectorVersion, faceID: entry.faceID)
                if try FaceAnalysisSQL.existingSequence(db, faceKey: key.storageKey) == nil {
                    newKeys.append(key)
                }
                normalizedVectors.append((norm, geometry, key))
            }

            if currentCount + newKeys.count > capacity {
                let record = PhotoAnalysisRecord(photoID: fence.photoID, contentVersion: fence.contentVersion,
                                                 contentHash: fence.contentHash, sourceBinding: fence.sourceIdentity,
                                                 modelIdentifier: manifest.identifier, preprocessingVersion: manifest.preprocessingVersion,
                                                 status: .capacityFull, reason: "Face capacity exceeded")
                try FaceAnalysisSQL.recordPhotoStatus(db, record: record)
                return .full
            }

            for (values, _, key) in normalizedVectors {
                let sequence: Int
                if let existing = try FaceAnalysisSQL.existingSequence(db, faceKey: key.storageKey) {
                    sequence = existing
                } else {
                    sequence = try FaceAnalysisSQL.nextSequence(db)
                }
                let row = FaceVectorRow(faceKey: key, photoID: fence.photoID, contentVersion: fence.contentVersion,
                                        contentHash: fence.contentHash, sourceBinding: fence.sourceIdentity,
                                        modelIdentifier: manifest.identifier, preprocessingVersion: manifest.preprocessingVersion,
                                        detectorVersion: fence.detectorVersion, firstAnalysisSequence: sequence, vector: values)
                let data = try FaceAnalysisEncoding.encodeVector(values)
                try FaceAnalysisSQL.insertVector(db, row: row, data: data)
            }


            let record = PhotoAnalysisRecord(photoID: fence.photoID, contentVersion: fence.contentVersion,
                                             contentHash: fence.contentHash, sourceBinding: fence.sourceIdentity,
                                             modelIdentifier: manifest.identifier, preprocessingVersion: manifest.preprocessingVersion,
                                             status: .completed, reason: reason)
            try FaceAnalysisSQL.recordPhotoStatus(db, record: record)
            return .inserted(vectors.count)
        }
    }

    public func satisfiesAnalysisReuse(photo: PhotoIdentity, manifest: ModelManifest) throws -> Bool {
        try peopleRead { db in
            guard let hash = photo.contentHash, !hash.isEmpty else { return false }
            if let record = try FaceAnalysisSQL.readPhotoStatus(db, photoID: photo.id, contentVersion: photo.contentVersion,
                                                                contentHash: hash, model: manifest.identifier,
                                                                prep: manifest.preprocessingVersion) {
                if record.status == .completed || record.status == .emptySuccess {
                    return true
                }
            }
            if !photo.analysis.faces.isEmpty {
                let allSuppressed = try photo.analysis.faces.allSatisfy { face in
                    let key = FaceKey(photo: photo, face: face)
                    return try FaceAnalysisSQL.isSuppressed(db, faceKey: key.storageKey)
                }
                if allSuppressed { return true }
            }
            return false
        }
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

    public func suppressFace(key: FaceKey, photoID: UUID, contentVersion: Int,
                             contentHash: String, sourceBinding: String?) throws {
        try peopleTransaction { db in
            let record = FaceSuppressionRecord(faceKey: key, photoID: photoID, contentVersion: contentVersion,
                                               contentHash: contentHash, sourceBinding: sourceBinding)
            try FaceAnalysisSQL.suppressFace(db, suppression: record)
        }
    }

    public func isFaceSuppressed(key: FaceKey) throws -> Bool {
        try peopleRead { db in
            try FaceAnalysisSQL.isSuppressed(db, faceKey: key.storageKey)
        }
    }

    public func recordGroupSeparation(faceKeyA: FaceKey, faceKeyB: FaceKey) throws {
        try peopleTransaction { db in
            try FaceAnalysisSQL.recordSeparation(db, keyA: faceKeyA.storageKey, keyB: faceKeyB.storageKey, createdAt: Date())
        }
    }

    public func removeGroupSeparation(faceKeyA: FaceKey, faceKeyB: FaceKey) throws {
        try peopleTransaction { db in
            try FaceAnalysisSQL.removeSeparation(db, keyA: faceKeyA.storageKey, keyB: faceKeyB.storageKey)
        }
    }

    public func areGroupSeparated(faceKeyA: FaceKey, faceKeyB: FaceKey) throws -> Bool {
        try peopleRead { db in
            try FaceAnalysisSQL.areSeparated(db, keyA: faceKeyA.storageKey, keyB: faceKeyB.storageKey)
        }
    }

    public func groupSeparations(for faceKey: FaceKey) throws -> Set<FaceKey> {
        try peopleRead { db in
            let strings = try FaceAnalysisSQL.separationsForFace(db, key: faceKey.storageKey)
            var result = Set<FaceKey>()
            for s in strings {
                let parts = s.split(separator: "|")
                guard parts.count >= 4,
                      let photoID = UUID(uuidString: String(parts[0])),
                      let version = Int(parts[1]),
                      let detectorData = Data(base64Encoded: String(parts[2])),
                      let detector = String(data: detectorData, encoding: .utf8),
                      let faceID = UUID(uuidString: String(parts[3])) else { continue }
                result.insert(FaceKey(photoID: photoID, contentVersion: version, detectorVersion: detector, faceID: faceID))
            }
            return result
        }
    }

    public func recomputationNeeded() throws -> Bool {
        try peopleRead { db in
            let photos: [PhotoIdentity] = try PeopleSQL.rows(db, "SELECT payload FROM photos")
            for photo in photos {
                guard photo.missing != true,
                      photo.analysis.status == .successful,
                      photo.analysis.contentVersion == photo.contentVersion,
                      let hash = photo.contentHash, !hash.isEmpty else { continue }
                let statusCount = try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM photo_analysis_records WHERE photo_id=? AND content_version=? AND content_hash=? AND (status='completed' OR status='emptySuccess')",
                                                      strings: [photo.id.uuidString, "\(photo.contentVersion)", hash])
                if statusCount == 0 {
                    let hasFaces = !photo.analysis.faces.isEmpty
                    if hasFaces {
                        let allSuppressed = try photo.analysis.faces.allSatisfy { face in
                            let key = FaceKey(photo: photo, face: face)
                            return try FaceAnalysisSQL.isSuppressed(db, faceKey: key.storageKey)
                        }
                        if !allSuppressed { return true }
                    } else {
                        return true
                    }
                }
            }
            return false
        }
    }

    /// One consistent read of people, current source/pipeline-filtered durable analysis, exclusions
    /// and suppressions. The expensive pure grouping runs after this transaction has closed.
    public func captureFaceGrouping(modelIdentifier: String, preprocessingVersion: String) throws -> FaceGroupingCapture {
        try peopleRead { db in
            let records: [PersonRecord] = try PeopleSQL.rows(db, "SELECT payload FROM people ORDER BY rowid")
            let summaries = try records.map { person in
                PersonSummary(person: person, confirmedPhotoCount: try PeopleSQL.scalar(db, "SELECT COUNT(DISTINCT c.photo_id) FROM current_faces c JOIN manual_faces m ON m.key=c.key WHERE m.person_id=?", strings: [person.id.uuidString]))
            }
            let keys: [FaceKey] = try PeopleSQL.rows(db, "SELECT payload FROM current_faces ORDER BY rowid")
            let faces = try keys.map { key -> FaceItem in
                let photo = try PeopleSQL.currentPhoto(db, key)
                return FaceItem(key: key, photo: photo, geometry: photo.analysis.faces.first { $0.id == key.faceID }!,
                                state: try PeopleSQL.faceState(db, key))
            }
            let snapshot = PeopleSnapshot(revision: try PeopleSQL.scalar(db, "SELECT revision FROM catalog_revision"),
                                          people: summaries, faces: faces, undoID: nil)
            let bindings: [String?] = try PeopleSQL.rows(db, "SELECT payload FROM source_binding WHERE singleton=1")
            let source = bindings.first ?? nil
            let currentKeys = Set(keys)
            var hashByPhoto: [UUID: String] = [:]
            for face in faces {
                if let hash = face.photo.contentHash, !hash.isEmpty { hashByPhoto[face.key.photoID] = hash }
            }
            var rows: [FaceVectorRow] = []
            for row in try FaceAnalysisSQL.allVectors(db) where row.modelIdentifier == modelIdentifier &&
                row.preprocessingVersion == preprocessingVersion && bindings.count == 1 && row.sourceBinding == source &&
                currentKeys.contains(row.faceKey) {
                guard let hash = hashByPhoto[row.faceKey.photoID], row.contentHash == hash else { continue }
                rows.append(row)
            }
            let suppressions = Set(try FaceAnalysisSQL.allSuppressions(db).filter {
                $0.sourceBinding == source && currentKeys.contains($0.faceKey) &&
                    hashByPhoto[$0.photoID] == $0.contentHash
            }.map(\.faceKey))
            let separations = Set(try FaceAnalysisSQL.allSeparations(db).map { FaceGroupPair($0.faceKeyA, $0.faceKeyB) })
            return FaceGroupingCapture(revision: snapshot.revision, people: snapshot, rows: rows,
                                       separations: separations, suppressions: suppressions)
        }
    }

    /// The production possible-membership result for Verify and group surfaces. The capture is a
    /// single bounded read; grouping itself is pure, deterministic and off the SQL transaction.
    public func faceMembership(policy: SuggestionPolicy = .evaluationDefault,
                               groupingPolicy: FaceGroupingPolicy = .evaluationDefault,
                               progress: (@Sendable (FaceGroupingProgress) -> Void)? = nil) async throws -> FaceMembershipResult {
        let capture = try captureFaceGrouping(modelIdentifier: policy.modelIdentifier,
                                              preprocessingVersion: policy.preprocessingVersion)
        let worker = Task.detached {
            try FaceGrouping.membership(snapshot: capture.people, rows: capture.rows,
                                        separations: capture.separations, suppressions: capture.suppressions,
                                        policy: policy, groupingPolicy: groupingPolicy, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }
}
