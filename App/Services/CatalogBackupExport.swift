import Foundation
import Darwin
import CryptoKit
import AFITCCore

/// Owns exclusive output creation and checked partial cleanup; never replaces a destination.
actor CatalogBackupExport {
    enum Failure: Error { case unsafe, collision, write, changed, cleanup }
    private var output: URL?
    private var identity: stat?
    private var created: [String: stat] = [:]
    func write(_ backup: PreparedCatalogBackup, to parent: URL, name: String,
               progress: @escaping @Sendable (CatalogOperationProgress) -> Void) throws -> URL {
        let scoped = parent.startAccessingSecurityScopedResource()
        defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
        guard parent.isFileURL, name == URL(fileURLWithPath: name).lastPathComponent else { throw Failure.unsafe }
        progress(CatalogOperationProgress(phase: "Waiting for selected folder", completed: 0, total: nil, unit: "operations"))
        var coordinationError: NSError?, result: Result<URL, Error>?
        NSFileCoordinator().coordinate(writingItemAt: parent, options: [], error: &coordinationError) { selected in
            result = Result {
                let parentFD = Darwin.open(selected.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard parentFD >= 0 else { throw Failure.unsafe }; defer { Darwin.close(parentFD) }
                let target = selected.appendingPathComponent(name, isDirectory: true)
                try Task.checkCancellation()
                guard mkdirat(parentFD, name, 0o700) == 0 else { throw Failure.collision }
                let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw Failure.write }; defer { Darwin.close(fd) }
                var info = stat(); guard fstat(fd, &info) == 0 else { throw Failure.write }
                output = target; identity = info
                do {
                    guard Set(try FileManager.default.contentsOfDirectory(atPath: backup.directory.path)) == ["manifest.json", "catalog.sqlite"] else { throw Failure.unsafe }
                    let manifest = try copy("manifest.json", from: backup.directory, into: fd, maximum: BackupManifest.maximumManifestBytes, progress: progress)
                    let catalog = try copy("catalog.sqlite", from: backup.directory, into: fd, maximum: BackupManifest.maximumCatalogBytes, progress: progress)
                    let parsed = try JSONDecoder().decode(BackupManifest.self, from: manifest.2)
                    guard parsed == backup.manifest, catalog.0 == backup.manifest.catalogBytes,
                          catalog.1 == backup.manifest.catalogSHA256, manifest.0 + catalog.0 <= BackupManifest.maximumTotalBytes,
                          try names(fd) == ["manifest.json", "catalog.sqlite"] else { throw Failure.changed }
                    try verify("manifest.json", directory: fd, size: manifest.0, hash: manifest.1)
                    try verify("catalog.sqlite", directory: fd, size: catalog.0, hash: catalog.1)
                    var path = stat()
                    guard fstatat(parentFD, name, &path, AT_SYMLINK_NOFOLLOW) == 0,
                          path.st_dev == info.st_dev, path.st_ino == info.st_ino, fsync(fd) == 0, fsync(parentFD) == 0 else { throw Failure.changed }
                    try Task.checkCancellation()
                    output = nil; identity = nil; created = [:]
                    return target
                } catch { try cleanup(); throw error }
            }
        }
        if coordinationError != nil { throw Failure.write }
        guard let result else { throw Failure.write }; return try result.get()
    }
    private func copy(_ name: String, from source: URL, into directory: Int32, maximum: Int,
                      progress: @Sendable (CatalogOperationProgress) -> Void) throws -> (Int, String, Data) {
        let input = Darwin.open(source.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw Failure.unsafe }; defer { Darwin.close(input) }
        var before = stat(); guard fstat(input, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
            before.st_nlink == 1, before.st_size > 0, before.st_size <= maximum else { throw Failure.unsafe }
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.collision }; defer { Darwin.close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0 else { throw Failure.write }; created[name] = info
        var buffer = [UInt8](repeating: 0, count: 64 * 1024), total = 0, hash = SHA256(), manifest = Data()
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(input, &buffer, buffer.count)
            guard count >= 0 else { throw Failure.write }; if count == 0 { break }
            guard total <= maximum - count else { throw Failure.unsafe }
            let data = Data(buffer.prefix(count)); hash.update(data: data)
            if name == "manifest.json" { manifest.append(data) }
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < count {
                    let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), count - offset)
                    guard written > 0 else { throw Failure.write }; offset += written
                }
            }
            total += count
            progress(CatalogOperationProgress(phase: "Writing package", completed: total, total: Int(before.st_size), unit: "bytes"))
        }
        var after = stat(), pathInfo = stat()
        guard fstat(input, &after) == 0, lstat(source.appendingPathComponent(name).path, &pathInfo) == 0,
              same(before, after), same(after, pathInfo), total == before.st_size, fsync(fd) == 0 else { throw Failure.changed }
        return (total, hash.finalize().map { String(format: "%02x", $0) }.joined(), manifest)
    }
    private func verify(_ name: String, directory: Int32, size: Int, hash: String) throws {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.changed }; defer { Darwin.close(fd) }
        var before = stat(); guard let owned = created[name], fstat(fd, &before) == 0,
            before.st_dev == owned.st_dev, before.st_ino == owned.st_ino, before.st_nlink == 1,
            before.st_mode & S_IFMT == S_IFREG, before.st_size == size else { throw Failure.changed }
        var bytes = [UInt8](repeating: 0, count: 64 * 1024), total = 0, digest = SHA256()
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &bytes, bytes.count)
            guard count >= 0, total <= size - count else { throw Failure.changed }; if count == 0 { break }
            total += count; digest.update(data: Data(bytes.prefix(count)))
        }
        var after = stat(), path = stat()
        guard fstat(fd, &after) == 0, fstatat(directory, name, &path, AT_SYMLINK_NOFOLLOW) == 0,
              same(before, after), same(after, path), total == size,
              digest.finalize().map({ String(format: "%02x", $0) }).joined() == hash else { throw Failure.changed }
    }
    private func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_nlink == b.st_nlink && a.st_size == b.st_size &&
            a.st_mode == b.st_mode && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
            a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private func names(_ fd: Int32) throws -> Set<String> {
        let duplicate = dup(fd); guard duplicate >= 0 else { throw Failure.unsafe }
        guard let stream = fdopendir(duplicate) else { Darwin.close(duplicate); throw Failure.unsafe }
        defer { closedir(stream) }; rewinddir(stream)
        var result = Set<String>()
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { result.insert(name) }
        }
        return result
    }
    /// Retains ownership on failed cleanup for explicit retry, never deletes foreign identities.
    func cleanup() throws {
        guard let output, let identity else { return }
        let fd = Darwin.open(output.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.cleanup }; defer { Darwin.close(fd) }
        var current = stat()
        guard fstat(fd, &current) == 0, current.st_dev == identity.st_dev, current.st_ino == identity.st_ino else { throw Failure.cleanup }
        let names = try names(fd); guard names.isSubset(of: Set(created.keys)) else { throw Failure.cleanup }
        for name in names {
            var file = stat()
            guard let expected = created[name], fstatat(fd, name, &file, AT_SYMLINK_NOFOLLOW) == 0,
                  file.st_dev == expected.st_dev, file.st_ino == expected.st_ino, file.st_nlink == 1,
                  file.st_mode & S_IFMT == S_IFREG else { throw Failure.cleanup }
        }
        for name in names { guard unlinkat(fd, name, 0) == 0 else { throw Failure.cleanup }; created.removeValue(forKey: name) }
        var path = stat(); guard lstat(output.path, &path) == 0, path.st_dev == identity.st_dev,
              path.st_ino == identity.st_ino, rmdir(output.path) == 0 else { throw Failure.cleanup }
        self.output = nil; self.identity = nil
    }
}
