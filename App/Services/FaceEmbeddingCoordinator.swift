import Foundation
import UIKit
import AFITCCore
import AFITCRuntime

/// Thin MainActor facade over the runtime face-detail lifecycle. It owns no pipeline logic:
/// the runtime store builds the per-scan producer, and every scan's verified analysis is
/// persisted through the durable producer, so later scans of unchanged bytes reuse it without
/// reads or inference. When evaluation suggestions are on, the same durable producer is wrapped
/// in a `FaceJobCoordinator` that feeds the RAM-only suggestion index; when off, nothing extra
/// is constructed.
@MainActor
final class FaceEmbeddingCoordinator {
    private let store = TransientFaceEmbeddingStore()
    private var observer: NSObjectProtocol?
    /// Set by `SuggestionService` when it is created; nil means suggestions were never opened.
    weak var suggestions: SuggestionService?
    /// Runtime producers owned by in-flight suggestion jobs, released in `finishScan`.
    private var runtimeProducers: [ObjectIdentifier: RuntimeFaceVectorProducer] = [:]
    /// Catalog of the most recent scan; durable vector reloads read it. Cleared by `invalidate`.
    private var repository: CatalogRepository?
    private let analysisResources = FaceJobResources()

    init() {
        analysisResources.isEnabled = true
        // Memory pressure closes the suggestion gate first, then drops the retained batch and
        // the suggestion index synchronously so no publication can slip in between.
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self, store] _ in
            MainActor.assumeIsolated {
                self?.suggestions?.resources.latchMemoryWarning()
                self?.analysisResources.latchMemoryWarning()
                store.invalidate()
                self?.suggestions?.dropIndex()
            }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// Called by `startScan` after its operation is registered. Synthetic fixtures get nil, or in DEBUG
    /// with `--uitest-synthetic-suggestions` a job around the fixed synthetic vector producer.
    /// Durable persistence is always on; with suggestions off the durable producer is returned alone.
    func beginScan(repository: CatalogRepository, operation: CatalogSessionLifecycle.Operation,
                   syntheticFixture: Bool) -> (any ScanEnrichment)? {
        self.repository = repository
        analysisResources.clearMemoryWarning()
        let producer = store.makeEnrichment(repository: repository, operationID: operation.id,
                                            sessionEpoch: operation.session, syntheticFixture: syntheticFixture)
        #if DEBUG
        if syntheticFixture { return syntheticSuggestionJob(repository: repository) }
        #endif
        guard let producer else { return nil }
        let persistent = PersistentFaceAnalysisProducer(producer: producer, repository: repository, store: store, gate: analysisResources)
        guard let jobs = suggestions?.prepareJob() else { return persistent }
        let runtime = RuntimeFaceVectorProducer(enrichment: persistent, store: store)
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
        if let persistent = enrichment as? PersistentFaceAnalysisProducer {
            await persistent.release()
            return
        }
        await (enrichment as? TransientFaceEmbeddingProducer)?.release()
    }

    /// Reloads durable current vectors into the suggestion index after relaunch or a dropped
    /// index. Nothing is recomputed and no source is read: only already persisted vectors of
    /// the current source binding, current faces and current content load, photo by photo.
    func reloadDurableVectors(into index: any FaceVectorIndex, catalog: CatalogRepository? = nil) async {
        guard let repository = catalog ?? repository else { return }
        let manifest = ModelManifest.openCVSFace2021December
        guard let rows = try? await repository.currentDurableFaceVectors(manifest: manifest),
              !rows.isEmpty else { return }
        let epoch = index.epoch
        var byPhoto: [UUID: [(face: FaceKey, vector: EmbeddingVector, contentHash: String)]] = [:]
        for row in rows { byPhoto[row.face.photoID, default: []].append(row) }
        for (photoID, entries) in byPhoto {
            guard let hash = entries.first?.contentHash else { continue }
            _ = try? index.insert(entries.map { (face: $0.face, vector: $0.vector) },
                                  photoID: photoID, contentHash: hash, manifest: manifest, epoch: epoch)
        }
    }

    /// Synchronous: invalidates the operation token and drops the retained batch and the index.
    func invalidate() {
        store.invalidate()
        repository = nil
        suggestions?.dropIndex()
    }
}
