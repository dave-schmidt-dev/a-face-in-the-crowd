import XCTest
import Darwin
@testable import AFITCCore

final class RestoreDurabilityTests: XCTestCase {
    private struct Fixture {
        let source: SearchFixture
        let package: PreparedCatalogBackup
        let root: URL
        let trace: DurabilityTrace
        let files: CatalogRestoreFiles
    }
    private func fixture(expectedDiagnostic: Bool = false, diagnostics: SourceRestoreReadDiagnostics? = nil, fault: @escaping @Sendable (RestoreFileEvent) -> Int32? = { _ in nil },
                         observer: @escaping @Sendable (RestoreFileEvent) throws -> Void = { _ in }) async throws -> Fixture {
        let f = try await SearchFixture.make(self)
        _ = try await f.photo("fictional.jpg", [f.people[0]])
        let package = try await f.catalog.prepareBackup()
        let root = f.root.appendingPathComponent("restore-files")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let trace = DurabilityTrace()
        let files = try CatalogRestoreFiles(root: root, observer: { value in
            trace.append(value)
            if value.changedFields != 0 && !expectedDiagnostic { XCTFail("Unexpected stability mask role=\(value.role.rawValue) fields=\(value.changedFields)") }
            try observer(value)
        }, fault: fault, readDiagnostics: diagnostics)
        return Fixture(source: f, package: package, root: root, trace: trace, files: files)
    }
    private func prepared(_ f: Fixture) async throws -> (RestoreFileStage, RestoreMarker) {
        let stage = try await f.files.createStage()
        let old = try await f.files.copyPackage(from: f.package.directory, manifest: f.package.manifest, into: stage, slot: .old)
        let new = try await f.files.copyPackage(from: f.package.directory, manifest: f.package.manifest, into: stage, slot: .new)
        try await f.files.prepareInstallation(stage, new: new)
        return (stage, RestoreMarker(version: 1, transaction: stage.transaction, state: .prepared, old: old, new: new))
    }
    private func exportReadDiagnostics(_ diagnostics: SourceRestoreReadDiagnostics, _ selector: String) {
        guard let path = ProcessInfo.processInfo.environment["AFITC_SYNTHETIC_DIAGNOSTIC_EVIDENCE"] else { return }
        do {
            let data = try JSONEncoder().encode(diagnostics.snapshot())
            try data.write(to: URL(fileURLWithPath: path).appendingPathComponent(selector + ".json"))
        } catch { XCTFail("bounded synthetic diagnostic export failed") }
    }
    func testReadDiagnosticsKnownChmodRejectsUnchangedMarkerBytes() async throws {
        let diagnostics = SourceRestoreReadDiagnostics(), mutation = MarkerModeMutation()
        defer { exportReadDiagnostics(diagnostics, "testReadDiagnosticsKnownChmodRejectsUnchangedMarkerBytes") }
        let f = try await fixture(expectedDiagnostic: true, diagnostics: diagnostics, observer: { event in
            if event.role == .marker && event.operation == .read && event.moment == .before { try mutation.applyOnce() }
        })
        let (stage, marker) = try await prepared(f); try await f.files.publish(marker, stage: stage)
        let file = f.root.appendingPathComponent("restore-marker.json"), before = try Data(contentsOf: file)
        mutation.set(file)
        do { _ = try await f.files.readMarker(); XCTFail("known chmod admitted") } catch { XCTAssertEqual(error as? RestoreFileError, .changedSource) }
        XCTAssertTrue(mutation.applied); XCTAssertEqual(try Data(contentsOf: file), before)
        let trace = diagnostics.snapshot(); XCTAssertEqual(trace.dropped, 0)
        let beforeRead = try XCTUnwrap(trace.events.first { $0.role == .marker && $0.boundary == .beforeReadObserver })
        let afterCallback = try XCTUnwrap(trace.events.first { $0.readID == beforeRead.readID && $0.boundary == .beforeReadSyscall })
        let a = try XCTUnwrap(beforeRead.descriptor.fields), b = try XCTUnwrap(afterCallback.descriptor.fields)
        XCTAssertEqual(a.device, b.device); XCTAssertEqual(a.inode, b.inode); XCTAssertEqual(a.size, b.size)
        XCTAssertNotEqual(a.mode, b.mode); XCTAssertTrue(a.ctimeSeconds != b.ctimeSeconds || a.ctimeNanoseconds != b.ctimeNanoseconds)
        XCTAssertEqual(afterCallback.path.fields, b)
    }
    func testReadDiagnosticsRetainsActualFailedStatErrnoWithoutRetry() async throws {
        let diagnostics = SourceRestoreReadDiagnostics(), mutation = MarkerUnlinkMutation()
        defer { exportReadDiagnostics(diagnostics, "testReadDiagnosticsRetainsActualFailedStatErrnoWithoutRetry") }
        let f = try await fixture(expectedDiagnostic: true, diagnostics: diagnostics, observer: { event in
            if event.role == .marker && event.operation == .read && event.moment == .after { try mutation.applyOnce() }
        })
        let (stage, marker) = try await prepared(f); try await f.files.publish(marker, stage: stage)
        mutation.set(f.root.appendingPathComponent("restore-marker.json"))
        do { _ = try await f.files.readMarker(); XCTFail("unlinked marker admitted") } catch { XCTAssertEqual(error as? RestoreFileError, .changedSource) }
        XCTAssertTrue(mutation.applied)
        let event = try XCTUnwrap(diagnostics.snapshot().events.last { $0.role == .marker && $0.boundary == .finalGuard })
        XCTAssertEqual(event.path.status, -1); XCTAssertEqual(event.path.error, ENOENT); XCTAssertNil(event.path.fields)
        XCTAssertEqual(event.descriptor.status, 0); XCTAssertEqual(event.descriptor.fields?.links, 0)
        XCTAssertNotNil(event.guardBaseline); XCTAssertEqual(diagnostics.snapshot().dropped, 0)
        // A real EBADF observation must remain failed even when the sampler receives a valid FD.
        var info = stat(); let failure = fstat(-1, &info); let capturedError = errno
        let fd = open(f.package.directory.appendingPathComponent("catalog.sqlite").path, O_RDONLY | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd, 0); guard fd >= 0 else { return }; defer { Darwin.close(fd) }
        errno = EDOM
        diagnostics.sample(diagnostics.nextReadID(), origin: .files, role: .catalog, boundary: .finalGuard, fd: fd,
            descriptorResult: .init(info, status: failure, error: capturedError),
            pathResult: .init(status: -1, error: ENOENT, fields: nil))
        XCTAssertEqual(errno, EDOM)
        let failed = try XCTUnwrap(diagnostics.snapshot().events.last)
        XCTAssertEqual(failed.descriptor.status, -1); XCTAssertEqual(failed.descriptor.error, EBADF); XCTAssertNil(failed.descriptor.fields)
        XCTAssertEqual(failed.path.error, ENOENT)
    }
    func testMarkerAdoptedRecoveryTemporaryRequiresExactOwnedPrefix() async throws {
        for kind in ["zero", "partial", "complete", "extra", "malformed", "symlink", "hardlink", "directory", "wrongBytes", "oversized", "second"] {
            let f = try await fixture(); let (stage, marker) = try await prepared(f)
            try await f.files.publish(marker, stage: stage)
            let folder = f.root.appendingPathComponent(stage.name)
            let name = kind == "extra" ? "foreign.sqlite" : kind == "malformed" ? "recover-not-a-uuid.sqlite" : "recover-" + UUID().uuidString + ".sqlite"
            let file = folder.appendingPathComponent(name)
            let bytes = try Data(contentsOf: f.package.directory.appendingPathComponent("catalog.sqlite"))
            let oldBytes = try Data(contentsOf: folder.appendingPathComponent("old/catalog.sqlite"))
            let newBytes = try Data(contentsOf: folder.appendingPathComponent("new/catalog.sqlite"))
            if kind == "symlink" { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: f.package.directory.appendingPathComponent("catalog.sqlite")) }
            else if kind == "hardlink" { try FileManager.default.linkItem(at: f.package.directory.appendingPathComponent("catalog.sqlite"), to: file) }
            else if kind == "directory" { try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false) }
            else {
                let content = kind == "zero" ? Data() : kind == "complete" ? bytes : kind == "wrongBytes" ? Data([0xff,0xff,0xff]) : kind == "oversized" ? bytes + Data([1]) : Data(bytes.prefix(1024))
                try content.write(to: file)
            }
            if kind == "second" { try Data().write(to: folder.appendingPathComponent("recover-" + UUID().uuidString + ".sqlite")) }
            let restarted = try CatalogRestoreFiles(root: f.root)
            if ["zero", "partial", "complete"].contains(kind) {
                let pending = try await restarted.retainedStage(); let adopted = try XCTUnwrap(pending)
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
                try await restarted.recoverInstallation(adopted.0, marker: adopted.1)
                try await restarted.finishMarkerRemoval(adopted.0, marker: adopted.1); try await restarted.discard(adopted.0)
            } else {
                do { _ = try await restarted.retainedStage(); XCTFail("hostile recovery temp admitted: \(kind)") } catch { }
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
                XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("restore-marker.json")), try marker.encoded())
                XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("old/catalog.sqlite")), oldBytes)
                XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("new/catalog.sqlite")), newBytes)
            }
        }
    }
    func testRecoveryTemporaryNeverDeletedWithoutValidatedMarkerAuthority() async throws {
        for malformed in [false, true] {
            let f = try await fixture(); let (stage, marker) = try await prepared(f)
            let file = f.root.appendingPathComponent(stage.name + "/recover-" + UUID().uuidString + ".sqlite")
            let bytes = Data((try Data(contentsOf: f.package.directory.appendingPathComponent("catalog.sqlite"))).prefix(128))
            try bytes.write(to: file)
            if malformed { try Data("invalid marker".utf8).write(to: f.root.appendingPathComponent("restore-marker.json")) }
            let fresh = try CatalogRestoreFiles(root: f.root)
            if malformed { do { _ = try await fresh.retainedStage(); XCTFail("invalid marker admitted") } catch { } }
            else { let pending = try await fresh.retainedStage(); XCTAssertNil(pending) }
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(stage.name + "/old/catalog.sqlite")), try Data(contentsOf: f.package.directory.appendingPathComponent("catalog.sqlite")))
            XCTAssertEqual(marker.state, .prepared)
        }
    }
    func testRecoveryTemporaryCleanupInterruptionRetainsMarkerAndRetriesIdempotently() async throws {
        for operation in [RestoreFileOperation.unlink, .directorySync] {
            let f = try await fixture(); let (stage, marker) = try await prepared(f)
            try await f.files.publish(marker, stage: stage)
            let file = f.root.appendingPathComponent(stage.name + "/recover-" + UUID().uuidString + ".sqlite")
            try Data((try Data(contentsOf: f.package.directory.appendingPathComponent("catalog.sqlite"))).prefix(128)).write(to: file)
            let restarted = try CatalogRestoreFiles(root: f.root, observer: { event in
                if event.operation == operation && event.role == (operation == .unlink ? .install : .stage) && event.moment == .after { throw RestoreFileError.syscall(EIO) }
            })
            do { _ = try await restarted.retainedStage(); XCTFail("cleanup fault ignored") } catch { XCTAssertEqual(error as? RestoreFileError, .syscall(EIO)) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("restore-marker.json").path))
            let fresh = try CatalogRestoreFiles(root: f.root)
            let pending = try await fresh.retainedStage(); let adopted = try XCTUnwrap(pending)
            try await fresh.recoverInstallation(adopted.0, marker: adopted.1)
            try await fresh.finishMarkerRemoval(adopted.0, marker: adopted.1); try await fresh.discard(adopted.0)
            XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("catalog.sqlite")), try Data(contentsOf: f.package.directory.appendingPathComponent("catalog.sqlite")))
        }
    }
    func testActualProtectedCopiesSyncAncestorsAndCanonicalMarkerOrdering() async throws {
        let f = try await fixture(); let (stage, marker) = try await prepared(f)
        do { _ = try await f.files.createStage(transaction: stage.transaction); XCTFail("collidingstage succeeded") }
        catch { XCTAssertEqual(error as? RestoreFileError, .syscall(EEXIST)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(stage.name + "/old/catalog.sqlite").path))
        let source = try Data(contentsOf: f.package.directory.appendingPathComponent("catalog.sqlite"))
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(stage.name + "/new/catalog.sqlite")), source)
        for slot in ["old", "new"] {
            for name in ["manifest.json", "catalog.sqlite"] {
                let file = f.root.appendingPathComponent(stage.name + "/" + slot + "/" + name)
                XCTAssertTrue(try CatalogRepository.excludedFromBackup(file))
                XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o400)
            }
        }
        XCTAssertEqual(try RestoreMarker.decode(marker.encoded()), marker)
        try await f.files.publish(marker, stage: stage)
        let read = try await f.files.readMarker(); XCTAssertEqual(read, marker)
        let events = f.trace.values()
        let rename = try XCTUnwrap(events.firstIndex { $0.operation == .rename && $0.role == .marker && $0.moment == .after })
        XCTAssertTrue(events[..<rename].contains { $0.operation == .fileSync && $0.role == .marker && $0.moment == .after })
        XCTAssertTrue(events[(rename+1)...].contains { $0.operation == .directorySync && $0.role == .root && $0.moment == .after })
        XCTAssertTrue(events[..<rename].contains { $0.operation == .directorySync && $0.role == .ancestor && $0.moment == .after })
        do { try await f.files.discard(stage); XCTFail("referenced snapshot discarded") } catch { XCTAssertEqual(error as? RestoreFileError, .markerPresent) }
        try await f.files.removeMarker(stage); try await f.files.discard(stage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(stage.name).path))
        let final = f.trace.values()
        let unlinkMarker = try XCTUnwrap(final.firstIndex { $0.operation == .unlink && $0.role == .marker && $0.moment == .after })
        let garbage = try XCTUnwrap(final.firstIndex { $0.operation == .unlink && $0.role == .old && $0.moment == .before })
        XCTAssertTrue(final[(unlinkMarker+1)..<garbage].contains { $0.operation == .directorySync && $0.role == .root && $0.moment == .after })
    }
    func testAtomicReplaceNeverUnlinksExistingDestinationAndSyncsBothParents() async throws {
        try await MarkerDomainTrialContext.original(owner: self, scenario: "AtomicReplace") { try await Self.runDomainAtomic($0) }
    }
    static func runDomainAtomic(_ context: MarkerDomainTrialContext) async throws {
        let source = try await context.make("atomic")
        _ = try await source.photo("fictional.jpg", [source.people[0]])
        let package = try await source.catalog.prepareBackup(progress: { _ in }, options: BackupOptions(), ownedProtection: context.ownedProtection), root = source.root.appendingPathComponent("restore-files")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let trace = DurabilityTrace()
        let files = try context.files(root, observer: { event in
            trace.append(event)
            if !context.comparison && event.changedFields != 0 { context.fail("Unexpected stability mask role=\(event.role.rawValue) fields=\(event.changedFields)") }
        })
        let f = Fixture(source: source, package: package, root: root, trace: trace, files: files)
        let stage = try await files.createStage()
        let old = try await files.copyPackage(from: package.directory, manifest: package.manifest, into: stage, slot: .old)
        let new = try await files.copyPackage(from: package.directory, manifest: package.manifest, into: stage, slot: .new)
        try await files.prepareInstallation(stage, new: new)
        let marker = RestoreMarker(version: 1, transaction: stage.transaction, state: .prepared, old: old, new: new)
        let live = f.root.appendingPathComponent("catalog.sqlite"); try Data("original".utf8).write(to: live)
        try await f.files.publish(marker, stage: stage)
        f.trace.clear(); try await f.files.replaceInstallation(stage, new: marker.new)
        try context.equal(try Data(contentsOf: live), try Data(contentsOf: f.package.directory.appendingPathComponent("catalog.sqlite")))
        let events = f.trace.values()
        try context.isFalse(events.contains { $0.operation == .unlink })
        let rename = try context.unwrap(events.firstIndex { $0.operation == .rename && $0.role == .install && $0.moment == .after })
        try context.isTrue(events[(rename+1)...].contains { $0.operation == .directorySync && $0.role == .stage && $0.moment == .after })
        try context.isTrue(events[(rename+1)...].contains { $0.operation == .directorySync && $0.role == .root && $0.moment == .after })
        let committed = RestoreMarker(version: 1, transaction: marker.transaction, state: .committed, old: marker.old, new: marker.new)
        try await f.files.publish(committed, stage: stage)
        let read = try await f.files.readMarker(); try context.equal(read, committed)
        try await f.files.removeMarker(stage); try await f.files.discard(stage)

    }
    func testInjectedCopySyncAndCrossDeviceFailuresPreserveLiveAndPermitOwnedCleanup() async throws {
        for (operation, role, code) in [(RestoreFileOperation.write, RestoreFileRole.old, ENOSPC), (.fileSync,.new,EIO), (.directorySync,.ancestor,EINVAL), (.protect,.old,EACCES)] {
            let f = try await fixture(fault: { $0.operation == operation && $0.role == role ? code : nil })
            var stage: RestoreFileStage?
            do {
                stage = try await f.files.createStage()
                _ = try await f.files.copyPackage(from: f.package.directory, manifest: f.package.manifest, into: stage!, slot: role == .new ? .new : .old)
                XCTFail("injected failure succeeded")
            } catch { XCTAssertEqual(error as? RestoreFileError, .syscall(code)) }
            if let stage { try await f.files.discard(stage) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.path), [])
            let rows = try await f.source.query(.any, [f.source.people[0]]); XCTAssertEqual(rows.totalCount, 1)
        }
        let switcher = FaultSwitch()
        let f = try await fixture(fault: { switcher.matches($0) ? EXDEV : nil })
        let (stage, marker) = try await prepared(f)
        let live = f.root.appendingPathComponent("catalog.sqlite"); let before = Data("old".utf8); try before.write(to: live)
        try await f.files.publish(marker, stage: stage); switcher.set(.rename, .install)
        do { try await f.files.replaceInstallation(stage, new: marker.new); XCTFail("EXDEV succeeded") } catch { XCTAssertEqual(error as? RestoreFileError, .syscall(EXDEV), "stability diagnostics: \(f.trace.values().map { $0.changedFields }.filter { $0 != 0 })") }
        XCTAssertEqual(try Data(contentsOf: live), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(stage.name + "/old/catalog.sqlite").path))
        switcher.clear(); try await f.files.removeMarker(stage); try await f.files.discard(stage)
    }
    func testMarkerRenameAndParentSyncErrorsRetainRequiredSnapshots() async throws {
        let toggle = FaultSwitch(); let f = try await fixture(fault: { toggle.matches($0) ? EIO : nil })
        let (stage, marker) = try await prepared(f)
        toggle.set(.rename, .marker)
        do { try await f.files.publish(marker, stage: stage); XCTFail("rename fault succeeded") } catch { XCTAssertEqual(error as? RestoreFileError, .syscall(EIO)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("restore-marker.json").path))
        toggle.clear(); toggle.set(.directorySync, .root)
        do { try await f.files.publish(marker, stage: stage); XCTFail("parent sync fault succeeded") } catch { XCTAssertEqual(error as? RestoreFileError, .syscall(EIO)) }
        toggle.clear()
        let read = try await f.files.readMarker(); XCTAssertEqual(read, marker)
        do { try await f.files.discard(stage); XCTFail("postrename evidence discarded") } catch { XCTAssertEqual(error as? RestoreFileError, .markerPresent) }
        toggle.set(.directorySync, .root)
        do { try await f.files.removeMarker(stage); XCTFail("marker removal sync fault succeeded") } catch { XCTAssertEqual(error as? RestoreFileError, .syscall(EIO)) }
        toggle.clear()
        do { try await f.files.discard(stage); XCTFail("ambiguous removal evidence discarded") } catch { XCTAssertEqual(error as? RestoreFileError, .markerPresent) }
        // Republish retained metadata to resolve durable ambiguity before explicit cleanup.
        try await f.files.publish(marker, stage: stage); try await f.files.removeMarker(stage); try await f.files.discard(stage)
    }
    func testStrictMarkerAndMissingChangedEvidenceFailClosedAcrossNewHelper() async throws {
        let diagnostics = SourceRestoreReadDiagnostics(); defer { exportReadDiagnostics(diagnostics, "testStrictMarkerAndMissingChangedEvidenceFailClosedAcrossNewHelper") }
        let f = try await fixture(diagnostics: diagnostics); let (stage, marker) = try await prepared(f)
        let bytes = try marker.encoded()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any]); object["extra"] = true
        XCTAssertThrowsError(try RestoreMarker.decode(JSONSerialization.data(withJSONObject: object, options: .sortedKeys)))
        XCTAssertThrowsError(try RestoreMarker.decode(Data(bytes.dropLast())))
        XCTAssertThrowsError(try RestoreMarker.decode(Data(repeating: 32, count: RestoreMarker.maximumBytes + 1)))
        var path = try XCTUnwrap(object["old"] as? [String: Any]); path["path"] = "../escape"; object.removeValue(forKey: "extra"); object["old"] = path
        XCTAssertThrowsError(try RestoreMarker.decode(JSONSerialization.data(withJSONObject: object, options: .sortedKeys)))
        try await f.files.publish(marker, stage: stage)
        let restarted = try CatalogRestoreFiles(root: f.root, readDiagnostics: diagnostics)
        let pending = try await restarted.retainedStage(); let adopted = try XCTUnwrap(pending)
        XCTAssertEqual(adopted.1, marker)
        do { try await restarted.discard(adopted.0); XCTFail("restart deleted required evidence") } catch { XCTAssertEqual(error as? RestoreFileError, .markerPresent) }
        let file = f.root.appendingPathComponent(stage.name + "/new/catalog.sqlite")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try Data([1,2,3]).write(to: file)
        do { _ = try await restarted.readMarker(); XCTFail("corrupt snapshot admitted") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("restore-marker.json").path))
    }
    func testUnsafeEntriesSymlinksHardlinksAndMissingInstallationReject() async throws {
        let f = try await fixture()
        for kind in ["extra", "symlink", "hardlink", "missing"] {
            let source = f.source.root.appendingPathComponent("attack-" + kind)
            try FileManager.default.copyItem(at: f.package.directory, to: source)
            let file = source.appendingPathComponent("catalog.sqlite")
            if kind == "extra" { try Data([1]).write(to: source.appendingPathComponent("catalog.sqlite-wal")) }
            else {
                try FileManager.default.removeItem(at: file)
                if kind == "symlink" { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: f.package.directory.appendingPathComponent("catalog.sqlite")) }
                if kind == "hardlink" { try FileManager.default.linkItem(at: f.package.directory.appendingPathComponent("catalog.sqlite"), to: file) }
            }
            let stage = try await f.files.createStage()
            do { _ = try await f.files.copyPackage(from: source, manifest: f.package.manifest, into: stage, slot: .old); XCTFail("unsafe copy succeeded") } catch { }
            try await f.files.discard(stage); try FileManager.default.removeItem(at: source)
        }
        let stage = try await f.files.createStage()
        let old = try await f.files.copyPackage(from: f.package.directory, manifest: f.package.manifest, into: stage, slot: .old)
        let new = try await f.files.copyPackage(from: f.package.directory, manifest: f.package.manifest, into: stage, slot: .new)
        let marker = RestoreMarker(version: 1, transaction: stage.transaction, state: .prepared, old: old, new: new)
        do { try await f.files.publish(marker, stage: stage); XCTFail("marker withoutinstall succeeded") } catch { }
        try await f.files.discard(stage)
        let other = try CatalogRestoreFiles(root: f.root); let foreign = try await f.files.createStage()
        do { try await other.discard(foreign); XCTFail("foreign stage discarded") } catch { XCTAssertEqual(error as? RestoreFileError, .foreignStage) }
        try await f.files.discard(foreign)
    }
    func testMetadataOnlyMutationReportsStatDifferenceWithoutChangingBytes() async throws {
        let mutation = MetadataMutation()
        let f = try await fixture(expectedDiagnostic: true, observer: { event in
            if event.operation == .read && event.role == .old && event.moment == .after { try mutation.applyOnce() }
        })
        let source = f.package.directory.appendingPathComponent("manifest.json")
        let original = try Data(contentsOf: source)
        mutation.set(source)
        let stage = try await f.files.createStage()
        do {
            _ = try await f.files.copyPackage(from: f.package.directory, manifest: f.package.manifest, into: stage, slot: .old)
            XCTFail("metadata revision change accepted")
        } catch { XCTAssertEqual(error as? RestoreFileError, .changedSource) }
        XCTAssertEqual(try Data(contentsOf: source), original)
        let diagnostics = f.trace.values().filter { $0.changedFields != 0 }
        XCTAssertEqual(diagnostics.count, 1)
        let fields = try XCTUnwrap(diagnostics.first).changedFields
        XCTAssertNotEqual(fields & ((1 << 6) | (1 << 11)), 0) // observed FD/path mtime change
        XCTAssertEqual(fields & (1 | (1 << 3) | (1 << 4) | (1 << 8) | (1 << 9)), 0) // bytes/identity/size unchanged
        try await f.files.discard(stage)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.path), [])
        let query = try await f.source.query(.only, [f.source.people[0]]); XCTAssertEqual(query.totalCount, 1)
    }
    func testParentMetadataMutationRejectsWithSourceParentMask() async throws {
        let mutation = MetadataMutation()
        let f = try await fixture(expectedDiagnostic: true, observer: { event in
            if event.operation == .read && event.role == .old && event.moment == .after { try mutation.applyOnce() }
        })
        mutation.set(f.package.directory)
        let bytes = try Data(contentsOf: f.package.directory.appendingPathComponent("catalog.sqlite"))
        let stage = try await f.files.createStage()
        do { _ = try await f.files.copyPackage(from: f.package.directory, manifest: f.package.manifest, into: stage, slot: .old); XCTFail("parent mutation accepted") }
        catch { XCTAssertEqual(error as? RestoreFileError, .changedSource) }
        let event = try XCTUnwrap(f.trace.values().last { $0.changedFields != 0 })
        XCTAssertEqual(event.role, .sourceParent); XCTAssertNotEqual(event.changedFields & (1 << 6), 0)
        XCTAssertEqual(event.changedFields & (1|2|4|(1 << 3)|(1 << 4)|(1 << 5)|(1 << 13)), 0)
        XCTAssertEqual(try Data(contentsOf: f.package.directory.appendingPathComponent("catalog.sqlite")), bytes)
        try await f.files.discard(stage)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.path), [])
    }
    func testAfterRenameObserverFailureFirstReadMetadataDiagnostic() async throws {
        let diagnostic = MarkerStatDiagnostic(), stop = FaultSwitch()
        let f = try await fixture(expectedDiagnostic: true, observer: { event in
            if event.role == .marker { diagnostic.capture("helper-\(event.operation.rawValue)-\(event.moment)") }
            if stop.matches(event) && event.moment == .after { throw RestoreFileError.syscall(EIO) }
        })
        let (stage, marker) = try await prepared(f)
        diagnostic.set(f.root.appendingPathComponent("restore-marker.json"))
        stop.set(.rename, .marker)
        do { try await f.files.publish(marker, stage: stage); XCTFail("afterrename injection ignored") }
        catch { XCTAssertEqual(error as? RestoreFileError, .syscall(EIO)) }
        stop.clear(); diagnostic.capture("helper-prior-first-read")
        do {
            let read = try await f.files.readMarker(); XCTAssertEqual(read, marker)
            print("SYNTHETIC_MARKER_OUTCOME helper-first-read=accepted")
        } catch {
            XCTAssertEqual(error as? RestoreFileError, .changedSource)
            let event = try XCTUnwrap(f.trace.values().last { $0.changedFields != 0 })
            print("SYNTHETIC_MARKER_OUTCOME helper-first-read=rejected role=\(event.role.rawValue) fields=\(event.changedFields)")
        }
        diagnostic.capture("helper-after-first-read")
        // Preserve the real published marker and retained evidence before fixture teardown.
        if let evidence = ProcessInfo.processInfo.environment["AFITC_SYNTHETIC_DIAGNOSTIC_EVIDENCE"] {
            let target = URL(fileURLWithPath: evidence).appendingPathComponent("helper-retained-stage")
            try FileManager.default.copyItem(at: f.root, to: target)
        }
        for syncParent in [false, true] {
            let root = f.source.root.appendingPathComponent(syncParent ? "raw-synced" : "raw-unsynced")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let temporary = root.appendingPathComponent("temporary"), named = root.appendingPathComponent("marker")
            let bytes = try marker.encoded()
            XCTAssertTrue(FileManager.default.createFile(atPath: temporary.path, contents: Data()))
            let trace = MarkerStatDiagnostic(); trace.set(temporary); trace.capture("raw-created")
            try CatalogRepository.protect(temporary); trace.capture("raw-protected")
            let writer = open(temporary.path, O_WRONLY | O_NOFOLLOW); XCTAssertGreaterThanOrEqual(writer, 0)
            XCTAssertEqual(bytes.withUnsafeBytes { Darwin.write(writer, $0.baseAddress, $0.count) }, bytes.count)
            trace.capture("raw-written", fd: writer); XCTAssertEqual(fsync(writer), 0); trace.capture("raw-file-synced", fd: writer)
            XCTAssertEqual(Darwin.close(writer), 0); trace.capture("raw-writer-closed")
            XCTAssertEqual(rename(temporary.path, named.path), 0); trace.set(named, retainBaseline: true); trace.capture("raw-renamed")
            if syncParent {
                let parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW); XCTAssertGreaterThanOrEqual(parent, 0)
                XCTAssertEqual(fsync(parent), 0); XCTAssertEqual(Darwin.close(parent), 0); trace.capture("raw-parent-synced")
            }
            let reader = open(named.path, O_RDONLY | O_NOFOLLOW); XCTAssertGreaterThanOrEqual(reader, 0)
            trace.capture("raw-reader-opened", fd: reader)
            var buffer = [UInt8](repeating: 0, count: bytes.count + 1)
            XCTAssertEqual(buffer.withUnsafeMutableBytes { Darwin.read(reader, $0.baseAddress, $0.count) }, bytes.count)
            trace.capture("raw-read", fd: reader)
            XCTAssertEqual(buffer.withUnsafeMutableBytes { Darwin.read(reader, $0.baseAddress, $0.count) }, 0)
            trace.capture("raw-eof", fd: reader); XCTAssertEqual(Darwin.close(reader), 0); trace.capture("raw-reader-closed")
            XCTAssertEqual(try Data(contentsOf: named), bytes)
            print("SYNTHETIC_MARKER_PROTOCOL parentSynced=\(syncParent)")
        }
    }
    func testActualCopyCancellationAndAfterRenameObserverKeepOwnershipTruthful() async throws {
        let f = try await fixture(observer: { event in
            if event.operation == .read && event.role == .old && event.moment == .after { withUnsafeCurrentTask { $0?.cancel() } }
        })
        let stage = try await f.files.createStage()
        let task = Task { try await f.files.copyPackage(from: f.package.directory, manifest: f.package.manifest, into: stage, slot: .old) }
        do { _ = try await task.value; XCTFail("cancellation ignored") } catch { XCTAssertTrue(error is CancellationError) }
        try await f.files.discard(stage)
        let stop = FaultSwitch()
        let g = try await fixture(observer: { event in if stop.matches(event) && event.moment == .after { throw RestoreFileError.syscall(EIO) } })
        let (otherStage, marker) = try await prepared(g)
        stop.set(.open, .marker)
        do { try await g.files.publish(marker, stage: otherStage); XCTFail("open observer stop ignored") } catch { XCTAssertEqual(error as? RestoreFileError, .syscall(EIO)) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: g.root.path), [otherStage.name])
        stop.set(.rename, .marker)
        do { try await g.files.publish(marker, stage: otherStage); XCTFail("observer stop ignored") } catch { XCTAssertEqual(error as? RestoreFileError, .syscall(EIO)) }
        stop.clear()
        do { try await g.files.discard(otherStage); XCTFail("afterrename stage lost retention") } catch { XCTAssertEqual(error as? RestoreFileError, .markerPresent) }
        try await g.files.removeMarker(otherStage); try await g.files.discard(otherStage)
    }
}
private final class DurabilityTrace: @unchecked Sendable {
    private let lock = NSLock(); private var events: [RestoreFileEvent] = []
    func append(_ value: RestoreFileEvent) { lock.lock(); defer { lock.unlock() }; events.append(value) }
    func values() -> [RestoreFileEvent] { lock.lock(); defer { lock.unlock() }; return events }
    func clear() { lock.lock(); defer { lock.unlock() }; events.removeAll() }
}
private final class FaultSwitch: @unchecked Sendable {
    private let lock = NSLock(); private var target: (RestoreFileOperation, RestoreFileRole)?
    func set(_ operation: RestoreFileOperation, _ role: RestoreFileRole) { lock.lock(); defer { lock.unlock() }; target = (operation,role) }
    func clear() { lock.lock(); defer { lock.unlock() }; target = nil }
    func matches(_ event: RestoreFileEvent) -> Bool { lock.lock(); defer { lock.unlock() }; return target.map { $0.0 == event.operation && $0.1 == event.role } ?? false }
}

private final class MetadataMutation: @unchecked Sendable {
    private let lock = NSLock(); private var source: URL?
    func set(_ source: URL) { lock.lock(); defer { lock.unlock() }; self.source = source }
    func applyOnce() throws {
        lock.lock(); defer { lock.unlock() }; guard let source else { return }; self.source = nil
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let before = try XCTUnwrap(attributes[.modificationDate] as? Date)
        try FileManager.default.setAttributes([.modificationDate: before.addingTimeInterval(60)], ofItemAtPath: source.path)
    }
}

/// Synthetic-only syscall observations. Logs fixed phase names and changed-field bits, not values or paths.
private final class MarkerStatDiagnostic: @unchecked Sendable {
    private let lock = NSLock(); private var path: URL?; private var previous: stat?
    func set(_ path: URL, retainBaseline: Bool = false) { lock.lock(); defer { lock.unlock() }; self.path = path; if !retainBaseline { previous = nil } }
    func capture(_ phase: String, fd: Int32? = nil) {
        lock.lock(); defer { lock.unlock() }; guard let path else { return }
        var value = stat(); let status = fd.map { fstat($0, &value) } ?? lstat(path.path, &value)
        guard status == 0 else { print("SYNTHETIC_MARKER_STAT phase=\(phase) statError=\(errno)"); return }
        var mask: UInt16 = 0
        if let before = previous {
            if before.st_dev != value.st_dev || before.st_ino != value.st_ino { mask |= 1 }
            if before.st_size != value.st_size { mask |= 2 }
            if before.st_nlink != value.st_nlink { mask |= 4 }
            if before.st_mtimespec.tv_sec != value.st_mtimespec.tv_sec || before.st_mtimespec.tv_nsec != value.st_mtimespec.tv_nsec { mask |= 8 }
            if before.st_ctimespec.tv_sec != value.st_ctimespec.tv_sec || before.st_ctimespec.tv_nsec != value.st_ctimespec.tv_nsec { mask |= 16 }
        }
        previous = value; print("SYNTHETIC_MARKER_STAT phase=\(phase) fields=\(mask) descriptor=\(fd != nil)")
    }
}

private final class MarkerModeMutation: @unchecked Sendable {
    private let lock = NSLock(); private var file: URL?; private var didApply = false
    var applied: Bool { lock.lock(); defer { lock.unlock() }; return didApply }
    func set(_ file: URL) { lock.lock(); defer { lock.unlock() }; self.file = file }
    func applyOnce() throws {
        lock.lock(); defer { lock.unlock() }; guard let file else { return }; self.file = nil
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { throw RestoreFileError.syscall(errno) }
        var closed = false; defer { if !closed { Darwin.close(fd) } }; var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              fchmod(fd, (info.st_mode & 0o777) ^ 0o200) == 0 else { throw RestoreFileError.unsafeEntry }
        guard Darwin.close(fd) == 0 else { throw RestoreFileError.syscall(errno) }; closed = true; didApply = true
    }
}

private final class MarkerUnlinkMutation: @unchecked Sendable {
    private let lock = NSLock(); private var file: URL?; private var didApply = false
    var applied: Bool { lock.lock(); defer { lock.unlock() }; return didApply }
    func set(_ file: URL) { lock.lock(); defer { lock.unlock() }; self.file = file }
    func applyOnce() throws {
        lock.lock(); defer { lock.unlock() }; guard let file else { return }; self.file = nil
        guard unlink(file.path) == 0 else { throw RestoreFileError.syscall(errno) }; didApply = true
    }
}
