import AFITCCore
import Foundation
import OnnxRuntimeBindings

struct SFaceCPUBackendFactory: EmbeddingInferenceBackendFactory {
    func makeBackend(artifact: VerifiedModelArtifact, manifest: ModelManifest) throws
        -> any EmbeddingInferenceBackend {
        try SFaceCPUBackend(artifact: artifact, manifest: manifest)
    }
}

/// ONNX Runtime CPU adapter. The session is only reached through the serialized runtime queue.
final class SFaceCPUBackend: EmbeddingInferenceBackend, @unchecked Sendable {
    let metadata: EmbeddingRuntimeMetadata
    private let manifest: ModelManifest
    private let environment: ORTEnv
    private let session: ORTSession

    init(artifact: VerifiedModelArtifact, manifest: ModelManifest) throws {
        guard artifact.byteCount == manifest.artifactByteCount,
              artifact.sha256 == manifest.artifactSHA256 else {
            throw FaceEmbeddingRuntimeError.artifactRejected
        }
        do {
            let environment = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(1)
            let session = try ORTSession(env: environment, modelPath: artifact.url.path,
                                          sessionOptions: options)
            let inputNames = try session.inputNames()
            let outputNames = try session.outputNames()
            guard inputNames == [manifest.inputName], outputNames == [manifest.outputName] else {
                throw FaceEmbeddingRuntimeError.runtimeContractMismatch
            }

            self.manifest = manifest
            self.environment = environment
            self.session = session
            // ORT 1.24.2's Swift wrapper exposes graph names but no input type/shape query.
            // Those are pinned by this artifact digest and enforced on each submitted tensor.
            self.metadata = EmbeddingRuntimeMetadata(
                inputNames: inputNames, inputShape: manifest.inputShape,
                inputElementType: manifest.inputElementType,
                outputNames: outputNames, outputShape: manifest.outputShape,
                outputElementType: manifest.outputElementType)
        } catch let error as FaceEmbeddingRuntimeError {
            throw error
        } catch {
            throw FaceEmbeddingRuntimeError.sessionCreationFailed
        }
    }

    func infer(_ input: ModelTensor) async throws -> EmbeddingVector {
        guard input.shape == manifest.inputShape,
              input.values.count == manifest.inputShape.reduce(1, *),
              input.values.allSatisfy(\.isFinite) else {
            throw FaceEmbeddingRuntimeError.invalidInput
        }
        do {
            let inputValue = try ORTValue(tensorData: input.values.withUnsafeBytes { raw in
                NSMutableData(bytes: raw.baseAddress!, length: raw.count)
            }, elementType: .float, shape: input.shape.map(NSNumber.init(value:)))
            let outputs = try session.run(withInputs: [manifest.inputName: inputValue],
                                          outputNames: [manifest.outputName], runOptions: nil)
            guard let output = outputs[manifest.outputName] else {
                throw FaceEmbeddingRuntimeError.runtimeContractMismatch
            }
            let info = try output.tensorTypeAndShapeInfo()
            let shape = info.shape.map(\.intValue)
            guard info.elementType == .float, shape == manifest.outputShape else {
                throw FaceEmbeddingRuntimeError.runtimeContractMismatch
            }
            let outputData = try output.tensorData() as Data
            let count = manifest.outputShape.reduce(1, *)
            guard outputData.count == count * MemoryLayout<Float>.size else {
                throw FaceEmbeddingRuntimeError.runtimeContractMismatch
            }
            let values = outputData.withUnsafeBytes { raw in
                (0..<count).map {
                    raw.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self)
                }
            }
            guard values.allSatisfy(\.isFinite) else {
                throw FaceEmbeddingRuntimeError.runtimeContractMismatch
            }
            return EmbeddingVector(modelIdentifier: manifest.identifier, values: values)
        } catch let error as FaceEmbeddingRuntimeError {
            throw error
        } catch {
            throw FaceEmbeddingRuntimeError.backendFailed
        }
    }
}
