import Foundation
import SQLite3
import CryptoKit
import Darwin

public enum RestoreValidationError: Error, Sendable, Equatable {
    case unsafeEntry, changedSource, malformed, unsupportedFormat, schema, domain, injectedFailure
}
public enum RestoreValidationStage: String, Sendable { case manifest, catalog, schema, integrity, domain }
public enum RestoreValidationUnit: Sendable { case bytes, sqliteInstructions, rows, jsonNodes, domainItems }
public struct RestoreValidationProgress: Sendable {
    public let stage: RestoreValidationStage
    public let completed: Int
    public let total: Int?
    public let unit: RestoreValidationUnit
}
public struct ValidatedCatalogBackup: Sendable {
    public let directory: URL
    public let manifest: BackupManifest
    let owner: UUID
    let token: UUID
}
enum RestoreValidationFault { case afterCopy }
/// Fixed diagnostic fields only; never exposes a source path, value or timestamp.
enum RestoreStabilityEntry: Sendable { case manifest, catalog, parent }
enum RestoreStabilityReason: Sendable { case read, growth, stat, fields, entries }
struct RestoreStabilityEvent: Sendable {
    let entry: RestoreStabilityEntry
    let reason: RestoreStabilityReason
    // 1 FD-stat error,2 path-stat error,4 bytecount,8 identity,16 size,
    // 32 links,64 mtime,128 ctime,256 entryset. No default logging.
    let fields: UInt16
}

/// Admission only: no live catalog, grant, migration or restore operation is performed here.
public actor RestoreValidator {
    private var readDiagnostics: SourceRestoreReadDiagnostics?
    private let root: URL
    private let ownedProtection: OwnedRestoreProtection
    private let rootOwnership: RestoreStageRootOwnership
    private var rootRetiring = false
    private let owner = UUID()
    private var stages: [UUID: URL] = [:]
    /// Registered stage identities still owned by this validator; a dropped validator releases them.
    private var registeredStages: [UUID: (device: Int64, inode: UInt64)] = [:]
    private var stabilityObserver: (@Sendable (RestoreStabilityEvent) -> Void)?
    public init(stagingDirectory: URL) throws {
        root = stagingDirectory.standardizedFileURL
        ownedProtection = .production
        rootOwnership = try RestoreStageRootOwnership(root, ownedProtection: ownedProtection)
    }
    init(stagingDirectory: URL, stabilityObserver: @escaping @Sendable (RestoreStabilityEvent) -> Void,
         readDiagnostics: SourceRestoreReadDiagnostics? = nil, ownedProtection: OwnedRestoreProtection = .production) throws {
        root = stagingDirectory.standardizedFileURL
        self.stabilityObserver = stabilityObserver; self.readDiagnostics = readDiagnostics
        self.ownedProtection = ownedProtection
        rootOwnership = try RestoreStageRootOwnership(root, ownedProtection: ownedProtection)
    }
    deinit {
        for identity in registeredStages.values {
            ImportStageRegistry.shared.unregister(device: identity.device, inode: identity.inode)
        }
    }
    public func validate(package: URL, progress: @escaping @Sendable (RestoreValidationProgress) -> Void = { _ in }) throws -> ValidatedCatalogBackup {
        try validate(package: package, progress: progress, fault: nil)
    }
    func validate(package: URL, progress: @escaping @Sendable (RestoreValidationProgress) -> Void,
                  fault: RestoreValidationFault?) throws -> ValidatedCatalogBackup {
        guard !rootRetiring else { throw BackupError.unsafeStage }
        try rootOwnership.validate()
        try Task.checkCancellation()
        progress(RestoreValidationProgress(stage: .manifest, completed: 0, total: nil, unit: .bytes))
        var outcome: Result<ValidatedCatalogBackup, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: package, options: .withoutChanges, error: &coordinationError) { url in
            outcome = Result { try stage(url, progress: progress, fault: fault) }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw RestoreValidationError.unsafeEntry }
        return try outcome.get()
    }
    /// Terminal retirement uses this validator's retained root identity, never a caller path.
    public func retireOwnedEmptyStagingRoot() throws { try retireOwnedEmptyStagingRoot(fault: nil) }
    func retireOwnedEmptyStagingRoot(fault: RestoreStageRootFault?) throws {
        guard stages.isEmpty else { throw BackupError.unsafeStage }
        rootRetiring = true
        try rootOwnership.remove(fault: fault)
    }
    public func discard(_ validated: ValidatedCatalogBackup) throws {
        try rootOwnership.validate()
        guard validated.owner == owner, stages[validated.token] == validated.directory else { throw BackupError.unsafeStage }
        try FileManager.default.removeItem(at: validated.directory); stages.removeValue(forKey: validated.token)
        if let identity = registeredStages.removeValue(forKey: validated.token) {
            ImportStageRegistry.shared.unregister(device: identity.device, inode: identity.inode)
        }
    }
    private func stage(_ source: URL, progress: @escaping @Sendable (RestoreValidationProgress) -> Void,
                       fault: RestoreValidationFault?) throws -> ValidatedCatalogBackup {
        try Task.checkCancellation()
        guard source.isFileURL else { throw RestoreValidationError.unsafeEntry }
        let descriptor = Darwin.open(source.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw RestoreValidationError.unsafeEntry }; defer { Darwin.close(descriptor) }
        var before = stat(); guard fstat(descriptor, &before) == 0 else { throw RestoreValidationError.unsafeEntry }
        let parentReadID = readDiagnostics?.nextReadID()
        func parentSample(_ boundary: SourceRestoreReadDiagnostics.Boundary, known: stat? = nil, observed: SourceRestoreReadDiagnostics.StatResult? = nil) {
            if let parentReadID { readDiagnostics?.sample(parentReadID, origin: .validator, role: .sourceParent, boundary: boundary, fd: descriptor, namedPath: source, knownFD: known, baseline: boundary == .baseline ? before : nil, descriptorResult: observed) }
        }
        parentSample(.baseline, known: before)
        guard try entries(descriptor) == ["manifest.json", "catalog.sqlite"] else { throw RestoreValidationError.unsafeEntry }
        parentSample(.afterEntries); parentSample(.beforeDestination)
        let token = UUID(); let destination = root.appendingPathComponent(token.uuidString, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw BackupError.unsafeStage }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: destination)
                if let identity = registeredStages.removeValue(forKey: token) {
                    ImportStageRegistry.shared.unregister(device: identity.device, inode: identity.inode)
                }
            }
        }
        var created = stat()
        guard lstat(destination.path, &created) == 0, created.st_mode & S_IFMT == S_IFDIR else { throw RestoreValidationError.unsafeEntry }
        let identity = (device: Int64(created.st_dev), inode: UInt64(created.st_ino))
        ImportStageRegistry.shared.register(device: identity.device, inode: identity.inode)
        registeredStages[token] = identity
        try CatalogRepository.protect(destination, directory: true, ownedProtection: ownedProtection); parentSample(.afterDestination)
        let manifestCopy = try copy(descriptor, "manifest.json", destination, limit: BackupManifest.maximumManifestBytes, stage: .manifest, progress: progress)
        parentSample(.afterManifest)
        let manifestData = try Data(contentsOf: destination.appendingPathComponent("manifest.json"))
        try RestoreDomain.shape(manifestData, context: "manifest")
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: manifestData)
        guard manifest.formatVersion == 1 else { throw RestoreValidationError.unsupportedFormat }
        guard manifest.schemaVersion == CatalogSchema.currentVersion else { throw ScanError.unsupportedSchema }
        guard manifest.revision >= 0, manifest.createdAt.timeIntervalSince1970.isFinite,
              manifest.catalogSHA256.utf8.count == 64,
              manifest.catalogSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw RestoreValidationError.malformed }
        try BackupFiles.checkLengths(catalog: manifest.catalogBytes, manifest: manifestCopy.bytes, options: BackupOptions())
        let catalogCopy = try copy(descriptor, "catalog.sqlite", destination, limit: manifest.catalogBytes, stage: .catalog, progress: progress)
        parentSample(.afterCatalog)
        guard catalogCopy.bytes == manifest.catalogBytes, catalogCopy.digest == manifest.catalogSHA256 else { throw RestoreValidationError.malformed }
        var after = stat()
        let statStatus = fstat(descriptor, &after); let statError = errno; let statOK = statStatus == 0
        parentSample(.finalGuard, observed: .init(after, status: statStatus, error: statError))
        guard statOK, same(before, after) else {
            stabilityObserver?(RestoreStabilityEvent(entry: .parent, reason: statOK ? .fields : .stat,
                fields: statOK ? differences(before, after) : 1))
            throw RestoreValidationError.changedSource
        }
        do {
            guard try entries(descriptor) == ["manifest.json", "catalog.sqlite"] else {
                stabilityObserver?(RestoreStabilityEvent(entry: .parent, reason: .entries, fields: 256))
                throw RestoreValidationError.changedSource
            }
        } catch {
            if error as? RestoreValidationError != .changedSource {
                stabilityObserver?(RestoreStabilityEvent(entry: .parent, reason: .entries, fields: 256))
            }
            throw error
        }
        if fault != nil { throw RestoreValidationError.injectedFailure }
        do { try inspect(destination.appendingPathComponent("catalog.sqlite"), manifest: manifest, progress: progress) }
        catch { try Task.checkCancellation(); throw error }
        for name in ["catalog.sqlite", "manifest.json"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.appendingPathComponent(name).path)
        }
        try Task.checkCancellation(); stages[token] = destination; completed = true
        return ValidatedCatalogBackup(directory: destination, manifest: manifest, owner: owner, token: token)
    }
    private func entries(_ descriptor: Int32) throws -> Set<String> {
        guard let directory = fdopendir(dup(descriptor)) else { throw RestoreValidationError.unsafeEntry }
        defer { closedir(directory) }; rewinddir(directory); var result = Set<String>(); errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard result.count < 2, ["manifest.json", "catalog.sqlite"].contains(name), result.insert(name).inserted else { throw RestoreValidationError.unsafeEntry }
        }
        guard errno == 0 else { throw RestoreValidationError.unsafeEntry }; return result
    }
    private func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private func differences(_ a: stat, _ b: stat) -> UInt16 {
        var fields: UInt16 = 0
        if a.st_dev != b.st_dev || a.st_ino != b.st_ino { fields |= 8 }
        if a.st_size != b.st_size { fields |= 16 }
        if a.st_nlink != b.st_nlink { fields |= 32 }
        if a.st_mtimespec.tv_sec != b.st_mtimespec.tv_sec || a.st_mtimespec.tv_nsec != b.st_mtimespec.tv_nsec { fields |= 64 }
        if a.st_ctimespec.tv_sec != b.st_ctimespec.tv_sec || a.st_ctimespec.tv_nsec != b.st_ctimespec.tv_nsec { fields |= 128 }
        return fields
    }
    private func copy(_ parent: Int32, _ name: String, _ target: URL, limit: Int, stage: RestoreValidationStage,
                      progress: @escaping @Sendable (RestoreValidationProgress) -> Void) throws -> (bytes: Int, digest: String) {
        let entry: RestoreStabilityEntry = stage == .manifest ? .manifest : .catalog
        let input = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw RestoreValidationError.unsafeEntry }; defer { Darwin.close(input) }
        var original = stat()
        guard fstat(input, &original) == 0, original.st_mode & S_IFMT == S_IFREG, original.st_nlink == 1 else { throw RestoreValidationError.unsafeEntry }
        let readID = readDiagnostics?.nextReadID()
        func sample(_ boundary: SourceRestoreReadDiagnostics.Boundary, result: Int? = nil, readErrno: Int32? = nil) {
            if let readID { readDiagnostics?.sample(readID, origin: .validator, role: stage == .manifest ? .manifest : .catalog, boundary: boundary, fd: input, parent: parent, name: name, result: result, readErrno: readErrno) }
        }
        if let readID { readDiagnostics?.sample(readID, origin: .validator, role: stage == .manifest ? .manifest : .catalog, boundary: .baseline, fd: input, parent: parent, name: name, knownFD: original, baseline: original) }
        guard original.st_size > 0, original.st_size <= limit else { throw BackupError.limitExceeded }
        sample(.beforeDestination)
        let output = target.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: output.path, contents: Data()) else { throw ScanError.database }
        try CatalogRepository.protect(output, ownedProtection: ownedProtection)
        let writer = try FileHandle(forWritingTo: output); defer { try? writer.close() }; sample(.afterDestination)
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024); var consumed = 0; var hash = SHA256()
        while true {
            try Task.checkCancellation()
            sample(.beforeReadSyscall)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, $0.count) }; let savedReadError = errno
            sample(.afterReadSyscall, result: count, readErrno: savedReadError)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                stabilityObserver?(RestoreStabilityEvent(entry: entry, reason: .read, fields: 0))
                throw RestoreValidationError.changedSource
            }; if count == 0 { break }
            consumed += count
            guard consumed <= original.st_size, consumed <= limit else {
                stabilityObserver?(RestoreStabilityEvent(entry: entry, reason: .growth, fields: 4))
                throw RestoreValidationError.changedSource
            }
            sample(.beforeConsume); let data = Data(buffer.prefix(count)); try writer.write(contentsOf: data); hash.update(data: data); sample(.afterConsume)
            sample(.beforeProgress); progress(RestoreValidationProgress(stage: stage, completed: consumed, total: Int(original.st_size), unit: .bytes)); sample(.afterProgress)
            try Task.checkCancellation()
        }
        var final = stat(); var pathState = stat()
        let fdStatus = fstat(input, &final); let fdError = errno
        let pathStatus = fstatat(parent, name, &pathState, AT_SYMLINK_NOFOLLOW); let pathError = errno
        let fdOK = fdStatus == 0, pathOK = pathStatus == 0
        if let readID { readDiagnostics?.sample(readID, origin: .validator, role: stage == .manifest ? .manifest : .catalog, boundary: .finalGuard, fd: input, parent: parent, name: name, baseline: original, descriptorResult: .init(final, status: fdStatus, error: fdError), pathResult: .init(pathState, status: pathStatus, error: pathError)) }
        guard consumed == original.st_size, fdOK, same(original, final), pathOK, same(original, pathState) else {
            let fields: UInt16 = (consumed == original.st_size ? 0 : 4) | (fdOK ? differences(original, final) : 1) |
                (pathOK ? differences(original, pathState) : 2)
            stabilityObserver?(RestoreStabilityEvent(entry: entry, reason: fdOK && pathOK ? .fields : .stat, fields: fields))
            throw RestoreValidationError.changedSource
        }
        try writer.synchronize()
        return (consumed, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    private func inspect(_ file: URL, manifest: BackupManifest, progress: @escaping @Sendable (RestoreValidationProgress) -> Void) throws {
        let inspection = try RestoreInspection(file: file)
        do { try inspection.inspect(manifest: manifest, progress: progress); try inspection.close() }
        catch { try inspection.close(); throw error }
    }
}


enum RestoreStageRootFault: Equatable { case beforeRemoval, afterRemoval, parentSync }
/// Retained exact directory authority, including a physically removed but unsynced parent.
private final class RestoreStageRootOwnership: @unchecked Sendable {
    private let url: URL
    private let parentURL: URL
    private let name: String
    private let parent: Int32
    private let root: Int32
    private let parentIdentity: stat
    private let rootIdentity: stat
    private var removed = false
    init(_ requested: URL, ownedProtection: OwnedRestoreProtection) throws {
        url = requested.standardizedFileURL; parentURL = url.deletingLastPathComponent(); name = url.lastPathComponent
        guard requested.isFileURL, !["", ".", ".."].contains(name), !name.contains("/") else { throw RestoreValidationError.unsafeEntry }
        parent = Darwin.open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw RestoreValidationError.unsafeEntry }
        var prior = stat()
        if fstatat(parent, name, &prior, AT_SYMLINK_NOFOLLOW) == 0 {
            guard prior.st_mode & S_IFMT == S_IFDIR else { Darwin.close(parent); throw RestoreValidationError.unsafeEntry }
        } else {
            guard errno == ENOENT, mkdirat(parent, name, 0o700) == 0 else { Darwin.close(parent); throw RestoreValidationError.unsafeEntry }
        }
        root = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { Darwin.close(parent); throw RestoreValidationError.unsafeEntry }
        var p = stat(), r = stat()
        guard fstat(parent, &p) == 0, fstat(root, &r) == 0 else { Darwin.close(root); Darwin.close(parent); throw RestoreValidationError.unsafeEntry }
        parentIdentity = p; rootIdentity = r
        do { try validate(); try CatalogRepository.protect(url, directory: true, ownedProtection: ownedProtection, descriptor: root); try validate() }
        catch { Darwin.close(root); Darwin.close(parent); throw error }
    }
    deinit { Darwin.close(root); Darwin.close(parent) }
    func validate() throws {
        var p = stat(), namedParent = stat(), r = stat(), namedRoot = stat()
        guard fstat(parent, &p) == 0, lstat(parentURL.path, &namedParent) == 0,
              p.st_dev == parentIdentity.st_dev, p.st_ino == parentIdentity.st_ino,
              p.st_dev == namedParent.st_dev, p.st_ino == namedParent.st_ino, namedParent.st_mode & S_IFMT == S_IFDIR,
              fstat(root, &r) == 0, r.st_dev == rootIdentity.st_dev, r.st_ino == rootIdentity.st_ino else { throw RestoreValidationError.unsafeEntry }
        let status = fstatat(parent, name, &namedRoot, AT_SYMLINK_NOFOLLOW)
        if removed { guard status != 0, errno == ENOENT else { throw RestoreValidationError.unsafeEntry }; return }
        guard status == 0, namedRoot.st_mode & S_IFMT == S_IFDIR,
              namedRoot.st_dev == r.st_dev, namedRoot.st_ino == r.st_ino else { throw RestoreValidationError.unsafeEntry }
    }
    func remove(fault: RestoreStageRootFault?) throws {
        try Task.checkCancellation(); try validate()
        if !removed {
            let duplicate = dup(root); guard duplicate >= 0 else { throw RestoreValidationError.unsafeEntry }
            guard let stream = fdopendir(duplicate) else { Darwin.close(duplicate); throw RestoreValidationError.unsafeEntry }
            var empty = true; rewinddir(stream); errno = 0
            while let entry = readdir(stream) {
                let value = withUnsafePointer(to: entry.pointee.d_name) { p in
                    p.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if value != "." && value != ".." { empty = false; break }
            }
            let readError = errno; closedir(stream)
            guard empty, readError == 0 else { throw BackupError.unsafeStage }
            if fault == .beforeRemoval { throw RestoreValidationError.injectedFailure }
            try validate()
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw RestoreValidationError.unsafeEntry }
            removed = true
            if fault == .afterRemoval { throw RestoreValidationError.injectedFailure }
        }
        if fault == .parentSync { throw RestoreValidationError.injectedFailure }
        guard fsync(parent) == 0 else { throw RestoreValidationError.unsafeEntry }
    }
}
