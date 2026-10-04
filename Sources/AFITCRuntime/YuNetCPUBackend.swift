import AFITCCore
import Foundation
import OnnxRuntimeBindings

struct YuNetCPUBackendFactory: YuNetBackendFactory {
    func makeBackend(artifact: VerifiedModelArtifact) throws -> any YuNetInferenceBackend {
        try YuNetCPUBackend(artifact: artifact)
    }
}

/// Exact pinned graph, CPU default provider, one intra-op thread. No CoreML provider is appended.
final class YuNetCPUBackend: YuNetInferenceBackend, @unchecked Sendable {
    let inputNames: [String]
    let outputNames: [String]
    private let environment: ORTEnv
    private let session: ORTSession
    init(artifact: VerifiedModelArtifact) throws {
        guard artifact.byteCount == YuNetRuntimeContract.artifactBytes,
              artifact.sha256 == YuNetRuntimeContract.artifactSHA256 else { throw YuNetRuntimeError.artifactRejected }
        do {
            let env = try ORTEnv(loggingLevel: .warning), options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(1)
            let session = try ORTSession(env: env, modelPath: artifact.url.path, sessionOptions: options)
            let inputs = try session.inputNames(), outputs = try session.outputNames()
            try YuNetRuntimeContract.validateNames(inputs, outputs)
            environment = env; self.session = session; inputNames = inputs; outputNames = outputs
        } catch let error as YuNetRuntimeError { throw error }
        catch { throw YuNetRuntimeError.sessionCreationFailed }
    }
    func infer(_ input: YuNetRuntimeTensor) async throws -> [YuNetRuntimeTensor] {
        try YuNetRuntimeContract.validateInput(input)
        do {
            let bytes = input.values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
            let value = try ORTValue(tensorData: bytes, elementType: .float,
                                     shape: input.shape.map(NSNumber.init(value:)))
            let outputs = try session.run(withInputs: [YuNetRuntimeContract.inputName: value],
                                          outputNames: Set(YuNetRuntimeContract.outputNames), runOptions: nil)
            guard outputs.count == YuNetRuntimeContract.outputNames.count else {
                throw YuNetRuntimeError.runtimeContractMismatch
            }
            return try YuNetRuntimeContract.outputNames.map { name in
                guard let output = outputs[name], let expected = YuNetRuntimeContract.outputShape(name) else {
                    throw YuNetRuntimeError.runtimeContractMismatch
                }
                let info = try output.tensorTypeAndShapeInfo(), shape = info.shape.map(\.intValue)
                guard info.elementType == .float, shape == expected else { throw YuNetRuntimeError.runtimeContractMismatch }
                let data = try output.tensorData() as Data, count = expected.reduce(1, *)
                guard data.count == count * MemoryLayout<Float>.size else { throw YuNetRuntimeError.runtimeContractMismatch }
                let values = data.withUnsafeBytes { raw in
                    (0..<count).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
                }
                guard values.allSatisfy(\.isFinite) else { throw YuNetRuntimeError.runtimeContractMismatch }
                return YuNetRuntimeTensor(name: name, elementType: .float32, shape: shape, values: values)
            }
        } catch let error as YuNetRuntimeError { throw error }
        catch { throw YuNetRuntimeError.backendFailed }
    }
}
