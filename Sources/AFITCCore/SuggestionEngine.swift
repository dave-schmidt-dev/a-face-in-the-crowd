import Accelerate
import Foundation

/// Injected ranking parameters. `evaluationDefault` values are uncalibrated evaluation settings;
/// recognition is not qualified (INV-9) and Task 2.2 owns calibration.
///
/// Rules applied by `SuggestionEngine`:
/// - A person's score is the maximum cosine over that person's first `anchorCap` embedded anchors
///   (ordered by photo path, then face UUID).
/// - People already confirmed on another face of the candidate's photo are excluded for that
///   candidate, as are pair-rejected and pair-deferred people.
/// - A candidate is ambiguous, skipped and counted when its best score reaches `minScore` and any
///   second-best person scores within `minMargin` of it, whether or not that second score
///   reaches `minScore`.
public struct SuggestionPolicy: Sendable, Equatable {
    public let minScore: Float
    public let minMargin: Float
    public let anchorCap: Int
    public let modelIdentifier: String
    public let preprocessingVersion: String
    public init(minScore: Float, minMargin: Float, anchorCap: Int,
                manifest: ModelManifest = .openCVSFace2021December) {
        self.minScore = minScore; self.minMargin = minMargin; self.anchorCap = max(1, anchorCap)
        self.modelIdentifier = manifest.identifier; self.preprocessingVersion = manifest.preprocessingVersion
    }
    /// Evaluation-only defaults: floor 0.45, margin 0.05, 50 anchors per person.
    public static let evaluationDefault = SuggestionPolicy(minScore: 0.45, minMargin: 0.05, anchorCap: 50)
}

/// One evaluation suggestion. It carries everything a guarded confirm needs to prove the card
/// is still current; it never confirms anything by itself.
public struct Suggestion: Sendable, Equatable, Identifiable {
    public let face: FaceKey
    public let personID: UUID
    /// The suggested person's `exemplarRevision` at compute time.
    public let exemplarRevision: Int
    /// The candidate's manual state at compute time.
    public let expectedState: ManualFaceState
    public let score: Float
    /// The suggested person's anchor that produced `score`.
    public let closestExemplar: FaceKey
    public var id: String { face.id }
}

/// Ranked suggestions plus non-identifying counts for the empty and ambiguous states.
public struct SuggestionResult: Sendable, Equatable {
    public let suggestions: [Suggestion]
    /// Candidates with a fresh vector scored against at least one eligible person.
    public let compared: Int
    /// Candidates skipped because the best and second-best people were within the margin.
    public let ambiguous: Int
}

/// Pure, deterministic ranking over a people snapshot and a vector index snapshot.
/// No SQL, no catalog access, no mutation; safe to call off the main actor.
public enum SuggestionEngine {
    public static func suggestions(snapshot: PeopleSnapshot, index: FaceVectorIndex,
                                   policy: SuggestionPolicy = .evaluationDefault) -> SuggestionResult {
        suggestions(snapshot: snapshot, vectors: index.snapshot(), policy: policy)
    }

    static func suggestions(snapshot: PeopleSnapshot, vectors: [FaceVectorKey: [Float]],
                            policy: SuggestionPolicy) -> SuggestionResult {
        func vector(_ item: FaceItem) -> [Float]? {
            guard item.photo.missing != true, let hash = item.photo.contentHash, !hash.isEmpty else { return nil }
            return vectors[FaceVectorKey(face: item.key, modelIdentifier: policy.modelIdentifier,
                                         preprocessingVersion: policy.preprocessingVersion, contentHash: hash)]
        }
        func ordered(_ lhs: FaceItem, _ rhs: FaceItem) -> Bool {
            lhs.photo.relativePath != rhs.photo.relativePath ? lhs.photo.relativePath < rhs.photo.relativePath
                : lhs.key.faceID.uuidString < rhs.key.faceID.uuidString
        }
        let active = Dictionary(snapshot.people.map(\.person).filter { $0.mergedInto == nil }.map { ($0.id, $0) },
                                uniquingKeysWith: { first, _ in first })
        var anchors: [UUID: [(key: FaceKey, values: [Float])]] = [:]
        for item in snapshot.faces.sorted(by: ordered) {
            let state = item.state
            guard state.isAnchor, let person = state.personID, active[person] != nil, !state.notPerson,
                  !state.rejectedPeople.contains(person), let values = vector(item),
                  anchors[person, default: []].count < policy.anchorCap else { continue }
            anchors[person, default: []].append((item.key, values))
        }
        var confirmedInPhoto: [UUID: Set<UUID>] = [:]
        for item in snapshot.faces {
            if let person = item.state.personID { confirmedInPhoto[item.key.photoID, default: []].insert(person) }
        }
        let people = anchors.keys.sorted { $0.uuidString < $1.uuidString }
        var compared = 0, ambiguous = 0
        var best: [String: (item: FaceItem, suggestion: Suggestion)] = [:]
        for item in snapshot.faces.sorted(by: ordered) {
            let state = item.state
            guard state.personID == nil, !state.notPerson, !state.deferred, let candidate = vector(item) else { continue }
            let blocked = confirmedInPhoto[item.key.photoID, default: []]
            var scores: [(person: UUID, score: Float, exemplar: FaceKey)] = []
            for person in people where !state.rejectedPeople.contains(person) &&
                !state.deferredPeople.contains(person) && !blocked.contains(person) {
                var top: (score: Float, key: FaceKey)?
                for anchor in anchors[person]! {
                    let score = cosine(candidate, anchor.values)
                    if top == nil || score > top!.score { top = (score, anchor.key) }
                }
                if let top { scores.append((person, top.score, top.key)) }
            }
            guard !scores.isEmpty else { continue }
            compared += 1
            // Stable sort keeps person-UUID order for exact ties.
            let ranked = scores.enumerated().sorted { $0.element.score != $1.element.score
                ? $0.element.score > $1.element.score : $0.offset < $1.offset }.map(\.element)
            guard ranked[0].score >= policy.minScore else { continue }
            if ranked.count > 1, ranked[0].score - ranked[1].score < policy.minMargin { ambiguous += 1; continue }
            let person = active[ranked[0].person]!
            let suggestion = Suggestion(face: item.key, personID: person.id, exemplarRevision: person.exemplarRevision,
                                        expectedState: state, score: ranked[0].score, closestExemplar: ranked[0].exemplar)
            // One face per person per photo: keep the highest score; ties keep the earlier face.
            let slot = "\(item.key.photoID.uuidString)|\(person.id.uuidString)"
            if let existing = best[slot], existing.suggestion.score >= suggestion.score { continue }
            best[slot] = (item, suggestion)
        }
        let suggestions = best.values.sorted {
            $0.suggestion.score != $1.suggestion.score ? $0.suggestion.score > $1.suggestion.score : ordered($0.item, $1.item)
        }.map(\.suggestion)
        return SuggestionResult(suggestions: suggestions, compared: compared, ambiguous: ambiguous)
    }

    /// Dot product of two unit vectors, clamped to the cosine range.
    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
        var result: Float = 0
        vDSP_dotpr(lhs, 1, rhs, 1, &result, vDSP_Length(lhs.count))
        return result.isFinite ? min(1, max(-1, result)) : -1
    }
}
