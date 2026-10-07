import SwiftUI
import AFITCCore
import Darwin

/// App-owned input continuity. Sensitive draft text stays in RAM and the protected sibling store.
@MainActor
final class AppPresentationState: ObservableObject {
    let search = SearchService()
    @Published private(set) var preferences = PresentationPreferences()
    @Published private(set) var drafts: [UUID: PersonNameDraft] = [:]
    @Published private(set) var warning: String?
    @Published private(set) var isSavingInputs = false
    @Published private(set) var saveFailed = false
    @Published private(set) var saveFeedback: String?
    var canRetrySavingInputs: Bool { saveFailed && !isSavingInputs && services?.isQuiescingCatalog == false }
    #if DEBUG
    private let testDirectory: URL
    private struct ObstructionIdentity: Sendable { let device: UInt64; let inode: UInt64 }
    private var obstruction: ObstructionIdentity?
    private var fixtureTask: Task<Void, Never>?
    @Published private(set) var saveFixtureProbe = "Obstruction absent"
    #endif
    @Published private(set) var loaded = false
    @Published private(set) var persistenceProbe = "Writes 0 · Active 0"
    private let store: PresentationPreferenceStore
    private var epoch: UUID
    private var mutation: UInt64 = 0
    private var pending: PresentationPreferences?
    private var saveTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private weak var services: AppServices?
    private var committedWaiting: [UUID: (String, Int)] = [:]
    private var writes = 0
    private var editedDraftIDs: Set<UUID> = []
    init(directory: URL, launch: LaunchOptions) {
        let initial = UUID(); epoch = initial
        #if DEBUG
        if launch.has("--uitest-synthetic-source"),
           launch.has("--uitest-protected-hold-preferences") {
            // Core validates exact generated UUID ownership before this real writer hook is installed.
            store = try! PresentationPreferenceStore(ownedSyntheticDirectory: directory, epoch: initial,
                beforeSyntheticWrite: { await ProtectedFixtureGate.hold("preference-writer") })
        } else { store = PresentationPreferenceStore(ownedDirectory: directory, epoch: initial) }
        #else
        store = PresentationPreferenceStore(ownedDirectory: directory, epoch: initial)
        #endif
        #if DEBUG
        testDirectory = directory
        #endif
    }
    func releaseProtectedSnapshots() {
        search.invalidate(); drafts = drafts.filter { $0.value.dirty }
        committedWaiting = [:]
    }
    func finishProtectedWork() async {
        if let loadTask { await loadTask.value }; if let saveTask { await saveTask.value }
        #if DEBUG
        if let fixtureTask { await fixtureTask.value }
        #endif
        // flush returns only after the actual coalescing writer has finished, including failure.
        do { try await store.flush() }
        catch { warning = "Saved inputs could not finish. Dirty text remains in memory."; saveFailed = true }
    }
    func attach(_ services: AppServices) {
        self.services = services
        guard let operation = services.catalogSession.begin("presentation-load") else { return }
        let initialMutation = mutation, initialEpoch = epoch
        let work = Task {
            defer { services.catalogSession.finish(operation); loadTask = nil }
            do {
                guard services.sessionIsCurrent(operation.session), services.protection.admitsWork, !Task.isCancelled else { return }
                let value = try await store.load()
                guard services.sessionIsCurrent(operation.session), epoch == initialEpoch else { return }
                if mutation == initialMutation { preferences = value; drafts = value.drafts }
                else {
                    // An early filter edit must never discard unrelated saved owner text.
                    for (id, draft) in value.drafts where !editedDraftIDs.contains(id) { drafts[id] = draft }
                    preferences.anchors.merge(value.anchors) { current, _ in current }
                    changed()
                }
                loaded = true
                if services.hasLoadedPeopleSnapshot { reconcile(services.peopleSnapshot.people.map(\.person)) }
            } catch {
                guard services.sessionIsCurrent(operation.session), epoch == initialEpoch else { return }
                warning = "Saved inputs could not be opened. Current edits remain in memory."; loaded = true
            }
        }
        loadTask = work; services.catalogSession.bind(operation) { work.cancel() }
    }
    func setSearch(mode: SearchMode? = nil, selected: Set<UUID>? = nil) {
        guard services?.isQuiescingCatalog == false, services?.privacy.catalogDeleted != true else { return }
        if let mode { preferences.search.mode = mode }
        if let selected { preferences.search.selected = selected }
        preferences.search.requestedPages = 1; search.invalidate(); changed()
    }
    func catalogAdopted() {
        guard saveTask == nil else { return }
        isSavingInputs = false
        if !saveFailed { startSave() }
    }
    func requestedPage() {
        guard services?.isQuiescingCatalog == false, services?.privacy.catalogDeleted != true else { return }
        preferences.search.requestedPages = min(64, preferences.search.requestedPages + 1); changed()
    }
    func anchor(_ section: String, available: Set<UUID>) -> UUID? {
        guard let id = preferences.anchors[section], available.contains(id) else { return nil }; return id
    }
    func setAnchor(_ id: UUID, section: String) {
        guard services?.isQuiescingCatalog == false, services?.privacy.catalogDeleted != true, preferences.anchors[section] != id else { return }
        preferences.anchors[section] = id; changed()
    }
    func ensureDraft(_ person: PersonRecord) {
        if drafts[person.id] == nil { drafts[person.id] = PersonNameDraft(person: person) }
        reconcile([person], complete: false)
    }
    func edit(_ id: UUID, text: String) {
        guard services?.isQuiescingCatalog == false, services?.privacy.catalogDeleted != true, var draft = drafts[id] else { return }
        editedDraftIDs.insert(id); draft.edit(text); drafts[id] = draft; changed()
    }
    func reconcile(_ people: [PersonRecord], complete: Bool = true) {
        let records = Dictionary(grouping: people, by: \.id)
        var modified = false
        for (id, var draft) in drafts {
            let record = records[id]?.count == 1 ? records[id]?.first : nil
            if !complete, record == nil { continue }
            if let waiting = committedWaiting[id], let record, record.exemplarRevision <= waiting.1 { continue }
            committedWaiting.removeValue(forKey: id)
            let before = draft; draft.reconcile(record)
            if draft != before { drafts[id] = draft; modified = true }
        }
        if modified { changed() }
    }
    func discardDraft(_ id: UUID) {
        guard services?.isQuiescingCatalog == false, services?.privacy.catalogDeleted != true else { return }
        editedDraftIDs.insert(id); drafts.removeValue(forKey: id); committedWaiting.removeValue(forKey: id); changed()
    }
    func recordVisible(_ section: String, positions: [UUID: CGFloat]) {
        guard loaded else { return }
        let visible = positions.filter { $0.value >= 0 }.min { $0.value < $1.value }
        if let id = visible?.key { setAnchor(id, section: section) }
    }
    func useCurrent(_ person: PersonRecord) {
        guard services?.isQuiescingCatalog == false, services?.privacy.catalogDeleted != true else { return }
        editedDraftIDs.insert(person.id); drafts[person.id] = PersonNameDraft(person: person); committedWaiting.removeValue(forKey: person.id); changed()
    }
    func review(_ person: PersonRecord) {
        guard services?.isQuiescingCatalog == false, services?.privacy.catalogDeleted != true, var draft = drafts[person.id] else { return }
        editedDraftIDs.insert(person.id); draft.reviewAgainst(person); drafts[person.id] = draft; changed()
    }
    func acceptedCommit(_ id: UUID, text: String) {
        guard var draft = drafts[id] else { return }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        editedDraftIDs.insert(id); committedWaiting[id] = (name, draft.baseRevision)
        draft.baseName = name; draft.ownerText = name; draft.dirty = false; draft.conflict = nil
        drafts[id] = draft; changed()
    }
    private func changed() {
        if mutation < UInt64.max { mutation += 1 }
        // Clean canonical names are RAM-only; disk contains dirty input drafts only.
        preferences.drafts = drafts.filter { $0.value.dirty }
        pending = preferences
        if !saveFailed { startSave() }
    }
    /// One explicit attempt uses current RAM input; errors never enqueue an automatic retry.
    func retrySavingInputs() {
        guard canRetrySavingInputs else { return }
        preferences.drafts = drafts.filter { $0.value.dirty }
        pending = preferences; saveFeedback = "Saving inputs"; startSave()
    }
    private func startSave() {
        guard saveTask == nil, pending != nil, let services,
              let operation = services.catalogSession.begin("presentation-write") else { return }
        let capturedEpoch = epoch
        let work = Task {
            defer {
                services.catalogSession.finish(operation); saveTask = nil
                if services.sessionIsCurrent(operation.session), epoch == capturedEpoch {
                    isSavingInputs = false; persistenceProbe = "Writes \(writes) · Active 0"
                }
            }
            while let value = pending {
                pending = nil
                guard services.sessionIsCurrent(operation.session), epoch == capturedEpoch, !Task.isCancelled else { return }
                do {
                    try await store.save(value, epoch: capturedEpoch)
                    // Cancellation never masquerades as completion of the actual actor writer.
                    try await store.flush()
                    guard services.sessionIsCurrent(operation.session), epoch == capturedEpoch else { return }
                    writes += 1; warning = nil; saveFailed = false
                    if saveFeedback != nil { saveFeedback = pending == nil ? "Inputs saved" : "Saving inputs" }
                } catch {
                    guard services.sessionIsCurrent(operation.session), epoch == capturedEpoch else { return }
                    warning = "Inputs could not be saved. Dirty text remains in memory; reduce the saved input or retry."
                    saveFailed = true; saveFeedback = "Inputs not saved"
                    pending = nil; return
                }
            }
        }
        saveTask = work; isSavingInputs = true; persistenceProbe = "Writes \(writes) · Active 1"
        services.catalogSession.bind(operation) { work.cancel() }
    }
    /// Narrow permission does not open ordinary preferences or catalog admissions.
    func prepareProtectedAdoption(_ services: AppServices, permit: ProtectedReopenPermit,
                                  preserveOriginal: Bool) async throws {
        self.services = services
        func check() throws {
            guard services.protection.accepts(permit), !Task.isCancelled else { throw CancellationError() }
        }
        try check()
        if let loadTask { await loadTask.value }; if let saveTask { await saveTask.value }
        try await store.flush(); try check()
        if preserveOriginal {
            if !loaded {
                let value = try await store.load(); try check()
                preferences = value; drafts = value.drafts; loaded = true
            }
            // Latest dirty RAM input wins, including base/conflict metadata retained on lock.
            preferences.drafts = drafts.filter { $0.value.dirty }; pending = preferences
        } else {
            let next = UUID(); try await store.resetForCatalogReplacement(epoch: next)
            // Capture the completed disk epoch even if a new WILL rejects subsequent publication.
            epoch = next; pending = nil
            try check()
            preferences = PresentationPreferences(); drafts = [:]; committedWaiting = [:]
            mutation = 0; editedDraftIDs = []; warning = nil; saveFailed = false; loaded = true
        }
        search.invalidate(); isSavingInputs = false
    }
    /// Called after actual catalog drain, before synchronous graph publication.
    func prepareAdoption(preserveOriginal: Bool) async throws {
        if let loadTask { await loadTask.value }; if let saveTask { await saveTask.value }
        guard services?.protection.admitsWork == true else { throw CancellationError() }
        search.invalidate()
        // A canceled old-session save may have consumed pending without publishing.
        // Re-admit the latest retained input only after the checked original graph reopens.
        guard !preserveOriginal else { pending = preferences; return }
        let next = UUID()
        try await store.resetForCatalogReplacement(epoch: next)
        epoch = next; pending = nil; preferences = PresentationPreferences(); drafts = [:]; committedWaiting = [:]
        mutation = 0; editedDraftIDs = []; warning = nil; saveFailed = false; isSavingInputs = false; saveFeedback = nil; loaded = true
    }
    /// Checked postcommit cleanup; callers retain the committed family until this finishes.
    func removeDeletedPeople(_ ids: Set<UUID>) async throws {
        if let loadTask { await loadTask.value }; if let saveTask { await saveTask.value }
        #if DEBUG
        if let fixtureTask { await fixtureTask.value }
        #endif
        guard services?.protection.admitsWork == true, !Task.isCancelled else { throw CancellationError() }
        var next = preferences
        let remaining = drafts.filter { !ids.contains($0.key) }
        next.drafts = remaining.filter { $0.value.dirty }
        next.search.selected.subtract(ids); next.search.requestedPages = 1
        // Anchor values identify photos; only the deleted person sections belong to this family.
        next.anchors = next.anchors.filter { key, _ in
            !ids.contains(where: { key == "Person-" + $0.uuidString })
        }
        try await store.save(next, epoch: epoch); try await store.flush()
        preferences = next; drafts = remaining; pending = nil
        committedWaiting = committedWaiting.filter { !ids.contains($0.key) }; editedDraftIDs.subtract(ids)
        search.invalidate(); warning = nil; saveFailed = false; isSavingInputs = false
    }
    func removeOwnedPreferencesForCatalogDelete(permit: ProtectedReopenPermit? = nil) async throws {
        if let loadTask { await loadTask.value }; if let saveTask { await saveTask.value }
        #if DEBUG
        if let fixtureTask { await fixtureTask.value }
        #endif
        guard let services, (services.protection.admitsWork || permit.map(services.protection.accepts) == true), !Task.isCancelled else { throw CancellationError() }
        let next = UUID(); try await store.removeOwnedPreferencesForCatalogDelete(epoch: next)
        epoch = next; pending = nil; preferences = PresentationPreferences(); drafts = [:]; committedWaiting = [:]; editedDraftIDs = []; search.invalidate()
        warning = nil; saveFailed = false; saveFeedback = nil; isSavingInputs = false; loaded = true
    }
    #if DEBUG
    /// Fixed synthetic fault only; repair checks the identity this fixture exclusively created.
    func setSaveObstructionForTest(create: Bool) {
        guard let services, services.usesSyntheticFixture, loaded, fixtureTask == nil,
              services.launch.has("--uitest-presentation-save-retry") else { return }
        let operation = services.catalogSession.begin("presentation-save-fixture")
        guard operation != nil || services.privacy.pendingCleanup else { return }
        let session = services.catalogSession.session
        let capturedEpoch = epoch, directory = testDirectory, recorded = obstruction
        let work = Task {
            defer { if let operation { services.catalogSession.finish(operation) }; fixtureTask = nil }
            if let saveTask { await saveTask.value }
            guard services.catalogSession.session == session, epoch == capturedEpoch, !Task.isCancelled else { return }
            let filesystem = Task.detached { () throws -> ObstructionIdentity? in
                let file = directory.appendingPathComponent("preferences.tmp")
                var root = stat()
                guard lstat(directory.path, &root) == 0, root.st_mode & S_IFMT == S_IFDIR else { throw PresentationPreferenceError.unsafe }
                if create {
                    guard recorded == nil else { throw PresentationPreferenceError.unsafe }
                    let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    guard fd >= 0 else { throw PresentationPreferenceError.unsafe }; defer { Darwin.close(fd) }
                    var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw PresentationPreferenceError.unsafe }
                    let identity = ObstructionIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
                    do { try CatalogRepository.protect(file); guard fsync(fd) == 0 else { throw PresentationPreferenceError.io } }
                    catch { try Self.removeTestObstruction(file, identity: identity); throw error }
                    return identity
                }
                guard let recorded else { throw PresentationPreferenceError.unsafe }
                try Self.removeTestObstruction(file, identity: recorded); return nil
            }
            do {
                let identity = try await filesystem.value
                // Retain cleanup authority even if the actual completed fixture belongs to a retired session.
                obstruction = identity
                guard services.catalogSession.session == session, epoch == capturedEpoch else { return }
                saveFixtureProbe = create ? "Obstruction blocked" : "Obstruction repaired"
            } catch {
                guard services.catalogSession.session == session, epoch == capturedEpoch else { return }
                saveFixtureProbe = "Obstruction unchanged"
            }
        }
        fixtureTask = work; if let operation { services.catalogSession.bind(operation) { work.cancel() } }
    }
    nonisolated private static func removeTestObstruction(_ file: URL, identity: ObstructionIdentity) throws {
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              UInt64(info.st_dev) == identity.device, UInt64(info.st_ino) == identity.inode else { throw PresentationPreferenceError.unsafe }
        guard unlink(file.path) == 0 else { throw PresentationPreferenceError.io }
    }
    func preserveInputsForTest() async {
        guard let services, services.usesSyntheticFixture, !services.isQuiescingCatalog else { return }
        do { if let saveTask { await saveTask.value }; try await store.flush() }
        catch { warning = "Inputs could not be saved. Current edits remain in memory." }
    }
    #endif
}

/// Visible semantic UUID anchors; no content names or pixel offsets are persisted.
struct PresentationAnchorKey: PreferenceKey {
    static var defaultValue: [String: [UUID: CGFloat]] = [:]
    static func reduce(value: inout [String: [UUID: CGFloat]], nextValue: () -> [String: [UUID: CGFloat]]) {
        for (section, anchors) in nextValue() { value[section, default: [:]].merge(anchors) { _, new in new } }
    }
}
extension View {
    @ViewBuilder func optionalPresentationAnchor(_ id: UUID?, section: String) -> some View {
        if let id { presentationAnchor(id, section: section) } else { self }
    }
    func presentationAnchor(_ id: UUID, section: String) -> some View {
        self.id(id).background(GeometryReader { proxy in
            Color.clear.preference(key: PresentationAnchorKey.self,
                value: [section: [id: proxy.frame(in: .named("catalog-scroll-" + section)).minY]])
        })
    }
}
