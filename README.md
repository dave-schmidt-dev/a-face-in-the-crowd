# A Face in the Crowd

A planned, local-first iPad app for naming people in personal photo collections and finding photos containing selected combinations of them.

**Status:** buildable iPadOS 17 source slice with folder selection, recursive JPEG previews, local face detection and resumable incremental reconciliation. Synthetic core regressions and simulator compilation pass; native UI checks run at the phase gate, and physical-drive/device acceptance remains pending. People, Verify and Search have navigation placeholders; naming, recognition, people search and TestFlight are not available.

## Product direction

- Read one user-selected external-drive root and its nested folders without changing originals.
- Keep human-confirmed identities separate from machine suggestions.
- Search for any selected set of people with Together, Any selected, and Only selected rules; Exclude is deferred.
- Store the catalog locally and make backup, restore, and export explicit.
- Design for accessible iPad use and truthful progress, uncertainty, and source availability.

The planned compatibility floor is iPadOS 17. Older test iPads establish compatibility; an M4 iPad Pro establishes target performance. The accepted UI is retained. Foreground indexing must show honest progress and resume after interruption. Optional OS 26/27 features are outside the core MVP.

## Delivery sequence

1. Prove external-drive access, reconnect, durable decisions, and a licensed local face model on target iPads.
2. Build the read-only catalog, naming and verification, deterministic people search, and recovery workflow.
3. Add optional local scene understanding and query assistance after the core people workflow is reliable.
4. Complete local testing before a limited TestFlight with the intended testers.

The source design packet and operational planning records are retained locally and are excluded from this public repository. Reference artwork and third-party model weights are not licensed by this repository's MIT license. No family photographs or biometric data should be committed.

## Repository state

The app reads one selected folder recursively without changing originals, publishes previews before discovery completes and records explicit discovery, processing, skipped and failed counts. Accepted previews and stable photo identities survive interrupted scans. Trusted unchanged revisions reuse prior work; ambiguous revisions receive cancellable integrity reads. Source failures preserve accepted data, and missing records are marked only after successful complete discovery. Regranting an unverifiable source requires confirmation.

The transactional SQLite catalog, checkpoints and bounded preview cache stay in the protected app container. Synthetic regression coverage includes interruption, source loss, stale generations, disk pressure and migration rollback. Headless checks verify target membership and compile the app and both test bundles without booting a simulator. These checks do not establish real-drive access, live Vision behavior, native UI usability or physical-device performance. [INVARIANTS.md](INVARIANTS.md) defines the system contract; [CHANGELOG.md](CHANGELOG.md) records human-facing changes.

## Verification and diagnostics

`tools/verify.sh task1.1 --headless`, `tools/verify.sh task1.4 --headless`, `tools/verify.sh task1.2 --headless` and `tools/verify.sh task1.5 --headless` have passed their mapped core checks and incremental iPad test-bundle compilation. It validates exact Xcode source membership, SwiftPM test membership, every test-file mapping and actual passing selectors; missing, empty or drifting mappings fail. Evidence and elapsed time are retained in `.logs/verification/`.

The accumulated native phase gate is configured for all four source-slice tasks; native UI checks run at that gate. It compiles the app/test bundles and executes synthetic UI checks on a disposable iPad simulator. The gate requires the installed shared `simctl_gate_lib.sh` at `~/Documents/Projects/apple_developer/release_tools/templates/` (override with `AFITC_SIMCTL_GATE_LIB`). The helper owns device cleanup, clone cleanup and the shared Apple UI lock. Headless checks never boot devices. Simulator evidence does not establish physical source/device acceptance.

Diagnostics accepts fixed event categories and aggregate nonnegative counts only. Warnings always write; debug events require `--debug`. Protected, backup-excluded diagnostics rotate at 64 KiB into at most three archives, in the app container. Names, paths, images, vectors and free-form errors have no logging API. Model weights, conversion products, private catalogs/vectors, SwiftPM caches and diagnostics are excluded from Git; the changelog remains public.

## Versioning

The first functional milestone will start at 0.1.0, with SemVer for documented workflow/catalog compatibility. The bootstrap app identifies itself as 0.1.0; it has no functional release. Pending changes stay under Unreleased.

## License

Original project work in this repository is available under the [MIT License](LICENSE). Third-party materials require their own rights review.
