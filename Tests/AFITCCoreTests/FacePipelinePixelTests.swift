import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AFITCCore

final class FacePipelinePixelTests: XCTestCase {
    func testCornerChannelsAndTopLeftOrientationPackToBGRNCHW() throws {
        let pixels: [UInt8] = [
            241, 17, 29, 9, 223, 41,
            13, 37, 239, 227, 211, 19
        ]
        let raster = try RGB8Raster(width: 2, height: 2, bytes: pixels)
        let prepared = try YuNetRasterPreprocessor.prepare(raster: raster)
        XCTAssertEqual(prepared.geometry.resizedWidth, 640)
        XCTAssertEqual(prepared.geometry.resizedHeight, 640)
        XCTAssertEqual(prepared.letterboxedRGB.bytes.prefix(3), [241, 17, 29])
        XCTAssertEqual(prepared.letterboxedRGB.bytes.suffix(3), [227, 211, 19])
        XCTAssertEqual(prepared.modelInput.shape, [1, 3, 640, 640])
        let plane = 640 * 640
        XCTAssertEqual(prepared.modelInput.values[0].bitPattern, Float(29).bitPattern)
        XCTAssertEqual(prepared.modelInput.values[plane].bitPattern, Float(17).bitPattern)
        XCTAssertEqual(prepared.modelInput.values[2 * plane].bitPattern, Float(241).bitPattern)
        XCTAssertEqual(prepared.modelInput.values[639].bitPattern, Float(41).bitPattern)
        XCTAssertEqual(prepared.modelInput.values[plane + 639].bitPattern, Float(223).bitPattern)
        XCTAssertEqual(prepared.modelInput.values[2 * plane + 639].bitPattern, Float(9).bitPattern)
        XCTAssertEqual(prepared.modelInput.values[plane - 1].bitPattern, Float(19).bitPattern)
        XCTAssertEqual(prepared.modelInput.values[2 * plane - 1].bitPattern, Float(211).bitPattern)
        XCTAssertEqual(prepared.modelInput.values[3 * plane - 1].bitPattern, Float(227).bitPattern)
    }

    func testPaddedRowsPortraitLandscapeAndOddRemainderStayExplicit() throws {
        let padded = try RGB8Raster(width: 2, height: 1, rowBytes: 8,
                                    bytes: [11, 23, 37, 41, 53, 67, 199, 211])
        let portrait = try YuNetRasterPreprocessor.prepare(raster: padded)
        XCTAssertEqual(portrait.geometry.padTop, 160)
        XCTAssertEqual(portrait.geometry.padBottom, 160)
        XCTAssertEqual(portrait.geometry.padLeft, 0)
        let blackPadRow = Array(portrait.letterboxedRGB.bytes.prefix(640 * 3))
        XCTAssertTrue(blackPadRow.allSatisfy { $0 == 0 })
        let contentRow = 200 * 640 * 3
        XCTAssertEqual(Array(portrait.letterboxedRGB.bytes[contentRow..<(contentRow + 3)]), [11, 23, 37])
        XCTAssertEqual(Array(portrait.letterboxedRGB.bytes[(contentRow + 639 * 3)..<(contentRow + 640 * 3)]),
                       [41, 53, 67])

        let landscape = try RGB8Raster(width: 640, height: 639,
                                       bytes: [UInt8](repeating: 127, count: 640 * 639 * 3))
        let landscapeInput = try YuNetRasterPreprocessor.prepare(raster: landscape)
        XCTAssertEqual(landscapeInput.geometry.padLeft, 0)
        XCTAssertEqual(landscapeInput.geometry.padRight, 0)
        XCTAssertEqual(landscapeInput.geometry.padTop, 0)
        XCTAssertEqual(landscapeInput.geometry.padBottom, 1)
        XCTAssertEqual(landscapeInput.geometry.effectiveScaleX, 1)
        XCTAssertEqual(landscapeInput.geometry.effectiveScaleY, 1)
    }

    func testImageIOOrientationsOneThroughEightProduceUprightCanonicalRGB() throws {
        let image = try quadrantImage()
        for orientation in 1...8 {
            let jpeg = try jpegData(image, orientation: orientation)
            let canonical = try JPEGPreviewDecoder.canonicalRGB(jpeg)
            let rotates = (5...8).contains(orientation)
            XCTAssertEqual(canonical.width, rotates ? 8 : 12, "EXIF orientation \(orientation)")
            XCTAssertEqual(canonical.height, rotates ? 12 : 8, "EXIF orientation \(orientation)")
            for (sourceX, sourceY, colorIndex) in [(3, 2, 0), (9, 2, 1), (3, 6, 2), (9, 6, 3)] {
                let destination = orientedPoint(x: sourceX, y: sourceY,
                                                width: 12, height: 8, orientation: orientation)
                let actual = pixel(canonical, x: destination.0, y: destination.1)
                XCTAssertEqual(nearestQuadrantColor(actual), colorIndex,
                               "EXIF orientation \(orientation), mapped corner \(colorIndex), pixel \(actual)")
            }
        }
    }

    func testPreparationReportsCompletedRowsAndChecksCancellation() async throws {
        let raster = try RGB8Raster(width: 4, height: 8, bytes: [UInt8](repeating: 31, count: 4 * 8 * 3))
        let recorder = ProgressRecorder()
        _ = try YuNetRasterPreprocessor.prepare(raster: raster) { recorder.append($0) }
        let events = recorder.events
        XCTAssertTrue(events.contains { $0.phase == .resize && $0.completedRows == $0.totalRows })
        XCTAssertTrue(events.contains { $0.phase == .tensorPacking && $0.completedRows == 640 && $0.totalRows == 640 })
        XCTAssertTrue(events.allSatisfy { $0.completedRows > 0 && $0.completedRows <= $0.totalRows })

        let task = Task.detached {
            try YuNetRasterPreprocessor.prepare(raster: raster) { event in
                if event.phase == .resize && event.completedRows == 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do {
            _ = try await task.value
            XCTFail("cancelled pixel preparation completed")
        } catch is CancellationError {
            // Expected: cancellation is checked before the next resize row.
        }
    }

    func testInvalidDimensionsAndStorageFailClosed() throws {
        XCTAssertThrowsError(try RGB8Raster(width: 0, height: 1, bytes: []))
        XCTAssertThrowsError(try RGB8Raster(width: 2, height: 1, rowBytes: 5, bytes: [UInt8](repeating: 0, count: 5)))
        XCTAssertThrowsError(try RGB8Raster(width: 40_000, height: 1, bytes: []))
    }

    func testFixed640OpenCVParityRunsOnlyWhenExplicitlyOptedIn() throws {
        guard let rawPath = ProcessInfo.processInfo.environment["AFITC_YUNET640_REFERENCE_PATH"] else {
            throw XCTSkip("Set AFITC_YUNET640_REFERENCE_PATH to the frozen phase2.yunet640-reference directory to run ten-case parity.")
        }
        try YuNetPixelReferenceParity.assertAllTen(referenceDirectory: URL(fileURLWithPath: rawPath))
    }

    private func quadrantImage() throws -> CGImage {
        let width = 12, height = 8
        let colors: [[UInt8]] = [[240, 8, 8], [8, 240, 8], [8, 8, 240], [240, 240, 8]]
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let color = colors[(y >= height / 2 ? 2 : 0) + (x >= width / 2 ? 1 : 0)]
                bytes[index] = color[0]
                bytes[index + 1] = color[1]
                bytes[index + 2] = color[2]
            }
        }
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                                    CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw ScanError.malformed
        }
        return image
    }

    private func jpegData(_ image: CGImage, orientation: Int) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ScanError.malformed
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 1.0,
            kCGImagePropertyOrientation: orientation
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ScanError.malformed }
        return output as Data
    }

    private func orientedPoint(x: Int, y: Int, width: Int, height: Int, orientation: Int) -> (Int, Int) {
        switch orientation {
        case 2: return (width - 1 - x, y)
        case 3: return (width - 1 - x, height - 1 - y)
        case 4: return (x, height - 1 - y)
        case 5: return (y, x)
        case 6: return (height - 1 - y, x)
        case 7: return (height - 1 - y, width - 1 - x)
        case 8: return (y, width - 1 - x)
        default: return (x, y)
        }
    }

    private func pixel(_ raster: RGB8Raster, x: Int, y: Int) -> [UInt8] {
        let offset = y * raster.rowBytes + x * 3
        return Array(raster.bytes[offset..<(offset + 3)])
    }

    private func nearestQuadrantColor(_ pixel: [UInt8]) -> Int {
        let colors: [[Int]] = [[240, 8, 8], [8, 240, 8], [8, 8, 240], [240, 240, 8]]
        return colors.indices.min { lhs, rhs in
            colors[lhs].enumerated().reduce(0) { $0 + abs(Int(pixel[$1.offset]) - $1.element) }
                < colors[rhs].enumerated().reduce(0) { $0 + abs(Int(pixel[$1.offset]) - $1.element) }
        } ?? -1
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [YuNetPixelPreparationProgress] = []

    var events: [YuNetPixelPreparationProgress] {
        lock.lock(); defer { lock.unlock() }
        return values
    }

    func append(_ value: YuNetPixelPreparationProgress) {
        lock.lock(); defer { lock.unlock() }
        values.append(value)
    }
}
