import XCTest
import Foundation
import Darwin
@testable import AFITCCore

final class PresentationPreferenceTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("afitc-prefs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func input() -> PresentationPreferences {
        var value = PresentationPreferences(); let person = PersonRecord(displayName: "Fictional name")
        var draft = PersonNameDraft(person: person); draft.edit("Owner draft")
        value.drafts[person.id] = draft; value.search.selected = [person.id]; value.search.mode = .any
        value.search.requestedPages = 3; value.anchors["People"] = person.id; return value
    }
    func testRoundTripInputOnlyAndEffectiveProtection() async throws {
        let root = try fixture().appendingPathComponent("Catalog-Presentation"), epoch = UUID()
        let store = PresentationPreferenceStore(ownedDirectory: root, epoch: epoch), value = input()
        try await store.save(value, epoch: epoch); try await store.flush()
        let loaded = try await store.load(); XCTAssertEqual(loaded, value)
        for url in [root, root.appendingPathComponent("preferences.json")] {
            XCTAssertTrue(try CatalogRepository.excludedFromBackup(url))
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, url == root ? 0o700 : 0o600)
            #if os(iOS)
            XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .complete)
            #endif
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("preferences.json"))) as! [String: Any]
        XCTAssertEqual(Set(object.keys), ["version", "search", "anchors", "drafts"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("preferences.tmp").path))
    }
    func testBoundsRejectWithoutEvictingPriorInput() async throws {
        let root = try fixture().appendingPathComponent("prefs"), epoch = UUID(), value = input()
        let store = PresentationPreferenceStore(ownedDirectory: root, epoch: epoch)
        try await store.save(value, epoch: epoch); try await store.flush()
        var huge = value; huge.drafts[huge.drafts.keys.first!]!.ownerText = String(repeating: "x", count: 65536)
        do { try await store.save(huge, epoch: epoch); XCTFail("Oversize admitted") } catch { XCTAssertEqual(error as? PresentationPreferenceError, .bounds) }
        huge = value; huge.search.requestedPages = 65
        do { try await store.save(huge, epoch: epoch); XCTFail("Page overflow admitted") } catch { XCTAssertEqual(error as? PresentationPreferenceError, .bounds) }
        huge = value
        for _ in 0..<128 { let p = PersonRecord(displayName: "Fiction"); var d = PersonNameDraft(person: p); d.edit("Draft"); huge.drafts[p.id] = d }
        do { try await store.save(huge, epoch: epoch); XCTFail("Draft overflow admitted") } catch { XCTAssertEqual(error as? PresentationPreferenceError, .bounds) }
        let reloaded = try await store.load(); XCTAssertEqual(reloaded, value)
    }
    func testMalformedVersionModeAndUUIDFailWithFixedErrors() async throws {
        let root = try fixture().appendingPathComponent("prefs"), epoch = UUID()
        let store = PresentationPreferenceStore(ownedDirectory: root, epoch: epoch)
        _ = try await store.load()
        let final = root.appendingPathComponent("preferences.json")
        for data in [Data("private malformed draft".utf8), Data("{\"version\":99,\"search\":{\"mode\":\"together\",\"selected\":[],\"requestedPages\":1},\"anchors\":{},\"drafts\":[]}".utf8)] {
            try data.write(to: final)
            do { _ = try await store.load(); XCTFail("Invalid input admitted") }
            catch { XCTAssertTrue([PresentationPreferenceError.corrupt, .unsupported].contains(error as? PresentationPreferenceError ?? .io)) }
        }
        var value = input(); value.anchors["source/path"] = UUID()
        do { try await store.save(value, epoch: epoch); XCTFail("Path key admitted") } catch { XCTAssertEqual(error as? PresentationPreferenceError, .corrupt) }
    }
    func testFailedAtomicWritePreservesOldBytesAndCleansOwnedTemporary() async throws {
        let root = try fixture().appendingPathComponent("prefs"), epoch = UUID(), value = input()
        let store = PresentationPreferenceStore(ownedDirectory: root, epoch: epoch)
        try await store.save(value, epoch: epoch); try await store.flush()
        let before = try Data(contentsOf: root.appendingPathComponent("preferences.json"))
        let failed = PresentationPreferenceStore(ownedDirectory: root, epoch: epoch, beforeWrite: {}, failBeforeReplace: true)
        var next = value; next.search.requestedPages = 4
        try await failed.save(next, epoch: epoch)
        do { try await failed.flush(); XCTFail("Fault not reached") } catch { XCTAssertEqual(error as? PresentationPreferenceError, .injectedFailure) }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("preferences.json")), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("preferences.tmp").path))
    }
    func testForeignEntrySymlinkAndHardLinkRemainUntouched() async throws {
        let base = try fixture(), root = base.appendingPathComponent("prefs"), outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("foreign".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("preferences.json"), withDestinationURL: outside)
        let store = PresentationPreferenceStore(ownedDirectory: root, epoch: UUID())
        do { _ = try await store.load(); XCTFail("Symlink admitted") } catch { XCTAssertEqual(error as? PresentationPreferenceError, .unsafe) }
        XCTAssertEqual(try Data(contentsOf: outside), Data("foreign".utf8))
        try FileManager.default.removeItem(at: root.appendingPathComponent("preferences.json"))
        XCTAssertEqual(link(outside.path, root.appendingPathComponent("preferences.json").path), 0)
        do { _ = try await store.load(); XCTFail("Hard link admitted") } catch { XCTAssertEqual(error as? PresentationPreferenceError, .unsafe) }
        try Data("unknown".utf8).write(to: root.appendingPathComponent("foreign"))
        do { try await store.removeOwnedPreferencesForCatalogDelete(epoch: UUID()); XCTFail("Foreign directory removed") } catch { XCTAssertEqual(error as? PresentationPreferenceError, .unsafe) }
        XCTAssertEqual(try Data(contentsOf: outside), Data("foreign".utf8))
    }
    func testQueuedOldWriterActuallyDrainsBeforeResetAndCannotRepopulate() async throws {
        let root = try fixture().appendingPathComponent("prefs"), old = UUID(), next = UUID(), gate = HeldWriter()
        let store = PresentationPreferenceStore(ownedDirectory: root, epoch: old, beforeWrite: { await gate.hold() })
        try await store.save(input(), epoch: old); await gate.waitUntilHeld()
        let reset = Task { try await store.resetForCatalogReplacement(epoch: next) }
        // Actor admission gives a causal observation that reset has closed the old epoch.
        var rejected = false
        for _ in 0..<1000 {
            do { try await store.save(input(), epoch: old) } catch { rejected = true; break }
            await Task.yield()
        }
        XCTAssertTrue(rejected); XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("preferences.json").path))
        await gate.release(); try await reset.value
        let resetValue = try await store.load(); XCTAssertEqual(resetValue, PresentationPreferences())
        do { try await store.save(input(), epoch: old); XCTFail("Old epoch admitted") } catch { XCTAssertEqual(error as? PresentationPreferenceError, .staleEpoch) }
    }
    func testCoalescesToLatestInputAndDeletesOnlyOwnedSibling() async throws {
        let base = try fixture(), root = base.appendingPathComponent("Catalog-Presentation"), epoch = UUID(), gate = HeldWriter()
        let export = base.appendingPathComponent("old-export"); try Data("export".utf8).write(to: export)
        let store = PresentationPreferenceStore(ownedDirectory: root, epoch: epoch, beforeWrite: { await gate.hold() })
        var value = input(); try await store.save(value, epoch: epoch); await gate.waitUntilHeld()
        for page in 2...12 { value.search.requestedPages = page; try await store.save(value, epoch: epoch) }
        await gate.release(); try await store.flush(); let reloaded = try await store.load(); XCTAssertEqual(reloaded, value)
        try await store.removeOwnedPreferencesForCatalogDelete(epoch: UUID())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path)); XCTAssertEqual(try Data(contentsOf: export), Data("export".utf8))
    }
    func testForeignFixedTemporaryIsNeverRemovedBySaveOrDelete() async throws {
        let root = try fixture().appendingPathComponent("prefs"), epoch = UUID()
        let store = PresentationPreferenceStore(ownedDirectory: root, epoch: epoch)
        _ = try await store.load()
        let foreign = root.appendingPathComponent("preferences.tmp"), sentinel = Data("foreign temporary".utf8)
        try sentinel.write(to: foreign)
        try await store.save(input(), epoch: epoch)
        do { try await store.flush(); XCTFail("Foreign temporary replaced") } catch { XCTAssertEqual(error as? PresentationPreferenceError, .unsafe) }
        do { try await store.removeOwnedPreferencesForCatalogDelete(epoch: UUID()); XCTFail("Foreign temporary removed") } catch { XCTAssertEqual(error as? PresentationPreferenceError, .unsafe) }
        XCTAssertEqual(try Data(contentsOf: foreign), sentinel)
    }
    func testActualFailedWriteRequiresExplicitLatestInputRetryAfterOwnedRepair() async throws {
        let root = try fixture().appendingPathComponent("prefs"), epoch = UUID(), previous = input()
        let store = PresentationPreferenceStore(ownedDirectory: root, epoch: epoch)
        try await store.save(previous, epoch: epoch); try await store.flush()
        let final = root.appendingPathComponent("preferences.json"), before = try Data(contentsOf: final)
        let obstruction = root.appendingPathComponent("preferences.tmp")
        let fd = Darwin.open(obstruction.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0); guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        var owned = stat(); XCTAssertEqual(fstat(fd, &owned), 0)
        var removed = false
        defer {
            var actual = stat()
            if !removed, lstat(obstruction.path, &actual) == 0, actual.st_mode & S_IFMT == S_IFREG,
               actual.st_nlink == 1, actual.st_dev == owned.st_dev, actual.st_ino == owned.st_ino { unlink(obstruction.path) }
        }
        try CatalogRepository.protect(obstruction); XCTAssertEqual(fsync(fd), 0)
        var latest = previous; latest.search.requestedPages = 4
        try await store.save(latest, epoch: epoch)
        do { try await store.flush(); XCTFail("Real obstruction did not fail writer") }
        catch { XCTAssertEqual(error as? PresentationPreferenceError, .unsafe) }
        XCTAssertEqual(try Data(contentsOf: final), before)
        let personID = try XCTUnwrap(latest.drafts.keys.first)
        latest.drafts[personID]!.edit("Latest retained owner input")
        var actual = stat()
        XCTAssertEqual(lstat(obstruction.path, &actual), 0); XCTAssertEqual(actual.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(actual.st_nlink, 1); XCTAssertEqual(actual.st_dev, owned.st_dev); XCTAssertEqual(actual.st_ino, owned.st_ino)
        guard actual.st_dev == owned.st_dev, actual.st_ino == owned.st_ino, actual.st_mode & S_IFMT == S_IFREG, actual.st_nlink == 1 else { return }
        XCTAssertEqual(unlink(obstruction.path), 0); removed = true
        // Repair has no queued write and cannot manufacture a success outcome.
        do { try await store.flush(); XCTFail("Repair alone cleared failed outcome") }
        catch { XCTAssertEqual(error as? PresentationPreferenceError, .unsafe) }
        XCTAssertEqual(try Data(contentsOf: final), before)
        try await store.save(latest, epoch: epoch); try await store.flush()
        let reopened = PresentationPreferenceStore(ownedDirectory: root, epoch: UUID())
        let accepted = try await reopened.load(); XCTAssertEqual(accepted, latest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: obstruction.path))
    }
    func testDirtyDraftConflictRetainsTextAndCleanDraftFollowsCanonical() throws {
        let original = PersonRecord(displayName: "Same name"), other = PersonRecord(displayName: "Same name")
        XCTAssertNotEqual(original.id, other.id)
        var dirty = PersonNameDraft(person: original), clean = dirty; dirty.edit("Owner text")
        var renamed = original; renamed.displayName = "Renamed"; renamed.exemplarRevision += 1
        dirty.reconcile(renamed); clean.reconcile(renamed)
        XCTAssertEqual(dirty.ownerText, "Owner text"); XCTAssertEqual(dirty.conflict, .changed); XCTAssertEqual(clean.ownerText, "Renamed")
        dirty.reviewAgainst(renamed); XCTAssertNil(dirty.conflict); XCTAssertTrue(dirty.dirty)
        renamed.mergedInto = other.id; dirty.reconcile(renamed)
        XCTAssertEqual(dirty.ownerText, "Owner text"); XCTAssertEqual(dirty.conflict, .unavailable)
        dirty.reconcile(nil); XCTAssertEqual(dirty.ownerText, "Owner text")
    }
}
private actor HeldWriter {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var held = false, released = false
    func hold() async {
        guard !released else { return }; held = true
        observers.forEach { $0.resume() }; observers = []
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilHeld() async { if held { return }; await withCheckedContinuation { observers.append($0) } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
