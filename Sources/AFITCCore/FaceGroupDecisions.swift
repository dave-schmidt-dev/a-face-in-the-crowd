import Foundation
import SQLite3

/// Pinned group state captured when a reviewer inspected the group. Guards compare these exact
/// face states and current generations, never an unrelated catalog revision.
public struct FaceGroupSnapshot: Sendable, Equatable {
    public let seed: FaceKey
    public let members: [FaceKey]
    public let expectedStates: [ManualFaceState]
    public init(seed: FaceKey, members: [FaceKey], expectedStates: [ManualFaceState]) {
        self.seed = seed; self.members = members; self.expectedStates = expectedStates
    }
    public func state(for key: FaceKey) -> ManualFaceState? {
        expectedStates.first { $0.key == key }
    }
}

extension FaceGroup {
    /// Builds the pinned snapshot only when every inspected member still has a captured state.
    public func snapshot(states: [FaceKey: ManualFaceState]) -> FaceGroupSnapshot? {
        let expected = members.compactMap { states[$0] }
        guard expected.count == members.count else { return nil }
        return FaceGroupSnapshot(seed: seed, members: members, expectedStates: expected)
    }
}

extension CatalogRepository {
    /// Names exactly the inspected cover under both the pinned group and manual-state guards.
    public func nameGroup(cover: FaceKey, group: FaceGroupSnapshot, displayName: String) throws -> UUID {
        guard let state = group.state(for: cover) else { throw DecisionError.conflict }
        return try applyDecision(.expectingState(.nameGroup(cover: cover, group: group, displayName: displayName),
                                                expectedState: state))
    }
    /// Durable "not in this group" correction. Separations are written against every inspected
    /// member, so removing or reseeding the seed never erases the exclusion.
    public func excludeGroupMember(face: FaceKey, group: FaceGroupSnapshot) throws -> UUID {
        try applyDecision(.excludeGroupMember(face: face, group: group))
    }
    /// Labels the pinned group to an existing person. Aggregation happens through that person;
    /// no person is created and no person merge is implied.
    public func labelGroup(cover: FaceKey, group: FaceGroupSnapshot, personID: UUID,
                           exemplarRevision: Int) throws -> UUID {
        try applyDecision(.labelGroup(cover: cover, group: group, personID: personID, exemplarRevision: exemplarRevision))
    }

    static func applyGroupExclusion(_ db: OpaquePointer, face: FaceKey, group: FaceGroupSnapshot,
                                    failure: DecisionFailurePoint?) throws -> UUID {
        var inspected = Set<FaceKey>()
        for state in group.expectedStates {
            guard inspected.insert(state.key).inserted else { throw DecisionError.conflict }
            _ = try PeopleSQL.currentPhoto(db, state.key)
            guard try PeopleSQL.faceState(db, state.key) == state else { throw DecisionError.conflict }
        }
        guard inspected.contains(face), Set(group.members) == inspected, group.members.contains(group.seed) else { throw DecisionError.conflict }
        _ = try PeopleSQL.currentPhoto(db, face)
        var beforePairs = Set<FaceGroupPair>()
        var afterPairs = Set<FaceGroupPair>()
        for member in group.members where member != face {
            let pair = FaceGroupPair(face, member)
            if try FaceAnalysisSQL.areSeparated(db, keyA: face.storageKey, keyB: member.storageKey) {
                beforePairs.insert(pair)
            }
            try FaceAnalysisSQL.recordSeparation(db, keyA: face.storageKey, keyB: member.storageKey, createdAt: Date())
            afterPairs.insert(pair)
        }
        if failure == .afterFaceWrite { throw DecisionError.injectedFailure }
        let effect = DecisionEffect(people: [], face: nil, faces: group.expectedStates)
        let record = DecisionRecord(id: UUID(), kind: "group-exclude", before: effect, after: effect,
            createdPersonID: nil, date: Date(),
            revision: try CatalogCounters.successor(CatalogCounters.read(db, .revision)), undoOf: nil,
            separationsBefore: separationRecords(beforePairs), separationsAfter: separationRecords(afterPairs))
        try PeopleSQL.run(db, "INSERT INTO decisions(id,payload,undo_of) VALUES(?,?,NULL)", strings: [record.id.uuidString], data: JSONEncoder().encode(record))
        if failure == .afterLedgerWrite { throw DecisionError.injectedFailure }
        return record.id
    }

    static func applyGroupLabel(_ db: OpaquePointer, cover: FaceKey, group: FaceGroupSnapshot,
                                personID: UUID, exemplarRevision: Int,
                                failure: DecisionFailurePoint?) throws -> UUID {
        let person = try PeopleSQL.person(db, personID)
        guard person.mergedInto == nil, person.exemplarRevision == exemplarRevision else { throw DecisionError.conflict }
        var inspected = Set<FaceKey>()
        var states: [ManualFaceState] = []
        for state in group.expectedStates {
            guard inspected.insert(state.key).inserted else { throw DecisionError.conflict }
            _ = try PeopleSQL.currentPhoto(db, state.key)
            guard try PeopleSQL.faceState(db, state.key) == state else { throw DecisionError.conflict }
            states.append(state)
        }
        guard inspected.contains(cover), group.members.contains(group.seed),
              Set(group.members) == inspected, states.count == group.members.count else { throw DecisionError.conflict }
        let coverState = states.first { $0.key == cover }!
        let updatedStates = [coverState].map { state -> ManualFaceState in
            var updated = state
            updated.personID = personID; updated.isAnchor = true
            updated.notPerson = false; updated.deferred = false
            updated.rejectedPeople.remove(personID); updated.deferredPeople.remove(personID)
            return updated
        }
        var updatedPerson = person
        if updatedPerson.cover == nil || !states.contains(where: { $0.key == updatedPerson.cover }) {
            updatedPerson.cover = cover
        }
        updatedPerson.exemplarRevision = try CatalogCounters.successor(updatedPerson.exemplarRevision, minimum: 1)
        try PeopleSQL.writePerson(db, updatedPerson)
        if failure == .afterPersonWrite { throw DecisionError.injectedFailure }
        for state in updatedStates { try PeopleSQL.writeFace(db, state) }
        if failure == .afterFaceWrite { throw DecisionError.injectedFailure }
        let record = DecisionRecord(id: UUID(), kind: "group-label",
            before: DecisionEffect(people: [person], face: nil, faces: [coverState]),
            after: DecisionEffect(people: [updatedPerson], face: nil, faces: updatedStates),
            createdPersonID: nil, date: Date(),
            revision: try CatalogCounters.successor(CatalogCounters.read(db, .revision)), undoOf: nil)
        try PeopleSQL.run(db, "INSERT INTO decisions(id,payload,undo_of) VALUES(?,?,NULL)", strings: [record.id.uuidString], data: JSONEncoder().encode(record))
        if failure == .afterLedgerWrite { throw DecisionError.injectedFailure }
        return record.id
    }

    static func separationRecords(_ pairs: Set<FaceGroupPair>) -> [GroupSeparationRecord] {
        pairs.sorted {
            $0.first.storageKey != $1.first.storageKey
                ? $0.first.storageKey < $1.first.storageKey
                : $0.second.storageKey < $1.second.storageKey
        }.map { GroupSeparationRecord(faceKeyA: $0.first, faceKeyB: $0.second) }
    }
}
