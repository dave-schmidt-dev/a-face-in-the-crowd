import Foundation
import ImageIO
import AFITCCore

/// App facade shares the exact bounded decoder exercised by the headless gate.
enum PreviewService {
    static func decode(_ data: Data) throws -> CGImage { try JPEGPreviewDecoder.decode(data) }
    static func jpeg(_ image: CGImage) throws -> Data { try JPEGPreviewDecoder.jpeg(image) }
}
