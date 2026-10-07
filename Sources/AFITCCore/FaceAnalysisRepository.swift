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

public struct GroupSeparationRecord: Sendable, Equatable {
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

enum FaceAnalysisSQL {
    static let schema = """
    CREATE TABLE face_vectors(
        face_key TEXT PRIMARY KEY,
        photo_id TEXT NOT NULL,
        content_version INTEGER NOT NULL,
        content_hash TEXT NOT NULL,
        source_binding TEXT,
        model_identifier TEXT NOT NULL,
        preprocessing_version TEXT NOT NULL,
        detector_version TEXT NOT NULL,
        first_analysis_sequence INTEGER NOT NULL,
        vector BLOB NOT NULL
    );
    CREATE INDEX face_vectors_photo ON face_vectors(photo_id);
    CREATE INDEX face_vectors_sequence ON face_vectors(first_analysis_sequence);

    CREATE TABLE photo_analysis_records(
        photo_id TEXT NOT NULL,
        content_version INTEGER NOT NULL,
        content_hash TEXT NOT NULL,
        source_binding TEXT,
        model_identifier TEXT NOT NULL,
        preprocessing_version TEXT NOT NULL,
        status TEXT NOT NULL,
        reason TEXT,
        PRIMARY KEY(photo_id, content_version, content_hash, model_identifier, preprocessing_version)
    );

    CREATE TABLE face_suppression(
        face_key TEXT PRIMARY KEY,
        photo_id TEXT NOT NULL,
        content_version INTEGER NOT NULL,
        content_hash TEXT NOT NULL,
        source_binding TEXT,
        created_at REAL NOT NULL
    );

    CREATE TABLE group_separations(
        face_key_a TEXT NOT NULL,
        face_key_b TEXT NOT NULL,
        created_at REAL NOT NULL,
        PRIMARY KEY(face_key_a, face_key_b)
    );

    CREATE TABLE face_analysis_sequence(
        singleton INTEGER PRIMARY KEY CHECK(singleton=1),
        next_sequence INTEGER NOT NULL
    );
    INSERT INTO face_analysis_sequence VALUES(1,1);
    """

    static func nextSequence(_ db: OpaquePointer) throws -> Int {
        let stmt = try PeopleSQL.statement(db, "SELECT next_sequence FROM face_analysis_sequence WHERE singleton=1")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw ScanError.database }
        let current = Int(sqlite3_column_int(stmt, 0))
        let next = current + 1
        try PeopleSQL.run(db, "UPDATE face_analysis_sequence SET next_sequence=? WHERE singleton=1", strings: ["\(next)"])
        return current
    }

    static func existingSequence(_ db: OpaquePointer, faceKey: String) throws -> Int? {
        let stmt = try PeopleSQL.statement(db, "SELECT first_analysis_sequence FROM face_vectors WHERE face_key=?", strings: [faceKey])
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return nil
    }

    static func countCurrentVectors(_ db: OpaquePointer) throws -> Int {
        try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM face_vectors")
    }

    static func insertVector(_ db: OpaquePointer, row: FaceVectorRow, data: Data) throws {
        let sql = """
        INSERT INTO face_vectors(face_key, photo_id, content_version, content_hash, source_binding, model_identifier, preprocessing_version, detector_version, first_analysis_sequence, vector)
        VALUES(?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(face_key) DO UPDATE SET
            photo_id=excluded.photo_id,
            content_version=excluded.content_version,
            content_hash=excluded.content_hash,
            source_binding=excluded.source_binding,
            model_identifier=excluded.model_identifier,
            preprocessing_version=excluded.preprocessing_version,
            detector_version=excluded.detector_version,
            first_analysis_sequence=excluded.first_analysis_sequence,
            vector=excluded.vector
        """
        let strings = [
            row.faceKey.storageKey,
            row.photoID.uuidString,
            "\(row.contentVersion)",
            row.contentHash,
            row.sourceBinding ?? "",
            row.modelIdentifier,
            row.preprocessingVersion,
            row.detectorVersion,
            "\(row.firstAnalysisSequence)"
        ]
        try PeopleSQL.run(db, sql, strings: strings, data: data)
    }

    static func deleteStaleGenerations(_ db: OpaquePointer, photoID: UUID, currentVersion: Int) throws {
        try PeopleSQL.run(db, "DELETE FROM face_vectors WHERE photo_id=? AND content_version < ?",
                          strings: [photoID.uuidString, "\(currentVersion)"])
    }

    static func deleteVector(_ db: OpaquePointer, faceKey: String) throws {
        try PeopleSQL.run(db, "DELETE FROM face_vectors WHERE face_key=?", strings: [faceKey])
    }

    static func deleteVectorsForPhoto(_ db: OpaquePointer, photoID: UUID) throws {
        try PeopleSQL.run(db, "DELETE FROM face_vectors WHERE photo_id=?", strings: [photoID.uuidString])
    }

    static func recordPhotoStatus(_ db: OpaquePointer, record: PhotoAnalysisRecord) throws {
        let sql = """
        INSERT INTO photo_analysis_records(photo_id, content_version, content_hash, source_binding, model_identifier, preprocessing_version, status, reason)
        VALUES(?,?,?,?,?,?,?,?)
        ON CONFLICT(photo_id, content_version, content_hash, model_identifier, preprocessing_version)
        DO UPDATE SET status=excluded.status, reason=excluded.reason
        """
        let strings = [
            record.photoID.uuidString,
            "\(record.contentVersion)",
            record.contentHash,
            record.sourceBinding ?? "",
            record.modelIdentifier,
            record.preprocessingVersion,
            record.status.rawValue,
            record.reason ?? ""
        ]
        try PeopleSQL.run(db, sql, strings: strings)
    }

    static func readPhotoStatus(_ db: OpaquePointer, photoID: UUID, contentVersion: Int, contentHash: String,
                                model: String, prep: String) throws -> PhotoAnalysisRecord? {
        let sql = "SELECT status, reason, source_binding FROM photo_analysis_records WHERE photo_id=? AND content_version=? AND content_hash=? AND model_identifier=? AND preprocessing_version=?"
        let strings = [photoID.uuidString, "\(contentVersion)", contentHash, model, prep]
        let stmt = try PeopleSQL.statement(db, sql, strings: strings)
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            let statusStr = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let reasonStr = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let sourceStr = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            guard let status = PhotoAnalysisStatus(rawValue: statusStr) else { return nil }
            return PhotoAnalysisRecord(photoID: photoID, contentVersion: contentVersion, contentHash: contentHash,
                                       sourceBinding: sourceStr?.isEmpty == true ? nil : sourceStr,
                                       modelIdentifier: model, preprocessingVersion: prep, status: status, reason: reasonStr?.isEmpty == true ? nil : reasonStr)
        }
        return nil
    }

    static func allVectors(_ db: OpaquePointer) throws -> [FaceVectorRow] {
        let sql = "SELECT face_key, photo_id, content_version, content_hash, source_binding, model_identifier, preprocessing_version, detector_version, first_analysis_sequence, vector FROM face_vectors ORDER BY first_analysis_sequence ASC"
        let stmt = try PeopleSQL.statement(db, sql)
        defer { sqlite3_finalize(stmt) }
        var result: [FaceVectorRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let keyStr = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let photoStr = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let version = Int(sqlite3_column_int(stmt, 2))
            let hash = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let source = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            let model = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
            let prep = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
            let detector = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? ""
            let seq = Int(sqlite3_column_int(stmt, 8))
            let blobCount = Int(sqlite3_column_bytes(stmt, 9))
            guard let blobPtr = sqlite3_column_blob(stmt, 9), blobCount == FaceAnalysisEncoding.vectorByteCount,
                  let photoID = UUID(uuidString: photoStr) else { continue }
            let data = Data(bytes: blobPtr, count: blobCount)
            let values = try FaceAnalysisEncoding.decodeVector(data)
            let parts = keyStr.split(separator: "|")
            guard parts.count >= 4,
                  let parsedPhotoID = UUID(uuidString: String(parts[0])),
                  let parsedVersion = Int(parts[1]),
                  let detectorData = Data(base64Encoded: String(parts[2])),
                  let parsedDetector = String(data: detectorData, encoding: .utf8),
                  let parsedFaceID = UUID(uuidString: String(parts[3])) else { continue }
            let key = FaceKey(photoID: parsedPhotoID, contentVersion: parsedVersion,
                              detectorVersion: parsedDetector, faceID: parsedFaceID)
            result.append(FaceVectorRow(faceKey: key, photoID: photoID, contentVersion: version,
                                        contentHash: hash, sourceBinding: source?.isEmpty == true ? nil : source,
                                        modelIdentifier: model, preprocessingVersion: prep, detectorVersion: detector,
                                        firstAnalysisSequence: seq, vector: values))
        }
        return result
    }

    static func suppressFace(_ db: OpaquePointer, suppression: FaceSuppressionRecord) throws {
        let sql = "INSERT INTO face_suppression(face_key, photo_id, content_version, content_hash, source_binding, created_at) VALUES(?,?,?,?,?,?) ON CONFLICT(face_key) DO UPDATE SET created_at=excluded.created_at"
        let strings = [
            suppression.faceKey.storageKey,
            suppression.photoID.uuidString,
            "\(suppression.contentVersion)",
            suppression.contentHash,
            suppression.sourceBinding ?? "",
            "\(suppression.createdAt.timeIntervalSince1970)"
        ]
        try PeopleSQL.run(db, sql, strings: strings)
        try PeopleSQL.run(db, "DELETE FROM face_vectors WHERE face_key=?", strings: [suppression.faceKey.storageKey])
    }

    static func isSuppressed(_ db: OpaquePointer, faceKey: String) throws -> Bool {
        try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM face_suppression WHERE face_key=?", strings: [faceKey]) > 0
    }

    static func allSuppressions(_ db: OpaquePointer) throws -> [FaceSuppressionRecord] {
        let sql = "SELECT face_key, photo_id, content_version, content_hash, source_binding, created_at FROM face_suppression"
        let stmt = try PeopleSQL.statement(db, sql)
        defer { sqlite3_finalize(stmt) }
        var result: [FaceSuppressionRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let keyStr = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let photoStr = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let version = Int(sqlite3_column_int(stmt, 2))
            let hash = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let source = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            let created = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
            let parts = keyStr.split(separator: "|")
            guard parts.count >= 4,
                  let parsedPhotoID = UUID(uuidString: String(parts[0])),
                  let parsedVersion = Int(parts[1]),
                  let detectorData = Data(base64Encoded: String(parts[2])),
                  let parsedDetector = String(data: detectorData, encoding: .utf8),
                  let parsedFaceID = UUID(uuidString: String(parts[3])),
                  let photoID = UUID(uuidString: photoStr) else { continue }
            let key = FaceKey(photoID: parsedPhotoID, contentVersion: parsedVersion,
                              detectorVersion: parsedDetector, faceID: parsedFaceID)
            result.append(FaceSuppressionRecord(faceKey: key, photoID: photoID, contentVersion: version,
                                                contentHash: hash, sourceBinding: source?.isEmpty == true ? nil : source,
                                                createdAt: created))
        }
        return result
    }

    static func recordSeparation(_ db: OpaquePointer, keyA: String, keyB: String, createdAt: Date) throws {
        let sortedA = min(keyA, keyB), sortedB = max(keyA, keyB)
        let sql = "INSERT INTO group_separations(face_key_a, face_key_b, created_at) VALUES(?,?,?) ON CONFLICT(face_key_a, face_key_b) DO UPDATE SET created_at=excluded.created_at"
        try PeopleSQL.run(db, sql, strings: [sortedA, sortedB, "\(createdAt.timeIntervalSince1970)"])
    }

    static func removeSeparation(_ db: OpaquePointer, keyA: String, keyB: String) throws {
        let sortedA = min(keyA, keyB), sortedB = max(keyA, keyB)
        try PeopleSQL.run(db, "DELETE FROM group_separations WHERE face_key_a=? AND face_key_b=?", strings: [sortedA, sortedB])
    }

    static func areSeparated(_ db: OpaquePointer, keyA: String, keyB: String) throws -> Bool {
        let sortedA = min(keyA, keyB), sortedB = max(keyA, keyB)
        return try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM group_separations WHERE face_key_a=? AND face_key_b=?",
                                    strings: [sortedA, sortedB]) > 0
    }

    static func separationsForFace(_ db: OpaquePointer, key: String) throws -> Set<String> {
        let sql = "SELECT face_key_a, face_key_b FROM group_separations WHERE face_key_a=? OR face_key_b=?"
        let stmt = try PeopleSQL.statement(db, sql, strings: [key, key])
        defer { sqlite3_finalize(stmt) }
        var result = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let a = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let b = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            if a == key { result.insert(b) } else { result.insert(a) }
        }
        return result
    }

    static func allSeparations(_ db: OpaquePointer) throws -> [GroupSeparationRecord] {
        let sql = "SELECT face_key_a, face_key_b, created_at FROM group_separations"
        let stmt = try PeopleSQL.statement(db, sql)
        defer { sqlite3_finalize(stmt) }
        var result: [GroupSeparationRecord] = []
        func parseKey(_ keyStr: String) -> FaceKey? {
            let parts = keyStr.split(separator: "|")
            guard parts.count >= 4,
                  let parsedPhotoID = UUID(uuidString: String(parts[0])),
                  let parsedVersion = Int(parts[1]),
                  let detectorData = Data(base64Encoded: String(parts[2])),
                  let parsedDetector = String(data: detectorData, encoding: .utf8),
                  let parsedFaceID = UUID(uuidString: String(parts[3])) else { return nil }
            return FaceKey(photoID: parsedPhotoID, contentVersion: parsedVersion,
                           detectorVersion: parsedDetector, faceID: parsedFaceID)
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let aStr = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let bStr = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let created = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            guard let keyA = parseKey(aStr), let keyB = parseKey(bStr) else { continue }
            result.append(GroupSeparationRecord(faceKeyA: keyA, faceKeyB: keyB, createdAt: created))
        }
        return result
    }

    static func allPhotoRecords(_ db: OpaquePointer) throws -> [PhotoAnalysisRecord] {
        let sql = "SELECT photo_id, content_version, content_hash, source_binding, model_identifier, preprocessing_version, status, reason FROM photo_analysis_records"
        let stmt = try PeopleSQL.statement(db, sql)
        defer { sqlite3_finalize(stmt) }
        var result: [PhotoAnalysisRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let photoStr = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let version = Int(sqlite3_column_int(stmt, 1))
            let hash = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let source = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            let model = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let prep = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
            let statusStr = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
            let reasonStr = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
            guard let photoID = UUID(uuidString: photoStr),
                  let status = PhotoAnalysisStatus(rawValue: statusStr) else { continue }
            result.append(PhotoAnalysisRecord(photoID: photoID, contentVersion: version, contentHash: hash,
                                              sourceBinding: source?.isEmpty == true ? nil : source,
                                              modelIdentifier: model, preprocessingVersion: prep,
                                              status: status, reason: reasonStr?.isEmpty == true ? nil : reasonStr))
        }
        return result
    }
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
}
