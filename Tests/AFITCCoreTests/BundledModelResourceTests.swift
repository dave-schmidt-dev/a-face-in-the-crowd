import CryptoKit
import Foundation
import XCTest
@testable import AFITCCore

final class BundledModelResourceTests: XCTestCase {
    func testPinnedModelDescriptorsUseFixedBundleNamesAndDigests() {
        let yunet = BundledModel.yuNet2023Mar.descriptor
        XCTAssertEqual(yunet.identifier, "yunet-2023mar")
        XCTAssertEqual(yunet.filename, "face_detection_yunet_2023mar.onnx")
        XCTAssertEqual(yunet.resourceName, "face_detection_yunet_2023mar")
        XCTAssertEqual(yunet.byteCount, 232_589)
        XCTAssertEqual(yunet.sha256, "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4")

        let sface = BundledModel.sface2021Dec.descriptor
        XCTAssertEqual(sface.identifier, "sface-2021dec")
        XCTAssertEqual(sface.filename, "face_recognition_sface_2021dec.onnx")
        XCTAssertEqual(sface.resourceName, "face_recognition_sface_2021dec")
        XCTAssertEqual(sface.byteCount, 38_696_353)
        XCTAssertEqual(sface.sha256, "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79")
        XCTAssertEqual(BundledModel.allCases.count, 2)
    }

    func testValidBundleResourceStreamsProgressAndReturnsTheSameReadOnlyURL() throws {
        let payload = Data((0..<(1 << 20) + 19).map { UInt8($0 % 251) })
        let (directory, file) = try makeFile(payload, named: "synthetic.onnx")
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = makeDescriptor(payload)
        let progress = ProgressCapture()

        let verified = try BundledModelResources.verify(descriptor, at: file) {
            progress.append($0)
        }

        XCTAssertEqual(verified.descriptor, descriptor)
        XCTAssertEqual(verified.url, file)
        XCTAssertEqual(verified.byteCount, payload.count)
        XCTAssertEqual(verified.sha256, descriptor.sha256)
        XCTAssertEqual(progress.values.map(\.completedBytes), [1 << 20, Int64(payload.count)])
        XCTAssertTrue(progress.values.allSatisfy { $0.totalBytes == Int64(payload.count) })
    }

    func testMissingWrongLengthAndSwappedBytesAreRejected() throws {
        let payload = Data([1, 2, 3, 4, 5])
        let (directory, file) = try makeFile(payload, named: "synthetic.onnx")
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try BundledModelResources.verify(makeDescriptor(payload), at: nil)) {
            XCTAssertEqual($0 as? BundledModelResourceError, .missing("test-model"))
        }
        XCTAssertThrowsError(try BundledModelResources.verify(
            makeDescriptor(payload, byteCount: payload.count + 1), at: file
        )) {
            XCTAssertEqual($0 as? BundledModelResourceError, .byteCountMismatch("test-model"))
        }
        XCTAssertThrowsError(try BundledModelResources.verify(
            makeDescriptor(payload, sha256: String(repeating: "0", count: 64)), at: file
        )) {
            XCTAssertEqual($0 as? BundledModelResourceError, .digestMismatch("test-model"))
        }
    }

    func testDirectoryAndSymbolicLinkAreNotAcceptedAsModelFiles() throws {
        let payload = Data([9, 8, 7])
        let (directory, file) = try makeFile(payload, named: "target.onnx")
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = makeDescriptor(payload)
        let folder = directory.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        XCTAssertThrowsError(try BundledModelResources.verify(descriptor, at: folder)) {
            XCTAssertEqual($0 as? BundledModelResourceError, .notRegularFile("test-model"))
        }
        let link = directory.appendingPathComponent("link.onnx")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try BundledModelResources.verify(descriptor, at: link)) {
            XCTAssertEqual($0 as? BundledModelResourceError, .notRegularFile("test-model"))
        }
    }

    func testCancellationNeverReturnsPartiallyVerifiedResource() throws {
        let payload = Data(repeating: 0x41, count: (2 << 20) + 3)
        let (directory, file) = try makeFile(payload, named: "synthetic.onnx")
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = makeDescriptor(payload)
        var checks = 0
        let progress = ProgressCapture()

        XCTAssertThrowsError(try BundledModelResources.verify(
            descriptor,
            at: file,
            progress: { progress.append($0) },
            cancellationCheck: {
                checks += 1
                return checks > 2
            }
        )) {
            XCTAssertEqual($0 as? BundledModelResourceError, .cancelled("test-model"))
        }
        XCTAssertEqual(progress.values.count, 1)
    }

    private func makeDescriptor(_ data: Data, byteCount: Int? = nil,
                               sha256: String? = nil) -> BundledModelDescriptor {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return BundledModelDescriptor(
            identifier: "test-model",
            filename: "synthetic.onnx",
            resourceName: "synthetic",
            byteCount: byteCount ?? data.count,
            sha256: sha256 ?? digest
        )
    }

    private func makeFile(_ data: Data, named name: String) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("afitc-bundled-model-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent(name)
        try data.write(to: file, options: .atomic)
        return (directory, file)
    }
}

private final class ProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [BundledModelProgress] = []

    func append(_ item: BundledModelProgress) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var values: [BundledModelProgress] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
