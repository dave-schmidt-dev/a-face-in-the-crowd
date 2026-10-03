import Foundation

/// Stable initial-scan identity. Reconciliation must create a new content generation.
public struct PhotoIdentity: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let relativePath: String
    public let dateAdded: Date
    public let contentVersion: Int
    public var previewPath: String?
    public var metadata: SourceMetadata?
    public var contentHash: String?
    public var missing: Bool?
    public var verifiedAt: Date?
    public var captureDate: CaptureDateMetadata?
    public var analysis: FaceAnalysisState
    public init(id: UUID = UUID(), relativePath: String, dateAdded: Date = Date(),
                contentVersion: Int = 1, previewPath: String? = nil,
                analysis: FaceAnalysisState = .pending, metadata: SourceMetadata? = nil,
                contentHash: String? = nil, missing: Bool? = nil, verifiedAt: Date? = nil,
                captureDate: CaptureDateMetadata? = nil) {
        self.id = id; self.relativePath = relativePath; self.dateAdded = dateAdded
        self.contentVersion = contentVersion; self.previewPath = previewPath; self.analysis = analysis
        self.metadata = metadata; self.contentHash = contentHash; self.missing = missing; self.verifiedAt = verifiedAt
        self.captureDate = captureDate
    }
}
