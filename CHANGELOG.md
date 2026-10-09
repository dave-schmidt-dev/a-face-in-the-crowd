# Changelog

All notable changes to this project will be documented here.

The format follows Keep a Changelog 1.1.0, and functional releases will follow Semantic Versioning 2.0.0.

## [Unreleased]

### Added
- Added a standalone opt-in physical iPad People analysis-status probe (`AFITC_LIVE_UI_PROBE=1`) with safe aggregate output; `AFITC_LIVE_UI_OBSERVE_ONLY=1` observes an existing scan without tapping Finish.
- Portable AppServices backup-progress coverage now replaces its duplicate release UI check, with generated-source storage isolated beneath the injected test root and actual worker drain before teardown.
- Group photo crops now open their matching original through the existing guarded read-only viewer and retain the group on close.
- Naming or labeling a conservative pinned face group now assigns the chosen person to every safe member in one atomic, undoable transaction, so all group photos appear as confirmed Search results immediately. The cover is the only new training anchor; uncertain faces outside the group remain in the shared Verify review flow. Search still separates confirmed and possible results using one captured revision, and the explicit reviewed-batch API retains its full-state guards and Undo. No source read or inference runs during labeling.
- People opens saved unnamed groups and labels all safe pinned members in place while retaining the seed and photos. “Not in this group” removes only the selected member's assignment to that person, saves the separation, and supports Undo. Verify shares saved membership and lets people focus the existing review queue from People or Search without a toggle or rescan. People has one “Finish face analysis” action for missing-status photos and current retryable failures, using the guarded scan path while reusing completed analysis. Stable no-details failures are explained as an automatic-matching limitation and excluded from retry; other failure reasons use fixed safe wording. Source selection, original-source confirmation and progress remain in the People flow. Portable AppServices tests measure mixed-status completion and analysis reuse. Recognition and owner acceptance remain separate.
- Scans now persist face analysis durably and reuse it: two unchanged scans and a relaunch reuse one inference result with zero extra reads or model work, durable vectors reload from the catalog after relaunch or memory pressure, and a trusted unchanged photo missing analysis gets exactly one admitted catch-up read after pinned runtime preparation and thermal/memory admission. Failed attempts have an explicit per-photo retry admission. Catch-up preserves the stored Vision face keys, geometry, content version and manual identity decisions without rerunning the detector; failed, paused and capacity-full analysis are explicit retry states, never empty success. A deletion or suppression that lands while a batch is in flight cannot re-insert suppressed vectors, and human naming during in-flight inference no longer discards usable model results.
- Derive conservative provisional face groups from durable local analysis, preserving seed identity across naming and later faces. Naming assigns the label to every safe pinned member while using only the cover as a new anchor; guarded exclusions remove a corrected member's assignment, survive reseeding and can be undone. Displayed-group deletion suppresses the original generation across reopen and model refresh.
- Store versioned face analysis in the protected catalog, with atomic stale-result guards, capacity limits and migration from schema 3. Backups retain human decisions and omit derived face vectors.
- Added a local match-quality evaluation against the Gallagher research dataset, using the bundled face models and the app's suggestion rule; the dataset stays private and is never committed.
- Applied the approved design system across Library, People, Person, Verify, Search, Settings and the photo viewer: brand palette and lockup, a dense photo grid, circular people cards, one compact status per screen in plain language, destructive actions grouped last, pinch-to-zoom and date taken in the viewer, pull to refresh, and layouts that stay reachable at the largest text size on 9.7-inch iPads. Save warnings and retry rows no longer cover the last control.
- Verify offers evaluation suggestions, off by default: after Find face details, unidentified faces are compared in memory with faces you confirmed, and one possible match at a time is shown for Yes, Not this person, Unsure, Not a person or Skip. Suggestions never confirm themselves, close calls are not shown, and an answer on a card that changed elsewhere is refused until you choose Show latest. Recognition is not qualified; face details stay in the protected local catalog and reload after relaunch, and are never uploaded or exported.
- Scans can compute transient on-device face details for photos whose bytes were just read, reusing those bytes and keeping only the latest photo's raw results in memory. Existing face IDs and manual decisions are preserved; nothing is saved, matched or labeled. Recognition usefulness and device qualification remain separate.
- Bundled pinned local YuNet/SFace resources and license notices with offline build verification, strict read-only resolution, and resumable nonclobber acquisition. Resource checks accumulate with phase6; inference usefulness and device qualification remain separate.
- Integrated strict YuNet CPU preparation/inference mechanics and an immutable catalog face-freshness fence; explicit generated-reference diagnostics remain separate from recognition and device qualification.
- Integrated the production SFace CPU runtime module with strict preparation/cancellation/provenance checks and measured generated-input diagnostics. Numerical differences remain observations, without accepted cross-backend tolerance or recognition usefulness claims.
- Added strict YuNet named-head decoding and source-coordinate restoration, checked against frozen generated OpenCV reference outputs; App inference and physical-device qualification remain pending.
- Added bounded, cancellable YuNet 640 pixel preparation with exact ten-case OpenCV input-pixel parity; model execution and recognition remain separate gates.
- Connected protected catalog reopening and confirmed deletion to checked cleanup of the original retained prepared export; failures retain cleanup authority for explicit retry. Native UI and physical-device verification remain pending.
- Integrated retained prepared-backup cleanup ownership across catalog reopening, with strict synthetic foreign-output and partial-cleanup checks; the App bridge is connected; accumulated acceptance remains pending.
- Added ephemeral YuNet/Vision face alignment association with generation, raster and detector provenance checks. Ambiguous geometry stays unavailable; no recognition or persisted manual state changes are enabled.
- Integrated protected catalog privacy actions and retained reopening preparation; checked retired-export cleanup is connected; accumulated native acceptance remains pending.
- Added detector-neutral SFace RGB8 preprocessing with synthetic OpenCV reference checks and bounded source dimensions; recognition remains disabled.
- Prepared local device delivery tooling with generated-data behavioral checks; physical signing, installation and installed-byte readback remain unrun.
- Added pinned test-only ONNX Runtime arithmetic admission checks with separate macOS diagnostics and iOS simulator admission.
- Added pinned OpenCV Zoo SFace artifact metadata and dependency-free tensor/embedding contracts, with a local opt-in CPU diagnostic. It exercises generated input only and does not enable recognition or establish physical-device qualification.
- Expanded durable restore crash checks to derive killpoints from an observed trace, interrupt actual helper processes, and verify fresh-start recovery; phase acceptance remains pending.
- Preview-cache writes reserve retained previews, canonical residual staging files and new bytes; exclusive staging identity checks preserve the old preview and foreign replacements on failed publication. Missing previews rebuild from unchanged source content without rerunning face detection.
- Prepared typed person-family deletion with immutable history retained, comprehensive inverse-reference checks, source-grant disconnect, and a fenced runtime catalog-cleanup owner. Whole-app draining, durable erase guarantees, physical-device behavior, and Phase5 acceptance remain unproven.
- Failed input persistence now offers an explicit Retry saving inputs action, preserving current edits and reporting actual save completion. Native UI validation remains pending.
- Isolated preparation for saved search inputs, semantic scroll anchors and protected dirty name drafts. Completed searches survive navigation; conflicting drafts require review. Native UI validation and Phase 5 clearance remain pending.
- Catalog backup and validated replacement screens, with unencrypted-content warnings, explicit folder destinations, retained recovery Retry and renewed source access. This is local preparation; new UI flows have not yet been run or accepted.
- Integrated bounded restore read diagnostics and a focused synthetic process-crash regression. Earlier metadata-change failures remain unexplained; full phase acceptance is pending.
- Integrated the prepared catalog backup/restore Core and synthetic metadata diagnostics with the existing app session checks. Restore acceptance and the unexplained metadata-change investigation remain pending.
- Catalog-session admission, cancellation and actual completion fencing for preparing safe catalog recovery.
- Search now exposes confirmed-person Together, Any selected and Only selected controls, distinct UUID person chips, frozen result pages and explicit refresh. The read-only photo viewer verifies source binding and current byte hashes, decodes a bounded 1024-pixel image, and labels cached fallback or missing previews honestly.
- Confirmed-person Together, Any and Only queries capture names, counts, EXIF wall-clock ordering and immutable pages at one catalog revision. Explicit merge aliases retain stable identity; unresolved extra detections prevent Only matches.
- Original JPEG capture dates persist as optional source EXIF wall-clock metadata, with explicit unknown values and source offsets. Validation uses a conservative Gregorian/clock subset rather than claiming full EXIF conformance; import times and device time zones are never substituted.
- Explicit duplicate-person merge previews show source/kept record IDs, photo counts and contextual per-face conflict choices. Atomic merges preserve archived provenance; restart-safe undo restores affected decisions and advances exemplar epochs so stale work stays stale. Unavailable same-generation decisions must reconnect before merging.
- Durable manual people records with selected-face naming, distinct same-name IDs, explicit false-detection decisions, pair rejections and deferrals. Corrections and atomic undo validate the current photo/detector generation; People detail shows confirmed-photo counts and bounded preview context. Fictional runtime fixtures cover the manual workflow separately from model qualification.
- Read-only folder selection and recursive JPEG scanning with incremental previews, explicit progress, cancellation and local face detection states.
- Resume and incremental reconciliation with cached last-verified previews, cancellable integrity reads, source identity confirmation and durable stale-scan protection. Changed bytes invalidate face generations; unavailable folders retain the catalog, and missing photos are marked only after complete discovery. Saved folder permissions restore after cached catalog publication; deterministic interruption fixtures cover resumed scans.
- Bounded image decoding, protected transactional catalog/checkpoints and a backup-excluded 512 MiB preview cache.
- Adaptive Library, People, Verify and Search navigation with Settings, plus typed redacted diagnostics with bounded rotation and debug opt-in.
- iPadOS 17 app/core foundation and manifest-driven verification with synthetic source/recovery regressions, target-membership checks and ownership-safe simulator cleanup. Synthetic UI checks are separate from physical-device acceptance.
- Contracts for preserving originals, local sensitive data, human confirmation, truthful search and recoverable catalogs.

### Changed
- The simulator UI suite is cut from 92 tests to 10 end-to-end journeys that run at phase gates (the full phase6 gate now takes about 23 minutes instead of more than 75). 37 tests were removed because Core tests cover the same rule or they only checked layout; 45 App-session tests that have no unit-test home yet run only in the release-only `phase-release-ui` gate.
- Search updates its results as soon as you change the people or the mode; Refresh results is gone and pull to refresh re-runs the current search. The first search after opening the app still starts with Show photos.
- Verify shows the review card near the top: a one-line evaluation notice with details behind an info button, one control row for Suggestions, Find face details and Clear face details, and the counts below the card.
- Undo last decision is a toolbar button on People, Person and Verify instead of a full-width button in the content.
- Person shows the name once, with an Edit button to rename it; Confirmed faces is a plain heading.
- Photos open full screen. The caption shows the file name; the read-only note is behind an info button and the pixel size is no longer shown.
- A completed scan shows one completion label and the counts; the empty Library shows only the welcome card.
- At the largest text sizes the sidebar starts hidden on iPad, and person names in Search and the naming sheet wrap instead of being cut off.
- The catalog database now opens with full SQLite `secure_delete`, so deleted names and decisions are overwritten in the file instead of relying on the platform default.
- `tools/verify.sh` strips File Provider extended attributes from reused build products before building, so codesign no longer fails when the project lives in a synced Documents folder.
- `tools/verify.sh <phase> --headless` runs an accumulated phase's Core tests and iPad compile without the simulator UI suite; the full UI gate is reserved for release milestones.
- `tools/verify.sh` gives every Core test run a fresh runner-owned `synthetic-evidence/` directory as `AFITC_SYNTHETIC_DIAGNOSTIC_EVIDENCE`, preserving a caller-exported value, and records it in the run summary.
- Accumulated native gates retain both UI and runtime-unit cases, report their actual counts and stage durations, and use a 45-minute watchdog for phase 5 and a 75-minute watchdog for phase 6 with bounded cleanup.
- App-created macOS backup, validation and restore outputs use descriptor backup exclusion; iOS and live catalog protection retain Foundation. Strict source checks and immutable recovery evidence remain enforced. Full software integration is being verified; native UI and physical-device acceptance remain pending.
- Defined the MVP around one drive with nested folders, three confirmed-people search modes and visible resumable indexing; scene and language features remain outside the core MVP.
- Separated synthetic core checks and simulator compilation from native UI, physical compatibility and M4 performance acceptance.

### Fixed
- Native verification disables Xcode verbose post-test diagnostics to avoid simulator diagnosis stalls while retaining logs, XCTest attachments, strict test results and owned simulator cleanup.
- Checked catalog startup now lets SQLite recover supported hot journals after an interrupted write, including read-only file permissions, while preserving committed names and rechecking the restored schema before migration/publication. Unsupported versions identifiable before recovery remain unchanged.
- Analysis writes preserve valid temporarily missing photos and inspect only the admitted photo. Saved completion/group catch-up state now matches the pinned pipeline and source; checked existing opens reject unsupported versions identifiable before recovery without changing files. Restore regressions compare photo values and propagate crash-checkpoint errors while retaining strict kill witnesses.
- Scan activity, all-photos Search and photo-viewer status show their message once; root-level filenames no longer repeat as an identical path. Existing native journeys assert single status values and group preservation around photo viewing.
- Choosing a real photo folder on iPad no longer fails with "Folder access denied": folder access now uses the exact folder link the picker returned.
- Cleaning up a failed backup export now reopens access to the chosen folder, so the cleanup can succeed without a relaunch before privacy actions are available again.
- Restore leftovers that startup could not remove are now counted in the diagnostic log (count only, no names or paths).
- Deleting the local catalog now checks the whole catalog before erasing anything, and accepts the app’s own leftovers (an import folder after relaunch, previews left by restoring an older backup, interrupted backup or restore stages, temporary marker and preview files), so deletion no longer stops partway.
- Backup and restore stages left by an interrupted run are removed at the next launch instead of keeping catalog copies on disk.
- A photo whose original became oversized or unsafe while its preview was missing no longer keeps its earlier confirmed faces in search.
- Restore failures now report the original error even when closing the preparation also fails.
- Restored catalogs now reopen on iOS; the restored database was previously left read-only and the restore could not finish.
- Library scroll position no longer jumps while a scan adds photos.
- Protected-data and Settings status labels used by UI tests now update, so they no longer show stale values.
- Runtime inference rechecks parent cancellation and provenance after joined work completes, preventing stale results after a held completion callback.
- Folder-picker cancellation verification waits for the system Cancel control to appear and become actionable before testing the unchanged folder state.
- Switching sections from a person record returns to the selected section’s root in sidebar and compact navigation.
- Switching the regular-width sidebar section resets its navigation stack so pushed person detail cannot obscure Search. Synthetic Search regressions retain root/chip assertions and capture failures before unsafe array access.
- Native People workflow checks wait for naming to dismiss and reject empty, nonfinite or offscreen frames before requesting a control activation point.
- Compact Search verification locates floating navigation tabs by their stable identifier or label.
- Search snapshot concurrency verification observes an actual blocked SQLite commit, then successful commit after the pinned read releases; immutable counts and revisions remain coherent.
- Search preserves unavailable selected records until explicitly cleared, uses singular photo counts, and guards released viewer status from stale fallback errors. Synthetic cancellation checks now observe the held request finishing without publication. A separate synthetic decoder-error race checks that memory release remains visible after failed cache work completes.
- Bounded native UI reveal and People traversal loops stop checking once their target is visible, preserving scroll limits and workflow assertions.
- The accumulated Phase 3 native verification budget is 30 minutes following measured accessibility latency; other phases retain 20 minutes, with assertion waits and owned-process cleanup unchanged.
- Automatic People snapshots during a scan use exponentially spaced callbacks, with explicit final/user refreshes; cover lookup is indexed per render. Preview loading and release keep stable geometry, and passive UI status checks use visible frames rather than activation points.
- Scan updates coalesce People refreshes into bounded outstanding work. Saved decisions and merges close their forms even if the subsequent view refresh fails, with a separate retryable warning; cached Library recovery survives a people-only read failure. Rename undo synchronizes the editable name, and compact workflow checks scroll to visible status without extending timeouts.
- Face previews release decoded images when leaving the screen or receiving a memory warning, and discard cancelled or stale decode completions. Memory-release placeholders remain truthful.
- Valid photo previews remain available when face detection fails; analysis remains unresolved and failure counts stay explicit. Protected catalogs reject malformed empty payloads, and preview-cache bookkeeping avoids repeated full-directory scans.
- Native verification selects an installed iPad from an available runtime’s supported device types, preventing incompatible device/runtime pairs and comparing runtime versions numerically.
- A Vision face box that extends past the photo edge no longer blocks face analysis: the pipeline fence now keeps exactly the faces the catalog indexes, so a photo with any valid face completes and an all-edge-overflow photo records empty success instead of being reread on every scan.

No functional app release exists yet.

### Security
- Backup copies left in Caches by an interrupted restore check are now removed at the next launch; a check still in progress is never touched.
- Inspecting an untrusted backup now also checks for malformed database pages and avoids memory-mapped reads.
