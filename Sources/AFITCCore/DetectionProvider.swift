import Foundation

public struct ProcessedPreview: Sendable {
    public let jpeg: Data
    public let analysis: FaceAnalysisState
    public init(jpeg: Data, analysis: FaceAnalysisState) { self.jpeg = jpeg; self.analysis = analysis }
}
/// Native implementation performs bounded orientation-aware decode and Vision locally.
public protocol DetectionProvider: Sendable {
    func process(_ data: Data, contentVersion: Int) async throws -> ProcessedPreview
}

import ImageIO
import UniformTypeIdentifiers

/// Bounded oriented decode: the full-resolution pixel buffer is never materialized.
public enum JPEGPreviewDecoder {
    public static func decode(_ data: Data) throws -> CGImage {
        guard data.count <= DecodeLimits.maximumFileBytes else { throw ScanError.oversized }
        try validateJPEGHeader(data)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw ScanError.malformed }
        try DecodeLimits.validate(bytes: data.count, width: width, height: height)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: DecodeLimits.previewDimension,
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw ScanError.malformed }
        return image
    }
    /// Reject enormous declared dimensions before ImageIO attempts metadata/codec work.
    private static func validateJPEGHeader(_ data: Data) throws {
        guard data.count >= 4, data[0] == 0xff, data[1] == 0xd8 else { throw ScanError.malformed }
        var cursor = 2
        let frames: Set<UInt8> = [0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf]
        while cursor + 3 < data.count {
            try Task.checkCancellation()
            guard data[cursor] == 0xff else { throw ScanError.malformed }
            while cursor < data.count && data[cursor] == 0xff { cursor += 1 }
            guard cursor + 2 < data.count else { throw ScanError.malformed }
            let marker = data[cursor]; cursor += 1
            if marker == 0xda || marker == 0xd9 { break }
            if marker == 0x01 || (0xd0...0xd7).contains(marker) { continue }
            let length = Int(data[cursor]) * 256 + Int(data[cursor + 1])
            guard length >= 2, length <= data.count - cursor else { throw ScanError.malformed }
            if frames.contains(marker) {
                guard length >= 8 else { throw ScanError.malformed }
                let height = Int(data[cursor + 3]) * 256 + Int(data[cursor + 4])
                let width = Int(data[cursor + 5]) * 256 + Int(data[cursor + 6])
                try DecodeLimits.validate(bytes: data.count, width: width, height: height)
                return
            }
            cursor += length
        }
        throw ScanError.malformed
    }
    public static func jpeg(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw ScanError.malformed }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ScanError.malformed }
        return output as Data
    }
}

import Vision

/// Actor serializes decode and Vision with no main-actor image processing.
public actor VisionJPEGDetector: DetectionProvider {
    public init() {}
    public func process(_ data: Data, contentVersion: Int) async throws -> ProcessedPreview {
        try Task.checkCancellation()
        return try autoreleasepool {
            let image = try JPEGPreviewDecoder.decode(data)
            let request = VNDetectFaceLandmarksRequest()
            request.revision = VNDetectFaceLandmarksRequestRevision3
            try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
            try Task.checkCancellation()
            let faces = (request.results ?? []).map { observation in
                let box = observation.boundingBox
                let points = observation.landmarks?.allPoints?.normalizedPoints.map {
                    [Double($0.x), Double($0.y)]
                } ?? []
                return FaceGeometry(rectangle: [box.origin.x, box.origin.y, box.width, box.height], landmarks: points)
            }
            let state = FaceAnalysisState(status: .successful, detectorVersion: "vision-landmarks-r3-preview1024-v1",
                                          contentVersion: contentVersion, faces: faces)
            return ProcessedPreview(jpeg: try JPEGPreviewDecoder.jpeg(image), analysis: state)
        }
    }
}
