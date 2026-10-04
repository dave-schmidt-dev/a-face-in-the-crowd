import AFITCCore
@testable import AFITCRuntime
import Foundation
import XCTest

final class YuNetRuntimeTests: XCTestCase {
    private var project: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private var model: URL { project.appendingPathComponent("models/face_detection_yunet_2023mar.onnx") }
    private func input(_ values: [Float]? = nil, name: String = "input", type: YuNetRuntimeTensor.ElementType = .float32,
                       shape: [Int] = [1, 3, 640, 640]) -> YuNetRuntimeTensor {
        YuNetRuntimeTensor(name: name, elementType: type, shape: shape,
                           values: values ?? [Float](repeating: 0, count: 3 * 640 * 640))
    }
    private func provenance() -> YuNetRuntimeProvenance {
        YuNetRuntimeProvenance(photoID: UUID(), contentVersion: 1, detectorVersion: "existing-vision-r3",
                               operationID: UUID(), sessionEpoch: 1)
    }
    private func failure(_ request: () async throws -> Void, _ expected: YuNetRuntimeError) async {
        do { try await request(); XCTFail("Invalid request accepted") }
        catch let error as YuNetRuntimeError { XCTAssertEqual(error, expected) }
        catch { XCTFail("Unexpected error type: \(error)") }
    }
    func testMissingCorruptHashAndWrongArtifactFailBeforeSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AFITC-YuNet-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let factory = TestYuNetFactory(backend: TestYuNetBackend()), prep = YuNetModelPreparation(factory: factory)
        let missing = root.appendingPathComponent("missing")
        await failure({ _ = try await prep.prepare(at: missing) }, .modelUnavailable)
        let corrupt = root.appendingPathComponent("corrupt")
        try Data(repeating: 0, count: YuNetRuntimeContract.artifactBytes).write(to: corrupt)
        await failure({ _ = try await prep.prepare(at: corrupt) }, .artifactRejected)
        try Data([1]).write(to: corrupt)
        await failure({ _ = try await prep.prepare(at: corrupt) }, .artifactRejected)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: model)
        await failure({ _ = try await prep.prepare(at: link) }, .modelUnavailable)
        await failure({ _ = try await prep.prepare(at: root) }, .modelUnavailable)
        XCTAssertEqual(factory.calls.value, 0)
    }
    func testPreparationProgressCancellationAndGraphNameFailures() async throws {
        let gate = TestYuNetFactoryGate(), backend = TestYuNetBackend()
        let factory = TestYuNetFactory(backend: backend, gate: gate)
        let progress = YuNetTestProgress(), returned = YuNetTestFlag()
        let task = Task {
            defer { returned.set(true) }
            return try await YuNetModelPreparation(factory: factory).prepare(at: model) { progress.append($0) }
        }
        try await wait { gate.entered.value }
        task.cancel()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(returned.value); XCTAssertFalse(progress.has(.ready))
        gate.release.signal()
        do { _ = try await task.value; XCTFail("Cancelled preparation ready") } catch is CancellationError {}
        XCTAssertTrue(returned.value); XCTAssertTrue(gate.finished.value)
        XCTAssertTrue(progress.has(.verifyingArtifact)); XCTAssertTrue(progress.has(.creatingSession))
        XCTAssertTrue(progress.has(.cancelled)); XCTAssertFalse(progress.has(.ready))
        let wrong = TestYuNetFactory(backend: TestYuNetBackend(names: ["wrong"]))
        await failure({ _ = try await YuNetModelPreparation(factory: wrong).prepare(at: model) }, .runtimeContractMismatch)
        let normal = YuNetTestProgress()
        _ = try await YuNetModelPreparation(factory: TestYuNetFactory(backend: backend)).prepare(at: model) { normal.append($0) }
        XCTAssertTrue(normal.has(.ready)); XCTAssertEqual(normal.events.first?.completedUnits, 0)
        XCTAssertEqual(normal.events.filter { $0.stage == .verifyingArtifact }.last?.completedUnits, 232_589)
    }
    func testInputNameTypeShapeCountRangeFailuresRejectBeforeBackend() async throws {
        let backend = TestYuNetBackend(), runtime = YuNetRuntime(backend: backend)
        let invalid = [input(name: "data"), input(type: .float16), input(type: .int32), input(shape: [1, 3, 639, 640]),
                       input([0]), input([Float](repeating: -.infinity, count: 3 * 640 * 640)),
                       input([Float](repeating: 256, count: 3 * 640 * 640))]
        for value in invalid {
            await failure({ _ = try await runtime.infer(from: value, provenance: provenance()) }, .invalidInput)
        }
        let observed5 = await backend.count(); XCTAssertEqual(observed5, 0)
    }
    func testActualOutputNameTypeShapeCountAndFiniteFailuresReject() async throws {
        let base = TestYuNetBackend.outputs()
        var duplicate = base; duplicate[1] = base[0]
        let first = base[0]
        let mutations = [
            YuNetRuntimeTensor(name: "unexpected", elementType: .float32, shape: first.shape, values: first.values),
            YuNetRuntimeTensor(name: first.name, elementType: .float16, shape: first.shape, values: first.values),
            YuNetRuntimeTensor(name: first.name, elementType: .float32, shape: [1, 1, 1], values: first.values),
            YuNetRuntimeTensor(name: first.name, elementType: .float32, shape: first.shape, values: [0]),
            YuNetRuntimeTensor(name: first.name, elementType: .float32, shape: first.shape, values: [Float](repeating: .nan, count: first.values.count))]
        var cases = [Array(base.dropLast()), duplicate]
        for changed in mutations { var value = base; value[0] = changed; cases.append(value) }
        for value in cases {
            let runtime = YuNetRuntime(backend: TestYuNetBackend(output: value))
            await failure({ _ = try await runtime.infer(from: input(), provenance: provenance()) }, .runtimeContractMismatch)
        }
        let valid = try await YuNetRuntime(backend: TestYuNetBackend(output: Array(base.reversed())))
            .infer(from: input(), provenance: provenance())
        XCTAssertEqual(valid.outputs.map(\.name), YuNetRuntimeContract.outputNames)
        let failing = YuNetRuntime(backend: TestYuNetBackend(throwsFailure: true))
        await failure({ _ = try await failing.infer(from: input(), provenance: provenance()) }, .backendFailed)
    }
    func testQueueSerialExecutionAndCancelledStartedWorkActuallyDrains() async throws {
        let backend = TestYuNetBackend(held: true), runtime = YuNetRuntime(backend: backend)
        let completed = YuNetTestFlag(), progress = YuNetTestProgress()
        let first = Task {
            defer { completed.set(true) }
            return try await runtime.infer(from: input(), provenance: provenance())
        }
        try await wait { await backend.count() == 1 }
        let second = Task { try await runtime.infer(from: input(), provenance: provenance()) { progress.append($0) } }
        try await wait { progress.has(.queued) }
        first.cancel(); second.cancel()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(completed.value); let observed4 = await backend.count(); XCTAssertEqual(observed4, 1)
        await backend.release()
        do { _ = try await first.value; XCTFail("Cancelled active returned result") } catch is CancellationError {}
        do { _ = try await second.value; XCTFail("Cancelled queue entered") } catch is CancellationError {}
        XCTAssertTrue(completed.value); let observed3 = await backend.count(); XCTAssertEqual(observed3, 1)
        let third = Task { try await runtime.infer(from: input(), provenance: provenance()) }
        try await wait { await backend.count() == 2 }
        await backend.release(); _ = try await third.value
        let observed2 = await backend.maximum(); XCTAssertEqual(observed2, 1)
    }
    func testStaleProvenanceAtDequeueAndAfterInferenceSuppressesResults() async throws {
        let backend = TestYuNetBackend(held: true), runtime = YuNetRuntime(backend: backend)
        let current = YuNetTestFlag(true), queued = YuNetTestProgress()
        let first = Task { try await runtime.infer(from: input(), provenance: provenance()) }
        try await wait { await backend.count() == 1 }
        let second = Task { try await runtime.infer(from: input(), provenance: provenance(), isCurrent: { _ in current.value }) { queued.append($0) } }
        try await wait { queued.has(.queued) }; current.set(false)
        await backend.release(); _ = try await first.value
        await failure({ _ = try await second.value }, .staleProvenance)
        let observed1 = await backend.count(); XCTAssertEqual(observed1, 1); XCTAssertFalse(queued.has(.runningInference))
        current.set(true)
        let late = Task { try await runtime.infer(from: input(), provenance: provenance(), isCurrent: { _ in current.value }) }
        try await wait { await backend.count() == 2 }; current.set(false); await backend.release()
        await failure({ _ = try await late.value }, .staleProvenance)
    }
    func testParentReturnFenceRejectsCancellationAndStaleAfterCompletedCallback() async throws {
        for cancel in [true, false] {
            let backend = TestYuNetBackend(), runtime = YuNetRuntime(backend: backend)
            let gate = SFaceCompletionBoundaryGate(), current = YuNetTestFlag(true), returned = YuNetTestFlag()
            let request = Task {
                defer { returned.set(true) }
                return try await runtime.infer(from: input(), provenance: provenance(),
                    isCurrent: { _ in current.value }, progress: { if $0.stage == .completed { gate.hold() } })
            }
            try await gate.waitForEntry()
            let calls = await backend.count(); XCTAssertEqual(calls, 1)
            if cancel { request.cancel() } else { current.set(false) }
            try await Task.sleep(for: .milliseconds(20)); XCTAssertFalse(returned.value)
            gate.release()
            do { _ = try await request.value; XCTFail("Parent published after return-boundary invalidation") }
            catch is CancellationError { XCTAssertTrue(cancel) }
            catch let error as YuNetRuntimeError { XCTAssertFalse(cancel); XCTAssertEqual(error, .staleProvenance) }
            XCTAssertTrue(returned.value)
        }
    }

    #if os(macOS)
    func testActualPinnedCPUAllTenRawHeadParity() async throws {
        guard ProcessInfo.processInfo.environment["AFITC_RUN_YUNET_REFERENCE_PARITY"] == "1" else {
            throw XCTSkip("Actual YuNet reference diagnostic requires explicit opt-in and frozen artifacts")
        }
        let runtime = try await YuNetModelPreparation().prepare(at: model)
        try await YuNetORTParityEvidence.run(runtime: runtime, model: model,
            output: project.appendingPathComponent(".logs/verification/phase2.yunet-runtime/parity-metrics.json"))
    }
    #endif
    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw YuNetRuntimeError.backendFailed }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor TestYuNetBackend: YuNetInferenceBackend {
    nonisolated let inputNames = ["input"]
    nonisolated let outputNames: [String]
    private let output: [YuNetRuntimeTensor]
    private let held: Bool
    private let throwsFailure: Bool
    private var calls = 0, active = 0, maxActive = 0
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    init(names: [String] = YuNetRuntimeContract.outputNames, output: [YuNetRuntimeTensor]? = nil,
         held: Bool = false, throwsFailure: Bool = false) {
        outputNames = names; self.output = output ?? Self.outputs(); self.held = held; self.throwsFailure = throwsFailure
    }
    static func outputs() -> [YuNetRuntimeTensor] {
        YuNetRuntimeContract.outputNames.map {
            let shape = YuNetRuntimeContract.outputShape($0)!
            return YuNetRuntimeTensor(name: $0, elementType: .float32, shape: shape,
                                      values: [Float](repeating: 0, count: shape.reduce(1, *)))
        }
    }
    func infer(_ input: YuNetRuntimeTensor) async throws -> [YuNetRuntimeTensor] {
        calls += 1; active += 1; maxActive = max(maxActive, active); defer { active -= 1 }
        if held { await withCheckedContinuation { releaseWaiter = $0 } }
        if throwsFailure { throw YuNetRuntimeError.backendFailed }; return output
    }
    func count() -> Int { calls }
    func maximum() -> Int { maxActive }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}
private final class YuNetTestFlag: @unchecked Sendable {
    private let lock = NSLock(); private var stored: Bool
    init(_ value: Bool = false) { stored = value }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: Bool) { lock.lock(); stored = value; lock.unlock() }
}
private final class YuNetTestProgress: @unchecked Sendable {
    private let lock = NSLock(); private var values: [FaceEmbeddingProgress] = []
    var events: [FaceEmbeddingProgress] { lock.lock(); defer { lock.unlock() }; return values }
    func append(_ value: FaceEmbeddingProgress) { lock.lock(); values.append(value); lock.unlock() }
    func has(_ stage: FaceEmbeddingProgress.Stage) -> Bool { events.contains { $0.stage == stage } }
}
private final class TestYuNetFactoryGate: @unchecked Sendable {
    let entered = YuNetTestFlag(), finished = YuNetTestFlag(), release = DispatchSemaphore(value: 0)
}
private final class TestYuNetFactory: YuNetBackendFactory, @unchecked Sendable {
    let calls = YuNetTestCount()
    let backend: any YuNetInferenceBackend
    let gate: TestYuNetFactoryGate?
    init(backend: any YuNetInferenceBackend, gate: TestYuNetFactoryGate? = nil) { self.backend = backend; self.gate = gate }
    func makeBackend(artifact: VerifiedModelArtifact) throws -> any YuNetInferenceBackend {
        calls.increment()
        if let gate {
            gate.entered.set(true)
            guard gate.release.wait(timeout: .now() + 5) == .success else { throw YuNetRuntimeError.backendFailed }
            gate.finished.set(true)
        }
        return backend
    }
}
private final class YuNetTestCount: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
