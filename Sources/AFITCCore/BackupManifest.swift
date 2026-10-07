import Foundation
import CryptoKit
import SQLite3

public enum BackupError: Error, Sendable, Equatable { case limitExceeded, busy, unsafeStage }
public enum BackupOperation: String, Sendable { case preparing, copying, waiting, validating, hashing, finalising }
public struct BackupProgress: Sendable {
    public let operation: BackupOperation
    public let completed: Int
    public let total: Int?
}
public struct BackupCounts: Codable, Sendable, Equatable {
    public let photos: Int
    public let people: Int
    public let currentFaces: Int
    public let manualFaceStates: Int
    public let negativePairs: Int
    public let deferrals: Int
    public let decisionEvents: Int
}
/// Checksums detect corruption, not authority. V1 contains no originals, cache or grants.
public struct BackupManifest: Codable, Sendable, Equatable {
    public let formatVersion: Int
    public let schemaVersion: Int
    public let createdAt: Date
    public let revision: Int
    public let counts: BackupCounts
    public let catalogBytes: Int
    public let catalogSHA256: String
    public static let maximumManifestBytes = 1024 * 1024
    public static let maximumCatalogBytes = 64 * 1024 * 1024
    public static let maximumTotalBytes = 65 * 1024 * 1024
}
/// Only the producing repository can discard its owned completed package.
public struct PreparedCatalogBackup: Sendable {
    public let directory: URL
    public let manifest: BackupManifest
    let owner: UUID
    let token: UUID
}
enum BackupFailure: Equatable { case busy, full, finish }
struct BackupOptions {
    var pagesPerStep = 128
    var busyRetries = 3
    var failure: BackupFailure?
    var manifestLimit = BackupManifest.maximumManifestBytes
    var catalogLimit = BackupManifest.maximumCatalogBytes
    var totalLimit = BackupManifest.maximumTotalBytes
}
enum BackupFiles {
    static func checkLengths(catalog: Int, manifest: Int, options: BackupOptions) throws {
        let (total, overflow) = catalog.addingReportingOverflow(manifest)
        guard catalog >= 0, manifest >= 0, !overflow, catalog <= options.catalogLimit,
              manifest <= options.manifestLimit, total <= options.totalLimit else { throw BackupError.limitExceeded }
    }
    static func summary(_ db: OpaquePointer) throws -> (Int, BackupCounts) {
        func count(_ table: String) throws -> Int { try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM \(table)") }
        return (try PeopleSQL.scalar(db, "SELECT revision FROM catalog_revision WHERE singleton=1"),
            try BackupCounts(photos: count("photos"), people: count("people"), currentFaces: count("current_faces"),
                manualFaceStates: count("manual_faces"), negativePairs: count("pair_negatives"),
                deferrals: count("deferrals"), decisionEvents: count("decisions")))
    }
    static func validate(_ db: OpaquePointer, expectedVersion: Int? = nil) throws {
        let v = try CatalogSchema.version(db)
        if let expectedVersion {
            guard v == expectedVersion else { throw ScanError.unsupportedSchema }
        } else {
            guard v == 3 || v == CatalogSchema.currentVersion else { throw ScanError.unsupportedSchema }
        }
        let statement = try PeopleSQL.statement(db, "PRAGMA integrity_check")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0),
              String(cString: text) == "ok", sqlite3_step(statement) == SQLITE_DONE else { throw ScanError.database }
        let foreign = try PeopleSQL.statement(db, "PRAGMA foreign_key_check")
        defer { sqlite3_finalize(foreign) }
        guard sqlite3_step(foreign) == SQLITE_DONE else { throw ScanError.database }
    }
    static func digest(_ file: URL, bytes: Int, progress: @Sendable (BackupProgress) -> Void) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256(); var consumed = 0
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            guard !data.isEmpty else { break }
            consumed += data.count
            guard consumed <= bytes else { throw ScanError.database }
            hash.update(data: data)
            progress(BackupProgress(operation: .hashing, completed: consumed, total: bytes))
            try Task.checkCancellation()
        }
        guard consumed == bytes else { throw ScanError.database }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Private recovery metadata, not a portable backup or authority assertion.
enum RestoreMarkerState: String, Codable, Sendable { case prepared, committed }
enum RestoreSnapshotSlot: String, Sendable { case old, new }
struct RestoreSnapshotReference: Codable, Sendable, Equatable {
    let path: String
    let catalogBytes: Int
    let catalogSHA256: String
    let manifestBytes: Int
    let manifestSHA256: String
    let schemaVersion: Int
}
struct RestoreMarker: Codable, Sendable, Equatable {
    static let maximumBytes = 64 * 1024
    let version: Int
    let transaction: UUID
    let state: RestoreMarkerState
    let old: RestoreSnapshotReference
    let new: RestoreSnapshotReference
    var selected: RestoreSnapshotReference { state == .prepared ? old : new }
    var stageName: String { "restore-" + transaction.uuidString }
    func checked() throws {
        guard version == 1 else { throw RestoreFileError.invalidMarker }
        for (slot, reference) in [("old", old), ("new", new)] {
            guard reference.path == stageName + "/" + slot,
                  (reference.schemaVersion == 3 || reference.schemaVersion == CatalogSchema.currentVersion),
                  reference.catalogBytes > 0, reference.catalogBytes <= BackupManifest.maximumCatalogBytes,
                  reference.manifestBytes > 0, reference.manifestBytes <= BackupManifest.maximumManifestBytes else { throw RestoreFileError.invalidMarker }
            try BackupFiles.checkLengths(catalog: reference.catalogBytes, manifest: reference.manifestBytes, options: BackupOptions())
            for hash in [reference.catalogSHA256, reference.manifestSHA256] {
                guard hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw RestoreFileError.invalidMarker }
            }
        }
    }
    func encoded() throws -> Data {
        try checked(); let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(self)
        guard bytes.count <= Self.maximumBytes else { throw RestoreFileError.invalidMarker }; return bytes
    }
    static func decode(_ bytes: Data) throws -> RestoreMarker {
        guard !bytes.isEmpty, bytes.count <= maximumBytes else { throw RestoreFileError.invalidMarker }
        do {
            let marker = try JSONDecoder().decode(Self.self, from: bytes)
            // Internal markers have one canonical encoding; duplicate/unknown fields cannot be hidden by decoding.
            guard try marker.encoded() == bytes else { throw RestoreFileError.invalidMarker }; return marker
        } catch { throw RestoreFileError.invalidMarker }
    }
}

/// Foreground callers receive bounded synchronous work updates, without per-row Tasks or private paths.
public enum CatalogRestorePhase: String, Sendable {
    case snapshotting, validating, renewing, staging, preparing, retiring, installing, verifying
    case committing, recovering, removingGrant, clearingMarker, cleaning, opening, completed
}
public enum CatalogRestoreWorkUnit: Sendable { case operations, bytes, pages, sqliteInstructions, rows, jsonNodes, domainItems }
public struct CatalogRestoreProgress: Sendable {
    public let phase: CatalogRestorePhase
    public let completed: Int
    public let total: Int?
    public let unit: CatalogRestoreWorkUnit
    public init(phase: CatalogRestorePhase, completed: Int = 0, total: Int? = nil, unit: CatalogRestoreWorkUnit = .operations) {
        self.phase = phase; self.completed = completed; self.total = total; self.unit = unit
    }
}
