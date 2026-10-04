import Foundation

enum RestoreFileError: Error, Sendable, Equatable {
    case unsafeEntry, changedSource, invalidMarker, markerPresent, missingEvidence, foreignStage
    case syscall(Int32)
}
enum RestoreFileOperation: String, Sendable { case mkdir, open, protect, read, write, fileSync, directorySync, rename, unlink, close, verify }
enum RestoreFileRole: String, Sendable { case root, ancestor, stage, old, new, install, marker, sourceParent }
enum RestoreFileMoment: Sendable { case before, after }
struct RestoreFileEvent: Sendable {
    let operation: RestoreFileOperation
    let role: RestoreFileRole
    let moment: RestoreFileMoment
    // Bit0 bytecount;1/2 failed FD/path stat;3...7 FD and8...12 path:
    // identity,size,linkcount,mtime,ctime. Bit13 entryset/read error (sourceParent).
    // No paths or actual timestamps are emitted.
    var changedFields: UInt16 = 0
}
struct RestoreFileStage: Sendable {
    let transaction: UUID
    let owner: UUID
    var name: String { "restore-" + transaction.uuidString }
}
