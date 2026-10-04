import Foundation
import Darwin
import CryptoKit

/// Filesystem primitives only. Caller must hold the catalog's exclusive reservation.
/// No live SQLite, migration, retirement or grant operation is performed here.
actor CatalogRestoreFiles {
    private let readDiagnostics: SourceRestoreReadDiagnostics?
    private let markerProtection: RestoreMarkerProtection
    private let markerExclusion: CalibratedMarkerExclusion?
    private let ownedProtection: OwnedRestoreProtection
    private let markerFullArm: MarkerFullProtectionArm
    private let root: URL
    private let rootFD: Int32
    private let owner = UUID()
    private var owned = Set<UUID>()
    private var retained = Set<UUID>()
    private var removedStages = Set<UUID>()
    private var workProgress: @Sendable (Int, Int?) -> Void = { _, _ in }
    func setProgress(_ progress: @escaping @Sendable (Int, Int?) -> Void) { workProgress = progress }
    private var removedMarkers: [UUID: RestoreMarker] = [:]
    private let observer: @Sendable (RestoreFileEvent) throws -> Void
    private let fault: @Sendable (RestoreFileEvent) -> Int32?
    init(root: URL, observer: @escaping @Sendable (RestoreFileEvent) throws -> Void = { _ in },
         fault: @escaping @Sendable (RestoreFileEvent) -> Int32? = { _ in nil },
         readDiagnostics: SourceRestoreReadDiagnostics? = nil,
         markerProtection: RestoreMarkerProtection = .full,
         markerExclusion: CalibratedMarkerExclusion? = nil, markerFullArm: MarkerFullProtectionArm = .production, ownedProtection: OwnedRestoreProtection = .production) throws {
        guard root.isFileURL else { throw RestoreFileError.unsafeEntry }
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RestoreFileError.syscall(errno) }
        self.root = root.resolvingSymlinksInPath().standardizedFileURL; rootFD = fd
        self.observer = observer; self.fault = fault; self.readDiagnostics = readDiagnostics
        self.markerProtection = markerProtection; self.markerExclusion = markerExclusion; self.markerFullArm = markerFullArm; self.ownedProtection = ownedProtection
    }
    deinit { Darwin.close(rootFD) }
    private func step<T>(_ operation: RestoreFileOperation, _ role: RestoreFileRole, cleanup: ((T) -> Void)? = nil, _ body: () throws -> T) throws -> T {
        let event = RestoreFileEvent(operation: operation, role: role, moment: .before)
        try observer(event); if let error = fault(event) { throw RestoreFileError.syscall(error) }
        let value = try body()
        do { try observer(RestoreFileEvent(operation: operation, role: role, moment: .after)) }
        catch { cleanup?(value); throw error }; return value
    }
    private func close(_ fd: Int32, _ role: RestoreFileRole, didClose: () -> Void = {}) throws {
        try step(.close, role) { guard Darwin.close(fd) == 0 else { throw RestoreFileError.syscall(errno) }; didClose() }
    }
    private func sync(_ fd: Int32, _ role: RestoreFileRole, directory: Bool) throws {
        try step(directory ? .directorySync : .fileSync, role) { guard fsync(fd) == 0 else { throw RestoreFileError.syscall(errno) } }
    }
    private func openDir(_ parent: Int32, _ name: String, _ role: RestoreFileRole) throws -> Int32 {
        try step(.open, role, cleanup: { Darwin.close($0) }) {
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw RestoreFileError.syscall(errno) }; return fd
        }
    }
    private func names(_ fd: Int32) throws -> Set<String> {
        let copy = dup(fd); guard copy >= 0 else { throw RestoreFileError.syscall(errno) }
        guard let dir = fdopendir(copy) else { Darwin.close(copy); throw RestoreFileError.syscall(errno) }
        defer { closedir(dir) }; rewinddir(dir); var values = Set<String>()
        while true {
            try Task.checkCancellation(); errno = 0
            guard let entry = readdir(dir) else { guard errno == 0 else { throw RestoreFileError.syscall(errno) }; return values }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { values.insert(name) }
            guard values.count <= 3 else { throw RestoreFileError.unsafeEntry }
        }
    }
    private func regular(_ parent: Int32, _ name: String, _ flags: Int32, _ role: RestoreFileRole, baseline: ((Int32, stat) -> Void)? = nil) throws -> (Int32, stat) {
        try step(.open, role, cleanup: { value in
            Darwin.close(value.0)
            if flags & (O_CREAT | O_EXCL) == (O_CREAT | O_EXCL) { unlinkat(parent, name, 0) }
        }) {
            let fd = openat(parent, name, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            guard fd >= 0 else { throw RestoreFileError.syscall(errno) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { Darwin.close(fd); throw RestoreFileError.unsafeEntry }
            baseline?(fd, info); return (fd, info)
        }
    }
    private func stable(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && a.st_nlink == b.st_nlink &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private func checked(_ stage: RestoreFileStage) throws -> Int32 {
        guard stage.owner == owner, owned.contains(stage.transaction) else { throw RestoreFileError.foreignStage }
        return try openDir(rootFD, stage.name, .stage)
    }
    private func protect(_ path: URL, _ role: RestoreFileRole, directory: Bool = false, descriptor: Int32? = nil) throws {
        try step(.protect, role) { try CatalogRepository.protect(path, directory: directory, ownedProtection: ownedProtection, descriptor: descriptor) }
    }
    func createStage(transaction: UUID = UUID()) throws -> RestoreFileStage {
        try Task.checkCancellation()
        let stage = RestoreFileStage(transaction: transaction, owner: owner)
        var created = false
        do {
            try protect(root, .root, directory: true)
            try step(.mkdir, .stage) { guard mkdirat(rootFD, stage.name, 0o700) == 0 else { throw RestoreFileError.syscall(errno) }; owned.insert(transaction); created = true }
            try protect(root.appendingPathComponent(stage.name), .stage, directory: true)
            let fd = try checked(stage); defer { Darwin.close(fd) }
            try sync(fd, .stage, directory: true); try sync(rootFD, .ancestor, directory: true)
            return stage
        } catch { if created && !retained.contains(transaction) { try? discard(stage) }; throw error }
    }
    private func writeAll(_ fd: Int32, _ bytes: Data, _ role: RestoreFileRole) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = try step(.write, role) { Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), bytes.count - offset) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw RestoreFileError.syscall(count < 0 ? errno : EIO) }; offset += count
            }
        }
    }
    private func readFile(_ parent: Int32, _ name: String, limit: Int, role: RestoreFileRole,
                          consume: (Data) throws -> Void) throws -> (Int, String) {
        let readID = readDiagnostics?.nextReadID()
        let (fd, before) = try regular(parent, name, O_RDONLY, role, baseline: { fd, value in
            if let readID { self.readDiagnostics?.sample(readID, origin: .files, role: .init(role), boundary: .baseline, fd: fd, parent: parent, name: name, knownFD: value, baseline: value) }
        }); defer { Darwin.close(fd) }
        func sample(_ boundary: SourceRestoreReadDiagnostics.Boundary, result: Int? = nil, readErrno: Int32? = nil) {
            if let readID { readDiagnostics?.sample(readID, origin: .files, role: .init(role), boundary: boundary, fd: fd, parent: parent, name: name, result: result, readErrno: readErrno) }
        }
        sample(.afterOpenObserver)
        guard before.st_size > 0, before.st_size <= limit else { throw BackupError.limitExceeded }
        sample(.beforeProgress); workProgress(0, Int(before.st_size)); sample(.afterProgress)
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024); var bytes = 0; var digest = SHA256()
        while true {
            try Task.checkCancellation()
            sample(.beforeReadObserver)
            let count = try step(.read, role) {
                sample(.beforeReadSyscall)
                let result = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }; let savedError = errno
                sample(.afterReadSyscall, result: result, readErrno: savedError); return result
            }
            sample(.afterReadObserver)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw RestoreFileError.syscall(errno) }; if count == 0 { break }
            bytes += count
            guard bytes <= before.st_size, bytes <= limit else {
                try observer(RestoreFileEvent(operation: .verify, role: role, moment: .after, changedFields: 1))
                throw RestoreFileError.changedSource
            }
            sample(.beforeConsume); let data = Data(buffer.prefix(count)); digest.update(data: data); try consume(data); sample(.afterConsume)
            sample(.beforeProgress); workProgress(bytes, Int(before.st_size)); sample(.afterProgress)
        }
        var after = stat(); var path = stat()
        let descriptorStatus = fstat(fd, &after); let descriptorError = errno
        let pathStatus = fstatat(parent, name, &path, AT_SYMLINK_NOFOLLOW); let pathError = errno
        let descriptorOK = descriptorStatus == 0, pathOK = pathStatus == 0
        if let readID { readDiagnostics?.sample(readID, origin: .files, role: .init(role), boundary: .finalGuard, fd: fd, parent: parent, name: name, baseline: before, descriptorResult: .init(after, status: descriptorStatus, error: descriptorError), pathResult: .init(path, status: pathStatus, error: pathError)) }
        guard bytes == before.st_size, descriptorOK, stable(before, after), pathOK, stable(before, path) else {
            var fields: UInt16 = bytes == before.st_size ? 0 : 1
            if !descriptorOK { fields |= 2 }; if !pathOK { fields |= 4 }
            for (value, shift) in [(after, 3), (path, 8)] {
                if value.st_dev != before.st_dev || value.st_ino != before.st_ino { fields |= 1 << shift }
                if value.st_size != before.st_size { fields |= 1 << (shift + 1) }
                if value.st_nlink != before.st_nlink { fields |= 1 << (shift + 2) }
                if value.st_mtimespec.tv_sec != before.st_mtimespec.tv_sec || value.st_mtimespec.tv_nsec != before.st_mtimespec.tv_nsec { fields |= 1 << (shift + 3) }
                if value.st_ctimespec.tv_sec != before.st_ctimespec.tv_sec || value.st_ctimespec.tv_nsec != before.st_ctimespec.tv_nsec { fields |= 1 << (shift + 4) }
            }
            try observer(RestoreFileEvent(operation: .verify, role: role, moment: .after, changedFields: fields))
            throw RestoreFileError.changedSource
        }
        return (bytes, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
    private func copy(_ source: Int32, _ name: String, _ destination: Int32, _ target: String, _ path: URL,
                      limit: Int, role: RestoreFileRole) throws -> (Int, String) {
        let (fd, _) = try regular(destination, target, O_WRONLY | O_CREAT | O_EXCL, role)
        var closed = false; defer { if !closed { Darwin.close(fd) } }
        try protect(path, role, descriptor: fd)
        let result = try readFile(source, name, limit: limit, role: role) { try writeAll(fd, $0, role) }
        try step(.protect, role) { guard fchmod(fd, 0o400) == 0 else { throw RestoreFileError.syscall(errno) } }
        try sync(fd, role, directory: false); try close(fd, role, didClose: { closed = true })
        return result
    }
    func copyPackage(from source: URL, manifest: BackupManifest, into stage: RestoreFileStage,
                     slot: RestoreSnapshotSlot) throws -> RestoreSnapshotReference {
        try Task.checkCancellation(); guard !retained.contains(stage.transaction), source.isFileURL,
              manifest.formatVersion == 1, manifest.schemaVersion == 3 else { throw RestoreFileError.invalidMarker }
        let sourceFD = Darwin.open(source.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else { throw RestoreFileError.syscall(errno) }; defer { Darwin.close(sourceFD) }
        guard try names(sourceFD) == ["manifest.json", "catalog.sqlite"] else { throw RestoreFileError.unsafeEntry }
        var before = stat(); guard fstat(sourceFD, &before) == 0 else { throw RestoreFileError.syscall(errno) }
        let parentReadID = readDiagnostics?.nextReadID()
        if let parentReadID { readDiagnostics?.sample(parentReadID, origin: .files, role: .sourceParent, boundary: .baseline, fd: sourceFD, knownFD: before, baseline: before) }
        let destination = try checked(stage); defer { Darwin.close(destination) }
        let role: RestoreFileRole = slot == .old ? .old : .new
        try step(.mkdir, role) { guard mkdirat(destination, slot.rawValue, 0o700) == 0 else { throw RestoreFileError.syscall(errno) } }
        let path = root.appendingPathComponent(stage.name).appendingPathComponent(slot.rawValue)
        try protect(path, role, directory: true)
        let folder = try openDir(destination, slot.rawValue, role); defer { Darwin.close(folder) }
        let metadata = try copy(sourceFD, "manifest.json", folder, "manifest.json", path.appendingPathComponent("manifest.json"), limit: BackupManifest.maximumManifestBytes, role: role)
        var encoded = Data()
        _ = try readFile(folder, "manifest.json", limit: BackupManifest.maximumManifestBytes, role: role) { encoded.append($0) }
        guard try JSONDecoder().decode(BackupManifest.self, from: encoded) == manifest else { throw RestoreFileError.invalidMarker }
        try BackupFiles.checkLengths(catalog: manifest.catalogBytes, manifest: metadata.0, options: BackupOptions())
        let catalog = try copy(sourceFD, "catalog.sqlite", folder, "catalog.sqlite", path.appendingPathComponent("catalog.sqlite"), limit: manifest.catalogBytes, role: role)
        guard catalog.0 == manifest.catalogBytes, catalog.1 == manifest.catalogSHA256 else { throw RestoreFileError.missingEvidence }
        var after = stat()
        let statStatus = fstat(sourceFD, &after); let statError = errno; let statOK = statStatus == 0
        if let parentReadID { readDiagnostics?.sample(parentReadID, origin: .files, role: .sourceParent, boundary: .finalGuard, fd: sourceFD, baseline: before, descriptorResult: .init(after, status: statStatus, error: statError)) }
        guard statOK, stable(before, after) else {
            var fields: UInt16 = statOK ? 0 : 2
            if statOK {
                if before.st_dev != after.st_dev || before.st_ino != after.st_ino { fields |= 1 << 3 }
                if before.st_size != after.st_size { fields |= 1 << 4 }
                if before.st_nlink != after.st_nlink { fields |= 1 << 5 }
                if before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec || before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec { fields |= 1 << 6 }
                if before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec || before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec { fields |= 1 << 7 }
            }
            try observer(RestoreFileEvent(operation: .verify, role: .sourceParent, moment: .after, changedFields: fields))
            throw RestoreFileError.changedSource
        }
        do {
            guard try names(sourceFD) == ["manifest.json", "catalog.sqlite"] else {
                try observer(RestoreFileEvent(operation: .verify, role: .sourceParent, moment: .after, changedFields: 1 << 13))
                throw RestoreFileError.changedSource
            }
        } catch {
            if error as? RestoreFileError != .changedSource {
                try observer(RestoreFileEvent(operation: .verify, role: .sourceParent, moment: .after, changedFields: 1 << 13))
            }
            throw error
        }
        try sync(folder, role, directory: true); try sync(destination, .stage, directory: true); try sync(rootFD, .ancestor, directory: true)
        return RestoreSnapshotReference(path: stage.name + "/" + slot.rawValue, catalogBytes: catalog.0, catalogSHA256: catalog.1,
            manifestBytes: metadata.0, manifestSHA256: metadata.1, schemaVersion: 3)
    }
    private func verify(_ reference: RestoreSnapshotReference, transaction: UUID) throws {
        let stage = try openDir(rootFD, "restore-" + transaction.uuidString, .stage); defer { Darwin.close(stage) }
        let name = reference.path.split(separator: "/").last.map(String.init) ?? ""
        let role: RestoreFileRole = name == "old" ? .old : .new
        let folder = try openDir(stage, name, role); defer { Darwin.close(folder) }
        guard try names(folder) == ["manifest.json", "catalog.sqlite"] else { throw RestoreFileError.unsafeEntry }
        let metadata = try readFile(folder, "manifest.json", limit: reference.manifestBytes, role: role) { _ in }
        let catalog = try readFile(folder, "catalog.sqlite", limit: reference.catalogBytes, role: role) { _ in }
        guard metadata.0 == reference.manifestBytes, metadata.1 == reference.manifestSHA256,
              catalog.0 == reference.catalogBytes, catalog.1 == reference.catalogSHA256 else { throw RestoreFileError.missingEvidence }
        try step(.verify, role) {}
    }
    func prepareInstallation(_ stage: RestoreFileStage, new: RestoreSnapshotReference) throws {
        let expected = "restore-" + stage.transaction.uuidString + "/new"
        guard new.path == expected, !retained.contains(stage.transaction) else { throw RestoreFileError.invalidMarker }
        try verify(new, transaction: stage.transaction)
        let fd = try checked(stage); defer { Darwin.close(fd) }
        let source = try openDir(fd, "new", .new); defer { Darwin.close(source) }
        var a = stat(); var b = stat(); guard fstat(fd, &a) == 0, fstat(rootFD, &b) == 0, a.st_dev == b.st_dev else { throw RestoreFileError.syscall(EXDEV) }
        let result = try copy(source, "catalog.sqlite", fd, "install.sqlite", root.appendingPathComponent(stage.name).appendingPathComponent("install.sqlite"), limit: new.catalogBytes, role: .install)
        guard result.1 == new.catalogSHA256 else { throw RestoreFileError.missingEvidence }
        try sync(fd, .stage, directory: true); try sync(rootFD, .ancestor, directory: true)
    }
    func readMarker() throws -> RestoreMarker? {
        var info = stat()
        if fstatat(rootFD, "restore-marker.json", &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }; throw RestoreFileError.syscall(errno)
        }
        var data = Data(); _ = try readFile(rootFD, "restore-marker.json", limit: RestoreMarker.maximumBytes, role: .marker) { data.append($0) }
        let marker = try RestoreMarker.decode(data)
        try verify(marker.old, transaction: marker.transaction); try verify(marker.new, transaction: marker.transaction)
        return marker
    }
    /// Adopt only evidence referenced by a fully checked marker after a process restart.
    func retainedStage() throws -> (RestoreFileStage, RestoreMarker)? {
        guard let marker = try readMarker() else { return nil }
        owned.insert(marker.transaction); retained.insert(marker.transaction)
        let stage = RestoreFileStage(transaction: marker.transaction, owner: owner)
        try cleanupRecoveryTemporary(stage, marker: marker)
        return (stage, marker)
    }
    /// Only marker-adopted, byte-proven partial recovery copies may be discarded after a crash.
    private func cleanupRecoveryTemporary(_ stage: RestoreFileStage, marker: RestoreMarker) throws {
        try retainedAuthority(stage, marker: marker)
        let fd = try checked(stage); defer { Darwin.close(fd) }
        let duplicate = dup(fd); guard duplicate >= 0 else { throw RestoreFileError.syscall(errno) }
        guard let directory = fdopendir(duplicate) else { Darwin.close(duplicate); throw RestoreFileError.syscall(errno) }
        defer { closedir(directory) }; rewinddir(directory)
        var entries = Set<String>(); var temporary: String?
        while true {
            try Task.checkCancellation(); errno = 0
            guard let entry = readdir(directory) else { guard errno == 0 else { throw RestoreFileError.syscall(errno) }; break }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            entries.insert(name); guard entries.count <= 4 else { throw RestoreFileError.unsafeEntry }
            if ["old", "new", "install.sqlite"].contains(name) { continue }
            guard name.hasPrefix("recover-"), name.hasSuffix(".sqlite"), temporary == nil else { throw RestoreFileError.unsafeEntry }
            let text = String(name.dropFirst(8).dropLast(7))
            guard let uuid = UUID(uuidString: text), uuid.uuidString == text else { throw RestoreFileError.unsafeEntry }
            temporary = name
        }
        guard entries.contains("old"), entries.contains("new") else { throw RestoreFileError.missingEvidence }
        guard let temporary else { try sync(fd, .stage, directory: true); return }
        let reference = marker.selected
        let role: RestoreFileRole = marker.state == .prepared ? .old : .new
        let folder = try openDir(fd, marker.state == .prepared ? "old" : "new", role); defer { Darwin.close(folder) }
        let (source, sourceInfo) = try regular(folder, "catalog.sqlite", O_RDONLY, role); defer { Darwin.close(source) }
        let (input, before) = try regular(fd, temporary, O_RDONLY, .install); defer { Darwin.close(input) }
        guard before.st_size >= 0, before.st_size <= reference.catalogBytes else { throw RestoreFileError.unsafeEntry }
        if before.st_size > 0 {
            _ = try readFile(fd, temporary, limit: reference.catalogBytes, role: .install) { data in
                var bytes = [UInt8](repeating: 0, count: data.count); var offset = 0
                while offset < bytes.count {
                    try Task.checkCancellation()
                    let remaining = bytes.count - offset
                    let count = try step(.read, role) { bytes.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress!.advanced(by: offset), remaining) } }
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw RestoreFileError.missingEvidence }; offset += count
                }
                guard Data(bytes) == data else { throw RestoreFileError.missingEvidence }
            }
        }
        var current = stat(); var sourceCurrent = stat(); var sourcePath = stat()
        guard fstat(source, &sourceCurrent) == 0, fstatat(folder, "catalog.sqlite", &sourcePath, AT_SYMLINK_NOFOLLOW) == 0,
              stable(sourceInfo, sourceCurrent), stable(sourceInfo, sourcePath) else { throw RestoreFileError.changedSource }
        try step(.unlink, .install) {
            guard fstat(input, &current) == 0, stable(before, current),
                  fstatat(fd, temporary, &current, AT_SYMLINK_NOFOLLOW) == 0, stable(before, current) else { throw RestoreFileError.changedSource }
            guard unlinkat(fd, temporary, 0) == 0 else { throw RestoreFileError.syscall(errno) }
        }
        try sync(fd, .stage, directory: true)
    }
    func publish(_ marker: RestoreMarker, stage: RestoreFileStage) throws {
        guard stage.transaction == marker.transaction else { throw RestoreFileError.foreignStage }
        let fd = try checked(stage); defer { Darwin.close(fd) }
        let prior = try readMarker()
        if marker.state == .prepared { guard prior == nil else { throw RestoreFileError.markerPresent } }
        else { guard let prior, prior.transaction == marker.transaction, prior.old == marker.old, prior.new == marker.new else { throw RestoreFileError.invalidMarker } }
        let bytes = try marker.encoded()
        if marker.state == .prepared {
            let install = try readFile(fd, "install.sqlite", limit: marker.new.catalogBytes, role: .install) { _ in }
            guard install.0 == marker.new.catalogBytes, install.1 == marker.new.catalogSHA256 else { throw RestoreFileError.missingEvidence }
        }
        try verify(marker.old, transaction: marker.transaction); try verify(marker.new, transaction: marker.transaction)
        let temporary = "marker-" + UUID().uuidString + ".tmp"
        let (output, _) = try regular(rootFD, temporary, O_WRONLY | O_CREAT | O_EXCL, .marker)
        var closed = false; var moved = false
        defer { if !closed { Darwin.close(output) }; if !moved { unlinkat(rootFD, temporary, 0) } }
        try step(.protect, .marker) { try markerProtection.apply(root.appendingPathComponent(temporary), descriptor: output, calibratedExclusion: markerExclusion, fullArm: markerFullArm) }; try writeAll(output, bytes, .marker)
        try sync(output, .marker, directory: false); try close(output, .marker, didClose: { closed = true })
        try step(.rename, .marker) {
            guard renameat(rootFD, temporary, rootFD, "restore-marker.json") == 0 else { throw RestoreFileError.syscall(errno) }
            moved = true; retained.insert(stage.transaction)
        }
        try sync(rootFD, .root, directory: true)
    }
    /// Atomic replacement primitive against the reserved root, never unlinking live first.
    func replaceInstallation(_ stage: RestoreFileStage, new: RestoreSnapshotReference) throws {
        guard let marker = try readMarker(), marker.transaction == stage.transaction, marker.state == .prepared, marker.new == new else { throw RestoreFileError.invalidMarker }
        let fd = try checked(stage); defer { Darwin.close(fd) }
        let installed = try readFile(fd, "install.sqlite", limit: new.catalogBytes, role: .install) { _ in }
        guard installed.0 == new.catalogBytes, installed.1 == new.catalogSHA256 else { throw RestoreFileError.missingEvidence }
        try step(.rename, .install) { guard renameat(fd, "install.sqlite", rootFD, "catalog.sqlite") == 0 else { throw RestoreFileError.syscall(errno) } }
        try sync(fd, .stage, directory: true); try sync(rootFD, .root, directory: true)
    }
    /// Refresh a privately owned pre-PREPARED package after checked mutable-epoch renewal.
    func refreshPackage(_ stage: RestoreFileStage, slot: RestoreSnapshotSlot, manifest: BackupManifest) throws -> RestoreSnapshotReference {
        guard !retained.contains(stage.transaction) else { throw RestoreFileError.markerPresent }
        let fd = try checked(stage); defer { Darwin.close(fd) }
        let role: RestoreFileRole = slot == .old ? .old : .new
        let folder = try openDir(fd, slot.rawValue, role); defer { Darwin.close(folder) }
        let catalog = try readFile(folder, "catalog.sqlite", limit: BackupManifest.maximumCatalogBytes, role: role) { _ in }
        let value = BackupManifest(formatVersion: 1, schemaVersion: manifest.schemaVersion, createdAt: manifest.createdAt,
            revision: manifest.revision, counts: manifest.counts, catalogBytes: catalog.0, catalogSHA256: catalog.1)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; let data = try encoder.encode(value)
        try BackupFiles.checkLengths(catalog: catalog.0, manifest: data.count, options: BackupOptions())
        let temporary = "manifest-" + UUID().uuidString + ".tmp"
        let (output, _) = try regular(folder, temporary, O_WRONLY | O_CREAT | O_EXCL, role)
        var closed = false; var moved = false
        defer { if !closed { Darwin.close(output) }; if !moved { unlinkat(folder, temporary, 0) } }
        try protect(root.appendingPathComponent(stage.name).appendingPathComponent(slot.rawValue).appendingPathComponent(temporary), role, descriptor: output)
        try writeAll(output, data, role); try sync(output, role, directory: false); try close(output, role, didClose: { closed = true })
        try step(.rename, role) { guard renameat(folder, temporary, folder, "manifest.json") == 0 else { throw RestoreFileError.syscall(errno) }; moved = true }
        try sync(folder, role, directory: true); try sync(fd, .stage, directory: true); try sync(rootFD, .ancestor, directory: true)
        let metadata = try readFile(folder, "manifest.json", limit: data.count, role: role) { _ in }
        return RestoreSnapshotReference(path: stage.name + "/" + slot.rawValue, catalogBytes: catalog.0, catalogSHA256: catalog.1,
            manifestBytes: metadata.0, manifestSHA256: metadata.1, schemaVersion: manifest.schemaVersion)
    }
    /// Re-copy marker-selected retained evidence on every retry; never infer authority from live bytes.
    func recoverInstallation(_ stage: RestoreFileStage, marker: RestoreMarker) throws {
        try retainedAuthority(stage, marker: marker)
        let reference = marker.selected
        try verify(reference, transaction: stage.transaction)
        let fd = try checked(stage); defer { Darwin.close(fd) }
        let slot = marker.state == .prepared ? "old" : "new"
        let source = try openDir(fd, slot, marker.state == .prepared ? .old : .new); defer { Darwin.close(source) }
        for name in ["catalog.sqlite-journal", "catalog.sqlite-wal", "catalog.sqlite-shm"] {
            var info = stat()
            if fstatat(rootFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { throw RestoreFileError.unsafeEntry }
            guard errno == ENOENT else { throw RestoreFileError.syscall(errno) }
        }
        var parent = stat(); var child = stat()
        guard fstat(rootFD, &parent) == 0, fstat(fd, &child) == 0, parent.st_dev == child.st_dev else { throw RestoreFileError.syscall(EXDEV) }
        let temporary = "recover-" + UUID().uuidString + ".sqlite"
        var moved = false; defer { if !moved { unlinkat(fd, temporary, 0) } }
        let result = try copy(source, "catalog.sqlite", fd, temporary, root.appendingPathComponent(stage.name).appendingPathComponent(temporary),
            limit: reference.catalogBytes, role: .install)
        guard result.0 == reference.catalogBytes, result.1 == reference.catalogSHA256 else { throw RestoreFileError.missingEvidence }
        try sync(fd, .stage, directory: true)
        try step(.rename, .install) {
            guard renameat(fd, temporary, rootFD, "catalog.sqlite") == 0 else { throw RestoreFileError.syscall(errno) }; moved = true
        }
        try sync(fd, .stage, directory: true); try sync(rootFD, .root, directory: true)
    }
    private func retainedAuthority(_ stage: RestoreFileStage, marker: RestoreMarker) throws {
        guard stage.transaction == marker.transaction, retained.contains(stage.transaction) else { throw RestoreFileError.foreignStage }
        let persisted = try readMarker()
        guard persisted == nil || persisted == marker else { throw RestoreFileError.invalidMarker }
        // Nil is legal only for this retained helper after its own ambiguous marker removal.
        if persisted == nil { guard removedMarkers[stage.transaction] == marker else { throw RestoreFileError.invalidMarker } }
    }
    func selectedManifest(_ stage: RestoreFileStage, marker: RestoreMarker) throws -> BackupManifest {
        try retainedAuthority(stage, marker: marker)
        let reference = marker.selected; try verify(reference, transaction: stage.transaction)
        let fd = try checked(stage); defer { Darwin.close(fd) }
        let folder = try openDir(fd, marker.state == .prepared ? "old" : "new", marker.state == .prepared ? .old : .new); defer { Darwin.close(folder) }
        var data = Data(); _ = try readFile(folder, "manifest.json", limit: reference.manifestBytes, role: marker.state == .prepared ? .old : .new) { data.append($0) }
        try RestoreDomain.shape(data, context: "manifest")
        let value = try JSONDecoder().decode(BackupManifest.self, from: data)
        guard value.formatVersion == 1, value.schemaVersion == reference.schemaVersion, value.revision >= 0,
              value.createdAt.timeIntervalSince1970.isFinite, value.catalogBytes == reference.catalogBytes,
              value.catalogSHA256 == reference.catalogSHA256 else { throw RestoreFileError.invalidMarker }
        return value
    }
    func verifyInstalled(_ reference: RestoreSnapshotReference) throws {
        let value = try readFile(rootFD, "catalog.sqlite", limit: reference.catalogBytes, role: .install) { _ in }
        guard value.0 == reference.catalogBytes, value.1 == reference.catalogSHA256 else { throw RestoreFileError.missingEvidence }
    }
    /// Every recovery requires a new source grant, including rollback to OLD.
    func removeGrant() throws {
        var info = stat()
        if fstatat(rootFD, "source.bookmark", &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw RestoreFileError.unsafeEntry }
            try step(.unlink, .root) { guard unlinkat(rootFD, "source.bookmark", 0) == 0 else { throw RestoreFileError.syscall(errno) } }
        } else { guard errno == ENOENT else { throw RestoreFileError.syscall(errno) } }
        try sync(rootFD, .root, directory: true)
    }
    /// Retry a known unlink/sync ambiguity under the same retained session authority.
    func finishMarkerRemoval(_ stage: RestoreFileStage, marker: RestoreMarker) throws {
        try retainedAuthority(stage, marker: marker)
        _ = try checkedAndClose(stage)
        try step(.unlink, .marker) {
            if unlinkat(rootFD, "restore-marker.json", 0) != 0 { guard errno == ENOENT else { throw RestoreFileError.syscall(errno) } }
            removedMarkers[stage.transaction] = marker
        }
        try sync(rootFD, .root, directory: true)
        retained.remove(stage.transaction); removedMarkers.removeValue(forKey: stage.transaction)
    }
    func removeMarker(_ stage: RestoreFileStage) throws {
        guard let marker = try readMarker(), marker.transaction == stage.transaction else { throw RestoreFileError.invalidMarker }
        _ = try checkedAndClose(stage)
        try step(.unlink, .marker) { guard unlinkat(rootFD, "restore-marker.json", 0) == 0 else { throw RestoreFileError.syscall(errno) } }
        try sync(rootFD, .root, directory: true)
        retained.remove(stage.transaction)
    }
    private func checkedAndClose(_ stage: RestoreFileStage) throws -> Bool { let fd = try checked(stage); try close(fd, .stage); return true }
    func discard(_ stage: RestoreFileStage) throws {
        guard stage.owner == owner, owned.contains(stage.transaction) else { throw RestoreFileError.foreignStage }
        if removedStages.contains(stage.transaction) {
            try sync(rootFD, .root, directory: true)
            removedStages.remove(stage.transaction); owned.remove(stage.transaction); return
        }
        guard !retained.contains(stage.transaction) else { throw RestoreFileError.markerPresent }
        // Even a new helper instance must never discard evidence named by a marker.
        if let marker = try readMarker(), marker.transaction == stage.transaction { throw RestoreFileError.markerPresent }
        let fd = try checked(stage); defer { Darwin.close(fd) }
        let entries = try names(fd); guard entries.isSubset(of: ["old", "new", "install.sqlite"]) else { throw RestoreFileError.unsafeEntry }
        for name in ["old", "new"] where entries.contains(name) {
            let role: RestoreFileRole = name == "old" ? .old : .new
            let folder = try openDir(fd, name, role); defer { Darwin.close(folder) }
            let files = try names(folder); guard files.isSubset(of: ["manifest.json", "catalog.sqlite"]) else { throw RestoreFileError.unsafeEntry }
            for file in files {
                let (input, _) = try regular(folder, file, O_RDONLY, role); try close(input, role)
                try step(.unlink, role) { guard unlinkat(folder, file, 0) == 0 else { throw RestoreFileError.syscall(errno) } }
            }
            try sync(folder, role, directory: true)
            try step(.unlink, role) { guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw RestoreFileError.syscall(errno) } }
            try sync(fd, .stage, directory: true)
        }
        if entries.contains("install.sqlite") {
            let (input, _) = try regular(fd, "install.sqlite", O_RDONLY, .install); try close(input, .install)
            try step(.unlink, .install) { guard unlinkat(fd, "install.sqlite", 0) == 0 else { throw RestoreFileError.syscall(errno) } }
        }
        try step(.unlink, .stage) { guard unlinkat(rootFD, stage.name, AT_REMOVEDIR) == 0 else { throw RestoreFileError.syscall(errno) }; removedStages.insert(stage.transaction) }
        try sync(rootFD, .root, directory: true)
        removedStages.remove(stage.transaction); owned.remove(stage.transaction)
    }
}
