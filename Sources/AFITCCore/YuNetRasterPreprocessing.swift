import Foundation

public enum YuNetPixelPreparationPhase: String, Sendable {
    case canonicalRGB
    case resize
    case tensorPacking
}

/// Row counts reflect completed work, so callers can expose bounded progress.
public struct YuNetPixelPreparationProgress: Equatable, Sendable {
    public let phase: YuNetPixelPreparationPhase
    public let completedRows: Int
    public let totalRows: Int

    public init(phase: YuNetPixelPreparationPhase, completedRows: Int, totalRows: Int) {
        self.phase = phase
        self.completedRows = completedRows
        self.totalRows = totalRows
    }
}

/// Exact rounded-size and centered-padding geometry for a 640 square input.
public struct YuNet640Geometry: Equatable, Sendable {
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let resizedWidth: Int
    public let resizedHeight: Int
    public let padLeft: Int
    public let padTop: Int
    public let padRight: Int
    public let padBottom: Int
    public let effectiveScaleX: Double
    public let effectiveScaleY: Double
}

public struct YuNet640PreparedInput: Sendable {
    public let letterboxedRGB: RGB8Raster
    public let modelInput: ModelTensor
    public let geometry: YuNet640Geometry
}

/// Dependency-free RGB resize, letterbox, and BGR NCHW packing for YuNet.
/// The fixed-point coefficients and pixel-center mapping follow OpenCV 4.10
/// `INTER_LINEAR` for 8-bit input. Its optimized ARM `VResizeLinearVec_32s8u`
/// high-product and rounded-pack arithmetic is retained for reference parity.
/// Run this synchronous work on a worker task.
public enum YuNetRasterPreprocessor {
    public static let inputDimension = 640
    private static let coefficientBits = 11
    private static let coefficientScale = 1 << coefficientBits

    private struct AxisSample {
        let first: Int
        let second: Int
        let firstWeight: Int
        let secondWeight: Int
    }

    public static func prepare(
        raster: RGB8Raster,
        progress: (@Sendable (YuNetPixelPreparationProgress) -> Void)? = nil
    ) throws -> YuNet640PreparedInput {
        let sourceWidth = raster.width
        let sourceHeight = raster.height
        let scale = min(Double(inputDimension) / Double(sourceWidth),
                        Double(inputDimension) / Double(sourceHeight))
        let resizedWidth = min(inputDimension, Int(floor(Double(sourceWidth) * scale + 0.5)))
        let resizedHeight = min(inputDimension, Int(floor(Double(sourceHeight) * scale + 0.5)))
        guard resizedWidth > 0, resizedHeight > 0 else { throw SFacePreprocessingError.invalidDimensions }

        let padLeft = (inputDimension - resizedWidth) / 2
        let padTop = (inputDimension - resizedHeight) / 2
        let padRight = inputDimension - resizedWidth - padLeft
        let padBottom = inputDimension - resizedHeight - padTop
        let geometry = YuNet640Geometry(
            sourceWidth: sourceWidth, sourceHeight: sourceHeight,
            resizedWidth: resizedWidth, resizedHeight: resizedHeight,
            padLeft: padLeft, padTop: padTop, padRight: padRight, padBottom: padBottom,
            effectiveScaleX: Double(resizedWidth) / Double(sourceWidth),
            effectiveScaleY: Double(resizedHeight) / Double(sourceHeight)
        )
        let xSamples = try axisSamples(sourceExtent: sourceWidth, destinationExtent: resizedWidth)
        let ySamples = try axisSamples(sourceExtent: sourceHeight, destinationExtent: resizedHeight)
        var canvas = [UInt8](repeating: 0, count: inputDimension * inputDimension * 3)

        for y in 0..<resizedHeight {
            try Task.checkCancellation()
            let ys = ySamples[y]
            let sourceRow0 = ys.first * raster.rowBytes
            let sourceRow1 = ys.second * raster.rowBytes
            let destinationRow = ((y + padTop) * inputDimension + padLeft) * 3
            for x in 0..<resizedWidth {
                let xs = xSamples[x]
                let sourcePixel0 = sourceRow0 + xs.first * 3
                let sourcePixel1 = sourceRow0 + xs.second * 3
                let sourcePixel2 = sourceRow1 + xs.first * 3
                let sourcePixel3 = sourceRow1 + xs.second * 3
                let destinationPixel = destinationRow + x * 3
                for channel in 0..<3 {
                    let top = Int(raster.bytes[sourcePixel0 + channel]) * xs.firstWeight
                        + Int(raster.bytes[sourcePixel1 + channel]) * xs.secondWeight
                    let bottom = Int(raster.bytes[sourcePixel2 + channel]) * xs.firstWeight
                        + Int(raster.bytes[sourcePixel3 + channel]) * xs.secondWeight
                    // OpenCV 4.10's optimized ARM kernel shifts each horizontal
                    // accumulator by four before signed high-half multiplication.
                    let topPacked = min(Int(Int16.max), max(Int(Int16.min), top >> 4))
                    let bottomPacked = min(Int(Int16.max), max(Int(Int16.min), bottom >> 4))
                    let topHigh = (topPacked * ys.firstWeight) >> 16
                    let bottomHigh = (bottomPacked * ys.secondWeight) >> 16
                    let vectorSum = min(Int(Int16.max), max(Int(Int16.min), topHigh + bottomHigh))
                    canvas[destinationPixel + channel] = UInt8(clamping: (vectorSum + 2) >> 2)
                }
            }
            progress?(YuNetPixelPreparationProgress(phase: .resize, completedRows: y + 1,
                                                     totalRows: resizedHeight))
        }
        try Task.checkCancellation()

        let planeSize = inputDimension * inputDimension
        var tensorValues = [Float](repeating: 0, count: 3 * planeSize)
        for y in 0..<inputDimension {
            try Task.checkCancellation()
            for x in 0..<inputDimension {
                let pixel = (y * inputDimension + x) * 3
                let planeIndex = y * inputDimension + x
                tensorValues[planeIndex] = Float(canvas[pixel + 2])
                tensorValues[planeSize + planeIndex] = Float(canvas[pixel + 1])
                tensorValues[2 * planeSize + planeIndex] = Float(canvas[pixel])
            }
            progress?(YuNetPixelPreparationProgress(phase: .tensorPacking, completedRows: y + 1,
                                                     totalRows: inputDimension))
        }
        try Task.checkCancellation()
        let outputRaster = try RGB8Raster(width: inputDimension, height: inputDimension, bytes: canvas)
        let modelInput = try ModelTensor(shape: [1, 3, inputDimension, inputDimension], values: tensorValues)
        return YuNet640PreparedInput(letterboxedRGB: outputRaster, modelInput: modelInput, geometry: geometry)
    }

    private static func axisSamples(sourceExtent: Int, destinationExtent: Int) throws -> [AxisSample] {
        guard sourceExtent > 0, destinationExtent > 0 else { throw SFacePreprocessingError.invalidDimensions }
        let inverseScale = Double(destinationExtent) / Double(sourceExtent)
        let scale = 1.0 / inverseScale
        return (0..<destinationExtent).map { destination in
            let coordinate = Float((Double(destination) + 0.5) * scale - 0.5)
            var first = Int(floor(Double(coordinate)))
            var fraction = coordinate - Float(first)
            if first < 0 {
                first = 0
                fraction = 0
            }
            if first >= sourceExtent - 1 {
                first = sourceExtent - 1
                fraction = 0
            }
            let second = min(first + 1, sourceExtent - 1)
            let secondWeight = Int((fraction * Float(coefficientScale)).rounded(.toNearestOrEven))
            let firstWeight = Int(((1 - fraction) * Float(coefficientScale)).rounded(.toNearestOrEven))
            return AxisSample(first: first, second: second,
                              firstWeight: min(coefficientScale, max(0, firstWeight)),
                              secondWeight: min(coefficientScale, max(0, secondWeight)))
        }
    }
}
