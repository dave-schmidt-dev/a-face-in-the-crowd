import Foundation
import AFITCCore

/// One cancellable query. Results and pagination retain the repository's immutable snapshot.
@MainActor
final class SearchService: ObservableObject {
    @Published private(set) var snapshot: SearchSnapshot?
    @Published private(set) var searching = false
    @Published private(set) var error: String?
    @Published private(set) var visibleResults: [SearchResult] = []
    private var task: Task<Void, Never>?
    private var generation = UUID()
    func invalidate() {
        generation = UUID(); task?.cancel(); task = nil
        searching = false; snapshot = nil; visibleResults = []; error = nil
    }
    func search(mode: SearchMode, selected: Set<UUID>, services: AppServices) {
        invalidate()
        let token = generation
        searching = true
        task = Task {
            do {
                let query = try PeopleQuery(mode: mode, selectedPersonIDs: selected)
                let result = try await services.searchSnapshot(query)
                try Task.checkCancellation()
                guard generation == token else { return }
                snapshot = result; visibleResults = try result.page(offset: 0)
            } catch is CancellationError { }
            catch {
                guard generation == token else { return }
                self.error = mode == .only && selected.isEmpty ? "Select at least one person for Only selected." : "Search unavailable. Try again."
            }
            guard generation == token else { return }
            searching = false; task = nil
        }
    }
    func nextPage() {
        guard let snapshot else { return }
        do { visibleResults += try snapshot.page(offset: visibleResults.count) }
        catch { self.error = "This page is unavailable." }
    }
}
