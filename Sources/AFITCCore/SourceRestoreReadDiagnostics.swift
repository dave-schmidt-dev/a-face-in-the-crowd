import Foundation
import Darwin

/// Internal synthetic-test opt-in. No default logging, retained paths, payloads or extra handles.
final class SourceRestoreReadDiagnostics: @unchecked Sendable {
    enum Origin: String, Codable, Sendable { case files, validator }
    enum Role: String, Codable, Sendable {
        case root, ancestor, stage, old, new, install, marker, sourceParent, manifest, catalog
        init(_ value: RestoreFileRole) { self = Role(rawValue: value.rawValue)! }
    }
    enum Boundary: String, Codable, Sendable {
        case baseline, afterOpenObserver, beforeProgress, afterProgress, beforeReadObserver
        case beforeReadSyscall, afterReadSyscall, afterReadObserver, beforeConsume, afterConsume, finalGuard
        case afterEntries, beforeDestination, afterDestination, afterManifest, afterCatalog
    }
    struct Fields: Codable, Sendable, Equatable {
        let ctimeSeconds: Int64; let ctimeNanoseconds: Int64; let mode: UInt32
        let device: Int64; let inode: UInt64; let size: Int64; let links: UInt64
        let mtimeSeconds: Int64; let mtimeNanoseconds: Int64
        init(_ value: stat) {
            ctimeSeconds = Int64(value.st_ctimespec.tv_sec); ctimeNanoseconds = Int64(value.st_ctimespec.tv_nsec)
            mode = UInt32(value.st_mode); device = Int64(value.st_dev); inode = UInt64(value.st_ino)
            size = Int64(value.st_size); links = UInt64(value.st_nlink)
            mtimeSeconds = Int64(value.st_mtimespec.tv_sec); mtimeNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        }
    }
    struct StatResult: Codable, Sendable {
        let observed: Bool; let status: Int32?; let error: Int32?; let fields: Fields?
        init(status: Int32, error: Int32, fields: Fields?) {
            observed = true; self.status = status; self.error = error; self.fields = fields
        }
        init(_ value: stat, status: Int32, error: Int32) {
            self.init(status: status, error: status == 0 ? 0 : error, fields: status == 0 ? Fields(value) : nil)
        }
        private init() { observed = false; status = nil; error = nil; fields = nil }
        static var unobserved: StatResult { StatResult() }
    }
    struct Event: Codable, Sendable {
        let sequence: Int; let readID: Int; let origin: Origin; let role: Role; let boundary: Boundary
        let process: Int32; let thread: UInt64; let descriptor: StatResult; let path: StatResult
        let guardBaseline: Fields?; let syscallResult: Int?; let syscallErrno: Int32?
    }
    struct Trace: Codable, Sendable { let capacity: Int; let dropped: Int; let events: [Event] }
    private let lock = NSLock()
    private var ring: [Event] = []; private var position = 0; private var dropped = 0
    private var sequence = 0; private var readSequence = 0
    private let capacity = 512
    struct ReadTrace: Codable, Sendable { let readID: Int; let dropped: Int; let events: [Event] }
    struct ReadCapture: Codable, Sendable { let readDrops: Int; let eventDrops: Int; let traces: [ReadTrace] }
    private struct ReadBuffer { var dropped = 0; var events: [Event] = [] }
    private let perReadCapture: Bool
    private var reads: [Int: ReadBuffer] = [:]
    private var readDrops = 0
    enum StatCall: Sendable { case descriptor, relativePath, absolutePath }
    private let originalStatsOnly: Bool
    private let statObserver: (@Sendable (StatCall) -> Void)?
    /// Original-only records only already-performed guard stats; all other fields are explicitly unobserved.
    init(originalStatsOnly: Bool = false, statObserver: (@Sendable (StatCall) -> Void)? = nil, perReadCapture: Bool = false) {
        self.originalStatsOnly = originalStatsOnly; self.statObserver = statObserver; self.perReadCapture = perReadCapture
    }
    func nextReadID() -> Int {
        lock.lock(); defer { lock.unlock() }; readSequence += 1
        if perReadCapture { if readSequence <= 128 { reads[readSequence] = ReadBuffer() } else { readDrops += 1 } }
        return readSequence
    }
    /// Fixed opt-in bounds; overflowing evidence never changes admission or filesystem behavior.
    func snapshotReads() -> ReadCapture {
        lock.lock(); defer { lock.unlock() }
        let traces = reads.keys.sorted().map { ReadTrace(readID: $0, dropped: reads[$0]!.dropped, events: reads[$0]!.events) }
        return ReadCapture(readDrops: readDrops, eventDrops: traces.reduce(0) { $0 + $1.dropped }, traces: traces)
    }
    /// Same-descriptor sampling preserves the caller's errno and never changes admission/guard outcomes.
    func sample(_ readID: Int, origin: Origin, role: Role, boundary: Boundary, fd: Int32,
                parent: Int32? = nil, name: String? = nil, namedPath: URL? = nil,
                knownFD: stat? = nil, knownPath: stat? = nil, baseline: stat? = nil,
                descriptorResult: StatResult? = nil, pathResult: StatResult? = nil,
                result: Int? = nil, readErrno: Int32? = nil) {
        let saved = errno; defer { errno = saved }
        let descriptor: StatResult
        if let descriptorResult { descriptor = descriptorResult }
        else if let knownFD { descriptor = .init(knownFD, status: 0, error: 0) }
        else if originalStatsOnly { descriptor = .unobserved }
        else {
            var value = stat(); statObserver?(.descriptor)
            let status = fstat(fd, &value); let error = errno
            descriptor = .init(value, status: status, error: error)
        }
        let path: StatResult
        if let pathResult { path = pathResult }
        else if let knownPath { path = .init(knownPath, status: 0, error: 0) }
        else if originalStatsOnly { path = .unobserved }
        else {
            var value = stat(); let status: Int32
            if let parent, let name { statObserver?(.relativePath); status = fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) }
            else if let namedPath { statObserver?(.absolutePath); status = lstat(namedPath.path, &value) }
            else { status = -1; errno = EINVAL }
            let error = errno; path = .init(value, status: status, error: error)
        }
        var thread: UInt64 = 0; pthread_threadid_np(nil, &thread)
        lock.lock(); defer { lock.unlock() }; sequence += 1
        let event = Event(sequence: sequence, readID: readID, origin: origin, role: role, boundary: boundary,
            process: getpid(), thread: thread,
            descriptor: descriptor, path: path,
            guardBaseline: baseline.map(Fields.init) ?? reads[readID]?.events.last?.guardBaseline ?? ring.last(where: { $0.readID == readID })?.guardBaseline, syscallResult: result, syscallErrno: readErrno)
        if perReadCapture, var buffer = reads[readID] {
            if buffer.events.count < capacity { buffer.events.append(event) } else { buffer.dropped += 1 }
            reads[readID] = buffer
        }
        if ring.count < capacity { ring.append(event) }
        else { ring[position] = event; position = (position + 1) % capacity; dropped += 1 }
    }
    func snapshot() -> Trace {
        lock.lock(); defer { lock.unlock() }
        let values = ring.count < capacity || position == 0 ? ring : Array(ring[position...]) + Array(ring[..<position])
        return Trace(capacity: capacity, dropped: dropped, events: values)
    }
}
