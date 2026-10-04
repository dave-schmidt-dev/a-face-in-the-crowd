import XCTest
import Foundation
import AFITCCore
import AFITCRuntime
#if os(macOS)
import CryptoKit
#endif

#if os(macOS)
import Darwin
import Dispatch
/// Exercises production argument and native mapping validation without builds or devices.
final class RuntimeAdmissionRunnerTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func run(_ arguments: [String]) throws -> (Int32, String) {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let outputURL = temporary.appendingPathComponent("runner.log")
        let pidURL = temporary.appendingPathComponent("runner-child.pid")
        let supervisor = #"""
import os, signal, subprocess, sys
pid_path, output_path, *command = sys.argv[1:]
with open(output_path, "wb") as output:
    child = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT,
                             start_new_session=True)
    with open(pid_path, "w", encoding="ascii") as receipt:
        receipt.write(str(child.pid))
    try:
        status = child.wait(timeout=45)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGTERM)
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=5)
        print("[runner test] child timed out", file=sys.stderr)
        sys.exit(124)
sys.exit(status)
"""#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", supervisor, pidURL.path, outputURL.path,
                            root.appendingPathComponent("tools/verify.sh").path] + arguments
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        let completed = finished.wait(timeout: .now() + .seconds(60)) == .success
        var status: Int32 = completed ? process.terminationStatus : 124
        if !completed {
            if let value = try? String(contentsOf: pidURL, encoding: .ascii),
               let child = Int32(value), child > 1 {
                _ = kill(-child, SIGTERM)
            }
            process.terminate()
            if finished.wait(timeout: .now() + .seconds(5)) != .success {
                if let value = try? String(contentsOf: pidURL, encoding: .ascii),
                   let child = Int32(value), child > 1 {
                    _ = kill(-child, SIGKILL)
                }
                _ = kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + .seconds(5))
            }
            status = 124
        }
        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        return (status, completed ? output : output + "\n[runner test] bounded wait expired")
    }
    func testRuntimeAdmissionRejectsWrongCLI() throws {
        for arguments in [["task1.4", "--runtime-admission"], ["task2.runtime-admission", "--runtime-admission", "extra"]] {
            let result = try run(arguments)
            XCTAssertNotEqual(result.0, 0); XCTAssertTrue(result.1.contains("Usage:"))
        }
    }
    func testNativeUnitSelectorsValidateTypeMembershipAndDeclarations() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let path = temporary.appendingPathComponent("manifest.json")
        let original = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("tools/test-manifest.json"))) as! [String: Any]
        let valid = try run(["task2.runtime-admission", "--validate-manifest", root.appendingPathComponent("tools/test-manifest.json").path])
        XCTAssertEqual(valid.0, 0, valid.1)
        let badValues: [Any] = [[], "not-an-array", [42], ["UITests.ModelContractTests/testCPUUntrainedAddKnownInput"],
                               ["AFITCCoreTests.ModelContractTests/testAbsentRuntimeMethod"],
                               ["AFITCCoreTests.ModelContractTests/testRuntimeAdmissionRejectsWrongCLI"]]
        for value in badValues {
            var manifest = original, tasks = original["tasks"] as! [String: Any]
            var task = tasks["task2.runtime-admission"] as! [String: Any]
            var targets = task["targets"] as! [String: Any], config = targets["AFITCCoreTests"] as! [String: Any]
            config["nativeUnitSelectors"] = value; targets["AFITCCoreTests"] = config
            task["targets"] = targets; tasks["task2.runtime-admission"] = task; manifest["tasks"] = tasks
            try JSONSerialization.data(withJSONObject: manifest).write(to: path)
            let result = try run(["task2.runtime-admission", "--validate-manifest", path.path])
            XCTAssertNotEqual(result.0, 0, "Invalid native mapping passed: \(value)")
            XCTAssertTrue(result.1.contains("ERROR:"))
        }
    }
}

#endif

#if os(iOS) || os(macOS)
import OnnxRuntimeBindings

/// Untrained arithmetic proves runtime admission only, never recognition or provider partitioning.
final class ModelContractTests: XCTestCase {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
    private func model(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("synthetic-add.onnx")
        try SyntheticAddModel.bytes.write(to: url)
        return url
    }
    private func assertAdd(coreML: Bool) throws {
        let env = try ORTEnv(loggingLevel: .warning)
        XCTAssertEqual(ORTVersion(), "1.24.2")
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        if coreML {
            guard ORTIsCoreMLExecutionProviderAvailable() else {
                XCTFail("Pinned runtime does not expose the required CoreML provider"); return
            }
            let provider = ORTCoreMLExecutionProviderOptions()
            provider.useCPUOnly = true
            try options.appendCoreMLExecutionProvider(with: provider)
        }
        let session = try ORTSession(env: env, modelPath: model(in: directory()).path, sessionOptions: options)
        XCTAssertEqual(Set(try session.inputNames()), ["x", "y"])
        XCTAssertEqual(try session.outputNames(), ["z"])
        func tensor(_ values: [Float]) throws -> ORTValue {
            let data = values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
            return try ORTValue(tensorData: data, elementType: .float, shape: [2])
        }
        let outputs = try session.run(withInputs: ["x": tensor([1, 2]), "y": tensor([3, 4])],
                                      outputNames: ["z"], runOptions: nil)
        let output = try XCTUnwrap(outputs["z"])
        let info = try output.tensorTypeAndShapeInfo()
        XCTAssertEqual(info.elementType, .float); XCTAssertEqual(info.shape, [2])
        let data = try output.tensorData() as Data
        XCTAssertEqual(data.count, 2 * MemoryLayout<Float>.size)
        guard data.count == 8 else { return }
        let actual = data.withUnsafeBytes { [$0.loadUnaligned(fromByteOffset: 0, as: Float.self),
                                            $0.loadUnaligned(fromByteOffset: 4, as: Float.self)] }
        XCTAssertEqual(actual, [4, 6])
        // A registered CoreML session may execute this small graph through CPU fallback.
    }
    func testCPUUntrainedAddKnownInput() throws { try assertAdd(coreML: false) }
    func testCoreMLRegistrationAndUntrainedAddOutput() throws { try assertAdd(coreML: true) }

    func testPinnedSFaceManifestAcceptsExactArtifactAndRejectsDrift() throws {
        let manifest = ModelManifest.openCVSFace2021December
        XCTAssertEqual(manifest.inputName, "data")
        XCTAssertEqual(manifest.inputShape, [1, 3, 112, 112])
        XCTAssertEqual(manifest.outputName, "fc1")
        XCTAssertEqual(manifest.outputShape, [1, 128])
        XCTAssertEqual(manifest.licenseIdentifier, "Apache-2.0")
        XCTAssertNoThrow(try manifest.validateArtifact(byteCount: 38_696_353,
            sha256: "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"))
        XCTAssertThrowsError(try manifest.validateArtifact(byteCount: 38_696_352,
            sha256: manifest.artifactSHA256))
        XCTAssertThrowsError(try manifest.validateArtifact(byteCount: manifest.artifactByteCount,
            sha256: String(repeating: "0", count: 64)))
        XCTAssertThrowsError(try manifest.validateRuntime(inputNames: ["wrong"], inputShape: manifest.inputShape,
            inputType: .float32, outputNames: [manifest.outputName], outputShape: manifest.outputShape,
            outputType: .float32))
    }

    func testModelTensorRejectsInvalidShapesCountsAndNonFiniteValues() {
        XCTAssertThrowsError(try ModelTensor(shape: [1, 0], values: []))
        XCTAssertThrowsError(try ModelTensor(shape: [1, 2], values: [1]))
        XCTAssertThrowsError(try ModelTensor(shape: [1, 1], values: [.infinity]))
        XCTAssertNoThrow(try ModelTensor(shape: [1, 2], values: [0, 255]))
    }

    func testEmbeddingNormalizationAndCosineMathControls() throws {
        let manifest = ModelManifest.openCVSFace2021December
        func vector(_ first: Float, _ second: Float) -> EmbeddingVector {
            var values = [Float](repeating: 0, count: 128)
            values[0] = first; values[1] = second
            return EmbeddingVector(modelIdentifier: manifest.identifier, values: values)
        }
        let threeFour = vector(3, 4)
        let normalized = try threeFour.normalized(using: manifest)
        XCTAssertEqual(normalized.values[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(normalized.values[1], 0.8, accuracy: 1e-6)
        XCTAssertEqual(try threeFour.cosineSimilarity(to: threeFour, using: manifest), 1, accuracy: 1e-6)
        XCTAssertEqual(try threeFour.cosineSimilarity(to: vector(-4, 3), using: manifest), 0, accuracy: 1e-6)
        XCTAssertEqual(try threeFour.cosineSimilarity(to: vector(-3, -4), using: manifest), -1, accuracy: 1e-6)
        XCTAssertThrowsError(try vector(0, 0).normalized(using: manifest))
        XCTAssertThrowsError(try EmbeddingVector(modelIdentifier: manifest.identifier,
            values: [Float](repeating: .nan, count: 128)).normalized(using: manifest))
        XCTAssertThrowsError(try EmbeddingVector(modelIdentifier: manifest.identifier,
            values: [Float](repeating: 1, count: 127)).normalized(using: manifest))
        XCTAssertThrowsError(try EmbeddingVector(modelIdentifier: "other", values: threeFour.values)
            .normalized(using: manifest))
    }

    #if os(macOS)
    /// Opt-in, CPU-only diagnostic against the pinned trained artifact and generated tensor input.
    func testSFaceCPUActualModelContractWhenOptedIn() async throws {
        guard ProcessInfo.processInfo.environment["AFITC_RUN_SFACE_MODEL_TESTS"] == "1" else {
            throw XCTSkip("Set AFITC_RUN_SFACE_MODEL_TESTS=1 to run the local trained-model diagnostic")
        }
        let environment = ProcessInfo.processInfo.environment
        let modelPath = environment["AFITC_SFACE_MODEL_PATH"]
            ?? projectRoot.appendingPathComponent("models/face_recognition_sface_2021dec.onnx").path
        let modelURL = URL(fileURLWithPath: modelPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelPath), "Opt-in SFace model is missing")
        let attributes = try FileManager.default.attributesOfItem(atPath: modelPath)
        let modelByteCount = (attributes[.size] as? NSNumber)?.intValue ?? -1
        let manifest = ModelManifest.openCVSFace2021December
        let modelDigestBefore = try Self.sha256(file: modelURL)
        try manifest.validateArtifact(byteCount: modelByteCount, sha256: modelDigestBefore)
        let parityRequested = try SFaceOutputParity.parityRequested()
        let wrongExpectedModelDigest = parityRequested
            ? try SFaceOutputParity.verifyWrongExpectedModelDigest(
                manifest: manifest, byteCount: modelByteCount, actualDigest: modelDigestBefore)
            : nil
        defer {
            let finalDigest = try? Self.sha256(file: modelURL)
            let finalSize = (try? FileManager.default.attributesOfItem(atPath: modelPath))?[.size] as? NSNumber
            XCTAssertNotNil(finalDigest, "Pinned SFace model disappeared during inference")
            XCTAssertEqual(finalDigest, modelDigestBefore, "Pinned SFace model changed during inference")
            XCTAssertEqual(finalSize?.intValue, modelByteCount, "Pinned SFace model length changed during inference")
        }

        let runtime = try await ModelPreparation(manifest: manifest).prepare(at: modelURL)

        let values = (0..<(3 * 112 * 112)).map { index -> Float in
            let channel = index / (112 * 112)
            let pixel = index % (112 * 112)
            let y = pixel / 112
            let x = pixel % 112
            return Float((channel * 73 + x * 3 + y * 5) % 256)
        }
        let tensor = try ModelTensor(shape: manifest.inputShape, values: values)
        let provenance = FaceEmbeddingProvenance(
            photoID: UUID(), contentVersion: 1, faceID: UUID(), detectorVersion: "synthetic-contract-v1",
            operationID: UUID(), sessionEpoch: 1, modelIdentifier: manifest.identifier,
            preprocessingVersion: manifest.preprocessingVersion)
        let result = try await runtime.embedding(from: tensor, provenance: provenance)
        XCTAssertEqual(result.provenance, provenance)
        XCTAssertEqual(result.embedding.values.count, 128)
        XCTAssertTrue(result.embedding.values.allSatisfy(\.isFinite))
        print("[SFace diagnostic] AFITCRuntime CPU tensor passed; input=[1,3,112,112] float32; output=[1,128] float32; vector values omitted")
        try await SFaceOutputParity.run(
            runtime: runtime,
            provenance: provenance,
            manifest: manifest,
            modelURL: modelURL,
            modelDigestBefore: modelDigestBefore,
            wrongExpectedModelDigest: wrongExpectedModelDigest,
            defaultEvidenceRoot: projectRoot)
    }

    private static func sha256(file url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    #endif

    func testMissingAndCorruptModelsFailSessionCreation() throws {
        let env = try ORTEnv(loggingLevel: .warning), options = try ORTSessionOptions()
        let root = try directory()
        XCTAssertThrowsError(try ORTSession(env: env, modelPath: root.appendingPathComponent("missing.onnx").path,
                                           sessionOptions: options))
        let corrupt = root.appendingPathComponent("corrupt.onnx")
        try Data([0xff, 0x00, 0x01]).write(to: corrupt)
        XCTAssertThrowsError(try ORTSession(env: env, modelPath: corrupt.path, sessionOptions: options))
    }
}

/// Minimal protobuf wire writer for an initializer-free FLOAT[2] Add graph.
/// Field numbers follow https://github.com/onnx/onnx/blob/main/onnx/onnx.proto.
/// IR8/opset13 contains no labels, learned parameters, external data or private inputs.
private enum SyntheticAddModel {
    static func varint(_ value: UInt64) -> Data {
        var number = value, bytes = Data()
        while number >= 128 { bytes.append(UInt8(number & 127) | 128); number >>= 7 }
        bytes.append(UInt8(number)); return bytes
    }
    static func integer(_ field: UInt64, _ value: UInt64) -> Data { varint(field << 3) + varint(value) }
    static func message(_ field: UInt64, _ value: Data) -> Data {
        varint((field << 3) | 2) + varint(UInt64(value.count)) + value
    }
    static func string(_ field: UInt64, _ value: String) -> Data { message(field, Data(value.utf8)) }
    static func value(_ name: String) -> Data {
        let dimension = integer(1, 2)
        let shape = message(1, dimension)
        let tensorType = integer(1, 1) + message(2, shape)
        return string(1, name) + message(2, message(1, tensorType))
    }
    static var bytes: Data {
        let node = string(1, "x") + string(1, "y") + string(2, "z") + string(4, "Add")
        let graph = message(1, node) + string(2, "afitc-untrained-add") +
            message(11, value("x")) + message(11, value("y")) + message(12, value("z"))
        return integer(1, 8) + string(2, "AFITC synthetic runtime admission") +
            message(7, graph) + message(8, integer(2, 13))
    }
}
#endif
