#if os(macOS)
import AFITCCore
import CryptoKit
import Darwin
import Foundation

/// Captures local CPU ORT outputs for the frozen generated SFace tensor fixtures.
enum SFaceOutputParity {
    static let expectedFixtureReceiptSHA256 =
        "30b01266a347a702389f8daa92751d0dd6bb05582f4e0ff1e0e678551226ac84"
    static let expectedReferenceReceiptSHA256 =
        "36b6cbb3c9d71070db1a1028fe46d05f17a73ddecb1937fd25761d452596757d"
    static let expectedModelSHA256 =
        "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"
    static let expectedModelBytes = 38_696_353
    static let caseNames = [
        "near-identity",
        "rotated-scaled-translated-five-point",
        "partial-top-left-zero-border",
        "partial-bottom-right-zero-border",
        "channel-stride-sentinel",
        "quant-phase-below-8-of-32",
        "quant-phase-exact-8-of-32",
        "quant-phase-above-8-of-32",
        "uint8-half-rounding"
    ]
    static let tensorElementCount = 3 * 112 * 112
    static let outputElementCount = 128

    struct EvidenceError: Error, CustomStringConvertible {
        let description: String
    }

    struct FixtureInput {
        let file: String
        let data: Data
        let sha256: String
    }

    struct ReferenceOutput {
        let featureFile: String
        let featureData: Data
        let featureValues: [Float]
        let featureSHA256: String
        let directFile: String
        let directData: Data
        let directSHA256: String
    }

    struct Inference {
        let data: Data
        let values: [Float]
        let shape: [Int]
        let elementType: String
    }

    static func fail(_ message: String) -> EvidenceError {
        EvidenceError(description: message)
    }

    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw fail(message) }
    }

    static func parityRequested() throws -> Bool {
        switch ProcessInfo.processInfo.environment["AFITC_RUN_SFACE_OUTPUT_PARITY"] {
        case nil, "0": return false
        case "1": return true
        default: throw fail("AFITC_RUN_SFACE_OUTPUT_PARITY must be 0 or 1")
        }
    }

    /// Proves the artifact validator rejects a false expected digest before any ORT session exists.
    static func verifyWrongExpectedModelDigest(
        manifest: ModelManifest,
        byteCount: Int,
        actualDigest: String
    ) throws -> String {
        var bytes = Array(actualDigest.utf8)
        guard let first = bytes.first else { throw fail("Pinned model digest is empty") }
        bytes[0] = first == 48 ? 49 : 48
        let wrongDigest = String(decoding: bytes, as: UTF8.self)
        do {
            try manifest.validateArtifact(byteCount: byteCount, sha256: wrongDigest)
        } catch {
            return wrongDigest
        }
        throw fail("ModelManifest accepted the wrong expected model digest")
    }

    static func verifiedFile(
        root: URL,
        record: [String: Any]
    ) throws -> (String, Data, String) {
        let relative = try string(record, "file")
        let components = relative.split(separator: "/")
        try require(!relative.hasPrefix("/") && !components.contains(".."),
                    "Evidence file path escapes its receipt root")
        let data = try Data(contentsOf: root.appendingPathComponent(relative))
        let actualSHA = digest(data)
        try require(actualSHA == string(record, "sha256"),
                    "Evidence file digest mismatch: \(relative)")
        try require(data.count == integer(record, "bytes"),
                    "Evidence file byte count mismatch: \(relative)")
        return (relative, data, actualSHA)
    }

    static func floats(_ data: Data, expectedCount: Int) throws -> [Float] {
        try require(data.count == expectedCount * MemoryLayout<Float>.size,
                    "Float32 binary has an unexpected byte count")
        return data.withUnsafeBytes { raw in
            (0..<expectedCount).map { index in
                let bits = raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
                return Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
    }

    static func encoded(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * MemoryLayout<Float>.size)
        for value in values {
            var bits = value.bitPattern.littleEndian
            Swift.withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func jsonObject(_ data: Data, label: String) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw fail("\(label) is not a JSON object")
        }
        return value
    }

    static func object(_ parent: [String: Any], _ key: String) throws -> [String: Any] {
        guard let value = parent[key] as? [String: Any] else { throw fail("Missing object \(key)") }
        return value
    }

    static func asObject(_ value: Any, label: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw fail("\(label) is not an object") }
        return object
    }

    static func array(_ parent: [String: Any], _ key: String) throws -> [Any] {
        guard let value = parent[key] as? [Any] else { throw fail("Missing array \(key)") }
        return value
    }

    static func string(_ parent: [String: Any], _ key: String) throws -> String {
        guard let value = parent[key] as? String else { throw fail("Missing string \(key)") }
        return value
    }

    static func integer(_ parent: [String: Any], _ key: String) throws -> Int {
        guard let value = parent[key] as? NSNumber else { throw fail("Missing integer \(key)") }
        return value.intValue
    }

    static func integerArray(_ parent: [String: Any], _ key: String) throws -> [Int] {
        guard let values = parent[key] as? [Any] else { throw fail("Missing integer array \(key)") }
        return try values.map { value in
            guard let number = value as? NSNumber else { throw fail("Non-integer value in \(key)") }
            return number.intValue
        }
    }

    static func required<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw fail(message) }
        return value
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(file url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fileByteCount(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? -1
    }

    static func writeJSON(_ value: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    static func report(_ message: String) {
        print("[SFace parity] \(message)")
        fflush(stdout)
    }
}
#endif
