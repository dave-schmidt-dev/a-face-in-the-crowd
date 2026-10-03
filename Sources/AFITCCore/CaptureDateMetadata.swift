import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Source EXIF wall-clock time, never interpreted in the device time zone or sorted as UTC.
public struct CaptureDateMetadata: Codable, Sendable, Equatable {
    public let localWallClock: String
    public let sourceOffset: String?
    public let provenance: String

    private init(localWallClock: String, sourceOffset: String?) {
        self.localWallClock = localWallClock; self.sourceOffset = sourceOffset
        self.provenance = "exif.dateTimeOriginal"
    }
    private enum CodingKeys: String, CodingKey { case localWallClock, sourceOffset, provenance }
    /// Catalog payloads must satisfy the same value contract as source extraction.
    public init(from decoder: Decoder) throws {
        do {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let local = try values.decode(String.self, forKey: .localWallClock)
            let offset = try values.decodeIfPresent(String.self, forKey: .sourceOffset)
            let provenance = try values.decode(String.self, forKey: .provenance)
            var bytes = Array(local.utf8)
            guard bytes.count == 19, bytes[4] == 45, bytes[7] == 45, bytes[10] == 84,
                  provenance == "exif.dateTimeOriginal" else { throw Self.corrupt(decoder) }
            bytes[4] = 58; bytes[7] = 58; bytes[10] = 32
            guard let parsed = Self.parse(original: String(decoding: bytes, as: UTF8.self), offset: offset),
                  parsed.localWallClock == local, parsed.sourceOffset == offset else { throw Self.corrupt(decoder) }
            self = parsed
        } catch {
            // Missing, mistyped or malformed fields cannot turn into valid sort keys silently.
            throw Self.corrupt(decoder)
        }
    }
    private static func corrupt(_ decoder: Decoder) -> DecodingError {
        .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid persisted capture metadata."))
    }
    /// Metadata-only extraction. Caller must first validate the original JPEG with the bounded pipeline.
    public static func extract(fromValidatedJPEG data: Data) -> CaptureDateMetadata? {
        guard !data.isEmpty, data.count <= DecodeLimits.maximumFileBytes,
              let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        return parse(original: original, offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String)
    }
    /// Conservative Gregorian application subset of EXIF's ASCII date grammar; leap-second 60 is unsupported.
    static func parse(original: String, offset: String?) -> CaptureDateMetadata? {
        let bytes = sourceASCII(original)
        guard bytes.count == 19, bytes[4] == 58, bytes[7] == 58, bytes[10] == 32,
              bytes[13] == 58, bytes[16] == 58 else { return nil }
        let separators = Set([4, 7, 10, 13, 16])
        guard bytes.indices.allSatisfy({ separators.contains($0) || (48...57).contains(bytes[$0]) }) else { return nil }
        func number(_ start: Int, _ count: Int) -> Int {
            bytes[start..<(start + count)].reduce(0) { $0 * 10 + Int($1 - 48) }
        }
        let year = number(0, 4), month = number(5, 2), day = number(8, 2)
        guard (1...9999).contains(year), (1...12).contains(month),
              (0...23).contains(number(11, 2)), (0...59).contains(number(14, 2)),
              (0...59).contains(number(17, 2)) else { return nil }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...days[month - 1]).contains(day) else { return nil }
        var normalized = bytes
        normalized[4] = 45; normalized[7] = 45; normalized[10] = 84
        return CaptureDateMetadata(localWallClock: String(decoding: normalized, as: UTF8.self),
                                   sourceOffset: validOffset(offset))
    }
    private static func validOffset(_ value: String?) -> String? {
        guard let value else { return nil }
        let bytes = sourceASCII(value)
        guard bytes.count == 6, bytes[0] == 43 || bytes[0] == 45, bytes[3] == 58,
              [1, 2, 4, 5].allSatisfy({ (48...57).contains(bytes[$0]) }) else { return nil }
        let hours = Int(bytes[1] - 48) * 10 + Int(bytes[2] - 48)
        let minutes = Int(bytes[4] - 48) * 10 + Int(bytes[5] - 48)
        // Conservative app subset; EXIF specifies grammar/count without normative numeric offset bounds.
        guard hours <= 23, minutes <= 59 else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
    private static func sourceASCII(_ value: String) -> [UInt8] {
        var bytes = Array(value.utf8)
        if bytes.last == 0 { bytes.removeLast() }
        return bytes
    }
}
