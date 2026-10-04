import Foundation

public enum YuNetGeometryTransformError: Error, Equatable, Sendable {
    case invalidSourceFrame
    case invalidLetterboxDimensions
    case invalidDecodedGeometry
    case coordinateOverflow
}

/// Exact geometry for a centered 640x640 letterbox of the current upright Vision raster.
///
/// Resize dimensions use positive round-half-up arithmetic. Odd padding is placed on
/// the right or bottom. Inverse scaling uses the rounded dimensions' effective X/Y
/// scales, never the ideal pre-rounding scale.
public struct YuNetGeometryTransform: Equatable, Sendable {
    public static let canvasDimension = 640

    /// Preserves the existing photo generation, operation token, and Vision raster size.
    public let sourceFrame: FaceAlignmentFrame
    public let resizedWidth: Int
    public let resizedHeight: Int
    public let padLeft: Int
    public let padTop: Int
    public let padRight: Int
    public let padBottom: Int
    public let effectiveScaleX: Double
    public let effectiveScaleY: Double

    public init(frame: FaceAlignmentFrame) throws {
        guard frame.contentVersion > 0,
              frame.rasterWidth > 0, frame.rasterHeight > 0,
              frame.rasterWidth <= RGB8Raster.maximumDimension,
              frame.rasterHeight <= RGB8Raster.maximumDimension else {
            throw YuNetGeometryTransformError.invalidSourceFrame
        }

        let width = Double(frame.rasterWidth)
        let height = Double(frame.rasterHeight)
        let idealScale = min(Double(Self.canvasDimension) / width,
                             Double(Self.canvasDimension) / height)
        let roundedWidth = floor(width * idealScale + 0.5)
        let roundedHeight = floor(height * idealScale + 0.5)
        guard roundedWidth.isFinite, roundedHeight.isFinite,
              roundedWidth >= 1, roundedHeight >= 1,
              roundedWidth <= Double(Self.canvasDimension),
              roundedHeight <= Double(Self.canvasDimension) else {
            throw YuNetGeometryTransformError.invalidLetterboxDimensions
        }

        let actualWidth = Int(roundedWidth)
        let actualHeight = Int(roundedHeight)
        let horizontalPadding = Self.canvasDimension - actualWidth
        let verticalPadding = Self.canvasDimension - actualHeight
        let left = horizontalPadding / 2
        let top = verticalPadding / 2

        self.sourceFrame = frame
        self.resizedWidth = actualWidth
        self.resizedHeight = actualHeight
        self.padLeft = left
        self.padTop = top
        self.padRight = horizontalPadding - left
        self.padBottom = verticalPadding - top
        self.effectiveScaleX = Double(actualWidth) / width
        self.effectiveScaleY = Double(actualHeight) / height
    }

    /// Maps raw model-canvas box edges and pixel-center landmarks back to the source frame.
    /// Geometry is not clipped; later association rejects out-of-raster candidate points.
    public func map(_ row: YuNetDecodedRow) throws -> YuNetMappedDetection {
        guard row.rawValues.count == YuNetDecodedRow.valueCount,
              row.rawValues.allSatisfy(\.isFinite),
              row.width > 0, row.height > 0,
              effectiveScaleX.isFinite, effectiveScaleX > 0,
              effectiveScaleY.isFinite, effectiveScaleY > 0 else {
            throw YuNetGeometryTransformError.invalidDecodedGeometry
        }

        let left = (Double(row.x) - Double(padLeft)) / effectiveScaleX
        let top = (Double(row.y) - Double(padTop)) / effectiveScaleY
        let right = (Double(row.x) + Double(row.width) - Double(padLeft)) / effectiveScaleX
        let bottom = (Double(row.y) + Double(row.height) - Double(padTop)) / effectiveScaleY
        let boxWidth = right - left
        let boxHeight = bottom - top
        guard [left, top, right, bottom, boxWidth, boxHeight].allSatisfy(\.isFinite),
              boxWidth > 0, boxHeight > 0 else {
            throw YuNetGeometryTransformError.coordinateOverflow
        }

        let mappedPoints = try row.landmarks.ordered.map(mapPixelCenter)
        let points: SFaceFivePoints
        do {
            points = try SFaceFivePoints(mappedPoints[0], mappedPoints[1], mappedPoints[2],
                                         mappedPoints[3], mappedPoints[4])
        } catch {
            throw YuNetGeometryTransformError.coordinateOverflow
        }
        let geometry = FaceAlignmentYuNetFace(
            box: FaceAlignmentPixelBox(x: left, y: top, width: boxWidth, height: boxHeight),
            points: points
        )
        return YuNetMappedDetection(sourceFrame: sourceFrame, decodedRow: row, geometry: geometry)
    }

    public func map(_ rows: [YuNetDecodedRow]) throws -> [YuNetMappedDetection] {
        try rows.map(map)
    }

    private func mapPixelCenter(_ point: YuNetPoint) throws -> SFacePoint {
        let x = ((Double(point.x) - Double(padLeft)) + 0.5) / effectiveScaleX - 0.5
        let y = ((Double(point.y) - Double(padTop)) + 0.5) / effectiveScaleY - 0.5
        guard x.isFinite, y.isFinite,
              x >= -Double(Float.greatestFiniteMagnitude),
              x <= Double(Float.greatestFiniteMagnitude),
              y >= -Double(Float.greatestFiniteMagnitude),
              y <= Double(Float.greatestFiniteMagnitude) else {
            throw YuNetGeometryTransformError.coordinateOverflow
        }
        let floatX = Float(x)
        let floatY = Float(y)
        guard floatX.isFinite, floatY.isFinite else {
            throw YuNetGeometryTransformError.coordinateOverflow
        }
        return SFacePoint(x: floatX, y: floatY)
    }
}

/// Mapped ephemeral geometry with the source frame and exact decoded row retained.
public struct YuNetMappedDetection: Equatable, Sendable {
    public let sourceFrame: FaceAlignmentFrame
    public let decodedRow: YuNetDecodedRow
    public let geometry: FaceAlignmentYuNetFace

    public var score: Float { decodedRow.score }

    public init(sourceFrame: FaceAlignmentFrame, decodedRow: YuNetDecodedRow,
                geometry: FaceAlignmentYuNetFace) {
        self.sourceFrame = sourceFrame
        self.decodedRow = decodedRow
        self.geometry = geometry
    }
}
