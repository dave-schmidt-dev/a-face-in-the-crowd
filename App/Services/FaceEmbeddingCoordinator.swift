import Foundation
import UIKit
import AFITCCore
import AFITCRuntime

/// Thin MainActor facade over the runtime face-detail lifecycle. It owns no pipeline logic:
/// the runtime store builds the per-scan producer, and the latest batch stays in RAM only.
@MainActor
final class FaceEmbeddingCoordinator {
    private let store = TransientFaceEmbeddingStore()
    private var observer: NSObjectProtocol?

    init() {
        // Memory pressure drops the retained batch and stops in-flight publication.
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [store] _ in store.invalidate() }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// Called by `startScan` after its operation is registered; synthetic fixtures get nil.
    func beginScan(repository: CatalogRepository, operation: CatalogSessionLifecycle.Operation,
                   syntheticFixture: Bool) -> (any ScanEnrichment)? {
        store.makeEnrichment(repository: repository, operationID: operation.id,
                             sessionEpoch: operation.session, syntheticFixture: syntheticFixture)
    }

    /// Releases model handles once the scan has returned, after actual runtime drain.
    func finishScan(_ enrichment: (any ScanEnrichment)?) async {
        await (enrichment as? TransientFaceEmbeddingProducer)?.release()
    }

    /// Synchronous: invalidates the operation token and drops the retained batch.
    func invalidate() { store.invalidate() }
}
