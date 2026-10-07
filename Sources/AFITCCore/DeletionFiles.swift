import Foundation
import Darwin

/// Fixed fault positions; no product-selectable failure injection or sensitive logging.
enum DeletionFileFault: Sendable, Equatable { case beforeUnlink(Int), afterUnlink(Int), directorySync(Int) }
final class DeletionFiles: @unchecked Sendable {
    private struct Entry {
        let name: String
        let device: dev_t
        let inode: ino_t
        let size: off_t
    }
    private let root: URL
    private let cache: URL
    private let rootFD: Int32
    private let cacheFD: Int32
    private let rootIdentity: stat
    private let cacheIdentity: stat
    private let preservedPackages: Set<String>
    private var entries: [(Bool, Entry)] = []
    /// App-owned leftover trees and temporaries, erased only after every original entry.
    private var trees: [(Bool, DeletionTree)] = []
    private var removed = Set<Int>()
    private var started = false
    private static let live = Set(["source.bookmark", "catalog.sqlite", "catalog.sqlite-journal", "catalog.sqlite-wal", "catalog.sqlite-shm"])
    private static let diagnostics = "Diagnostics"
    init(directory: URL, cache: URL, photoIDs: Set<UUID>, preservedPackages: Set<String>) throws {
        root = directory; self.cache = cache; self.preservedPackages = preservedPackages
        rootFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw DeletionError.syscall(errno) }
        cacheFD = Darwin.open(cache.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard cacheFD >= 0 else { Darwin.close(rootFD); throw DeletionError.syscall(errno) }
        var a = stat(), b = stat()
        guard fstat(rootFD, &a) == 0, fstat(cacheFD, &b) == 0 else {
            Darwin.close(rootFD); Darwin.close(cacheFD); throw DeletionError.syscall(errno)
        }
        rootIdentity = a; cacheIdentity = b
        do {
            try validateRoots()
            let rootNames = try names(directory)
            guard rootNames.contains("catalog.sqlite") else { throw DeletionError.unsafeEntry }
            var rootExtras: [(Bool, Entry)] = []
            for name in rootNames.subtracting(Self.live).subtracting(preservedPackages).sorted() {
                let url = directory.appendingPathComponent(name)
                if name == Self.diagnostics {
                    // Removed by its own owner before erase; erase still refuses it if present.
                    var info = stat()
                    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw DeletionError.unsafeEntry }
                    continue
                }
                switch DeletionTree.rootKind(name) {
                case .file?: rootExtras.append((false, try Self.entry(url)))
                case .directory(let shape)?:
                    let tree = try DeletionTree.capture(url, shape: shape)
                    // A stage registered by a live prepared-backup owner is never adopted unless preserved.
                    guard shape != .backupStage || !PreparedStageRegistry.shared.contains(device: tree.device, inode: tree.inode) else { throw DeletionError.unsafeEntry }
                    trees.append((false, tree))
                case nil: throw DeletionError.unsafeEntry
                }
            }
            for name in preservedPackages {
                guard name.hasPrefix("backup-"), UUID(uuidString: String(name.dropFirst(7))) != nil else { throw DeletionError.unsafeEntry }
                var info = stat()
                guard fstatat(rootFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw DeletionError.unsafeEntry }
                let url = directory.appendingPathComponent(name)
                guard try names(url) == Set(["manifest.json", "catalog.sqlite"]) else { throw DeletionError.unsafeEntry }
                for child in ["manifest.json", "catalog.sqlite"] { _ = try Self.entry(url.appendingPathComponent(child)) }
            }
            let rootEntries = try rootNames.intersection(Self.live).sorted().map { (false, try Self.entry(directory.appendingPathComponent($0))) } + rootExtras
            var cacheEntries: [(Bool, Entry)] = []
            for name in try names(cache).sorted() {
                let url = cache.appendingPathComponent(name)
                if name == DeletionTree.importRoot { trees.append((true, try DeletionTree.capture(url, shape: .importRoot))); continue }
                // Stale previews (for example after restoring an older backup) still use the exact owned grammar.
                guard Self.ownedJPEG(name, photoIDs: photoIDs) || Self.stalePreview(name) || CachePolicy.ownsStageFile(named: name) else { throw DeletionError.unsafeEntry }
                cacheEntries.append((true, try Self.entry(url)))
            }
            // Grant first, then DB/sidecars, then exactly validated derived files.
            entries = rootEntries.sorted { ($0.1.name == "source.bookmark" ? 0 : 1) < ($1.1.name == "source.bookmark" ? 0 : 1) } + cacheEntries
        } catch { Darwin.close(rootFD); Darwin.close(cacheFD); throw error }
    }
    deinit { Darwin.close(rootFD); Darwin.close(cacheFD) }
    private static func ownedJPEG(_ name: String, photoIDs: Set<UUID>) -> Bool {
        guard name.hasSuffix(".jpg"), name.utf8.count <= 160 else { return false }
        let stem = String(name.dropLast(4)); guard stem.count >= 36 else { return false }
        let prefix = String(stem.prefix(36))
        guard let id = UUID(uuidString: prefix), prefix == id.uuidString, photoIDs.contains(id) else { return false }
        let suffix = String(stem.dropFirst(36))
        return suffix.isEmpty || (suffix.first == "-" && suffix.dropFirst().split(separator: "-", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } })
    }
    private static func stalePreview(_ name: String) -> Bool {
        guard CachePolicy.ownsPreviewFile(named: name), name.count >= 36 else { return false }
        let prefix = String(name.prefix(36))
        return UUID(uuidString: prefix)?.uuidString == prefix
    }
    private func names(_ url: URL) throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: url.path)) }
    private static func entry(_ url: URL) throws -> Entry {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size >= 0 else { throw DeletionError.unsafeEntry }
        return Entry(name: url.lastPathComponent, device: info.st_dev, inode: info.st_ino, size: info.st_size)
    }
    private func validateRoots() throws {
        for (url, fd, original) in [(root, rootFD, rootIdentity), (cache, cacheFD, cacheIdentity)] {
            var path = stat(), handle = stat()
            guard lstat(url.path, &path) == 0, fstat(fd, &handle) == 0,
                  path.st_mode & S_IFMT == S_IFDIR, path.st_dev == original.st_dev, path.st_ino == original.st_ino,
                  handle.st_dev == path.st_dev, handle.st_ino == path.st_ino else { throw DeletionError.changedEntry }
        }
    }
    func erase(progress: @Sendable (DeletionProgress) -> Void, fault: DeletionFileFault?) throws {
        try Task.checkCancellation(); try validateRoots(); try CatalogRestoreRepository.requireNoMarker(root)
        let knownRoot = Set(entries.filter { !$0.0 }.map { $0.1.name } + trees.filter { !$0.0 }.map { $0.1.name }).union(preservedPackages)
        let knownCache = Set(entries.filter { $0.0 }.map { $0.1.name } + trees.filter { $0.0 }.map { $0.1.name })
        guard try names(root).isSubset(of: knownRoot), try names(cache).isSubset(of: knownCache) else { throw DeletionError.unsafeEntry }
        // SQLite may remove its own journal while closing. Catalog bytes may change until close.
        if !started {
            entries = try entries.compactMap { derived, old in
                let url = (derived ? cache : root).appendingPathComponent(old.name)
                var info = stat()
                if lstat(url.path, &info) != 0 { guard errno == ENOENT, !derived, old.name != "catalog.sqlite" else { throw DeletionError.changedEntry }; return nil }
                let fresh = try Self.entry(url)
                guard fresh.device == old.device, fresh.inode == old.inode else { throw DeletionError.changedEntry }
                return (derived, fresh)
            }; started = true
        }
        let total = entries.count + trees.count
        progress(DeletionProgress(completed: removed.count, total: total))
        for (index, pair) in entries.enumerated() where !removed.contains(index) {
            try Task.checkCancellation(); try validateRoots()
            let (derived, entry) = pair, fd = derived ? cacheFD : rootFD
            if fault == .beforeUnlink(index) { throw DeletionError.injectedFailure }
            var info = stat()
            let status = fstatat(fd, entry.name, &info, AT_SYMLINK_NOFOLLOW)
            if status == 0 {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                      info.st_dev == entry.device, info.st_ino == entry.inode, info.st_size == entry.size else { throw DeletionError.changedEntry }
                guard unlinkat(fd, entry.name, 0) == 0 else { throw DeletionError.syscall(errno) }
            } else { guard errno == ENOENT else { throw DeletionError.syscall(errno) } }
            if fault == .afterUnlink(index) { throw DeletionError.injectedFailure }
            if fault == .directorySync(index) { throw DeletionError.syscall(EIO) }
            guard fsync(fd) == 0 else { throw DeletionError.syscall(errno) }
            removed.insert(index); progress(DeletionProgress(completed: removed.count, total: total))
        }
        for (offset, pair) in trees.enumerated() where !removed.contains(entries.count + offset) {
            let index = entries.count + offset
            try Task.checkCancellation(); try validateRoots()
            let fd = pair.0 ? cacheFD : rootFD
            if fault == .beforeUnlink(index) { throw DeletionError.injectedFailure }
            try DeletionTree.remove(pair.1, in: fd)
            if fault == .afterUnlink(index) { throw DeletionError.injectedFailure }
            if fault == .directorySync(index) { throw DeletionError.syscall(EIO) }
            guard fsync(fd) == 0 else { throw DeletionError.syscall(errno) }
            removed.insert(index); progress(DeletionProgress(completed: removed.count, total: total))
        }
        // A removed entry reappearing is never silently adopted on a retry.
        guard try names(root) == preservedPackages, try names(cache).isEmpty else { throw DeletionError.changedEntry }
    }
    static func removeGrant(_ root: URL) throws {
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw DeletionError.syscall(errno) }; defer { Darwin.close(fd) }
        var info = stat()
        if fstatat(fd, "source.bookmark", &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw DeletionError.syscall(errno) }; return
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw DeletionError.unsafeEntry }
        guard unlinkat(fd, "source.bookmark", 0) == 0, fsync(fd) == 0 else { throw DeletionError.syscall(errno) }
    }
}

/// Exact app-owned leftover grammar (crash-orphaned restore/backup stages, marker and import staging).
/// Every node is no-follow, identity-captured, and regular single-link or an expected directory.
struct DeletionTree {
    enum Shape: Equatable { case backupStage, restoreStage, restoreSlot, importRoot, importStage }
    enum Kind: Equatable { case file, directory(Shape) }
    static let importRoot = "CatalogImport"
    let name: String
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let children: [DeletionTree]?

    static func canonical(_ name: String, prefix: String, suffix: String) -> Bool {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count == prefix.count + 36 + suffix.count else { return false }
        let text = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        return UUID(uuidString: text)?.uuidString == text
    }
    static func rootKind(_ name: String) -> Kind? {
        if canonical(name, prefix: "marker-", suffix: ".tmp") { return .file }
        if canonical(name, prefix: "backup-", suffix: "") { return .directory(.backupStage) }
        if canonical(name, prefix: "restore-", suffix: "") { return .directory(.restoreStage) }
        return nil
    }
    static func childKind(_ shape: Shape, _ name: String) -> Kind? {
        switch shape {
        case .backupStage: return ["catalog.sqlite", "manifest.json", "catalog.sqlite-journal"].contains(name) ? .file : nil
        case .restoreStage:
            if name == "old" || name == "new" { return .directory(.restoreSlot) }
            return name == "install.sqlite" || canonical(name, prefix: "recover-", suffix: ".sqlite") ? .file : nil
        case .restoreSlot:
            return ["catalog.sqlite", "manifest.json", "catalog.sqlite-journal"].contains(name) || canonical(name, prefix: "manifest-", suffix: ".tmp") ? .file : nil
        case .importRoot: return canonical(name, prefix: "", suffix: "") ? .directory(.importStage) : nil
        case .importStage: return ["catalog.sqlite", "manifest.json"].contains(name) ? .file : nil
        }
    }
    static func capture(_ url: URL, kind: Kind) throws -> DeletionTree {
        guard case .directory(let shape) = kind else {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size >= 0 else { throw DeletionError.unsafeEntry }
            return DeletionTree(name: url.lastPathComponent, device: info.st_dev, inode: info.st_ino, size: info.st_size, children: nil)
        }
        return try capture(url, shape: shape)
    }
    static func capture(_ url: URL, shape: Shape) throws -> DeletionTree {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw DeletionError.unsafeEntry }
        var children: [DeletionTree] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
            guard let kind = childKind(shape, name) else { throw DeletionError.unsafeEntry }
            children.append(try capture(url.appendingPathComponent(name), kind: kind))
        }
        return DeletionTree(name: url.lastPathComponent, device: info.st_dev, inode: info.st_ino, size: 0, children: children)
    }
    static func listing(_ fd: Int32) throws -> Set<String> {
        let copy = dup(fd); guard copy >= 0 else { throw DeletionError.syscall(errno) }
        guard let dir = fdopendir(copy) else { Darwin.close(copy); throw DeletionError.syscall(errno) }
        defer { closedir(dir) }; rewinddir(dir); var values = Set<String>()
        while true {
            errno = 0
            guard let entry = readdir(dir) else { guard errno == 0 else { throw DeletionError.syscall(errno) }; return values }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { values.insert(name) }
        }
    }
    /// Identity-checked removal; an already absent node at any level counts as removed.
    static func remove(_ node: DeletionTree, in parent: Int32) throws {
        var info = stat()
        if fstatat(parent, node.name, &info, AT_SYMLINK_NOFOLLOW) != 0 { guard errno == ENOENT else { throw DeletionError.syscall(errno) }; return }
        guard info.st_dev == node.device, info.st_ino == node.inode else { throw DeletionError.changedEntry }
        guard let children = node.children else {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size == node.size else { throw DeletionError.changedEntry }
            guard unlinkat(parent, node.name, 0) == 0 else { throw DeletionError.syscall(errno) }
            return
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw DeletionError.changedEntry }
        let fd = openat(parent, node.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw DeletionError.syscall(errno) }; defer { Darwin.close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == node.device, opened.st_ino == node.inode else { throw DeletionError.changedEntry }
        guard try listing(fd).isSubset(of: Set(children.map(\.name))) else { throw DeletionError.unsafeEntry }
        for child in children { try remove(child, in: fd) }
        guard fsync(fd) == 0 else { throw DeletionError.syscall(errno) }
        guard unlinkat(parent, node.name, AT_REMOVEDIR) == 0 else { throw DeletionError.syscall(errno) }
    }
    /// Startup-only sweep under the startup reservation. Never runs while a restore marker exists and never
    /// touches a backup stage registered by a live prepared-backup owner. Unrecognised shapes are left alone.
    /// Returns how many recognised leftovers failed capture or removal; the count carries no names or paths.
    @discardableResult static func sweepOrphans(_ root: URL) -> Int {
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return 0 }; defer { Darwin.close(fd) }
        var marker = stat()
        guard fstatat(fd, "restore-marker.json", &marker, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT,
              let names = try? listing(fd) else { return 0 }
        var changed = false, skipped = 0
        for name in names.sorted() {
            guard let kind = rootKind(name) else { continue }
            guard let node = try? capture(root.appendingPathComponent(name), kind: kind) else { skipped += 1; continue }
            if kind == .directory(.backupStage), PreparedStageRegistry.shared.contains(device: node.device, inode: node.inode) { continue }
            if (try? remove(node, in: fd)) != nil { changed = true } else { skipped += 1 }
        }
        if changed { _ = fsync(fd) }
        return skipped
    }
    /// Startup-only sweep of crash-orphaned import stages under the cache's CatalogImport root. Never
    /// touches a stage registered by a live validating owner and never removes the root itself.
    /// Unrecognised shapes are left alone. Returns how many recognised leftovers failed capture or
    /// removal; the count carries no names or paths.
    @discardableResult static func sweepImportOrphans(_ cache: URL) -> Int {
        let root = cache.appendingPathComponent(importRoot, isDirectory: true)
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return 0 }; defer { Darwin.close(fd) }
        guard let names = try? listing(fd) else { return 0 }
        var changed = false, skipped = 0
        for name in names.sorted() {
            guard childKind(.importRoot, name) == .directory(.importStage) else { continue }
            guard let node = try? capture(root.appendingPathComponent(name, isDirectory: true), kind: .directory(.importStage)) else { skipped += 1; continue }
            if ImportStageRegistry.shared.contains(device: node.device, inode: node.inode) { continue }
            if (try? remove(node, in: fd)) != nil { changed = true } else { skipped += 1 }
        }
        if changed { _ = fsync(fd) }
        return skipped
    }
}

/// Process-wide identities of backup stages whose prepared owner is still alive.
final class PreparedStageRegistry: @unchecked Sendable {
    static let shared = PreparedStageRegistry()
    private let lock = NSLock()
    private var live: [String: Int] = [:]
    private static func key(_ device: Int64, _ inode: UInt64) -> String { "\(device):\(inode)" }
    func register(device: Int64, inode: UInt64) {
        lock.lock(); defer { lock.unlock() }; live[Self.key(device, inode), default: 0] += 1
    }
    func unregister(device: Int64, inode: UInt64) {
        lock.lock(); defer { lock.unlock() }
        let key = Self.key(device, inode)
        if let count = live[key], count > 1 { live[key] = count - 1 } else { live.removeValue(forKey: key) }
    }
    func contains(device: dev_t, inode: ino_t) -> Bool {
        lock.lock(); defer { lock.unlock() }; return live[Self.key(Int64(device), UInt64(inode))] != nil
    }
}

/// Process-wide identities of import stages whose validating owner is still alive.
final class ImportStageRegistry: @unchecked Sendable {
    static let shared = ImportStageRegistry()
    private let lock = NSLock()
    private var live: [String: Int] = [:]
    private static func key(_ device: Int64, _ inode: UInt64) -> String { "\(device):\(inode)" }
    func register(device: Int64, inode: UInt64) {
        lock.lock(); defer { lock.unlock() }; live[Self.key(device, inode), default: 0] += 1
    }
    func unregister(device: Int64, inode: UInt64) {
        lock.lock(); defer { lock.unlock() }
        let key = Self.key(device, inode)
        if let count = live[key], count > 1 { live[key] = count - 1 } else { live.removeValue(forKey: key) }
    }
    func contains(device: dev_t, inode: ino_t) -> Bool {
        lock.lock(); defer { lock.unlock() }; return live[Self.key(Int64(device), UInt64(inode))] != nil
    }
}
