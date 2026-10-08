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

/// Lightweight durable state for People retry messaging, independent of vector grouping work.
public struct FaceAnalysisStatusSnapshot: Sendable {
    public let photoRecords: [PhotoAnalysisRecord]
    public let activeVectorCount: Int
    public let sourceBinding: String?
    public let hasSourceBinding: Bool
    public let incompletePhotoIDs: Set<UUID>

    public init(photoRecords: [PhotoAnalysisRecord], activeVectorCount: Int, sourceBinding: String?,
                hasSourceBinding: Bool, incompletePhotoIDs: Set<UUID>) {
        self.photoRecords = photoRecords; self.activeVectorCount = activeVectorCount
        self.sourceBinding = sourceBinding; self.hasSourceBinding = hasSourceBinding
        self.incompletePhotoIDs = incompletePhotoIDs
    }
}

public struct FaceAnalysisRepository: Sendable {
    public static let defaultCapacity = 20_000
    public let catalog: CatalogRepository
    public init(catalog: CatalogRepository) { self.catalog = catalog }
    public func snapshot() async throws -> FaceAnalysisSnapshot { try await catalog.faceAnalysisSnapshot() }
}

extension CatalogRepository {
    /// Reads only durable status rows and counts; People can update retry controls while model
    /// grouping is paused or fails without loading vectors or suppressions into app memory.
    public func faceAnalysisStatusSnapshot() throws -> FaceAnalysisStatusSnapshot {
        try peopleRead { db in
            let bindings: [String?] = try PeopleSQL.rows(db, "SELECT payload FROM source_binding WHERE singleton=1")
            return FaceAnalysisStatusSnapshot(
                photoRecords: try FaceAnalysisSQL.allPhotoRecords(db),
                activeVectorCount: try FaceAnalysisSQL.countCurrentVectors(db),
                sourceBinding: bindings.count == 1 ? bindings[0] : nil,
                hasSourceBinding: bindings.count == 1,
                incompletePhotoIDs: try Self.incompleteAnalysisPhotoIDs(
                    db, modelIdentifier: ModelManifest.openCVSFace2021December.identifier,
                    preprocessingVersion: ModelManifest.openCVSFace2021December.preprocessingVersion))
        }
    }

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
                guard fence.faces.isEmpty, vectors.isEmpty else { return .stale }
                try FaceAnalysisSQL.deleteVectorsForPhoto(db, photoID: fence.photoID)
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
            // Vectors from another source binding are stale derived generations of this photo.
            try PeopleSQL.run(db, "DELETE FROM face_vectors WHERE photo_id=? AND source_binding != ?",
                              strings: [fence.photoID.uuidString, fence.sourceIdentity ?? ""])
            // Preserve unrelated and temporarily missing photos. Only the admitted photo's
            // indexed rows are decoded/cleaned; the retained-row capacity check is a scalar SQL count.
            let hashes = [fence.photoID: fence.contentHash]
            let currentKeys = Set(fence.faces.map { FaceKey(photoID: fence.photoID,
                contentVersion: fence.contentVersion, detectorVersion: fence.detectorVersion, faceID: $0.id) })
            for row in try FaceAnalysisSQL.allVectors(db, photoID: fence.photoID) where
                !currentKeys.contains(row.faceKey) || row.contentHash != fence.contentHash ||
                row.sourceBinding != fence.sourceIdentity || row.modelIdentifier != manifest.identifier ||
                row.preprocessingVersion != manifest.preprocessingVersion {
                try FaceAnalysisSQL.deleteVector(db, faceKey: row.faceKey.storageKey)
            }
            let suppressed = try Self.currentSuppressedKeys(db, source: fence.sourceIdentity, hashes: hashes)
            var currentCount = try FaceAnalysisSQL.countCurrentVectors(db)
            var newKeys: [FaceKey] = []
            var normalizedVectors: [([Float], FaceGeometry, FaceKey)] = []

            var submitted = Set<UUID>()
            for entry in vectors {
                guard submitted.insert(entry.faceID).inserted else { return .stale }
                guard let geometry = fence.faces.first(where: { $0.id == entry.faceID }) else {
                    return .stale
                }
                let norm = try entry.vector.normalized(using: manifest).values
                let key = FaceKey(photoID: fence.photoID, contentVersion: fence.contentVersion,
                                  detectorVersion: fence.detectorVersion, faceID: entry.faceID)
                // Suppression is rechecked inside this transaction before capacity counting and
                // insertion, so a human deletion during in-flight inference cannot reinsert the
                // suppressed biometric vector.
                if suppressed.contains(key) { continue }
                if try FaceAnalysisSQL.existingSequence(db, faceKey: key.storageKey) == nil {
                    newKeys.append(key)
                }
                normalizedVectors.append((norm, geometry, key))
            }

            if currentCount + newKeys.count > capacity {
                try FaceAnalysisSQL.pruneIncompatibleForCapacity(db, source: fence.sourceIdentity, manifest: manifest)
                currentCount = try FaceAnalysisSQL.countCurrentVectors(db)
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
            return .inserted(normalizedVectors.count)
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
            try Self.recomputationNeeded(db, modelIdentifier: ModelManifest.openCVSFace2021December.identifier,
                                         preprocessingVersion: ModelManifest.openCVSFace2021December.preprocessingVersion)
        }
    }

    /// One consistent read of people, current source/pipeline-filtered durable analysis, exclusions
    /// and suppressions. The expensive pure grouping runs after this transaction has closed.
    public func captureFaceGrouping(modelIdentifier: String, preprocessingVersion: String) throws -> FaceGroupingCapture {
        try peopleRead { db in
            try Self.captureFaceGrouping(db, modelIdentifier: modelIdentifier, preprocessingVersion: preprocessingVersion)
        }
    }
    /// Caller-owned read seam: grouping and Search can freeze exactly the same revision.
    static func captureFaceGrouping(_ db: OpaquePointer, modelIdentifier: String,
                                     preprocessingVersion: String) throws -> FaceGroupingCapture {
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
                                       separations: separations, suppressions: suppressions,
                                       analysisIncomplete: try Self.recomputationNeeded(db, modelIdentifier: modelIdentifier,
                                                                                       preprocessingVersion: preprocessingVersion))
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
                                        policy: policy, groupingPolicy: groupingPolicy, progress: progress,
                                        analysisIncomplete: capture.analysisIncomplete)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }
}
