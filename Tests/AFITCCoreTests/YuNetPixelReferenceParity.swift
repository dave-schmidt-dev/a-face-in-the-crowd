import CryptoKit
import Foundation
import XCTest
@testable import AFITCCore

enum YuNetPixelReferenceParity {
    private static let expectedManifestSHA256 = "64a52cb0b1b0d97bc88e64629e0f4d1781738713e2904e7341aa8430b7b4c4db"
    private static let expectedExecutionReceiptSHA256 = "0101853f5fa4a95c7888c31d8047e153c99322438d30cebceb15539e487d8aef"

    static func assertAllTen(referenceDirectory: URL) throws {
        guard referenceDirectory.lastPathComponent == "phase2.yunet640-reference" else {
            throw failure("reference path is not the frozen phase2.yunet640-reference directory")
        }
        let manifestURL = referenceDirectory.appendingPathComponent("artifact-manifest.json")
        let executionURL = referenceDirectory.appendingPathComponent("execution-receipt.json")
        try requireHash(manifestURL, expected: expectedManifestSHA256, label: "artifact manifest")
        try requireHash(executionURL, expected: expectedExecutionReceiptSHA256, label: "execution receipt")

        let manifest = try json(manifestURL)
        let execution = try json(executionURL)
        let artifactRows = manifest["files"] as? [[String: Any]] ?? []
        let expectedArtifacts = Dictionary(uniqueKeysWithValues: artifactRows.compactMap { row -> (String, String)? in
            guard let path = row["path"] as? String, let digest = row["sha256"] as? String else { return nil }
            return (path, digest)
        })
        let inputRows = execution["inputRGBs"] as? [[String: Any]] ?? []
        guard artifactRows.count == 171, inputRows.count == 10 else {
            throw failure("frozen receipt inventory does not have 171 outputs and ten canonical inputs")
        }

        let sourceDirectory = referenceDirectory.deletingLastPathComponent()
            .appendingPathComponent("phase2.yunet-host-comparison", isDirectory: true)
        for ordinal in 1...10 {
            let sample = String(format: "sample-%02d", ordinal)
            let relativeInput = ".logs/verification/phase2.yunet-host-comparison/\(sample).rgb"
            guard let inputRow = inputRows.first(where: { ($0["path"] as? String) == relativeInput }),
                  let width = inputRow["width"] as? Int,
                  let height = inputRow["height"] as? Int,
                  let inputDigest = inputRow["sha256"] as? String else {
                throw failure("execution receipt has no canonical RGB binding for \(sample)")
            }
            let inputURL = sourceDirectory.appendingPathComponent("\(sample).rgb")
            let inputData = try Data(contentsOf: inputURL, options: .mappedIfSafe)
            try requireHash(inputData, expected: inputDigest, label: "canonical RGB \(sample)")
            let raster = try RGB8Raster(width: width, height: height, bytes: Array(inputData))
            let prepared = try YuNetRasterPreprocessor.prepare(raster: raster)

            let canvasRelative = "\(sample)/letterbox640.rgb"
            let tensorRelative = "\(sample)/input-bgr-nchw-f32.npy"
            let receiptRelative = "\(sample)/receipt.json"
            let canvasURL = referenceDirectory.appendingPathComponent(canvasRelative)
            let tensorURL = referenceDirectory.appendingPathComponent(tensorRelative)
            let receiptURL = referenceDirectory.appendingPathComponent(receiptRelative)
            try requireManifestHash(canvasURL, relativePath: canvasRelative, expectedArtifacts: expectedArtifacts)
            try requireManifestHash(tensorURL, relativePath: tensorRelative, expectedArtifacts: expectedArtifacts)
            try requireManifestHash(receiptURL, relativePath: receiptRelative, expectedArtifacts: expectedArtifacts)

            let canvas = try Data(contentsOf: canvasURL, options: .mappedIfSafe)
            let actualCanvas = Data(prepared.letterboxedRGB.bytes)
            guard actualCanvas == canvas else {
                throw mismatch(sample, "RGB canvas", firstDifference(actualCanvas, canvas))
            }
            let expectedTensorBits = try readFloat32NCHW(tensorURL)
            guard expectedTensorBits.count == prepared.modelInput.values.count else {
                throw failure("\(sample) tensor element count differs from frozen NCHW reference")
            }
            if let index = expectedTensorBits.indices.first(where: {
                expectedTensorBits[$0] != prepared.modelInput.values[$0].bitPattern
            }) {
                throw mismatch(sample, "BGR NCHW tensor", index)
            }
            try compareGeometry(prepared.geometry, receiptURL: receiptURL, sample: sample)
        }
        print("[YuNet pixel parity] ten canonical RGB cases matched frozen OpenCV 4.10 RGB canvases, tensor bits, and rounded geometry")
    }

    private static func compareGeometry(_ actual: YuNet640Geometry, receiptURL: URL, sample: String) throws {
        let root = try json(receiptURL)
        guard let letterbox = root["letterbox"] as? [String: Any] else {
            throw failure("\(sample) reference receipt has no letterbox geometry")
        }
        let integerFields: [(String, Int)] = [
            ("resizedWidth", actual.resizedWidth), ("resizedHeight", actual.resizedHeight),
            ("padLeft", actual.padLeft), ("padTop", actual.padTop),
            ("padRight", actual.padRight), ("padBottom", actual.padBottom)
        ]
        for (key, value) in integerFields where (letterbox[key] as? Int) != value {
            throw failure("\(sample) geometry field \(key) differs from the frozen receipt")
        }
        guard let x = letterbox["effectiveScaleX"] as? Double,
              let y = letterbox["effectiveScaleY"] as? Double,
              x.bitPattern == actual.effectiveScaleX.bitPattern,
              y.bitPattern == actual.effectiveScaleY.bitPattern else {
            throw failure("\(sample) effective scale differs from the frozen receipt")
        }
    }

    private static func requireManifestHash(_ url: URL, relativePath: String,
                                           expectedArtifacts: [String: String]) throws {
        guard let expected = expectedArtifacts[relativePath] else {
            throw failure("frozen artifact manifest omits \(relativePath)")
        }
        try requireHash(url, expected: expected, label: relativePath)
    }

    private static func requireHash(_ url: URL, expected: String, label: String) throws {
        try requireHash(Data(contentsOf: url, options: .mappedIfSafe), expected: expected, label: label)
    }

    private static func requireHash(_ data: Data, expected: String, label: String) throws {
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw failure("\(label) SHA-256 differs from its frozen binding") }
    }

    private static func json(_ url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw failure("invalid frozen JSON receipt at \(url.lastPathComponent)")
        }
        return value
    }

    private static func readFloat32NCHW(_ url: URL) throws -> [UInt32] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let bytes = [UInt8](data)
        guard bytes.count >= 10, Array(bytes[0..<6]) == [0x93, 0x4e, 0x55, 0x4d, 0x50, 0x59] else {
            throw failure("invalid NPY header for \(url.lastPathComponent)")
        }
        let major = bytes[6]
        let headerLength: Int
        let headerStart: Int
        if major == 1 {
            headerLength = Int(bytes[8]) | Int(bytes[9]) << 8
            headerStart = 10
        } else if major == 2 || major == 3 {
            guard bytes.count >= 12 else { throw failure("truncated NPY header") }
            headerLength = Int(bytes[8]) | Int(bytes[9]) << 8 | Int(bytes[10]) << 16 | Int(bytes[11]) << 24
            headerStart = 12
        } else {
            throw failure("unsupported NPY version")
        }
        let payloadStart = headerStart + headerLength
        guard payloadStart <= bytes.count,
              let header = String(bytes: bytes[headerStart..<payloadStart], encoding: .ascii),
              header.contains("'descr': '<f4'"), header.contains("'fortran_order': False"),
              header.contains("'shape': (1, 3, 640, 640)") else {
            throw failure("unexpected NPY dtype, order, shape, or header")
        }
        let payloadBytes = bytes.count - payloadStart
        guard payloadBytes == 1 * 3 * 640 * 640 * MemoryLayout<UInt32>.size else {
            throw failure("unexpected NPY payload byte count")
        }
        return stride(from: payloadStart, to: bytes.count, by: 4).map { offset in
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
    }

    private static func firstDifference(_ lhs: Data, _ rhs: Data) -> Int {
        let commonCount = min(lhs.count, rhs.count)
        if let index = (0..<commonCount).first(where: { lhs[$0] != rhs[$0] }) { return index }
        return commonCount
    }

    private static func mismatch(_ sample: String, _ artifact: String, _ index: Int) -> NSError {
        failure("\(sample) \(artifact) differs at flat index \(index)")
    }

    private static func failure(_ description: String) -> NSError {
        NSError(domain: "AFITCYuNetPixelParity", code: 1,
                userInfo: [NSLocalizedDescriptionKey: description])
    }
}
