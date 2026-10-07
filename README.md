# A Face in the Crowd

A planned, local-first iPad app for naming people in personal photo collections and finding photos containing selected combinations of them.

**Status:** buildable iPadOS 17 source slice with folder selection, recursive JPEG previews, local face detection and resumable incremental reconciliation. People supports manual naming, correction, deliberate merge and undo with stable person IDs; confirmed-person Search supports Together, Any and Only. Backup export, validated restore, privacy controls and whole-catalog deletion are implemented. Scans persist face analysis once and reuse it across rescans and relaunch. People shows saved unnamed groups and named possible photos; Verify reviews the same saved membership without a toggle or rescan. Recognition qualification remains separate. Physical iPad compatibility, qualified recognition and full MVP acceptance require separate device and model evaluation.

## Product direction

- Read one user-selected external-drive root and its nested folders without changing originals.
- Keep human-confirmed identities separate from machine suggestions.
- Search for any selected set of people with Together, Any selected, and Only selected rules; Exclude is deferred.
- Store the catalog locally and make backup, restore, and export explicit.
- Design for accessible iPad use and truthful progress, uncertainty, and source availability.

The planned compatibility floor is iPadOS 17. Older test iPads establish compatibility; an M4 iPad Pro establishes target performance. The accepted UI is retained. Foreground indexing must show honest progress and resume after interruption. Optional OS 26/27 features are outside the core MVP.

## Delivery sequence

1. Prove external-drive access, reconnect, durable decisions, and a licensed local face model on target iPads.
2. Complete verification of the read-only catalog, naming, confirmed-person search, and recovery workflow.
3. Add optional local scene understanding and query assistance after the core people workflow is reliable.
4. Complete local testing before a limited TestFlight with the intended testers.

The source design packet and operational planning records are retained locally and are excluded from this public repository. Reference artwork and third-party model weights are not licensed by this repository's MIT license. No family photographs or biometric data should be committed.

## Repository state

The app reads one selected folder recursively without changing originals, publishes previews before discovery completes and records explicit discovery, processing, skipped and failed counts. Accepted previews and stable photo identities survive interrupted scans. Trusted unchanged revisions reuse prior work; ambiguous revisions receive cancellable integrity reads. Source failures preserve accepted data, and missing records are marked only after successful complete discovery. Regranting an unverifiable source requires confirmation.

The transactional SQLite catalog, checkpoints and bounded preview cache stay in the protected app container. Synthetic regression coverage includes interruption, source loss, stale generations, disk pressure and migration rollback. Headless checks verify target membership and compile the app and both test bundles without booting a simulator. These checks do not establish real-drive access, live Vision behavior, native UI usability or physical-device performance. [INVARIANTS.md](INVARIANTS.md) defines the system contract; [CHANGELOG.md](CHANGELOG.md) records human-facing changes.

Schema 4 adds durable face-analysis storage with content, source and pipeline guards. Backup exports remove derived vectors and mark restored catalogs for recomputation while retaining human decisions. The core derives bounded provisional groups from a consistent durable-analysis snapshot, with stable seed identity across naming and later analysis. Naming confirms only the inspected cover; group exclusions persist across reseeding and support guarded undo. Displayed-group deletion suppresses that content/source generation across model refresh and remains non-undoable. Scans persist analysis once and reuse it thereafter (see the face analysis boundary below); group naming and review UI are implemented; possible-membership Search is the next phase, and recognition qualification and owner acceptance remain separate.

## Manual identity boundary

Manual decisions attach to the selected current face generation. Distinct people may have equal display names; duplicate photo bytes and third-person assignments do not propagate during merge. The People workflow supports naming, reassignment, unsure, rejection, explicit not-a-person correction, and deliberate source-to-survivor merge. Every confirmed/rejected face conflict needs an exact explicit choice; cancel writes nothing. Merge and reopened undo restore links, negatives, deferrals, anchors, covers, names, source archive and distinct-photo counts atomically while advancing exemplar epochs. Legacy schema 3 undo payloads remain readable, and successive undo stays safe. An affected same-generation face unavailable at merge time must reconnect before merge; changed-generation history stays inactive.

People releases cached face-preview rasters and invalidates in-flight preview work when the view disappears or memory pressure is reported. DEBUG fixtures use explicit synthetic inputs and do not establish recognition. Native UI, physical-device and model qualification remain separate acceptance gates.

## Search and viewer boundary

Search uses human-confirmed identities and Together, Any, or Only selection rules. Results are immutable pages from a captured catalog revision. The read-only viewer validates the selected original and falls back to a bounded cached preview when the original is unavailable or changed. Capture ordering uses validated original JPEG wall-clock metadata. These capabilities do not qualify recognition suggestions, backup/restore, physical-device behavior, or a production model.

## Face analysis boundary

During a scan, photos whose bytes were actually read may get face analysis: the scan reuses those exact bytes, runs the pinned local YuNet and SFace models on the CPU, and attaches raw vectors only to existing Vision face IDs that match one detection uniquely. Results persist in the protected catalog through a fenced transaction that rechecks the current source, content hash, geometry and detector generation, rechecks exact-generation suppression before inserting (so a deletion landing mid-flight cannot re-insert suppressed vectors), and prunes stale source-binding rows before capacity counting. Human naming during in-flight analysis does not discard usable model results; generation, source or session changes do.

Scans analyze once and reuse thereafter. A trusted unchanged photo whose current completed analysis matches the actual catalog photo, source binding and pipeline causes zero extra reads and zero model work across rescans and relaunch; durable vectors reload from the catalog after relaunch or memory pressure. A trusted unchanged photo missing analysis gets exactly one admitted catch-up read after the pinned models are prepared and thermal/memory admission is open; failed, paused and capacity-full states are explicit retry states, never empty success, and `CatalogRepository.admitFaceAnalysisRetry(photo:manifest:)` explicitly admits another attempt for the inspected photo; ordinary scans preserve the retry hold. Catch-up preserves the stored Vision face keys, geometry, content version and manual identity decisions without rerunning the detector. Naming or viewing a photo never starts source reads or inference. Failures leave accepted analysis and manual decisions unchanged. Synthetic DEBUG fixtures bypass the trained models. This does not establish recognition usefulness or physical-device qualification.

People opens an unnamed group's photos and names its inspected cover in place, preserving the group seed and visible photos. Named details distinguish confirmed and possible photos and offer guarded confirm/reject and Undo. One off-main saved-membership result feeds People and Verify, including after reopening; label save and navigation never read sources or run inference. Grouping runs at coalesced, logarithmic awaited scan boundaries and respects the model thermal/memory gate. An explicit Retry unfinished face analysis action admits only current failed/paused/capacity markers before an ordinary scan; successful photos retain reuse. Manual per-face naming remains available below groups.

Verify shows one saved suggestion at a time with the candidate, closest confirmed example and similarity. Yes, Not this person, Unsure and Not a person are ordinary undoable decisions guarded against cards that changed elsewhere; Skip lasts for the session. Thresholds are uncalibrated and recognition is not qualified. DEBUG synthetic source/detector fixtures persist fixed fictional vectors during their first ordinary scan; no suggestion toggle or Find face details pass is required.

## Verification and diagnostics

Use `tools/verify.sh task7.4 --headless` for portable AppServices causal tests and iPad compilation. `phase7 --headless` unions current task7.1–task7.4 coverage with phase6; the focused native group/name/reopen/confirmed-Search journey is registered for the next GUI milestone. Possible-membership Search and task7.5 join that union in the next phase. Use `tools/verify.sh task3.3 --headless`, `task4.1 --headless`, `task4.capture-date --headless`, `task4.2 --headless`, and `task2.3-producer --headless` for focused checks; `tools/verify.sh phase3` and `phase4` run accumulated gates. `tools/verify.sh phase6 --headless` runs the accumulated phase's Core tests and iPad compile without the simulator UI suite; the pre-push hook uses it, and the full `phase6` UI gate runs at release milestones. Native phase gates run only the 10 UI journeys in `ui.journeys`; the 45 App-session UI checks in `ui.release` run with `tools/verify.sh phase-release-ui` before a release. `tools/verify.sh phase6` runs the accumulated gate and requires `AFITC_RUN_SFACE_MODEL_TESTS=1` with `AFITC_SFACE_MODEL_PATH` set to the verified local SFace artifact, since skipped selectors fail the gate. Task and phase selector mappings live in `tools/test-manifest.json`; the runner checks exact Xcode and SwiftPM membership, mapped selectors, and iPadOS 17 app/test compilation, and fails on missing or drifting mappings. Each run writes receipts and logs under `.logs/verification/`; these logs and `HISTORY.md` are local ignored evidence, not files distributed with the public repository. This command list is reproducible guidance, not a claim that every command was run.

The accumulated native phase gate uses the task set configured for that phase in `tools/test-manifest.json`; native UI checks run at that gate. It compiles the app/test bundles and executes synthetic UI checks on a disposable iPad simulator. The gate requires the installed shared `simctl_gate_lib.sh` at `~/Documents/Projects/apple_developer/release_tools/templates/` (override with `AFITC_SIMCTL_GATE_LIB`). The helper owns device cleanup, clone cleanup and the shared Apple UI lock. Headless checks never boot devices. Simulator evidence does not establish physical source/device acceptance.

Diagnostics accepts fixed event categories and aggregate nonnegative counts only. Warnings always write; debug events require `--debug`. Protected, backup-excluded diagnostics rotate at 64 KiB into at most three archives, in the app container. Names, paths, images, vectors and free-form errors have no logging API. Model weights, conversion products, private catalogs/vectors, SwiftPM caches and diagnostics are excluded from Git; the changelog remains public.

## Versioning

The first functional milestone will start at 0.1.0, with SemVer for documented workflow/catalog compatibility. The bootstrap app identifies itself as 0.1.0; it has no functional release. Pending changes stay under Unreleased.

## License

Original project work in this repository is available under the [MIT License](LICENSE). Third-party materials require their own rights review.

## Pinned local model resources

`tools/model-resources.json` pins YuNet and SFace bytes and their upstream notices. Run `python3 tools/acquire-model-resources.py` to acquire missing ignored weights; `--model` selects one model. Existing invalid files are preserved, promotion never overwrites a destination, and per-model locks serialize acquisition. `--verify-only` performs offline checks (also run before Xcode builds). Models and notices are bundled as read-only resources; no App download is enabled. Software mechanics and bundled-byte checks do not establish recognition usefulness or physical-device qualification.
