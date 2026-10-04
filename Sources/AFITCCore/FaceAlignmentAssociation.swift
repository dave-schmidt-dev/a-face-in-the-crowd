import Foundation

/// Shared identity for two detector passes over the same upright preview raster.
/// The operation token fences late work for a photo generation.
public struct FaceAlignmentFrame: Equatable, Sendable {
    public let photoID: UUID
    public let contentVersion: Int
    public let rasterWidth: Int
    public let rasterHeight: Int
    public let operationToken: UUID

    public init(photoID: UUID, contentVersion: Int, rasterWidth: Int, rasterHeight: Int,
                operationToken: UUID) {
        self.photoID = photoID
        self.contentVersion = contentVersion
        self.rasterWidth = rasterWidth
        self.rasterHeight = rasterHeight
        self.operationToken = operationToken
    }
}

/// Vision's normalized lower-left-origin box.
public struct FaceAlignmentNormalizedBox: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Top-left-origin box in continuous raster-edge coordinates.
public struct FaceAlignmentPixelBox: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Existing Vision UUID plus ephemeral geometry. No face identity is created here.
public struct FaceAlignmentVisionFace: Equatable, Sendable {
    public let faceID: UUID
    public let box: FaceAlignmentNormalizedBox

    public init(faceID: UUID, box: FaceAlignmentNormalizedBox) {
        self.faceID = faceID
        self.box = box
    }
}

/// YuNet geometry with its already-canonical typed SFace slots, passed through unchanged.
public struct FaceAlignmentYuNetFace: Equatable, Sendable {
    public let box: FaceAlignmentPixelBox
    public let points: SFaceFivePoints

    public init(box: FaceAlignmentPixelBox, points: SFaceFivePoints) {
        self.box = box
        self.points = points
    }
}

public struct FaceAlignmentVisionInput: Equatable, Sendable {
    public let frame: FaceAlignmentFrame
    public let detectorRevision: String
    public let faces: [FaceAlignmentVisionFace]

    public init(frame: FaceAlignmentFrame, detectorRevision: String,
                faces: [FaceAlignmentVisionFace]) {
        self.frame = frame
        self.detectorRevision = detectorRevision
        self.faces = faces
    }
}

public struct FaceAlignmentYuNetInput: Equatable, Sendable {
    public let frame: FaceAlignmentFrame
    public let detectorRevision: String
    public let faces: [FaceAlignmentYuNetFace]

    public init(frame: FaceAlignmentFrame, detectorRevision: String,
                faces: [FaceAlignmentYuNetFace]) {
        self.frame = frame
        self.detectorRevision = detectorRevision
        self.faces = faces
    }
}

public enum FaceAlignmentUnavailableReason: Equatable, Sendable {
    case invalidFrame
    case staleProvenance
    case detectorRevisionMismatch
    case invalidVisionGeometry
    case invalidYuNetGeometry
    case landmarksOutsideRaster
    case noPositiveIoU
    case ambiguousOverlap
    case landmarksOutsideVisionBounds
}

public enum FaceAlignmentResolution: Equatable, Sendable {
    case available(SFaceFivePoints)
    case unavailable(FaceAlignmentUnavailableReason)
}

public struct FaceAlignmentAssociationRow: Equatable, Sendable {
    public let visionFaceID: UUID
    public let resolution: FaceAlignmentResolution

    public init(visionFaceID: UUID, resolution: FaceAlignmentResolution) {
        self.visionFaceID = visionFaceID
        self.resolution = resolution
    }
}

/// Ordered transient enrichment for current Vision IDs. This value is not Codable or persisted.
public struct FaceAlignmentAssociationResult: Equatable, Sendable {
    public let frame: FaceAlignmentFrame
    public let visionDetectorRevision: String
    public let yuNetDetectorRevision: String
    public let rows: [FaceAlignmentAssociationRow]

    public init(frame: FaceAlignmentFrame, visionDetectorRevision: String,
                yuNetDetectorRevision: String, rows: [FaceAlignmentAssociationRow]) {
        self.frame = frame
        self.visionDetectorRevision = visionDetectorRevision
        self.yuNetDetectorRevision = yuNetDetectorRevision
        self.rows = rows
    }
}

/// Associates only positive-IoU bipartite components containing exactly one face from each detector.
public enum FaceAlignmentAssociator {
    /// Boxes use continuous raster edges; landmark values use pixel-center coordinates.
    /// Vision containment allows only 0.5 pixel for center/edge quantization. IoU adds graph
    /// edges only when positive; it is not a confidence score or a usefulness threshold.
    public static func associate(
        currentFrame: FaceAlignmentFrame,
        expectedVisionDetectorRevision: String,
        expectedYuNetDetectorRevision: String,
        vision: FaceAlignmentVisionInput,
        yuNet: FaceAlignmentYuNetInput
    ) -> FaceAlignmentAssociationResult {
        guard isValid(currentFrame) else {
            return unavailable(currentFrame, expectedVisionDetectorRevision, expectedYuNetDetectorRevision,
                               vision.faces, .invalidFrame)
        }
        guard vision.frame == currentFrame, yuNet.frame == currentFrame else {
            return unavailable(currentFrame, expectedVisionDetectorRevision, expectedYuNetDetectorRevision,
                               vision.faces, .staleProvenance)
        }
        guard !expectedVisionDetectorRevision.isEmpty, !expectedYuNetDetectorRevision.isEmpty,
              vision.detectorRevision == expectedVisionDetectorRevision,
              yuNet.detectorRevision == expectedYuNetDetectorRevision else {
            return unavailable(currentFrame, expectedVisionDetectorRevision, expectedYuNetDetectorRevision,
                               vision.faces, .detectorRevisionMismatch)
        }
        guard Set(vision.faces.map(\.faceID)).count == vision.faces.count else {
            return unavailable(currentFrame, expectedVisionDetectorRevision, expectedYuNetDetectorRevision,
                               vision.faces, .invalidVisionGeometry)
        }

        let optionalVisionBoxes = vision.faces.map { pixelEdges(for: $0.box, frame: currentFrame) }
        guard optionalVisionBoxes.allSatisfy({ $0 != nil }) else {
            return unavailable(currentFrame, expectedVisionDetectorRevision, expectedYuNetDetectorRevision,
                               vision.faces, .invalidVisionGeometry)
        }
        let visionBoxes = optionalVisionBoxes.compactMap { $0 }
        let optionalYuNetBoxes = yuNet.faces.map { pixelEdges(for: $0.box, frame: currentFrame) }
        guard optionalYuNetBoxes.allSatisfy({ $0 != nil }) else {
            return unavailable(currentFrame, expectedVisionDetectorRevision, expectedYuNetDetectorRevision,
                               vision.faces, .invalidYuNetGeometry)
        }
        let yuNetBoxes = optionalYuNetBoxes.compactMap { $0 }

        for face in yuNet.faces {
            let points = ordered(face.points)
            guard pointsAreFiniteAndDistinct(points) else {
                return unavailable(currentFrame, expectedVisionDetectorRevision, expectedYuNetDetectorRevision,
                                   vision.faces, .invalidYuNetGeometry)
            }
            guard points.allSatisfy({ pointIsInsideRaster($0, frame: currentFrame) }) else {
                return unavailable(currentFrame, expectedVisionDetectorRevision, expectedYuNetDetectorRevision,
                                   vision.faces, .landmarksOutsideRaster)
            }
        }

        var visionNeighbors = Array(repeating: [Int](), count: visionBoxes.count)
        for vi in visionBoxes.indices {
            for yi in yuNetBoxes.indices where hasPositiveIoU(visionBoxes[vi], yuNetBoxes[yi]) {
                visionNeighbors[vi].append(yi)
            }
        }

        var resolutions = Array(repeating: FaceAlignmentResolution.unavailable(.noPositiveIoU),
                               count: vision.faces.count)
        var visitedVision = Set<Int>()
        for start in visionBoxes.indices where !visitedVision.contains(start) && !visionNeighbors[start].isEmpty {
            var componentVision = Set<Int>()
            var componentYuNet = Set<Int>()
            var pending: [(isVision: Bool, index: Int)] = [(true, start)]
            while let node = pending.popLast() {
                if node.isVision {
                    guard componentVision.insert(node.index).inserted else { continue }
                    visitedVision.insert(node.index)
                    for yi in visionNeighbors[node.index] { pending.append((false, yi)) }
                } else {
                    guard componentYuNet.insert(node.index).inserted else { continue }
                    for vi in visionBoxes.indices where visionNeighbors[vi].contains(node.index) {
                        pending.append((true, vi))
                    }
                }
            }

            guard componentVision.count == 1, componentYuNet.count == 1,
                  let vi = componentVision.first, let yi = componentYuNet.first else {
                for vi in componentVision { resolutions[vi] = .unavailable(.ambiguousOverlap) }
                continue
            }
            let candidate = yuNet.faces[yi]
            guard ordered(candidate.points).allSatisfy({ isContained($0, in: visionBoxes[vi]) }) else {
                resolutions[vi] = .unavailable(.landmarksOutsideVisionBounds)
                continue
            }
            resolutions[vi] = .available(candidate.points)
        }

        let rows = zip(vision.faces, resolutions).map {
            FaceAlignmentAssociationRow(visionFaceID: $0.0.faceID, resolution: $0.1)
        }
        return FaceAlignmentAssociationResult(frame: currentFrame,
            visionDetectorRevision: expectedVisionDetectorRevision,
            yuNetDetectorRevision: expectedYuNetDetectorRevision, rows: rows)
    }

    private static func isValid(_ frame: FaceAlignmentFrame) -> Bool {
        frame.contentVersion > 0 && frame.rasterWidth > 0 && frame.rasterHeight > 0
            && frame.rasterWidth <= RGB8Raster.maximumDimension
            && frame.rasterHeight <= RGB8Raster.maximumDimension
    }

    private static func pixelEdges(for box: FaceAlignmentNormalizedBox,
                                   frame: FaceAlignmentFrame) -> AlignmentEdges? {
        guard [box.x, box.y, box.width, box.height].allSatisfy(\.isFinite),
              box.x >= 0, box.y >= 0, box.width > 0, box.height > 0 else { return nil }
        let right = box.x + box.width
        let topNormalized = box.y + box.height
        guard right.isFinite, topNormalized.isFinite, right <= 1, topNormalized <= 1 else { return nil }
        let width = Double(frame.rasterWidth), height = Double(frame.rasterHeight)
        return AlignmentEdges(minX: box.x * width, minY: (1 - topNormalized) * height,
                              maxX: right * width, maxY: (1 - box.y) * height)
    }

    private static func pixelEdges(for box: FaceAlignmentPixelBox,
                                   frame: FaceAlignmentFrame) -> AlignmentEdges? {
        let right = box.x + box.width
        let bottom = box.y + box.height
        guard [box.x, box.y, box.width, box.height, right, bottom].allSatisfy(\.isFinite),
              box.x >= 0, box.y >= 0, box.width > 0, box.height > 0,
              right <= Double(frame.rasterWidth), bottom <= Double(frame.rasterHeight) else { return nil }
        return AlignmentEdges(minX: box.x, minY: box.y, maxX: right, maxY: bottom)
    }

    private static func ordered(_ points: SFaceFivePoints) -> [SFacePoint] {
        [points.point0, points.point1, points.point2, points.point3, points.point4]
    }

    private static func pointsAreFiniteAndDistinct(_ points: [SFacePoint]) -> Bool {
        guard points.count == 5, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        for first in points.indices {
            for second in points.indices where second > first {
                if points[first].x == points[second].x && points[first].y == points[second].y { return false }
            }
        }
        return true
    }

    private static func pointIsInsideRaster(_ point: SFacePoint, frame: FaceAlignmentFrame) -> Bool {
        let x = Double(point.x), y = Double(point.y)
        return x.isFinite && y.isFinite && x >= 0 && y >= 0
            && x <= Double(frame.rasterWidth - 1) && y <= Double(frame.rasterHeight - 1)
    }

    private static func isContained(_ point: SFacePoint, in box: AlignmentEdges) -> Bool {
        let halfPixel = 0.5
        let x = Double(point.x), y = Double(point.y)
        return x >= box.minX - halfPixel && x <= box.maxX + halfPixel
            && y >= box.minY - halfPixel && y <= box.maxY + halfPixel
    }

    private static func hasPositiveIoU(_ lhs: AlignmentEdges, _ rhs: AlignmentEdges) -> Bool {
        let width = min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX)
        let height = min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY)
        guard width > 0, height > 0 else { return false }
        let intersection = width * height
        let union = lhs.area + rhs.area - intersection
        let value = intersection / union
        return value.isFinite && value > 0
    }

    private static func unavailable(_ frame: FaceAlignmentFrame, _ visionRevision: String,
                                    _ yuNetRevision: String, _ faces: [FaceAlignmentVisionFace],
                                    _ reason: FaceAlignmentUnavailableReason) -> FaceAlignmentAssociationResult {
        let rows = faces.map {
            FaceAlignmentAssociationRow(visionFaceID: $0.faceID, resolution: .unavailable(reason))
        }
        return FaceAlignmentAssociationResult(frame: frame, visionDetectorRevision: visionRevision,
            yuNetDetectorRevision: yuNetRevision, rows: rows)
    }
}

private struct AlignmentEdges {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double

    var area: Double { (maxX - minX) * (maxY - minY) }
}
