import AFITCCore
import AFITCRuntime
import CryptoKit
import Foundation

/// Authenticates the fixed OpenCV evidence before reading any tensor. No original photos.
enum YuNetORTParityEvidence {
    static func referenceRoot() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["AFITC_YUNET_REFERENCE_ROOT"],
              path.hasPrefix("/"), !path.isEmpty else { throw Failure.evidence("explicit reference root required") }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
    static let manifestSHA = "64a52cb0b1b0d97bc88e64629e0f4d1781738713e2904e7341aa8430b7b4c4db"
    struct Entry: Decodable { let path: String; let bytes: Int; let sha256: String }
    struct Manifest: Decodable {
        let status: String; let fileCountExcludingManifest: Int; let totalBytesExcludingManifest: Int
        let files: [Entry]
    }
    struct Receipt: Decodable {
        struct Tensor: Decodable { let shape: [Int]; let dtype: String; let npySHA256: String }
        struct Input: Decodable {
            let name: String; let shape: [Int]; let dtype: String; let layout: String
            let colorOrder: String; let scale: Double; let mean: [Double]; let npySHA256: String
        }
        let sampleId: String; let inputTensor: Input; let rawOutputs: [String: Tensor]; let modelSHA256: String
    }
    struct NPY { let shape: [Int]; let values: [Float] }
    enum Failure: Error { case evidence(String) }
    static func require(_ value: Bool, _ label: String) throws {
        if !value { throw Failure.evidence(label) }
    }
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func authenticatedInventory() throws -> [String: Entry] {
        let bytes = try Data(contentsOf: referenceRoot().appendingPathComponent("artifact-manifest.json"))
        try require(sha(bytes) == manifestSHA, "manifest digest")
        let manifest = try JSONDecoder().decode(Manifest.self, from: bytes)
        try require(manifest.status == "FROZEN_EVIDENCE_MANIFEST" && manifest.files.count == 171 &&
                    manifest.fileCountExcludingManifest == 171 && manifest.totalBytesExcludingManifest == 67_047_919,
                    "manifest inventory")
        var entries: [String: Entry] = [:]
        for entry in manifest.files {
            try require(entries[entry.path] == nil, "duplicate artifact")
            entries[entry.path] = entry
            _ = try verified(entry.path, entries: entries)
        }
        for (file, expected) in [
            ("STOP", "9434e66937f611370ad99ec730207fd81c4eed867641dec405291573bcfc2af3"),
            ("execution-receipt.json", "0101853f5fa4a95c7888c31d8047e153c99322438d30cebceb15539e487d8aef"),
            ("reference-summary.json", "5657f9b0f0d0489190d69ea8e372f6fb673740b2381dbfc41e1de13ea383843a")
        ] { try require(sha(try verified(file, entries: entries)) == expected, "frozen receipt digest") }
        return entries
    }
    static func verified(_ path: String, entries: [String: Entry]) throws -> Data {
        try require(!path.hasPrefix("/") && !path.split(separator: "/").contains(".."), "relative artifact path")
        guard let entry = entries[path] else { throw Failure.evidence("absent artifact") }
        let url = try referenceRoot().appendingPathComponent(path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try require(attributes[.type] as? FileAttributeType == .typeRegular && entry.bytes >= 0 &&
                    entry.bytes <= 16 * 1024 * 1024 && (attributes[.size] as? NSNumber)?.intValue == entry.bytes,
                    "artifact type/length")
        let data = try Data(contentsOf: url)
        try require(data.count == entry.bytes && sha(data) == entry.sha256, "artifact digest")
        return data
    }
    static func tensor(_ data: Data) throws -> NPY {
        try require(data.count >= 10 && Array(data.prefix(6)) == [147, 78, 85, 77, 80, 89] && data[6] == 1 && data[7] == 0,
                    "NPY version")
        let headerLength = Int(data[8]) + Int(data[9]) * 256
        try require(headerLength < 4096 && 10 + headerLength <= data.count, "NPY header length")
        let header = String(decoding: data[10..<(10 + headerLength)], as: UTF8.self)
        try require(header.contains("'descr': '<f4'") && header.contains("'fortran_order': False"), "NPY dtype/order")
        let expression = try NSRegularExpression(pattern: #"'shape':\s*\(([^)]*)\)"#)
        guard let match = expression.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let range = Range(match.range(at: 1), in: header) else { throw Failure.evidence("NPY shape") }
        let shape = header[range].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        try require(shape.count == 3 || shape.count == 4, "NPY dimensions")
        var count = 1
        for value in shape { try require(value > 0 && value <= 6400 && count <= 2_000_000 / value, "NPY bound"); count *= value }
        let offset = 10 + headerLength
        try require(data.count - offset == count * 4, "NPY tensor bytes")
        let values = data.withUnsafeBytes { raw in
            (0..<count).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + $0 * 4, as: UInt32.self))) }
        }
        try require(values.allSatisfy(\.isFinite), "NPY finite")
        return NPY(shape: shape, values: values)
    }
    static func metrics(_ actual: [Float], _ expected: [Float]) throws -> [String: Any] {
        try require(actual.count == expected.count && !actual.isEmpty && actual.allSatisfy(\.isFinite), "metric shape/finite")
        var exact = 0, maxAbs = 0.0, squares = 0.0, maxULP: UInt64 = 0
        func ordered(_ value: Float) -> UInt32 { let bits = value.bitPattern; return bits & 0x80000000 == 0 ? bits | 0x80000000 : ~bits }
        for i in actual.indices {
            let difference = abs(Double(actual[i]) - Double(expected[i]))
            maxAbs = max(maxAbs, difference); squares += difference * difference
            if actual[i].bitPattern == expected[i].bitPattern { exact += 1 }
            let a = UInt64(ordered(actual[i])), b = UInt64(ordered(expected[i]))
            maxULP = max(maxULP, a > b ? a - b : b - a)
        }
        return ["valueCount": actual.count, "finiteCount": actual.count, "exactBitsCount": exact,
                "maxAbsoluteDifference": maxAbs, "rmsDifference": sqrt(squares / Double(actual.count)), "maxULP": maxULP]
    }
    static func run(runtime: YuNetRuntime, model: URL, output: URL) async throws {
        let entries = try authenticatedInventory()
        try require(sha(try Data(contentsOf: model)) == YuNetRuntimeContract.artifactSHA256, "model before")
        var rows: [[String: Any]] = [], controls: [[String: Any]] = []
        for number in 1...10 {
            try Task.checkCancellation()
            let sample = String(format: "sample-%02d", number)
            print("[yunet-parity] actual CPU sample \(number)/10")
            let receipt = try JSONDecoder().decode(Receipt.self, from: verified(sample + "/receipt.json", entries: entries))
            try require(receipt.sampleId == sample && receipt.modelSHA256 == YuNetRuntimeContract.artifactSHA256 &&
                        receipt.inputTensor.name == "input" && receipt.inputTensor.dtype == "float32" &&
                        receipt.inputTensor.layout == "NCHW" && receipt.inputTensor.colorOrder == "B,G,R" &&
                        receipt.inputTensor.scale == 1 && receipt.inputTensor.mean == [0, 0, 0] &&
                        receipt.inputTensor.shape == YuNetRuntimeContract.inputShape &&
                        Set(receipt.rawOutputs.keys) == Set(YuNetRuntimeContract.outputNames), "sample contract")
            let bytes = try verified(sample + "/input-bgr-nchw-f32.npy", entries: entries)
            try require(sha(bytes) == receipt.inputTensor.npySHA256, "input receipt digest")
            let input = try tensor(bytes)
            let request = YuNetRuntimeTensor(name: "input", elementType: .float32, shape: input.shape, values: input.values)
            let provenance = YuNetRuntimeProvenance(photoID: UUID(), contentVersion: 1, detectorVersion: "synthetic-reference", operationID: UUID(), sessionEpoch: 1)
            let result = try await runtime.infer(from: request, provenance: provenance)
            try require(result.provenance == provenance, "echoed provenance")
            for actual in result.outputs {
                guard let contract = receipt.rawOutputs[actual.name] else { throw Failure.evidence("head receipt") }
                let data = try verified(sample + "/raw-" + actual.name + ".npy", entries: entries)
                try require(sha(data) == contract.npySHA256 && contract.dtype == "float32", "head digest/type")
                let expected = try tensor(data)
                try require(actual.elementType == .float32 && actual.shape == expected.shape && actual.shape == contract.shape,
                            "observed ORT output type/shape")
                var row = try metrics(actual.values, expected.values)
                row["sample"] = sample; row["head"] = actual.name; row["observedORTElementType"] = "float32"
                row["observedORTShape"] = actual.shape; rows.append(row)
            }
            if number == 1 {
                for label in ["wrong-channel-planes", "wrong-scale-1-over-255"] {
                    var changed = input.values
                    if label == "wrong-channel-planes" {
                        let plane = 640 * 640
                        for i in 0..<plane { changed[i] = input.values[i + 2 * plane]; changed[i + 2 * plane] = input.values[i] }
                    } else { changed = changed.map { $0 / 255 } }
                    let modified = YuNetRuntimeTensor(name: "input", elementType: .float32, shape: input.shape, values: changed)
                    let control = try await runtime.infer(from: modified, provenance: provenance)
                    var changedCount = 0, maximum = 0.0
                    for (a, b) in zip(control.outputs, result.outputs) {
                        let report = try metrics(a.values, b.values)
                        changedCount += a.values.count - (report["exactBitsCount"] as! Int)
                        maximum = max(maximum, report["maxAbsoluteDifference"] as! Double)
                    }
                    try require(changedCount > 0 && maximum > 0, "actual causal input control")
                    controls.append(["control": label, "changedFloatCount": changedCount, "maxAbsoluteDifference": maximum])
                }
            }
        }
        try require(rows.count == 120 && controls.count == 2, "complete actual diagnostic")
        try require(sha(try Data(contentsOf: model)) == YuNetRuntimeContract.artifactSHA256, "model after")
        let report: [String: Any] = ["status": "ACTUAL_CPU_RAW_HEAD_DIAGNOSTIC_NOT_IDENTITY_ACCEPTANCE", "sampleCount": 10,
            "headComparisons": 120, "runtime": "ORT1.24.2 CPU default", "intraOpThreads": 1, "coreMLAppended": false,
            "inputShapeTypeObservation": "pinned artifact/constructed tensor contract, not graph query",
            "metrics": rows, "controls": controls, "hostOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": "host execution architecture recorded separately", "crossBackendTolerance": "none adjudicated; nonzero differences retained"]
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        print("[yunet-parity] actual10 samples /120 raw heads completed; nonzero differences retained")
    }
}
