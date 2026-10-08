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
    /// Names and labels every safe member of the pinned conservative group atomically.
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
    /// Labels every safe member of the pinned group to an existing person. The selected cover
    /// becomes one training anchor; other newly assigned members remain non-anchors.
    public func labelGroup(cover: FaceKey, group: FaceGroupSnapshot, personID: UUID,
                           exemplarRevision: Int) throws -> UUID {
        try applyDecision(.labelGroup(cover: cover, group: group, personID: personID, exemplarRevision: exemplarRevision))
    }

    static func applyGroupExclusion(_ db: OpaquePointer, face: FaceKey, group: FaceGroupSnapshot,
                                    failure: DecisionFailurePoint?) throws -> UUID {
        guard let selectedState = group.state(for: face) else { throw DecisionError.conflict }
        let people = Set(group.expectedStates.compactMap(\.personID))
        guard people.count <= 1 else { throw DecisionError.conflict }
        let groupPerson = people.first
        let states = try checkedLabelGroupStates(db, cover: face, group: group, targetPersonID: groupPerson)
        var beforePairs = Set<FaceGroupPair>()
        var afterPairs = Set<FaceGroupPair>()
        for member in group.members where member != face {
            try Task.checkCancellation()
            let pair = FaceGroupPair(face, member)
            if try FaceAnalysisSQL.areSeparated(db, keyA: face.storageKey, keyB: member.storageKey) {
                beforePairs.insert(pair)
            }
            afterPairs.insert(pair)
        }

        let person = try groupPerson.map { try PeopleSQL.person(db, $0) }
        if let person, person.mergedInto != nil { throw DecisionError.conflict }
        let shouldUnassign = groupPerson != nil && selectedState.personID == groupPerson
        var updatedPerson = person
        var updatedStates = states
        if shouldUnassign, let groupPerson, let index = updatedStates.firstIndex(where: { $0.key == face }) {
            var corrected = updatedStates[index]
            corrected.personID = nil
            corrected.isAnchor = false
            corrected.rejectedPeople.insert(groupPerson)
            corrected.deferredPeople.remove(groupPerson)
            corrected.deferred = false
            updatedStates[index] = corrected

            var replacement = updatedPerson!
            if replacement.cover == face {
                replacement.cover = try replacementAnchor(db, person: groupPerson, excluding: face)
            }
            replacement.exemplarRevision = try CatalogCounters.successor(replacement.exemplarRevision, minimum: 1)
            updatedPerson = replacement
            try PeopleSQL.writePerson(db, replacement)
        }
        if failure == .afterPersonWrite, shouldUnassign { throw DecisionError.injectedFailure }
        if shouldUnassign, let index = updatedStates.firstIndex(where: { $0.key == face }) {
            try PeopleSQL.writeFace(db, updatedStates[index])
        }
        let now = Date()
        for pair in afterPairs {
            try FaceAnalysisSQL.recordSeparation(db, keyA: pair.first.storageKey, keyB: pair.second.storageKey, createdAt: now)
        }
        if failure == .afterFaceWrite { throw DecisionError.injectedFailure }
        let beforeEffect = DecisionEffect(people: person.map { [$0] } ?? [], face: nil, faces: states)
        let afterEffect = DecisionEffect(people: updatedPerson.map { [$0] } ?? [], face: nil, faces: updatedStates)
        let record = DecisionRecord(id: UUID(), kind: "group-exclude", before: beforeEffect, after: afterEffect,
            createdPersonID: nil, date: Date(),
            revision: try CatalogCounters.successor(CatalogCounters.read(db, .revision)), undoOf: nil,
            separationsBefore: separationRecords(beforePairs), separationsAfter: separationRecords(afterPairs))
        try PeopleSQL.run(db, "INSERT INTO decisions(id,payload,undo_of) VALUES(?,?,NULL)", strings: [record.id.uuidString], data: JSONEncoder().encode(record))
        if failure == .afterLedgerWrite { throw DecisionError.injectedFailure }
        return record.id
    }

    static func checkedLabelGroupStates(_ db: OpaquePointer, cover: FaceKey, group: FaceGroupSnapshot,
                                        targetPersonID: UUID?) throws -> [ManualFaceState] {
        let keys = Set(group.members)
        let assignedPeople = Set(group.expectedStates.compactMap(\.personID))
        guard !group.members.isEmpty, keys.count == group.members.count,
              group.members.contains(group.seed), keys.contains(cover),
              group.expectedStates.count == group.members.count,
              Set(group.expectedStates.map(\.key)) == keys,
              Set(group.members.map(\.photoID)).count == group.members.count,
              assignedPeople.count <= 1,
              targetPersonID.map({ assignedPeople.isSubset(of: [$0]) }) ?? assignedPeople.isEmpty else {
            throw DecisionError.conflict
        }

        let bindingRows: [String?] = try PeopleSQL.rows(db, "SELECT payload FROM source_binding WHERE singleton=1")
        guard bindingRows.count == 1 else { throw DecisionError.conflict }
        let sourceBinding = bindingRows[0]
        let policy = SuggestionPolicy.evaluationDefault
        var states: [ManualFaceState] = []
        states.reserveCapacity(group.expectedStates.count)
        for captured in group.expectedStates {
            try Task.checkCancellation()
            let photo = try PeopleSQL.currentPhoto(db, captured.key)
            let suppressed = try FaceAnalysisSQL.isSuppressed(db, faceKey: captured.key.storageKey)
            guard try PeopleSQL.faceState(db, captured.key) == captured,
                  !captured.notPerson, !captured.deferred,
                  let hash = photo.contentHash, !hash.isEmpty,
                  let vector = try FaceAnalysisSQL.vectorRow(db, faceKey: captured.key.storageKey),
                  vector.photoID == photo.id, vector.contentVersion == photo.contentVersion,
                  vector.contentHash == hash, vector.sourceBinding == sourceBinding,
                  vector.modelIdentifier == policy.modelIdentifier,
                  vector.preprocessingVersion == policy.preprocessingVersion,
                  !suppressed else {
                throw DecisionError.conflict
            }
            if let targetPersonID {
                guard captured.personID == nil || captured.personID == targetPersonID,
                      !captured.rejectedPeople.contains(targetPersonID),
                      !captured.deferredPeople.contains(targetPersonID) else { throw DecisionError.conflict }
            } else {
                guard captured.personID == nil, !captured.isAnchor else { throw DecisionError.conflict }
            }
            states.append(captured)
        }

        let memberKeys = Set(group.members.map(\.storageKey))
        for separation in try FaceAnalysisSQL.allSeparations(db) {
            guard !(memberKeys.contains(separation.faceKeyA.storageKey) &&
                    memberKeys.contains(separation.faceKeyB.storageKey)) else { throw DecisionError.conflict }
        }
        return states
    }

    static func applyGroupName(_ db: OpaquePointer, cover: FaceKey, group: FaceGroupSnapshot,
                               displayName: String, failure: DecisionFailurePoint?) throws -> UUID {
        let value = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 120,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DecisionError.invalidName
        }
        let states = try checkedLabelGroupStates(db, cover: cover, group: group, targetPersonID: nil)
        let person = PersonRecord(displayName: value, cover: cover)
        let updatedStates = states.map { state -> ManualFaceState in
            var updated = state
            updated.personID = person.id
            updated.isAnchor = state.key == cover
            return updated
        }
        try PeopleSQL.writePerson(db, person)
        if failure == .afterPersonWrite { throw DecisionError.injectedFailure }
        for state in updatedStates { try PeopleSQL.writeFace(db, state) }
        if failure == .afterFaceWrite { throw DecisionError.injectedFailure }
        let record = DecisionRecord(id: UUID(), kind: "name",
            before: DecisionEffect(people: [], face: nil, faces: states),
            after: DecisionEffect(people: [person], face: nil, faces: updatedStates),
            createdPersonID: person.id, date: Date(),
            revision: try CatalogCounters.successor(CatalogCounters.read(db, .revision)), undoOf: nil)
        try PeopleSQL.run(db, "INSERT INTO decisions(id,payload,undo_of) VALUES(?,?,NULL)", strings: [record.id.uuidString], data: JSONEncoder().encode(record))
        if failure == .afterLedgerWrite { throw DecisionError.injectedFailure }
        return record.id
    }

    static func applyGroupLabel(_ db: OpaquePointer, cover: FaceKey, group: FaceGroupSnapshot,
                                personID: UUID, exemplarRevision: Int,
                                failure: DecisionFailurePoint?) throws -> UUID {
        let person = try PeopleSQL.person(db, personID)
        guard person.mergedInto == nil, person.exemplarRevision == exemplarRevision else { throw DecisionError.conflict }
        let states = try checkedLabelGroupStates(db, cover: cover, group: group, targetPersonID: personID)
        let updatedStates = states.map { state -> ManualFaceState in
            var updated = state
            updated.personID = personID
            if state.key == cover { updated.isAnchor = true }
            return updated
        }
        var updatedPerson = person
        if try !hasValidCurrentAnchorCover(db, person: person) {
            updatedPerson.cover = cover
        }
        updatedPerson.exemplarRevision = try CatalogCounters.successor(updatedPerson.exemplarRevision, minimum: 1)
        try PeopleSQL.writePerson(db, updatedPerson)
        if failure == .afterPersonWrite { throw DecisionError.injectedFailure }
        for state in updatedStates { try PeopleSQL.writeFace(db, state) }
        if failure == .afterFaceWrite { throw DecisionError.injectedFailure }
        let record = DecisionRecord(id: UUID(), kind: "group-label",
            before: DecisionEffect(people: [person], face: nil, faces: states),
            after: DecisionEffect(people: [updatedPerson], face: nil, faces: updatedStates),
            createdPersonID: nil, date: Date(),
            revision: try CatalogCounters.successor(CatalogCounters.read(db, .revision)), undoOf: nil)
        try PeopleSQL.run(db, "INSERT INTO decisions(id,payload,undo_of) VALUES(?,?,NULL)", strings: [record.id.uuidString], data: JSONEncoder().encode(record))
        if failure == .afterLedgerWrite { throw DecisionError.injectedFailure }
        return record.id
    }

    static func hasValidCurrentAnchorCover(_ db: OpaquePointer, person: PersonRecord) throws -> Bool {
        guard let cover = person.cover else { return false }
        do {
            _ = try PeopleSQL.currentPhoto(db, cover)
        } catch let error as DecisionError where error == .staleFace {
            return false
        }
        let state = try PeopleSQL.faceState(db, cover)
        return state.personID == person.id && state.isAnchor && !state.notPerson && !state.deferred &&
            !state.rejectedPeople.contains(person.id) && !state.deferredPeople.contains(person.id)
    }

    static func replacementAnchor(_ db: OpaquePointer, person: UUID, excluding face: FaceKey) throws -> FaceKey? {
        let anchors: [ManualFaceState] = try PeopleSQL.rows(db, """
            SELECT m.payload FROM manual_faces m JOIN current_faces c ON c.key=m.key
            WHERE m.person_id=? AND m.anchor=1 AND m.key!=? ORDER BY c.rowid
            """, strings: [person.uuidString, face.storageKey])
        return anchors.first {
            $0.personID == person && $0.isAnchor && !$0.notPerson && !$0.deferred &&
                !$0.rejectedPeople.contains(person) && !$0.deferredPeople.contains(person)
        }?.key
    }

    /// All inspected states and generations are validated before the first write. The ledger
    /// carries every affected face, so Undo restores the whole batch or refuses it atomically.
    static func applyGroupConfirmation(_ db: OpaquePointer, group: FaceGroupSnapshot,
                                       personID: UUID, exemplarRevision: Int,
                                       failure: DecisionFailurePoint?) throws -> UUID {
        let person = try PeopleSQL.person(db, personID)
        guard person.mergedInto == nil, person.exemplarRevision == exemplarRevision,
              !group.members.isEmpty, Set(group.members).count == group.members.count,
              Set(group.members) == Set(group.expectedStates.map(\.key)),
              group.members.count == group.expectedStates.count, group.members.contains(group.seed) else { throw DecisionError.conflict }
        for state in group.expectedStates {
            try Task.checkCancellation()
            _ = try PeopleSQL.currentPhoto(db, state.key)
            guard try PeopleSQL.faceState(db, state.key) == state,
                  state.personID == nil || state.personID == personID,
                  !state.notPerson, !state.deferred, !state.rejectedPeople.contains(personID),
                  !state.deferredPeople.contains(personID) else { throw DecisionError.conflict }
        }
        var updatedPerson = person
        updatedPerson.exemplarRevision = try CatalogCounters.successor(person.exemplarRevision, minimum: 1)
        if updatedPerson.cover == nil { updatedPerson.cover = group.seed }
        let updated = group.expectedStates.map { state -> ManualFaceState in
            var value = state; value.personID = personID; value.isAnchor = true
            return value
        }
        try PeopleSQL.writePerson(db, updatedPerson)
        if failure == .afterPersonWrite { throw DecisionError.injectedFailure }
        for state in updated { try PeopleSQL.writeFace(db, state) }
        if failure == .afterFaceWrite { throw DecisionError.injectedFailure }
        let record = DecisionRecord(id: UUID(), kind: "group-confirm",
            before: DecisionEffect(people: [person], face: nil, faces: group.expectedStates),
            after: DecisionEffect(people: [updatedPerson], face: nil, faces: updated),
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
