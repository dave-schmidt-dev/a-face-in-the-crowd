import Foundation

/// Injected ranking parameters. `evaluationDefault` values are uncalibrated evaluation settings;
/// recognition is not qualified (INV-9) and Task 2.2 owns calibration.
///
/// `SuggestionEngine` no longer ranks independently: it projects the one production
/// `FaceMembershipResult` computed by `FaceGrouping` (provisional groups plus person membership)
/// into the legacy card API.
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

/// Pure, deterministic projection over a people snapshot and a vector index snapshot.
/// No SQL, no catalog access, no mutation; safe to call off the main actor.
public enum SuggestionEngine {
    public static func suggestions(snapshot: PeopleSnapshot, index: FaceVectorIndex,
                                   policy: SuggestionPolicy = .evaluationDefault) -> SuggestionResult {
        suggestions(snapshot: snapshot, vectors: index.snapshot(), policy: policy)
    }

    static func suggestions(snapshot: PeopleSnapshot, vectors: [FaceVectorKey: [Float]],
                            policy: SuggestionPolicy) -> SuggestionResult {
        guard let membership = try? FaceGrouping.membership(snapshot: snapshot, vectors: vectors, policy: policy) else {
            return SuggestionResult(suggestions: [], compared: 0, ambiguous: 0)
        }
        return SuggestionResult(suggestions: membership.suggestions, compared: membership.compared,
                                ambiguous: membership.ambiguous)
    }
}
