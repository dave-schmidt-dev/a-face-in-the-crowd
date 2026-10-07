import Foundation
import Darwin
import SQLite3

public enum CatalogRecoveryError: Error, Sendable, Equatable { case recoveryRequired, alreadyRunning, completed }

/// Retained restore session. Failed post-marker work requires explicit retry under the same capability.
public actor CatalogRestoreRepository {
    private let reservation: CatalogExclusiveReservation
    private let directory: URL
    private let cache: URL
    private let observer: @Sendable (RestoreFileEvent) throws -> Void
    private let fault: @Sendable (RestoreFileEvent) -> Int32?
    private let readDiagnostics: SourceRestoreReadDiagnostics?
    private let markerFullArm: MarkerFullProtectionArm
    private let ownedProtection: OwnedRestoreProtection
    private let requireExistingOnFresh: Bool
    /// Only the startup reservation sweeps crash-orphaned stages; live and suspension sessions never do.
    private let sweepsOrphans: Bool
    /// Fixed count of recognised leftovers the startup sweep could not remove; no names or paths.
    public private(set) var skippedOrphans = 0
    private var freshCandidate: CatalogRepository?
    private var files: CatalogRestoreFiles?
    private var retained: (RestoreFileStage, RestoreMarker)?
    private var preparation: CatalogRestorePreparation?
    private var live: CatalogRepository?
    private var liveRetired = false
    private var temporaryBackup: PreparedCatalogBackup?
    private var unpublished: RestoreFileStage?
    private var running = false
    private var completed = false
    private var cleaned = false
    private var recovered = false
    public enum ProtectedDataPhase: Sendable { case open, closing, closeRetryRequired, closed, reopening, completed }
    public private(set) var protectedDataPhase = ProtectedDataPhase.open
    public struct ProtectedDataOutcome: Sendable {
        public let catalog: CatalogRepository
        public let disposition: CatalogSuspensionRepository.Disposition
    }
    struct RetiredBackupClosure: Sendable {
        let reservation: CatalogExclusiveReservation
        let ownerID: UUID
        fileprivate init(reservation: CatalogExclusiveReservation, ownerID: UUID) {
            self.reservation = reservation; self.ownerID = ownerID
        }
    }
    private var retiredBackupClosure: RetiredBackupClosure?
    private var protectedCloseAttempted = false
    #if DEBUG
    private var heldInspection: RestoreInspection?
    private var heldInspectionStatement: ProtectedDataSQLiteStatement?
    #endif
    public init(directory: URL, cacheDirectory: URL, requireExisting: Bool = false) throws {
        try self.init(directory: directory, cacheDirectory: cacheDirectory, observer: { _ in }, fault: { _ in nil }, requireExisting: requireExisting)
    }
    init(directory: URL, cacheDirectory: URL,
         observer: @escaping @Sendable (RestoreFileEvent) throws -> Void,
         fault: @escaping @Sendable (RestoreFileEvent) -> Int32?,
         readDiagnostics: SourceRestoreReadDiagnostics? = nil, requireExisting: Bool = false,
         markerFullArm: MarkerFullProtectionArm = .production, ownedProtection: OwnedRestoreProtection = .production) throws {
        reservation = try CatalogRootRegistry.shared.startup(directory: directory, cache: cacheDirectory)
        self.directory = reservation.directory
        cache = URL(fileURLWithPath: CatalogRootRegistry.canonical(cacheDirectory), isDirectory: true)
        self.observer = observer; self.fault = fault; self.readDiagnostics = readDiagnostics; requireExistingOnFresh = requireExisting
        self.markerFullArm = markerFullArm; self.ownedProtection = ownedProtection; sweepsOrphans = true
    }
    private init(live: CatalogRepository, reservation: CatalogExclusiveReservation,
                 observer: @escaping @Sendable (RestoreFileEvent) throws -> Void,
                 fault: @escaping @Sendable (RestoreFileEvent) -> Int32?,
                 readDiagnostics: SourceRestoreReadDiagnostics?, markerFullArm: MarkerFullProtectionArm, ownedProtection: OwnedRestoreProtection) {
        self.live = live; self.reservation = reservation; directory = live.directory; cache = live.cacheDirectory
        self.observer = observer; self.fault = fault; self.readDiagnostics = readDiagnostics; requireExistingOnFresh = false
        self.markerFullArm = markerFullArm; self.ownedProtection = ownedProtection; sweepsOrphans = false
    }
    /// Inert bridge: physical retirement is checked by the suspension owner; no second startup reservation.
    init(suspensionReservation: CatalogExclusiveReservation, cacheDirectory: URL) {
        reservation = suspensionReservation; directory = suspensionReservation.directory; cache = cacheDirectory
        observer = { _ in }; fault = { _ in nil }; readDiagnostics = nil; requireExistingOnFresh = true
        markerFullArm = .production; ownedProtection = .production; sweepsOrphans = false
    }
    /// Checked typed evidence after actual successful recovery/open and capability release.
    func completedRecoveryDisposition() -> Bool? { !running && completed ? recovered : nil }
    /// Closes actual handles only; retains this reservation and every owned stage for explicit unlock.
    public func suspendForProtectedData() async throws {
        guard !completed else { throw CatalogRecoveryError.completed }
        guard !running else { throw CatalogRecoveryError.alreadyRunning }
        guard protectedDataPhase != .closed else { throw CatalogLifetimeError.retired }
        try Task.checkCancellation()
        running = true; protectedCloseAttempted = true; protectedDataPhase = .closing
        defer { running = false }
        do {
            try preparation?.close()
            #if DEBUG
            try heldInspection?.close(); heldInspection = nil
            #endif
            if let freshCandidate {
                try await freshCandidate.retire(using: reservation); self.freshCandidate = nil
            }
            if let live, !liveRetired {
                try await live.retire(using: reservation); liveRetired = true
                retiredBackupClosure = RetiredBackupClosure(reservation: reservation, ownerID: live.owner.id)
            }
            protectedDataPhase = .closed
        } catch { protectedDataPhase = .closeRetryRequired; throw error }
    }
    /// Explicit checked unlock: existing-only original or durable marker recovery, never a second capability.
    public func reopenAfterProtectedData(progress: @escaping @Sendable (CatalogRestoreProgress) -> Void = { _ in }) async throws -> ProtectedDataOutcome {
        guard !completed else { throw CatalogRecoveryError.completed }
        guard !running else { throw CatalogRecoveryError.alreadyRunning }
        guard protectedDataPhase == .closed else { throw CatalogRecoveryError.recoveryRequired }
        protectedDataPhase = .reopening
        do {
            let catalog = try await performOpen(progress: progress)
            protectedDataPhase = .completed
            return ProtectedDataOutcome(catalog: catalog, disposition: recovered ? .restoreRecovered : .ordinaryExisting)
        } catch { protectedDataPhase = .closed; throw error }
    }
    #if DEBUG
    /// Fixed actual reserved inspection/unfinished statement; only this owner catalog, no caller SQL/path.
    public func holdProtectedInspectionForTest() throws {
        guard !running, !completed, !protectedCloseAttempted, heldInspection == nil else { throw CatalogRecoveryError.alreadyRunning }
        try ProtectedDataFixture.require(directory)
        let inspection = try RestoreInspection(file: directory.appendingPathComponent("catalog.sqlite"), reservation: reservation)
        let statement = ProtectedDataSQLiteStatement()
        do { try inspection.withHandle { try statement.prepare($0) } }
        catch { try inspection.close(); throw error }
        heldInspection = inspection; heldInspectionStatement = statement
    }
    // Internal causal preparation fixture uses the real snapshot/stage/inspection ownership path.
    func prepareUnpublishedBackupForTest() async throws -> (URL, URL) {
        guard !running, !completed, !protectedCloseAttempted, let live, temporaryBackup == nil else { throw CatalogRecoveryError.alreadyRunning }
        running = true; defer { running = false }
        let backup = try await live.prepareBackup(progress: { _ in }, options: BackupOptions(), reservation: reservation, ownedProtection: ownedProtection)
        temporaryBackup = backup
        let files = try CatalogRestoreFiles(root: directory, markerFullArm: markerFullArm, ownedProtection: ownedProtection); self.files = files
        let stage = try await files.createStage(); unpublished = stage
        _ = try await files.copyPackage(from: backup.directory, manifest: backup.manifest, into: stage, slot: .old)
        try verifier().verify(backup.directory.appendingPathComponent("catalog.sqlite"), manifest: backup.manifest, progress: { _ in })
        return (backup.directory, directory.appendingPathComponent(stage.name))
    }
    public func releaseProtectedInspectionForTest() throws {
        try heldInspectionStatement?.finalize(); heldInspectionStatement = nil
    }
    #endif
    /// Authority for explicit original-graph recovery after checked pre-PREPARED cleanup.
    /// Never reacquires a reservation or touches the filesystem.
    public func preservedCatalogAfterCleanup() -> CatalogRepository? {
        guard !running, completed, !liveRetired, retained == nil,
              unpublished == nil, temporaryBackup == nil else { return nil }
        return live
    }
    #if DEBUG
    public enum TestFault: Sendable { case afterPreparedMarker }
    /// Fixed one-shot fault after actual durable marker publication; synthetic tests only.
    public static func beginRestore(catalog: CatalogRepository, testFault: TestFault) async throws -> CatalogRestoreRepository {
        let trigger = PreparedMarkerTestFault()
        return try await beginRestore(catalog: catalog, observer: { try trigger.observe($0) }, fault: { _ in nil })
    }
    #endif
    /// Admission refuses other handles, construction and outstanding work before any restore filesystem effect.
    public static func beginRestore(catalog: CatalogRepository) async throws -> CatalogRestoreRepository {
        try await beginRestore(catalog: catalog, observer: { _ in }, fault: { _ in nil })
    }
    static func beginRestore(catalog: CatalogRepository,
                             observer: @escaping @Sendable (RestoreFileEvent) throws -> Void,
                             fault: @escaping @Sendable (RestoreFileEvent) -> Int32?,
                             readDiagnostics: SourceRestoreReadDiagnostics? = nil,
                             markerFullArm: MarkerFullProtectionArm = .production, ownedProtection: OwnedRestoreProtection = .production) async throws -> CatalogRestoreRepository {
        let reservation = try await catalog.reserveExclusive()
        return CatalogRestoreRepository(live: catalog, reservation: reservation, observer: observer, fault: fault, readDiagnostics: readDiagnostics, markerFullArm: markerFullArm, ownedProtection: ownedProtection)
    }
    static func requireNoMarker(_ directory: URL) throws {
        var info = stat()
        if lstat(directory.appendingPathComponent("restore-marker.json").path, &info) == 0 { throw CatalogRecoveryError.recoveryRequired }
        guard errno == ENOENT else { throw CatalogRecoveryError.recoveryRequired }
    }
    private func inspectorProgress(_ phase: CatalogRestorePhase,
                                   _ progress: @escaping @Sendable (CatalogRestoreProgress) -> Void) -> @Sendable (RestoreValidationProgress) -> Void {
        { value in
            let unit: CatalogRestoreWorkUnit
            switch value.unit { case .bytes: unit = .bytes; case .sqliteInstructions: unit = .sqliteInstructions
            case .rows: unit = .rows; case .jsonNodes: unit = .jsonNodes; case .domainItems: unit = .domainItems }
            progress(CatalogRestoreProgress(phase: phase, completed: value.completed, total: value.total, unit: unit))
        }
    }
    private func phase(_ phase: CatalogRestorePhase, files: CatalogRestoreFiles,
                       progress: @escaping @Sendable (CatalogRestoreProgress) -> Void) async {
        progress(CatalogRestoreProgress(phase: phase))
        await files.setProgress { progress(CatalogRestoreProgress(phase: phase, completed: $0, total: $1, unit: .bytes)) }
    }
    private func verifier() throws -> CatalogRestorePreparation {
        if let preparation { return preparation }
        let value = CatalogRestorePreparation(reservation: reservation); preparation = value; return value
    }
    /// Recover typed PREPARED→OLD / COMMITTED→NEW before any fresh actor can open the root.
    public func open(progress: @escaping @Sendable (CatalogRestoreProgress) -> Void = { _ in }) async throws -> CatalogRepository {
        guard !protectedCloseAttempted else { throw CatalogRecoveryError.recoveryRequired }
        return try await performOpen(progress: progress)
    }
    private func performOpen(progress: @escaping @Sendable (CatalogRestoreProgress) -> Void) async throws -> CatalogRepository {
        guard !completed else { throw CatalogRecoveryError.completed }
        guard !running else { throw CatalogRecoveryError.alreadyRunning }
        running = true; defer { running = false }
        try preparation?.close()
        if freshCandidate != nil { return try await fresh(progress: progress) }
        if files == nil, FileManager.default.fileExists(atPath: directory.path) {
            files = try CatalogRestoreFiles(root: directory, observer: observer, fault: fault, readDiagnostics: readDiagnostics, markerFullArm: markerFullArm, ownedProtection: ownedProtection)
        }
        if !cleaned, let files {
            if let persisted = try await files.retainedStage() { retained = persisted; unpublished = nil }
            if let (stage, marker) = retained {
                recovered = true
                let manifest = try await files.selectedManifest(stage, marker: marker)
                progress(CatalogRestoreProgress(phase: .validating))
                try verifier().verify(directory.appendingPathComponent(marker.selected.path).appendingPathComponent("catalog.sqlite"),
                    manifest: manifest, progress: inspectorProgress(.validating, progress))
                if let live, !liveRetired { try await live.retire(using: reservation); liveRetired = true }
                await phase(.recovering, files: files, progress: progress)
                try await files.recoverInstallation(stage, marker: marker)
                try await verifyInstalled(files, marker: marker, manifest: manifest, progress: progress)
                return try await finish(files, stage: stage, marker: marker, progress: progress)
            }
            if live != nil {
                if protectedCloseAttempted {
                    try await performPrePreparedCleanup(files, release: false)
                    return try await fresh(progress: progress)
                }
                try await cleanupBeforePrepared(files); throw CatalogRecoveryError.recoveryRequired
            }
        }
        return try await fresh(progress: progress)
    }
    /// Commits only validated identity data. Originals and source grants are never imported.
    public func restore(_ validated: ValidatedCatalogBackup,
                        progress: @escaping @Sendable (CatalogRestoreProgress) -> Void = { _ in }) async throws -> CatalogRepository {
        guard !completed, let live else { throw CatalogRecoveryError.completed }
        guard !protectedCloseAttempted else { throw CatalogRecoveryError.recoveryRequired }
        guard !running else { throw CatalogRecoveryError.alreadyRunning }
        running = true; defer { running = false }
        let files = try CatalogRestoreFiles(root: directory, observer: observer, fault: fault, readDiagnostics: readDiagnostics, markerFullArm: markerFullArm, ownedProtection: ownedProtection); self.files = files
        var publicationAttempted = false
        do {
            progress(CatalogRestoreProgress(phase: .snapshotting))
            let backup = try await live.prepareBackup(progress: { value in
                progress(CatalogRestoreProgress(phase: .snapshotting, completed: value.completed, total: value.total,
                    unit: value.operation == .copying ? .pages : .bytes))
            }, options: BackupOptions(), reservation: reservation, ownedProtection: ownedProtection)
            temporaryBackup = backup
            await phase(.staging, files: files, progress: progress)
            let stage = try await files.createStage(); unpublished = stage
            _ = try await files.copyPackage(from: backup.directory, manifest: backup.manifest, into: stage, slot: .old)
            _ = try await files.copyPackage(from: validated.directory, manifest: validated.manifest, into: stage, slot: .new)
            let oldURL = directory.appendingPathComponent(stage.name + "/old/catalog.sqlite")
            let newURL = directory.appendingPathComponent(stage.name + "/new/catalog.sqlite")
            let preparation = try verifier()
            progress(CatalogRestoreProgress(phase: .validating))
            try preparation.verify(oldURL, manifest: backup.manifest, progress: inspectorProgress(.validating, progress))
            try preparation.verify(newURL, manifest: validated.manifest, progress: inspectorProgress(.validating, progress))
            progress(CatalogRestoreProgress(phase: .renewing))
            let (oldManifest, newManifest) = try preparation.renew(old: oldURL, new: newURL, oldManifest: backup.manifest, newManifest: validated.manifest, progress: progress)
            let old = try await files.refreshPackage(stage, slot: .old, manifest: oldManifest)
            let new = try await files.refreshPackage(stage, slot: .new, manifest: newManifest)
            func exact(_ input: BackupManifest, _ reference: RestoreSnapshotReference) -> BackupManifest {
                BackupManifest(formatVersion: input.formatVersion, schemaVersion: input.schemaVersion, createdAt: input.createdAt,
                    revision: input.revision, counts: input.counts, catalogBytes: reference.catalogBytes, catalogSHA256: reference.catalogSHA256)
            }
            try preparation.verify(oldURL, manifest: exact(oldManifest, old), progress: inspectorProgress(.validating, progress))
            try preparation.verify(newURL, manifest: exact(newManifest, new), progress: inspectorProgress(.validating, progress))
            try await live.discardRestoreBackup(backup, reservation: reservation); temporaryBackup = nil
            await phase(.preparing, files: files, progress: progress)
            try await files.prepareInstallation(stage, new: new)
            let marker = RestoreMarker(version: 1, transaction: stage.transaction, state: .prepared, old: old, new: new)
            publicationAttempted = true
            try await files.publish(marker, stage: stage); retained = (stage, marker); unpublished = nil
            progress(CatalogRestoreProgress(phase: .retiring)); try await live.retire(using: reservation); liveRetired = true
            await phase(.removingGrant, files: files, progress: progress); try await files.removeGrant()
            await phase(.installing, files: files, progress: progress); try await files.replaceInstallation(stage, new: new)
            let actual = exact(newManifest, new)
            try await verifyInstalled(files, marker: RestoreMarker(version: 1, transaction: stage.transaction, state: .committed, old: old, new: new), manifest: actual, progress: progress)
            await phase(.committing, files: files, progress: progress)
            let committed = RestoreMarker(version: 1, transaction: stage.transaction, state: .committed, old: old, new: new)
            try await files.publish(committed, stage: stage); retained = (stage, committed); recovered = true
            return try await finish(files, stage: stage, marker: committed, progress: progress)
        } catch {
            // A close failure must not mask the original error or skip owned cleanup.
            try? preparation?.close()
            if !publicationAttempted { try await cleanupBeforePrepared(files) }
            else if let persisted = try await files.retainedStage() { retained = persisted; unpublished = nil }
            else if !liveRetired { try await cleanupBeforePrepared(files) }
            throw error
        }
    }
    /// Await finite owned cleanup independently of the request's cancellation; release only after it succeeds.
    private func cleanupBeforePrepared(_ files: CatalogRestoreFiles) async throws {
        let cleanup = Task.detached { try await self.performPrePreparedCleanup(files) }
        try await cleanup.value
    }
    private func performPrePreparedCleanup(_ files: CatalogRestoreFiles, release: Bool = true) async throws {
        if let unpublished { try await files.discard(unpublished); self.unpublished = nil }
        if let temporaryBackup, let live {
            if let retiredBackupClosure {
                try await live.discardRetiredRestoreBackup(temporaryBackup, reservation: reservation, closure: retiredBackupClosure)
            } else { try await live.discardRestoreBackup(temporaryBackup, reservation: reservation) }
            self.temporaryBackup = nil
        }
        if release { try reservation.release(); completed = true }
    }
    private func verifyInstalled(_ files: CatalogRestoreFiles, marker: RestoreMarker, manifest: BackupManifest,
                                 progress: @escaping @Sendable (CatalogRestoreProgress) -> Void) async throws {
        await phase(.verifying, files: files, progress: progress); try await files.verifyInstalled(marker.selected)
        try verifier().verify(directory.appendingPathComponent("catalog.sqlite"), manifest: manifest, progress: inspectorProgress(.verifying, progress))
        try await files.verifyInstalled(marker.selected)
    }
    private func finish(_ files: CatalogRestoreFiles, stage: RestoreFileStage, marker: RestoreMarker,
                        progress: @escaping @Sendable (CatalogRestoreProgress) -> Void) async throws -> CatalogRepository {
        await phase(.removingGrant, files: files, progress: progress); try await files.removeGrant()
        await phase(.clearingMarker, files: files, progress: progress); try await files.finishMarkerRemoval(stage, marker: marker)
        cleaned = true
        await phase(.cleaning, files: files, progress: progress); try await files.discard(stage); retained = nil
        return try await fresh(progress: progress)
    }
    private func fresh(progress: @escaping @Sendable (CatalogRestoreProgress) -> Void) async throws -> CatalogRepository {
        if cleaned, let (stage, _) = retained, let files { try await files.discard(stage); retained = nil }
        progress(CatalogRestoreProgress(phase: .opening))
        if freshCandidate == nil {
            // No marker remains here (recovery finished or none existed); the sweep re-checks before any unlink.
            if sweepsOrphans, live == nil, retained == nil {
                skippedOrphans = DeletionTree.sweepOrphans(directory)
                skippedOrphans += DeletionTree.sweepImportOrphans(cache)
            }
            try Self.restoreLiveWritability(directory)
            freshCandidate = try CatalogRepository(directory: directory, cacheDirectory: cache, reservation: reservation,
                requireExisting: recovered || requireExistingOnFresh || protectedCloseAttempted)
        }
        guard let freshCandidate else { throw CatalogRecoveryError.recoveryRequired }
        try reservation.release(); completed = true; progress(CatalogRestoreProgress(phase: .completed)); return freshCandidate
    }
    /// Installed copies are immutable (0400); the live file returns to owner-writable under the reservation before the
    /// fresh actor applies protection, which on iOS writes the backup exclusion even when unchanged and needs write access.
    /// Absent files are left to creation; non-regular or linked entries are left for the actor's existing guards.
    private static func restoreLiveWritability(_ directory: URL) throws {
        let fd = Darwin.open(directory.appendingPathComponent("catalog.sqlite").path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { if errno == ENOENT || errno == ELOOP { return }; throw RestoreFileError.syscall(errno) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw RestoreFileError.syscall(errno) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_mode & 0o777 != 0o600 else { return }
        guard fchmod(fd, 0o600) == 0 else { throw RestoreFileError.syscall(errno) }
    }
}

#if DEBUG
private final class PreparedMarkerTestFault: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var markerRenamed = false
    func observe(_ event: RestoreFileEvent) throws {
        lock.lock(); defer { lock.unlock() }
        if event.operation == .rename, event.role == .marker, event.moment == .after { markerRenamed = true }
        if !fired, markerRenamed, event.operation == .directorySync, event.role == .root, event.moment == .after {
            fired = true; throw RestoreFileError.syscall(EIO)
        }
    }
}
#endif
