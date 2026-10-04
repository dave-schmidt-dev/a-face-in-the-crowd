import Foundation
import Darwin

/// Stable identity for a no-follow filesystem object. Directory link counts and file sizes are
/// intentionally excluded when they can change as children are added or removed.
struct PreparedBackupNodeIdentity: Equatable, Sendable {
    let device: Int64
    let inode: UInt64
    let nodeType: UInt32
    let linkCount: UInt64

    init(_ info: stat) {
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
        nodeType = UInt32(info.st_mode & S_IFMT)
        linkCount = UInt64(info.st_nlink)
    }

    func matches(_ info: stat, directory: Bool, checkLinks: Bool = true) -> Bool {
        let expectedType = directory ? UInt32(S_IFDIR) : UInt32(S_IFREG)
        return device == Int64(info.st_dev) && inode == UInt64(info.st_ino) && nodeType == expectedType &&
            (!checkLinks || linkCount == UInt64(info.st_nlink))
    }
    func identifiesSameObject(as other: PreparedBackupNodeIdentity) -> Bool {
        device == other.device && inode == other.inode && nodeType == other.nodeType
    }
}

/// The producer's original parent directory and exact prepared package remain registered until
/// checked removal completes. This carries no database or reservation authority.
final class PreparedBackupOwnership: @unchecked Sendable {
    static let files: Set<String> = ["catalog.sqlite", "manifest.json"]

    let owner: UUID
    let token: UUID
    let directory: URL
    let stageURL: URL
    let stageName: String
    let parentIdentity: PreparedBackupNodeIdentity
    private let parentFD: Int32
    private let stageIdentity: PreparedBackupNodeIdentity
    private var children: [String: PreparedBackupNodeIdentity] = [:]
    private var removedChildren = Set<String>()
    private var stageRemoved = false
    private var finished = false
    private var sealed = false
    #if DEBUG
    private var cleanupFailure: PreparedBackupCleanupFailure?
    #endif

    private init(owner: UUID, token: UUID, directory: URL, stageURL: URL, parentFD: Int32,
                 parentIdentity: PreparedBackupNodeIdentity, stageIdentity: PreparedBackupNodeIdentity) {
        self.owner = owner
        self.token = token
        self.directory = directory.standardizedFileURL
        self.stageURL = stageURL.standardizedFileURL
        stageName = stageURL.lastPathComponent
        self.parentFD = parentFD
        self.parentIdentity = parentIdentity
        self.stageIdentity = stageIdentity
        PreparedStageRegistry.shared.register(device: stageIdentity.device, inode: stageIdentity.inode)
    }

    deinit {
        PreparedStageRegistry.shared.unregister(device: stageIdentity.device, inode: stageIdentity.inode)
        Darwin.close(parentFD)
    }

    static func captureDirectory(_ directory: URL) throws -> PreparedBackupNodeIdentity {
        let root = directory.standardizedFileURL
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw BackupError.unsafeStage }
        defer { Darwin.close(fd) }
        var descriptor = stat()
        var path = stat()
        guard fstat(fd, &descriptor) == 0, lstat(root.path, &path) == 0 else { throw BackupError.unsafeStage }
        let identity = PreparedBackupNodeIdentity(descriptor)
        guard identity.matches(path, directory: true, checkLinks: false) else { throw BackupError.unsafeStage }
        return identity
    }

    /// Atomically creates a uniquely named stage under an opened, identity-checked catalog root.
    static func create(directory: URL, stage: URL, owner: UUID, token: UUID) throws -> PreparedBackupOwnership {
        let root = directory.standardizedFileURL
        let package = stage.standardizedFileURL
        let name = "backup-" + token.uuidString
        guard root.isFileURL, package.deletingLastPathComponent() == root, package.lastPathComponent == name else {
            throw BackupError.unsafeStage
        }
        let parentFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw BackupError.unsafeStage }
        var keepParent = false
        defer { if !keepParent { Darwin.close(parentFD) } }
        var parentInfo = stat()
        var pathInfo = stat()
        guard fstat(parentFD, &parentInfo) == 0, lstat(root.path, &pathInfo) == 0 else { throw BackupError.unsafeStage }
        let parentIdentity = PreparedBackupNodeIdentity(parentInfo)
        guard parentIdentity.matches(pathInfo, directory: true, checkLinks: false) else { throw BackupError.unsafeStage }
        guard mkdirat(parentFD, name, 0o700) == 0 else { throw BackupError.unsafeStage }

        var stageInfo = stat()
        guard fstatat(parentFD, name, &stageInfo, AT_SYMLINK_NOFOLLOW) == 0,
              stageInfo.st_mode & S_IFMT == S_IFDIR else { throw BackupError.unsafeStage }
        let stageIdentity = PreparedBackupNodeIdentity(stageInfo)
        let stageFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stageFD >= 0 else {
            var current = stat()
            if fstatat(parentFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
               stageIdentity.matches(current, directory: true, checkLinks: false) { _ = unlinkat(parentFD, name, AT_REMOVEDIR) }
            throw BackupError.unsafeStage
        }
        var openedInfo = stat()
        let openedOK = fstat(stageFD, &openedInfo) == 0 && stageIdentity.matches(openedInfo, directory: true, checkLinks: false)
        Darwin.close(stageFD)
        guard openedOK else {
            var current = stat()
            if fstatat(parentFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
               stageIdentity.matches(current, directory: true, checkLinks: false) { _ = unlinkat(parentFD, name, AT_REMOVEDIR) }
            throw BackupError.unsafeStage
        }
        let value = PreparedBackupOwnership(owner: owner, token: token, directory: root, stageURL: package,
            parentFD: parentFD, parentIdentity: parentIdentity, stageIdentity: stageIdentity)
        keepParent = true
        return value
    }

    /// Captures one producer-created regular file immediately after creation, before writing bytes.
    func recordFile(_ name: String) throws {
        guard !sealed, Self.files.contains(name), children[name] == nil else { throw BackupError.unsafeStage }
        let stageFD = try openVerifiedStage()
        defer { Darwin.close(stageFD) }
        var before = stat()
        guard fstatat(stageFD, name, &before, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1 else { throw BackupError.unsafeStage }
        let fd = openat(stageFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw BackupError.unsafeStage }
        defer { Darwin.close(fd) }
        var opened = stat()
        var current = stat()
        let identity = PreparedBackupNodeIdentity(before)
        guard fstat(fd, &opened) == 0, fstatat(stageFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              identity.matches(opened, directory: false), identity.matches(current, directory: false) else {
            throw BackupError.unsafeStage
        }
        children[name] = identity
    }

    /// Seals the exact expected package after both files are fully written and protected.
    func seal() throws {
        guard !sealed, Set(children.keys) == Self.files else { throw BackupError.unsafeStage }
        let stageFD = try openVerifiedStage()
        defer { Darwin.close(stageFD) }
        guard try entryNames(stageFD) == Self.files else { throw BackupError.unsafeStage }
        for name in Self.files { try verifyChild(stageFD, name: name, identity: children[name]!) }
        try sync(stageFD)
        try sync(parentFD)
        sealed = true
    }

    /// Removes only registered children and the registered stage. Progress is retained after every
    /// unlink. Once the stage is gone, retries only fsync the retained original parent descriptor.
    func remove() throws {
        guard !finished else { throw BackupError.unsafeStage }
        if stageRemoved {
            try sync(parentFD)
            finished = true
            return
        }
        try verifyParentPath()
        let stageFD = try openVerifiedStage()
        defer { Darwin.close(stageFD) }
        let remaining = Set(children.keys).subtracting(removedChildren)
        guard try entryNames(stageFD) == remaining else { throw BackupError.unsafeStage }
        for name in remaining { try verifyChild(stageFD, name: name, identity: children[name]!) }

        for name in remaining.sorted() {
            try verifyChild(stageFD, name: name, identity: children[name]!)
            guard unlinkat(stageFD, name, 0) == 0 else { throw BackupError.unsafeStage }
            removedChildren.insert(name)
            try sync(stageFD)
            #if DEBUG
            if cleanupFailure == .afterFirstChildUnlink {
                cleanupFailure = nil
                throw BackupError.unsafeStage
            }
            #endif
        }
        guard try entryNames(stageFD).isEmpty else { throw BackupError.unsafeStage }
        try verifyParentPath()
        var current = stat()
        guard fstatat(parentFD, stageName, &current, AT_SYMLINK_NOFOLLOW) == 0,
              stageIdentity.matches(current, directory: true, checkLinks: false) else { throw BackupError.unsafeStage }
        guard unlinkat(parentFD, stageName, AT_REMOVEDIR) == 0 else { throw BackupError.unsafeStage }
        stageRemoved = true
        #if DEBUG
        if cleanupFailure == .afterStageUnlinkBeforeParentSync {
            cleanupFailure = nil
            throw BackupError.unsafeStage
        }
        #endif
        try sync(parentFD)
        finished = true
    }

    #if DEBUG
    func failNextCleanupForTest(_ failure: PreparedBackupCleanupFailure) { cleanupFailure = failure }
    #endif

    private func verifyParentPath() throws {
        var descriptor = stat()
        var path = stat()
        guard fstat(parentFD, &descriptor) == 0, lstat(directory.path, &path) == 0,
              parentIdentity.matches(descriptor, directory: true, checkLinks: false),
              parentIdentity.matches(path, directory: true, checkLinks: false) else { throw BackupError.unsafeStage }
    }

    private func openVerifiedStage() throws -> Int32 {
        var current = stat()
        guard fstatat(parentFD, stageName, &current, AT_SYMLINK_NOFOLLOW) == 0,
              stageIdentity.matches(current, directory: true, checkLinks: false) else { throw BackupError.unsafeStage }
        let fd = openat(parentFD, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw BackupError.unsafeStage }
        var opened = stat()
        guard fstat(fd, &opened) == 0, stageIdentity.matches(opened, directory: true, checkLinks: false) else {
            Darwin.close(fd)
            throw BackupError.unsafeStage
        }
        return fd
    }

    private func verifyChild(_ parent: Int32, name: String, identity: PreparedBackupNodeIdentity) throws {
        var before = stat()
        guard fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) == 0,
              identity.matches(before, directory: false) else { throw BackupError.unsafeStage }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw BackupError.unsafeStage }
        defer { Darwin.close(fd) }
        var opened = stat()
        var after = stat()
        guard fstat(fd, &opened) == 0, fstatat(parent, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
              identity.matches(opened, directory: false), identity.matches(after, directory: false) else {
            throw BackupError.unsafeStage
        }
    }

    private func entryNames(_ fd: Int32) throws -> Set<String> {
        let copy = dup(fd)
        guard copy >= 0 else { throw BackupError.unsafeStage }
        guard let directory = fdopendir(copy) else { Darwin.close(copy); throw BackupError.unsafeStage }
        defer { closedir(directory) }
        rewinddir(directory)
        var result = Set<String>()
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw BackupError.unsafeStage }
                return result
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.insert(name) }
            if result.count > Self.files.count { throw BackupError.unsafeStage }
        }
    }

    private func sync(_ fd: Int32) throws {
        guard fsync(fd) == 0 else { throw BackupError.unsafeStage }
    }
}

#if DEBUG
enum PreparedBackupCleanupFailure: Equatable { case afterFirstChildUnlink, afterStageUnlinkBeforeParentSync }

/// A test-only barrier for proving the suspension owner rejects concurrent cleanup reentry.
final class PreparedBackupCleanupGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pause() {
        condition.lock()
        entered = true
        let continuations = waiters
        waiters = []
        condition.unlock()
        continuations.forEach { $0.resume() }
        condition.lock()
        while !released { condition.wait() }
        condition.unlock()
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if entered {
                condition.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                condition.unlock()
            }
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
#endif
