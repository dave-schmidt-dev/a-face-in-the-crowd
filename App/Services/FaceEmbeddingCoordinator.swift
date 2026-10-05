import Foundation
import UIKit
import AFITCCore
import AFITCRuntime

/// Thin MainActor facade over the runtime face-detail lifecycle. It owns no pipeline logic:
/// the runtime store builds the per-scan producer, and the latest batch stays in RAM only.
/// When evaluation suggestions are on, the same producer is wrapped in a `FaceJobCoordinator`
/// that feeds the RAM-only suggestion index; when off, nothing extra is constructed.
@MainActor
final class FaceEmbeddingCoordinator {
    private let store = TransientFaceEmbeddingStore()
    private var observer: NSObjectProtocol?
    /// Set by `SuggestionService` when it is created; nil means suggestions were never opened.
    weak var suggestions: SuggestionService?
    /// Runtime producers owned by in-flight suggestion jobs, released in `finishScan`.
    private var runtimeProducers: [ObjectIdentifier: RuntimeFaceVectorProducer] = [:]

    init() {
        // Memory pressure closes the suggestion gate first, then drops the retained batch and
        // the suggestion index synchronously so no publication can slip in between.
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self, store] _ in
            MainActor.assumeIsolated {
                self?.suggestions?.resources.latchMemoryWarning()
                store.invalidate()
                self?.suggestions?.dropIndex()
            }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// Called by `startScan` after its operation is registered. Synthetic fixtures get nil, or in DEBUG
    /// with `--uitest-synthetic-suggestions` a job around the fixed synthetic vector producer.
    /// With suggestions off the store's producer is returned unchanged.
    func beginScan(repository: CatalogRepository, operation: CatalogSessionLifecycle.Operation,
                   syntheticFixture: Bool) -> (any ScanEnrichment)? {
        let producer = store.makeEnrichment(repository: repository, operationID: operation.id,
                                            sessionEpoch: operation.session, syntheticFixture: syntheticFixture)
        #if DEBUG
        if syntheticFixture { return syntheticSuggestionJob(repository: repository) }
        #endif
        guard let producer, let jobs = suggestions?.prepareJob() else { return producer }
        let runtime = RuntimeFaceVectorProducer(producer: producer, store: store)
        let job = FaceJobCoordinator(repository: repository, producer: runtime, index: jobs.index,
                                     gate: jobs.gate, stats: jobs.stats)
        runtimeProducers[ObjectIdentifier(job)] = runtime
        return job
    }

    /// Releases model handles once the scan has returned, after actual runtime drain.
    func finishScan(_ enrichment: (any ScanEnrichment)?) async {
        if let job = enrichment as? FaceJobCoordinator {
            let runtime = runtimeProducers.removeValue(forKey: ObjectIdentifier(job))
            suggestions?.finishJob()
            await runtime?.release()
            return
        }
        await (enrichment as? TransientFaceEmbeddingProducer)?.release()
    }

    /// Synchronous: invalidates the operation token and drops the retained batch and the index.
    func invalidate() {
        store.invalidate()
        suggestions?.dropIndex()
    }
}
