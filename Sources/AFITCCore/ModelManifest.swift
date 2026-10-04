import Foundation

/// Describes a local model artifact and the tensor contract expected by its provider.
public struct ModelManifest: Codable, Equatable, Sendable {
    public let identifier: String
    public let sourceURL: String
    public let sourceRevision: String
    public let licenseIdentifier: String
    public let artifactSHA256: String
    public let artifactByteCount: Int
    public let inputName: String
    public let inputShape: [Int]
    public let inputElementType: ModelElementType
    public let outputName: String
    public let outputShape: [Int]
    public let outputElementType: ModelElementType
    public let preprocessingVersion: String

    public init(identifier: String, sourceURL: String, sourceRevision: String, licenseIdentifier: String,
                artifactSHA256: String, artifactByteCount: Int, inputName: String, inputShape: [Int],
                inputElementType: ModelElementType, outputName: String, outputShape: [Int],
                outputElementType: ModelElementType, preprocessingVersion: String) {
        self.identifier = identifier
        self.sourceURL = sourceURL
        self.sourceRevision = sourceRevision
        self.licenseIdentifier = licenseIdentifier
        self.artifactSHA256 = artifactSHA256.lowercased()
        self.artifactByteCount = artifactByteCount
        self.inputName = inputName
        self.inputShape = inputShape
        self.inputElementType = inputElementType
        self.outputName = outputName
        self.outputShape = outputShape
        self.outputElementType = outputElementType
        self.preprocessingVersion = preprocessingVersion
    }

    /// Pinned OpenCV Zoo SFace artifact; this records provenance, not rollout approval.
    public static let openCVSFace2021December = ModelManifest(
        identifier: "opencv-sface-2021dec",
        sourceURL: "https://media.githubusercontent.com/media/opencv/opencv_zoo/47534e27c9851bb1128ccc0102f1145e27f23f98/models/face_recognition_sface/face_recognition_sface_2021dec.onnx",
        sourceRevision: "47534e27c9851bb1128ccc0102f1145e27f23f98",
        licenseIdentifier: "Apache-2.0",
        artifactSHA256: "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79",
        artifactByteCount: 38_696_353,
        inputName: "data",
        inputShape: [1, 3, 112, 112],
        inputElementType: .float32,
        outputName: "fc1",
        outputShape: [1, 128],
        outputElementType: .float32,
        preprocessingVersion: "opencv-sface-aligncrop-rgb-raw-f32-v1"
    )

    /// Rejects any artifact whose acquired bytes differ from the pinned manifest.
    public func validateArtifact(byteCount: Int, sha256: String) throws {
        guard byteCount == artifactByteCount else { throw ModelManifestError.byteCountMismatch }
        let normalized = sha256.lowercased()
        guard normalized.count == 64,
              normalized.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              normalized == artifactSHA256 else { throw ModelManifestError.digestMismatch }
    }

    /// Checks the dimensions and names used by the pinned graph before inference.
    public func validateRuntime(inputNames: [String], inputShape: [Int], inputType: ModelElementType,
                                outputNames: [String], outputShape: [Int], outputType: ModelElementType) throws {
        guard inputNames == [self.inputName], inputShape == self.inputShape, inputType == inputElementType,
              outputNames == [self.outputName], outputShape == self.outputShape, outputType == outputElementType else {
            throw ModelManifestError.runtimeContractMismatch
        }
    }
}

/// ONNX tensor element types used by the dependency-free model contract.
public enum ModelElementType: String, Codable, Equatable, Sendable {
    case float32
}

/// Fail-closed errors for artifact and runtime contract validation.
public enum ModelManifestError: Error, Equatable, Sendable {
    case byteCountMismatch
    case digestMismatch
    case runtimeContractMismatch
}
