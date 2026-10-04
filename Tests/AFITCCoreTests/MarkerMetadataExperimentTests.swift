import XCTest
import Foundation
import Darwin
import CryptoKit
@testable import AFITCCore

/// Low-level synthetic filesystem experiment; the snapshot bytes are not a SQLite catalog.
final class MarkerMetadataExperimentTests: XCTestCase {
    private struct Trial: Codable {
        let id: UUID
        let block: Int
        let arm: RestoreMarkerProtection
        let originalStatsOnly: Bool
        let control: Bool
        var mechanism: String?
        var phase = "registered"
        var outcome = "unobserved"
        var classification = "unobserved"
        var error: String?
        var changedMasks: [UInt16] = []
        var addedStatCalls = 0
        var preserved = false
        var originalRemoved = false
        var trace: SourceRestoreReadDiagnostics.Trace?
    }
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0; private var masks: [UInt16] = []; private var mutated = false
        let marker: URL
        let control: Bool
        init(marker: URL, control: Bool) { self.marker = marker; self.control = control }
        func statCall() { lock.lock(); calls += 1; lock.unlock() }
        func event(_ event: RestoreFileEvent) throws {
            lock.lock(); defer { lock.unlock() }
            if event.changedFields != 0 { masks.append(event.changedFields) }
            if control && !mutated && event.role == .marker && event.operation == .read && event.moment == .before {
                guard chmod(marker.path, 0o400) == 0 else { throw RestoreFileError.syscall(errno) }
                mutated = true
            }
        }
        func values() -> (Int, [UInt16], Bool) { lock.lock(); defer { lock.unlock() }; return (calls, masks, mutated) }
    }
    private func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    private func package(_ stage: RestoreFileStage, root: URL, slot: String) throws -> RestoreSnapshotReference {
        let folder = root.appendingPathComponent(stage.name).appendingPathComponent(slot)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        // Identical fixed non-domain bytes for every trial/arm; only the marker metadata intervention varies.
        let catalog = Data(repeating: 0x41, count: 1024), manifest = Data("synthetic-filesystem-only".utf8)
        try catalog.write(to: folder.appendingPathComponent("catalog.sqlite"))
        try manifest.write(to: folder.appendingPathComponent("manifest.json"))
        return RestoreSnapshotReference(path: stage.name + "/" + slot, catalogBytes: catalog.count,
            catalogSHA256: hash(catalog), manifestBytes: manifest.count, manifestSHA256: hash(manifest), schemaVersion: 3)
    }
    private func trial(block: Int, arm: RestoreMarkerProtection, originalOnly: Bool, control: Bool, evidence: URL,
                       exclusion: CalibratedMarkerExclusion? = nil) async throws -> Trial {
        let id = UUID(), fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("afitc-marker-components-" + id.uuidString)
        let record = evidence.appendingPathComponent(id.uuidString + ".json")
        var result = Trial(id: id, block: block, arm: arm, originalStatsOnly: originalOnly, control: control)
        result.mechanism = exclusion?.mechanism.rawValue
        // Exact synthetic ownership is recorded before mkdir, construction or any stage operation.
        try write(result, to: record)
        var publishedBytes: Data?
        var expected: RestoreMarker?
        var diagnostics: SourceRestoreReadDiagnostics?
        let probe = Probe(marker: root.appendingPathComponent("restore-marker.json"), control: control)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: false)
            result.phase = "setup"
            let files = try CatalogRestoreFiles(root: root, markerProtection: arm, markerExclusion: exclusion)
            let stage = try await files.createStage()
            let old = try package(stage, root: root, slot: "old"), new = try package(stage, root: root, slot: "new")
            try Data(repeating: 0x41, count: 1024).write(to: root.appendingPathComponent(stage.name).appendingPathComponent("install.sqlite"))
            let marker = RestoreMarker(version: 1, transaction: stage.transaction, state: .prepared, old: old, new: new)
            try await files.publish(marker, stage: stage)
            publishedBytes = try marker.encoded(); expected = marker
            // Fresh collector and reader only after publication, never setup/protection/readback.
            let collector = SourceRestoreReadDiagnostics(originalStatsOnly: originalOnly, statObserver: { _ in probe.statCall() })
            diagnostics = collector
            let reader = try CatalogRestoreFiles(root: root, observer: { try probe.event($0) }, readDiagnostics: collector)
            result.phase = "read"
            let observed = try await reader.readMarker()
            XCTAssertEqual(observed, expected)
            result.outcome = "strict-read-accepted"
        } catch {
            result.error = String(describing: error)
            result.outcome = result.phase == "read" ? "strict-read-rejected" : "setup-failed"
        }
        // No evidence IO until the actual strict read returned/threw.
        result.trace = diagnostics?.snapshot()
        let values = probe.values(); result.addedStatCalls = values.0; result.changedMasks = values.1
        if result.outcome == "strict-read-accepted" { result.classification = "accepted" }
        else if result.phase != "read" { result.classification = "setup-error" }
        else if result.error != String(describing: RestoreFileError.changedSource) { result.classification = "probe-error" }
        else { result.classification = values.1 == [4224] ? "ctime-only-rejected" : "other-guard-rejected" }
        if let trace = result.trace {
            XCTAssertEqual(trace.dropped, 0)
            let markerEvents = trace.events.filter { $0.role == .marker }
            if let baseline = markerEvents.first(where: { $0.boundary == .baseline })?.guardBaseline {
                XCTAssertEqual(baseline.mode & 0o777, 0o600)
            } else { XCTFail("Actual marker baseline not captured") }
            XCTAssertNotNil(markerEvents.first { $0.boundary == .finalGuard })
            if originalOnly { XCTAssertEqual(values.0, 0) } else { XCTAssertGreaterThan(values.0, 0) }
        }
        if control {
            XCTAssertTrue(values.2)
            XCTAssertEqual(result.phase, "read")
            XCTAssertEqual(result.error, String(describing: RestoreFileError.changedSource))
            XCTAssertEqual(try Data(contentsOf: probe.marker), publishedBytes)
        } else if result.phase != "read" { XCTFail("Scheduled trial setup failed: \(result.error ?? "unknown")") }
        if result.outcome != "strict-read-accepted" && fm.fileExists(atPath: root.path) {
            let destination = evidence.appendingPathComponent("preserved-" + id.uuidString)
            // The primitive fixture has seven fixed small files, no user inputs or linked entries.
            try write(result, to: record)
            try fm.copyItem(at: root, to: destination); result.preserved = true
        }
        if fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
        result.originalRemoved = !fm.fileExists(atPath: root.path)
        XCTAssertTrue(result.originalRemoved)
        try write(result, to: record)
        return result
    }
    func testCounterbalancedMarkerProtectionComponents256TrialsAndFourChmodControls() async throws {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["AFITC_SYNTHETIC_DIAGNOSTIC_EVIDENCE"])
        let evidence = URL(fileURLWithPath: path).appendingPathComponent("marker-components")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let cells = RestoreMarkerProtection.allCases.flatMap { arm in [false, true].map { (arm, $0) } }
        var results: [Trial] = []
        for block in 0..<2 {
            let order = block == 0 ? cells : Array(cells.reversed())
            for (arm, originalOnly) in order {
                for _ in 0..<16 {
                    results.append(try await trial(block: block, arm: arm, originalOnly: originalOnly, control: false, evidence: evidence))
                }
                try write(results, to: evidence.appendingPathComponent("scheduled-results.json"))
                print("[marker-components] completed \(results.count)/256 scheduled trials", terminator: "\n")
            }
        }
        for originalOnly in [false, true] {
            for _ in 0..<2 { results.append(try await trial(block: 2, arm: .full, originalOnly: originalOnly, control: true, evidence: evidence)) }
        }
        XCTAssertEqual(results.filter { !$0.control }.count, 256)
        XCTAssertEqual(results.filter { $0.control }.count, 4)
        for block in 0..<2 {
            for (arm, mode) in cells { XCTAssertEqual(results.filter { !$0.control && $0.block == block && $0.arm == arm && $0.originalStatsOnly == mode }.count, 16) }
        }
        try write(results, to: evidence.appendingPathComponent("scheduled-results.json"))
        print("[marker-components] completed 256 scheduled trials + 4 controls; guard rejections are diagnostic occurrences, not product acceptance")
    }

    func testDescriptorMarkerConfigNegativesAndIndependentFoundationEquivalence() async throws {
        let context = try MarkerDomainTrialContext(owner: self, scenario: "configuration")
        do { try await configuration(context); _ = try context.finish(error: nil) }
        catch { _ = try context.finish(error: error); throw error }
    }
    private func configuration(_ context: MarkerDomainTrialContext) async throws {
        #if os(macOS)
        let fixture = try await context.make("configuration")
        let invalid: [Data?] = [nil, Data(), Data([1, 2, 3]), Data(repeating: 0, count: 1025),
            try PropertyListSerialization.data(fromPropertyList: "wrong", format: .binary, options: 0),
            try PropertyListSerialization.data(fromPropertyList: "com.apple.backupd", format: .xml, options: 0)]
        for bytes in invalid { XCTAssertThrowsError(try MarkerDescriptorValue.checked(bytes)) }
        XCTAssertEqual(try MarkerDescriptorValue.checked(MarkerDescriptorValue.fixed), MarkerDescriptorValue.fixed)
        let a = fixture.root.appendingPathComponent("Foundation-control"), b = fixture.root.appendingPathComponent("descriptor-control")
        let fdA = Darwin.open(a.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        let fdB = Darwin.open(b.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        defer { if fdA >= 0 { XCTAssertEqual(Darwin.close(fdA), 0) }; if fdB >= 0 { XCTAssertEqual(Darwin.close(fdB), 0) } }
        guard fdA >= 0, fdB >= 0 else { throw RestoreFileError.syscall(errno) }
        var reference = a, values = URLResourceValues(); values.isExcludedFromBackup = true
        try reference.setResourceValues(values)
        XCTAssertEqual(try CalibratedMarkerExclusion.read(a, descriptor: fdA, throughDescriptor: true), MarkerDescriptorValue.fixed)
        try RestoreMarkerProtection.full.apply(b, descriptor: fdB, calibratedExclusion: nil, fullArm: .descriptor)
        XCTAssertTrue(try CatalogRepository.excludedFromBackup(b))
        XCTAssertEqual(try URL(fileURLWithPath: b.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(try CalibratedMarkerExclusion.read(b, descriptor: fdB, throughDescriptor: true), MarkerDescriptorValue.fixed)
        XCTAssertEqual(hash(MarkerDescriptorValue.fixed), "8332208d45e5ce6a6e8fbce20032850ce228330125d59489170006e91384b7df")
        let probe = Probe(marker: b, control: false)
        let diagnostics = SourceRestoreReadDiagnostics(originalStatsOnly: true, statObserver: { _ in probe.statCall() }, perReadCapture: true)
        let first = diagnostics.nextReadID()
        for _ in 0..<513 { diagnostics.sample(first, origin: .files, role: .marker, boundary: .beforeReadObserver, fd: fdB) }
        for _ in 0..<128 { _ = diagnostics.nextReadID() }
        let bounded = diagnostics.snapshotReads()
        XCTAssertEqual(bounded.readDrops, 1); XCTAssertEqual(bounded.eventDrops, 1)
        XCTAssertEqual(bounded.traces.count, 128); XCTAssertEqual(bounded.traces.first?.events.count, 512)
        XCTAssertEqual(probe.values().0, 0)
        #endif
    }

    func testProductionOwnedPolicyUsesPlatformDefaultThroughPublicBackupValidationAndRestore() async throws {
        #if os(macOS)
        XCTAssertEqual(OwnedRestoreProtection.production, .descriptor)
        #else
        XCTAssertEqual(OwnedRestoreProtection.production, .foundation)
        #endif
        let old = try await SearchFixture.make(self), incoming = try await SearchFixture.make(self)
        let photo = try await incoming.photo("fictional-default-policy.jpg", [nil])
        let package = try await incoming.catalog.prepareBackup()
        let validator = try RestoreValidator(stagingDirectory: incoming.root.appendingPathComponent("public-validation"))
        let validated = try await validator.validate(package: package.directory)
        for directory in [package.directory, validated.directory] {
            XCTAssertTrue(try CatalogRepository.excludedFromBackup(directory))
            for name in ["manifest.json", "catalog.sqlite"] {
                XCTAssertTrue(try CatalogRepository.excludedFromBackup(directory.appendingPathComponent(name)))
            }
        }
        let session = try await CatalogRestoreRepository.beginRestore(catalog: old.catalog)
        let fresh = try await session.restore(validated)
        let photos = try await fresh.photos(); XCTAssertEqual(photos.map { $0.id }, [photo.id])
        let grant = try await fresh.loadGrant(); XCTAssertNil(grant)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.root.appendingPathComponent("db/restore-marker.json").path))
    }

    func testOwnedOutputDirectoryAndFileFoundationEquivalenceAndUnsafeConfigRejection() async throws {
        #if os(macOS)
        let fixture = try await SearchFixture.make(self)
        for directory in [false, true] {
            let reference = fixture.root.appendingPathComponent(directory ? "reference-dir" : "reference-file")
            let candidate = fixture.root.appendingPathComponent(directory ? "candidate-dir" : "candidate-file")
            for url in [reference, candidate] {
                if directory { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
                else { XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("fictional".utf8))) }
            }
            try OwnedRestoreProtection.foundation.apply(reference, directory: directory)
            try OwnedRestoreProtection.descriptor.apply(candidate, directory: directory)
            for url in [reference, candidate] {
                let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : 0))
                XCTAssertGreaterThanOrEqual(fd, 0); guard fd >= 0 else { throw RestoreFileError.syscall(errno) }
                var closed = false; defer { if !closed { Darwin.close(fd) } }
                XCTAssertEqual(try CalibratedMarkerExclusion.read(url, descriptor: fd, throughDescriptor: true), MarkerDescriptorValue.fixed)
                XCTAssertEqual(try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
                var info = stat(); XCTAssertEqual(fstat(fd, &info), 0)
                XCTAssertEqual(info.st_mode & 0o777, directory ? 0o700 : 0o600)
                XCTAssertEqual(fsync(fd), 0); XCTAssertEqual(Darwin.close(fd), 0); closed = true
            }
        }
        let absent = fixture.root.appendingPathComponent("never-created")
        let invalid: [Data?] = [nil, Data(), Data("bad".utf8), Data(repeating: 1, count: 1025)]
        for bytes in invalid {
            XCTAssertThrowsError(try OwnedRestoreProtection.descriptor.apply(absent, configuredBytes: bytes))
            XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
        }
        let wrongKind = fixture.root.appendingPathComponent("candidate-dir")
        XCTAssertThrowsError(try OwnedRestoreProtection.descriptor.apply(wrongKind))
        let target = fixture.root.appendingPathComponent("candidate-file"), symbolic = fixture.root.appendingPathComponent("symbolic")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: target)
        XCTAssertThrowsError(try OwnedRestoreProtection.descriptor.apply(symbolic))
        let linked = fixture.root.appendingPathComponent("hard-linked")
        XCTAssertEqual(link(target.path, linked.path), 0)
        XCTAssertThrowsError(try OwnedRestoreProtection.descriptor.apply(linked))
        #endif
    }

    #if os(macOS)
    /// Inspect only new, exactly owned synthetic calibration descriptors, never external metadata.
    private func attributes(_ descriptor: Int32) throws -> [String: Data] {
        let size = flistxattr(descriptor, nil, 0, 0)
        guard size >= 0, size <= 1024 else { throw RestoreFileError.unsafeEntry }
        guard size > 0 else { return [:] }
        var names = [CChar](repeating: 0, count: size)
        guard flistxattr(descriptor, &names, size, 0) == size else { throw RestoreFileError.syscall(errno) }
        var values: [String: Data] = [:]
        for nameBytes in names.split(separator: 0) {
            let name = String(decoding: nameBytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard name.utf8.count <= 127, values.count < 8 else { throw RestoreFileError.unsafeEntry }
            let count = fgetxattr(descriptor, name, nil, 0, 0, 0)
            guard count >= 0, count <= 1024 else { throw RestoreFileError.unsafeEntry }
            var bytes = [UInt8](repeating: 0, count: count)
            guard fgetxattr(descriptor, name, &bytes, count, 0, 0) == count else { throw RestoreFileError.syscall(errno) }
            values[name] = Data(bytes)
        }
        return values
    }
    private func calibration(block: Int, descriptorSetter: Bool, expected: Data?, evidence: URL) throws -> Data {
        let id = UUID(), fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("afitc-marker-calibration-" + id.uuidString)
        let record = evidence.appendingPathComponent("calibration-" + id.uuidString + ".json")
        var result = ["id": id.uuidString, "block": String(block), "kind": descriptorSetter ? "descriptor-equivalence" : "Foundation-derivation",
                      "phase": "registered", "outcome": "unobserved", "preserved": "false", "originalRemoved": "false"]
        try write(result, to: record) // Ownership before mkdir/open/setters.
        var fd: Int32 = -1; var value: Data?; var failure: Error?
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: false)
            let file = root.appendingPathComponent("synthetic-calibration")
            fd = Darwin.open(file.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw RestoreFileError.syscall(errno) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600,
                  info.st_nlink == 1 else { throw RestoreFileError.unsafeEntry }
            result["phase"] = "calibrating"
            let before = try attributes(fd)
            if descriptorSetter {
                let config = try CalibratedMarkerExclusion(mechanism: .descriptorDescriptor, bytes: XCTUnwrap(expected))
                try config.apply(file, descriptor: fd)
            } else {
                var url = file; var resources = URLResourceValues(); resources.isExcludedFromBackup = true
                try url.setResourceValues(resources)
            }
            let after = try attributes(fd)
            let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
            guard changed.allSatisfy({ $0 == CalibratedMarkerExclusion.key }),
                  let observed = after[CalibratedMarkerExclusion.key], try CatalogRepository.excludedFromBackup(file) else {
                throw RestoreFileError.unsafeEntry
            }
            _ = try CalibratedMarkerExclusion(mechanism: .foundationPath, bytes: observed)
            if let expected { guard observed == expected else { throw RestoreFileError.unsafeEntry } }
            value = observed; result["outcome"] = "verified"
            result["valueBytes"] = String(observed.count); result["valueSHA256"] = hash(observed)
        } catch { failure = error; result["outcome"] = "calibration-error"; result["error"] = String(describing: error) }
        if fd >= 0 { guard Darwin.close(fd) == 0 else { throw RestoreFileError.syscall(errno) } }
        if failure != nil && fm.fileExists(atPath: root.path) {
            try write(result, to: record)
            try fm.copyItem(at: root, to: evidence.appendingPathComponent("preserved-calibration-" + id.uuidString)); result["preserved"] = "true"
        }
        if fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
        result["originalRemoved"] = String(!fm.fileExists(atPath: root.path)); XCTAssertEqual(result["originalRemoved"], "true")
        try write(result, to: record)
        if let failure { throw failure }; return try XCTUnwrap(value)
    }
    #endif

    func testCounterbalancedExclusionMechanisms320TrialsFourCalibrationOwnersAndFourChmodControls() async throws {
        #if os(macOS)
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["AFITC_SYNTHETIC_DIAGNOSTIC_EVIDENCE"])
        let evidence = URL(fileURLWithPath: path).appendingPathComponent("marker-exclusion")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let cells = MarkerExclusionMechanism.allCases.flatMap { arm in [false, true].map { (arm, $0) } }
        var results: [Trial] = []; var lastCalibration: Data?
        for block in 0..<2 {
            let calibrated = try calibration(block: block, descriptorSetter: false, expected: nil, evidence: evidence)
            _ = try calibration(block: block, descriptorSetter: true, expected: calibrated, evidence: evidence)
            lastCalibration = calibrated
            let order = block == 0 ? cells : Array(cells.reversed())
            for (mechanism, mode) in order {
                let config = try CalibratedMarkerExclusion(mechanism: mechanism, bytes: calibrated)
                for _ in 0..<16 {
                    results.append(try await trial(block: block, arm: mechanism == .none ? .none : .exclusionOnly,
                        originalOnly: mode, control: false, evidence: evidence, exclusion: config))
                }
                try write(results, to: evidence.appendingPathComponent("scheduled-results.json"))
                print("[marker-exclusion] completed \(results.count)/320 scheduled trials")
            }
        }
        for mode in [false, true] {
            for mechanism in [MarkerExclusionMechanism.foundationPath, .descriptorDescriptor] {
                let config = try CalibratedMarkerExclusion(mechanism: mechanism, bytes: XCTUnwrap(lastCalibration))
                results.append(try await trial(block: 2, arm: .exclusionOnly, originalOnly: mode, control: true, evidence: evidence, exclusion: config))
            }
        }
        XCTAssertEqual(results.filter { !$0.control }.count, 320); XCTAssertEqual(results.filter { $0.control }.count, 4)
        for block in 0..<2 {
            for (arm, mode) in cells {
                XCTAssertEqual(results.filter { !$0.control && $0.block == block && $0.mechanism == arm.rawValue && $0.originalStatsOnly == mode }.count, 16)
            }
        }
        try write(results, to: evidence.appendingPathComponent("scheduled-results.json"))
        print("[marker-exclusion] completed320 +4 calibration owners +4 controls; diagnostic completion, not product acceptance")
        #endif
    }
}
