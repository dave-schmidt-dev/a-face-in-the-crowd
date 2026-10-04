import Foundation
import Darwin

/// Actor-confined linked FIFO accounting and filesystem policy for owned preview files.
struct CachePolicy {
    struct Candidate {
        let name: String
        let size: UInt64
        let modified: Date
    }
    struct DirectoryStamp: Equatable {
        let device: UInt64
        let inode: UInt64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
    }
    private struct Entry {
        let size: UInt64
        let modified: Date
        var previous: String?
        var next: String?
    }
    private struct StageIdentity {
        let device: UInt64
        let inode: UInt64

        func matches(_ info: stat) -> Bool {
            (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1 &&
            UInt64(info.st_dev) == device && UInt64(info.st_ino) == inode
        }
    }
    private struct StagedFile {
        let descriptor: Int32
        let identity: StageIdentity
    }

    private var inventory: [String: Entry]?
    private var residualStageFiles: [String: UInt64] = [:]
    private(set) var residualStageBytes: UInt64 = 0
    private var head: String?
    private var tail: String?
    private(set) var totalBytes: UInt64 = 0
    private(set) var inventoryBuilds = 0
    private(set) var directoryStamp: DirectoryStamp?

    var isBuilt: Bool { inventory != nil }
    var names: [String] { inventory.map { Array($0.keys) } ?? [] }

    /// The filename embeds the owning photo UUID and an optional scan generation.
    /// No path component, extension variation, or arbitrary suffix is accepted.
    static func ownsPreviewFile(named name: String, for id: UUID? = nil) -> Bool {
        guard name.hasSuffix(".jpg"), !name.contains("/"), !name.contains("\\") else { return false }
        let stem = String(name.dropLast(4))
        guard stem.count >= 36 else { return false }
        let photoID = String(stem.prefix(36))
        guard UUID(uuidString: photoID) != nil else { return false }
        if let id, photoID.caseInsensitiveCompare(id.uuidString) != .orderedSame { return false }
        let suffix = stem.dropFirst(36)
        guard !suffix.isEmpty else { return true }
        guard suffix.first == "-" else { return false }
        let generation = suffix.dropFirst().split(separator: "-", omittingEmptySubsequences: false)
        guard generation.count == 2 else { return false }
        return generation.allSatisfy { value in
            guard !value.isEmpty, value.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  value.count == 1 || value.first != "0",
                  let number = UInt64(value) else { return false }
            return number > 0
        }
    }

    /// Only the exact UUID spelling emitted by this implementation is derived staging state.
    static func ownsStageFile(named name: String) -> Bool {
        let prefix = ".afitc-preview-stage-"
        let suffix = ".tmp"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let token = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        guard token.count == 36, let id = UUID(uuidString: token) else { return false }
        return id.uuidString == token
    }

    func previewIsAvailable(_ name: String?, for id: UUID, in directory: URL) throws -> Bool {
        guard let name, Self.ownsPreviewFile(named: name, for: id),
              let file = try candidate(named: name, in: directory) else { return false }
        return file.size > 0 && file.size <= UInt64(DecodeLimits.maximumFileBytes)
    }

    mutating func clearOwnedPreviews(in directory: URL) throws -> Int {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            var removed = 0
            for url in files {
                let name = url.lastPathComponent
                guard Self.ownsPreviewFile(named: name),
                      try candidate(named: name, in: directory) != nil else { continue }
                if Darwin.unlink(url.path) == 0 { removed += 1 }
                else if errno != ENOENT { throw Self.posixError(errno) }
            }
            invalidate()
            return removed
        } catch {
            invalidate()
            throw error
        }
    }

    /// Keep the old destination until a bounded, protected staging file can replace it.
    mutating func store(_ jpeg: Data, id: UUID, generation: String?, in directory: URL,
                        budget: Int, beforePublish: (@Sendable () throws -> Void)?,
                        validateLease: () throws -> Void, protect: (URL) throws -> Void) throws -> String {
        guard !jpeg.isEmpty else { throw ScanError.malformed }
        guard jpeg.count <= DecodeLimits.maximumFileBytes else { throw ScanError.oversized }
        let limit = UInt64(max(0, min(budget, DecodeLimits.cacheBudget)))
        guard limit > 0, UInt64(jpeg.count) <= limit else { throw ScanError.storagePressure }
        let name = id.uuidString + (generation.map { "-" + $0 } ?? "") + ".jpg"
        guard Self.ownsPreviewFile(named: name, for: id) else { throw ScanError.unsafePath }
        let destination = directory.appendingPathComponent(name)
        try Self.validateDestination(name, in: directory)
        try reconcile(in: directory)

        // Retain the old destination and every residual stage while reserving the new bytes.
        let oldBytes = inventory?[name]?.size ?? 0
        let (oldAndNew, oldOverflow) = oldBytes.addingReportingOverflow(UInt64(jpeg.count))
        let (minimumPeak, residualOverflow) = oldAndNew.addingReportingOverflow(residualStageBytes)
        guard !oldOverflow, !residualOverflow, minimumPeak <= limit else { throw ScanError.storagePressure }
        while true {
            let (previewsAndNew, previewOverflow) = totalBytes.addingReportingOverflow(UInt64(jpeg.count))
            let (peak, residualPeakOverflow) = previewsAndNew.addingReportingOverflow(residualStageBytes)
            if !previewOverflow && !residualPeakOverflow && peak <= limit { break }
            guard let oldest = oldest(excluding: name) else { throw ScanError.storagePressure }
            try removeOwnedPreview(oldest, in: directory)
        }

        let stage = directory.appendingPathComponent(".afitc-preview-stage-\(UUID().uuidString).tmp")
        var staged: StagedFile?
        var didPublish = false
        do {
            let ownedStage = try Self.writeStage(jpeg, to: stage, protect: protect)
            staged = ownedStage
            try beforePublish?()
            if Task.isCancelled { throw CancellationError() }
            try validateLease()
            try Self.validateDestination(name, in: directory)
            guard try Self.stageIsOwned(ownedStage, at: stage) else { throw ScanError.unsafePath }
            guard Darwin.rename(stage.path, destination.path) == 0 else { throw Self.posixError(errno) }
            didPublish = true
            let closeStatus = Darwin.close(ownedStage.descriptor)
            let closeCode = errno
            staged = nil
            guard closeStatus == 0 else { throw Self.posixError(closeCode) }
            let file = Candidate(name: name, size: UInt64(jpeg.count), modified: Date())
            try recordCommitted(file)
            setDirectoryStamp(try Self.directoryStamp(in: directory))
            return name
        } catch {
            if let staged {
                if !didPublish, (try? Self.stageIsOwned(staged, at: stage)) == true {
                    _ = Darwin.unlink(stage.path)
                }
                _ = Darwin.close(staged.descriptor)
            }
            throw error
        }
    }

    mutating func invalidate() {
        inventory = nil; head = nil; tail = nil; totalBytes = 0
        residualStageFiles = [:]; residualStageBytes = 0; directoryStamp = nil
    }

    private mutating func reconcile(in directory: URL) throws {
        var stamp = try Self.directoryStamp(in: directory)
        if !isBuilt || directoryStamp != stamp {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            var candidates: [Candidate] = []
            var residual: [(String, UInt64)] = []
            for url in files {
                let name = url.lastPathComponent
                if Self.ownsPreviewFile(named: name) {
                    if let file = try candidate(named: name, in: directory) { candidates.append(file) }
                } else if Self.ownsStageFile(named: name), let size = try Self.residualStageSize(named: name, in: directory) {
                    residual.append((name, size))
                }
            }
            // Every stage was classified safe above. No store is in flight on this actor, so an owned
            // regular stage is a crash leftover; one that cannot be unlinked stays counted.
            var stages: [String: UInt64] = [:]
            var stageBytes: UInt64 = 0
            var unlinked = false
            for (name, size) in residual {
                if Darwin.unlink(directory.appendingPathComponent(name).path) == 0 || errno == ENOENT { unlinked = true; continue }
                let (sum, overflow) = stageBytes.addingReportingOverflow(size)
                guard !overflow else { throw ScanError.storagePressure }
                stages[name] = size
                stageBytes = sum
            }
            if unlinked { stamp = try Self.directoryStamp(in: directory) }
            try rebuild(from: candidates, stamp: stamp, initial: !isBuilt)
            residualStageFiles = stages
            residualStageBytes = stageBytes
            return
        }
        for name in names {
            if let file = try candidate(named: name, in: directory) { try refresh(file) }
            else { remove(name) }
        }
        try refreshResidualStages(in: directory)
        // Keep the observed stamp. If the directory changed during reconciliation, the next
        // operation will rebuild rather than treating an incomplete listing as current.
    }

    private mutating func refreshResidualStages(in directory: URL) throws {
        var refreshed: [String: UInt64] = [:]
        var bytes: UInt64 = 0
        for name in residualStageFiles.keys.sorted() {
            guard let size = try Self.residualStageSize(named: name, in: directory) else { continue }
            let (sum, overflow) = bytes.addingReportingOverflow(size)
            guard !overflow else { throw ScanError.storagePressure }
            refreshed[name] = size
            bytes = sum
        }
        residualStageFiles = refreshed
        residualStageBytes = bytes
    }

    private static func directoryStamp(in directory: URL) throws -> DirectoryStamp {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw ScanError.database }
        return DirectoryStamp(device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }

    private func candidate(named name: String, in directory: URL) throws -> Candidate? {
        guard Self.ownsPreviewFile(named: name) else { return nil }
        let url = directory.appendingPathComponent(name)
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw Self.posixError(errno)
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size >= 0 else { return nil }
        let modified = Date(timeIntervalSince1970:
            Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return Candidate(name: name, size: UInt64(info.st_size), modified: modified)
    }

    private static func residualStageSize(named name: String, in directory: URL) throws -> UInt64? {
        guard Self.ownsStageFile(named: name) else { return nil }
        let url = directory.appendingPathComponent(name)
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw Self.posixError(errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_size >= 0 else {
            throw ScanError.unsafePath
        }
        return UInt64(info.st_size)
    }

    private static func validateDestination(_ name: String, in directory: URL) throws {
        guard Self.ownsPreviewFile(named: name) else { throw ScanError.unsafePath }
        let url = directory.appendingPathComponent(name)
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw ScanError.unsafePath }
        } else if errno != ENOENT {
            throw Self.posixError(errno)
        }
    }

    private mutating func removeOwnedPreview(_ name: String, in directory: URL) throws {
        guard Self.ownsPreviewFile(named: name) else { throw ScanError.unsafePath }
        let url = directory.appendingPathComponent(name)
        guard try candidate(named: name, in: directory) != nil else { remove(name); return }
        if Darwin.unlink(url.path) == 0 || errno == ENOENT { remove(name); return }
        throw Self.posixError(errno)
    }

    private static func stageIsOwned(_ staged: StagedFile, at url: URL) throws -> Bool {
        var opened = stat()
        guard fstat(staged.descriptor, &opened) == 0 else { throw Self.posixError(errno) }
        guard staged.identity.matches(opened) else { return false }
        var named = stat()
        if lstat(url.path, &named) != 0 {
            if errno == ENOENT { return false }
            throw Self.posixError(errno)
        }
        return staged.identity.matches(named)
    }

    private static func writeStage(_ data: Data, to url: URL, protect: (URL) throws -> Void) throws -> StagedFile {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw Self.posixError(errno) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw Self.posixError(code)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_size >= 0 else {
            _ = Darwin.close(descriptor)
            throw ScanError.unsafePath
        }
        let staged = StagedFile(descriptor: descriptor,
            identity: StageIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)))
        do {
            guard try stageIsOwned(staged, at: url) else { throw ScanError.unsafePath }
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            guard try stageIsOwned(staged, at: url) else { throw ScanError.unsafePath }
            #endif
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { throw ScanError.malformed }
                var offset = 0
                while offset < bytes.count {
                    let amount = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                    if amount < 0 {
                        let code = errno
                        if code == EINTR { continue }
                        throw Self.posixError(code)
                    }
                    guard amount > 0 else { throw ScanError.database }
                    offset += amount
                }
            }
            guard Darwin.fsync(descriptor) == 0 else { throw Self.posixError(errno) }
            guard try stageIsOwned(staged, at: url) else { throw ScanError.unsafePath }
            try protect(url)
            guard try stageIsOwned(staged, at: url) else { throw ScanError.unsafePath }
            return staged
        } catch {
            if (try? stageIsOwned(staged, at: url)) == true { _ = Darwin.unlink(url.path) }
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    private mutating func rebuild(from files: [Candidate], stamp: DirectoryStamp, initial: Bool) throws {
        inventory = [:]; head = nil; tail = nil; totalBytes = 0
        for file in files.sorted(by: {
            $0.modified == $1.modified ? $0.name < $1.name : $0.modified < $1.modified
        }) {
            try append(file)
        }
        if initial, inventoryBuilds < Int.max { inventoryBuilds += 1 }
        directoryStamp = stamp
    }

    private mutating func refresh(_ file: Candidate) throws {
        guard let old = inventory?[file.name] else {
            try append(file)
            return
        }
        guard old.size != file.size || old.modified != file.modified else { return }
        remove(file.name)
        try append(file)
    }

    private mutating func remove(_ name: String) {
        guard let entry = inventory?.removeValue(forKey: name) else { return }
        if let previous = entry.previous { inventory?[previous]?.next = entry.next }
        else { head = entry.next }
        if let next = entry.next { inventory?[next]?.previous = entry.previous }
        else { tail = entry.previous }
        totalBytes -= entry.size
    }

    private func oldest(excluding name: String) -> String? {
        var candidate = head
        while let current = candidate {
            if current != name { return current }
            candidate = inventory?[current]?.next
        }
        return nil
    }

    private mutating func recordCommitted(_ file: Candidate) throws {
        remove(file.name)
        try append(file)
    }

    private mutating func setDirectoryStamp(_ stamp: DirectoryStamp) {
        directoryStamp = stamp
    }

    private mutating func append(_ file: Candidate) throws {
        let (sum, overflow) = totalBytes.addingReportingOverflow(file.size)
        guard !overflow, inventory != nil else { throw ScanError.storagePressure }
        inventory?[file.name] = Entry(size: file.size, modified: file.modified, previous: tail, next: nil)
        if let tail { inventory?[tail]?.next = file.name }
        else { head = file.name }
        tail = file.name
        totalBytes = sum
    }
}
