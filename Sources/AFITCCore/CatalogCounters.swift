import Foundation
import SQLite3

/// A persisted identity counter cannot be coerced or advanced beyond its exact domain.
enum CounterError: Error, Equatable { case exhausted, invalidStoredValue }

/// Checked counters shared by catalog transactions and content-generation invalidation.
enum CatalogCounters {
    enum Singleton {
        case lease, revision
        var select: String {
            switch self {
            case .lease: return "SELECT generation FROM scan_lease WHERE singleton=1"
            case .revision: return "SELECT revision FROM catalog_revision WHERE singleton=1"
            }
        }
        var update: String {
            switch self {
            case .lease: return "UPDATE scan_lease SET generation=? WHERE singleton=1"
            case .revision: return "UPDATE catalog_revision SET revision=? WHERE singleton=1"
            }
        }
    }
    /// Advance a nonnegative epoch without overflow, preserving lawful maximum history.
    static func successor(_ current: Int, minimum: Int = 0) throws -> Int {
        guard current >= minimum else { throw CounterError.invalidStoredValue }
        let (next, overflow) = current.addingReportingOverflow(1)
        guard !overflow else { throw CounterError.exhausted }
        return next
    }
    /// Read the actual SQLite INTEGER storage class, never a truncated REAL or TEXT.
    static func integer(_ statement: OpaquePointer, column: Int32 = 0) throws -> Int {
        guard sqlite3_column_type(statement, column) == SQLITE_INTEGER,
              let value = Int(exactly: sqlite3_column_int64(statement, column)) else {
            throw CounterError.invalidStoredValue
        }
        return value
    }
    static func read(_ db: OpaquePointer, _ singleton: Singleton) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, singleton.select, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw ScanError.database }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ScanError.database }
        let value = try integer(statement)
        guard value >= 0 else { throw CounterError.invalidStoredValue }
        return value
    }
    /// Bind an exact successor inside the caller's existing write transaction.
    @discardableResult static func advance(_ db: OpaquePointer, _ singleton: Singleton) throws -> Int {
        let next = try successor(read(db, singleton))
        try set(db, singleton, next)
        return next
    }
    static func set(_ db: OpaquePointer, _ singleton: Singleton, _ value: Int) throws {
        guard value >= 0, let exact = Int64(exactly: value) else { throw CounterError.invalidStoredValue }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, singleton.update, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw ScanError.database }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, exact) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw ScanError.database }
    }
}
