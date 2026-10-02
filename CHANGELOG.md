# Changelog

All notable changes to this project will be documented here.

The format follows Keep a Changelog 1.1.0, and functional releases will follow Semantic Versioning 2.0.0.

## [Unreleased]

### Added

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

- Valid photo previews remain available when face detection fails; analysis remains unresolved and failure counts stay explicit. Protected catalogs reject malformed empty payloads, and preview-cache bookkeeping avoids repeated full-directory scans.

- Native verification selects an installed iPad from an available runtime’s supported device types, preventing incompatible device/runtime pairs and comparing runtime versions numerically.

No functional app release exists yet.
