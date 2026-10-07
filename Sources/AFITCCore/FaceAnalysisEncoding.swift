import Foundation

public enum FaceAnalysisEncodingError: Error, Sendable, Equatable {
    case invalidDimension
    case invalidByteCount
    case nonFiniteValues
    case zeroNorm
}

/// Bounded binary encoding for normalized 128-element Float32 face embedding vectors.
/// Fixed 512-byte layout: 128 32-bit floating-point numbers in host byte order.
public enum FaceAnalysisEncoding {
    public static let vectorDimension = 128
    public static let vectorByteCount = 512

    /// Encodes 128 finite Float values into exactly 512 bytes.
    public static func encodeVector(_ values: [Float]) throws -> Data {
        guard values.count == vectorDimension else {
            throw FaceAnalysisEncodingError.invalidDimension
        }
        guard values.allSatisfy(\.isFinite) else {
            throw FaceAnalysisEncodingError.nonFiniteValues
        }
        var data = Data(count: vectorByteCount)
        data.withUnsafeMutableBytes { buffer in
            let floatBuffer = buffer.bindMemory(to: Float.self)
            for i in 0..<vectorDimension {
                floatBuffer[i] = values[i]
            }
        }
        return data
    }

    /// Decodes exactly 512 bytes into 128 finite Float values.
    public static func decodeVector(_ data: Data) throws -> [Float] {
        guard data.count == vectorByteCount else {
            throw FaceAnalysisEncodingError.invalidByteCount
        }
        var values = [Float](repeating: 0, count: vectorDimension)
        data.withUnsafeBytes { buffer in
            let floatBuffer = buffer.bindMemory(to: Float.self)
            for i in 0..<vectorDimension {
                values[i] = floatBuffer[i]
            }
        }
        guard values.allSatisfy(\.isFinite) else {
            throw FaceAnalysisEncodingError.nonFiniteValues
        }
        return values
    }

    /// Validates that raw bytes represent 512 bytes of finite Floats.
    public static func isValidVectorBytes(_ data: Data) -> Bool {
        guard data.count == vectorByteCount else { return false }
        return data.withUnsafeBytes { buffer in
            let floatBuffer = buffer.bindMemory(to: Float.self)
            for i in 0..<vectorDimension {
                if !floatBuffer[i].isFinite { return false }
            }
            return true
        }
    }
}
