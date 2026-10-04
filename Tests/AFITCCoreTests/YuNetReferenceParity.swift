import CryptoKit
import Foundation
@testable import AFITCCore

/// Reads only the frozen generated YuNet raw-head fixtures when explicitly opted in.
/// It verifies the inventory before parsing any tensor and never runs model inference.
enum YuNetReferenceParity {
    static let expectedManifestSHA256 = "64a52cb0b1b0d97bc88e64629e0f4d1781738713e2904e7341aa8430b7b4c4db"
    static let expectedExecutionReceiptSHA256 = "0101853f5fa4a95c7888c31d8047e153c99322438d30cebceb15539e487d8aef"
    static let expectedSummarySHA256 = "5657f9b0f0d0489190d69ea8e372f6fb673740b2381dbfc41e1de13ea383843a"
    static let expectedStopSHA256 = "9434e66937f611370ad99ec730207fd81c4eed867641dec405291573bcfc2af3"
    static let maximumAllowedULPDistance: UInt64 = 4

    static let rowFields = [
        "bboxX", "bboxY", "bboxWidth", "bboxHeight",
        "rightEyeX", "rightEyeY", "leftEyeX", "leftEyeY", "noseTipX", "noseTipY",
        "rightMouthX", "rightMouthY", "leftMouthX", "leftMouthY", "score"
    ]

    struct Report {
        let sampleCount: Int
        let rawTensorCount: Int
        let expectedRowCount: Int
        let decodedRowCount: Int
        let comparedFloatCount: Int
        let exactFloatCount: Int
        let maximumULPDistance: UInt64
        let maximumAbsoluteError: Double
        let fieldMaximumULP: [String: UInt64]
        let mismatches: [String]

        var summary: String {
            let fields = rowFields.map { "\($0)=\(fieldMaximumULP[$0, default: 0])" }.joined(separator: ",")
            return "samples=\(sampleCount) rawTensors=\(rawTensorCount) rows=\(decodedRowCount)/\(expectedRowCount) " +
                "values=\(comparedFloatCount) exact=\(exactFloatCount) maxULP=\(maximumULPDistance) " +
                "maxAbs=\(maximumAbsoluteError) fieldMaxULP=[\(fields)]"
        }
    }

    private struct ArtifactManifest: Decodable {
        let status: String
        let artifactDirectory: String
        let fileCountExcludingManifest: Int
        let totalBytesExcludingManifest: Int
        let files: [ArtifactEntry]
    }

    private struct ArtifactEntry: Decodable {
        let path: String
        let bytes: Int
        let sha256: String
    }

    private struct ExecutionReceipt: Decodable {
        let status: String
        let execution: Execution
        let model: Model

        struct Execution: Decodable {
            let rawHeadsSaved: Int
            let detectionsSaved: Int
            let samples: Int
        }

        struct Model: Decodable {
            let sha256: String
            let bytes: Int
        }
    }

    private struct ReferenceSummary: Decodable {
        let status: String
        let model: Model
        let rawOutputNamesRequested: [String]
        let detectionRowFields: [String]
        let samples: [Sample]

        struct Model: Decodable { let sha256: String }
        struct Sample: Decodable { let sampleId: String; let faceCount: Int }
    }

    private struct SampleReceipt: Decodable {
        let sampleId: String
        let rawOutputs: [String: RawOutput]

        struct RawOutput: Decodable {
            let shape: [Int]
            let dtype: String
            let npySHA256: String
        }
    }

    private struct NPYTensor {
        let shape: [Int]
        let values: [Float]
    }

    static func compare(root: URL) throws -> Report {
        guard root.isFileURL, root.path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("STOP").path) else {
            throw ReferenceError.invalidRoot
        }

        let manifestData = try Data(contentsOf: root.appendingPathComponent("artifact-manifest.json"))
        guard sha256(manifestData) == expectedManifestSHA256 else { throw ReferenceError.manifestDigest }
        let manifest = try JSONDecoder().decode(ArtifactManifest.self, from: manifestData)
        guard manifest.status == "FROZEN_EVIDENCE_MANIFEST",
              manifest.artifactDirectory == ".logs/verification/phase2.yunet640-reference",
              manifest.fileCountExcludingManifest == 171,
              manifest.files.count == manifest.fileCountExcludingManifest,
              manifest.totalBytesExcludingManifest == 67_047_919 else {
            throw ReferenceError.invalidManifest
        }
        let entries = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })

        _ = try verifiedData("STOP", root: root, entries: entries)
        let executionData = try verifiedData("execution-receipt.json", root: root, entries: entries)
        guard sha256(executionData) == expectedExecutionReceiptSHA256 else {
            throw ReferenceError.executionReceiptDigest
        }
        let execution = try JSONDecoder().decode(ExecutionReceipt.self, from: executionData)
        guard execution.status == "STOPPED_COMPLETE_REFERENCE_EVIDENCE_ONLY",
              execution.execution.samples == 10,
              execution.execution.rawHeadsSaved == 120,
              execution.execution.detectionsSaved == 14,
              execution.model.sha256 == "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4",
              execution.model.bytes == 232_589 else {
            throw ReferenceError.invalidExecutionReceipt
        }

        let summaryData = try verifiedData("reference-summary.json", root: root, entries: entries)
        guard sha256(summaryData) == expectedSummarySHA256 else { throw ReferenceError.summaryDigest }
        let summary = try JSONDecoder().decode(ReferenceSummary.self, from: summaryData)
        let expectedSampleIDs = (1...10).map { String(format: "sample-%02d", $0) }
        guard summary.status == "MEASURED_REFERENCE_ONLY_NOT_ACCEPTANCE",
              summary.model.sha256 == execution.model.sha256,
              Set(summary.rawOutputNamesRequested) == Set(YuNetTensorDecoder.outputNames),
              summary.rawOutputNamesRequested.count == YuNetTensorDecoder.outputNames.count,
              summary.detectionRowFields == rowFields,
              summary.samples.map(\.sampleId) == expectedSampleIDs else {
            throw ReferenceError.invalidSummary
        }

        let stopData = try Data(contentsOf: root.appendingPathComponent("STOP"))
        guard sha256(stopData) == expectedStopSHA256 else { throw ReferenceError.stopDigest }

        var expectedRowCount = 0
        var decodedRowCount = 0
        var comparedFloatCount = 0
        var exactFloatCount = 0
        var maximumULP: UInt64 = 0
        var maximumAbsoluteError = 0.0
        var fieldMaximumULP = Dictionary(uniqueKeysWithValues: rowFields.map { ($0, UInt64(0)) })
        var mismatches: [String] = []
        var verifiedTensorCount = 0

        for sample in summary.samples {
            let sampleID = sample.sampleId
            let prefix = "\(sampleID)/"
            let receiptPath = prefix + "receipt.json"
            let receiptData = try verifiedData(receiptPath, root: root, entries: entries)
            let receipt = try JSONDecoder().decode(SampleReceipt.self, from: receiptData)
            guard receipt.sampleId == sampleID,
                  Set(receipt.rawOutputs.keys) == Set(YuNetTensorDecoder.outputNames),
                  receipt.rawOutputs.count == YuNetTensorDecoder.outputNames.count else {
                throw ReferenceError.invalidSampleReceipt(sampleID)
            }

            var tensors: [YuNetNamedTensor] = []
            for name in YuNetTensorDecoder.outputNames {
                guard let output = receipt.rawOutputs[name], output.dtype == "float32" else {
                    throw ReferenceError.invalidOutputReceipt(sampleID, name)
                }
                let path = prefix + "raw-\(name).npy"
                let data = try verifiedData(path, root: root, entries: entries)
                guard sha256(data) == output.npySHA256 else {
                    throw ReferenceError.outputDigestMismatch(sampleID, name)
                }
                let tensor = try parseNPY(data)
                let expectedShape = Self.expectedShape(for: name)
                guard output.shape == expectedShape, tensor.shape == expectedShape else {
                    throw ReferenceError.outputShapeMismatch(sampleID, name)
                }
                tensors.append(YuNetNamedTensor(name: name, elementType: .float32,
                                                shape: tensor.shape, values: tensor.values))
                verifiedTensorCount += 1
            }

            let rowsData = try verifiedData(prefix + "facedetectoryn-rows-f32.npy", root: root,
                                            entries: entries)
            let referenceRows = try parseNPY(rowsData)
            guard referenceRows.shape == [sample.faceCount, YuNetDecodedRow.valueCount],
                  referenceRows.values.count == sample.faceCount * YuNetDecodedRow.valueCount,
                  referenceRows.values.allSatisfy(\.isFinite) else {
                throw ReferenceError.invalidReferenceRows(sampleID)
            }

            let decoded = try YuNetTensorDecoder.decode(outputs: tensors)
            expectedRowCount += sample.faceCount
            decodedRowCount += decoded.count
            if decoded.count != sample.faceCount {
                mismatches.append("\(sampleID): expected \(sample.faceCount) rows, decoded \(decoded.count)")
            }
            for rowIndex in 0..<min(decoded.count, sample.faceCount) {
                let actual = decoded[rowIndex].rawValues
                let expectedBase = rowIndex * YuNetDecodedRow.valueCount
                for fieldIndex in rowFields.indices {
                    let expected = referenceRows.values[expectedBase + fieldIndex]
                    let observed = actual[fieldIndex]
                    let distance = ulpDistance(expected, observed)
                    let absoluteError = abs(Double(expected) - Double(observed))
                    comparedFloatCount += 1
                    if distance == 0 { exactFloatCount += 1 }
                    maximumULP = max(maximumULP, distance)
                    fieldMaximumULP[rowFields[fieldIndex]] = max(
                        fieldMaximumULP[rowFields[fieldIndex], default: 0], distance
                    )
                    maximumAbsoluteError = max(maximumAbsoluteError, absoluteError)
                    if distance > maximumAllowedULPDistance, mismatches.count < 32 {
                        mismatches.append(
                            "\(sampleID) row \(rowIndex) \(rowFields[fieldIndex]): expected \(expected), " +
                                "decoded \(observed), ulpDistance \(distance), absError \(absoluteError)"
                        )
                    }
                }
            }
        }

        guard verifiedTensorCount == 120 else { throw ReferenceError.rawTensorCount(verifiedTensorCount) }
        return Report(sampleCount: summary.samples.count, rawTensorCount: verifiedTensorCount,
                      expectedRowCount: expectedRowCount, decodedRowCount: decodedRowCount,
                      comparedFloatCount: comparedFloatCount, exactFloatCount: exactFloatCount,
                      maximumULPDistance: maximumULP, maximumAbsoluteError: maximumAbsoluteError,
                      fieldMaximumULP: fieldMaximumULP, mismatches: mismatches)
    }

    private static func expectedShape(for name: String) -> [Int] {
        let pieces = name.split(separator: "_")
        let stride = Int(pieces[1])!
        let side = 640 / stride
        let channels = pieces[0] == "bbox" ? 4 : (pieces[0] == "kps" ? 10 : 1)
        return [1, side * side, channels]
    }

    private static func verifiedData(_ relativePath: String, root: URL,
                                     entries: [String: ArtifactEntry]) throws -> Data {
        guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains(".."),
              let entry = entries[relativePath] else { throw ReferenceError.unlistedArtifact(relativePath) }
        let file = root.appendingPathComponent(relativePath, isDirectory: false)
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.count == entry.bytes, sha256(data) == entry.sha256 else {
            throw ReferenceError.artifactDigestMismatch(relativePath)
        }
        return data
    }

    private static func parseNPY(_ data: Data) throws -> NPYTensor {
        let bytes = [UInt8](data)
        guard bytes.count >= 10,
              Array(bytes[0..<6]) == [0x93, 0x4e, 0x55, 0x4d, 0x50, 0x59] else {
            throw ReferenceError.invalidNPY
        }
        let major = bytes[6]
        let headerLength: Int
        let headerStart: Int
        switch major {
        case 1:
            headerLength = Int(UInt16(bytes[8]) | (UInt16(bytes[9]) << 8))
            headerStart = 10
        case 2, 3:
            guard bytes.count >= 12 else { throw ReferenceError.invalidNPY }
            headerLength = Int(UInt32(bytes[8]) | (UInt32(bytes[9]) << 8) |
                               (UInt32(bytes[10]) << 16) | (UInt32(bytes[11]) << 24))
            headerStart = 12
        default:
            throw ReferenceError.unsupportedNPYVersion(major)
        }
        let (dataStart, overflow) = headerStart.addingReportingOverflow(headerLength)
        guard !overflow, dataStart <= bytes.count,
              let header = String(bytes: bytes[headerStart..<dataStart], encoding: .utf8),
              capture("'descr'\\s*:\\s*'([^']+)'", in: header) == "<f4",
              capture("'fortran_order'\\s*:\\s*(True|False)", in: header) == "False",
              let shapeText = capture("'shape'\\s*:\\s*\\(([^)]*)\\)", in: header) else {
            throw ReferenceError.invalidNPYHeader
        }
        let shape = shapeText.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !shape.isEmpty, shape.allSatisfy({ $0 >= 0 }) else { throw ReferenceError.invalidNPYShape }
        var valueCount = 1
        for dimension in shape {
            let (product, productOverflow) = valueCount.multipliedReportingOverflow(by: dimension)
            guard !productOverflow else { throw ReferenceError.invalidNPYShape }
            valueCount = product
        }
        let (expectedByteCount, byteOverflow) = valueCount.multipliedReportingOverflow(by: 4)
        guard !byteOverflow, bytes.count - dataStart == expectedByteCount else {
            throw ReferenceError.invalidNPYByteCount
        }
        var values = [Float](repeating: 0, count: valueCount)
        for index in 0..<valueCount {
            let offset = dataStart + index * 4
            let bits = UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) |
                (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
            values[index] = Float(bitPattern: bits)
        }
        return NPYTensor(shape: shape, values: values)
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func ulpDistance(_ lhs: Float, _ rhs: Float) -> UInt64 {
        func orderedBits(_ value: Float) -> UInt64 {
            let bits = value.bitPattern
            let ordered = bits & 0x8000_0000 == 0 ? bits | 0x8000_0000 : ~bits
            return UInt64(ordered)
        }
        let left = orderedBits(lhs)
        let right = orderedBits(rhs)
        return left >= right ? left - right : right - left
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private enum ReferenceError: Error, CustomStringConvertible {
        case invalidRoot, manifestDigest, invalidManifest, executionReceiptDigest, invalidExecutionReceipt
        case summaryDigest, invalidSummary, stopDigest, invalidSampleReceipt(String), invalidOutputReceipt(String, String)
        case outputDigestMismatch(String, String), outputShapeMismatch(String, String), invalidReferenceRows(String)
        case rawTensorCount(Int), unlistedArtifact(String), artifactDigestMismatch(String), invalidNPY
        case unsupportedNPYVersion(UInt8), invalidNPYHeader, invalidNPYShape, invalidNPYByteCount

        var description: String {
            switch self {
            case .invalidRoot: "reference root is missing or not an absolute file URL"
            case .manifestDigest: "frozen artifact manifest SHA-256 changed"
            case .invalidManifest: "frozen artifact manifest metadata is invalid"
            case .executionReceiptDigest: "execution receipt SHA-256 changed"
            case .invalidExecutionReceipt: "execution receipt does not identify the pinned ten-case reference run"
            case .summaryDigest: "reference summary SHA-256 changed"
            case .invalidSummary: "reference summary does not match the pinned detector/output contract"
            case .stopDigest: "STOP receipt SHA-256 changed"
            case .invalidSampleReceipt(let sample): "invalid sample receipt for \(sample)"
            case .invalidOutputReceipt(let sample, let name): "invalid raw output receipt \(sample)/\(name)"
            case .outputDigestMismatch(let sample, let name): "raw output digest differs from receipt \(sample)/\(name)"
            case .outputShapeMismatch(let sample, let name): "raw output shape differs from pinned contract \(sample)/\(name)"
            case .invalidReferenceRows(let sample): "invalid FaceDetectorYN rows for \(sample)"
            case .rawTensorCount(let count): "verified \(count) raw tensors; expected 120"
            case .unlistedArtifact(let path): "reference artifact is absent from frozen manifest: \(path)"
            case .artifactDigestMismatch(let path): "reference artifact size or digest differs: \(path)"
            case .invalidNPY: "invalid NumPy array file"
            case .unsupportedNPYVersion(let version): "unsupported NumPy array format version \(version)"
            case .invalidNPYHeader: "invalid or unsupported NumPy array header"
            case .invalidNPYShape: "invalid NumPy array shape"
            case .invalidNPYByteCount: "NumPy array byte count does not match its shape"
            }
        }
    }
}
