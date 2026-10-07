import Accelerate
import Foundation

/// Order-independent pair identity for a durable "not in this group" separation.
public struct FaceGroupPair: Sendable, Hashable {
    public let first: FaceKey
    public let second: FaceKey
    public init(_ a: FaceKey, _ b: FaceKey) {
        if a.storageKey <= b.storageKey { first = a; second = b } else { first = b; second = a }
    }
}

/// Versioned, conservative grouping parameters derived from the shared matching threshold.
/// `representativeCap` bounds how many admitted members constrain later candidates so no
/// transitive chain can join a group. Work is always bounded by `maxComparisons`.
public struct FaceGroupingPolicy: Sendable, Equatable {
    public static let currentVersion = 1
    public let version: Int
    public let matchThreshold: Float
    public let ambiguityMargin: Float
    public let maxComparisons: Int
    public let maxGroups: Int
    public let maxMembers: Int
    public let representativeCap: Int
    public init(version: Int = FaceGroupingPolicy.currentVersion,
                matchThreshold: Float = SuggestionPolicy.evaluationDefault.minScore,
                ambiguityMargin: Float = SuggestionPolicy.evaluationDefault.minMargin,
                maxComparisons: Int = 2_000_000,
                maxGroups: Int = 20_000,
                maxMembers: Int = 2_000,
                representativeCap: Int = 8) {
        self.version = version
        self.matchThreshold = min(1, max(-1, matchThreshold))
        self.ambiguityMargin = max(0, ambiguityMargin)
        self.maxComparisons = max(0, maxComparisons)
        self.maxGroups = max(1, maxGroups)
        self.maxMembers = max(1, maxMembers)
        self.representativeCap = max(1, representativeCap)
    }
    public static let evaluationDefault = FaceGroupingPolicy()
}

/// One current face offered to the pure grouping engine with its durable first-analysis order.
public struct FaceGroupingFace: Sendable, Equatable {
    public let key: FaceKey
    public let firstAnalysisSequence: Int
    public let vector: [Float]
    public let state: ManualFaceState
    public let suppressed: Bool
    public init(key: FaceKey, firstAnalysisSequence: Int, vector: [Float],
                state: ManualFaceState, suppressed: Bool = false) {
        self.key = key; self.firstAnalysisSequence = firstAnalysisSequence; self.vector = vector
        self.state = state; self.suppressed = suppressed
    }
}

public struct FaceGroupingProgress: Sendable, Equatable {
    public let compared: Int
    public let groups: Int
    public let total: Int
    public init(compared: Int, groups: Int, total: Int) {
        self.compared = compared; self.groups = groups; self.total = total
    }
}

/// A provisional group whose identity is the durable seed FaceKey, never a person.
public struct FaceGroup: Sendable, Equatable, Identifiable {
    public let seed: FaceKey
    public let members: [FaceKey]
    public var id: String { seed.id }
    public init(seed: FaceKey, members: [FaceKey]) { self.seed = seed; self.members = members }
}

public struct FaceGroupingResult: Sendable, Equatable {
    public let revision: Int
    public let groups: [FaceGroup]
    public let assignments: [FaceKey: FaceKey]
    public let compared: Int
    public let ambiguous: Int
    public let incomplete: Bool
    public init(revision: Int, groups: [FaceGroup], assignments: [FaceKey: FaceKey],
                compared: Int, ambiguous: Int, incomplete: Bool) {
        self.revision = revision; self.groups = groups; self.assignments = assignments
        self.compared = compared; self.ambiguous = ambiguous; self.incomplete = incomplete
    }
    public func group(for face: FaceKey) -> FaceGroup? {
        guard let seed = assignments[face] else { return nil }
        return groups.first { $0.seed == seed }
    }
}

/// The shared possible-membership answer for one current face: a confirmed person when one is
/// suggested, otherwise the provisional group seed and its current member set.
public struct FaceMembership: Sendable, Equatable {
    public let face: FaceKey
    public let personID: UUID?
    public let groupSeed: FaceKey
    public let members: [FaceKey]
    public let score: Float?
    public let closestExemplar: FaceKey?
    public let ambiguous: Bool
    public init(face: FaceKey, personID: UUID?, groupSeed: FaceKey, members: [FaceKey],
                score: Float?, closestExemplar: FaceKey?, ambiguous: Bool) {
        self.face = face; self.personID = personID; self.groupSeed = groupSeed; self.members = members
        self.score = score; self.closestExemplar = closestExemplar; self.ambiguous = ambiguous
    }
}

/// One production membership result shared by provisional groups and Verify suggestions.
public struct FaceMembershipResult: Sendable, Equatable {
    public let revision: Int
    public let suggestions: [Suggestion]
    public let groups: [FaceGroup]
    public let memberships: [FaceKey: FaceMembership]
    public let compared: Int
    public let ambiguous: Int
    public let incomplete: Bool
    public init(revision: Int, suggestions: [Suggestion], groups: [FaceGroup],
                memberships: [FaceKey: FaceMembership], compared: Int, ambiguous: Int, incomplete: Bool) {
        self.revision = revision; self.suggestions = suggestions; self.groups = groups
        self.memberships = memberships; self.compared = compared; self.ambiguous = ambiguous
        self.incomplete = incomplete
    }
    public static let empty = FaceMembershipResult(revision: 0, suggestions: [], groups: [],
                                                   memberships: [:], compared: 0, ambiguous: 0, incomplete: false)
}

/// Internally consistent capture of people, current-generation durable analysis and constraints.
public struct FaceGroupingCapture: Sendable {
    public let revision: Int
    public let people: PeopleSnapshot
    public let rows: [FaceVectorRow]
    public let separations: Set<FaceGroupPair>
    public let suppressions: Set<FaceKey>
    public init(revision: Int, people: PeopleSnapshot, rows: [FaceVectorRow],
                separations: Set<FaceGroupPair>, suppressions: Set<FaceKey>) {
        self.revision = revision; self.people = people; self.rows = rows
        self.separations = separations; self.suppressions = suppressions
    }
}

/// Pure, deterministic, off-main provisional grouping. No SQL, no catalog access, no mutation.
public enum FaceGrouping {
    /// Greedy durable-order grouping: each face in first-analysis order joins the single best
    /// existing group it matches, otherwise it becomes a fixed seed. A candidate must match the
    /// seed and every admitted representative, never a chain of members. Same-photo faces and
    /// captured separations are excluded, near-ties across groups stay ambiguous, and every
    /// budget stop reports `incomplete` instead of guessing.
    public static func groups(faces: [FaceGroupingFace], separations: Set<FaceGroupPair> = [],
                              revision: Int = 0, policy: FaceGroupingPolicy = .evaluationDefault,
                              progress: (@Sendable (FaceGroupingProgress) -> Void)? = nil) throws -> FaceGroupingResult {
        let ordered = faces.sorted {
            $0.firstAnalysisSequence != $1.firstAnalysisSequence
                ? $0.firstAnalysisSequence < $1.firstAnalysisSequence
                : $0.key.storageKey < $1.key.storageKey
        }
        let eligible = ordered.filter {
            !$0.suppressed && !$0.state.notPerson && !$0.state.deferred &&
                !$0.vector.isEmpty
        }
        var groups: [FaceGroup] = []
        var groupFaces: [[FaceGroupingFace]] = []
        var members: [[FaceKey]] = []
        var memberSets: [Set<FaceKey>] = []
        var excluded: [FaceKey: Set<FaceKey>] = [:]
        for pair in separations {
            excluded[pair.first, default: []].insert(pair.second)
            excluded[pair.second, default: []].insert(pair.first)
        }
        var assignments: [FaceKey: FaceKey] = [:]
        var compared = 0
        var ambiguous = 0
        var incomplete = false
        let total = eligible.count
        var processed = 0
        var photoSets: [Set<UUID>] = []
        var labels: [Set<UUID>] = []
        var rejectedLabels: [Set<UUID>] = []
        faceLoop: for face in eligible {
            try Task.checkCancellation()
            processed += 1
            var ranked: [(group: Int, score: Float)] = []
            for index in groups.indices {
                try Task.checkCancellation()
                if compared >= policy.maxComparisons { incomplete = true; break faceLoop }
                compared += 1
                if photoSets[index].contains(face.key.photoID) { continue }
                let identities = labels[index]
                if let person = face.state.personID, !identities.isEmpty, !identities.contains(person) { continue }
                if !face.state.rejectedPeople.isDisjoint(with: identities) ||
                    !face.state.deferredPeople.isDisjoint(with: identities) { continue }
                if let person = face.state.personID, rejectedLabels[index].contains(person) { continue }
                if let blocked = excluded[face.key], !blocked.isDisjoint(with: memberSets[index]) { continue }
                var admission: Float = -1
                var admitted = true
                for representative in groupFaces[index].prefix(policy.representativeCap) {
                    if compared >= policy.maxComparisons { incomplete = true; break faceLoop }
                    let score = cosine(face.vector, representative.vector)
                    compared += 1
                    if score < policy.matchThreshold { admitted = false; break }
                    admission = admission < 0 ? score : min(admission, score)
                }
                if admitted { ranked.append((index, admission)) }
            }
            if !ranked.isEmpty {
                ranked.sort { $0.score != $1.score ? $0.score > $1.score : $0.group < $1.group }
                if ranked.count > 1, ranked[0].score - ranked[1].score < policy.ambiguityMargin {
                    ambiguous += 1
                    continue
                }
                let index = ranked[0].group
                if members[index].count >= policy.maxMembers { incomplete = true; continue }
                members[index].append(face.key)
                memberSets[index].insert(face.key)
                if groupFaces[index].count < policy.representativeCap { groupFaces[index].append(face) }
                photoSets[index].insert(face.key.photoID)
                rejectedLabels[index].formUnion(face.state.rejectedPeople)
                rejectedLabels[index].formUnion(face.state.deferredPeople)
                if let person = face.state.personID { labels[index].insert(person) }
                assignments[face.key] = groups[index].seed
            } else {
                if groups.count >= policy.maxGroups { incomplete = true; continue }
                groups.append(FaceGroup(seed: face.key, members: [face.key]))
                groupFaces.append([face])
                members.append([face.key])
                memberSets.append([face.key])
                photoSets.append([face.key.photoID])
                labels.append(Set(face.state.personID.map { [$0] } ?? []))
                rejectedLabels.append(face.state.rejectedPeople.union(face.state.deferredPeople))
                assignments[face.key] = face.key
            }
            if compared % 256 == 0 || processed == total {
                progress?(FaceGroupingProgress(compared: compared, groups: groups.count, total: total))
            }
        }
        let completed = groups.indices.map { FaceGroup(seed: groups[$0].seed, members: members[$0]) }
        progress?(FaceGroupingProgress(compared: compared, groups: groups.count, total: total))
        return FaceGroupingResult(revision: revision, groups: completed, assignments: assignments,
                                  compared: compared, ambiguous: ambiguous, incomplete: incomplete)
    }

    /// The one production possible-membership result. Person scoring is the same bounded
    /// nearest-exemplar policy the legacy API projects; provisional grouping is pure and bounded.
    public static func membership(snapshot: PeopleSnapshot, vectors: [FaceVectorKey: [Float]],
                                  separations: Set<FaceGroupPair> = [], suppressions: Set<FaceKey> = [],
                                  policy: SuggestionPolicy = .evaluationDefault,
                                  groupingPolicy: FaceGroupingPolicy = .evaluationDefault,
                                  progress: (@Sendable (FaceGroupingProgress) -> Void)? = nil) throws -> FaceMembershipResult {
        var sequences: [FaceKey: Int] = [:]
        for (index, item) in snapshot.faces.sorted(by: faceOrder).enumerated() { sequences[item.key] = index }
        return try membership(snapshot: snapshot, vectors: vectors, sequences: sequences, separations: separations,
                              suppressions: suppressions, policy: policy, groupingPolicy: groupingPolicy, progress: progress)
    }

    public static func membership(snapshot: PeopleSnapshot, rows: [FaceVectorRow],
                                  separations: Set<FaceGroupPair> = [], suppressions: Set<FaceKey> = [],
                                  policy: SuggestionPolicy = .evaluationDefault,
                                  groupingPolicy: FaceGroupingPolicy = .evaluationDefault,
                                  progress: (@Sendable (FaceGroupingProgress) -> Void)? = nil) throws -> FaceMembershipResult {
        var vectors: [FaceVectorKey: [Float]] = [:]
        var sequences: [FaceKey: Int] = [:]
        for row in rows {
            vectors[row.vectorKey] = row.vector
            sequences[row.faceKey] = row.firstAnalysisSequence
        }
        return try membership(snapshot: snapshot, vectors: vectors, sequences: sequences, separations: separations,
                              suppressions: suppressions, policy: policy, groupingPolicy: groupingPolicy, progress: progress)
    }

    static func membership(snapshot: PeopleSnapshot, vectors: [FaceVectorKey: [Float]],
                           sequences: [FaceKey: Int], separations: Set<FaceGroupPair>,
                           suppressions: Set<FaceKey>, policy: SuggestionPolicy,
                           groupingPolicy: FaceGroupingPolicy,
                           progress: (@Sendable (FaceGroupingProgress) -> Void)?) throws -> FaceMembershipResult {
        func vector(_ item: FaceItem) -> [Float]? {
            guard item.photo.missing != true, let hash = item.photo.contentHash, !hash.isEmpty else { return nil }
            return vectors[FaceVectorKey(face: item.key, modelIdentifier: policy.modelIdentifier,
                                         preprocessingVersion: policy.preprocessingVersion, contentHash: hash)]
        }
        let orderedFaces = snapshot.faces.sorted(by: faceOrder)
        var groupingFaces: [FaceGroupingFace] = []
        for item in orderedFaces {
            guard let values = vector(item) else { continue }
            groupingFaces.append(FaceGroupingFace(key: item.key,
                                                  firstAnalysisSequence: sequences[item.key] ?? Int.max,
                                                  vector: values, state: item.state,
                                                  suppressed: suppressions.contains(item.key)))
        }
        let grouping = try groups(faces: groupingFaces, separations: separations,
                                  revision: snapshot.revision, policy: groupingPolicy, progress: progress)
        let active = Dictionary(snapshot.people.map(\.person).filter { $0.mergedInto == nil }.map { ($0.id, $0) },
                                uniquingKeysWith: { first, _ in first })
        var anchors: [UUID: [(key: FaceKey, values: [Float])]] = [:]
        for item in orderedFaces {
            let state = item.state
            guard state.isAnchor, let person = state.personID, active[person] != nil, !state.notPerson,
                  !suppressions.contains(item.key), !state.rejectedPeople.contains(person),
                  let values = vector(item), anchors[person, default: []].count < policy.anchorCap else { continue }
            anchors[person, default: []].append((item.key, values))
        }
        var confirmedInPhoto: [UUID: Set<UUID>] = [:]
        for item in snapshot.faces {
            if let person = item.state.personID { confirmedInPhoto[item.key.photoID, default: []].insert(person) }
        }
        let people = anchors.keys.sorted { $0.uuidString < $1.uuidString }
        var compared = 0
        var scoreComparisons = grouping.compared
        var incomplete = grouping.incomplete
        var ambiguous = 0
        var ambiguousFaces = Set<FaceKey>()
        var best: [String: (item: FaceItem, suggestion: Suggestion)] = [:]
        candidateLoop: for item in orderedFaces {
            try Task.checkCancellation()
            let state = item.state
            guard state.personID == nil, !state.notPerson, !state.deferred, !suppressions.contains(item.key),
                  let candidate = vector(item) else { continue }
            let blocked = confirmedInPhoto[item.key.photoID, default: []]
            var scores: [(person: UUID, score: Float, exemplar: FaceKey)] = []
            for person in people where !state.rejectedPeople.contains(person) &&
                !state.deferredPeople.contains(person) && !blocked.contains(person) {
                let personAnchors = anchors[person]!
                if personAnchors.contains(where: { separations.contains(FaceGroupPair(item.key, $0.key)) }) { continue }
                var top: (score: Float, key: FaceKey)?
                for anchor in personAnchors {
                    try Task.checkCancellation()
                    guard scoreComparisons < groupingPolicy.maxComparisons else { incomplete = true; break candidateLoop }
                    scoreComparisons += 1
                    let score = cosine(candidate, anchor.values)
                    if top == nil || score > top!.score { top = (score, anchor.key) }
                }
                if let top { scores.append((person, top.score, top.key)) }
            }
            guard !scores.isEmpty else { continue }
            compared += 1
            let ranked = scores.enumerated().sorted { $0.element.score != $1.element.score
                ? $0.element.score > $1.element.score : $0.offset < $1.offset }.map(\.element)
            guard ranked[0].score >= policy.minScore else { continue }
            if ranked.count > 1, ranked[0].score - ranked[1].score < policy.minMargin {
                ambiguous += 1; ambiguousFaces.insert(item.key); continue
            }
            let person = active[ranked[0].person]!
            let suggestion = Suggestion(face: item.key, personID: person.id, exemplarRevision: person.exemplarRevision,
                                        expectedState: state, score: ranked[0].score, closestExemplar: ranked[0].exemplar)
            let slot = "\(item.key.photoID.uuidString)|\(person.id.uuidString)"
            if let existing = best[slot], existing.suggestion.score >= suggestion.score { continue }
            best[slot] = (item, suggestion)
        }
        let suggestions = best.values.sorted {
            $0.suggestion.score != $1.suggestion.score
                ? $0.suggestion.score > $1.suggestion.score : faceOrder($0.item, $1.item)
        }.map(\.suggestion)
        var personSeeds: [UUID: FaceKey] = [:]
        var personAnchors: [UUID: [FaceKey]] = [:]
        let durableAnchors = snapshot.faces.sorted { lhs, rhs in
            let left = sequences[lhs.key] ?? Int.max
            let right = sequences[rhs.key] ?? Int.max
            return left != right ? left < right : lhs.key.storageKey < rhs.key.storageKey
        }
        for item in durableAnchors where item.state.isAnchor {
            guard let person = item.state.personID, active[person] != nil, !item.state.notPerson,
                  !suppressions.contains(item.key), vector(item) != nil else { continue }
            personAnchors[person, default: []].append(item.key)
            if personSeeds[person] == nil { personSeeds[person] = item.key }
        }
        let groupsBySeed = Dictionary(uniqueKeysWithValues: grouping.groups.map { ($0.seed, $0) })
        let suggestionByFace = Dictionary(suggestions.map { ($0.face, $0) }, uniquingKeysWith: { first, _ in first })
        var memberships: [FaceKey: FaceMembership] = [:]
        for item in orderedFaces {
            guard vector(item) != nil, !suppressions.contains(item.key),
                  !item.state.notPerson, !item.state.deferred else { continue }
            let state = item.state
            let provisionalSeed = grouping.assignments[item.key]
            let provisionalGroup = provisionalSeed.flatMap { groupsBySeed[$0] }
            let groupMembers = provisionalGroup?.members ?? [item.key]
            if let suggestion = suggestionByFace[item.key] {
                memberships[item.key] = FaceMembership(face: item.key, personID: suggestion.personID,
                    groupSeed: provisionalSeed ?? item.key,
                    members: groupMembers,
                    score: suggestion.score, closestExemplar: suggestion.closestExemplar, ambiguous: false)
            } else if let person = state.personID, personSeeds[person] != nil {
                memberships[item.key] = FaceMembership(face: item.key, personID: person, groupSeed: provisionalSeed ?? item.key,
                    members: groupMembers, score: nil, closestExemplar: nil, ambiguous: false)
            } else {
                memberships[item.key] = FaceMembership(face: item.key, personID: nil,
                    groupSeed: provisionalSeed ?? item.key, members: provisionalGroup?.members ?? [item.key],
                    score: nil, closestExemplar: nil, ambiguous: ambiguousFaces.contains(item.key))
            }
        }
        return FaceMembershipResult(revision: snapshot.revision, suggestions: suggestions, groups: grouping.groups,
                                    memberships: memberships, compared: compared, ambiguous: ambiguous,
                                    incomplete: incomplete)
    }

    static func faceOrder(_ lhs: FaceItem, _ rhs: FaceItem) -> Bool {
        lhs.photo.relativePath != rhs.photo.relativePath ? lhs.photo.relativePath < rhs.photo.relativePath
            : lhs.key.faceID.uuidString < rhs.key.faceID.uuidString
    }

    /// Dot product of two unit vectors, clamped to the cosine range.
    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
        var result: Float = 0
        vDSP_dotpr(lhs, 1, rhs, 1, &result, vDSP_Length(lhs.count))
        return result.isFinite ? min(1, max(-1, result)) : -1
    }
}
