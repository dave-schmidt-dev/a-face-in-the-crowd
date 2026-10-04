import Foundation
import Darwin

/// Immutable role-local method; iOS retains its existing Foundation implementation.
enum MarkerFullProtectionArm: String, Sendable, Codable {
    case foundation, descriptor
    static var production: Self {
        #if os(macOS)
        return .descriptor
        #else
        return .foundation
        #endif
    }
}
/// Exact bytes derived from owned Foundation-treated calibration metadata, never runtime calibration.
enum MarkerDescriptorValue {
    static let fixed = Data(base64Encoded: "YnBsaXN0MDBfEBFjb20uYXBwbGUuYmFja3VwZAgAAAAAAAABAQAAAAAAAAABAAAAAAAAAAAAAAAAAAAAHA==")!
    static func checked(_ bytes: Data?) throws -> Data {
        guard let bytes, !bytes.isEmpty, bytes.count <= 1024, bytes == fixed,
              try PropertyListSerialization.propertyList(from: bytes, format: nil) as? String == "com.apple.backupd" else { throw RestoreFileError.unsafeEntry }
        return bytes
    }
}

/// Fixed test-only API contrasts, never a product setting or an exclusion qualification.
enum MarkerExclusionMechanism: String, CaseIterable, Sendable {
    case none, foundationPath, foundationDescriptor, descriptorPath, descriptorDescriptor
}

/// Opaque bytes must come from a freshly owned Foundation-treated calibration file.
/// The known key/semantic value mirror the current macOS catalog exclusion contract.
struct CalibratedMarkerExclusion: Sendable {
    static let key = "com.apple.metadata:com_apple_backup_excludeItem"
    let mechanism: MarkerExclusionMechanism
    let bytes: Data
    init(mechanism: MarkerExclusionMechanism, bytes: Data) throws {
        guard !bytes.isEmpty, bytes.count <= 1024,
              try PropertyListSerialization.propertyList(from: bytes, format: nil) as? String == "com.apple.backupd" else {
            throw RestoreFileError.unsafeEntry
        }
        self.mechanism = mechanism; self.bytes = bytes
    }
    #if os(macOS)
    /// Identical bounded validation for either readback mechanism; no invented plist encoding.
    static func read(_ url: URL, descriptor: Int32, throughDescriptor: Bool) throws -> Data {
        let count = throughDescriptor ? fgetxattr(descriptor, key, nil, 0, 0, 0) : getxattr(url.path, key, nil, 0, 0, 0)
        guard count > 0, count <= 1024 else { throw RestoreFileError.unsafeEntry }
        var bytes = [UInt8](repeating: 0, count: count)
        let actual = throughDescriptor ? fgetxattr(descriptor, key, &bytes, count, 0, 0) : getxattr(url.path, key, &bytes, count, 0, 0)
        guard actual == count else { throw RestoreFileError.syscall(errno) }
        return Data(bytes)
    }
    func apply(_ url: URL, descriptor: Int32) throws {
        guard mechanism != .none else { return }
        if mechanism == .foundationPath || mechanism == .foundationDescriptor {
            var value = url
            var resources = URLResourceValues(); resources.isExcludedFromBackup = true
            try value.setResourceValues(resources)
        } else {
            let status = bytes.withUnsafeBytes { fsetxattr(descriptor, Self.key, $0.baseAddress, $0.count, 0, 0) }
            guard status == 0 else { throw RestoreFileError.syscall(errno) }
        }
        let actual = try Self.read(url, descriptor: descriptor,
            throughDescriptor: mechanism == .foundationDescriptor || mechanism == .descriptorDescriptor)
        guard actual == bytes else { throw RestoreFileError.unsafeEntry }
        _ = try Self(mechanism: mechanism, bytes: actual)
    }
    #endif
}

/// Fixed internal component interventions for synthetic filesystem diagnosis only.
/// Production construction always defaults to the existing complete protection path.
enum RestoreMarkerProtection: String, CaseIterable, Sendable, Codable {
    case none, exclusionOnly, permissionsOnly, full

    func apply(_ url: URL, descriptor: Int32, calibratedExclusion: CalibratedMarkerExclusion?, fullArm: MarkerFullProtectionArm) throws {
        if let calibratedExclusion {
            #if os(macOS)
            try calibratedExclusion.apply(url, descriptor: descriptor); return
            #else
            throw RestoreFileError.unsafeEntry // No descriptor-equivalence claim on iOS.
            #endif
        }
        switch self {
        case .none: break // O_CREAT already creates the regular marker with mode 0600.
        case .exclusionOnly:
            var value = url
            var resources = URLResourceValues(); resources.isExcludedFromBackup = true
            try value.setResourceValues(resources)
            guard try CatalogRepository.excludedFromBackup(url) else { throw ScanError.database }
        case .permissionsOnly:
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            #endif
        case .full:
            #if os(macOS)
            if fullArm == .descriptor {
                let bytes = try MarkerDescriptorValue.checked(MarkerDescriptorValue.fixed)
                let status = bytes.withUnsafeBytes { fsetxattr(descriptor, CalibratedMarkerExclusion.key, $0.baseAddress, $0.count, 0, 0) }
                guard status == 0 else { throw RestoreFileError.syscall(errno) }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                guard try CatalogRepository.excludedFromBackup(url) else { throw ScanError.database }
            } else { try CatalogRepository.protect(url) }
            #else
            try CatalogRepository.protect(url)
            #endif
        }
    }
}

/// Internal immutable policy only for app-created backup, validation and restore outputs.
/// Callers establish ownership before invoking it; original input paths never enter this API.
enum OwnedRestoreProtection: String, Sendable, Codable {
    case foundation, descriptor
    static var production: Self {
        #if os(macOS)
        return .descriptor
        #else
        return .foundation
        #endif
    }
    func apply(_ url: URL, directory: Bool = false, descriptor supplied: Int32? = nil,
               configuredBytes: Data? = MarkerDescriptorValue.fixed) throws {
        let bytes = try MarkerDescriptorValue.checked(configuredBytes)
        #if os(macOS)
        if self == .descriptor {
            let fd = supplied ?? Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : 0))
            guard fd >= 0 else { throw RestoreFileError.syscall(errno) }
            var closed = supplied != nil
            defer { if !closed { Darwin.close(fd) } }
            var info = stat(), path = stat()
            guard fstat(fd, &info) == 0, lstat(url.path, &path) == 0,
                  info.st_dev == path.st_dev, info.st_ino == path.st_ino,
                  info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
                  directory || info.st_nlink == 1 else { throw RestoreFileError.unsafeEntry }
            let status = bytes.withUnsafeBytes { fsetxattr(fd, CalibratedMarkerExclusion.key, $0.baseAddress, $0.count, 0, 0) }
            guard status == 0 else { throw RestoreFileError.syscall(errno) }
            try FileManager.default.setAttributes([.posixPermissions: directory ? 0o700 : 0o600], ofItemAtPath: url.path)
            guard try CatalogRepository.excludedFromBackup(url), lstat(url.path, &path) == 0,
                  info.st_dev == path.st_dev, info.st_ino == path.st_ino else { throw RestoreFileError.unsafeEntry }
            if supplied == nil { guard Darwin.close(fd) == 0 else { throw RestoreFileError.syscall(errno) }; closed = true }
            return
        }
        #endif
        try CatalogRepository.protect(url, directory: directory)
    }
}
