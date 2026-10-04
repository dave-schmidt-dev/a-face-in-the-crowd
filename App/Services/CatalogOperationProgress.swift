import Foundation
import AFITCCore

struct CatalogOperationProgress: Sendable {
    let phase: String
    let completed: Int
    let total: Int?
    let unit: String
    init(phase: String, completed: Int, total: Int?, unit: String) {
        self.phase = phase; self.completed = completed; self.total = total; self.unit = unit
    }
    init(_ value: BackupProgress) {
        phase = value.operation.rawValue; completed = value.completed; total = value.total; unit = "work"
    }
    init(_ value: RestoreValidationProgress) {
        phase = value.stage.rawValue; completed = value.completed; total = value.total; unit = String(describing: value.unit)
    }
    init(_ value: CatalogRestoreProgress) {
        phase = value.phase.rawValue; completed = value.completed; total = value.total; unit = String(describing: value.unit)
    }
}
/// One producer continuation and one consumer; queued work is always bounded to one value.
@MainActor
final class CatalogProgressBridge {
    private let continuation: AsyncStream<CatalogOperationProgress>.Continuation
    private let consumer: Task<Void, Never>
    let counts = CatalogProgressCounts()
    init(beforeConsume: (() async -> Void)? = nil, publish: @escaping (CatalogOperationProgress) -> Void) {
        let pair = AsyncStream<CatalogOperationProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation = pair.continuation
        consumer = Task {
            if let beforeConsume { await beforeConsume() }
            for await value in pair.stream { publish(value) }
        }
    }
    var sink: @Sendable (CatalogOperationProgress) -> Void {
        let continuation = continuation, counts = counts
        return { value in
            let result = continuation.yield(value)
            if case .dropped = result { counts.record(dropped: true) }
            else { counts.record(dropped: false) }
        }
    }
    func finish() async { continuation.finish(); await consumer.value }
}
final class CatalogProgressCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var updates = 0
    private var dropped = 0
    func record(dropped: Bool) { lock.lock(); defer { lock.unlock() }; updates += 1; if dropped { self.dropped += 1 } }
    var snapshot: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (updates, dropped) }
}
