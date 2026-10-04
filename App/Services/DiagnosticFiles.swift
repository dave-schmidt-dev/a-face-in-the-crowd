import Foundation
import Darwin

enum DiagnosticFileError: Error, Equatable { case unsafe, changed, syscall(Int32), injected }
enum DiagnosticFileFault: Equatable { case beforeUnlink(Int), afterUnlink(Int), parentSync }

/// One descriptor-owned directory. Only six fixed log names can ever be appended or removed.
final class DiagnosticFiles: @unchecked Sendable {
    private struct Entry { let name: String; let device: dev_t; let inode: ino_t; let size: off_t }
    private let url: URL
    private let parentURL: URL
    private let name: String
    private let parent: Int32
    private let root: Int32
    private let parentIdentity: stat
    private let rootIdentity: stat
    private var removal: [Entry]?
    private var removed = Set<Int>()
    private var rootRemoved = false
    static let allowed = Set(["diagnostics.log"] + (1...5).map { "diagnostics.\($0).log" })
    init(directory: URL, create: Bool) throws {
        url = directory.standardizedFileURL; parentURL = url.deletingLastPathComponent(); name = url.lastPathComponent
        guard directory.isFileURL, !["", ".", ".."].contains(name), !name.contains("/") else { throw DiagnosticFileError.unsafe }
        parent = Darwin.open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw DiagnosticFileError.syscall(errno) }
        var p = stat(); guard fstat(parent, &p) == 0 else { Darwin.close(parent); throw DiagnosticFileError.syscall(errno) }
        parentIdentity = p
        var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT, create else { Darwin.close(parent); throw DiagnosticFileError.syscall(errno) }
            guard mkdirat(parent, name, 0o700) == 0 else { Darwin.close(parent); throw DiagnosticFileError.syscall(errno) }
        }
        root = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { Darwin.close(parent); throw DiagnosticFileError.unsafe }
        var r = stat(); guard fstat(root, &r) == 0 else { Darwin.close(root); Darwin.close(parent); throw DiagnosticFileError.syscall(errno) }
        rootIdentity = r
        do { try validate(); _ = try snapshot(); try protect(url, fd: root, directory: true) }
        catch { Darwin.close(root); Darwin.close(parent); throw error }
    }
    deinit { Darwin.close(root); Darwin.close(parent) }
    private func identical(_ a: stat, _ b: stat) -> Bool { a.st_dev == b.st_dev && a.st_ino == b.st_ino }
    private func validate() throws {
        var p = stat(), namedParent = stat(), r = stat(), namedRoot = stat()
        guard fstat(parent, &p) == 0, lstat(parentURL.path, &namedParent) == 0,
              identical(p, parentIdentity), identical(p, namedParent), p.st_mode & S_IFMT == S_IFDIR,
              fstat(root, &r) == 0, identical(r, rootIdentity) else { throw DiagnosticFileError.changed }
        let status = fstatat(parent, name, &namedRoot, AT_SYMLINK_NOFOLLOW)
        if rootRemoved { guard status != 0, errno == ENOENT else { throw DiagnosticFileError.changed }; return }
        guard status == 0, namedRoot.st_mode & S_IFMT == S_IFDIR, identical(r, namedRoot) else { throw DiagnosticFileError.changed }
    }
    private func names() throws -> Set<String> {
        let duplicate = dup(root); guard duplicate >= 0 else { throw DiagnosticFileError.syscall(errno) }
        guard let stream = fdopendir(duplicate) else { Darwin.close(duplicate); throw DiagnosticFileError.syscall(errno) }
        defer { closedir(stream) }; rewinddir(stream); var result = Set<String>(); errno = 0
        while let entry = readdir(stream) {
            let value = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if value == "." || value == ".." { continue }
            guard Self.allowed.contains(value), result.count < 6, result.insert(value).inserted else { throw DiagnosticFileError.unsafe }
        }
        guard errno == 0 else { throw DiagnosticFileError.syscall(errno) }; return result
    }
    private func entry(_ name: String) throws -> Entry {
        var s = stat()
        guard Self.allowed.contains(name), fstatat(root, name, &s, AT_SYMLINK_NOFOLLOW) == 0,
              s.st_mode & S_IFMT == S_IFREG, s.st_nlink == 1, s.st_size >= 0, s.st_size <= 1024 * 1024 else { throw DiagnosticFileError.unsafe }
        return Entry(name: name, device: s.st_dev, inode: s.st_ino, size: s.st_size)
    }
    private func snapshot() throws -> [Entry] { try names().sorted().map(entry) }
    private func protect(_ file: URL, fd: Int32, directory: Bool) throws {
        guard fchmod(fd, directory ? 0o700 : 0o600) == 0 else { throw DiagnosticFileError.syscall(errno) }
        var protected = file; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protected.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
        #endif
        try validate()
    }
    func append(_ data: Data, maximum: Int, retained: Int) throws {
        guard removal == nil, !rootRemoved, data.count > 0, data.count <= maximum else { throw DiagnosticFileError.unsafe }
        try validate(); let existing = try snapshot()
        if let current = existing.first(where: { $0.name == "diagnostics.log" }), Int(current.size) + data.count > maximum {
            for index in stride(from: retained, through: 1, by: -1) {
                let target = "diagnostics.\(index).log", source = index == 1 ? "diagnostics.log" : "diagnostics.\(index - 1).log"
                if try names().contains(target) { _ = try entry(target); guard unlinkat(root, target, 0) == 0 else { throw DiagnosticFileError.syscall(errno) } }
                if try names().contains(source) { _ = try entry(source); guard renameat(root, source, root, target) == 0 else { throw DiagnosticFileError.syscall(errno) } }
            }
        }
        let present = try names().contains("diagnostics.log")
        let before = present ? try entry("diagnostics.log") : nil
        let flags = O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC | (present ? 0 : O_CREAT | O_EXCL)
        let fd = openat(root, "diagnostics.log", flags, 0o600); guard fd >= 0 else { throw DiagnosticFileError.syscall(errno) }; defer { Darwin.close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              before.map({ $0.device == info.st_dev && $0.inode == info.st_ino && $0.size == info.st_size }) ?? true else { throw DiagnosticFileError.changed }
        try protect(url.appendingPathComponent("diagnostics.log"), fd: fd, directory: false)
        let named = try entry("diagnostics.log"); guard named.device == info.st_dev, named.inode == info.st_ino else { throw DiagnosticFileError.changed }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }; guard count > 0 else { throw DiagnosticFileError.syscall(errno) }; offset += count
            }
        }
    }
    /// Failure retains the exact descriptors and entry identities; replacement files are never adopted.
    func remove(fault: DiagnosticFileFault? = nil) throws {
        try validate()
        if rootRemoved { guard fsync(parent) == 0 else { throw DiagnosticFileError.syscall(errno) }; return }
        if removal == nil { removal = try snapshot() }
        guard let removal, try names().isSubset(of: Set(removal.map(\.name))) else { throw DiagnosticFileError.unsafe }
        for (index, expected) in removal.enumerated() {
            try validate()
            if removed.contains(index) {
                guard !((try names()).contains(expected.name)) else { throw DiagnosticFileError.changed }; continue
            }
            if fault == .beforeUnlink(index) { throw DiagnosticFileError.injected }
            var current = stat()
            if fstatat(root, expected.name, &current, AT_SYMLINK_NOFOLLOW) == 0 {
                guard current.st_mode & S_IFMT == S_IFREG, current.st_nlink == 1,
                      current.st_dev == expected.device, current.st_ino == expected.inode, current.st_size == expected.size else { throw DiagnosticFileError.changed }
                guard unlinkat(root, expected.name, 0) == 0 else { throw DiagnosticFileError.syscall(errno) }
            } else { guard errno == ENOENT else { throw DiagnosticFileError.syscall(errno) } }
            if fault == .afterUnlink(index) { throw DiagnosticFileError.injected }
            guard fsync(root) == 0 else { throw DiagnosticFileError.syscall(errno) }; removed.insert(index)
        }
        try validate(); guard try names().isEmpty else { throw DiagnosticFileError.unsafe }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw DiagnosticFileError.syscall(errno) }; rootRemoved = true
        if fault == .parentSync { throw DiagnosticFileError.injected }
        guard fsync(parent) == 0 else { throw DiagnosticFileError.syscall(errno) }
    }
}
