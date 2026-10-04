import Foundation

public enum DeletionError: Error, Sendable, Equatable {
    case unsafeEntry, changedEntry, completed, injectedFailure, syscall(Int32)
}
public struct PersonDeletionResult: Sendable, Equatable {
    public let removedPersonIDs: Set<UUID>
    public let changedFaces: Int
}
public struct DeletionProgress: Sendable {
    public let completed: Int
    public let total: Int
}
public struct DeletionService: Sendable {
    public let catalog: CatalogRepository
    public init(catalog: CatalogRepository) { self.catalog = catalog }
    public func deletePerson(_ id: UUID) async throws -> PersonDeletionResult { try await catalog.deletePerson(id) }
    public func disconnectSource() async throws { try await catalog.disconnectSource() }
    public func prepareCatalogDeletion() async throws -> RetainedCatalogDeletion { try await catalog.prepareCatalogDeletion() }
}
enum PersonDeletionFault: Sendable { case afterFaces, afterPeople }
extension CatalogRepository {
    /// Deletes the explicit canonical alias family; immutable history is deliberately retained.
    public func deletePerson(_ id: UUID) throws -> PersonDeletionResult { try deletePerson(id, fault: nil) }
    func deletePerson(_ id: UUID, fault: PersonDeletionFault?) throws -> PersonDeletionResult {
        try peopleTransaction { db in
            let people: [PersonRecord] = try PeopleSQL.rows(db, "SELECT payload FROM people")
            var records: [UUID: PersonRecord] = [:]
            for person in people {
                guard records.updateValue(person, forKey: person.id) == nil else { throw ScanError.database }
            }
            func canonical(_ id: UUID) throws -> UUID {
                var next = id; var visited = Set<UUID>()
                while true {
                    try Task.checkCancellation()
                    guard visited.insert(next).inserted else { throw DecisionError.conflict }
                    guard let person = records[next] else { throw DecisionError.unknownPerson }
                    guard let alias = person.mergedInto else { return next }
                    next = alias
                }
            }
            let survivor = try canonical(id)
            var family = Set<UUID>()
            for person in people where try canonical(person.id) == survivor { family.insert(person.id) }
            let states: [ManualFaceState] = try PeopleSQL.rows(db, "SELECT payload FROM manual_faces ORDER BY key")
            var changed = 0
            for var state in states {
                try Task.checkCancellation()
                let before = state
                if state.personID.map({ family.contains($0) }) == true { state.personID = nil; state.isAnchor = false }
                state.rejectedPeople.subtract(family); state.deferredPeople.subtract(family)
                if state != before { try PeopleSQL.writeFace(db, state); changed += 1 }
            }
            if fault == .afterFaces { throw DeletionError.injectedFailure }
            for person in family { try Task.checkCancellation(); try PeopleSQL.run(db, "DELETE FROM people WHERE id=?", strings: [person.uuidString]) }
            if fault == .afterPeople { throw DeletionError.injectedFailure }
            return PersonDeletionResult(removedPersonIDs: family, changedFaces: changed)
        }
    }
    /// Core primitive only: callers must first drain their source callbacks and views.
    public func disconnectSource() throws {
        let ticket = try operationTicket(); defer { withExtendedLifetime(ticket) {} }
        try CatalogRestoreRepository.requireNoMarker(directory)
        try DeletionFiles.removeGrant(directory)
    }
    public func prepareCatalogDeletion() throws -> RetainedCatalogDeletion {
        try CatalogRestoreRepository.requireNoMarker(directory)
        let reservation = try reserveExclusive()
        do {
            let photos: [PhotoIdentity] = try exclusiveRead(reservation) { try PeopleSQL.rows($0, "SELECT payload FROM photos") }
            let files = try DeletionFiles(directory: directory, cache: cacheDirectory,
                photoIDs: Set(photos.map(\.id)), preservedPackages: Set(preparedBackups.values.map(\.lastPathComponent)))
            return RetainedCatalogDeletion(catalog: self, reservation: reservation, files: files)
        } catch { try reservation.release(); throw error }
    }
}

/// Runtime-only retained ownership. A partial failure requires explicit retry on this exact value.
/// There is no persisted deletion job or crash-atomic erase promise.
public actor RetainedCatalogDeletion {
    private let catalog: CatalogRepository
    private let reservation: CatalogExclusiveReservation
    private let files: DeletionFiles
    private var closed = false
    private var complete = false
    private var running = false
    private var closeAttempted = false
    public enum Phase: Sendable, Equatable { case reserved, closing, closeRetryRequired, closed, deleting, completed }
    public private(set) var phase = Phase.reserved
    init(catalog: CatalogRepository, reservation: CatalogExclusiveReservation, files: DeletionFiles) {
        self.catalog = catalog; self.reservation = reservation; self.files = files
    }
    private func admit() throws {
        guard !complete else { throw DeletionError.completed }
        guard !running else { throw CatalogLifetimeError.busy }
    }
    private func closeDatabase() async throws {
        guard !closed else { return }
        closeAttempted = true; phase = .closing
        do {
            try await catalog.retire(using: reservation)
            closed = true; phase = .closed
        } catch { phase = .closeRetryRequired; throw error }
    }
    /// Physical SQLite closure only. Keeps the same deletion reservation; no filesystem erase or cleanup.
    public func suspendForProtectedData() async throws {
        try admit(); guard !closed else { throw CatalogLifetimeError.retired }
        try Task.checkCancellation()
        running = true; defer { running = false }
        // Cancellation during the close cannot undo physical success or release a retired BUSY handle.
        try await closeDatabase()
    }
    public func retry(progress: @escaping @Sendable (DeletionProgress) -> Void = { _ in }) async throws {
        try await retry(progress: progress, fault: nil)
    }
    func retry(progress: @escaping @Sendable (DeletionProgress) -> Void = { _ in }, fault: DeletionFileFault?) async throws {
        try admit(); try Task.checkCancellation()
        running = true; defer { running = false }
        try await closeDatabase()
        // A request canceled during actual close must not continue into erasure.
        try Task.checkCancellation()
        phase = .deleting
        do {
            try files.erase(progress: progress, fault: fault)
            try reservation.release(); complete = true; phase = .completed
        } catch { phase = .closed; throw error }
    }
    /// Before physical close, cancellation can release the reservation without deleting anything.
    public func cancel() throws {
        try admit()
        guard !closed else { throw DeletionError.completed }
        guard !closeAttempted else { throw CatalogLifetimeError.closeBusy }
        try reservation.release(); complete = true; phase = .completed
    }
}
