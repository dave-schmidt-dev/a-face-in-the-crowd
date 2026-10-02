# Changelog

All notable changes to this project will be documented here.

The format follows Keep a Changelog 1.1.0, and functional releases will follow Semantic Versioning 2.0.0.

## [Unreleased]

### Added

- Explicit duplicate-person merge previews show source/kept record IDs, photo counts and contextual per-face conflict choices. Atomic merges preserve archived provenance; restart-safe undo restores affected decisions and advances exemplar epochs so stale work stays stale. Unavailable same-generation decisions must reconnect before merging.

- Durable manual people records with selected-face naming, distinct same-name IDs, explicit false-detection decisions, pair rejections and deferrals. Corrections and atomic undo validate the current photo/detector generation; People detail shows confirmed-photo counts and bounded preview context. Fictional runtime fixtures cover the manual workflow separately from model qualification.
- Read-only folder selection and recursive JPEG scanning with incremental previews, explicit progress, cancellation and local face detection states.
- Resume and incremental reconciliation with cached last-verified previews, cancellable integrity reads, source identity confirmation and durable stale-scan protection. Changed bytes invalidate face generations; unavailable folders retain the catalog, and missing photos are marked only after complete discovery. Saved folder permissions restore after cached catalog publication; deterministic interruption fixtures cover resumed scans.
- Bounded image decoding, protected transactional catalog/checkpoints and a backup-excluded 512 MiB preview cache.
- Adaptive Library, People, Verify and Search navigation with Settings, plus typed redacted diagnostics with bounded rotation and debug opt-in.
- iPadOS 17 app/core foundation and manifest-driven verification with synthetic source/recovery regressions, target-membership checks and ownership-safe simulator cleanup. Synthetic UI checks are separate from physical-device acceptance.
- Contracts for preserving originals, local sensitive data, human confirmation, truthful search and recoverable catalogs.

### Changed

- Defined the MVP around one drive with nested folders, three confirmed-people search modes and visible resumable indexing; scene and language features remain outside the core MVP.
- Separated synthetic core checks and simulator compilation from native UI, physical compatibility and M4 performance acceptance.

### Fixed

- Bounded native UI reveal and People traversal loops stop checking once their target is visible, preserving scroll limits and workflow assertions.
- The accumulated Phase 3 native verification budget is 30 minutes following measured accessibility latency; other phases retain 20 minutes, with assertion waits and owned-process cleanup unchanged.
- Automatic People snapshots during a scan use exponentially spaced callbacks, with explicit final/user refreshes; cover lookup is indexed per render. Preview loading and release keep stable geometry, and passive UI status checks use visible frames rather than activation points.
- Scan updates coalesce People refreshes into bounded outstanding work. Saved decisions and merges close their forms even if the subsequent view refresh fails, with a separate retryable warning; cached Library recovery survives a people-only read failure. Rename undo synchronizes the editable name, and compact workflow checks scroll to visible status without extending timeouts.
- Face previews release decoded images when leaving the screen or receiving a memory warning, and discard cancelled or stale decode completions. Memory-release placeholders remain truthful.
- Valid photo previews remain available when face detection fails; analysis remains unresolved and failure counts stay explicit. Protected catalogs reject malformed empty payloads, and preview-cache bookkeeping avoids repeated full-directory scans.

- Native verification selects an installed iPad from an available runtime’s supported device types, preventing incompatible device/runtime pairs and comparing runtime versions numerically.

No functional app release exists yet.
