import Foundation
import Darwin

/// One coalescing writer owns fixed files in a protected ApplicationSupport sibling.
public actor PresentationPreferenceStore {
    public static let maximumBytes = 64 * 1024
    private let directory: URL
    private var epoch: UUID
    private var pending: (PresentationPreferences, UUID)?
    private var writer: Task<Void, Never>?
    private var resetting = false
    private var lastError: PresentationPreferenceError?
    private let beforeWrite: (@Sendable () async -> Void)?
    private let failBeforeReplace: Bool
    public init(ownedDirectory: URL, epoch: UUID) {
        directory = ownedDirectory; self.epoch = epoch; beforeWrite = nil; failBeforeReplace = false
    }
    init(ownedDirectory: URL, epoch: UUID, beforeWrite: @escaping @Sendable () async -> Void,
         failBeforeReplace: Bool = false) {
        directory = ownedDirectory; self.epoch = epoch; self.beforeWrite = beforeWrite; self.failBeforeReplace = failBeforeReplace
    }
    #if DEBUG
    /// Generated fixture-only causal gate on the actual writer; production admission is unchanged.
    public init(ownedSyntheticDirectory: URL, epoch: UUID, beforeSyntheticWrite: @escaping @Sendable () async -> Void) throws {
        try ProtectedDataFixture.require(ownedSyntheticDirectory)
        directory = ownedSyntheticDirectory; self.epoch = epoch
        beforeWrite = beforeSyntheticWrite; failBeforeReplace = false
    }
    #endif
    public func load() throws -> PresentationPreferences {
        do {
            try prepareDirectory()
            let file = directory.appendingPathComponent("preferences.json")
            var info = stat()
            if lstat(file.path, &info) != 0 { guard errno == ENOENT else { throw PresentationPreferenceError.io }; return PresentationPreferences() }
            let bytes = try read(file)
            let value: PresentationPreferences
            do { value = try JSONDecoder().decode(PresentationPreferences.self, from: bytes) }
            catch { throw PresentationPreferenceError.corrupt }
            guard value.version == 1 else { throw PresentationPreferenceError.unsupported }
            try value.validated(); return value
        } catch let error as PresentationPreferenceError { throw error }
        catch { throw PresentationPreferenceError.io }
    }
    /// Returns after admission; flush accounts the actual writer through completion.
    public func save(_ value: PresentationPreferences, epoch: UUID) throws {
        guard !resetting else { throw PresentationPreferenceError.resetting }
        guard self.epoch == epoch else { throw PresentationPreferenceError.staleEpoch }
        try value.validated()
        let bytes: Data
        do { bytes = try JSONEncoder().encode(value) } catch { throw PresentationPreferenceError.corrupt }
        guard bytes.count <= Self.maximumBytes else { throw PresentationPreferenceError.bounds }
        pending = (value, epoch); lastError = nil
        if writer == nil { writer = Task { await self.drain() } }
    }
    public func flush() async throws {
        if let writer { await writer.value }
        if let lastError { throw lastError }
    }
    private func drain() async {
        while let next = pending {
            pending = nil
            if let beforeWrite { await beforeWrite() }
            guard !Task.isCancelled, next.1 == epoch, !resetting else { continue }
            do { try write(next.0) }
            catch let error as PresentationPreferenceError { lastError = error }
            catch { lastError = .io }
        }
        writer = nil
    }
    /// Closes admission, cancels/drains actual old work, then replaces only owned state.
    public func resetForCatalogReplacement(epoch newEpoch: UUID) async throws {
        guard !resetting else { throw PresentationPreferenceError.resetting }
        resetting = true; epoch = newEpoch; pending = nil
        let old = writer; old?.cancel(); if let old { await old.value }
        defer { resetting = false }
        lastError = nil
        do { try write(PresentationPreferences()) }
        catch let error as PresentationPreferenceError { throw error }
        catch { throw PresentationPreferenceError.io }
    }
    /// A serial integration hook for catalog deletion, not a claim that deletion is implemented.
    public func removeOwnedPreferencesForCatalogDelete(epoch newEpoch: UUID) async throws {
        guard !resetting else { throw PresentationPreferenceError.resetting }
        resetting = true; epoch = newEpoch; pending = nil
        let old = writer; old?.cancel(); if let old { await old.value }
        defer { resetting = false }
        do {
            try prepareDirectory()
            guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("preferences.tmp").path) else { throw PresentationPreferenceError.unsafe }
            for name in ["preferences.json"] {
                let file = directory.appendingPathComponent(name)
                var info = stat()
                if lstat(file.path, &info) != 0 { guard errno == ENOENT else { throw PresentationPreferenceError.io }; continue }
                try regular(info); guard unlink(file.path) == 0 else { throw PresentationPreferenceError.io }
            }
            guard rmdir(directory.path) == 0 else { throw PresentationPreferenceError.unsafe }
        } catch let error as PresentationPreferenceError { throw error }
        catch { throw PresentationPreferenceError.io }
    }
    private func prepareDirectory() throws {
        var info = stat()
        if lstat(directory.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw PresentationPreferenceError.unsafe }
            let names = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
            guard names.isSubset(of: ["preferences.json", "preferences.tmp"]) else { throw PresentationPreferenceError.unsafe }
        } else { guard errno == ENOENT else { throw PresentationPreferenceError.io } }
        try CatalogRepository.protect(directory, directory: true)
    }
    private func regular(_ info: stat) throws {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw PresentationPreferenceError.unsafe }
    }
    private func read(_ file: URL) throws -> Data {
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PresentationPreferenceError.unsafe }; defer { Darwin.close(fd) }
        var before = stat(); guard fstat(fd, &before) == 0 else { throw PresentationPreferenceError.io }; try regular(before)
        guard before.st_size > 0, before.st_size <= Self.maximumBytes else { throw PresentationPreferenceError.bounds }
        try CatalogRepository.protect(file)
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size) + 1), total = 0
        let capacity = bytes.count
        while total < capacity {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: total), capacity - total) }
            guard count >= 0 else { throw PresentationPreferenceError.io }; if count == 0 { break }; total += count
        }
        var after = stat(), path = stat()
        guard fstat(fd, &after) == 0, lstat(file.path, &path) == 0, after.st_dev == before.st_dev,
              after.st_ino == before.st_ino, path.st_ino == after.st_ino, path.st_dev == after.st_dev,
              after.st_size == before.st_size, total == before.st_size, after.st_nlink == 1 else { throw PresentationPreferenceError.unsafe }
        return Data(bytes.prefix(total))
    }
    private func write(_ value: PresentationPreferences) throws {
        try prepareDirectory(); try value.validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(value); guard bytes.count <= Self.maximumBytes else { throw PresentationPreferenceError.bounds }
        let temporary = directory.appendingPathComponent("preferences.tmp"), final = directory.appendingPathComponent("preferences.json")
        var finalInfo = stat()
        if lstat(final.path, &finalInfo) == 0 { try regular(finalInfo) }
        else { guard errno == ENOENT else { throw PresentationPreferenceError.io } }
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PresentationPreferenceError.unsafe }
        var owned = stat(); guard fstat(fd, &owned) == 0 else { Darwin.close(fd); throw PresentationPreferenceError.io }
        var moved = false
        defer {
            Darwin.close(fd)
            if !moved {
                var current = stat()
                if lstat(temporary.path, &current) == 0, current.st_dev == owned.st_dev, current.st_ino == owned.st_ino, current.st_nlink == 1 { unlink(temporary.path) }
            }
        }
        // Effective protection and exclusion are established on an empty file BEFORE any text.
        try CatalogRepository.protect(temporary)
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard count > 0 else { throw PresentationPreferenceError.io }; offset += count
            }
        }
        guard fsync(fd) == 0, try read(temporary) == bytes else { throw PresentationPreferenceError.io }
        if failBeforeReplace { throw PresentationPreferenceError.injectedFailure }
        guard rename(temporary.path, final.path) == 0 else { throw PresentationPreferenceError.io }; moved = true
        try CatalogRepository.protect(final)
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw PresentationPreferenceError.unsafe }; defer { Darwin.close(parent) }
        guard fsync(parent) == 0, try read(final) == bytes else { throw PresentationPreferenceError.io }
    }
}
