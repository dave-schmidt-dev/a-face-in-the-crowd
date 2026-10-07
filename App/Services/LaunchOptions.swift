import Foundation

/// The process launch arguments, parsed once and injected so services can be constructed with chosen flags.
public struct LaunchOptions: Sendable, Equatable {
    /// The full argument list this value was created from.
    public let arguments: [String]
    /// The arguments of the process this value was created in.
    public static let process = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)
    /// Creates options from a full argument list.
    public init(arguments: [String]) { self.arguments = arguments }
    /// True when the exact flag appears among the arguments.
    public func has(_ flag: String) -> Bool { arguments.contains(flag) }
    /// The argument immediately after the flag, when one is present.
    public func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
