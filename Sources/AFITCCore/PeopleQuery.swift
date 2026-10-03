import Foundation

public enum SearchMode: String, Sendable, Codable { case together, any, only }
public enum SearchError: Error, Sendable, Equatable {
    case emptyOnlySelection, unknownPerson(UUID), invalidAlias(UUID), invalidPage
}
/// A selection contains stable person UUIDs, never names or suggested identities.
public struct PeopleQuery: Sendable, Equatable {
    public let mode: SearchMode
    public let selectedPersonIDs: Set<UUID>
    public init(mode: SearchMode, selectedPersonIDs: Set<UUID>) throws {
        guard mode != .only || !selectedPersonIDs.isEmpty else { throw SearchError.emptyOnlySelection }
        self.mode = mode; self.selectedPersonIDs = selectedPersonIDs
    }
}
public struct SearchResult: Sendable {
    public let photo: PhotoIdentity
    public let confirmedPersonIDs: Set<UUID>
}
public struct SearchCoverage: Sendable {
    public let candidatePhotoCount: Int
    public let unresolvedCandidatePhotoCount: Int
    public let extraPeopleCandidatePhotoCount: Int
}
/// Records, names, counts and pagination belong to one SQLite read revision.
public struct SearchSnapshot: Sendable {
    public let revision: Int
    public let query: PeopleQuery
    public let selectedPeople: [PersonRecord]
    public let results: [SearchResult]
    public let coverage: SearchCoverage
    public var totalCount: Int { results.count }
    public var orderedPhotoIDs: [UUID] { results.map { $0.photo.id } }
    public func page(offset: Int, limit: Int = 60) throws -> [SearchResult] {
        guard offset >= 0, (1...200).contains(limit) else { throw SearchError.invalidPage }
        guard offset < results.count else { return [] }
        return Array(results[offset..<(offset + min(limit, results.count - offset))])
    }
}
