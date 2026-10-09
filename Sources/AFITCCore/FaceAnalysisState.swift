import Foundation

public enum AnalysisStatus: String, Codable, Sendable { case pending, successful, skipped, failed }
public struct FaceGeometry: Codable, Sendable, Equatable {
    public let id: UUID
    public let rectangle: [Double]
    public let landmarks: [[Double]]
    public init(id: UUID = UUID(), rectangle: [Double], landmarks: [[Double]]) {
        self.id = id; self.rectangle = rectangle; self.landmarks = landmarks
    }
    /// False for rectangles outside the photo: they never enter current_faces or the fence.
    public var isIndexable: Bool { PeopleSQL.validGeometry(rectangle) }
}
/// A successful zero-face index is not an assertion that a photo has no people.
public struct FaceAnalysisState: Codable, Sendable, Equatable {
    public let status: AnalysisStatus
    public let detectorVersion: String
    public let contentVersion: Int
    public let faces: [FaceGeometry]
    public let reason: String?
    public static let pending = FaceAnalysisState(status: .pending)
    public init(status: AnalysisStatus, detectorVersion: String = "vision-landmarks-v1",
                contentVersion: Int = 1, faces: [FaceGeometry] = [], reason: String? = nil) {
        self.status = status; self.detectorVersion = detectorVersion
        self.contentVersion = contentVersion; self.faces = faces; self.reason = reason
    }
}
