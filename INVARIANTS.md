# AFITC invariants

Planning charter for the native MVP; rules are required, not claims of existing implementation. iPadOS17 minimum; one chosen drive root; local processing; human-confirmed Together/Any/Only search. Current user scope overrides archived packet examples.

Gate mappings identify verification entry points, not passing evidence. INV-4, INV-6 and INV-9 map to planned qualification tests that are not implemented or run yet.

Area mappings include current and planned paths; mappings do not claim implementation.

### INV-1 — Visible, resumable work
area: ["Sources/AFITCCore/ScanCoordinator.swift", "App/AppServices.swift", "App/StatusView.swift", "App/LibraryView.swift", "tools/verify.sh"]
gate_test: Tests/AFITCCoreTests/SourceRecoveryTests.swift
threshold: 3
rationale: Discovery, reads, hashes, previews, detection, inference and restore show actual operation/counts, indeterminate totals where unknown, cancellation and durable checkpoints; failures preserve accepted work.

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
area: ["Sources/AFITCCore/PeopleRepository.swift", "Sources/AFITCCore/DecisionService.swift", "Sources/AFITCCore/UndoService.swift", "App/PeopleView.swift", "App/PersonDetailView.swift"]
gate_test: Tests/AFITCCoreTests/DecisionDurabilityTests.swift
threshold: 3
rationale: Naming confirms only the selected face. Suggestions cannot confirm themselves; rejection/unsure history persists. Correction/merge conflicts require explicit resolution; undo restores before-state atomically.

### INV-5 — Stable catalog versions
area: ["Sources/AFITCCore/PhotoIdentity.swift", "Sources/AFITCCore/FaceAnalysisState.swift", "Sources/AFITCCore/ScanCoordinator.swift", "Sources/AFITCCore/CatalogRepository.swift", "Sources/AFITCCore/CatalogSchema.swift"]
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
area: ["Sources/AFITCCore/ScanCoordinator.swift", "Sources/AFITCCore/CachePolicy.swift", "Sources/AFITCCore/CatalogRepository.swift", "App/Services/PreviewService.swift", "App/Services/FaceEmbeddingService.swift", "App/Services/PrivacyProtection.swift"]
gate_test: Tests/AFITCCoreTests/SourceRecoveryTests.swift
threshold: 3
rationale: Decode/inference concurrency and the shared thumbnail/crop/example cache are bounded. Lock, source loss, low storage and memory pressure pause safely; cache eviction has explicit offline effects.

### INV-9 — Evidence-bound qualification
area: ["Sources/AFITCCore/ModelManifest.swift", "Sources/AFITCCore/EmbeddingProvider.swift", "App/Services/FaceAlignment.swift", "App/Services/FaceEmbeddingService.swift", "tools/model-qualification.md"]
gate_test: Tests/AFITCCoreTests/ModelContractTests.swift
threshold: 3
rationale: Model rights/checksum/alignment/runtime/parity/usefulness are documented before recognition rollout. Simulator/core tests, physical iPad6 compatibility, installed M4 performance and owner usability are separate gates. No model substitution, install, upload or publication without its required authority.

## Source catalog implementation boundary

Task 1.2 implements pull-based recursive JPEG discovery, protected transactional per-photo/checkpoint state, bounded oriented previews and versioned local Vision landmarks. First previews are published before requesting the next discovery entry. Pending, skipped and failed detections remain unresolved; successful zero-face detection never confirms an identity. A failed detector can retain an independently validated bounded JPEG preview without claiming successful face analysis. Explicit DEBUG synthetic UI providers establish workflow evidence only; native Vision simulator/device evidence remains separate. Cancel, lock, memory/storage pressure and source loss retain accepted records. Task 1.5 resumes by rediscovering metadata while first publishing last-verified cached records. Provider-guaranteed unchanged content revisions avoid reads and analysis; weak metadata requires cancellable SHA-256 integrity reads. Unchanged bytes retain face UUIDs; changed bytes durably invalidate the old face generation before processing. Missing status requires a successful complete enumeration. Durable scan leases reject stale writes. Regrant uses volume/root identity when available and otherwise requires explicit confirmation of the original root; names and paths never establish identity. Counts describe the current discovery pass, while accepted catalog records remain visible across interruption. Restart resolves bounded protected bookmark data after publishing cached records; permission restoration never starts a scan and cannot overwrite a newer manual folder selection. Valid source operations renew stale minimal bookmarks. Derived previews can be evicted and are explicitly unavailable offline. Schema migration uses a validated SQLite backup snapshot and transactional rollback in protected owned catalog storage, never the source drive. Native protection/lock effectiveness and UI execution remain phase/device evidence boundaries.
