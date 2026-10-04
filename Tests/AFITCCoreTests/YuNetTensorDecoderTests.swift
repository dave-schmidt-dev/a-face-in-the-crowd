import Foundation
import XCTest
@testable import AFITCCore

final class YuNetTensorDecoderTests: XCTestCase {
    func testInputContractAndNamedOutputPermutationDecodeEveryStride() throws {
        let input = YuNetNamedTensor(
            name: YuNetTensorDecoder.inputName, elementType: .float32,
            shape: YuNetTensorDecoder.inputShape,
            values: [Float](repeating: 127, count: 3 * 640 * 640)
        )
        XCTAssertNoThrow(try YuNetTensorDecoder.validateInput(input))
        XCTAssertThrowsError(try YuNetTensorDecoder.validateInput(
            YuNetNamedTensor(name: "wrong", elementType: .float32,
                             shape: YuNetTensorDecoder.inputShape, values: input.values)
        )) { XCTAssertEqual($0 as? YuNetTensorDecoderError, .invalidInputName) }

        let rightEye = YuNetPoint(x: 25, y: 18)
        let leftEye = YuNetPoint(x: 28, y: 22)
        let nose = YuNetPoint(x: 32, y: 24)
        let rightMouth = YuNetPoint(x: 36, y: 28)
        let leftMouth = YuNetPoint(x: 40, y: 30)
        var fixture = TensorFixture()
        fixture.setCandidate(stride: 8, row: 2, column: 3,
                             box: Box(x: 22, y: 16, width: 8, height: 8),
                             points: [rightEye, leftEye, nose, rightMouth, leftMouth],
                             classScore: 0.95, objectScore: 0.95)
        fixture.setCandidate(stride: 16, row: 1, column: 2,
                             box: Box(x: 70, y: 20, width: 16, height: 16),
                             classScore: 0.95, objectScore: 0.95)
        fixture.setCandidate(stride: 32, row: 3, column: 4,
                             box: Box(x: 150, y: 100, width: 32, height: 32),
                             classScore: 0.95, objectScore: 0.95)

        let rows = try YuNetTensorDecoder.decode(
            outputs: fixture.outputs(order: Array(YuNetTensorDecoder.outputNames.reversed()))
        )
        XCTAssertEqual(rows.map(\.stride), [8, 16, 32])
        XCTAssertEqual(rows.map(\.generationOrder), [163, 6_442, 8_064])
        XCTAssertEqual(rows[0].rawValues.count, 15)
        XCTAssertEqual(rows[0].x, 22)
        XCTAssertEqual(rows[0].y, 16)
        XCTAssertEqual(rows[0].width, 8)
        XCTAssertEqual(rows[0].height, 8)
        XCTAssertEqual(rows[0].score, 0.95)
        XCTAssertEqual(rows[0].landmarks.ordered, [rightEye, leftEye, nose, rightMouth, leftMouth])
    }

    func testConfidenceClampingUsesStrictThreshold() throws {
        var fixture = TensorFixture()
        fixture.setCandidate(stride: 8, row: 0, column: 0,
                             box: Box(x: 20, y: 20, width: 8, height: 8),
                             classScore: 0.9, objectScore: 0.9)
        fixture.setCandidate(stride: 8, row: 0, column: 1,
                             box: Box(x: 40, y: 20, width: 8, height: 8),
                             classScore: 1.5, objectScore: 0.95)
        fixture.setCandidate(stride: 8, row: 0, column: 2,
                             box: Box(x: 60, y: 20, width: 8, height: 8),
                             classScore: -0.5, objectScore: 2)

        let rows = try YuNetTensorDecoder.decode(outputs: fixture.outputs())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].generationOrder, 1)
        XCTAssertEqual(rows[0].score, Float(0.95).squareRoot())
        XCTAssertGreaterThan(rows[0].score, YuNetTensorDecoder.confidenceThreshold)
    }

    func testRejectsMissingDuplicateExtraWrongTypeShapeAndValueCount() {
        let fixture = TensorFixture()
        let outputs = fixture.outputs()
        XCTAssertThrowsError(try YuNetTensorDecoder.decode(outputs: Array(outputs.dropLast()))) {
            XCTAssertEqual($0 as? YuNetTensorDecoderError, .missingOutput("kps_32"))
        }
        var duplicate = outputs
        duplicate.append(outputs[0])
        XCTAssertThrowsError(try YuNetTensorDecoder.decode(outputs: duplicate)) {
            XCTAssertEqual($0 as? YuNetTensorDecoderError, .duplicateOutputName(outputs[0].name))
        }
        var extra = outputs
        extra.append(YuNetNamedTensor(name: "extra", elementType: .float32, shape: [1, 1, 1], values: [0]))
        XCTAssertThrowsError(try YuNetTensorDecoder.decode(outputs: extra)) {
            XCTAssertEqual($0 as? YuNetTensorDecoderError, .unexpectedOutput("extra"))
        }

        let cls = outputs.first { $0.name == "cls_8" }!
        XCTAssertThrowsError(try YuNetTensorDecoder.decode(outputs: replacing(
            cls, in: outputs, type: .float16
        ))) { XCTAssertEqual($0 as? YuNetTensorDecoderError, .outputElementTypeMismatch("cls_8")) }
        XCTAssertThrowsError(try YuNetTensorDecoder.decode(outputs: replacing(
            cls, in: outputs, shape: [1, 6_400, 2]
        ))) { XCTAssertEqual($0 as? YuNetTensorDecoderError, .outputShapeMismatch("cls_8")) }
        XCTAssertThrowsError(try YuNetTensorDecoder.decode(outputs: replacing(
            cls, in: outputs, values: Array(cls.values.dropLast())
        ))) { XCTAssertEqual($0 as? YuNetTensorDecoderError, .outputValueCountMismatch("cls_8")) }

        XCTAssertThrowsError(try YuNetTensorDecoder.validateInput(
            YuNetNamedTensor(name: "input", elementType: .float16,
                             shape: [1, 3, 640, 640], values: [Float](repeating: 0, count: 3 * 640 * 640))
        )) { XCTAssertEqual($0 as? YuNetTensorDecoderError, .invalidInputElementType) }
    }

    func testRejectsNonfiniteHeadsExponentOverflowAndNonpositiveBoxes() {
        var nonfinite = TensorFixture()
        nonfinite.set("cls_8", index: 17, value: .nan)
        XCTAssertThrowsError(try YuNetTensorDecoder.decode(outputs: nonfinite.outputs())) {
            XCTAssertEqual($0 as? YuNetTensorDecoderError, .nonFiniteOutput("cls_8"))
        }

        var exponent = TensorFixture()
        exponent.setCandidate(stride: 8, row: 0, column: 0,
                              rawBoxOffsets: [0.5, 0.5, 1000, 0],
                              classScore: 0.95, objectScore: 0.95)
        XCTAssertThrowsError(try YuNetTensorDecoder.decode(outputs: exponent.outputs())) {
            XCTAssertEqual($0 as? YuNetTensorDecoderError, .exponentOverflow(0))
        }

        var underflow = TensorFixture()
        underflow.setCandidate(stride: 8, row: 0, column: 0,
                               rawBoxOffsets: [0.5, 0.5, 0, -1000],
                               classScore: 0.95, objectScore: 0.95)
        XCTAssertThrowsError(try YuNetTensorDecoder.decode(outputs: underflow.outputs())) {
            XCTAssertEqual($0 as? YuNetTensorDecoderError, .invalidDecodedBox(0))
        }

        var coordinateOverflow = TensorFixture()
        coordinateOverflow.setCandidate(stride: 8, row: 0, column: 0,
                                        box: Box(x: 3_000_000_000, y: 10, width: 8, height: 8),
                                        classScore: 0.95, objectScore: 0.95)
        XCTAssertThrowsError(try YuNetTensorDecoder.decode(outputs: coordinateOverflow.outputs())) {
            XCTAssertEqual($0 as? YuNetTensorDecoderError, .nmsCoordinateOverflow(0))
        }
    }

    func testNMSUsesStableTiesIntegerTruncationAndStrictIoU() throws {
        var truncation = TensorFixture()
        truncation.setCandidate(stride: 8, row: 1, column: 1,
                                box: Box(x: -0.8, y: 10, width: 1.8, height: 1.8),
                                classScore: 0.95, objectScore: 0.95)
        truncation.setCandidate(stride: 8, row: 1, column: 2,
                                box: Box(x: 0.8, y: 10, width: 1.8, height: 1.8),
                                classScore: 0.95, objectScore: 0.95)
        let truncated = try YuNetTensorDecoder.decode(outputs: truncation.outputs())
        XCTAssertEqual(truncated.map(\.generationOrder), [81])

        var overlap = TensorFixture()
        overlap.setCandidate(stride: 8, row: 1, column: 1,
                             box: Box(x: 10, y: 10, width: 13, height: 13),
                             classScore: 0.95, objectScore: 0.95)
        overlap.setCandidate(stride: 8, row: 1, column: 2,
                             box: Box(x: 17, y: 10, width: 13, height: 13),
                             classScore: 0.95, objectScore: 0.95)
        overlap.setCandidate(stride: 8, row: 1, column: 3,
                             box: Box(x: 16, y: 10, width: 13, height: 13),
                             classScore: 0.95, objectScore: 0.95)
        let selected = try YuNetTensorDecoder.decode(outputs: overlap.outputs())
        XCTAssertEqual(selected.map(\.generationOrder), [81, 82])
        XCTAssertEqual(selected[0].x, 10)
        XCTAssertEqual(selected[1].x, 17)
    }

    func testNMSAppliesTopKBeforeSuppressionInStableGenerationOrder() throws {
        var fixture = TensorFixture()
        for index in 0..<5_001 {
            let row = index / 80
            let column = index % 80
            fixture.setCandidate(stride: 8, row: row, column: column,
                                 box: Box(x: Float(column * 8) + 0.25,
                                          y: Float(row * 8) + 0.25,
                                          width: 1.5, height: 1.5),
                                 classScore: 0.95, objectScore: 0.95)
        }

        let selected = try YuNetTensorDecoder.decode(outputs: fixture.outputs())
        XCTAssertEqual(selected.count, 5_000)
        XCTAssertEqual(selected.first?.generationOrder, 0)
        XCTAssertEqual(selected.last?.generationOrder, 4_999)
    }

    func testLetterboxRoundHalfUpAndInverseEdgesAndPixelCentersPreserveSourceFrame() throws {
        let sourceFrame = FaceAlignmentFrame(
            photoID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
            contentVersion: 9, rasterWidth: 682, rasterHeight: 1_024,
            operationToken: UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        )
        let transform = try YuNetGeometryTransform(frame: sourceFrame)
        XCTAssertEqual(transform.resizedWidth, 426)
        XCTAssertEqual(transform.resizedHeight, 640)
        XCTAssertEqual(transform.padLeft, 107)
        XCTAssertEqual(transform.padRight, 107)
        XCTAssertEqual(transform.padTop, 0)
        XCTAssertEqual(transform.padBottom, 0)
        XCTAssertEqual(transform.effectiveScaleX, 426.0 / 682.0)
        XCTAssertEqual(transform.effectiveScaleY, 640.0 / 1_024.0)

        var fixture = TensorFixture()
        fixture.setCandidate(stride: 8, row: 0, column: 0,
                             box: Box(x: 107, y: 0, width: 8, height: 8),
                             points: [
                                YuNetPoint(x: 107, y: 0), YuNetPoint(x: 108, y: 1),
                                YuNetPoint(x: 110, y: 2), YuNetPoint(x: 112, y: 3),
                                YuNetPoint(x: 114, y: 4)
                             ],
                             classScore: 0.95, objectScore: 0.95)
        let row = try XCTUnwrap(YuNetTensorDecoder.decode(outputs: fixture.outputs()).first)
        let mapped = try transform.map(row)
        XCTAssertEqual(mapped.sourceFrame, sourceFrame)
        XCTAssertEqual(mapped.decodedRow, row)
        XCTAssertEqual(mapped.score, row.score)
        XCTAssertEqual(mapped.geometry.box.x, 0)
        XCTAssertEqual(mapped.geometry.box.y, 0)
        XCTAssertEqual(mapped.geometry.box.width, 8.0 / transform.effectiveScaleX)
        XCTAssertEqual(mapped.geometry.box.height, 8.0 / transform.effectiveScaleY)
        XCTAssertEqual(mapped.geometry.points.point0.x,
                       Float(((Double(107) - 107 + 0.5) / transform.effectiveScaleX) - 0.5))
        XCTAssertEqual(mapped.geometry.points.point0.y, Float(0.5 / transform.effectiveScaleY - 0.5))
        XCTAssertEqual(mapped.geometry.points.point1.x,
                       Float(((Double(108) - 107 + 0.5) / transform.effectiveScaleX) - 0.5))

        let landscape = try YuNetGeometryTransform(frame: frame(width: 1_024, height: 682))
        XCTAssertEqual(landscape.resizedWidth, 640)
        XCTAssertEqual(landscape.resizedHeight, 426)
        XCTAssertEqual(landscape.padLeft, 0)
        XCTAssertEqual(landscape.padTop, 107)
        XCTAssertEqual(landscape.padBottom, 107)

        let odd = try YuNetGeometryTransform(frame: frame(width: 1_000, height: 333))
        XCTAssertEqual(odd.resizedWidth, 640)
        XCTAssertEqual(odd.resizedHeight, 213)
        XCTAssertEqual(odd.padTop, 213)
        XCTAssertEqual(odd.padBottom, 214)
    }

    func testLetterboxRejectsInvalidSourceAndZeroRoundedDimension() {
        XCTAssertThrowsError(try YuNetGeometryTransform(frame: frame(width: 0, height: 10))) {
            XCTAssertEqual($0 as? YuNetGeometryTransformError, .invalidSourceFrame)
        }
        XCTAssertThrowsError(try YuNetGeometryTransform(frame: frame(width: 100, height: 100, version: 0))) {
            XCTAssertEqual($0 as? YuNetGeometryTransformError, .invalidSourceFrame)
        }
        XCTAssertThrowsError(try YuNetGeometryTransform(frame: frame(width: 32_766, height: 1))) {
            XCTAssertEqual($0 as? YuNetGeometryTransformError, .invalidLetterboxDimensions)
        }
    }

    func testFrozenOpenCVReferenceRowsMatchDecodedHeadsWhenOptedIn() throws {
        guard ProcessInfo.processInfo.environment["AFITC_RUN_YUNET_REFERENCE_PARITY"] == "1" else {
            throw XCTSkip("Set AFITC_RUN_YUNET_REFERENCE_PARITY=1 with the frozen reference root to run this opt-in check.")
        }
        let rootPath = try XCTUnwrap(
            ProcessInfo.processInfo.environment["AFITC_YUNET_REFERENCE_ROOT"],
            "AFITC_YUNET_REFERENCE_ROOT must identify the frozen phase2.yunet640-reference directory."
        )
        let report = try YuNetReferenceParity.compare(root: URL(fileURLWithPath: rootPath, isDirectory: true))
        print("[YuNetReferenceParity] \(report.summary)")
        XCTAssertEqual(report.sampleCount, 10)
        XCTAssertEqual(report.rawTensorCount, 120)
        XCTAssertEqual(report.expectedRowCount, 14)
        XCTAssertEqual(report.decodedRowCount, 14)
        XCTAssertEqual(report.comparedFloatCount, 210)
        XCTAssertLessThanOrEqual(report.maximumULPDistance, YuNetReferenceParity.maximumAllowedULPDistance)
        XCTAssertTrue(report.mismatches.isEmpty, report.mismatches.joined(separator: "\n"))
    }

    private func frame(width: Int = 682, height: Int = 1_024, version: Int = 9) -> FaceAlignmentFrame {
        FaceAlignmentFrame(photoID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
                           contentVersion: version, rasterWidth: width, rasterHeight: height,
                           operationToken: UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!)
    }

    private func replacing(_ tensor: YuNetNamedTensor, in outputs: [YuNetNamedTensor],
                           type: YuNetTensorElementType? = nil, shape: [Int]? = nil,
                           values: [Float]? = nil) -> [YuNetNamedTensor] {
        outputs.map {
            guard $0.name == tensor.name else { return $0 }
            return YuNetNamedTensor(name: $0.name, elementType: type ?? $0.elementType,
                                    shape: shape ?? $0.shape, values: values ?? $0.values)
        }
    }
}

private struct Box {
    let x: Float
    let y: Float
    let width: Float
    let height: Float
}

private struct TensorFixture {
    private(set) var heads: [String: [Float]] = [:]

    init() {
        for stride in YuNetTensorDecoder.strides {
            let side = 640 / stride
            let count = side * side
            heads["cls_\(stride)"] = [Float](repeating: 0, count: count)
            heads["obj_\(stride)"] = [Float](repeating: 0, count: count)
            heads["bbox_\(stride)"] = [Float](repeating: 0, count: count * 4)
            heads["kps_\(stride)"] = [Float](repeating: 0, count: count * 10)
        }
    }

    mutating func set(_ name: String, index: Int, value: Float) {
        heads[name]![index] = value
    }

    mutating func setCandidate(stride: Int, row: Int, column: Int, box: Box? = nil,
                               points: [YuNetPoint]? = nil, rawBoxOffsets: [Float]? = nil,
                               classScore: Float, objectScore: Float) {
        let side = 640 / stride
        let index = row * side + column
        let strideFloat = Float(stride)
        heads["cls_\(stride)"]![index] = classScore
        heads["obj_\(stride)"]![index] = objectScore

        let boxOffsets: [Float]
        if let rawBoxOffsets {
            boxOffsets = rawBoxOffsets
        } else {
            let target = box!
            let dx = (target.x + target.width / 2) / strideFloat - Float(column)
            let dy = (target.y + target.height / 2) / strideFloat - Float(row)
            let logWidth = Float(Foundation.log(Double(target.width) / Double(strideFloat)))
            let logHeight = Float(Foundation.log(Double(target.height) / Double(strideFloat)))
            boxOffsets = [dx, dy, logWidth, logHeight]
        }
        for component in 0..<4 {
            heads["bbox_\(stride)"]![index * 4 + component] = boxOffsets[component]
        }

        let targetPoints = points ?? [
            YuNetPoint(x: 1, y: 1), YuNetPoint(x: 2, y: 2), YuNetPoint(x: 3, y: 3),
            YuNetPoint(x: 4, y: 4), YuNetPoint(x: 5, y: 5)
        ]
        for slot in 0..<5 {
            let pointOffset = index * 10 + slot * 2
            heads["kps_\(stride)"]![pointOffset] = targetPoints[slot].x / strideFloat - Float(column)
            heads["kps_\(stride)"]![pointOffset + 1] = targetPoints[slot].y / strideFloat - Float(row)
        }
    }

    func outputs(order: [String]? = nil) -> [YuNetNamedTensor] {
        (order ?? YuNetTensorDecoder.outputNames).map { name in
            let pieces = name.split(separator: "_")
            let kind = String(pieces[0])
            let stride = Int(pieces[1])!
            let count = (640 / stride) * (640 / stride)
            let channels = kind == "bbox" ? 4 : (kind == "kps" ? 10 : 1)
            return YuNetNamedTensor(name: name, elementType: .float32,
                                    shape: [1, count, channels], values: heads[name]!)
        }
    }
}
