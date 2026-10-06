import Foundation

public enum ScanError: Error, Sendable, Equatable {
    case denied, unavailable, unsafePath, malformed, oversized, storagePressure
    case paused, initialScanOnly, database, unsupportedSchema, sourceConfirmationRequired, staleLease
    public var message: String {
        switch self {
        case .sourceConfirmationRequired: return "Confirm that this is the original source folder before reconnecting. Matching folder names do not establish identity."
        case .staleLease: return "A newer scan owns this catalog. This scan stopped."
        case .denied: return "Folder access denied. Choose the folder again."
        case .unavailable: return "Folder unavailable. Reconnect the drive."
        case .unsafePath: return "Skipped a link outside the selected folder."
        case .malformed: return "Unreadable JPEG."
        case .oversized: return "JPEG exceeds safe decode limits."
        case .storagePressure: return "Paused: storage is low."
        case .paused: return "Paused: device locked or memory pressure."
        case .initialScanOnly: return "This catalog already has a scan. Recovery and rescanning are not available yet."
        case .database: return "Catalog unavailable. Accepted records remain on disk."
        case .unsupportedSchema: return "Catalog version is unsupported."
        }
    }
}
public struct SourceEntry: Sendable, Equatable {
    public let relativePath: String
    public let metadata: SourceMetadata?
    public init(relativePath: String, metadata: SourceMetadata? = nil) {
        self.relativePath = relativePath; self.metadata = metadata
    }
}
/// Only provider-guaranteed content revisions may avoid integrity reads.
public struct SourceMetadata: Codable, Sendable, Equatable {
    public let revision: String?
    public let size: Int?
    public let modified: Date?
    public init(revision: String? = nil, size: Int? = nil, modified: Date? = nil) {
        self.revision = revision; self.size = size; self.modified = modified
    }
}
/// Pull-based discovery permits processing each photo before requesting the next entry.
public protocol PhotoSource: Sendable {
    func identity() async throws -> String?
    func permissionBookmark() async throws -> Data?
    func open() async throws
    func next() async throws -> SourceEntry?
    func read(_ entry: SourceEntry) async throws -> Data
    func close() async
}
public extension PhotoSource {
    func identity() async throws -> String? { nil }
    func permissionBookmark() async throws -> Data? { nil }
}
public struct DecodeLimits: Sendable {
    public static let maximumFileBytes = 64 * 1024 * 1024
    public static let maximumPixels = 80_000_000
    public static let maximumDimension = 32_768
    public static let previewDimension = 1024
    public static let cacheBudget = 512 * 1024 * 1024
    public static func validate(bytes: Int, width: Int, height: Int) throws {
        guard bytes > 0, width > 0, height > 0 else { throw ScanError.malformed }
        guard bytes <= maximumFileBytes, width <= maximumDimension, height <= maximumDimension,
              width <= maximumPixels / height else { throw ScanError.oversized }
    }
}

import Darwin

/// Security-scoped, coordinated read-only folder access. Never follows symbolic links.
public actor FolderPhotoSource: PhotoSource {
    private let root: URL
    /// The caller's URL instance. iOS attaches the security scope to it; a standardized copy can lose it.
    private let scopeURL: URL
    nonisolated var securityScopeURL: URL { scopeURL }
    private let granted: Bool?
    private var scoped = false
    private var openedIdentity: String?
    private var enumerator: FileManager.DirectoryEnumerator?
    private final class EnumerationFailure: @unchecked Sendable {
        private let lock = NSLock()
        private var failed = false
        func set() { lock.lock(); failed = true; lock.unlock() }
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return failed }
    }
    private var enumerationError = EnumerationFailure()
    public init(root: URL) { self.root = root.standardizedFileURL; scopeURL = root; granted = nil }
    init(root: URL, grantForTesting: Bool) { self.root = root.standardizedFileURL; scopeURL = root; granted = grantForTesting }
    #if DEBUG
    /// Runtime-generated synthetic app-container fixtures only; never used for user folders.
    public static func syntheticFixture(root: URL) -> FolderPhotoSource {
        FolderPhotoSource(root: root, grantForTesting: true)
    }
    #endif
    public func open() async throws {
        scoped = granted ?? scopeURL.startAccessingSecurityScopedResource()
        guard scoped else { throw ScanError.denied }
        let values: URLResourceValues
        do { values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isReadableKey]) }
        catch { throw ScanError.unavailable }
        guard values.isDirectory == true else { throw ScanError.unavailable }
        guard values.isSymbolicLink != true, values.isReadable != false else { throw ScanError.denied }
        openedIdentity = try await identity()
        enumerationError = EnumerationFailure()
        let failure = enumerationError
        enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles], errorHandler: { _, _ in
                failure.set()
                return false
            })
        guard enumerator != nil else { throw ScanError.unavailable }
    }
    public func next() async throws -> SourceEntry? {
        guard scoped, let enumerator else { throw ScanError.denied }
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) else { continue }
            guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw ScanError.unsafePath }
            let path = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return SourceEntry(relativePath: path, metadata: SourceMetadata(size: values.fileSize, modified: values.contentModificationDate))
        }
        if enumerationError.get() { throw ScanError.unavailable }
        // Drive loss must not be interpreted as successful empty enumeration.
        let rootValues = try root.resourceValues(forKeys: [.isReadableKey, .isDirectoryKey])
        guard rootValues.isDirectory == true, rootValues.isReadable != false else { throw ScanError.unavailable }
        if let openedIdentity { guard try await identity() == openedIdentity else { throw ScanError.unavailable } }
        return nil
    }
    public func read(_ entry: SourceEntry) async throws -> Data {
        guard scoped else { throw ScanError.denied }
        guard !entry.relativePath.hasPrefix("/"), !entry.relativePath.split(separator: "/").contains("..") else { throw ScanError.unsafePath }
        let url = root.appendingPathComponent(entry.relativePath)
        try checkContained(url)
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(ScanError.unavailable)
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinated in
            do {
                try checkContained(coordinated)
                let values = try coordinated.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey])
                guard values.isRegularFile == true else { throw ScanError.unsafePath }
                guard let size = values.fileSize, size <= DecodeLimits.maximumFileBytes else { throw ScanError.oversized }
                if let metadata = entry.metadata {
                    guard metadata.size == values.fileSize, metadata.modified == values.contentModificationDate else { throw ScanError.unavailable }
                }
                let bytes = try readWithoutLinks(coordinated)
                let after = try coordinated.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard after.fileSize == values.fileSize, after.contentModificationDate == values.contentModificationDate,
                      bytes.count == values.fileSize else { throw ScanError.unavailable }
                result = .success(bytes)
            } catch { result = .failure(error) }
        }
        if coordinationError != nil { throw ScanError.unavailable }
        do { return try result.get() }
        catch let error as ScanError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw ScanError.unavailable }
    }
    private func readWithoutLinks(_ url: URL) throws -> Data {
        let normalized = url.standardizedFileURL
        let components = String(normalized.path.dropFirst(root.standardizedFileURL.path.count + 1)).split(separator: "/")
        guard !components.isEmpty else { throw ScanError.unsafePath }
        var descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ScanError.unavailable }
        defer { Darwin.close(descriptor) }
        for (index, component) in components.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | (index < components.count - 1 ? O_DIRECTORY : 0)
            let next = openat(descriptor, String(component), flags)
            guard next >= 0 else { throw errno == ELOOP ? ScanError.unsafePath : ScanError.unavailable }
            Darwin.close(descriptor); descriptor = next
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw ScanError.unsafePath }
        guard info.st_size <= DecodeLimits.maximumFileBytes else { throw ScanError.oversized }
        var output = Data(); var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else { throw ScanError.unavailable }
            if count == 0 { break }
            guard output.count + count <= DecodeLimits.maximumFileBytes else { throw ScanError.oversized }
            output.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              after.st_size == info.st_size, after.st_ino == info.st_ino,
              after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
              output.count == info.st_size else { throw ScanError.unavailable }
        return output
    }
    private func checkContained(_ url: URL) throws {
        let normalizedRoot = root.standardizedFileURL
        let normalizedURL = url.standardizedFileURL
        let base = normalizedRoot.resolvingSymlinksInPath().path
        guard normalizedURL.path.hasPrefix(normalizedRoot.path + "/"),
              normalizedURL.resolvingSymlinksInPath().path.hasPrefix(base + "/") else { throw ScanError.unsafePath }
        var component = normalizedURL
        while component.path != normalizedRoot.path {
            guard component.path != "/" else { throw ScanError.unsafePath }
            let values = try component.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw ScanError.unsafePath }
            let previous = component.path
            component.deleteLastPathComponent()
            guard component.path != previous else { throw ScanError.unsafePath }
        }
    }
    public func close() async {
        enumerator = nil
        if scoped, granted == nil { scopeURL.stopAccessingSecurityScopedResource() }
        scoped = false
    }
    public func identity() async throws -> String? {
        guard scoped else { throw ScanError.denied }
        let values = try root.resourceValues(forKeys: [.volumeUUIDStringKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        guard let volume = values.volumeUUIDString,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return volume + ":" + inode.stringValue
    }
    public func permissionBookmark() async throws -> Data? { try bookmark() }
    public func bookmark() throws -> Data {
        // Bookmark remains private in the protected catalog container; never exported.
        try scopeURL.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}
