import Foundation
import AFITCCore

/// Native app facade; shares the SDK Vision pipeline exercised by core fixtures.
actor FaceDetectionService: DetectionProvider {
    private let detector = VisionJPEGDetector()
    func process(_ data: Data, contentVersion: Int) async throws -> ProcessedPreview {
        try await detector.process(data, contentVersion: contentVersion)
    }
}
