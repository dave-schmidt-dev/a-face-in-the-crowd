import Foundation
import Combine
import AFITCCore
import CryptoKit
import Darwin

/// Stable UI owner: failures retain recovery authority, returned actors and owned stages.
@MainActor
final class CatalogBackupService: ObservableObject {
    enum State: String { case idle, preparing, exportPreview, validating, restorePreview, writing, draining, restoring, recoveryRequired, failed, finished }
    enum Picker: String, Identifiable { case destination, restore; var id: String { rawValue } }
    struct Preview {
        let manifest: BackupManifest
        let bytes: Int
        var summary: String {
            let c = manifest.counts
            return "Revision \(manifest.revision) · \(bytes) bytes\n\(c.photos) photos · \(c.people) people · \(c.currentFaces) face records\n\(c.manualFaceStates) manual states · \(c.negativePairs) exclusions · \(c.deferrals) deferrals · \(c.decisionEvents) decisions"
        }
    }
    @Published private(set) var state = State.idle
    @Published private(set) var message = ""
    @Published private(set) var progress: CatalogOperationProgress?
    @Published private(set) var preview: Preview?
    @Published private(set) var volumeWarning = "Choose independent storage when possible. A backup on your photo drive will not survive that drive failing."
    @Published var picker: Picker?
    @Published private(set) var currentRevision: Int?
    @Published private(set) var destinationSelected = false
    @Published private(set) var probe = "Active 0 · Restore 0 · Open 0 · Adopt 0 · Returned 0 · Dropped 0"
    private weak var services: AppServices?
    private var task: Task<Void, Never>?
    private var operationID: UUID?
    private var operationSession: UInt64 = 0
    private var prepared: PreparedCatalogBackup?
    private var preparedOwner: CatalogRepository?
    #if DEBUG
    private var preparedReference: (ObjectIdentifier, URL)?
    var retainedPreparedProbe: String {
        let same = preparedOwner.flatMap { owner in prepared.map { value in
            preparedReference?.0 == ObjectIdentifier(owner) && preparedReference?.1 == value.directory
        } } ?? false
        return "Prepared \(prepared == nil ? 0 : 1) · Same owner and stage \(same ? 1 : 0)"
    }
    #endif
    private var validator: RestoreValidator?
    private var validated: ValidatedCatalogBackup?
    private var capturedCatalog: CatalogRepository?
    private var capturedCache: URL?
    private var originalSource: URL?
    private var destination: URL?
    private var restoreOwner: CatalogRestoreRepository?
    private var returned: CatalogRepository?
    private var preservedOriginal = false
    private var exportOwner: CatalogBackupExport?
    private var restores = 0, opens = 0, adopts = 0, drops = 0
    #if DEBUG
    let testSupport: CatalogBackupTestSupport
    private var privacyFixtures: SyntheticPrivacyBackupFixtures?
    #endif
    init(services: AppServices) {
        self.services = services
        #if DEBUG
        testSupport = CatalogBackupTestSupport(launch: services.launch)
        testSupport.changed = { [weak self] in
            guard let self, let id = self.operationID, self.owns(id, closed: true) else { return }
            self.objectWillChange.send()
        }
        #endif
    }
    var protectedAuthority: ProtectedCatalogAuthority? {
        if let returned { return .live(returned) }
        if let restoreOwner { return .restore(restoreOwner) }
        return nil
    }
    var retainedPreparedOwner: CatalogRepository? { prepared == nil ? nil : preparedOwner }
    /// Explicit unlock may clean only existing exact owners; a retired prepared owner is retained on failure.
    func finishProtectedAdoption(_ permit: ProtectedReopenPermit) async -> Bool {
        guard let services, services.protection.accepts(permit), task == nil else { return false }
        do {
            let epoch = try services.protection.cleanupGeneration(permit)
            if let exportOwner { try await exportOwner.cleanup(); self.exportOwner = nil }
            try services.protection.requireCleanup(epoch, permit: permit)
            try await cleanupLocal(permit: permit)
            restoreOwner = nil; returned = nil; capturedCatalog = nil; capturedCache = nil
            operationID = nil; preview = nil; destination = nil; destinationSelected = false
            state = .idle; message = ""; return true
        } catch {
            // Successful Core reopen is already strongly held by protection, even if cleanup fails.
            if services.protection.accepts(permit) {
                restoreOwner = nil; returned = nil; capturedCatalog = nil; capturedCache = nil; operationID = nil
                state = .failed; message = "Catalog reopened. Retained backup cleanup requires an explicit retry."
            }
            return false
        }
    }
    func cancelForProtection() { task?.cancel(); picker = nil }
    func finishProtectedWork() async { if let task { await task.value } }
    var busy: Bool { task != nil }
    var canCancel: Bool { [.preparing, .validating, .writing].contains(state) }
    var canBegin: Bool { !busy && [.idle, .finished].contains(state) && services?.privacy.blocksActions != true && services?.privacy.catalogDeleted != true }
    var privacyMayDrain: Bool { restoreOwner == nil && returned == nil && ![.draining, .restoring, .recoveryRequired].contains(state) }
    func cancelForPrivacyDrain() throws {
        guard privacyMayDrain else { throw CatalogRecoveryError.recoveryRequired }; task?.cancel(); picker = nil
    }
    /// Await the actual worker and progress consumer; retained restore authority never transfers.
    func finishPrivacyDrain() async throws {
        guard privacyMayDrain else { throw CatalogRecoveryError.recoveryRequired }
        if let task { await task.value }
        guard services?.protection.admitsWork == true, privacyMayDrain, task == nil else { throw CatalogRecoveryError.recoveryRequired }
        if let exportOwner { try await exportOwner.cleanup(); self.exportOwner = nil }
        try await cleanupLocal()
        preview = nil; destination = nil; destinationSelected = false; state = .idle
    }
    func retireImportRootForCatalogDeletion() async throws {
        guard privacyMayDrain, task == nil, validated == nil else { throw CatalogRecoveryError.recoveryRequired }
        if let validator { try await validator.retireOwnedEmptyStagingRoot(); self.validator = nil }
    }
    func releaseDeletedCatalogContext() throws {
        guard privacyMayDrain, task == nil, prepared == nil, validated == nil, exportOwner == nil, validator == nil else { throw CatalogRecoveryError.recoveryRequired }
        capturedCatalog = nil; capturedCache = nil; originalSource = nil; operationID = nil
        progress = nil; preview = nil; destination = nil; destinationSelected = false
    }
    private func owns(_ id: UUID, closed: Bool = false) -> Bool {
        guard operationID == id, let services, services.catalogSession.session == operationSession else { return false }
        return closed || services.sessionIsCurrent(operationSession)
    }
    private func updateProbe() {
        probe = "Active \(task == nil ? 0 : 1) · Restore \(restores) · Open \(opens) · Adopt \(adopts) · Returned \(returned == nil ? 0 : 1) · Dropped \(drops)"
    }
    private func admitted(_ kind: String, state next: State,
                          work: @escaping (CatalogRepository, URL, UUID, @escaping @Sendable (CatalogOperationProgress) -> Void) async throws -> Void) {
        guard task == nil, let services, services.protection.admitsWork, !services.privacy.blocksActions, let (repo, cache, operation) = services.beginBackupAdmission(kind) else { return }
        let id = UUID(); operationID = id; operationSession = operation.session
        state = next; message = ""; progress = nil
        let bridge = CatalogProgressBridge(beforeConsume: { [weak self] in
            #if DEBUG
            if let self, self.services?.usesSyntheticFixture == true, kind == "backup" { await self.testSupport.hold("progress") }
            #endif
        }) { [weak self] value in
            guard let self, self.owns(id) else { return }; self.progress = value
        }
        let sink = bridge.sink
        let worker = Task {
            do {
                guard services.protection.admitsWork, owns(id), !Task.isCancelled else { throw CancellationError() }
                try await work(repo, cache, id, sink)
            }
            catch {
                do {
                    if services.protection.admitsWork {
                        if let exportOwner { try await exportOwner.cleanup(); self.exportOwner = nil }
                        try await cleanupLocal()
                    }
                } catch { /* Keep exact owners for explicit cleanup retry. */ }
                #if DEBUG
                if services.protection.admitsWork, services.usesSyntheticFixture, testSupport.has("--uitest-backup-collision"), let destination {
                    await testSupport.confirmSentinel(destination)
                }
                #endif
                if owns(id) {
                    state = .failed
                    message = error is CancellationError ? "Operation cancelled. Existing catalog data is preserved." : "Operation could not finish. Existing catalog data is preserved. Retry cleanup or try again."
                }
            }
            await bridge.finish()
            services.catalogSession.finish(operation)
            if operationID == id {
                drops += bridge.counts.snapshot.1; task = nil; if owns(id, closed: true) { updateProbe() }
            }
        }
        task = worker; updateProbe(); services.catalogSession.bind(operation) { worker.cancel() }
    }
    func prepareExport() {
        guard canBegin else { return }
        admitted("backup", state: .preparing) { [self] repo, _, id, sink in
            let backup = try await repo.prepareBackup { sink(CatalogOperationProgress($0)) }
            prepared = backup; preparedOwner = repo
            #if DEBUG
            preparedReference = (ObjectIdentifier(repo), backup.directory)
            #endif
            guard owns(id), services?.protection.admitsWork == true else { throw CancellationError() }
            let bytes = try await Self.packageBytes(backup.directory, catalog: backup.manifest.catalogBytes)
            try Task.checkCancellation()
            guard owns(id) else { return }
            preview = Preview(manifest: backup.manifest, bytes: bytes); state = .exportPreview
            destination = nil; destinationSelected = false
        }
    }
    func requestDestination() { guard state == .exportPreview, !busy else { return }; picker = .destination }
    func requestRestore() { guard canBegin else { return }; picker = .restore }
    func pickerCancelled() { picker = nil; message = "Folder selection cancelled. No destination was written." }
    func picked(_ url: URL, intent: Picker) {
        picker = nil
        if intent == .destination {
            guard state == .exportPreview, !busy else { return }
            admitted("backup-destination", state: .exportPreview) { [self] _, _, id, _ in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let source = services?.selectedFolder
                let warning = await Task.detached { Self.volumeWarning(destination: url, source: source) }.value
                guard owns(id) else { return }
                destination = url; destinationSelected = true; volumeWarning = warning
            }
        } else { validate(url) }
    }
    func validate(_ url: URL) {
        guard !busy else { return }
        admitted("backup-validation", state: .validating) { [self] repo, cache, id, sink in
            capturedCatalog = repo; capturedCache = cache; originalSource = services?.selectedFolder
            let root = cache.appendingPathComponent("CatalogImport", isDirectory: true)
            if validator == nil { validator = try await Task.detached { try RestoreValidator(stagingDirectory: root) }.value }
            guard owns(id), services?.protection.admitsWork == true, !Task.isCancelled else { throw CancellationError() }
            guard let validator else { throw RestoreValidationError.unsafeEntry }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let package = try await validator.validate(package: url) { sink(CatalogOperationProgress($0)) }
            validated = package
            guard owns(id), services?.protection.admitsWork == true else { throw CancellationError() }
            let bytes = try await Self.packageBytes(package.directory, catalog: package.manifest.catalogBytes)
            let current = try await repo.peopleSnapshot()
            #if DEBUG
            if services?.usesSyntheticFixture == true { await testSupport.hold("validation") }
            #endif
            try Task.checkCancellation()
            guard owns(id) else { return }
            currentRevision = current.revision
            preview = Preview(manifest: package.manifest, bytes: bytes); state = .restorePreview
        }
    }
    func confirmExport() {
        guard state == .exportPreview, let destination, let prepared, !busy else { return }
        admitted("backup-write", state: .writing) { [self] _, _, id, sink in
            let owner = CatalogBackupExport(); exportOwner = owner
            var name = "Catalog-" + UUID().uuidString + ".afitc-backup"
            #if DEBUG
            if services?.usesSyntheticFixture == true {
                name = try await testSupport.exportName(destination: destination, proposed: name)
                await testSupport.hold("write")
            }
            #endif
            let exported = try await owner.write(prepared, to: destination, name: name, progress: sink)
            guard owns(id), services?.protection.admitsWork == true else { throw CancellationError() }
            #if DEBUG
            if let privacyFixtures { try await privacyFixtures.registerPackage(exported) }
            #endif
            try await cleanupLocal()
            guard owns(id) else { return }
            state = .finished; message = "Catalog package exported. Original photos and source permission are not included."
            exportOwner = nil; destinationSelected = false
        }
    }
    func confirmRestore() {
        guard state == .restorePreview, validated != nil, !busy, services?.privacy.blocksActions != true else { return }
        originalSource = services?.selectedFolder
        continueRestore()
    }
    private func continueRestore() {
        guard !busy, let services, services.protection.admitsWork, !services.privacy.blocksActions, let catalog = capturedCatalog, let cache = capturedCache else { return }
        let id = UUID(); operationID = id; operationSession = services.catalogSession.session
        state = .draining; message = "Waiting for current catalog work to finish."
        let worker = Task {
            let drained = await services.quiesceCatalogSession(seconds: drainSeconds)
            operationSession = services.catalogSession.session
            guard operationID == id else { return }
            guard services.protection.admitsWork else { task = nil; return }
            guard drained else {
                state = .recoveryRequired; message = "Catalog work has not finished. Release the held work or wait, then explicitly Retry."
                task = nil; updateProbe(); return
            }
            let bridge = CatalogProgressBridge { [weak self] value in
                guard let self, self.owns(id, closed: true) else { return }; self.progress = value
            }
            let sink = bridge.sink
            state = .restoring; message = "Catalog recovery is in progress."
            do {
                if restoreOwner == nil {
                    guard let validated else { throw CatalogRecoveryError.recoveryRequired }
                    #if DEBUG
                    if services.usesSyntheticFixture, testSupport.has("--uitest-backup-prepared-fault") {
                        restoreOwner = try await CatalogRestoreRepository.beginRestore(catalog: catalog, testFault: .afterPreparedMarker)
                    } else { restoreOwner = try await CatalogRestoreRepository.beginRestore(catalog: catalog) }
                    #else
                    restoreOwner = try await CatalogRestoreRepository.beginRestore(catalog: catalog)
                    #endif
                    restores += 1
                    guard let restoreOwner else { throw CatalogRecoveryError.recoveryRequired }
                    #if DEBUG
                    if services.usesSyntheticFixture, testSupport.has("--uitest-backup-cancel-before-prepared") {
                        await testSupport.hold("before-prepared")
                        task?.cancel()
                    }
                    #endif
                    returned = try await restoreOwner.restore(validated) { sink(CatalogOperationProgress($0)) }
                } else if returned == nil, let restoreOwner {
                    opens += 1
                    do { returned = try await restoreOwner.open { sink(CatalogOperationProgress($0)) } }
                    catch CatalogRecoveryError.completed {
                        guard let original = await restoreOwner.preservedCatalogAfterCleanup() else { throw CatalogRecoveryError.recoveryRequired }
                        returned = original; preservedOriginal = true
                    }
                }
                // Strongly retain the fresh actor before ANY later awaited read.
                updateProbe()
                guard let returned else { throw CatalogRecoveryError.recoveryRequired }
                let photos = try await returned.photos()
                #if DEBUG
                if services.usesSyntheticFixture { try testSupport.failSnapshotOnce() }
                #endif
                let people = try await returned.peopleSnapshot(), checkpoint = try await returned.checkpoint()
                guard services.protection.admitsWork, owns(id, closed: true) else { throw CancellationError() }
                var progress = checkpoint ?? ScanProgress()
                if [.processing, .discovering, .cancelling].contains(progress.phase) { progress.phase = .interrupted }
                try await cleanupLocal()
                try await services.presentation.prepareAdoption(preserveOriginal: preservedOriginal)
                guard services.protection.admitsWork, services.publishFreshCatalogSession(repository: returned, cache: cache, photos: photos, people: people,
                    progress: progress, preservedSource: preservedOriginal ? originalSource : nil) else { throw CatalogRecoveryError.recoveryRequired }
                adopts += 1
                if !preservedOriginal { services.setupError = "Reconnect the original source folder to access originals or resume indexing." }
                state = .finished
                message = preservedOriginal ? "Original catalog preserved. Source selection is unchanged." : "Catalog restored. Reconnect the original photo folder."
                restoreOwner = nil; self.returned = nil; capturedCatalog = nil; validatedCleanupComplete()
            } catch {
                if owns(id, closed: true) {
                    state = .recoveryRequired; message = "Recovery needs another attempt. Catalog work stays paused until you explicitly Retry."
                }
            }
            await bridge.finish()
            if operationID == id { drops += bridge.counts.snapshot.1; task = nil; updateProbe() }
        }
        task = worker; updateProbe()
    }
    private var drainSeconds: Double {
        #if DEBUG
        if services?.usesSyntheticFixture == true, testSupport.has("--uitest-session-short-timeout") { return 0.25 }
        #endif
        return 15
    }
    func retry() {
        guard !busy else { return }
        if state == .recoveryRequired { continueRestore(); return }
        if state == .failed { cancelPreview() }
    }
    func cancel() { if canCancel { task?.cancel() } }
    func cancelPreview() {
        guard !busy, state != .recoveryRequired else { return }
        admitted("backup-cleanup", state: .preparing) { [self] _, _, id, _ in
            if let exportOwner { try await exportOwner.cleanup(); self.exportOwner = nil }
            try await cleanupLocal()
            guard owns(id) else { return }
            preview = nil; destination = nil; destinationSelected = false; state = .idle; message = "Cancelled. Existing catalog is unchanged."
        }
    }
    private func cleanupLocal(permit: ProtectedReopenPermit? = nil) async throws {
        guard let protection = services?.protection else { throw CancellationError() }
        let epoch = try protection.cleanupGeneration(permit)
        if let prepared, let preparedOwner {
            let original = protection.retainedCleanupSuspension
            if let original { try await original.discardPreparedBackup(prepared) }
            else { try await preparedOwner.discardBackup(prepared) }
            // Consume committed cleanup before a later WILL can suppress publication; never resurrect it.
            if self.prepared?.directory == prepared.directory, self.preparedOwner === preparedOwner {
                self.prepared = nil; self.preparedOwner = nil
                if let original { protection.completedPreparedCleanup(original) }
            }
        }
        try protection.requireCleanup(epoch, permit: permit)
        if let validated, let validator {
            try await validator.discard(validated)
            if self.validated?.directory == validated.directory, self.validator === validator { self.validated = nil }
        }
        try protection.requireCleanup(epoch, permit: permit)
    }
    private func validatedCleanupComplete() { preview = nil; destination = nil; destinationSelected = false; preservedOriginal = false }
    nonisolated private static func packageBytes(_ directory: URL, catalog: Int) async throws -> Int {
        try await Task.detached {
            let bytes = try directory.appendingPathComponent("manifest.json").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
            guard bytes > 0, bytes <= BackupManifest.maximumManifestBytes, catalog >= 0,
                  catalog <= BackupManifest.maximumCatalogBytes, bytes + catalog <= BackupManifest.maximumTotalBytes else { throw BackupError.limitExceeded }
            return bytes + catalog
        }.value
    }
    nonisolated private static func volumeWarning(destination: URL, source: URL?) -> String {
        let common = "A backup on your photo drive will not survive that drive failing. Choose independent storage when possible."
        guard let source else { return "Separate storage could not be verified. " + common }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard let a = try? source.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let b = try? destination.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else { return "Separate storage could not be verified. " + common }
        return ((a as? NSObject)?.isEqual(b) == true ? "Selected folder is on the photo source volume. " : "Selected folder reports a different volume; physical redundancy is not verified. ") + common
    }
    #if DEBUG
    func releaseTestWork() { testSupport.release() }
    func selectTestFolder(_ intent: Picker) {
        guard services?.usesSyntheticFixture == true else { return }
        admitted("backup-test-picker", state: intent == .restore ? .validating : .exportPreview) { [self] repo, cache, id, _ in
            let fixtureCache: URL
            if testSupport.has("--uitest-privacy-controls") {
                if privacyFixtures == nil { privacyFixtures = try await Task.detached { try SyntheticPrivacyBackupFixtures(parent: cache.deletingLastPathComponent()) }.value }
                guard let privacyFixtures else { throw BackupError.unsafeStage }; fixtureCache = await privacyFixtures.root
            } else { fixtureCache = cache }
            let url: URL
            if intent == .destination { url = try await testSupport.destination(fixtureCache) }
            else {
                let backup = try await repo.prepareBackup()
                do { url = try await testSupport.package(backup, cache: fixtureCache); try await repo.discardBackup(backup) }
                catch { try? await repo.discardBackup(backup); throw error }
            }
            if let privacyFixtures {
                try await privacyFixtures.registerFolder(url)
                if intent == .restore { try await privacyFixtures.registerPackage(url) }
            }
            guard owns(id) else { return }
            // Start the normal production selected-folder path only after this real worker finishes.
            testSupport.selected = (url, intent)
        }
    }
    func consumeTestSelection() {
        guard !busy, let selected = testSupport.selected else { return }
        testSupport.selected = nil; picked(selected.0, intent: selected.1)
    }
    func verifyPrivacyCopies() async throws -> Int { try await privacyFixtures?.verify() ?? 0 }
    func cleanupPrivacyCopies() async throws {
        guard services?.privacy.catalogDeleted == true else { throw BackupError.unsafeStage }
        try await privacyFixtures?.cleanup(); privacyFixtures = nil
    }
    var testStatus: String { testSupport.status }
    #endif
}

#if DEBUG
/// Exclusively created synthetic sibling, never a canonical cache or a user picker path.
private actor SyntheticPrivacyBackupFixtures {
    let root: URL
    private struct Node { let directory: Bool; let device: dev_t; let inode: ino_t; let digest: String? }
    private let identity: stat
    private var nodes: [String: Node] = [:]
    private var packages = Set<String>()
    init(parent: URL) throws {
        root = parent.appendingPathComponent("AFITCPrivacyBackupFixture-" + UUID().uuidString, isDirectory: true)
        guard mkdir(root.path, 0o700) == 0 else { throw BackupError.unsafeStage }
        var value = stat(); guard lstat(root.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { throw BackupError.unsafeStage }
        identity = value; try CatalogRepository.protect(root, directory: true)
    }
    private func checkRoot() throws {
        var value = stat(); guard lstat(root.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR,
            value.st_dev == identity.st_dev, value.st_ino == identity.st_ino else { throw BackupError.unsafeStage }
    }
    private func node(_ relative: String, directory: Bool) throws -> Node {
        let url = root.appendingPathComponent(relative); var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
            directory || (value.st_nlink == 1 && value.st_size >= 0 && value.st_size <= BackupManifest.maximumCatalogBytes) else { throw BackupError.unsafeStage }
        let digest = directory ? nil : SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        return Node(directory: directory, device: value.st_dev, inode: value.st_ino, digest: digest)
    }
    func registerFolder(_ url: URL) throws {
        try checkRoot(); guard url.deletingLastPathComponent() == root else { throw BackupError.unsafeStage }
        let name = url.lastPathComponent
        guard ["SyntheticImport-", "SyntheticExport-"].contains(where: { name.hasPrefix($0) && UUID(uuidString: String(name.dropFirst($0.count))) != nil }) else { throw BackupError.unsafeStage }
        nodes[name] = try node(name, directory: true)
    }
    func registerPackage(_ url: URL) throws {
        try checkRoot()
        let relative: String
        if url.deletingLastPathComponent() == root { relative = url.lastPathComponent; guard nodes[relative] != nil else { throw BackupError.unsafeStage } }
        else {
            let folder = url.deletingLastPathComponent().lastPathComponent, name = url.lastPathComponent
            guard url.deletingLastPathComponent().deletingLastPathComponent() == root, nodes[folder] != nil,
                  name.hasPrefix("Catalog-"), name.hasSuffix(".afitc-backup"), UUID(uuidString: String(name.dropFirst(8).dropLast(13))) != nil else { throw BackupError.unsafeStage }
            relative = folder + "/" + name; nodes[relative] = try node(relative, directory: true)
        }
        guard Set(try FileManager.default.contentsOfDirectory(atPath: url.path)) == Set(["manifest.json", "catalog.sqlite"]) else { throw BackupError.unsafeStage }
        for file in ["manifest.json", "catalog.sqlite"] { nodes[relative + "/" + file] = try node(relative + "/" + file, directory: false) }
        packages.insert(relative)
    }
    func verify() throws -> Int {
        try checkRoot()
        for (relative, expected) in nodes {
            let actual = try node(relative, directory: expected.directory)
            guard actual.device == expected.device, actual.inode == expected.inode, actual.digest == expected.digest else { throw BackupError.unsafeStage }
        }
        for relative in [""] + nodes.filter({ $0.value.directory }).map(\.key) {
            let names = Set(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(relative).path))
            let expected = Set(nodes.keys.compactMap { child -> String? in
                let parent = (child as NSString).deletingLastPathComponent
                return parent == relative ? (child as NSString).lastPathComponent : nil
            })
            guard names == expected else { throw BackupError.unsafeStage }
        }
        return packages.count
    }
    func cleanup() throws {
        _ = try verify()
        for relative in nodes.keys.sorted(by: { $0.count > $1.count }) {
            try checkRoot(); let expected = nodes[relative]!, actual = try node(relative, directory: expected.directory)
            guard actual.device == expected.device, actual.inode == expected.inode else { throw BackupError.unsafeStage }
            let path = root.appendingPathComponent(relative).path
            guard (expected.directory ? rmdir(path) : unlink(path)) == 0 else { throw BackupError.unsafeStage }
        }
        try checkRoot(); guard rmdir(root.path) == 0 else { throw BackupError.unsafeStage }; nodes = [:]; packages = []
    }
}
#endif
