import AFITCCore
import CryptoKit
import Darwin
import Foundation

/// Verifies the fixed local YuNet artifact before constructing the real CPU session.
/// A URL/length/hash proof is retained, not an immutable snapshot owner; callers must
/// provide an immutable bundled or otherwise controlled model location through session creation.
public struct YuNetModelPreparation: Sendable {
    private let factory: any YuNetBackendFactory
    public init() { factory = YuNetCPUBackendFactory() }
    init(factory: any YuNetBackendFactory) { self.factory = factory }
    public func prepare(at url: URL, progress: @escaping FaceEmbeddingProgressHandler = { _ in }) async throws -> YuNetRuntime {
        let factory = self.factory
        let child = Task.detached(priority: .userInitiated) {
            let artifact = try Self.verify(url, progress: progress)
            try Task.checkCancellation()
            progress(FaceEmbeddingProgress(stage: .creatingSession, completedUnits: 0, totalUnits: 1,
                                          modelIdentifier: YuNetRuntimeContract.identifier))
            let backend = try factory.makeBackend(artifact: artifact)
            try Task.checkCancellation()
            return backend
        }
        do {
            let backend = try await withTaskCancellationHandler { try await child.value } onCancel: { child.cancel() }
            try Task.checkCancellation()
            try YuNetRuntimeContract.validateNames(backend.inputNames, backend.outputNames)
            try Task.checkCancellation()
            progress(FaceEmbeddingProgress(stage: .ready, completedUnits: 1, totalUnits: 1,
                                          modelIdentifier: YuNetRuntimeContract.identifier))
            return YuNetRuntime(backend: backend)
        } catch {
            progress(FaceEmbeddingProgress(stage: error is CancellationError ? .cancelled : .failed,
                                          completedUnits: 0, totalUnits: nil, modelIdentifier: YuNetRuntimeContract.identifier))
            throw error
        }
    }
    private static func verify(_ url: URL, progress: FaceEmbeddingProgressHandler) throws -> VerifiedModelArtifact {
        try Task.checkCancellation()
        guard url.isFileURL else { throw YuNetRuntimeError.modelUnavailable }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw YuNetRuntimeError.modelUnavailable }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
            throw YuNetRuntimeError.modelUnavailable
        }
        guard before.st_size == YuNetRuntimeContract.artifactBytes else { throw YuNetRuntimeError.artifactRejected }
        var digest = SHA256(), total = 0, buffer = [UInt8](repeating: 0, count: 65_536)
        progress(FaceEmbeddingProgress(stage: .verifyingArtifact, completedUnits: 0,
                                      totalUnits: Int64(before.st_size), modelIdentifier: YuNetRuntimeContract.identifier))
        while true {
            try Task.checkCancellation()
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw YuNetRuntimeError.modelUnavailable }
            if count == 0 { break }
            total += count
            guard total <= YuNetRuntimeContract.artifactBytes else { throw YuNetRuntimeError.artifactRejected }
            digest.update(data: Data(buffer.prefix(count)))
            progress(FaceEmbeddingProgress(stage: .verifyingArtifact, completedUnits: Int64(total),
                                          totalUnits: Int64(before.st_size), modelIdentifier: YuNetRuntimeContract.identifier))
        }
        var after = stat(), path = stat()
        let sha = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard total == YuNetRuntimeContract.artifactBytes, sha == YuNetRuntimeContract.artifactSHA256,
              fstat(descriptor, &after) == 0, lstat(url.path, &path) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              path.st_dev == after.st_dev, path.st_ino == after.st_ino,
              path.st_mode & S_IFMT == S_IFREG else { throw YuNetRuntimeError.artifactRejected }
        try Task.checkCancellation()
        return VerifiedModelArtifact(url: url, byteCount: total, sha256: sha)
    }
}
