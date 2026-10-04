import Foundation
import AFITCCore

/// Retains the reserved startup owner and any returned actor before subsequent reads.
@MainActor
final class CatalogStartupService {
    struct Snapshot {
        let repository: CatalogRepository
        let cache: URL
        let photos: [PhotoIdentity]
        let checkpoint: ScanProgress?
    }
    private let recovery: CatalogRestoreRepository
    private let cache: URL
    private var returned: CatalogRepository?
    private var worker: Task<Void, Never>?
    init(directory: URL, cache: URL) throws {
        recovery = try CatalogRestoreRepository(directory: directory, cacheDirectory: cache)
        self.cache = cache
    }
    var protectedAuthority: ProtectedCatalogAuthority {
        returned.map(ProtectedCatalogAuthority.live) ?? .restore(recovery)
    }
    func finishProtectedWork() async { if let worker { await worker.value } }
    func start(_ services: AppServices) {
        guard services.protection.admitsWork, worker == nil, let operation = services.catalogSession.begin("startup") else { return }
        services.isOpeningCatalog = true
        let task = Task {
            defer {
                if services.sessionIsCurrent(operation.session) { services.isOpeningCatalog = false }
                services.catalogSession.finish(operation); worker = nil
            }
            do {
                guard services.sessionIsCurrent(operation.session), services.protection.admitsWork, !Task.isCancelled else { return }
                if returned == nil { returned = try await recovery.open() }
                guard let repo = returned else { throw CatalogRecoveryError.recoveryRequired }
                let photos = try await repo.photos(), checkpoint = try await repo.checkpoint()
                #if DEBUG
                await services.holdSessionWork(operation)
                #endif
                guard services.sessionIsCurrent(operation.session) else { return }
                services.installStartupCatalog(Snapshot(repository: repo, cache: cache, photos: photos, checkpoint: checkpoint), session: operation.session)
                // People failures remain independent of cached Library/checkpoint/source recovery.
                await services.refreshPeople()
                guard services.sessionIsCurrent(operation.session) else { return }
                guard services.protection.admitsWork else { return }
                let generation = services.viewerSourceGeneration
                services.isRestoringSource = true
                defer { if services.sessionIsCurrent(operation.session) { services.isRestoringSource = false } }
                do {
                    let resolved = try await Self.resolveGrant(repo)
                    guard services.sessionIsCurrent(operation.session) else { return }
                    services.applyStartupSource(resolved, session: operation.session, generation: generation)
                } catch {
                    if services.sessionIsCurrent(operation.session), services.viewerSourceGeneration == generation {
                        services.setupError = "Saved source permission could not be restored. Choose the original folder again. Cached photos remain available."
                    }
                }
                guard services.sessionIsCurrent(operation.session) else { return }
                await services.diagnostics.record(.shellOpened, severity: .debug)
            } catch {
                if services.sessionIsCurrent(operation.session) {
                    services.setupError = "Catalog unavailable. Existing data has been preserved. Retry opening the catalog."
                }
            }
        }
        worker = task
        services.catalogSession.bind(operation) { task.cancel() }
    }
    private static func resolveGrant(_ repo: CatalogRepository) async throws -> CatalogRepository.ResolvedGrant? {
        guard let grant = try await repo.loadGrant() else { return nil }
        let work = Task.detached(priority: .utility) { try CatalogRepository.resolveGrant(grant) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}
