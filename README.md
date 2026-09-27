# A Face in the Crowd

A planned, local-first iPad app for naming people in personal photo collections and finding photos containing selected combinations of them.

**Status:** specification scaffold only. There is no Xcode project, working app, validated face model, device test, or TestFlight build in this repository.

## Product direction

- Read photos from user-selected external folders without changing the originals.
- Keep human-confirmed identities separate from machine suggestions.
- Search for any selected set of people with Together, Any selected, Only selected, and Exclude rules.
- Store the catalog locally and make backup, restore, and export explicit.
- Design for accessible iPad use and truthful progress, uncertainty, and source availability.

## Delivery sequence

1. Prove external-drive access, reconnect, durable decisions, and a licensed local face model on target iPads.
2. Build the read-only catalog, naming and verification, deterministic people search, and recovery workflow.
3. Add optional local scene understanding and query assistance after the core people workflow is reliable.
4. Complete local testing before a limited TestFlight with the intended testers.

The source design packet and operational planning records are retained locally and are excluded from this public repository. Reference artwork and third-party model weights are not licensed by this repository's MIT license. No family photographs or biometric data should be committed.

## Repository state

This repository currently contains project documentation only. Native implementation, test commands, supported OS versions, and device results will be documented when they exist.

## License

Original project work in this repository is available under the [MIT License](LICENSE). Third-party materials require their own rights review.
