import Foundation
#if canImport(UIKit)
import UIKit
#endif
import AFITCCore
import AFITCRuntime

/// Thin MainActor facade over the runtime face-detail lifecycle. It owns no pipeline logic:
/// every scan's verified analysis persists through the durable producer, so later scans of
/// unchanged bytes reuse it without reads or inference. The synthetic fixture persists its
/// fixed fictional vectors through the same fenced transaction, without a toggle.
@MainActor
final class FaceEmbeddingCoordinator {
    private let store = TransientFaceEmbeddingStore()
    private var observer: NSObjectProtocol?
    /// Analysis admission gate: memory warnings and thermal state pause catch-up reads.
    private let analysisResources: FaceJobResources

    init(analysisResources: FaceJobResources = FaceJobResources()) {
        self.analysisResources = analysisResources
        analysisResources.isEnabled = true
        // Memory pressure closes the analysis gate first, then drops the retained batch
        // synchronously so no publication can slip in between.
        #if canImport(UIKit)
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self, store] _ in
            MainActor.assumeIsolated {
                self?.analysisResources.latchMemoryWarning()
                store.invalidate()
            }
        }
        #endif
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// Called by `startScan` after its operation is registered. Durable persistence is always
    /// on; the synthetic fixture gets the fixed fictional vector producer behind the same
    /// reuse, admission and fence checks as production.
    func beginScan(repository: CatalogRepository, operation: CatalogSessionLifecycle.Operation,
                   syntheticFixture: Bool) -> (any ScanEnrichment)? {
        analysisResources.clearMemoryWarning()
        #if DEBUG
        if syntheticFixture { return SyntheticPersistentAnalysisProducer(repository: repository, gate: analysisResources) }
        #endif
        guard let producer = store.makeEnrichment(repository: repository, operationID: operation.id,
                                                 sessionEpoch: operation.session, syntheticFixture: syntheticFixture) else { return nil }
        return PersistentFaceAnalysisProducer(producer: producer, repository: repository, store: store, gate: analysisResources)
    }

    /// Releases model handles once the scan has returned, after actual runtime drain.
    func finishScan(_ enrichment: (any ScanEnrichment)?) async {
        if let persistent = enrichment as? PersistentFaceAnalysisProducer {
            await persistent.release()
            return
        }
        await (enrichment as? TransientFaceEmbeddingProducer)?.release()
    }

    /// The same thermal/memory gate also bounds saved-vector grouping admission.
    var groupingPauseReason: FaceJobPauseReason? { analysisResources.pauseReason() }

    /// Synchronous: invalidates the operation token and drops the retained batch.
    func invalidate() {
        store.invalidate()
    }
}
