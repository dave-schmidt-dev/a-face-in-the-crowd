import Foundation
import Darwin

/// Bounded diagnostics accepts only fixed categories and nonnegative aggregate counts.
/// Names, paths, images, vectors and arbitrary error descriptions cannot enter this API.
public actor DiagnosticLog {
    public enum Event: String, Sendable { case shellOpened, operationUnavailable, operationFailed, orphansSkipped }
    public enum Severity: String, Sendable { case warning, debug }
    private let directory: URL
    private let debugEnabled: Bool
    private let maximumBytes: Int
    private let retainedFiles: Int
    private var files: DiagnosticFiles?
    private var disabled = false
    private var paused = false
    private var afterAppend: (@Sendable () -> Void)?
    public init(directory: URL, debugEnabled: Bool = false,
                maximumBytes: Int = 64 * 1024, retainedFiles: Int = 3) {
        self.directory = directory; self.debugEnabled = debugEnabled
        self.maximumBytes = max(256, min(maximumBytes, 1024 * 1024))
        self.retainedFiles = max(1, min(retainedFiles, 5))
    }
    init(directory: URL, afterAppend: @escaping @Sendable () -> Void) {
        self.directory = directory; debugEnabled = false; maximumBytes = 64 * 1024; retainedFiles = 3
        self.afterAppend = afterAppend
    }
    public func record(_ event: Event, severity: Severity = .warning, count: Int = 0) {
        guard !disabled, !paused, severity == .warning || debugEnabled else { return }
        let data = Data("\(severity.rawValue) \(event.rawValue) count=\(max(0, count))\n".utf8)
        do {
            if files == nil { files = try DiagnosticFiles(directory: directory, create: true) }
            try files?.append(data, maximum: maximumBytes, retained: retainedFiles)
            afterAppend?()
        } catch { /* Fixed diagnostics must never expose a URL or free-form error. */ }
    }
    /// Actor barrier: earlier actual append bodies and their ephemeral file handles have finished.
    /// Pausing performs no filesystem work and preserves permanent deletion ownership.
    public func pauseForProtectedData() { paused = true }
    /// Explicit caller action after checked unlock; permanent disablement can never be reversed.
    @discardableResult public func resumeAfterProtectedData() -> Bool {
        guard !disabled else { return false }
        paused = false; return true
    }
    /// Disables admission permanently before cleanup. Explicit retries retain the same owner.
    public func disableAndRemoveOwnedFiles() throws { try disableAndRemoveOwnedFiles(fault: nil) }
    func disableAndRemoveOwnedFiles(fault: DiagnosticFileFault?) throws {
        disabled = true
        if files == nil {
            do { files = try DiagnosticFiles(directory: directory, create: false) }
            catch DiagnosticFileError.syscall(let code) where code == ENOENT { return }
        }
        try files?.remove(fault: fault)
    }
}
