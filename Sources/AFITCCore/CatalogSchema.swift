import Foundation
import SQLite3

/// Central ordered registry. SQLite transactional DDL provides atomic rollback.
public enum CatalogSchema {
    public static let currentVersion = 2
    public struct Migration {
        public let version: Int
        public let sql: String
        public init(version: Int, sql: String) { self.version = version; self.sql = sql }
    }
    public static let migrations = [Migration(version: 1, sql: """
        CREATE TABLE photos(id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, payload BLOB NOT NULL);
        CREATE TABLE scan_checkpoint(singleton INTEGER PRIMARY KEY CHECK(singleton=1), payload BLOB NOT NULL);
        """), Migration(version: 2, sql: """
        CREATE TABLE source_binding(singleton INTEGER PRIMARY KEY CHECK(singleton=1), payload BLOB NOT NULL);
        CREATE TABLE scan_lease(singleton INTEGER PRIMARY KEY CHECK(singleton=1), generation INTEGER NOT NULL);
        INSERT INTO scan_lease VALUES(1,0);
        """)]
    public static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure(db) }
    }
    public static func failure(_ db: OpaquePointer) -> ScanError {
        (sqlite3_extended_errcode(db) & 0xff) == SQLITE_FULL ? .storagePressure : .database
    }
    public static func version(_ db: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else {
            throw ScanError.database
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ScanError.database }
        return Int(sqlite3_column_int(statement, 0))
    }
    public static func migrate(_ db: OpaquePointer, registry: [Migration] = migrations,
                               target: Int = currentVersion) throws {
        let old = try version(db)
        guard old <= target else { throw ScanError.unsupportedSchema }
        guard old < target else { return }
        let original = sqlite3_db_filename(db, "main").map { String(cString: $0) } ?? ""
        let snapshotURL = original.isEmpty ? nil : URL(fileURLWithPath: original + ".migration-snapshot")
        if let snapshotURL {
            // SQLite backup, never copying a live database or sidecars as raw files.
            guard FileManager.default.createFile(atPath: snapshotURL.path, contents: Data()) else { throw ScanError.database }
            try CatalogRepository.protect(snapshotURL)
        }
        var snapshot: OpaquePointer?
        guard sqlite3_open(snapshotURL?.path ?? ":memory:", &snapshot) == SQLITE_OK, let snapshot else {
            if let snapshot { sqlite3_close(snapshot) }
            throw ScanError.database
        }
        defer {
            sqlite3_close(snapshot)
            if let snapshotURL { try? FileManager.default.removeItem(at: snapshotURL) }
        }
        try copy(from: db, to: snapshot)
        try validate(snapshot)
        try execute(db, "BEGIN IMMEDIATE")
        do {
            for next in (old + 1)...target {
                guard let migration = registry.first(where: { $0.version == next }) else {
                    throw ScanError.unsupportedSchema
                }
                try execute(db, migration.sql)
                try execute(db, "PRAGMA user_version=\(next)")
            }
            try execute(db, "COMMIT")
        } catch {
            try? execute(db, "ROLLBACK")
            // Restore from validated consistent SQLite snapshot, even after partial DDL.
            try copy(from: snapshot, to: db)
            try validate(db)
            throw error
        }
    }
    private static func copy(from source: OpaquePointer, to destination: OpaquePointer) throws {
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else { throw ScanError.database }
        let status = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE, finish == SQLITE_OK else { throw ScanError.database }
    }
    private static func validate(_ db: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK else { throw ScanError.database }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0), String(cString: value) == "ok" else { throw ScanError.database }
    }

}
