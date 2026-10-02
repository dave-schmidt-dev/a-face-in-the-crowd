import Foundation

public struct UndoService: Sendable {
    let catalog: CatalogRepository
    public init(catalog: CatalogRepository) { self.catalog = catalog }
    public func undo(_ id: UUID) async throws { try await catalog.undoDecision(id) }
}
extension CatalogRepository {
    public func undoDecision(_ id: UUID) throws { try undoDecision(id, failure: nil) }
    func undoDecision(_ id: UUID, failure: DecisionFailurePoint?) throws {
        try peopleTransaction { db in
            let records: [DecisionRecord] = try PeopleSQL.rows(db, "SELECT payload FROM decisions WHERE id=? AND undo_of IS NULL", strings: [id.uuidString])
            guard let record = records.first else { throw DecisionError.nothingToUndo }
            guard try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM decisions WHERE undo_of=?", strings: [id.uuidString]) == 0 else { throw DecisionError.conflict }
            for face in record.after.allFaces { _ = try PeopleSQL.currentPhoto(db, face.key) }
            for face in record.after.allFaces {
                guard try PeopleSQL.faceState(db, face.key) == face else { throw DecisionError.conflict }
            }
            for person in record.after.people {
                guard try PeopleSQL.person(db, person.id).matchesDomain(person) else { throw DecisionError.conflict }
            }
            if let created = record.createdPersonID {
                let key = record.after.face?.key.storageKey ?? ""
                guard try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM manual_faces WHERE key!=? AND person_id=?", strings: [key, created.uuidString]) == 0,
                      try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM pair_negatives WHERE face_key!=? AND person_id=?", strings: [key, created.uuidString]) == 0,
                      try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM deferrals WHERE face_key!=? AND scope=?", strings: [key, created.uuidString]) == 0 else { throw DecisionError.conflict }
            }
            if record.kind == "merge" {
                let ids = Set(record.after.people.map(\.id))
                let keys: [FaceKey] = try PeopleSQL.rows(db, "SELECT payload FROM current_faces ORDER BY key")
                var targeted: [ManualFaceState] = []
                for key in keys {
                    let state = try PeopleSQL.faceState(db, key)
                    if state.personID.map({ ids.contains($0) }) == true ||
                        !state.rejectedPeople.isDisjoint(with: ids) || !state.deferredPeople.isDisjoint(with: ids) {
                        targeted.append(state)
                    }
                }
                guard targeted == record.after.allFaces else { throw DecisionError.conflict }
            }
            var actualAfter = record.after
            actualAfter.people = try record.after.people.map { try PeopleSQL.person(db, $0.id) }
            var restoredPeople = record.before.people
            for index in restoredPeople.indices {
                if let cover = restoredPeople[index].cover,
                   record.before.allFaces.contains(where: { $0.key == cover && $0.personID == restoredPeople[index].id && $0.isAnchor }) {
                    _ = try PeopleSQL.currentPhoto(db, cover)
                }
                let current = try PeopleSQL.person(db, restoredPeople[index].id)
                restoredPeople[index].exemplarRevision = max(current.exemplarRevision, restoredPeople[index].exemplarRevision) + 1
                try PeopleSQL.writePerson(db, restoredPeople[index])
            }
            if failure == .afterPersonWrite { throw DecisionError.injectedFailure }
            for face in record.before.allFaces { try PeopleSQL.writeFace(db, face) }
            if let created = record.createdPersonID { try PeopleSQL.run(db, "DELETE FROM people WHERE id=?", strings: [created.uuidString]) }
            if failure == .afterFaceWrite { throw DecisionError.injectedFailure }
            var restored = record.before; restored.people = restoredPeople
            let inverse = DecisionRecord(id: UUID(), kind: "undo", before: actualAfter, after: restored,
                createdPersonID: nil, date: Date(), revision: try PeopleSQL.scalar(db, "SELECT revision FROM catalog_revision") + 1, undoOf: id)
            try PeopleSQL.run(db, "INSERT INTO decisions(id,undo_of,payload) VALUES(?,?,?)", strings: [inverse.id.uuidString, id.uuidString], data: JSONEncoder().encode(inverse))
            if failure == .afterLedgerWrite { throw DecisionError.injectedFailure }
        }
    }
}
