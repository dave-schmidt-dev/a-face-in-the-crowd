import Foundation

/// The process launch arguments, parsed once and injected so services can be constructed with chosen flags.
public struct LaunchOptions: Sendable, Equatable {
    /// The full argument list this value was created from.
    public let arguments: [String]
    /// Optional owner-injected root: `AppOwnedPaths` places Support and Caches beneath it.
    /// Nil uses the process's own application support and caches containers.
    public let ownedRoot: URL?
    /// The arguments of the process this value was created in.
    public static let process = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)
    /// Creates options from a full argument list.
    public init(arguments: [String], ownedRoot: URL? = nil) {
        self.arguments = arguments
        self.ownedRoot = ownedRoot
    }
    /// True when the exact flag appears among the arguments.
    public func has(_ flag: String) -> Bool { arguments.contains(flag) }
    /// The argument immediately after the flag, when one is present.
    public func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
