import Foundation
import SQLite3
import Darwin

/// Only private pre-PREPARED copies are mutable. Every SQLite lifetime remains root-accounted.
final class CatalogRestorePreparation {
    private let reservation: CatalogExclusiveReservation
    private var handles: [RestoreInspection] = []
    init(reservation: CatalogExclusiveReservation) { self.reservation = reservation }
    #if DEBUG
    /// Synthetic crash tests only: runs inside the open renew transaction after its first row write.
    static var renewWriteHook: (() -> Void)?
    #endif
    func close() throws { for handle in handles { try handle.close() }; handles.removeAll() }
    func verify(_ file: URL, manifest: BackupManifest,
                progress: @escaping @Sendable (RestoreValidationProgress) -> Void) throws {
        let handle = try RestoreInspection(file: file, reservation: reservation); handles.append(handle)
        try handle.inspect(manifest: manifest, progress: progress); try close()
    }
    private func permission(_ file: URL, writable: Bool) throws {
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RestoreFileError.syscall(errno) }
        var closed = false; defer { if !closed { Darwin.close(fd) } }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              fchmod(fd, writable ? 0o600 : 0o400) == 0, fsync(fd) == 0 else { throw RestoreFileError.unsafeEntry }
        guard Darwin.close(fd) == 0 else { throw RestoreFileError.syscall(errno) }; closed = true
    }
    private struct State { let revision: Int; let lease: Int; let people: [PersonRecord] }
    private func state(_ handle: RestoreInspection, didRead: () -> Void) throws -> State {
        try handle.withHandle { db in
            try Task.checkCancellation()
            let revision = try CatalogCounters.read(db, .revision); didRead()
            try Task.checkCancellation()
            let lease = try CatalogCounters.read(db, .lease); didRead()
            let statement = try PeopleSQL.statement(db, "SELECT payload FROM people ORDER BY id")
            defer { sqlite3_finalize(statement) }
            var people: [PersonRecord] = []; var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                try Task.checkCancellation()
                let count = Int(sqlite3_column_bytes(statement, 0))
                guard count > 0, let bytes = sqlite3_column_blob(statement, 0) else { throw ScanError.database }
                people.append(try JSONDecoder().decode(PersonRecord.self, from: Data(bytes: bytes, count: count)))
                didRead(); status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw CatalogSchema.failure(db) }
            return State(revision: revision, lease: lease, people: people)
        }
    }
    /// Renew both copies above current live/import mutable values; immutable ledger and face generations stay byte-identical.
    func renew(old: URL, new: URL, oldManifest: BackupManifest, newManifest: BackupManifest,
               progress: @escaping @Sendable (CatalogRestoreProgress) -> Void = { _ in }) throws -> (BackupManifest, BackupManifest) {
        try permission(old, writable: true); try permission(new, writable: true)
        let a = try RestoreInspection(file: old, reservation: reservation, readOnly: false); handles.append(a)
        let b = try RestoreInspection(file: new, reservation: reservation, readOnly: false); handles.append(b)
        var readCount = 0
        progress(CatalogRestoreProgress(phase: .renewing, completed: 0, total: nil, unit: .rows))
        func didRead() {
            readCount += 1
            progress(CatalogRestoreProgress(phase: .renewing, completed: readCount, total: nil, unit: .rows))
        }
        let oldState = try state(a, didRead: didRead), newState = try state(b, didRead: didRead)
        let revision = try CatalogCounters.successor(max(oldState.revision, newState.revision))
        let lease = try CatalogCounters.successor(max(oldState.lease, newState.lease))
        let oldEpochs = Dictionary(uniqueKeysWithValues: oldState.people.map { ($0.id, $0.exemplarRevision) })
        let newEpochs = Dictionary(uniqueKeysWithValues: newState.people.map { ($0.id, $0.exemplarRevision) })
        let personCount = oldState.people.count + newState.people.count
        var epochCount = 0
        progress(CatalogRestoreProgress(phase: .renewing, completed: 0, total: personCount, unit: .domainItems))
        func renewed(_ people: [PersonRecord], other: [UUID: Int]) throws -> [PersonRecord] {
            try people.map { value in
                try Task.checkCancellation()
                guard value.exemplarRevision > 0, (other[value.id] ?? 1) > 0 else { throw CounterError.invalidStoredValue }
                var person = value
                person.exemplarRevision = try CatalogCounters.successor(max(value.exemplarRevision, other[value.id] ?? 0), minimum: 1)
                epochCount += 1
                progress(CatalogRestoreProgress(phase: .renewing, completed: epochCount, total: personCount, unit: .domainItems))
                return person
            }
        }
        let oldPeople = try renewed(oldState.people, other: newEpochs), newPeople = try renewed(newState.people, other: oldEpochs)
        var writeCount = 0
        let writeTotal = personCount + 4
        progress(CatalogRestoreProgress(phase: .renewing, completed: 0, total: writeTotal, unit: .operations))
        func didWrite() {
            writeCount += 1
            progress(CatalogRestoreProgress(phase: .renewing, completed: writeCount, total: writeTotal, unit: .operations))
        }
        func write(_ handle: RestoreInspection, people: [PersonRecord]) throws {
            try handle.withHandle { db in
                try CatalogSchema.execute(db, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; BEGIN IMMEDIATE")
                do {
                    try Task.checkCancellation()
                    try CatalogCounters.set(db, .revision, revision); didWrite()
                    #if DEBUG
                    Self.renewWriteHook?()
                    #endif
                    try Task.checkCancellation()
                    try CatalogCounters.set(db, .lease, lease); didWrite()
                    for person in people { try Task.checkCancellation(); try PeopleSQL.writePerson(db, person); didWrite() }
                    try Task.checkCancellation()
                    try CatalogSchema.execute(db, "COMMIT")
                } catch { try? CatalogSchema.execute(db, "ROLLBACK"); throw error }
            }
        }
        try write(a, people: oldPeople); try write(b, people: newPeople); try close()
        try permission(old, writable: false); try permission(new, writable: false)
        func manifest(_ input: BackupManifest) -> BackupManifest {
            BackupManifest(formatVersion: input.formatVersion, schemaVersion: input.schemaVersion, createdAt: input.createdAt,
                revision: revision, counts: input.counts, catalogBytes: input.catalogBytes, catalogSHA256: input.catalogSHA256)
        }
        return (manifest(oldManifest), manifest(newManifest))
    }
}
