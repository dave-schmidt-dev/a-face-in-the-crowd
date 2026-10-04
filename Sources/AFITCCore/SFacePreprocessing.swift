import Foundation

// Adapted from the OpenCV 4.10.0 SFace five-point fit and INTER_LINEAR warp
// contract. This implementation is independent Swift code; source pin and
// required license text are in tools/third-party-notices/opencv-preprocessing-LICENSE.txt.
// Upstream sources: modules/objdetect/src/face_recognize.cpp and
// modules/imgproc/src/imgwarp.cpp at https://github.com/opencv/opencv/tree/4.10.0.

/// One float32 point in upright, top-left-origin raster pixel coordinates.
public struct SFacePoint: Equatable, Sendable {
    public let x: Float
    public let y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }
}

/// Five ordered model slots. Slot meaning is defined by the selected detector adapter;
/// this transport type does not infer anatomical landmarks or map Vision contours.
public struct SFaceFivePoints: Equatable, Sendable {
    public let point0: SFacePoint
    public let point1: SFacePoint
    public let point2: SFacePoint
    public let point3: SFacePoint
    public let point4: SFacePoint

    public init(_ point0: SFacePoint, _ point1: SFacePoint, _ point2: SFacePoint,
                _ point3: SFacePoint, _ point4: SFacePoint) throws {
        let points = [point0, point1, point2, point3, point4]
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw SFacePreprocessingError.nonFinitePoint
        }
        self.point0 = point0
        self.point1 = point1
        self.point2 = point2
        self.point3 = point3
        self.point4 = point4
    }

    fileprivate var ordered: [SFacePoint] { [point0, point1, point2, point3, point4] }
}

/// Owned interleaved RGB8 pixels with an explicit byte stride between rows.
/// Pixel stride is always three; orientation is upright and the origin is top-left.
public struct RGB8Raster: Equatable, Sendable {
    // OpenCV 4.10 remap requires source rows and columns below SHRT_MAX.
    public static let maximumDimension = 32_766
    public static let maximumStorageBytes = 512 * 1024 * 1024

    public let width: Int
    public let height: Int
    public let rowBytes: Int
    public let bytes: [UInt8]

    public init(width: Int, height: Int, rowBytes: Int? = nil, bytes: [UInt8]) throws {
        guard width > 0, height > 0,
              width <= Self.maximumDimension, height <= Self.maximumDimension else {
            throw SFacePreprocessingError.invalidDimensions
        }
        let (minimumRowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 3)
        guard !rowOverflow else { throw SFacePreprocessingError.invalidDimensions }
        let actualRowBytes = rowBytes ?? minimumRowBytes
        guard actualRowBytes >= minimumRowBytes else { throw SFacePreprocessingError.invalidRowStride }
        let (requiredBytes, storageOverflow) = actualRowBytes.multipliedReportingOverflow(by: height)
        guard !storageOverflow, requiredBytes <= Self.maximumStorageBytes else {
            throw SFacePreprocessingError.invalidDimensions
        }
        guard bytes.count == requiredBytes else { throw SFacePreprocessingError.invalidStorage }
        self.width = width
        self.height = height
        self.rowBytes = actualRowBytes
        self.bytes = bytes
    }

    fileprivate func packedRGBBytes() -> [UInt8] {
        if rowBytes == width * 3 { return bytes }
        var packed = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            let source = y * rowBytes
            let destination = y * width * 3
            packed[destination..<(destination + width * 3)] = bytes[source..<(source + width * 3)]
        }
        return packed
    }
}

/// Forward source-to-112x112 transform used by the pinned SFace crop operation.
public struct SFaceSimilarityTransform: Equatable, Sendable {
    public let m00: Double
    public let m01: Double
    public let m02: Double
    public let m10: Double
    public let m11: Double
    public let m12: Double

    public var coefficients: [Double] { [m00, m01, m02, m10, m11, m12] }

    public init(m00: Double, m01: Double, m02: Double,
                m10: Double, m11: Double, m12: Double) throws {
        let values = [m00, m01, m02, m10, m11, m12]
        guard values.allSatisfy(\.isFinite) else { throw SFacePreprocessingError.nonFiniteTransform }
        let determinant = m00 * m11 - m01 * m10
        guard determinant.isFinite, determinant != 0 else { throw SFacePreprocessingError.singularTransform }
        self.m00 = m00
        self.m01 = m01
        self.m02 = m02
        self.m10 = m10
        self.m11 = m11
        self.m12 = m12
    }

    fileprivate static func fit(_ points: SFaceFivePoints) throws -> (SFaceSimilarityTransform, [Double], [Double]) {
        let src = points.ordered
        let target: [(Float, Float)] = [
            (38.2946, 51.6963), (73.5318, 51.5014), (56.0252, 71.7366),
            (41.5493, 92.3655), (70.7299, 92.2041)
        ]
        let destinationMean: (Float, Float) = (56.0262, 71.9008)

        // Keep the ordered float32 additions and division used by face_recognize.cpp.
        let sourceMeanX = (((src[0].x + src[1].x) + src[2].x) + src[3].x + src[4].x) / 5
        let sourceMeanY = (((src[0].y + src[1].y) + src[2].y) + src[3].y + src[4].y) / 5
        guard sourceMeanX.isFinite, sourceMeanY.isFinite else { throw SFacePreprocessingError.nonFinitePoint }

        var sourceDemean = [(Float, Float)](repeating: (0, 0), count: 5)
        var destinationDemean = [(Float, Float)](repeating: (0, 0), count: 5)
        for index in 0..<5 {
            sourceDemean[index] = (src[index].x - sourceMeanX, src[index].y - sourceMeanY)
            destinationDemean[index] = (target[index].0 - destinationMean.0,
                                        target[index].1 - destinationMean.1)
        }

        // OpenCV multiplies the float operands before promoting each product to double.
        var covariance = [Double](repeating: 0, count: 4)
        for index in 0..<5 {
            covariance[0] += Double(destinationDemean[index].0 * sourceDemean[index].0)
            covariance[1] += Double(destinationDemean[index].0 * sourceDemean[index].1)
            covariance[2] += Double(destinationDemean[index].1 * sourceDemean[index].0)
            covariance[3] += Double(destinationDemean[index].1 * sourceDemean[index].1)
        }
        for index in covariance.indices { covariance[index] /= 5.0 }
        guard covariance.allSatisfy(\.isFinite) else { throw SFacePreprocessingError.nonFinitePoint }

        let d1 = covariance[0] * covariance[3] - covariance[1] * covariance[2] < 0 ? -1.0 : 1.0
        let (singular, u, vt) = SFacePreprocessor.jacobiSVD2x2(covariance)
        let largest = max(singular[0], singular[1])
        let rankTolerance = largest * 2.0 * Double(Float.leastNormalMagnitude)
        let rank = singular.reduce(0) { $0 + ($1 > rankTolerance ? 1 : 0) }
        guard rank == 2 else { throw SFacePreprocessingError.degeneratePoints }

        let dvt = [vt[0], vt[1], -vt[2], -vt[3]]
        let rotation = SFacePreprocessor.matrixMultiply2x2(u, d1 < 0 ? dvt : vt)

        var varianceX = 0.0
        var varianceY = 0.0
        for index in 0..<5 {
            varianceX += Double(sourceDemean[index].0 * sourceDemean[index].0)
            varianceY += Double(sourceDemean[index].1 * sourceDemean[index].1)
        }
        varianceX /= 5.0
        varianceY /= 5.0
        let variance = varianceX + varianceY
        guard variance.isFinite, variance > 0 else { throw SFacePreprocessingError.degeneratePoints }
        let scale = (1.0 / variance) * (singular[0] + singular[1] * d1)
        let tx = Double(destinationMean.0) - scale * (rotation[0] * Double(sourceMeanX) + rotation[1] * Double(sourceMeanY))
        let ty = Double(destinationMean.1) - scale * (rotation[2] * Double(sourceMeanX) + rotation[3] * Double(sourceMeanY))
        let transform = try SFaceSimilarityTransform(
            m00: rotation[0] * scale, m01: rotation[1] * scale, m02: tx,
            m10: rotation[2] * scale, m11: rotation[3] * scale, m12: ty
        )
        return (transform, covariance, singular)
    }
}

/// Failure modes for malformed pixels, invalid landmarks, and unsafe transforms.
public enum SFacePreprocessingError: Error, Equatable, Sendable {
    case invalidDimensions
    case invalidRowStride
    case invalidStorage
    case nonFinitePoint
    case degeneratePoints
    case nonFiniteTransform
    case singularTransform
    case coordinateOverflow
}

public struct SFacePreprocessingDiagnostics: Equatable, Sendable {
    public let covariance: [Double]
    public let singularValues: [Double]
    public let forwardMatrix: [Double]
}

public struct SFacePreprocessedFace: Equatable, Sendable {
    public let alignedRGB8: RGB8Raster
    public let modelInput: ModelTensor
    public let diagnostics: SFacePreprocessingDiagnostics
}

/// Pure CPU alignment and RGB-to-NCHW packing for the pinned OpenCV 4.10 SFace contract.
public enum SFacePreprocessor {
    public static let outputDimension = 112

    public static func prepare(raster: RGB8Raster, points: SFaceFivePoints) throws -> SFacePreprocessedFace {
        let (transform, covariance, singularValues) = try SFaceSimilarityTransform.fit(points)
        let aligned = try warp(raster, using: transform)
        var tensorValues = [Float](repeating: 0, count: 3 * outputDimension * outputDimension)
        let planeSize = outputDimension * outputDimension
        for pixel in 0..<planeSize {
            tensorValues[pixel] = Float(aligned.bytes[pixel * 3])
            tensorValues[planeSize + pixel] = Float(aligned.bytes[pixel * 3 + 1])
            tensorValues[2 * planeSize + pixel] = Float(aligned.bytes[pixel * 3 + 2])
        }
        let tensor = try ModelTensor(shape: [1, 3, outputDimension, outputDimension], values: tensorValues)
        let diagnostics = SFacePreprocessingDiagnostics(
            covariance: covariance, singularValues: singularValues, forwardMatrix: transform.coefficients
        )
        return SFacePreprocessedFace(alignedRGB8: aligned, modelInput: tensor, diagnostics: diagnostics)
    }

    /// Applies a source-to-destination affine using OpenCV 4.10 CPU INTER_LINEAR semantics.
    public static func warp(_ raster: RGB8Raster, using transform: SFaceSimilarityTransform) throws -> RGB8Raster {
        let determinant = transform.m00 * transform.m11 - transform.m01 * transform.m10
        guard determinant.isFinite, determinant != 0 else { throw SFacePreprocessingError.singularTransform }
        // Pinned OpenCV invertAffineTransform operation order.
        let inverseScale = 1.0 / determinant
        let m00 = transform.m11 * inverseScale
        let m01 = -transform.m01 * inverseScale
        let m02 = (transform.m01 * transform.m12 - transform.m02 * transform.m11) * inverseScale
        let m10 = -transform.m10 * inverseScale
        let m11 = transform.m00 * inverseScale
        let m12 = (transform.m02 * transform.m10 - transform.m00 * transform.m12) * inverseScale
        let inverse = [m00, m01, m02, m10, m11, m12]
        guard inverse.allSatisfy(\.isFinite) else { throw SFacePreprocessingError.nonFiniteTransform }

        let outputWidth = outputDimension
        let outputHeight = outputDimension
        let abScale = 1024.0
        let interpolationBits = 5
        let roundDelta: Int64 = 16
        var xDelta = [Int64](repeating: 0, count: outputWidth)
        var yDelta = [Int64](repeating: 0, count: outputWidth)
        for x in 0..<outputWidth {
            xDelta[x] = try roundedCoordinate(m00 * Double(x) * abScale)
            yDelta[x] = try roundedCoordinate(m10 * Double(x) * abScale)
        }

        var output = [UInt8](repeating: 0, count: outputWidth * outputHeight * 3)
        for y in 0..<outputHeight {
            let baseX = try roundedCoordinate((m01 * Double(y) + m02) * abScale)
            let baseY = try roundedCoordinate((m11 * Double(y) + m12) * abScale)
            for x in 0..<outputWidth {
                let (fixedX, xOverflow) = baseX.addingReportingOverflow(xDelta[x] + roundDelta)
                let (fixedY, yOverflow) = baseY.addingReportingOverflow(yDelta[x] + roundDelta)
                guard !xOverflow, !yOverflow else { throw SFacePreprocessingError.coordinateOverflow }
                let quantizedX = fixedX >> (10 - interpolationBits)
                let quantizedY = fixedY >> (10 - interpolationBits)
                let sourceX = quantizedX >> interpolationBits
                let sourceY = quantizedY >> interpolationBits
                let fractionX = Int(quantizedX & 31)
                let fractionY = Int(quantizedY & 31)
                let weights = interpolationWeights(x: fractionX, y: fractionY)
                let outputOffset = (y * outputWidth + x) * 3
                for channel in 0..<3 {
                    var sum: Int64 = 0
                    for neighbor in 0..<4 {
                        let nx = sourceX + Int64(neighbor & 1)
                        let ny = sourceY + Int64(neighbor >> 1)
                        if nx >= 0, ny >= 0, nx < Int64(raster.width), ny < Int64(raster.height) {
                            let sourceOffset = Int(ny) * raster.rowBytes + Int(nx) * 3 + channel
                            sum += Int64(raster.bytes[sourceOffset]) * weights[neighbor]
                        }
                    }
                    let rounded = (sum + 16_384) >> 15
                    output[outputOffset + channel] = UInt8(min(255, max(0, rounded)))
                }
            }
        }
        return try RGB8Raster(width: outputWidth, height: outputHeight, bytes: output)
    }

    private static func roundedCoordinate(_ value: Double) throws -> Int64 {
        guard value.isFinite,
              value >= Double(Int32.min), value <= Double(Int32.max) else {
            throw SFacePreprocessingError.coordinateOverflow
        }
        let rounded = value.rounded(.toNearestOrEven)
        guard rounded >= Double(Int32.min), rounded <= Double(Int32.max) else {
            throw SFacePreprocessingError.coordinateOverflow
        }
        return Int64(rounded)
    }

    private static func interpolationWeights(x: Int, y: Int) -> [Int64] {
        let inverseX = 32 - x
        let inverseY = 32 - y
        // Each exact binary coefficient is an integral multiple of 32 in 15-bit scale.
        return [
            Int64(inverseX * inverseY * 32), Int64(x * inverseY * 32),
            Int64(inverseX * y * 32), Int64(x * y * 32)
        ]
    }

    fileprivate static func matrixMultiply2x2(_ lhs: [Double], _ rhs: [Double]) -> [Double] {
        [
            lhs[0] * rhs[0] + lhs[1] * rhs[2], lhs[0] * rhs[1] + lhs[1] * rhs[3],
            lhs[2] * rhs[0] + lhs[3] * rhs[2], lhs[2] * rhs[1] + lhs[3] * rhs[3]
        ]
    }

    /// Port of OpenCV 4.10.0 JacobiSVDImpl_ for a full-rank 2x2 float64 covariance.
    fileprivate static func jacobiSVD2x2(_ covariance: [Double]) -> ([Double], [Double], [Double]) {
        // OpenCV transposes the input before JacobiSVDImpl_ and returns U as its transpose.
        var at = [covariance[0], covariance[2], covariance[1], covariance[3]]
        var vt = [1.0, 0.0, 0.0, 1.0]
        var singularSquared = [at[0] * at[0] + at[1] * at[1], at[2] * at[2] + at[3] * at[3]]
        let epsilon = Double.ulpOfOne * 10.0

        for _ in 0..<30 {
            let a = singularSquared[0]
            var p = at[0] * at[2] + at[1] * at[3]
            let b = singularSquared[1]
            if abs(p) <= epsilon * sqrt(a * b) { break }
            p *= 2.0
            let beta = a - b
            let gamma = stableHypot(p, beta)
            var cosine: Double
            var sine: Double
            if beta < 0 {
                let delta = (gamma - beta) * 0.5
                sine = sqrt(delta / gamma)
                cosine = p / (gamma * sine * 2.0)
            } else {
                cosine = sqrt((gamma + beta) / (gamma * 2.0))
                sine = p / (gamma * cosine * 2.0)
            }
            let ai0 = at[0], ai1 = at[1], aj0 = at[2], aj1 = at[3]
            at[0] = cosine * ai0 + sine * aj0
            at[1] = cosine * ai1 + sine * aj1
            at[2] = -sine * ai0 + cosine * aj0
            at[3] = -sine * ai1 + cosine * aj1
            singularSquared[0] = at[0] * at[0] + at[1] * at[1]
            singularSquared[1] = at[2] * at[2] + at[3] * at[3]
            let v0 = vt[0], v1 = vt[1], v2 = vt[2], v3 = vt[3]
            vt[0] = cosine * v0 + sine * v2
            vt[1] = cosine * v1 + sine * v3
            vt[2] = -sine * v0 + cosine * v2
            vt[3] = -sine * v1 + cosine * v3
        }

        var singular = [sqrt(singularSquared[0]), sqrt(singularSquared[1])]
        if singular[0] < singular[1] {
            singular.swapAt(0, 1)
            at.swapAt(0, 2)
            at.swapAt(1, 3)
            vt.swapAt(0, 2)
            vt.swapAt(1, 3)
        }
        if singular[0] > Double.leastNormalMagnitude {
            at[0] /= singular[0]; at[1] /= singular[0]
        }
        if singular[1] > Double.leastNormalMagnitude {
            at[2] /= singular[1]; at[3] /= singular[1]
        }
        let u = [at[0], at[2], at[1], at[3]]
        return (singular, u, vt)
    }

    private static func stableHypot(_ lhs: Double, _ rhs: Double) -> Double {
        let a = abs(lhs)
        let b = abs(rhs)
        if a > b {
            let ratio = b / a
            return a * sqrt(1.0 + ratio * ratio)
        }
        if b > 0 {
            let ratio = a / b
            return b * sqrt(1.0 + ratio * ratio)
        }
        return 0
    }
}
