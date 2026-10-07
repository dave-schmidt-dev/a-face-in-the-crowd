import Foundation
import SQLite3

extension CatalogRepository {
    /// Produces a completed protected package without suspending inside the pinned read.
    public func prepareBackup(progress: @escaping @Sendable (BackupProgress) -> Void = { _ in }) throws -> PreparedCatalogBackup {
        try prepareBackup(progress: progress, options: BackupOptions())
    }
    func prepareBackup(progress: @escaping @Sendable (BackupProgress) -> Void, options: BackupOptions,
                       reservation: CatalogExclusiveReservation? = nil, ownedProtection: OwnedRestoreProtection = .production) throws -> PreparedCatalogBackup {
        if let reservation {
            return try withExclusiveDatabase(reservation) { source in
                try prepareBackupBody(progress: progress, options: options, reservation: reservation, source: source, ownedProtection: ownedProtection)
            }
        }
        let ticket = try operationTicket(); defer { withExtendedLifetime(ticket) {} }
        return try prepareBackupBody(progress: progress, options: options, reservation: nil, source: nil, ownedProtection: ownedProtection)
    }
    private func prepareBackupBody(progress: @escaping @Sendable (BackupProgress) -> Void, options: BackupOptions,
                                   reservation: CatalogExclusiveReservation?, source: OpaquePointer?, ownedProtection: OwnedRestoreProtection) throws -> PreparedCatalogBackup {
        try Task.checkCancellation()
        progress(BackupProgress(operation: .preparing, completed: 0, total: nil))
        let token = UUID()
        let stage = directory.appendingPathComponent("backup-" + token.uuidString, isDirectory: true)
        var completed = false; var owned = false
        var ownership: PreparedBackupOwnership?
        defer { if owned && !completed { try? ownership?.remove() } }
        guard !FileManager.default.fileExists(atPath: stage.path) else { throw BackupError.unsafeStage }
        let stageOwnership = try PreparedBackupOwnership.create(directory: directory, stage: stage, owner: backupOwner, token: token)
        ownership = stageOwnership; owned = true
        try Self.protect(stage, directory: true, ownedProtection: ownedProtection)
        let file = stage.appendingPathComponent("catalog.sqlite")
        guard FileManager.default.createFile(atPath: file.path, contents: Data()) else { throw ScanError.database }
        try stageOwnership.recordFile("catalog.sqlite")
        try Self.protect(file, ownedProtection: ownedProtection)
        let reserved = try reservation.map { try CatalogRootRegistry.shared.beginReserved($0) }
        var destination: OpaquePointer?
        guard sqlite3_open_v2(file.path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let target = destination else {
            if let destination { if sqlite3_close(destination) == SQLITE_OK { reserved?.closed() } }
            else { reserved?.closed() }; throw ScanError.database
        }
        var closed = false
        defer { if !closed, sqlite3_close(target) == SQLITE_OK { reserved?.closed() } }
        try CatalogSchema.execute(target, "PRAGMA synchronous=FULL; PRAGMA journal_mode=DELETE")
        let copy: (OpaquePointer) throws -> Int = { source in
            let revision = try PeopleSQL.scalar(source, "SELECT revision FROM catalog_revision WHERE singleton=1")
            let pages = try PeopleSQL.scalar(source, "PRAGMA page_count")
            let pageSize = try PeopleSQL.scalar(source, "PRAGMA page_size")
            let (estimate, overflow) = pages.multipliedReportingOverflow(by: pageSize)
            guard !overflow else { throw BackupError.limitExceeded }
            try BackupFiles.checkLengths(catalog: estimate, manifest: 0, options: options)
            let space = try FileManager.default.attributesOfFileSystem(forPath: self.directory.path)
            guard let free = space[.systemFreeSize] as? NSNumber, free.int64Value >= Int64(estimate) + Int64(options.manifestLimit) else { throw ScanError.storagePressure }
            try CatalogSchema.incrementalCopy(from: source, to: target, options: options, progress: progress)
            return revision
        }
        let pinnedRevision: Int
        if let source {
            try CatalogSchema.execute(source, "BEGIN")
            do { pinnedRevision = try copy(source); try CatalogSchema.execute(source, "COMMIT") }
            catch { try? CatalogSchema.execute(source, "ROLLBACK"); throw error }
        } else { pinnedRevision = try peopleRead(copy) }
        progress(BackupProgress(operation: .validating, completed: 0, total: nil))
        try Task.checkCancellation()
        if try CatalogSchema.version(target) >= 4 {
            try CatalogSchema.execute(target, """
                PRAGMA secure_delete=ON;
                DELETE FROM face_vectors;
                DELETE FROM photo_analysis_records;
                VACUUM;
            """)
        }
        try BackupFiles.validate(target)
        let (revision, counts) = try BackupFiles.summary(target)
        guard revision == pinnedRevision else { throw ScanError.database }
        guard sqlite3_close(target) == SQLITE_OK else { throw ScanError.database }; closed = true; reserved?.closed()
        for artifact in try FileManager.default.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil) { try Self.protect(artifact, ownedProtection: ownedProtection) }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        try BackupFiles.checkLengths(catalog: size, manifest: 0, options: options)
        let digest = try BackupFiles.digest(file, bytes: size, progress: progress)
        let manifest = BackupManifest(formatVersion: 1, schemaVersion: CatalogSchema.currentVersion,
            createdAt: Date(), revision: revision, counts: counts, catalogBytes: size, catalogSHA256: digest)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        try BackupFiles.checkLengths(catalog: size, manifest: data.count, options: options)
        progress(BackupProgress(operation: .finalising, completed: 0, total: data.count))
        try Task.checkCancellation()
        let manifestFile = stage.appendingPathComponent("manifest.json")
        guard FileManager.default.createFile(atPath: manifestFile.path, contents: Data()) else { throw ScanError.database }
        try stageOwnership.recordFile("manifest.json")
        try Self.protect(manifestFile, ownedProtection: ownedProtection)
        let output = try FileHandle(forWritingTo: manifestFile)
        do { try output.write(contentsOf: data); try output.synchronize(); try output.close() }
        catch { try? output.close(); throw Self.writeFailure(error) }
        for artifact in try FileManager.default.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil) { try Self.protect(artifact, ownedProtection: ownedProtection) }
        try Task.checkCancellation()
        progress(BackupProgress(operation: .finalising, completed: data.count, total: data.count))
        try Task.checkCancellation()
        guard Set(try FileManager.default.contentsOfDirectory(atPath: stage.path)) == ["manifest.json", "catalog.sqlite"] else { throw ScanError.database }
        try stageOwnership.seal()
        preparedBackups[token] = stage; preparedBackupOwnership[token] = stageOwnership; completed = true
        return PreparedCatalogBackup(directory: stage, manifest: manifest, owner: backupOwner, token: token)
    }
    func discardRestoreBackup(_ backup: PreparedCatalogBackup, reservation: CatalogExclusiveReservation) throws {
        try withExclusiveDatabase(reservation) { _ in
            guard backup.owner == backupOwner, preparedBackups[backup.token] == backup.directory else { throw BackupError.unsafeStage }
            guard let ownership = preparedBackupOwnership[backup.token], ownership.owner == backupOwner,
                  ownership.token == backup.token, ownership.stageURL == backup.directory.standardizedFileURL else { throw BackupError.unsafeStage }
            try ownership.remove(); preparedBackups.removeValue(forKey: backup.token); preparedBackupOwnership.removeValue(forKey: backup.token)
        }
    }
    /// Checked restore closure authority only; owns exact stage and does not reopen retired SQLite.
    func discardRetiredRestoreBackup(_ backup: PreparedCatalogBackup, reservation: CatalogExclusiveReservation,
                                    closure: CatalogRestoreRepository.RetiredBackupClosure) throws {
        guard closure.reservation === reservation, closure.ownerID == owner.id,
              reservation.directory == directory, backup.owner == backupOwner,
              preparedBackups[backup.token] == backup.directory else { throw BackupError.unsafeStage }
        guard let ownership = preparedBackupOwnership[backup.token], ownership.owner == backupOwner,
              ownership.token == backup.token, ownership.stageURL == backup.directory.standardizedFileURL else { throw BackupError.unsafeStage }
        try ownership.remove(); preparedBackups.removeValue(forKey: backup.token); preparedBackupOwnership.removeValue(forKey: backup.token)
    }
    /// Removes only this actor's registered stage after its actual close; it uses no SQLite or fence.
    func discardRetiredPreparedBackup(_ backup: PreparedCatalogBackup, proof: CatalogRetiredCloseProof) throws {
        guard let ownership = preparedBackupOwnership[backup.token],
              validatesRetiredCloseProof(proof),
              proof.rootIdentity.identifiesSameObject(as: ownership.parentIdentity),
              backup.owner == backupOwner, preparedBackups[backup.token] == backup.directory,
              ownership.owner == backupOwner, ownership.token == backup.token,
              ownership.stageURL == backup.directory.standardizedFileURL else {
            throw BackupError.unsafeStage
        }
        #if DEBUG
        let gate = preparedBackupCleanupGates.removeValue(forKey: backup.token)
        gate?.pause()
        #endif
        try ownership.remove()
        preparedBackups.removeValue(forKey: backup.token); preparedBackupOwnership.removeValue(forKey: backup.token)
    }

    #if DEBUG
    func failNextPreparedBackupCleanupForTest(_ failure: PreparedBackupCleanupFailure,
                                              backup: PreparedCatalogBackup) throws {
        guard backup.owner == backupOwner, preparedBackups[backup.token] == backup.directory,
              let ownership = preparedBackupOwnership[backup.token] else { throw BackupError.unsafeStage }
        ownership.failNextCleanupForTest(failure)
    }

    func pauseNextPreparedBackupCleanupForTest(_ gate: PreparedBackupCleanupGate,
                                               backup: PreparedCatalogBackup) throws {
        guard backup.owner == backupOwner, preparedBackups[backup.token] == backup.directory,
              preparedBackupOwnership[backup.token] != nil else { throw BackupError.unsafeStage }
        preparedBackupCleanupGates[backup.token] = gate
    }
    #endif

    public func discardBackup(_ backup: PreparedCatalogBackup) throws {
        let ticket = try operationTicket(); defer { withExtendedLifetime(ticket) {} }
        guard backup.owner == backupOwner, preparedBackups[backup.token] == backup.directory else { throw BackupError.unsafeStage }
        guard let ownership = preparedBackupOwnership[backup.token], ownership.owner == backupOwner,
              ownership.token == backup.token, ownership.stageURL == backup.directory.standardizedFileURL else { throw BackupError.unsafeStage }
        try ownership.remove()
        preparedBackups.removeValue(forKey: backup.token); preparedBackupOwnership.removeValue(forKey: backup.token)
    }

}
