# A Face in the Crowd

A planned, local-first iPad app for naming people in personal photo collections and finding photos containing selected combinations of them.

**Status:** deep MVP plan complete; implementation has not started. There is no Xcode project, working app, validated face model, device test, or TestFlight build in this repository.

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

This repository currently contains project documentation only. The local deep plan contains six phases and 18 validated task contracts. Native implementation, actual test commands, qualified face-model/runtime, installation and device results will be documented when they exist. [INVARIANTS.md](INVARIANTS.md) defines the planned system contract; [CHANGELOG.md](CHANGELOG.md) records human-facing changes.

## Versioning

The first functional milestone will start at 0.1.0, with SemVer for documented workflow/catalog compatibility. This docs-only planning checkpoint has no app release or native version source; pending changes stay under Unreleased.

## License

Original project work in this repository is available under the [MIT License](LICENSE). Third-party materials require their own rights review.
