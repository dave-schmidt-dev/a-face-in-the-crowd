import CryptoKit
import Foundation

/// The two immutable model artifacts copied into the AFITC app bundle.
public enum BundledModel: String, CaseIterable, Sendable {
    case yuNet2023Mar = "yunet-2023mar"
    case sface2021Dec = "sface-2021dec"

    public var descriptor: BundledModelDescriptor {
        switch self {
        case .yuNet2023Mar:
            BundledModelDescriptor(
                identifier: rawValue,
                filename: "face_detection_yunet_2023mar.onnx",
                resourceName: "face_detection_yunet_2023mar",
                byteCount: 232_589,
                sha256: "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4"
            )
        case .sface2021Dec:
            BundledModelDescriptor(
                identifier: rawValue,
                filename: "face_recognition_sface_2021dec.onnx",
                resourceName: "face_recognition_sface_2021dec",
                byteCount: 38_696_353,
                sha256: "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"
            )
        }
    }
}

/// Pinned metadata needed to identify one immutable app-bundle resource.
public struct BundledModelDescriptor: Equatable, Sendable {
    public let identifier: String
    public let filename: String
    public let resourceName: String
    public let byteCount: Int
    public let sha256: String

    init(identifier: String, filename: String, resourceName: String,
         byteCount: Int, sha256: String) {
        self.identifier = identifier
        self.filename = filename
        self.resourceName = resourceName
        self.byteCount = byteCount
        self.sha256 = sha256.lowercased()
    }
}

/// Incremental verification progress in exact model-file bytes.
public struct BundledModelProgress: Equatable, Sendable {
    public let modelIdentifier: String
    public let completedBytes: Int64
    public let totalBytes: Int64

    public init(modelIdentifier: String, completedBytes: Int64, totalBytes: Int64) {
        self.modelIdentifier = modelIdentifier
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }
}

/// A bundle URL that passed the pinned regular-file, size and digest checks.
public struct VerifiedBundledModel: Equatable, Sendable {
    public let descriptor: BundledModelDescriptor
    public let url: URL
    public let sha256: String
    public let byteCount: Int

    init(descriptor: BundledModelDescriptor, url: URL, sha256: String, byteCount: Int) {
        self.descriptor = descriptor
        self.url = url
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

/// Fail-closed outcomes before any caller constructs a model session.
public enum BundledModelResourceError: Error, Equatable, Sendable {
    case missing(String)
    case notRegularFile(String)
    case byteCountMismatch(String)
    case digestMismatch(String)
    case cancelled(String)
}

/// Resolves only fixed app-bundle resources and never copies or downloads model bytes.
public enum BundledModelResources {
    public typealias ProgressHandler = @Sendable (BundledModelProgress) -> Void

    /// Finds a fixed ONNX resource in the immutable main bundle and verifies its bytes.
    public static func verify(
        _ model: BundledModel,
        in bundle: Bundle = .main,
        progress: @escaping ProgressHandler = { _ in }
    ) throws -> VerifiedBundledModel {
        let descriptor = model.descriptor
        guard let url = bundle.url(forResource: descriptor.resourceName, withExtension: "onnx") else {
            throw BundledModelResourceError.missing(descriptor.identifier)
        }
        return try verify(descriptor, at: url, progress: progress)
    }

    /// Internal seam for small generated test descriptors; production uses fixed model cases.
    static func verify(
        _ descriptor: BundledModelDescriptor,
        at url: URL?,
        progress: @escaping ProgressHandler = { _ in },
        cancellationCheck: () -> Bool = { Task<Never, Never>.isCancelled }
    ) throws -> VerifiedBundledModel {
        guard let url else { throw BundledModelResourceError.missing(descriptor.identifier) }
        do {
            guard !cancellationCheck() else { throw CancellationError() }
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
                throw BundledModelResourceError.notRegularFile(descriptor.identifier)
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else {
                throw BundledModelResourceError.notRegularFile(descriptor.identifier)
            }
            guard let fileSize = values.fileSize, fileSize == descriptor.byteCount else {
                throw BundledModelResourceError.byteCountMismatch(descriptor.identifier)
            }

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            var completed: Int64 = 0
            while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
                guard !cancellationCheck() else { throw CancellationError() }
                completed += Int64(data.count)
                guard completed <= Int64(descriptor.byteCount) else {
                    throw BundledModelResourceError.byteCountMismatch(descriptor.identifier)
                }
                hasher.update(data: data)
                progress(BundledModelProgress(
                    modelIdentifier: descriptor.identifier,
                    completedBytes: completed,
                    totalBytes: Int64(descriptor.byteCount)
                ))
            }
            guard completed == Int64(descriptor.byteCount) else {
                throw BundledModelResourceError.byteCountMismatch(descriptor.identifier)
            }
            guard !cancellationCheck() else { throw CancellationError() }
            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == descriptor.sha256 else {
                throw BundledModelResourceError.digestMismatch(descriptor.identifier)
            }
            return VerifiedBundledModel(
                descriptor: descriptor,
                url: url,
                sha256: actual,
                byteCount: descriptor.byteCount
            )
        } catch is CancellationError {
            throw BundledModelResourceError.cancelled(descriptor.identifier)
        } catch let error as BundledModelResourceError {
            throw error
        } catch {
            throw BundledModelResourceError.missing(descriptor.identifier)
        }
    }
}
