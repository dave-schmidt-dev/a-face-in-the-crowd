import Foundation
import SQLite3

/// Minimal catalog types for AFITCCore bootstrap.
public struct CatalogDatabaseInfo: Sendable, Equatable {
    public let sqliteVersion: String
    public let schemaVersion: Int

    public init(sqliteVersion: String = String(cString: sqlite3_libversion()), schemaVersion: Int = CatalogSchema.currentVersion) {
        self.sqliteVersion = sqliteVersion
        self.schemaVersion = schemaVersion
    }
}
