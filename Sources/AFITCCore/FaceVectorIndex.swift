import Foundation

/// Exact identity of one indexed vector: the detected face plus the model, preprocessing and
/// source-byte generation that produced it. Any component differing from current state is stale.
public struct FaceVectorKey: Sendable, Hashable {
    public let face: FaceKey
    public let modelIdentifier: String
    public let preprocessingVersion: String
    public let contentHash: String
    public init(face: FaceKey, modelIdentifier: String, preprocessingVersion: String, contentHash: String) {
        self.face = face; self.modelIdentifier = modelIdentifier
        self.preprocessingVersion = preprocessingVersion; self.contentHash = contentHash
    }
}

/// Outcome of offering one vector to a bounded index.
public enum FaceVectorInsertResult: Sendable, Equatable {
    case inserted, replaced
    /// The index is at capacity; nothing was added. Callers surface "index full".
    case full
}

/// Outcome of offering one photo's vectors to the index as a single all-or-nothing batch.
public enum FaceVectorBatchResult: Sendable, Equatable {
    /// Every entry is now held; the count of entries offered.
    case inserted(Int)
    /// The index was invalidated after the caller captured its epoch; nothing was added.
    case stale
    /// Adding the batch would exceed capacity; nothing was added.
    case full
}

/// Session-scoped face vector storage. Implementations hold unit vectors in RAM only and are
/// never Codable, persisted, exported or logged (INV-9 evaluation boundary, D2 = RAM-only).
public protocol FaceVectorIndex: AnyObject, Sendable {
    /// Maximum number of distinct keys retained.
    var capacity: Int { get }
    /// Current number of retained keys.
    var count: Int { get }
    /// Validates and normalizes `vector` once against `manifest`, then stores it under the exact
    /// key. A newer entry for the same `FaceKey` replaces any older model/hash entry for that face.
    @discardableResult
    func insert(_ vector: EmbeddingVector, face: FaceKey, contentHash: String,
                manifest: ModelManifest) throws -> FaceVectorInsertResult
    /// Validates and normalizes every entry first, then, under one lock, admits all of them only if
    /// no `invalidate()` happened since `epoch` was read and capacity allows the whole batch. An
    /// admitted batch (even an empty one) also records `photoID` as attempted for this hash and manifest.
    func insert(_ entries: [(face: FaceKey, vector: EmbeddingVector)], photoID: UUID, contentHash: String,
                manifest: ModelManifest, epoch: UInt64) throws -> FaceVectorBatchResult
    /// True when a batch for `photoID` with this hash and manifest was admitted since the last `invalidate()`.
    func wasAttempted(photoID: UUID, contentHash: String, manifest: ModelManifest) -> Bool
    /// Returns a consistent copy of every retained unit vector for one ranking pass.
    func snapshot() -> [FaceVectorKey: [Float]]
    /// Generation bumped by every `invalidate()`; work that read an older value must not publish.
    var epoch: UInt64 { get }
    /// Drops every retained vector and attempt record, and bumps `epoch`.
    func invalidate()
}

/// Errors raised before a vector is admitted to the index.
public enum FaceVectorIndexError: Error, Sendable, Equatable {
    case invalidCapacity, emptyContentHash
}

/// Bounded, lock-protected RAM implementation. Defaults to 20,000 faces (about 10 MB of SFace
/// vectors); when full it stops adding rather than evicting so results never silently shift.
public final class InMemoryFaceVectorIndex: FaceVectorIndex, @unchecked Sendable {
    public static let defaultCapacity = 20_000
    public let capacity: Int
    private let lock = NSLock()
    private var vectors: [FaceVectorKey: [Float]] = [:]
    private var keysByFace: [FaceKey: FaceVectorKey] = [:]
    /// Photos whose batch was admitted, so faces the producer could not embed are not re-inferred.
    private var attempted: Set<AttemptKey> = []
    private var generation: UInt64 = 0

    private struct AttemptKey: Hashable {
        let photoID: UUID, contentHash: String, modelIdentifier: String, preprocessingVersion: String
        init(_ photoID: UUID, _ contentHash: String, _ manifest: ModelManifest) {
            self.photoID = photoID; self.contentHash = contentHash
            modelIdentifier = manifest.identifier; preprocessingVersion = manifest.preprocessingVersion
        }
    }

    public init(capacity: Int = InMemoryFaceVectorIndex.defaultCapacity) throws {
        guard capacity > 0 else { throw FaceVectorIndexError.invalidCapacity }
        self.capacity = capacity
    }

    public var count: Int { lock.withLock { vectors.count } }

    @discardableResult
    public func insert(_ vector: EmbeddingVector, face: FaceKey, contentHash: String,
                       manifest: ModelManifest) throws -> FaceVectorInsertResult {
        guard !contentHash.isEmpty else { throw FaceVectorIndexError.emptyContentHash }
        let unit = try vector.normalized(using: manifest).values
        let key = FaceVectorKey(face: face, modelIdentifier: manifest.identifier,
                                preprocessingVersion: manifest.preprocessingVersion, contentHash: contentHash)
        return lock.withLock {
            if let previous = keysByFace[face] {
                vectors.removeValue(forKey: previous)
                vectors[key] = unit; keysByFace[face] = key
                return .replaced
            }
            guard vectors.count < capacity else { return .full }
            vectors[key] = unit; keysByFace[face] = key
            return .inserted
        }
    }

    public func insert(_ entries: [(face: FaceKey, vector: EmbeddingVector)], photoID: UUID, contentHash: String,
                       manifest: ModelManifest, epoch: UInt64) throws -> FaceVectorBatchResult {
        guard !contentHash.isEmpty else { throw FaceVectorIndexError.emptyContentHash }
        let units = try entries.map { (face: $0.face, values: try $0.vector.normalized(using: manifest).values) }
        return lock.withLock {
            guard epoch == generation else { return .stale }
            let added = Set(units.map(\.face)).subtracting(keysByFace.keys).count
            guard added <= capacity - vectors.count else { return .full }
            for unit in units {
                if let previous = keysByFace[unit.face] { vectors.removeValue(forKey: previous) }
                let key = FaceVectorKey(face: unit.face, modelIdentifier: manifest.identifier,
                                        preprocessingVersion: manifest.preprocessingVersion, contentHash: contentHash)
                vectors[key] = unit.values; keysByFace[unit.face] = key
            }
            attempted.insert(AttemptKey(photoID, contentHash, manifest))
            return .inserted(units.count)
        }
    }

    public func wasAttempted(photoID: UUID, contentHash: String, manifest: ModelManifest) -> Bool {
        lock.withLock { attempted.contains(AttemptKey(photoID, contentHash, manifest)) }
    }

    public func snapshot() -> [FaceVectorKey: [Float]] { lock.withLock { vectors } }

    public var epoch: UInt64 { lock.withLock { generation } }

    public func invalidate() {
        lock.withLock { vectors.removeAll(); keysByFace.removeAll(); attempted.removeAll(); generation &+= 1 }
    }
}
