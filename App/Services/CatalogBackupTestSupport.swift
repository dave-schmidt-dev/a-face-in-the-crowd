#if DEBUG
import Foundation
import AFITCCore

/// Fixed, generated local fixtures only. Production operation paths still perform all work.
@MainActor
final class CatalogBackupTestSupport {
    enum Failure: Error { case snapshot }
    let launch: LaunchOptions
    var selected: (URL, CatalogBackupService.Picker)?
    private var waiter: CheckedContinuation<Void, Never>?
    private var snapshotFailed = false
    var changed: (() -> Void)?
    private(set) var status = "Held 0 · Collision 0 · Sentinel 0" { didSet { changed?() } }
    init(launch: LaunchOptions) { self.launch = launch }
    func has(_ argument: String) -> Bool { launch.has(argument) }
    func hold(_ kind: String) async {
        guard has("--uitest-backup-hold-" + kind) else { return }
        status = "Held 1 · " + kind
        await withCheckedContinuation { waiter = $0 }
        status = "Held 0 · " + kind
    }
    func release() { let value = waiter; waiter = nil; value?.resume() }
    func failSnapshotOnce() throws {
        if !snapshotFailed, has("--uitest-backup-snapshot-fault") { snapshotFailed = true; throw Failure.snapshot }
    }
    func destination(_ cache: URL) async throws -> URL {
        try await Task.detached {
            let url = cache.appendingPathComponent("SyntheticExport-" + UUID().uuidString, isDirectory: true)
            try CatalogRepository.protect(url, directory: true); return url
        }.value
    }
    func package(_ backup: PreparedCatalogBackup, cache: URL) async throws -> URL {
        let invalid = has("--uitest-backup-invalid")
        return try await Task.detached {
            let url = cache.appendingPathComponent("SyntheticImport-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.copyItem(at: backup.directory, to: url)
            try CatalogRepository.protect(url, directory: true)
            if invalid { try Data("invalid synthetic catalog".utf8).write(to: url.appendingPathComponent("catalog.sqlite")) }
            return url
        }.value
    }
    func exportName(destination: URL, proposed: String) async throws -> String {
        guard has("--uitest-backup-collision") else { return proposed }
        let name = "Existing-fictional.afitc-backup"
        try await Task.detached {
            let path = destination.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            try Data("preserve-existing-fictional".utf8).write(to: path.appendingPathComponent("sentinel"))
        }.value
        status = "Held 0 · Collision 1 · Sentinel 1"
        return name
    }
    func confirmSentinel(_ destination: URL) async {
        let preserved = await checkSentinel(destination)
        status = "Held 0 · Collision 1 · Sentinel \(preserved ? 1 : 0)"
    }
    func checkSentinel(_ destination: URL) async -> Bool {
        await Task.detached {
            let file = destination.appendingPathComponent("Existing-fictional.afitc-backup/sentinel")
            return (try? Data(contentsOf: file)) == Data("preserve-existing-fictional".utf8)
        }.value
    }
}
#endif
