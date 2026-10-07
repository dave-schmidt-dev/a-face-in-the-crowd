import Foundation
import SQLite3

/// A possible result records both the confirmed subset and the provisional named identities.
/// Its photo and annotations belong to the same immutable capture as confirmed results.
public struct PossibleSearchResult: Sendable {
    public let photo: PhotoIdentity
    public let confirmedPersonIDs: Set<UUID>
    public let possiblePersonIDs: Set<UUID>
}

public struct FaceGroupSearchSnapshot: Sendable {
    public let confirmed: SearchSnapshot
    public let membership: FaceMembershipResult
    public let possibleResults: [PossibleSearchResult]
    public var revision: Int { confirmed.revision }
    public var possibleCount: Int { possibleResults.count }
    public func possiblePage(offset: Int, limit: Int = 60) throws -> [PossibleSearchResult] {
        guard offset >= 0, (1...200).contains(limit) else { throw SearchError.invalidPage }
        guard offset < possibleResults.count else { return [] }
        return Array(possibleResults[offset..<(offset + min(limit, possibleResults.count - offset))])
    }
}

extension CatalogRepository {
    /// Freezes confirmed Search, all photo records and grouping input in one SQL read, then
    /// uses the existing membership engine off-main. A matching shared result can be reused.
    public func faceGroupSearchSnapshot(query: PeopleQuery,
                                        sharedMembership: FaceMembershipResult? = nil) async throws -> FaceGroupSearchSnapshot {
        try await faceGroupSearchSnapshot(query: query, sharedMembership: sharedMembership, afterRevisionRead: nil)
    }
    func faceGroupSearchSnapshot(query: PeopleQuery, sharedMembership: FaceMembershipResult? = nil,
                                 afterRevisionRead: (@Sendable () throws -> Void)?) async throws -> FaceGroupSearchSnapshot {
        let capture = try peopleRead { db in
            let confirmed = try Self.confirmedSearchSnapshot(db, query: query, afterRevisionRead: afterRevisionRead)
            let grouping = try Self.captureFaceGrouping(db, modelIdentifier: SuggestionPolicy.evaluationDefault.modelIdentifier,
                                                        preprocessingVersion: SuggestionPolicy.evaluationDefault.preprocessingVersion)
            let photos: [PhotoIdentity] = try SearchSQL.records(db, "SELECT payload,id FROM photos")
            return (confirmed, grouping, photos.filter { $0.missing != true })
        }
        let worker = Task.detached {
            try Task.checkCancellation()
            let membership: FaceMembershipResult
            if let sharedMembership, sharedMembership.revision == capture.0.revision {
                membership = sharedMembership
            } else {
                let value = capture.1
                membership = try FaceGrouping.membership(snapshot: value.people, rows: value.rows,
                    separations: value.separations, suppressions: value.suppressions, analysisIncomplete: value.analysisIncomplete)
            }
            return try Self.combineGroupSearch(confirmed: capture.0, membership: membership,
                                                people: capture.1.people, photos: capture.2)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    static func combineGroupSearch(confirmed: SearchSnapshot, membership: FaceMembershipResult,
                                   people: PeopleSnapshot, photos: [PhotoIdentity]) throws -> FaceGroupSearchSnapshot {
        guard confirmed.revision == membership.revision, people.revision == confirmed.revision else { throw ScanError.database }
        // Only remains entirely confirmed and unresolved-safe. Provisional identities can
        // neither resolve unknown faces nor establish absence of another person.
        guard confirmed.query.mode != .only, !confirmed.query.selectedPersonIDs.isEmpty else {
            return FaceGroupSearchSnapshot(confirmed: confirmed, membership: membership, possibleResults: [])
        }
        let records = Dictionary(uniqueKeysWithValues: people.people.map { ($0.id, $0.person) })
        func canonical(_ id: UUID) -> UUID? {
            var value = id, seen = Set<UUID>()
            while seen.insert(value).inserted {
                guard let person = records[value] else { return nil }
                guard let next = person.mergedInto else { return value }; value = next
            }
            return nil
        }
        var confirmedByPhoto: [UUID: Set<UUID>] = [:]
        var possibleByPhoto: [UUID: Set<UUID>] = [:]
        for face in people.faces {
            try Task.checkCancellation()
            let state = face.state
            if let assigned = state.personID.flatMap(canonical), !state.notPerson, !state.deferred,
               !Set(state.rejectedPeople.compactMap(canonical)).contains(assigned),
               !Set(state.deferredPeople.compactMap(canonical)).contains(assigned) {
                confirmedByPhoto[face.photo.id, default: []].insert(assigned)
            } else if state.personID == nil, !state.notPerson, !state.deferred,
                      let possible = membership.memberships[face.key]?.personID.flatMap(canonical),
                      !Set(state.rejectedPeople.compactMap(canonical)).contains(possible),
                      !Set(state.deferredPeople.compactMap(canonical)).contains(possible) {
                possibleByPhoto[face.photo.id, default: []].insert(possible)
            }
        }
        let confirmedIDs = Set(confirmed.orderedPhotoIDs)
        let selected = confirmed.query.selectedPersonIDs
        var results: [PossibleSearchResult] = []
        for photo in photos where !confirmedIDs.contains(photo.id) {
            try Task.checkCancellation()
            let known = confirmedByPhoto[photo.id] ?? []
            let possible = possibleByPhoto[photo.id] ?? []
            let combined = known.union(possible)
            let matches = confirmed.query.mode == .together ? selected.isSubset(of: combined) : !selected.isDisjoint(with: combined)
            if matches, !possible.intersection(selected).isEmpty {
                results.append(PossibleSearchResult(photo: photo, confirmedPersonIDs: known, possiblePersonIDs: possible))
            }
        }
        results.sort {
            switch ($0.photo.captureDate?.localWallClock, $1.photo.captureDate?.localWallClock) {
            case let (a?, b?) where a != b: return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.photo.id.uuidString < $1.photo.id.uuidString
            }
        }
        return FaceGroupSearchSnapshot(confirmed: confirmed, membership: membership, possibleResults: results)
    }
}
