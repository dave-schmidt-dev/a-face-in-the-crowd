import Foundation
import SQLite3

public struct SearchRepository: Sendable {
    let catalog: CatalogRepository
    public init(catalog: CatalogRepository) { self.catalog = catalog }
    public func snapshot(query: PeopleQuery) async throws -> SearchSnapshot {
        try await catalog.searchSnapshot(query: query)
    }
}
extension CatalogRepository {
    public func searchSnapshot(query: PeopleQuery) throws -> SearchSnapshot {
        try searchSnapshot(query: query, afterRevisionRead: nil)
    }
    // The synchronous hook permits a causal two-handle snapshot test; no await crosses a transaction.
    func searchSnapshot(query: PeopleQuery, afterRevisionRead: (@Sendable () throws -> Void)?) throws -> SearchSnapshot {
        try peopleRead { db in
            let revision = try PeopleSQL.scalar(db, "SELECT revision FROM catalog_revision")
            try afterRevisionRead?()
            let people: [PersonRecord] = try SearchSQL.records(db, "SELECT payload,id FROM people")
            var byID: [UUID: PersonRecord] = [:]
            for person in people {
                guard byID.updateValue(person, forKey: person.id) == nil else { throw ScanError.database }
            }
            func canonical(_ id: UUID) throws -> UUID {
                var cursor = id; var visited = Set<UUID>()
                while true {
                    guard visited.insert(cursor).inserted else { throw SearchError.invalidAlias(id) }
                    guard let person = byID[cursor] else {
                        if cursor == id { throw SearchError.unknownPerson(id) }
                        throw SearchError.invalidAlias(id)
                    }
                    guard let next = person.mergedInto else { return cursor }; cursor = next
                }
            }
            let selected = try Set(query.selectedPersonIDs.map(canonical))
            let normalized = try PeopleQuery(mode: query.mode, selectedPersonIDs: selected)
            let selectedPeople = selected.sorted { $0.uuidString < $1.uuidString }.compactMap { byID[$0] }
            var photos: [UUID: PhotoIdentity] = [:]
            if selected.isEmpty {
                let all: [PhotoIdentity] = try SearchSQL.records(db, "SELECT payload,id FROM photos")
                for photo in all where photo.missing != true { photos[photo.id] = photo }
            } else {
                // Explicit archived UUIDs join their survivor. Unrelated broken aliases do not affect a selection.
                let aliases = people.compactMap { person -> String? in
                    guard let survivor = try? canonical(person.id), selected.contains(survivor) else { return nil }
                    return person.id.uuidString
                }.sorted()
                for start in stride(from: 0, to: aliases.count, by: 200) {
                    try Task.checkCancellation()
                    let chunk = Array(aliases[start..<min(start + 200, aliases.count)])
                    let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                    let candidates: [PhotoIdentity] = try SearchSQL.records(db, """
                    SELECT DISTINCT p.payload,p.id FROM manual_faces m INDEXED BY manual_faces_person
                    JOIN current_faces c ON c.key=m.key JOIN photos p ON p.id=c.photo_id
                    WHERE m.person_id IN (\(marks))
                    """, strings: chunk)
                    for photo in candidates where photo.missing != true { photos[photo.id] = photo }
                }
            }
            var results: [SearchResult] = []; var unresolved = 0; var extra = 0
            for photo in photos.values {
                try Task.checkCancellation()
                let keys: [FaceKey] = try PeopleSQL.rows(db, "SELECT payload FROM current_faces INDEXED BY current_faces_photo WHERE photo_id=?", strings: [photo.id.uuidString])
                let current = Set(keys)
                guard current.count == keys.count, keys.allSatisfy({ $0.photoID == photo.id }) else { throw ScanError.database }
                var confirmed = Set<UUID>()
                var resolved = photo.analysis.status == .successful && photo.analysis.contentVersion == photo.contentVersion && !photo.analysis.faces.isEmpty
                var rawIDs = Set<UUID>()
                for face in photo.analysis.faces {
                    let key = FaceKey(photo: photo, face: face)
                    guard rawIDs.insert(face.id).inserted, PeopleSQL.validGeometry(face.rectangle), current.contains(key),
                          photo.analysis.status == .successful, photo.analysis.contentVersion == photo.contentVersion else {
                        resolved = false; continue
                    }
                    guard try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM current_faces WHERE key=? AND photo_id=?", strings: [key.storageKey, photo.id.uuidString]) == 1 else { throw ScanError.database }
                    let state = try PeopleSQL.faceState(db, key)
                    guard state.key == key else { throw ScanError.database }
                    let relation = try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM manual_faces WHERE key=? AND COALESCE(person_id,'')=? AND anchor=?", strings: [key.storageKey, state.personID?.uuidString ?? "", state.isAnchor ? "1" : "0"])
                    if relation == 0, try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM manual_faces WHERE key=?", strings: [key.storageKey]) != 0 { throw ScanError.database }
                    if let personID = state.personID {
                        guard let person = try? canonical(personID) else { resolved = false; continue }
                        let rejected = Set(state.rejectedPeople.compactMap { try? canonical($0) })
                        let deferred = Set(state.deferredPeople.compactMap { try? canonical($0) })
                        guard !state.notPerson, !state.deferred, !rejected.contains(person), !deferred.contains(person) else {
                            resolved = false; continue
                        }
                        confirmed.insert(person)
                    } else if !state.notPerson || state.deferred {
                        resolved = false
                    }
                }
                if !resolved { unresolved += 1 }
                if !confirmed.subtracting(selected).isEmpty { extra += 1 }
                let matches: Bool
                switch query.mode {
                case .together: matches = selected.isSubset(of: confirmed)
                case .any: matches = selected.isEmpty || !selected.isDisjoint(with: confirmed)
                case .only: matches = resolved && confirmed == selected
                }
                if matches { results.append(SearchResult(photo: photo, confirmedPersonIDs: confirmed)) }
            }
            results.sort {
                switch ($0.photo.captureDate?.localWallClock, $1.photo.captureDate?.localWallClock) {
                case let (a?, b?) where a != b: return a < b
                case (_?, nil): return true
                case (nil, _?): return false
                default: return $0.photo.id.uuidString < $1.photo.id.uuidString
                }
            }
            return SearchSnapshot(revision: revision, query: normalized, selectedPeople: selectedPeople,
                                  results: results, coverage: SearchCoverage(candidatePhotoCount: photos.count,
                                  unresolvedCandidatePhotoCount: unresolved, extraPeopleCandidatePhotoCount: extra))
        }
    }
}

/// Validate relational IDs alongside JSON payloads before publishing a snapshot.
private enum SearchSQL {
    static func records<T: Decodable & Identifiable>(_ db: OpaquePointer, _ sql: String, strings: [String] = []) throws -> [T] where T.ID == UUID {
        let statement = try PeopleSQL.statement(db, sql, strings: strings)
        defer { sqlite3_finalize(statement) }
        var records: [T] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            try Task.checkCancellation()
            let size = Int(sqlite3_column_bytes(statement, 0))
            guard size > 0, let bytes = sqlite3_column_blob(statement, 0),
                  let rawID = sqlite3_column_text(statement, 1), let id = UUID(uuidString: String(cString: rawID)) else { throw ScanError.database }
            let value = try JSONDecoder().decode(T.self, from: Data(bytes: bytes, count: size))
            guard value.id == id else { throw ScanError.database }
            records.append(value); status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw CatalogSchema.failure(db) }
        return records
    }
}
