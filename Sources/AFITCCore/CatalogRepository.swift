import Foundation
import SQLite3
import Darwin

/// Protected local SQLite catalog. Each record and its progress share one transaction.
public actor CatalogRepository {
    private struct CacheEntry { var size: Int; var previous: String?; var next: String? }
    private var cacheInventory: [String: CacheEntry]?
    private var cacheHead: String?
    private var cacheTail: String?
    private var cacheBytes = 0
    private(set) var cacheInventoryBuilds = 0
    private var db: OpaquePointer?
    public let directory: URL
    public let cacheDirectory: URL
    public init(directory: URL, cacheDirectory: URL) throws {
        self.directory = directory; self.cacheDirectory = cacheDirectory
        try Self.protect(directory, directory: true)
        try Self.protect(cacheDirectory, directory: true)
        let file = directory.appendingPathComponent("catalog.sqlite")
        // Create the file with protection before SQLite writes any sensitive bytes.
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: Data()) else {
                throw ScanError.database
            }
        }
        try Self.protect(file)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else { if let handle { sqlite3_close(handle) }; throw ScanError.database }
        do {
            try CatalogSchema.execute(handle, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA busy_timeout=1000; PRAGMA foreign_keys=ON;")
            try CatalogSchema.migrate(handle)
            db = handle
            try Self.protectArtifacts(directory)
        } catch { sqlite3_close(handle); throw error }
    }
    deinit { if let db { sqlite3_close(db) } }
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
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: cacheDirectory.path)
        guard let free = attributes[.systemFreeSize] as? NSNumber,
              free.int64Value >= minimumFree else { throw ScanError.storagePressure }
    }
    public func checkpoint() throws -> ScanProgress? {
        guard let db else { throw ScanError.database }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM scan_checkpoint WHERE singleton=1", -1, &statement, nil) == SQLITE_OK else { throw ScanError.database }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try JSONDecoder().decode(ScanProgress.self, from: try Self.blob(statement!, column: 0))
    }
    public func photos() throws -> [PhotoIdentity] {
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
                try CatalogSchema.execute(db, "UPDATE catalog_revision SET revision=revision+1")
            }
            try write("INSERT OR REPLACE INTO scan_checkpoint(singleton,payload) VALUES(1,?)", strings: [], payload: JSONEncoder().encode(progress))
            try CatalogSchema.execute(db, "COMMIT")
            try Self.protectArtifacts(directory)
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
        guard let db else { throw ScanError.database }
        try CatalogSchema.execute(db, "BEGIN IMMEDIATE")
        do {
            try CatalogSchema.execute(db, "UPDATE scan_lease SET generation=generation+1 WHERE singleton=1")
            let generation = try leaseGeneration()
            try CatalogSchema.execute(db, "COMMIT")
            return generation
        } catch { try? CatalogSchema.execute(db, "ROLLBACK"); throw error }
    }
    private func leaseGeneration() throws -> Int {
        guard let db else { throw ScanError.database }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT generation FROM scan_lease WHERE singleton=1", -1, &statement, nil) == SQLITE_OK else { throw ScanError.database }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ScanError.database }
        return Int(sqlite3_column_int(statement, 0))
    }
    public func requireLease(_ lease: Int) throws {
        guard try leaseGeneration() == lease else { throw ScanError.staleLease }
    }
    public func acquireSource(identity: String?, confirmed: Bool) throws -> Int {
        guard let db else { throw ScanError.database }
        try CatalogSchema.execute(db, "BEGIN IMMEDIATE")
        do {
            try bindSource(identity: identity, confirmed: confirmed)
            try CatalogSchema.execute(db, "UPDATE scan_lease SET generation=generation+1 WHERE singleton=1")
            let generation = try leaseGeneration()
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
            if !changed.isEmpty { try CatalogSchema.execute(db, "UPDATE catalog_revision SET revision=revision+1") }
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
    /// Shared derived-data budget; evicted previews are explicitly unavailable offline.
    public func storePreview(_ jpeg: Data, id: UUID, generation: String? = nil, lease: Int? = nil, budget: Int = DecodeLimits.cacheBudget) throws -> String {
        if let lease { try requireLease(lease) }
        guard jpeg.count <= budget else { throw ScanError.storagePressure }
        let name = id.uuidString + (generation.map { "-" + $0 } ?? "") + ".jpg"
        let file = cacheDirectory.appendingPathComponent(name)
        try buildCacheInventoryIfNeeded()
        let replacedBytes = cacheInventory?[name]?.size ?? 0
        while cacheBytes - replacedBytes + jpeg.count > budget, let oldest = oldestOtherThan(name) {
            let url = cacheDirectory.appendingPathComponent(oldest)
            do { try FileManager.default.removeItem(at: url) }
            catch {
                let native = error as NSError
                guard (native.domain == NSCocoaErrorDomain && native.code == NSFileNoSuchFileError) ||
                      (native.domain == NSPOSIXErrorDomain && native.code == Int(ENOENT)) else { throw error }
            }
            removeCacheEntry(oldest)
        }
        do {
            #if os(iOS)
            try jpeg.write(to: file, options: [.atomic, .completeFileProtection])
            #else
            try jpeg.write(to: file, options: .atomic)
            #endif
            try Self.protect(file)
        } catch {
            // A failed atomic write/protection step may change derived disk state.
            // Reconstruct lazily next time rather than trusting stale replacement sizes.
            cacheInventory = nil
            if let error = error as? ScanError { throw error }
            throw Self.writeFailure(error)
        }
        removeCacheEntry(name)
        appendCacheEntry(name, size: jpeg.count)
        return name
    }
    /// One sorted reconstruction per repository lifetime; subsequent writes update linked FIFO state.
    private func buildCacheInventoryIfNeeded() throws {
        guard cacheInventory == nil else { return }
        let files = try FileManager.default.contentsOfDirectory(at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
        var entries: [(String, Int, Date)] = []
        for file in files {
            do {
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                entries.append((file.lastPathComponent, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast))
            } catch {
                let native = error as NSError
                guard native.domain == NSCocoaErrorDomain, native.code == NSFileReadNoSuchFileError else { throw error }
            }
        }
        cacheInventory = [:]; cacheHead = nil; cacheTail = nil; cacheBytes = 0
        for entry in entries.sorted(by: { $0.2 < $1.2 }) { appendCacheEntry(entry.0, size: entry.1) }
        cacheInventoryBuilds += 1
    }
    private func oldestOtherThan(_ replacement: String) -> String? {
        guard let first = cacheHead else { return nil }
        return first == replacement ? cacheInventory?[first]?.next : first
    }
    private func removeCacheEntry(_ name: String) {
        guard let entry = cacheInventory?.removeValue(forKey: name) else { return }
        if let previous = entry.previous { cacheInventory?[previous]?.next = entry.next }
        else { cacheHead = entry.next }
        if let next = entry.next { cacheInventory?[next]?.previous = entry.previous }
        else { cacheTail = entry.previous }
        cacheBytes -= entry.size
    }
    private func appendCacheEntry(_ name: String, size: Int) {
        cacheInventory?[name] = CacheEntry(size: size, previous: cacheTail, next: nil)
        if let previous = cacheTail { cacheInventory?[previous]?.next = name }
        else { cacheHead = name }
        cacheTail = name; cacheBytes += size
    }
    private static func writeFailure(_ error: Error) -> ScanError {
        let native = error as NSError
        if native.domain == NSCocoaErrorDomain, native.code == NSFileWriteOutOfSpaceError { return .storagePressure }
        if native.domain == NSPOSIXErrorDomain, native.code == Int(ENOSPC) { return .storagePressure }
        return .database
    }

    /// All manual reads/writes use this actor-owned connection without suspension in a transaction.
    func peopleRead<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        guard let db else { throw ScanError.database }
        try CatalogSchema.execute(db, "BEGIN")
        do {
            let result = try body(db)
            try CatalogSchema.execute(db, "COMMIT")
            return result
        } catch { try? CatalogSchema.execute(db, "ROLLBACK"); throw error }
    }
    func peopleTransaction<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        guard let db else { throw ScanError.database }
        try CatalogSchema.execute(db, "BEGIN IMMEDIATE")
        do {
            let value = try body(db)
            try CatalogSchema.execute(db, "UPDATE catalog_revision SET revision=revision+1")
            try CatalogSchema.execute(db, "COMMIT")
            return value
        } catch { try? CatalogSchema.execute(db, "ROLLBACK"); throw error }
    }

}
