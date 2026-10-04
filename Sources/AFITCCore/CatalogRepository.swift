import Foundation
import SQLite3
import Darwin

/// Opaque, in-process proof that this exact actor completed its physical SQLite close.
/// It grants stage-only cleanup and carries no live database or reservation authority.
final class CatalogRetiredCloseProof: @unchecked Sendable {
    let ownerID: UUID
    let backupOwner: UUID
    let rootIdentity: PreparedBackupNodeIdentity
    fileprivate init(ownerID: UUID, backupOwner: UUID, rootIdentity: PreparedBackupNodeIdentity) {
        self.ownerID = ownerID; self.backupOwner = backupOwner; self.rootIdentity = rootIdentity
    }
}

/// Protected local SQLite catalog. Each record and its progress share one transaction.
public actor CatalogRepository {
    private var cachePolicy = CachePolicy()
    private let beforePreviewPublish: (@Sendable () throws -> Void)?
    var cacheInventoryBuilds: Int { cachePolicy.inventoryBuilds }
    private var db: OpaquePointer?
    let backupOwner = UUID()
    var preparedBackups: [UUID: URL] = [:]
    var preparedBackupOwnership: [UUID: PreparedBackupOwnership] = [:]
    #if DEBUG
    var preparedBackupCleanupGates: [UUID: PreparedBackupCleanupGate] = [:]
    #endif
    let owner: CatalogRootRegistry.Owner
    private var retired = false
    public let directory: URL
    public let cacheDirectory: URL
    public init(directory: URL, cacheDirectory: URL) throws {
        try self.init(directory: directory, cacheDirectory: cacheDirectory, reservation: nil)
    }
    /// Fresh replacement construction remains fenced until the explicit capability is released.
    init(directory: URL, cacheDirectory: URL, reservation: CatalogExclusiveReservation?, requireExisting: Bool = false,
         afterReservation: (@Sendable () throws -> Void)? = nil,
         beforePublication: ((OpaquePointer) throws -> Void)? = nil,
         beforePreviewPublish: (@Sendable () throws -> Void)? = nil) throws {
        self.beforePreviewPublish = beforePreviewPublish
        owner = try CatalogRootRegistry.shared.reserve(directory: directory, cache: cacheDirectory, capability: reservation)
        self.directory = URL(fileURLWithPath: owner.root, isDirectory: true)
        self.cacheDirectory = URL(fileURLWithPath: owner.cache, isDirectory: true)
        var opening: OpaquePointer?
        var succeeded = false
        defer {
            if !succeeded {
                if let opening {
                    if sqlite3_close(opening) == SQLITE_OK { CatalogRootRegistry.shared.closed(owner) }
                    else { CatalogRootRegistry.shared.closeFailed(owner) }
                } else { CatalogRootRegistry.shared.closed(owner) }
            }
        }
        try afterReservation?()
        try CatalogRestoreRepository.requireNoMarker(self.directory)
        if requireExisting {
            var info = stat()
            guard lstat(self.directory.appendingPathComponent("catalog.sqlite").path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size > 0 else { throw CatalogRecoveryError.recoveryRequired }
        }
        try Self.protect(self.directory, directory: true)
        try Self.protect(self.cacheDirectory, directory: true)
        let file = self.directory.appendingPathComponent("catalog.sqlite")
        // Create the file with protection before SQLite writes any sensitive bytes.
        if !requireExisting && !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: Data()) else {
                throw ScanError.database
            }
        }
        try Self.protectLiveArtifacts(self.directory)
        guard sqlite3_open_v2(file.path, &opening, SQLITE_OPEN_READWRITE | (requireExisting ? 0 : SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle = opening else { throw ScanError.database }
        do {
            try CatalogSchema.execute(handle, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA busy_timeout=1000; PRAGMA foreign_keys=ON;")
            if requireExisting {
                guard try CatalogSchema.version(handle) == CatalogSchema.currentVersion else { throw ScanError.unsupportedSchema }
            } else { try CatalogSchema.migrate(handle) }
            try Self.protectLiveArtifacts(self.directory)
            try beforePublication?(handle)
            db = handle
            CatalogRootRegistry.shared.opened(owner)
            succeeded = true
        } catch { throw error }
    }
    deinit {
        // SQLITE_BUSY leaves registration behind, blocking unsafe reuse of the root.
        if let db {
            if sqlite3_close(db) == SQLITE_OK { CatalogRootRegistry.shared.closed(owner) }
            else { CatalogRootRegistry.shared.closeFailed(owner) }
        }
    }
    func operationTicket() throws -> CatalogOperationTicket {
        guard !retired else { throw CatalogLifetimeError.retired }
        return try CatalogRootRegistry.shared.begin(owner)
    }
    func validatesRetiredCloseProof(_ proof: CatalogRetiredCloseProof) -> Bool {
        retired && db == nil && proof.ownerID == owner.id && proof.backupOwner == backupOwner
    }
    func reserveExclusive() throws -> CatalogExclusiveReservation {
        guard !retired else { throw CatalogLifetimeError.retired }
        return try CatalogRootRegistry.shared.exclusive(owner)
    }
    /// Terminal before attempting physical closure. A busy handle retains the root fence.
    @discardableResult
    func retire(using reservation: CatalogExclusiveReservation) throws -> CatalogRetiredCloseProof {
        try CatalogRootRegistry.shared.validate(reservation, owner: owner, retire: true)
        retired = true
        // Bind proof to the existing root before close so a later path substitution is never adopted.
        let rootIdentity = try PreparedBackupOwnership.captureDirectory(directory)
        if let db {
            guard sqlite3_close(db) == SQLITE_OK else { throw CatalogLifetimeError.closeBusy }
            self.db = nil
        }
        CatalogRootRegistry.shared.closed(owner)
        return CatalogRetiredCloseProof(ownerID: owner.id, backupOwner: backupOwner, rootIdentity: rootIdentity)
    }
    /// Synchronous C2/test seam; never makes ordinary admissions privileged.
    func withExclusiveDatabase<T>(_ reservation: CatalogExclusiveReservation,
                                  _ body: (OpaquePointer) throws -> T) throws -> T {
        guard !retired else { throw CatalogLifetimeError.retired }
        let ticket = try CatalogRootRegistry.shared.beginPrivileged(reservation, owner: owner)
        defer { withExtendedLifetime(ticket) {} }
        guard let db else { throw ScanError.database }
        return try body(db)
    }
    func exclusiveRead<T>(_ reservation: CatalogExclusiveReservation, _ body: (OpaquePointer) throws -> T) throws -> T {
        try withExclusiveDatabase(reservation) { db in
            try CatalogSchema.execute(db, "BEGIN")
            do { let result = try body(db); try CatalogSchema.execute(db, "COMMIT"); return result }
            catch { try? CatalogSchema.execute(db, "ROLLBACK"); throw error }
        }
    }
    public static func protect(_ url: URL, directory: Bool = false) throws {
        if directory { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        var value = url
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try value.setResourceValues(resources)
        try FileManager.default.setAttributes([.posixPermissions: directory ? 0o700 : 0o600], ofItemAtPath: url.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
        guard try excludedFromBackup(url) else { throw ScanError.database }
    }
    /// Only callers owning newly created restore/backup outputs may select this internal policy.
    static func protect(_ url: URL, directory: Bool = false, ownedProtection: OwnedRestoreProtection,
                        descriptor: Int32? = nil) throws {
        if ownedProtection == .foundation { try protect(url, directory: directory); return }
        #if os(macOS)
        if directory { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try ownedProtection.apply(url, directory: directory, descriptor: descriptor)
        #else
        try protect(url, directory: directory)
        #endif
    }
    /// macOS temp fixtures expose the actual backup exclusion xattr; iPad uses its URL contract.
    public static func excludedFromBackup(_ url: URL) throws -> Bool {
        #if os(iOS)
        return try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
        #else
        let name = "com.apple.metadata:com_apple_backup_excludeItem"
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0, size <= 1024 else { return false }
        var bytes = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, name, &bytes, size, 0, 0) == size else { return false }
        return try PropertyListSerialization.propertyList(from: Data(bytes), format: nil) as? String == "com.apple.backupd"
        #endif
    }
    public static func protectArtifacts(_ directory: URL) throws {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) {
            try protect(url, directory: (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true)
        }
    }
    /// Ordinary catalog operations protect only live files, never immutable owned packages.
    private static func protectLiveArtifacts(_ directory: URL) throws {
        for name in ["catalog.sqlite", "catalog.sqlite-journal", "catalog.sqlite-wal", "catalog.sqlite-shm", "source.bookmark"] {
            let url = directory.appendingPathComponent(name)
            var info = stat()
            if lstat(url.path, &info) != 0 {
                if errno == ENOENT { continue }; throw ScanError.database
            }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw ScanError.database }
            try protect(url)
        }
    }
    public static let maximumGrantBytes = 1024 * 1024
    public struct ResolvedGrant: Sendable {
        public let url: URL
        public let stale: Bool
    }
    /// Resolve only owned protected bookmark bytes; never starts source access or scanning.
    public static func resolveGrant(_ data: Data) throws -> ResolvedGrant {
        guard !data.isEmpty, data.count <= maximumGrantBytes else { throw ScanError.denied }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                relativeTo: nil, bookmarkDataIsStale: &stale)
            guard url.isFileURL else { throw ScanError.denied }
            return ResolvedGrant(url: url, stale: stale)
        } catch { throw ScanError.denied }
    }
    public func loadGrant() throws -> Data? {
        let ticket = try operationTicket(); defer { withExtendedLifetime(ticket) {} }
        let file = directory.appendingPathComponent("source.bookmark")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= Self.maximumGrantBytes else { throw ScanError.denied }
        try Self.protect(file)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumGrantBytes + 1) ?? Data()
        guard data.count == size, data.count <= Self.maximumGrantBytes else { throw ScanError.denied }
        return data
    }
    public func storeGrant(_ data: Data, lease: Int? = nil) throws {
        let ticket = try operationTicket(); defer { withExtendedLifetime(ticket) {} }
        guard !data.isEmpty, data.count <= Self.maximumGrantBytes else { throw ScanError.denied }
        if let lease { try requireLease(lease) }
        let file = directory.appendingPathComponent("source.bookmark")
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        try Self.protect(file)
    }
    public func checkStorage(minimumFree: Int = 64 * 1024 * 1024) throws {
        let ticket = try operationTicket(); defer { withExtendedLifetime(ticket) {} }
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: cacheDirectory.path)
        guard let free = attributes[.systemFreeSize] as? NSNumber,
              free.int64Value >= minimumFree else { throw ScanError.storagePressure }
    }
    public func checkpoint() throws -> ScanProgress? {
        let ticket = try operationTicket(); defer { withExtendedLifetime(ticket) {} }
        guard let db else { throw ScanError.database }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM scan_checkpoint WHERE singleton=1", -1, &statement, nil) == SQLITE_OK else { throw ScanError.database }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try JSONDecoder().decode(ScanProgress.self, from: try Self.blob(statement!, column: 0))
    }
    public func photos() throws -> [PhotoIdentity] {
        let ticket = try operationTicket(); defer { withExtendedLifetime(ticket) {} }
        guard let db else { throw ScanError.database }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM photos ORDER BY rowid", -1, &statement, nil) == SQLITE_OK else { throw ScanError.database }
        defer { sqlite3_finalize(statement) }
        var photos: [PhotoIdentity] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            photos.append(try JSONDecoder().decode(PhotoIdentity.self, from: try Self.blob(statement!, column: 0)))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw ScanError.database }
        return photos
    }
    private static func blob(_ statement: OpaquePointer, column: Int32) throws -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB, count > 0,
              let bytes = sqlite3_column_blob(statement, column) else { throw ScanError.database }
        return Data(bytes: bytes, count: count)
    }
    public func save(_ photo: PhotoIdentity? = nil, progress: ScanProgress, lease: Int? = nil) throws {
        let ticket = try operationTicket(); defer { withExtendedLifetime(ticket) {} }
        guard let db else { throw ScanError.database }
        try CatalogSchema.execute(db, "BEGIN IMMEDIATE")
        do {
            if let lease { try requireLease(lease) }
            if let photo {
                if let stored = try storedPhoto(photo.id), stored.contentVersion > photo.contentVersion {
                    throw ScanError.staleLease
                }
                try write("INSERT INTO photos(id,path,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload WHERE photos.path=excluded.path", strings: [photo.id.uuidString, photo.relativePath], payload: JSONEncoder().encode(photo))
                try PeopleSQL.syncPhoto(db, photo)
                try CatalogCounters.advance(db, .revision)
            }
            try write("INSERT OR REPLACE INTO scan_checkpoint(singleton,payload) VALUES(1,?)", strings: [], payload: JSONEncoder().encode(progress))
            try CatalogSchema.execute(db, "COMMIT")
            try Self.protectLiveArtifacts(directory)
        } catch { try? CatalogSchema.execute(db, "ROLLBACK"); throw error }
    }
    /// Read-only original eligibility. A present, explicitly bound nil identity is distinct from no binding.
    /// Call again with the actual byte hash after coordinated source IO.
    public func validateViewerPhoto(_ captured: PhotoIdentity, sourceIdentity: String?,
                                    verifiedContentHash: String? = nil) throws {
        try peopleRead { db in
            guard let hash = captured.contentHash, !hash.isEmpty,
                  let current = try storedPhoto(captured.id), current.id == captured.id, current.missing != true,
                  current.contentVersion == captured.contentVersion,
                  current.relativePath == captured.relativePath, current.contentHash == hash,
                  verifiedContentHash == nil || verifiedContentHash == hash else { throw ScanError.unavailable }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT payload FROM source_binding WHERE singleton=1", -1, &statement, nil) == SQLITE_OK else { throw ScanError.database }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw ScanError.unavailable }
            let bound = try JSONDecoder().decode(String?.self, from: Self.blob(statement!, column: 0))
            guard bound == sourceIdentity else { throw ScanError.unavailable }
        }
    }
    private func storedPhoto(_ id: UUID) throws -> PhotoIdentity? {
        guard let db else { throw ScanError.database }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM photos WHERE id=?", -1, &statement, nil) == SQLITE_OK else { throw ScanError.database }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, id.uuidString, -1, transient) == SQLITE_OK else { throw ScanError.database }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw ScanError.database }
        return try JSONDecoder().decode(PhotoIdentity.self, from: try Self.blob(statement!, column: 0))
    }
    /// Every scan claims a new durable generation; stale coordinators cannot commit.
    public func claimLease() throws -> Int {
        let ticket = try operationTicket(); defer { withExtendedLifetime(ticket) {} }
        guard let db else { throw ScanError.database }
        try CatalogSchema.execute(db, "BEGIN IMMEDIATE")
        do {
            let generation = try CatalogCounters.advance(db, .lease)
            try CatalogSchema.execute(db, "COMMIT")
            return generation
        } catch { try? CatalogSchema.execute(db, "ROLLBACK"); throw error }
    }
    private func leaseGeneration() throws -> Int {
        guard let db else { throw ScanError.database }
        return try CatalogCounters.read(db, .lease)
    }
    public func requireLease(_ lease: Int) throws {
        let ticket = try operationTicket(); defer { withExtendedLifetime(ticket) {} }
        guard try leaseGeneration() == lease else { throw ScanError.staleLease }
    }
    public func acquireSource(identity: String?, confirmed: Bool) throws -> Int {
        let ticket = try operationTicket(); defer { withExtendedLifetime(ticket) {} }
        guard let db else { throw ScanError.database }
        try CatalogSchema.execute(db, "BEGIN IMMEDIATE")
        do {
            try bindSource(identity: identity, confirmed: confirmed)
            let generation = try CatalogCounters.advance(db, .lease)
            try CatalogSchema.execute(db, "COMMIT")
            return generation
        } catch { try? CatalogSchema.execute(db, "ROLLBACK"); throw error }
    }
    private func bindSource(identity: String?, confirmed: Bool) throws {
        guard let db else { throw ScanError.database }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM source_binding WHERE singleton=1", -1, &statement, nil) == SQLITE_OK else { throw ScanError.database }
        defer { sqlite3_finalize(statement) }
        let exists = sqlite3_step(statement) == SQLITE_ROW
        let previous = exists ? try JSONDecoder().decode(String?.self, from: try Self.blob(statement!, column: 0)) : nil
        let hasRecords = try !photos().isEmpty
        if exists || hasRecords {
            guard (identity != nil && previous == identity) || confirmed else { throw ScanError.sourceConfirmationRequired }
        }
        try write("INSERT OR REPLACE INTO source_binding(singleton,payload) VALUES(1,?)", strings: [], payload: JSONEncoder().encode(identity))
    }
    public func markMissing(except paths: Set<String>, progress: ScanProgress, lease: Int) throws -> [PhotoIdentity] {
        let ticket = try operationTicket(); defer { withExtendedLifetime(ticket) {} }
        guard let db else { throw ScanError.database }
        try CatalogSchema.execute(db, "BEGIN IMMEDIATE")
        do {
            try requireLease(lease)
            var changed: [PhotoIdentity] = []
            for var photo in try photos() where !paths.contains(photo.relativePath) {
                photo.missing = true
                try write("UPDATE photos SET payload=? WHERE id='\(photo.id.uuidString)'", strings: [], payload: JSONEncoder().encode(photo))
                try PeopleSQL.syncPhoto(db, photo)
                changed.append(photo)
            }
            try write("INSERT OR REPLACE INTO scan_checkpoint(singleton,payload) VALUES(1,?)", strings: [], payload: JSONEncoder().encode(progress))
            if !changed.isEmpty { try CatalogCounters.advance(db, .revision) }
            try CatalogSchema.execute(db, "COMMIT")
            return changed
        } catch { try? CatalogSchema.execute(db, "ROLLBACK"); throw error }
    }
    private func write(_ sql: String, strings: [String], payload: Data) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw ScanError.database }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, string) in strings.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), string, -1, transient) == SQLITE_OK else { throw ScanError.database }
        }
        let bound = payload.withUnsafeBytes { sqlite3_bind_blob(statement, Int32(strings.count + 1), $0.baseAddress, Int32(payload.count), transient) }
        guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw CatalogSchema.failure(db!) }
    }
    /// Test whether a catalog reference points to one bounded, canonical owned preview.
    public func previewIsAvailable(_ name: String?, for id: UUID) throws -> Bool {
        let ticket = try operationTicket(); defer { withExtendedLifetime(ticket) {} }
        return try cachePolicy.previewIsAvailable(name, for: id, in: cacheDirectory)
    }
    /// Remove only canonical, app-owned preview files. Catalog rows and source grants are untouched.
    @discardableResult
    public func clearDerivedCache() throws -> Int {
        let ticket = try operationTicket(); defer { withExtendedLifetime(ticket) {} }
        guard let db else { throw ScanError.database }
        try CatalogSchema.execute(db, "BEGIN IMMEDIATE")
        do {
            let removed = try cachePolicy.clearOwnedPreviews(in: cacheDirectory)
            try CatalogSchema.execute(db, "COMMIT")
            return removed
        } catch {
            cachePolicy.invalidate()
            try? CatalogSchema.execute(db, "ROLLBACK")
            throw error
        }
    }
    /// Reserve physical old + staged-new bytes under the shared derived-preview limit.
    public func storePreview(_ jpeg: Data, id: UUID, generation: String? = nil, lease: Int? = nil,
                             budget: Int = DecodeLimits.cacheBudget) throws -> String {
        let ticket = try operationTicket(); defer { withExtendedLifetime(ticket) {} }
        guard let db else { throw ScanError.database }
        try CatalogSchema.execute(db, "BEGIN IMMEDIATE")
        do {
            if let lease { try requireLease(lease) }
            let name = try cachePolicy.store(jpeg, id: id, generation: generation, in: cacheDirectory,
                budget: budget, beforePublish: beforePreviewPublish,
                validateLease: { if let lease { try self.requireLease(lease) } },
                protect: { try Self.protect($0) })
            try CatalogSchema.execute(db, "COMMIT")
            return name
        } catch {
            cachePolicy.invalidate()
            try? CatalogSchema.execute(db, "ROLLBACK")
            if error is CancellationError || error is CatalogLifetimeError { throw error }
            if let scanError = error as? ScanError { throw scanError }
            throw Self.writeFailure(error)
        }
    }
    static func writeFailure(_ error: Error) -> ScanError {
        let native = error as NSError
        if native.domain == NSCocoaErrorDomain, native.code == NSFileWriteOutOfSpaceError { return .storagePressure }
        if native.domain == NSPOSIXErrorDomain, native.code == Int(ENOSPC) { return .storagePressure }
        return .database
    }

    /// All manual reads/writes use this actor-owned connection without suspension in a transaction.
    func peopleRead<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        let ticket = try operationTicket(); defer { withExtendedLifetime(ticket) {} }
        guard let db else { throw ScanError.database }
        try CatalogSchema.execute(db, "BEGIN")
        do {
            let result = try body(db)
            try CatalogSchema.execute(db, "COMMIT")
            return result
        } catch { try? CatalogSchema.execute(db, "ROLLBACK"); throw error }
    }
    func peopleTransaction<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        let ticket = try operationTicket(); defer { withExtendedLifetime(ticket) {} }
        guard let db else { throw ScanError.database }
        try CatalogSchema.execute(db, "BEGIN IMMEDIATE")
        do {
            let nextRevision = try CatalogCounters.successor(CatalogCounters.read(db, .revision))
            let value = try body(db)
            try CatalogCounters.set(db, .revision, nextRevision)
            try CatalogSchema.execute(db, "COMMIT")
            return value
        } catch { try? CatalogSchema.execute(db, "ROLLBACK"); throw error }
    }

}
