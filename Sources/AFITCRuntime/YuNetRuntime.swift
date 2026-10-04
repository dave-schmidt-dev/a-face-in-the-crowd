import AFITCCore
import Foundation

/// Independent named raw tensor; later Core adapters preserve names, shapes and values.
public struct YuNetRuntimeTensor: Equatable, Sendable {
    public enum ElementType: Sendable { case float32, float16, int32 }
    public let name: String
    public let elementType: ElementType
    public let shape: [Int]
    public let values: [Float]
    public init(name: String, elementType: ElementType, shape: [Int], values: [Float]) {
        self.name = name; self.elementType = elementType; self.shape = shape; self.values = values
    }
}

/// Photo-level provenance; no detected face UUID is created by the runtime.
public struct YuNetRuntimeProvenance: Equatable, Sendable {
    public let photoID: UUID
    public let contentVersion: Int
    public let detectorVersion: String
    public let operationID: UUID
    public let sessionEpoch: UInt64
    public let modelIdentifier: String
    public let preprocessingVersion: String
    public init(photoID: UUID, contentVersion: Int, detectorVersion: String, operationID: UUID,
                sessionEpoch: UInt64, modelIdentifier: String = YuNetRuntimeContract.identifier,
                preprocessingVersion: String = YuNetRuntimeContract.preprocessingVersion) {
        self.photoID = photoID; self.contentVersion = contentVersion; self.detectorVersion = detectorVersion
        self.operationID = operationID; self.sessionEpoch = sessionEpoch
        self.modelIdentifier = modelIdentifier; self.preprocessingVersion = preprocessingVersion
    }
}
public struct YuNetRuntimeResult: Equatable, Sendable {
    public let provenance: YuNetRuntimeProvenance
    public let outputs: [YuNetRuntimeTensor]
}
public enum YuNetRuntimeError: Error, Equatable, Sendable {
    case modelUnavailable, artifactRejected, sessionCreationFailed, invalidInput
    case runtimeContractMismatch, staleProvenance, backendFailed
}

/// Pinned graph contract. Input declarations are not runtime graph metadata observations.
public enum YuNetRuntimeContract {
    public static let identifier = "opencv-yunet-2023mar-cpu640-v1"
    public static let preprocessingVersion = "opencv410-letterbox640-bgr-raw-f32-v1"
    public static let artifactBytes = 232_589
    public static let artifactSHA256 = "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4"
    public static let inputName = "input"
    public static let inputShape = [1, 3, 640, 640]
    public static let outputNames = [8, 16, 32].flatMap { stride in
        ["cls", "obj", "bbox", "kps"].map { "\($0)_\(stride)" }
    }
    public static func outputShape(_ name: String) -> [Int]? {
        let parts = name.split(separator: "_")
        guard parts.count == 2, let stride = Int(parts[1]), [8, 16, 32].contains(stride) else { return nil }
        let channels: Int
        switch parts[0] { case "cls", "obj": channels = 1; case "bbox": channels = 4
        case "kps": channels = 10; default: return nil }
        return [1, (640 / stride) * (640 / stride), channels]
    }
    static func validateInput(_ tensor: YuNetRuntimeTensor) throws {
        guard tensor.name == inputName, tensor.elementType == .float32, tensor.shape == inputShape,
              tensor.values.count == 3 * 640 * 640,
              tensor.values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 255 }) else {
            throw YuNetRuntimeError.invalidInput
        }
    }
    static func validateNames(_ input: [String], _ output: [String]) throws {
        guard input == [inputName], output.count == outputNames.count,
              Set(output) == Set(outputNames) else { throw YuNetRuntimeError.runtimeContractMismatch }
    }
    static func validatedOutputs(_ outputs: [YuNetRuntimeTensor]) throws -> [YuNetRuntimeTensor] {
        guard outputs.count == outputNames.count else { throw YuNetRuntimeError.runtimeContractMismatch }
        var named: [String: YuNetRuntimeTensor] = [:]
        for tensor in outputs {
            guard named[tensor.name] == nil, let shape = outputShape(tensor.name),
                  tensor.elementType == .float32, tensor.shape == shape,
                  tensor.values.count == shape.reduce(1, *), tensor.values.allSatisfy(\.isFinite) else {
                throw YuNetRuntimeError.runtimeContractMismatch
            }
            named[tensor.name] = tensor
        }
        return try outputNames.map {
            guard let tensor = named[$0] else { throw YuNetRuntimeError.runtimeContractMismatch }; return tensor
        }
    }
}

protocol YuNetInferenceBackend: Sendable {
    var inputNames: [String] { get }
    var outputNames: [String] { get }
    func infer(_ input: YuNetRuntimeTensor) async throws -> [YuNetRuntimeTensor]
}
protocol YuNetBackendFactory: Sendable {
    func makeBackend(artifact: VerifiedModelArtifact) throws -> any YuNetInferenceBackend
}

/// One actual execution at a time, including requests suspended inside a backend.
public actor YuNetRuntime {
    private let backend: any YuNetInferenceBackend
    private var tail: Task<Void, Never>?
    init(backend: any YuNetInferenceBackend) { self.backend = backend }
    public func infer(from input: YuNetRuntimeTensor, provenance: YuNetRuntimeProvenance,
                      isCurrent: @escaping @Sendable (YuNetRuntimeProvenance) -> Bool = { _ in true },
                      progress: @escaping FaceEmbeddingProgressHandler = { _ in }) async throws -> YuNetRuntimeResult {
        try Task.checkCancellation()
        guard provenance.modelIdentifier == YuNetRuntimeContract.identifier,
              provenance.preprocessingVersion == YuNetRuntimeContract.preprocessingVersion,
              isCurrent(provenance) else { throw YuNetRuntimeError.staleProvenance }
        try YuNetRuntimeContract.validateInput(input)
        let gate = YuNetCancellationGate(), previous = tail, backend = self.backend
        let emit: @Sendable (FaceEmbeddingProgress.Stage) -> Void = { stage in
            progress(FaceEmbeddingProgress(stage: stage, completedUnits: stage == .completed ? 1 : 0,
                                          totalUnits: 1, modelIdentifier: YuNetRuntimeContract.identifier))
        }
        emit(.queued)
        let work = Task.detached(priority: .userInitiated) {
            await previous?.value
            do {
                guard !gate.isCancelled else { throw CancellationError() }
                guard isCurrent(provenance) else { throw YuNetRuntimeError.staleProvenance }
                emit(.runningInference)
                let output = try await backend.infer(input)
                guard !gate.isCancelled else { throw CancellationError() }
                guard isCurrent(provenance) else { throw YuNetRuntimeError.staleProvenance }
                let validated = try YuNetRuntimeContract.validatedOutputs(output)
                guard !gate.isCancelled else { throw CancellationError() }
                emit(.completed)
                return YuNetRuntimeResult(provenance: provenance, outputs: validated)
            } catch {
                if gate.isCancelled || error is CancellationError { emit(.cancelled); throw CancellationError() }
                emit(.failed); throw error
            }
        }
        tail = Task.detached { _ = try? await work.value }
        // Cancellation suppresses a result; actual backend return establishes drain.
        return try await withTaskCancellationHandler {
            let result = try await work.value
            // Actual drain precedes this parent fence, including the completed callback.
            try Task.checkCancellation()
            guard isCurrent(provenance) else { throw YuNetRuntimeError.staleProvenance }
            return result
        } onCancel: { gate.cancel() }
    }
}
private final class YuNetCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}
