import Foundation

/// Element type for a named YuNet tensor. The pinned graph currently requires float32.
public enum YuNetTensorElementType: Equatable, Sendable {
    case float32
    case float16
    case int32
}

/// A tensor value at the model boundary. Names and shapes are validated before decoding.
public struct YuNetNamedTensor: Equatable, Sendable {
    public let name: String
    public let elementType: YuNetTensorElementType
    public let shape: [Int]
    public let values: [Float]

    public init(name: String, elementType: YuNetTensorElementType, shape: [Int], values: [Float]) {
        self.name = name
        self.elementType = elementType
        self.shape = shape
        self.values = values
    }
}

/// One finite model-coordinate point in the canonical YuNet slot order.
public struct YuNetPoint: Equatable, Sendable {
    public let x: Float
    public let y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }
}

/// Named meanings for YuNet's five output point pairs.
public struct YuNetCanonicalLandmarks: Equatable, Sendable {
    public let rightEye: YuNetPoint
    public let leftEye: YuNetPoint
    public let noseTip: YuNetPoint
    public let rightMouth: YuNetPoint
    public let leftMouth: YuNetPoint

    public init(rightEye: YuNetPoint, leftEye: YuNetPoint, noseTip: YuNetPoint,
                rightMouth: YuNetPoint, leftMouth: YuNetPoint) {
        self.rightEye = rightEye
        self.leftEye = leftEye
        self.noseTip = noseTip
        self.rightMouth = rightMouth
        self.leftMouth = leftMouth
    }

    public var ordered: [YuNetPoint] {
        [rightEye, leftEye, noseTip, rightMouth, leftMouth]
    }
}

/// One selected 15-value YuNet row, still in the original 640x640 model canvas.
public struct YuNetDecodedRow: Equatable, Sendable {
    public static let valueCount = 15

    /// x, y, width, height, five ordered point pairs, score.
    public let rawValues: [Float]
    public let stride: Int
    /// Index in stride-8, then stride-16, then stride-32 row-major generation order.
    public let generationOrder: Int

    public var x: Float { rawValues[0] }
    public var y: Float { rawValues[1] }
    public var width: Float { rawValues[2] }
    public var height: Float { rawValues[3] }
    public var score: Float { rawValues[14] }
    public var landmarks: YuNetCanonicalLandmarks {
        YuNetCanonicalLandmarks(
            rightEye: YuNetPoint(x: rawValues[4], y: rawValues[5]),
            leftEye: YuNetPoint(x: rawValues[6], y: rawValues[7]),
            noseTip: YuNetPoint(x: rawValues[8], y: rawValues[9]),
            rightMouth: YuNetPoint(x: rawValues[10], y: rawValues[11]),
            leftMouth: YuNetPoint(x: rawValues[12], y: rawValues[13])
        )
    }

    fileprivate init(rawValues: [Float], stride: Int, generationOrder: Int) {
        self.rawValues = rawValues
        self.stride = stride
        self.generationOrder = generationOrder
    }
}

public enum YuNetTensorDecoderError: Error, Equatable, Sendable {
    case invalidInputName
    case invalidInputElementType
    case invalidInputShape
    case invalidInputValueCount
    case nonFiniteInput
    case inputOutsideRawByteRange
    case duplicateOutputName(String)
    case missingOutput(String)
    case unexpectedOutput(String)
    case outputElementTypeMismatch(String)
    case outputShapeMismatch(String)
    case outputValueCountMismatch(String)
    case nonFiniteOutput(String)
    case exponentOverflow(Int)
    case invalidDecodedBox(Int)
    case decodedCoordinateOverflow(Int)
    case nmsCoordinateOverflow(Int)
}

/// Pure decoder for the pinned OpenCV 4.10 YuNet 2023mar twelve-head contract.
///
/// The graph input is BGR, NCHW float32, raw 0...255. Output lookup is name-based;
/// no meaning is inferred from runtime output enumeration order. Math follows the
/// pinned FaceDetectorYN and NMS findings recorded in the local phase2 prep proposal.
public enum YuNetTensorDecoder {
    public static let canvasDimension = 640
    public static let inputName = "input"
    public static let inputShape = [1, 3, 640, 640]
    public static let confidenceThreshold: Float = 0.9
    public static let nmsIoUThreshold = 0.3
    public static let nmsTopK = 5_000
    public static let strides = [8, 16, 32]
    private static let headKinds = ["cls", "obj", "bbox", "kps"]

    public static let outputNames: [String] = strides.flatMap { stride in
        headKinds.map { "\($0)_\(stride)" }
    }

    /// Checks the exact fixed graph input before a provider constructs an ORT value.
    public static func validateInput(_ tensor: YuNetNamedTensor) throws {
        guard tensor.name == inputName else { throw YuNetTensorDecoderError.invalidInputName }
        guard tensor.elementType == .float32 else { throw YuNetTensorDecoderError.invalidInputElementType }
        guard tensor.shape == inputShape else { throw YuNetTensorDecoderError.invalidInputShape }
        guard tensor.values.count == 3 * canvasDimension * canvasDimension else {
            throw YuNetTensorDecoderError.invalidInputValueCount
        }
        guard tensor.values.allSatisfy(\.isFinite) else { throw YuNetTensorDecoderError.nonFiniteInput }
        guard tensor.values.allSatisfy({ $0 >= 0 && $0 <= 255 }) else {
            throw YuNetTensorDecoderError.inputOutsideRawByteRange
        }
    }

    /// Validates and decodes exactly twelve named float32 outputs, then applies OpenCV-style NMS.
    public static func decode(outputs: [YuNetNamedTensor]) throws -> [YuNetDecodedRow] {
        var named: [String: YuNetNamedTensor] = [:]
        let expected = Set(outputNames)
        for tensor in outputs {
            guard expected.contains(tensor.name) else {
                throw YuNetTensorDecoderError.unexpectedOutput(tensor.name)
            }
            guard named[tensor.name] == nil else {
                throw YuNetTensorDecoderError.duplicateOutputName(tensor.name)
            }
            named[tensor.name] = tensor
        }
        for name in outputNames where named[name] == nil {
            throw YuNetTensorDecoderError.missingOutput(name)
        }
        guard outputs.count == outputNames.count else {
            throw YuNetTensorDecoderError.unexpectedOutput("output-count")
        }

        var headValues: [String: [Float]] = [:]
        for stride in strides {
            let side = canvasDimension / stride
            let rowCount = side * side
            for kind in headKinds {
                let name = "\(kind)_\(stride)"
                guard let tensor = named[name] else {
                    throw YuNetTensorDecoderError.missingOutput(name)
                }
                guard tensor.elementType == .float32 else {
                    throw YuNetTensorDecoderError.outputElementTypeMismatch(name)
                }
                let channels = kind == "bbox" ? 4 : (kind == "kps" ? 10 : 1)
                let shape = [1, rowCount, channels]
                guard tensor.shape == shape else {
                    throw YuNetTensorDecoderError.outputShapeMismatch(name)
                }
                let (expectedCount, overflow) = rowCount.multipliedReportingOverflow(by: channels)
                guard !overflow, tensor.values.count == expectedCount else {
                    throw YuNetTensorDecoderError.outputValueCountMismatch(name)
                }
                guard tensor.values.allSatisfy(\.isFinite) else {
                    throw YuNetTensorDecoderError.nonFiniteOutput(name)
                }
                headValues[name] = tensor.values
            }
        }

        var candidates: [NMSCandidate] = []
        var generationBase = 0
        for stride in strides {
            let side = canvasDimension / stride
            let rowCount = side * side
            let strideFloat = Float(stride)
            let classes = headValues["cls_\(stride)"]!
            let objects = headValues["obj_\(stride)"]!
            let boxes = headValues["bbox_\(stride)"]!
            let keypoints = headValues["kps_\(stride)"]!

            for row in 0..<side {
                for column in 0..<side {
                    let index = row * side + column
                    let generationOrder = generationBase + index
                    let classScore = min(1, max(0, classes[index]))
                    let objectScore = min(1, max(0, objects[index]))
                    let score = (classScore * objectScore).squareRoot()
                    guard score.isFinite else {
                        throw YuNetTensorDecoderError.decodedCoordinateOverflow(generationOrder)
                    }
                    guard score > confidenceThreshold else { continue }

                    let boxOffset = index * 4
                    let dx = boxes[boxOffset]
                    let dy = boxes[boxOffset + 1]
                    let width = try scaledExponential(boxes[boxOffset + 2], stride: strideFloat,
                                                      generationOrder: generationOrder)
                    let height = try scaledExponential(boxes[boxOffset + 3], stride: strideFloat,
                                                       generationOrder: generationOrder)
                    let centerX = (Float(column) + dx) * strideFloat
                    let centerY = (Float(row) + dy) * strideFloat
                    let x = centerX - width / 2
                    let y = centerY - height / 2
                    guard width > 0, height > 0 else {
                        throw YuNetTensorDecoderError.invalidDecodedBox(generationOrder)
                    }

                    var values = [Float](repeating: 0, count: YuNetDecodedRow.valueCount)
                    values[0] = x
                    values[1] = y
                    values[2] = width
                    values[3] = height
                    let pointOffset = index * 10
                    for slot in 0..<5 {
                        values[4 + slot * 2] =
                            (Float(column) + keypoints[pointOffset + slot * 2]) * strideFloat
                        values[5 + slot * 2] =
                            (Float(row) + keypoints[pointOffset + slot * 2 + 1]) * strideFloat
                    }
                    values[14] = score
                    guard values.allSatisfy(\.isFinite) else {
                        throw YuNetTensorDecoderError.decodedCoordinateOverflow(generationOrder)
                    }

                    let decoded = YuNetDecodedRow(rawValues: values, stride: stride,
                                                  generationOrder: generationOrder)
                    let rect = try IntegerRect2i(x: x, y: y, width: width, height: height,
                                                 generationOrder: generationOrder)
                    candidates.append(NMSCandidate(row: decoded, rect: rect))
                }
            }
            generationBase += rowCount
        }
        return suppress(candidates)
    }

    private static func scaledExponential(_ value: Float, stride: Float,
                                          generationOrder: Int) throws -> Float {
        let exponential = Foundation.exp(value)
        guard exponential.isFinite else {
            throw YuNetTensorDecoderError.exponentOverflow(generationOrder)
        }
        let scaled = exponential * stride
        guard scaled.isFinite else {
            throw YuNetTensorDecoderError.exponentOverflow(generationOrder)
        }
        return scaled
    }

    private static func suppress(_ candidates: [NMSCandidate]) -> [YuNetDecodedRow] {
        let ranked = candidates.sorted {
            if $0.row.score != $1.row.score { return $0.row.score > $1.row.score }
            return $0.row.generationOrder < $1.row.generationOrder
        }
        let top = ranked.prefix(nmsTopK)
        var selected: [NMSCandidate] = []
        for candidate in top {
            if selected.contains(where: { $0.rect.intersectionOverUnion(with: candidate.rect) > nmsIoUThreshold }) {
                continue
            }
            selected.append(candidate)
        }
        return selected.map(\.row)
    }
}

private struct NMSCandidate {
    let row: YuNetDecodedRow
    let rect: IntegerRect2i
}

/// OpenCV Rect2i coordinates are C++ int casts, which truncate finite values toward zero.
private struct IntegerRect2i {
    let x: Int32
    let y: Int32
    let width: Int32
    let height: Int32
    private let right: Int64
    private let bottom: Int64

    init(x: Float, y: Float, width: Float, height: Float, generationOrder: Int) throws {
        let ix = try Self.truncatedInt32(x, generationOrder: generationOrder)
        let iy = try Self.truncatedInt32(y, generationOrder: generationOrder)
        let iw = try Self.truncatedInt32(width, generationOrder: generationOrder)
        let ih = try Self.truncatedInt32(height, generationOrder: generationOrder)
        guard iw >= 0, ih >= 0 else {
            throw YuNetTensorDecoderError.invalidDecodedBox(generationOrder)
        }
        let r = Int64(ix) + Int64(iw)
        let b = Int64(iy) + Int64(ih)
        guard r <= Int64(Int32.max), r >= Int64(Int32.min),
              b <= Int64(Int32.max), b >= Int64(Int32.min) else {
            throw YuNetTensorDecoderError.nmsCoordinateOverflow(generationOrder)
        }
        self.x = ix
        self.y = iy
        self.width = iw
        self.height = ih
        self.right = r
        self.bottom = b
    }

    func intersectionOverUnion(with other: IntegerRect2i) -> Double {
        let intersectionWidth = max(0, min(right, other.right) - max(Int64(x), Int64(other.x)))
        let intersectionHeight = max(0, min(bottom, other.bottom) - max(Int64(y), Int64(other.y)))
        let intersection = intersectionWidth * intersectionHeight
        let lhsArea = Int64(width) * Int64(height)
        let rhsArea = Int64(other.width) * Int64(other.height)
        let union = lhsArea + rhsArea - intersection
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    private static func truncatedInt32(_ value: Float, generationOrder: Int) throws -> Int32 {
        guard value.isFinite else {
            throw YuNetTensorDecoderError.nmsCoordinateOverflow(generationOrder)
        }
        let truncated = Double(value.rounded(.towardZero))
        guard truncated >= Double(Int32.min), truncated <= Double(Int32.max) else {
            throw YuNetTensorDecoderError.nmsCoordinateOverflow(generationOrder)
        }
        return Int32(truncated)
    }
}
