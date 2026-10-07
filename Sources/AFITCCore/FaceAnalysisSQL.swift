import Foundation
import SQLite3

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

    /// Only capacity pressure permits this SQL-only sweep of incompatible source/pipeline rows.
    /// Their completion records must disappear too, so a returning source cannot claim reuse
    /// after its vectors were discarded. Valid missing-photo rows and suppression survive.
    static func pruneIncompatibleForCapacity(_ db: OpaquePointer, source: String?, manifest: ModelManifest) throws {
        let predicate = "COALESCE(source_binding,'') != ? OR model_identifier != ? OR preprocessing_version != ?"
        let values = [source ?? "", manifest.identifier, manifest.preprocessingVersion]
        try PeopleSQL.run(db, "DELETE FROM face_vectors WHERE " + predicate, strings: values)
        try PeopleSQL.run(db, "DELETE FROM photo_analysis_records WHERE " + predicate, strings: values)
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
        DO UPDATE SET status=excluded.status, reason=excluded.reason, source_binding=excluded.source_binding
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

    private static func parseVector(_ stmt: OpaquePointer) throws -> FaceVectorRow? {
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
              let photoID = UUID(uuidString: photoStr) else { return nil }
        let data = Data(bytes: blobPtr, count: blobCount)
        let values = try FaceAnalysisEncoding.decodeVector(data)
        let parts = keyStr.split(separator: "|")
        guard parts.count >= 4,
              let parsedPhotoID = UUID(uuidString: String(parts[0])),
              let parsedVersion = Int(parts[1]),
              let detectorData = Data(base64Encoded: String(parts[2])),
              let parsedDetector = String(data: detectorData, encoding: .utf8),
              let parsedFaceID = UUID(uuidString: String(parts[3])) else { return nil }
        let key = FaceKey(photoID: parsedPhotoID, contentVersion: parsedVersion,
                          detectorVersion: parsedDetector, faceID: parsedFaceID)
        return FaceVectorRow(faceKey: key, photoID: photoID, contentVersion: version,
                             contentHash: hash, sourceBinding: source?.isEmpty == true ? nil : source,
                             modelIdentifier: model, preprocessingVersion: prep, detectorVersion: detector,
                             firstAnalysisSequence: seq, vector: values)
    }

    static func vectorRow(_ db: OpaquePointer, faceKey: String) throws -> FaceVectorRow? {
        let sql = "SELECT face_key, photo_id, content_version, content_hash, source_binding, model_identifier, preprocessing_version, detector_version, first_analysis_sequence, vector FROM face_vectors WHERE face_key=?"
        let stmt = try PeopleSQL.statement(db, sql, strings: [faceKey])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return try parseVector(stmt)
    }

    static func allVectors(_ db: OpaquePointer, photoID: UUID? = nil) throws -> [FaceVectorRow] {
        let sql = "SELECT face_key, photo_id, content_version, content_hash, source_binding, model_identifier, preprocessing_version, detector_version, first_analysis_sequence, vector FROM face_vectors" + (photoID == nil ? "" : " WHERE photo_id=?") + " ORDER BY first_analysis_sequence ASC"
        let stmt = try PeopleSQL.statement(db, sql, strings: photoID.map { [$0.uuidString] } ?? [])
        defer { sqlite3_finalize(stmt) }
        var result: [FaceVectorRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let row = try parseVector(stmt) { result.append(row) }
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

    static func allSuppressions(_ db: OpaquePointer, photoID: UUID? = nil) throws -> [FaceSuppressionRecord] {
        let sql = "SELECT face_key, photo_id, content_version, content_hash, source_binding, created_at FROM face_suppression" + (photoID == nil ? "" : " WHERE photo_id=?")
        let stmt = try PeopleSQL.statement(db, sql, strings: photoID.map { [$0.uuidString] } ?? [])
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
