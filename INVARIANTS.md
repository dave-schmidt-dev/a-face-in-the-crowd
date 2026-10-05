# AFITC invariants

Native MVP charter and evidence boundary. iPadOS17 minimum; one chosen drive root; local processing; human-confirmed Together/Any/Only search. Current user scope overrides archived packet examples.

Gate mappings identify verification entry points, not passing evidence. INV-4 manual identity, correction and merge/undo behavior are implemented. Current phase status is recorded in `.logs/delivery.json`, with run receipts under `.logs/verification/` and canonical past work in `HISTORY.md`. INV-6 core search snapshots and Search UI are implemented; accumulated native Search UI gates remain pending, and INV-9 model qualification remains planned. Task 3.2 evaluation suggestions are implemented (owner-enabled, off by default, session-only RAM vector index) and unqualified; 3.2 phase acceptance stays pending on Task 2.2. No selector or compile result establishes physical-device or recognition-model qualification.

Area mappings include current and planned paths; mappings do not claim implementation.

### INV-1 — Visible, resumable work
area: ["Sources/AFITCCore/ScanCoordinator.swift", "App/AppServices.swift", "App/StatusView.swift", "App/LibraryView.swift", "App/VerifyView.swift", "tools/verify.sh"]
gate_test: Tests/AFITCCoreTests/SourceRecoveryTests.swift
threshold: 3
rationale: Discovery, reads, hashes, previews, detection, inference and restore show actual operation/counts, indeterminate totals where unknown, cancellation and durable checkpoints; failures preserve accepted work. Suggestion jobs report counts, per-photo durations and fixed pause reasons (off, device warm, memory low); a skipped job never fails the scan.

### INV-2 — Source integrity
area: ["Sources/AFITCCore/SourceProtocol.swift", "Sources/AFITCCore/ScanCoordinator.swift", "App/Services/FolderSource.swift"]
gate_test: Tests/AFITCCoreTests/SourceRecoveryTests.swift
threshold: 3
rationale: Read only within the selected folder grant. Never modify originals or infer empty/deleted source from access failure. Ambiguous content changes cannot inherit decisions.

### INV-3 — Local sensitive data
area: ["Sources/AFITCCore/CatalogRepository.swift", "App/Services/DiagnosticLog.swift", "App/Services/PrivacyProtection.swift", "App/Services/CatalogBackupService.swift"]
gate_test: Tests/AFITCCoreTests/RunnerContractTests.swift
threshold: 3
rationale: Catalog/derived data stays in the protected app container, excluded from automatic app backups. No photo/name/path/crop/vector telemetry, provider upload, public fixture or sensitive log. Export is explicit and warns of unencrypted private contents.

### INV-4 — Human identity authority
area: ["Sources/AFITCCore/PeopleRepository.swift", "Sources/AFITCCore/DecisionService.swift", "Sources/AFITCCore/UndoService.swift", "Sources/AFITCCore/ReviewQueue.swift", "App/PeopleView.swift", "App/PersonDetailView.swift"]
gate_test: Tests/AFITCCoreTests/DecisionDurabilityTests.swift
threshold: 3
rationale: Naming confirms only the selected face. Suggestions cannot confirm themselves; rejection/unsure history persists. A suggestion's Yes is a guarded confirm: the face state and the person's exemplar revision the card was rendered with must still match inside the write transaction, otherwise it is a conflict. The card's Not this person, Unsure and Not a person answers are guarded by the rendered face state the same way, so a stale card never overrides a newer decision. Correction/merge conflicts require explicit resolution; undo restores before-state atomically.

### INV-5 — Stable catalog versions
area: ["Sources/AFITCCore/PhotoIdentity.swift", "Sources/AFITCCore/FaceAnalysisState.swift", "Sources/AFITCCore/ScanCoordinator.swift", "Sources/AFITCCore/CatalogRepository.swift", "Sources/AFITCCore/CatalogSchema.swift", "Sources/AFITCCore/FaceJobCoordinator.swift", "Sources/AFITCCore/SuggestionEngine.swift"]
gate_test: Tests/AFITCCoreTests/CatalogPersistenceTests.swift
threshold: 3
rationale: Photo UUIDs and content/detector/model generations bind every face/job/decision. Stale work cannot overwrite newer decisions. Identical bytes at distinct paths are distinct photo records with separate confirmations/counts.

### INV-6 — Truthful search
area: ["Sources/AFITCCore/PeopleQuery.swift", "Sources/AFITCCore/SearchRepository.swift", "App/SearchView.swift"]
gate_test: Tests/AFITCCoreTests/PeopleQueryTests.swift
threshold: 3
rationale: Together/Any use confirmed sets by default. Only requires the exact selected set and successful resolved detected-face index. Unknown real faces are not false detections. Counts/pagination share one revision; possible results remain separate.

### INV-7 — Recoverable catalog
area: ["Sources/AFITCCore/CatalogRepository.swift", "Sources/AFITCCore/CatalogSchema.swift", "Sources/AFITCCore/BackupManifest.swift", "Sources/AFITCCore/RestoreValidator.swift", "App/Services/CatalogBackupService.swift"]
gate_test: Tests/AFITCCoreTests/CatalogPersistenceTests.swift
threshold: 3
rationale: SQLite migrations, export and restore use validated consistent snapshots, version checks and rollback. Failed/partial restore cannot overwrite live work. Grants are renewed, never portable backup permissions.

### INV-8 — Bounded resources
area: ["Sources/AFITCCore/ScanCoordinator.swift", "Sources/AFITCCore/CachePolicy.swift", "Sources/AFITCCore/CatalogRepository.swift", "App/Services/PreviewService.swift", "App/Services/FaceEmbeddingCoordinator.swift", "Sources/AFITCRuntime/TransientFaceEmbeddingProducer.swift", "Sources/AFITCCore/FaceVectorIndex.swift", "Sources/AFITCRuntime/RuntimeFaceVectorProducer.swift", "App/Services/PrivacyProtection.swift"]
gate_test: Tests/AFITCCoreTests/SourceRecoveryTests.swift
threshold: 3
rationale: Decode/inference concurrency and the shared derived cache are bounded. Replacement reserves old plus staged bytes, including residual canonical stages; eviction removes only canonical owned previews. Staging publication and cleanup require matching single-link inode identity. Lock, source loss, low storage and memory pressure pause safely; missing previews remain explicit while accepted analysis is preserved.

### INV-9 — Evidence-bound qualification
area: ["Sources/AFITCCore/ModelManifest.swift", "Sources/AFITCCore/EmbeddingProvider.swift", "Sources/AFITCCore/FaceAlignmentAssociation.swift", "Sources/AFITCRuntime/TransientFaceEmbeddingProducer.swift", "tools/model-qualification.md"]
gate_test: Tests/AFITCCoreTests/ModelContractTests.swift
threshold: 3
rationale: The pinned SFace manifest records declared license, source, checksum and tensor contract; dependency-free tensor/vector checks and an opt-in CPU diagnostic do not implement a production image-alignment or recognition path. Preprocessing parity, rights review, private-corpus utility, physical iPad6/M4 behavior and owner usability are separate gates before rollout. Owner-enabled evaluation suggestions on Verify (off by default, uncalibrated evaluation thresholds) are not rollout and do not change these gates. No model substitution, install, upload or publication without its required authority.

## Manual identity implementation boundary

Task 3.1 implements generation-bound manual naming and correction, stable distinct person IDs even when display names match, explicit unsure/rejected/not-a-person states, and targeted undo. Task 3.3 requires exact per-face choices for confirmed/rejected merge conflicts; cancel writes nothing, and third-person assignments and duplicate-copy confirmations do not propagate. Merge and reopened undo restore links, negatives, deferrals, anchors, covers, names, source archive and counts atomically while advancing exemplar epochs. Legacy schema 3 undo payloads remain readable, and successive undo is covered. Same-generation unavailable affected faces must reconnect before merge; changed-generation history remains inactive.

DEBUG workflow fixtures require explicit synthetic inputs and do not provide recognition. People releases cached face-preview rasters and invalidates in-flight preview work on disappearance or memory warning. Native UI, physical-device and model qualification remain separate acceptance gates. Current phase status is recorded in `.logs/delivery.json`; run evidence is retained under `.logs/verification/` and canonical past work in `HISTORY.md`.

## Source catalog implementation boundary

Task 1.2 implements pull-based recursive JPEG discovery, protected transactional per-photo/checkpoint state, bounded oriented previews and versioned local Vision landmarks. First previews are published before requesting the next discovery entry. Pending, skipped and failed detections remain unresolved; successful zero-face detection never confirms an identity. A failed detector can retain an independently validated bounded JPEG preview without claiming successful face analysis. Explicit DEBUG synthetic UI providers establish workflow evidence only; native Vision simulator/device evidence remains separate. Cancel, lock, memory/storage pressure and source loss retain accepted records. Task 1.5 resumes by rediscovering metadata while first publishing last-verified cached records. Provider-guaranteed unchanged content revisions avoid reads and analysis; weak metadata requires cancellable SHA-256 integrity reads. Unchanged bytes retain face UUIDs; changed bytes durably invalidate the old face generation before processing. Missing status requires a successful complete enumeration. Durable scan leases reject stale writes. Regrant uses volume/root identity when available and otherwise requires explicit confirmation of the original root; names and paths never establish identity. Counts describe the current discovery pass, while accepted catalog records remain visible across interruption. Restart resolves bounded protected bookmark data after publishing cached records; permission restoration never starts a scan and cannot overwrite a newer manual folder selection. Valid source operations renew stale minimal bookmarks. Derived previews can be evicted and are explicitly unavailable offline. An explicit scan verifies unchanged bytes and rebuilds missing previews without rerunning detection or changing accepted face identities; failed recovery keeps the analysis and reports the preview unavailable. Schema migration uses a validated SQLite backup snapshot and transactional rollback in protected owned catalog storage, never the source drive. Native protection/lock effectiveness and UI execution remain phase/device evidence boundaries.

Core search captures canonical UUID aliases, confirmed sets, raw detected-face coverage, counts and ordered pages in one read transaction. Together requires all selected confirmed people; Any requires at least one; Only requires the exact set and every raw detection resolved as a valid current confirmation or explicit valid false detection. Invalid geometry, unknown extras and stale generations never establish Only. Optional model jobs do not gate unrelated confirmed photos. Capture dates sort by source local wall clock, with unknown dates last and UUID ties.

Task 4.2 connects confirmed-person Search to immutable catalog snapshots. Selection edits cancel the single query; paging keeps captured names, IDs and counts until explicit refresh. Possible matches remain unavailable. Original viewing uses an independent read-only coordinated source actor and validates a present source binding, captured UUID/version/path/hash and actual bytes before publication, then closes access. Explicitly bound unknown provider identity remains eligible only with exact byte proof and unchanged app source generation; a missing binding fails closed. Decoding is bounded to 64 MiB input, 80 MP headers and a 1024-pixel raster. Source loss, changed bytes or stale snapshots use clearly labeled cached previews; missing cache stays unavailable. Dismissal, memory warning and device lock invalidate work and release images. Headless core/compile, accumulated native UI and physical-device acceptance remain separate gates.

Phase 4 synthetic held-viewer cancellation evidence observes the actual request catching cancellation and finishing with zero publications, rather than inferring cancellation from a dismissed image. Compact UI label/target-size checks do not establish VoiceOver or hardware-keyboard operation.

## Catalog-session preparation boundary

App lifecycle registrations precede asynchronous startup, scanning, People reads, decisions, merge/undo, Search and Viewer work. Quiescence closes admission, advances a session token distinct from source generation and catalog revision, cancels owned work and awaits its actual completion with a finite deadline. Timeout leaves the original graph retained and admissions closed; it does not authorize replacing the repository. Retired sessions cannot publish results, cached fallbacks, errors or completion flags. A committed write remains successful even when its session can no longer refresh. A fresh graph is published synchronously only after confirmed drain. Backup adoption is not integrated in this preparation slice; causal held-session UI tests are authored and mapped, with execution reserved for the coordinated phase gate. People/Library protected-media release remains a separate Task5.2 boundary.

A timed-out catalog session remains closed even after late workers finish. Only an explicit bounded drain retry in the same closed epoch can clear timeout and establish a successful drain; concurrent drain waiters are rejected. Fresh graph publication rejects timed-out or never-successfully-drained sessions. Re-drain does not resume source access or replace a repository automatically.

Catalog backup/restore Core is integrated for verification; this does not establish phase acceptance, crash-matrix completion, or physical-device durability. Metadata-change failures remain unresolved.

The archived focused crash run reached 10 synthetic SIGKILL terminations and nine fresh semantic recoveries with 10 owned roots cleaned. These process-crash checks do not establish physical power-loss durability or explain earlier metadata-change mask 4224. Main candidate evidence remains separate and phase acceptance is pending.

## Catalog portability App integration (Task 5.1D2 preparation)

- Startup retains CatalogRestoreRepository before catalog filesystem effects; returned actors survive later snapshot failures. Retry keeps the same recovery capability; no ordinary competing open is attempted.
- Replacement closes admission and awaits actual workers; timeout remains closed until explicit successful re-drain. The owning restore controller is not an admitted client. Complete graph publication is synchronous and session-fenced. A typed checked-cleanup accessor alone can authorize preserved-original graph adoption, retaining its original source selection. Restored/recovered graphs clear source selection and require explicit reconnect.
- Restore validation precedes replacement preview/confirmation. No import/source-original writes, grants, previews or custom cryptography. Durable failure retains owner and explicit Retry; progress is never reservation authority.
- Progress uses one bufferingNewest(1) stream and consumer per operation, fixed phase/count/unit values and a separate terminal result. No Task per row callback; stale sessions cannot publish results, errors or progress.
- Export needs explicit selected folder/confirmation, unencrypted sensitive-content and source-drive-loss warnings. Unique exclusive creation never replaces another output; bounded FD checks/checksums precede completion and partial cleanup verifies owned identities. Previously exported copies/originals remain outside cleanup.
- Fourteen backup/session UI selectors are authored/mapped; six predecessors are preserved. No UI/device/owner acceptance is established by headless compilation. Task 5.2 deletion/protection and full phase5 acceptance remain pending.

Prepared typed person-family deletion with immutable history retained, comprehensive inverse-reference checks, source-grant disconnect, and a fenced runtime catalog-cleanup owner. Whole-app draining, durable erase guarantees, physical-device behavior, and Phase5 acceptance remain unproven.

### Presentation continuity preparation (Task 6.1A, isolated and unaccepted)
- Only bounded input preferences and dirty draft baselines persist in a protected, backup-excluded ApplicationSupport sibling. Results, counts, coverage, images, source paths and grants never persist there; exported backups exclude this sibling. Relaunch requires explicit fresh search capture.
- One coalescing epoch writer accounts actual completion before replacement reset. Checked preserved-original authority keeps inputs; actual replacement resets them. Async owned-preference deletion is a future Task 5.2 seam, not an implemented catalog-deletion flow.
- Dirty owner text survives refresh, navigation and relaunch. Canonical changes, merge or deletion require explicit review/use-current/discard before Save. This UI preflight is not a concurrent Core compare-and-swap. Committed decision success clears dirty input even when refresh warns. Overflow retains RAM text and reports a fixed warning; no silent eviction or sensitive logging.
- Nine causal presentation UI selectors are authored/mapped. Headless compilation cannot establish rendered CLEAR, keyboard, large-type, native UI or owner acceptance. Phase 6 integration remains blocked on Phase 5 clearance.

- A failed presentation write stops its loop and retains current RAM input. Explicit production Retry requeues the latest inputs only through current open-session admission; controls disable during actual work/quiescence, and fixed success follows real flush completion. Bounds remain enforced; no automatic failure retry.
- Synthetic obstruction repair requires the recorded regular-file device/inode and single-link identity; repair alone never retries or reports a save. One causal actual failed-write/repair/resubmit Core regression and one additional UI flow cover the correction; native UI remains UNRUN.

- App-owned backup/validation/restore outputs select immutable macOS descriptor exclusion with checked identity/readback/close; iOS and live catalog protection retain Foundation. Originals never enter this setter. Synchronous per-trial assertions and bounded original-stat traces preserve all recovery guard semantics. Native/physical acceptance remains pending.

## Qualified partial integration boundary

- Privacy actions drain active work before disconnecting grants, clearing caches or deleting a person family. Immutable decision history remains; local input cleanup retries do not repeat committed person deletion.
- Catalog deletion retains its cleanup owner across busy or partial failures. Source originals and exported backups remain outside deletion; a deleted catalog is never silently recreated.
- Protected-data suspension fences ordinary admission through checked close and explicit reopening. Returned actors remain owned until safe closure; interrupted reopen stays fenced. Retired prepared-export cleanup now uses the checked original-owner App bridge; accumulated verification remains pending.
- Search input preferences and dirty name drafts survive ordinary navigation and refresh. Catalog replacement explicitly invalidates old presentation state; cancelled replacement preserves the original graph.
- SFace preprocessing is a detector-neutral synthetic reference boundary, not recognition qualification. Device delivery receipts distinguish host bytes, install outcome and independently verified installed bytes.
- This qualified source union preserves existing gates and adds privacy/protection memberships. Accumulated phase5/phase6 acceptance, pending cleanup integration and physical-device qualification are not established by parser checks.

## Qualified cleanup and alignment integration

- Prepared backup cleanup retains the original output owner and exact identity through catalog retirement and ordinary reopening. Foreign children, symlink replacements and incomplete synchronization cannot be admitted as successful cleanup. The App cleanup bridge is connected; accumulated native verification remains pending.
- Face alignment association is ephemeral and binds photo generation, bounded raster token and detector revisions. Ambiguous, incomplete or invalid candidate geometry is unavailable; original Vision analysis and manual identity state remain unchanged. Synthetic software checks do not establish trained recognition or physical-device qualification.

- App prepared-stage cleanup selects the retained first original suspension or the actual live prepared owner before I/O, without catch-based fallback. A typed reopen permit or captured open-generation gates each new effect; Core success consumes the exact owner/stage before publication checks and releases only matching historical proof. Failure retains authority for explicit retry. Confirmed-deletion reopen branches require checked cleanup before further erase/preparation. All eleven protected UI selectors remain mapped; native and physical-device verification are pending.

## Runtime and decoder integration boundary

- Production AFITCRuntime is the shared SwiftPM/Xcode SFace CPU module linked by the App and tests. Preparation validates pinned model bytes and metadata; cancellation drains actual work without stale publication. Queued inference revalidates provenance after predecessor work completes.
- Strict YuNet named-head decoding, stable integer NMS and effective-scale inverse coordinates are source mechanics. Frozen generated-reference checks do not establish ONNX YuNet inference, App admission, identity usefulness or physical-device qualification.
- Explicit artifact diagnostics remain separately mapped with all assertions. Normal decoder/pixel phase variants omit only those deliberate artifact opt-ins; runtime mechanics remain accumulated. Existing model opt-in phase mapping requires the pinned local model at its final gate.

## Current-face runtime return boundary

- SFace and YuNet runtime actors drain actual child work, then check parent cancellation and current provenance before returning. A completed progress callback is not publication authority.
- CatalogFacePipeline captures the actual owner/source/photo/detector/manual projection and optional scoped anchor in one existing read transaction; validate also requires the caller-verified content hash. It ignores unrelated revision changes and grants no future persisted-write permission. No schema/history epoch or identity inference is introduced.
- Generic YuNet mechanics remain accumulated; actual pinned ten-input CPU diagnostics are explicitly opted in and independently mapped. Source mechanics and host measurements do not establish App resource/wiring, physical inference, cross-backend tolerance or recognition usefulness.

## Transient scan-byte face pipeline boundary

- ScanCoordinator offers one optional awaited enrichment after an accepted photo is saved and published, only for bytes this scan iteration already read and hashed. It passes the same bytes, hash, entry and source identity; no reopen or second read. The trusted no-read path and non-successful analyses never enrich. Ordinary enrichment failure leaves saved analysis and manual state unchanged and reports unavailable; cancellation waits for the callback's actual return, then the existing source close and single finish. Stage text reaches the existing scan progress surface, is never checkpointed, and stops once cancellation or pause is requested.
- TransientFaceEmbeddingProducer composes canonical oriented RGB, the qualified fixed-640 BGR tensor, pinned YuNet heads, strict decode and inverse geometry, unique association to existing Vision face UUIDs, the SFace five-point crop and the raw 128-value output. It captures the catalog fence from the saved photo, requires the scan's verified hash, and revalidates after every await before publishing. Ambiguous, unmatched or misaligned faces are unavailable; zero-face photos never prepare models. The producer never normalizes, matches, persists or encodes vectors. Only with evaluation suggestions on, a FaceJobCoordinator normalizes a fenced photo's vectors once into a bounded RAM-only index (default 20,000 faces; when full it stops adding). The index is never encoded, persisted or exported, and is dropped on toggle off, quiescence, memory pressure, source or catalog-session change and relaunch. A ranking already running when the index is dropped holds its own vector copy only until that ranking returns; its result is discarded unpublished. Suggestions are labeled evaluation-only and never confirm.
- The store retains only the latest single-photo batch in RAM; the evaluation suggestion index above is the only other vector holder and the same invalidations drop it. MainActor clear, session quiescence, protected-snapshot release, source change and memory pressure synchronously invalidate the operation token and drop the batch; a completion that drains afterwards cannot publish. Model handles are released after the owning scan returns. A retained batch proves one transaction instant; any later use must revalidate it.
- Generic mechanics use fake ORT sessions behind the production adapter. The actual host CPU pipeline diagnostic is opt-in, reads models and the JPEG only from explicit environment paths, and is mapped separately from phase6. Neither establishes recognition usefulness, a tolerance, iOS trained execution or physical-device qualification.
