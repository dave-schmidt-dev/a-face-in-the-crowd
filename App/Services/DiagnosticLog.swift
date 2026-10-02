import Foundation

/// Bounded diagnostics accepts only fixed categories and nonnegative aggregate counts.
/// Names, paths, images, vectors and arbitrary error descriptions cannot enter this API.
public actor DiagnosticLog {
    public enum Event: String, Sendable { case shellOpened, operationUnavailable, operationFailed }
    public enum Severity: String, Sendable { case warning, debug }
    private let directory: URL
    private let debugEnabled: Bool
    private let maximumBytes: Int
    private let retainedFiles: Int

    public init(directory: URL, debugEnabled: Bool = false,
                maximumBytes: Int = 64 * 1024, retainedFiles: Int = 3) {
        self.directory = directory
        self.debugEnabled = debugEnabled
        self.maximumBytes = max(256, min(maximumBytes, 1024 * 1024))
        self.retainedFiles = max(1, min(retainedFiles, 5))
    }

    public func record(_ event: Event, severity: Severity = .warning, count: Int = 0) {
        guard severity == .warning || debugEnabled else { return }
        let data = Data("\(severity.rawValue) \(event.rawValue) count=\(max(0, count))\n".utf8)
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            var protected = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try protected.setResourceValues(values)
            #if os(iOS)
            try manager.setAttributes([.protectionKey: FileProtectionType.complete],
                                      ofItemAtPath: directory.path)
            #endif
            let current = directory.appendingPathComponent("diagnostics.log")
            let size = (try? manager.attributesOfItem(atPath: current.path)[.size] as? NSNumber)?.intValue ?? 0
            if size + data.count > maximumBytes {
                for index in stride(from: retainedFiles, through: 1, by: -1) {
                    let destination = directory.appendingPathComponent("diagnostics.\(index).log")
                    if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
                    let source = index == 1 ? current : directory.appendingPathComponent("diagnostics.\(index - 1).log")
                    if manager.fileExists(atPath: source.path) { try manager.moveItem(at: source, to: destination) }
                }
            }
            if !manager.fileExists(atPath: current.path) {
                #if os(iOS)
                let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
                #else
                let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
                #endif
                guard manager.createFile(atPath: current.path, contents: nil,
                                         attributes: attributes) else { return }
            }
            let handle = try FileHandle(forWritingTo: current)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Diagnostics must never leak the underlying URL or free-form error.
        }
    }
}
