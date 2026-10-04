import Foundation
import Darwin
import SQLite3

/// Retained, nondeleting authority. App drains its actual clients before acquiring this owner.
public actor CatalogSuspensionRepository {
    public enum Phase: Sendable, Equatable { case reserved, closing, suspended, reopening, recovering, completed }
    public enum Disposition: Sendable, Equatable { case ordinaryExisting, restoreRecovered }
    public struct Outcome: Sendable {
        public let catalog: CatalogRepository
        public let disposition: Disposition
    }
    public private(set) var phase = Phase.reserved
    private let live: CatalogRepository
    private let reservation: CatalogExclusiveReservation
    private let directory: URL
    private let cache: URL
    private var running = false
    private var physicallyClosed = false
    private var closedProof: CatalogRetiredCloseProof?
    private var ordinaryReopenCompleted = false
    private var fresh: CatalogRepository?
    private var recovery: CatalogRestoreRepository?
    #if DEBUG
    private var testStatement: ProtectedDataSQLiteStatement?
    /// Fixed unfinished SDK statement in this catalog; generated fixtures only at the App call site.
    public func holdSQLiteStatementForTest() async throws {
        try admit(); guard !physicallyClosed, testStatement == nil else { throw CatalogRecoveryError.alreadyRunning }
        try ProtectedDataFixture.require(directory)
        let statement = ProtectedDataSQLiteStatement()
        try await live.withExclusiveDatabase(reservation) { try statement.prepare($0) }
        testStatement = statement
    }
    public func releaseSQLiteStatementForTest() throws { try testStatement?.finalize(); testStatement = nil }
    #endif
    /// Return authority before the first physical close await; never lose a capability in a throwing close factory.
    public static func beginSuspension(catalog: CatalogRepository) async throws -> CatalogSuspensionRepository {
        try Task.checkCancellation()
        let capability = try await catalog.reserveExclusive()
        return CatalogSuspensionRepository(live: catalog, reservation: capability)
    }
    // Same actual capability test seam; no raw database pointer or reservation is exposed to App.
    init(live: CatalogRepository, reservation: CatalogExclusiveReservation) {
        self.live = live; self.reservation = reservation; directory = live.directory; cache = live.cacheDirectory
    }
    private func admit() throws {
        guard !running else { throw CatalogRecoveryError.alreadyRunning }
        guard phase != .completed else { throw CatalogRecoveryError.completed }
    }
    /// SQLITE_BUSY retires the old actor but retains its actual handle and this exact fence.
    public func suspend() async throws {
        try admit(); guard !physicallyClosed else { throw CatalogLifetimeError.retired }
        try Task.checkCancellation()
        running = true; phase = .closing; defer { running = false }
        do {
            let proof = try await live.retire(using: reservation)
            // Keep historical actual-close provenance even after ordinary reservation release.
            closedProof = proof
            physicallyClosed = true; phase = .suspended
        } catch { phase = .reserved; throw error }
    }
    /// Explicitly reopen the existing catalog; no create, migration, source access or grant removal.
    public func reopen() throws -> Outcome {
        try admit(); guard physicallyClosed, recovery == nil else { throw CatalogRecoveryError.recoveryRequired }
        try Task.checkCancellation()
        running = true; phase = .reopening; defer { running = false }
        do {
            if fresh == nil { fresh = try CatalogRepository(directory: directory, cacheDirectory: cache, reservation: reservation, requireExisting: true) }
            guard let fresh else { throw CatalogRecoveryError.recoveryRequired }
            // Store the actor before releasing its capability. Failed release retries this actor, never a second one.
            try reservation.release(); phase = .completed; ordinaryReopenCompleted = true
            return Outcome(catalog: fresh, disposition: .ordinaryExisting)
        } catch { phase = .suspended; throw error }
    }
    /// Explicit stage-only cleanup through this original owner after actual physical close.
    /// It remains valid while stably suspended or after an ordinary reopen/release, without
    /// claiming access to the replacement actor or an active catalog fence.
    public func discardPreparedBackup(_ backup: PreparedCatalogBackup) async throws {
        guard !running else { throw CatalogRecoveryError.alreadyRunning }
        guard physicallyClosed, let closedProof, recovery == nil,
              phase == .suspended || (phase == .completed && ordinaryReopenCompleted) else {
            throw CatalogRecoveryError.recoveryRequired
        }
        try Task.checkCancellation()
        running = true; defer { running = false }
        try await live.discardRetiredPreparedBackup(backup, proof: closedProof)
    }

    /// Marked recovery uses the existing durable restore algorithm under the SAME retained reservation.
    public func recoverMarkedCatalog() async throws -> Outcome {
        try admit(); guard physicallyClosed, recovery != nil || fresh == nil else { throw CatalogRecoveryError.recoveryRequired }
        try Task.checkCancellation()
        running = true; phase = .recovering; defer { running = false }
        do {
            if recovery == nil {
                var marker = stat()
                guard lstat(directory.appendingPathComponent("restore-marker.json").path, &marker) == 0,
                      marker.st_mode & S_IFMT == S_IFREG, marker.st_nlink == 1 else { throw CatalogRecoveryError.recoveryRequired }
                recovery = CatalogRestoreRepository(suspensionReservation: reservation, cacheDirectory: cache)
            }
            guard let recovery else { throw CatalogRecoveryError.recoveryRequired }
            if fresh == nil { fresh = try await recovery.open() }
            // A later disposition/snapshot read cannot drop the already returned actor.
            guard let restored = await recovery.completedRecoveryDisposition() else { throw CatalogRecoveryError.recoveryRequired }
            guard let fresh else { throw CatalogRecoveryError.recoveryRequired }
            phase = .completed
            return Outcome(catalog: fresh, disposition: restored ? .restoreRecovered : .ordinaryExisting)
        } catch { phase = .suspended; throw error }
    }
    // No automatic deinit release: abandoned incomplete authority deliberately fails closed.
}

#if DEBUG
enum ProtectedDataFixture {
    static func require(_ directory: URL) throws {
        var current = directory
        for _ in 0..<3 {
            let name = current.lastPathComponent
            if name.hasPrefix("AFITCTest-") {
                let suffix = String(name.dropFirst("AFITCTest-".count)).replacingOccurrences(of: "-Presentation", with: "")
                if UUID(uuidString: suffix) != nil { return }
            }
            current = current.deletingLastPathComponent()
        }
        throw CatalogRecoveryError.recoveryRequired
    }
}
/// Internal fixed statement; a real SQLite lifetime, never a fabricated close status.
final class ProtectedDataSQLiteStatement: @unchecked Sendable {
    private var statement: OpaquePointer?
    func prepare(_ db: OpaquePointer) throws {
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master", -1, &statement, nil) == SQLITE_OK else { throw ScanError.database }
    }
    func finalize() throws {
        guard let statement else { return }; self.statement = nil
        guard sqlite3_finalize(statement) == SQLITE_OK else { throw ScanError.database }
    }
    deinit { if let statement { sqlite3_finalize(statement) } }
}
#endif
