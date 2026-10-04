import Foundation

public enum ManualDecision: Sendable {
    case name(face: FaceKey, displayName: String)
    case confirm(face: FaceKey, personID: UUID)
    case reject(face: FaceKey, personID: UUID)
    case unsure(face: FaceKey, personID: UUID?)
    case unassign(face: FaceKey)
    case notPerson(face: FaceKey)
    case rename(personID: UUID, displayName: String)
}
public enum DecisionFailurePoint: String, Sendable, CaseIterable {
    case afterPersonWrite, afterFaceWrite, afterLedgerWrite
}
struct DecisionEffect: Codable, Sendable, Equatable {
    var people: [PersonRecord]
    var face: ManualFaceState?
    var faces: [ManualFaceState]? = nil
    var allFaces: [ManualFaceState] { faces ?? face.map { [$0] } ?? [] }
}
struct DecisionRecord: Codable, Sendable {
    let id: UUID
    let kind: String
    let before: DecisionEffect
    let after: DecisionEffect
    let createdPersonID: UUID?
    let date: Date
    let revision: Int
    let undoOf: UUID?
    var mergeResolutions: [MergeResolution]? = nil
}
public struct DecisionService: Sendable {
    let catalog: CatalogRepository
    public init(catalog: CatalogRepository) { self.catalog = catalog }
    public func apply(_ decision: ManualDecision) async throws -> UUID {
        try await catalog.applyDecision(decision)
    }
}

extension CatalogRepository {
    public func applyDecision(_ decision: ManualDecision) throws -> UUID {
        try applyDecision(decision, failure: nil)
    }
    /// Internal deterministic failure injection cannot be selected by the product UI.
    func applyDecision(_ decision: ManualDecision, failure: DecisionFailurePoint?) throws -> UUID {
        try peopleTransaction { db in
            var key: FaceKey?
            var target: UUID?
            var name: String?
            let kind: String
            switch decision {
            case .name(let face, let value): key = face; name = value; kind = "name"
            case .confirm(let face, let person): key = face; target = person; kind = "confirm"
            case .reject(let face, let person): key = face; target = person; kind = "reject"
            case .unsure(let face, let person): key = face; target = person; kind = "unsure"
            case .unassign(let face): key = face; kind = "unassign"
            case .notPerson(let face): key = face; kind = "not-person"
            case .rename(let person, let value): target = person; name = value; kind = "rename"
            }
            if let name {
                let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, value.count <= 120, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw DecisionError.invalidName }
            }
            var state: ManualFaceState?
            if let key { _ = try PeopleSQL.currentPhoto(db, key); state = try PeopleSQL.faceState(db, key) }
            var ids = Set<UUID>()
            if let previous = state?.personID { ids.insert(previous) }
            if let target { ids.insert(target) }
            let priorPeople = try ids.map { try PeopleSQL.person(db, $0) }.sorted { $0.id.uuidString < $1.id.uuidString }
            guard priorPeople.allSatisfy({ $0.mergedInto == nil }) else { throw DecisionError.unknownPerson }
            var people = priorPeople
            var created: UUID?
            if kind == "name", let key, let name {
                let person = PersonRecord(displayName: name.trimmingCharacters(in: .whitespacesAndNewlines), cover: key)
                created = person.id; target = person.id; people.append(person)
            }
            let before = DecisionEffect(people: priorPeople, face: state)
            if kind == "rename", let target, let name {
                let index = people.firstIndex { $0.id == target }!
                people[index].displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if var face = state {
                switch kind {
                case "name", "confirm":
                    face.personID = target; face.isAnchor = true; face.notPerson = false; face.deferred = false
                    if let target { face.rejectedPeople.remove(target); face.deferredPeople.remove(target) }
                case "reject":
                    if face.personID == target { face.personID = nil; face.isAnchor = false }
                    face.rejectedPeople.insert(target!); face.deferredPeople.remove(target!); face.deferred = false
                case "unsure":
                    if target == nil || face.personID == target { face.personID = nil; face.isAnchor = false }
                    face.notPerson = false
                    if let target { face.deferredPeople.insert(target) } else { face.deferred = true }
                case "unassign": face.personID = nil; face.isAnchor = false
                case "not-person": face.personID = nil; face.isAnchor = false; face.notPerson = true; face.deferred = false
                default: break
                }
                state = face
                for index in people.indices {
                    if people[index].id == before.face?.personID || people[index].id == face.personID {
                        people[index].exemplarRevision = try CatalogCounters.successor(people[index].exemplarRevision, minimum: 1)
                    }
                    if people[index].cover == key, people[index].id != face.personID { people[index].cover = nil }
                    if people[index].id == face.personID, people[index].cover == nil { people[index].cover = key }
                }
            }
            for person in people { try PeopleSQL.writePerson(db, person) }
            if failure == .afterPersonWrite { throw DecisionError.injectedFailure }
            if let state { try PeopleSQL.writeFace(db, state) }
            if failure == .afterFaceWrite { throw DecisionError.injectedFailure }
            let record = DecisionRecord(id: UUID(), kind: kind, before: before,
                after: DecisionEffect(people: people, face: state), createdPersonID: created, date: Date(),
                revision: try CatalogCounters.successor(CatalogCounters.read(db, .revision)), undoOf: nil)
            try PeopleSQL.run(db, "INSERT INTO decisions(id,payload,undo_of) VALUES(?,?,NULL)", strings: [record.id.uuidString], data: JSONEncoder().encode(record))
            if failure == .afterLedgerWrite { throw DecisionError.injectedFailure }
            return record.id
        }
    }
}

public enum MergeChoice: String, Codable, Sendable { case keepConfirmation, keepRejection }
public struct MergeResolution: Codable, Sendable {
    public let key: FaceKey
    public let choice: MergeChoice
    public init(key: FaceKey, choice: MergeChoice) { self.key = key; self.choice = choice }
}
public struct MergePreview: Sendable {
    public let source: PersonRecord
    public let survivor: PersonRecord
    public let faces: [FaceItem]
    public let conflicts: [FaceKey]
    public let sourcePhotoCount: Int
    public let survivorPhotoCount: Int
    public let combinedPhotoCount: Int
    let effect: DecisionEffect
}
public enum MergeFailurePoint: Sendable, CaseIterable {
    case afterFaceWrite, afterArchiveWrite, afterLedgerWrite
}

extension DecisionService {
    public func previewMerge(source: UUID, survivor: UUID) async throws -> MergePreview {
        try await catalog.previewMerge(source: source, survivor: survivor)
    }
    public func merge(_ preview: MergePreview, resolutions: [MergeResolution]) async throws -> UUID {
        try await catalog.mergePeople(preview, resolutions: resolutions)
    }
}

extension CatalogRepository {
    public func previewMerge(source: UUID, survivor: UUID) throws -> MergePreview {
        try peopleRead { db in try Self.mergePreview(db, source: source, survivor: survivor) }
    }
    private static func mergePreview(_ db: OpaquePointer, source: UUID, survivor: UUID) throws -> MergePreview {
        guard source != survivor else { throw DecisionError.conflict }
        let people = try [PeopleSQL.person(db, source), PeopleSQL.person(db, survivor)]
        guard people.allSatisfy({ $0.mergedInto == nil }) else { throw DecisionError.unknownPerson }
        // A temporarily unavailable same-generation effect could reappear unchanged. Require
        // it to be current before merging, so neither conflicts nor archived confirmations hide.
        let stored: [ManualFaceState] = try PeopleSQL.rows(db, "SELECT payload FROM manual_faces ORDER BY key")
        for state in stored where state.personID == source || state.personID == survivor ||
            !state.rejectedPeople.isDisjoint(with: [source, survivor]) || !state.deferredPeople.isDisjoint(with: [source, survivor]) {
            if try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM current_faces WHERE key=?", strings: [state.key.storageKey]) == 0 {
                let photos: [PhotoIdentity] = try PeopleSQL.rows(db, "SELECT payload FROM photos WHERE id=?", strings: [state.key.photoID.uuidString])
                if let photo = photos.first, photo.contentVersion == state.key.contentVersion,
                   photo.analysis.detectorVersion == state.key.detectorVersion,
                   photo.analysis.faces.contains(where: { $0.id == state.key.faceID }) { throw DecisionError.staleFace }
            }
        }
        let keys: [FaceKey] = try PeopleSQL.rows(db, "SELECT payload FROM current_faces ORDER BY key")
        var faces: [FaceItem] = []
        for key in keys {
            let state = try PeopleSQL.faceState(db, key)
            guard state.personID == source || state.personID == survivor ||
                    !state.rejectedPeople.isDisjoint(with: [source, survivor]) ||
                    !state.deferredPeople.isDisjoint(with: [source, survivor]) else { continue }
            guard state.personID.map({ !state.rejectedPeople.contains($0) }) ?? true else { throw DecisionError.conflict }
            let photo = try PeopleSQL.currentPhoto(db, key)
            faces.append(FaceItem(key: key, photo: photo, geometry: photo.analysis.faces.first { $0.id == key.faceID }!, state: state))
        }
        let conflicts = faces.filter {
            ($0.state.personID == source && $0.state.rejectedPeople.contains(survivor)) ||
            ($0.state.personID == survivor && $0.state.rejectedPeople.contains(source))
        }.map(\.key)
        let sourcePhotos = Set(faces.filter { $0.state.personID == source }.map { $0.key.photoID })
        let survivorPhotos = Set(faces.filter { $0.state.personID == survivor }.map { $0.key.photoID })
        return MergePreview(source: people[0], survivor: people[1], faces: faces, conflicts: conflicts,
            sourcePhotoCount: sourcePhotos.count, survivorPhotoCount: survivorPhotos.count,
            combinedPhotoCount: sourcePhotos.union(survivorPhotos).count,
            effect: DecisionEffect(people: people, face: nil, faces: faces.map(\.state)))
    }
    public func mergePeople(_ preview: MergePreview, resolutions: [MergeResolution]) throws -> UUID {
        try mergePeople(preview, resolutions: resolutions, failure: nil)
    }
    func mergePeople(_ preview: MergePreview, resolutions: [MergeResolution], failure: MergeFailurePoint?) throws -> UUID {
        try peopleTransaction { db in
            // Reload complete targeted membership under the write transaction, never trust a UI snapshot.
            for face in preview.faces { _ = try PeopleSQL.currentPhoto(db, face.key) }
            let current = try Self.mergePreview(db, source: preview.source.id, survivor: preview.survivor.id)
            guard current.effect == preview.effect, Set(current.conflicts) == Set(preview.conflicts),
                  resolutions.count == current.conflicts.count,
                  Set(resolutions.map(\.key)) == Set(current.conflicts) else { throw DecisionError.conflict }
            var choices: [FaceKey: MergeChoice] = [:]
            for resolution in resolutions {
                guard choices.updateValue(resolution.choice, forKey: resolution.key) == nil else { throw DecisionError.conflict }
            }
            let source = current.source.id, survivor = current.survivor.id
            var states = current.effect.allFaces
            for index in states.indices {
                let confirmed = states[index].personID == source || states[index].personID == survivor
                let rejected = states[index].rejectedPeople.contains(source) || states[index].rejectedPeople.contains(survivor)
                let deferred = states[index].deferredPeople.contains(source) || states[index].deferredPeople.contains(survivor)
                states[index].rejectedPeople.remove(source); states[index].rejectedPeople.remove(survivor)
                states[index].deferredPeople.remove(source); states[index].deferredPeople.remove(survivor)
                if confirmed {
                    if choices[states[index].key] == .keepRejection {
                        states[index].personID = nil; states[index].isAnchor = false
                        states[index].rejectedPeople.insert(survivor)
                    } else {
                        states[index].personID = survivor
                        // Confirmation resolves same-pair uncertainty, not unrelated-person deferrals.
                        states[index].deferred = false
                    }
                } else {
                    if rejected { states[index].rejectedPeople.insert(survivor) }
                    if deferred { states[index].deferredPeople.insert(survivor) }
                }
                guard states[index].personID != survivor || !states[index].rejectedPeople.contains(survivor) else { throw DecisionError.conflict }
                try PeopleSQL.writeFace(db, states[index])
            }
            if failure == .afterFaceWrite { throw DecisionError.injectedFailure }
            var people = current.effect.people
            people[0].mergedInto = survivor; people[0].cover = nil
            let eligible = states.filter { $0.personID == survivor && $0.isAnchor }.map(\.key)
            if !eligible.contains(where: { $0 == people[1].cover }) { people[1].cover = eligible.first }
            for index in people.indices { people[index].exemplarRevision = try CatalogCounters.successor(people[index].exemplarRevision, minimum: 1); try PeopleSQL.writePerson(db, people[index]) }
            if failure == .afterArchiveWrite { throw DecisionError.injectedFailure }
            var record = DecisionRecord(id: UUID(), kind: "merge", before: current.effect,
                after: DecisionEffect(people: people, face: nil, faces: states), createdPersonID: nil,
                date: Date(), revision: try CatalogCounters.successor(CatalogCounters.read(db, .revision)), undoOf: nil)
            record.mergeResolutions = resolutions
            try PeopleSQL.run(db, "INSERT INTO decisions(id,payload,undo_of) VALUES(?,?,NULL)", strings: [record.id.uuidString], data: JSONEncoder().encode(record))
            if failure == .afterLedgerWrite { throw DecisionError.injectedFailure }
            return record.id
        }
    }
}
