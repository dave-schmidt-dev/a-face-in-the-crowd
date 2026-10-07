import Foundation
import AFITCCore

/// One cancellable query. Results and pagination retain the repository's immutable snapshot.
@MainActor
final class SearchService: ObservableObject {
    @Published private(set) var snapshot: SearchSnapshot?
    @Published private(set) var groupedSnapshot: FaceGroupSearchSnapshot?
    @Published private(set) var visiblePossibleResults: [PossibleSearchResult] = []
    @Published private(set) var searching = false
    @Published private(set) var error: String?
    @Published private(set) var visibleResults: [SearchResult] = []
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private weak var services: AppServices?
    private var snapshotSession: UInt64?
    func cancelInFlight() {
        generation = UUID(); task?.cancel(); task = nil; searching = false
    }
    func invalidate() {
        cancelInFlight()
        snapshot = nil; groupedSnapshot = nil; visibleResults = []; visiblePossibleResults = []; error = nil; snapshotSession = nil
    }
    func search(mode: SearchMode, selected: Set<UUID>, services: AppServices, requestedPages: Int = 1) {
        invalidate()
        guard let operation = services.catalogSession.begin("search") else { return }
        self.services = services
        let token = generation
        searching = true
        let request = Task {
            defer { services.catalogSession.finish(operation) }
            do {
                let query = try PeopleQuery(mode: mode, selectedPersonIDs: selected)
                let result = try await services.faceGroupSearchSnapshot(query, session: operation.session)
                #if DEBUG
                await services.holdSessionWork(operation)
                #endif
                try Task.checkCancellation()
                guard generation == token, services.sessionIsCurrent(operation.session) else { return }
                groupedSnapshot = result; snapshot = result.confirmed
                visibleResults = try result.confirmed.page(offset: 0)
                visiblePossibleResults = try result.possiblePage(offset: 0)
                snapshotSession = operation.session
                for _ in 1..<max(1, min(64, requestedPages)) where visibleResults.count < result.confirmed.totalCount {
                    visibleResults += try result.confirmed.page(offset: visibleResults.count)
                }
            } catch is CancellationError { }
            catch {
                guard generation == token, services.sessionIsCurrent(operation.session) else { return }
                self.error = mode == .only && selected.isEmpty ? "Select at least one person for Only selected." : "Search unavailable. Try again."
            }
            guard generation == token, services.sessionIsCurrent(operation.session) else { return }
            searching = false; task = nil
        }
        task = request
        services.catalogSession.bind(operation) { [weak self] in request.cancel(); self?.invalidate() }
    }
    /// Metadata decisions request a fresh capture with the same filters. Existing value
    /// snapshots remain immutable; returning to Search never starts source/model work.
    func refreshIfNeeded(services: AppServices) {
        guard let snapshot, snapshot.revision < services.peopleSnapshot.revision else { return }
        search(mode: snapshot.query.mode, selected: snapshot.query.selectedPersonIDs,
               services: services, requestedPages: services.presentation.preferences.search.requestedPages)
    }
    func nextPage() {
        guard let snapshot, let snapshotSession, services?.sessionIsCurrent(snapshotSession) == true else {
            invalidate(); return
        }
        do { visibleResults += try snapshot.page(offset: visibleResults.count) }
        catch { self.error = "This page is unavailable." }
    }
    /// Independent cursor over the same immutable capture, without a repository/source read.
    func nextPossiblePage() {
        guard let groupedSnapshot, let snapshotSession, services?.sessionIsCurrent(snapshotSession) == true else {
            invalidate(); return
        }
        do { visiblePossibleResults += try groupedSnapshot.possiblePage(offset: visiblePossibleResults.count) }
        catch { self.error = "This possible-match page is unavailable." }
    }

}
