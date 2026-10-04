import CryptoKit
import Foundation
import XCTest
@testable import AFITCCore

final class SFacePreprocessingTests: XCTestCase {
    private enum Pattern {
        case asymmetricRGB
        case channelStrideSentinel
        case halfRounding
    }

    private struct Fixture {
        let name: String
        let pattern: Pattern
        let salt: UInt32
        let points: [SFacePoint]
        let expectedForwardMatrix: [Double]
        let expectedCropSHA256: String
        let expectedTensorSHA256: String
    }

    private static let fixtures: [Fixture] = [
        Fixture(
            name: "near-identity",
            pattern: .asymmetricRGB,
            salt: 1,
            points: [
                SFacePoint(x: Float(38.29460144042969), y: Float(51.6963005065918)),
                SFacePoint(x: Float(73.53179931640625), y: Float(51.501399993896484)),
                SFacePoint(x: Float(56.02519989013672), y: Float(71.73660278320312)),
                SFacePoint(x: Float(41.54930114746094), y: Float(92.3655014038086)),
                SFacePoint(x: Float(70.72989654541016), y: Float(92.2041015625))
            ],
            expectedForwardMatrix: [Double(0.9999999901097394), Double(2.309674939884841e-9), Double(0.000038535018560992285), Double(-2.3096749381188854e-9), Double(0.9999999901097396), Double(0.000023728703254732864)],
            expectedCropSHA256: "8d6dafdc65284be8f27a55206a37d1e2163bbcfd6d18388c7c8da635b5883dfe",
            expectedTensorSHA256: "9e7086ca0c39dc09dfd864e3c9733281b260c0b749843b34a742da76ec092f7d"
        ),
        Fixture(
            name: "rotated-scaled-translated-five-point",
            pattern: .asymmetricRGB,
            salt: 2,
            points: [
                SFacePoint(x: Float(58.154788970947266), y: Float(82.11077117919922)),
                SFacePoint(x: Float(97.33226776123047), y: Float(87.1972885131836)),
                SFacePoint(x: Float(75.07233428955078), y: Float(107.32373046875)),
                SFacePoint(x: Float(55.60356903076172), y: Float(128.1436767578125)),
                SFacePoint(x: Float(88.58702850341797), y: Float(132.16404724121094))
            ],
            expectedForwardMatrix: [Double(0.8794720054451298), Double(0.11497366769688344), Double(-22.23700566279588), Double(-0.11497366769688339), Double(0.8794720054451298), Double(-13.926574266951164)],
            expectedCropSHA256: "11b032a38299cc20c8a2cbfac25f79d5bd58865c10e8fd6412b27f240bb2edaf",
            expectedTensorSHA256: "8922d63e8d256f5ecf2e1e7f5c41b375353399f45f40374b9cd41e6cbf4f4dd5"
        ),
        Fixture(
            name: "partial-top-left-zero-border",
            pattern: .asymmetricRGB,
            salt: 3,
            points: [
                SFacePoint(x: Float(14.294601440429688), y: Float(20.696300506591797)),
                SFacePoint(x: Float(49.53179931640625), y: Float(20.501399993896484)),
                SFacePoint(x: Float(32.02519989013672), y: Float(40.736602783203125)),
                SFacePoint(x: Float(17.549301147460938), y: Float(61.365501403808594)),
                SFacePoint(x: Float(46.729896545410156), y: Float(61.2041015625))
            ],
            expectedForwardMatrix: [Double(0.9999999901097394), Double(2.309674939884841e-9), Double(24.00003836925223), Double(-2.3096749381188854e-9), Double(0.9999999901097396), Double(31.000023366672977)],
            expectedCropSHA256: "5e50ceb90aefb4f06f4bcab65da019c561514d9d08d1cb6e6374bbb563b89c64",
            expectedTensorSHA256: "76a5de81bc237835c2e796a0c759c06e77452672b7e19a6f493a1f6554b44cc8"
        ),
        Fixture(
            name: "partial-bottom-right-zero-border",
            pattern: .asymmetricRGB,
            salt: 4,
            points: [
                SFacePoint(x: Float(150.2946014404297), y: Float(119.69630432128906)),
                SFacePoint(x: Float(185.53179931640625), y: Float(119.50140380859375)),
                SFacePoint(x: Float(168.02520751953125), y: Float(139.73660278320312)),
                SFacePoint(x: Float(153.54930114746094), y: Float(160.36550903320312)),
                SFacePoint(x: Float(182.72988891601562), y: Float(160.2041015625))
            ],
            expectedForwardMatrix: [Double(1.0000000178821074), Double(2.4900984804337647e-8), Double(-111.99997597075125), Double(-2.4900984803409444e-8), Double(1.0000000178821076), Double(-67.99998305891478)],
            expectedCropSHA256: "a94091a1c9fd2412ac81dfef46868a48f6be4901034b61bdb72b7f208fa07369",
            expectedTensorSHA256: "ed93649b90ae9a98d8b93fa25f59b63a195c96ce2425e4df58605c237e6f77ca"
        ),
        Fixture(
            name: "channel-stride-sentinel",
            pattern: .channelStrideSentinel,
            salt: 5,
            points: [
                SFacePoint(x: Float(50.29460144042969), y: Float(55.6963005065918)),
                SFacePoint(x: Float(85.53179931640625), y: Float(55.501399993896484)),
                SFacePoint(x: Float(68.02519989013672), y: Float(75.73660278320312)),
                SFacePoint(x: Float(53.54930114746094), y: Float(96.3655014038086)),
                SFacePoint(x: Float(82.72989654541016), y: Float(96.2041015625))
            ],
            expectedForwardMatrix: [Double(1.0000000014065669), Double(2.7733031337447773e-9), Double(-11.999954529812015), Double(-2.773303133183391e-9), Double(1.0000000014065669), Double(-3.999977029918796)],
            expectedCropSHA256: "61b3994ec23f6acebb39fc7851486eeec62916ca7be6bf8902ae286cdd9b6950",
            expectedTensorSHA256: "c365b8abdc63a7fb024a889c34fc4ea40a5ee1281d4887e4d3cd0ad422730ec0"
        ),
        Fixture(
            name: "quant-phase-below-8-of-32",
            pattern: .asymmetricRGB,
            salt: 6,
            points: [
                SFacePoint(x: Float(38.54362487792969), y: Float(51.6963005065918)),
                SFacePoint(x: Float(73.78082275390625), y: Float(51.501399993896484)),
                SFacePoint(x: Float(56.27422332763672), y: Float(71.73660278320312)),
                SFacePoint(x: Float(41.79832458496094), y: Float(92.3655014038086)),
                SFacePoint(x: Float(70.97891998291016), y: Float(92.2041015625))
            ],
            expectedForwardMatrix: [Double(0.9999999901097394), Double(2.309674939884841e-9), Double(-0.24898490001852736), Double(-2.3096749381188854e-9), Double(0.9999999901097396), Double(0.000023729278410655752)],
            expectedCropSHA256: "3e6084c92ec25e933f5cf64587222ce3108cd66059fedd944284cb9a0ec55c4c",
            expectedTensorSHA256: "85b095452e035d15f38904a550c4935ee43960eed01ee85fcec64d5b006b75c7"
        ),
        Fixture(
            name: "quant-phase-exact-8-of-32",
            pattern: .asymmetricRGB,
            salt: 7,
            points: [
                SFacePoint(x: Float(38.54460144042969), y: Float(51.6963005065918)),
                SFacePoint(x: Float(73.78179931640625), y: Float(51.501399993896484)),
                SFacePoint(x: Float(56.27519989013672), y: Float(71.73660278320312)),
                SFacePoint(x: Float(41.79930114746094), y: Float(92.3655014038086)),
                SFacePoint(x: Float(70.97989654541016), y: Float(92.2041015625))
            ],
            expectedForwardMatrix: [Double(0.9999999901097394), Double(2.309674939884841e-9), Double(-0.24996146250887108), Double(-2.3096749381188854e-9), Double(0.9999999901097396), Double(0.00002372928067018165)],
            expectedCropSHA256: "c9e347ff971f3ae763b06b6ecd13f2eff42361f6dbdf2b0da5d00cec1aebcecd",
            expectedTensorSHA256: "d8fb145fcf42d3c562ec89456f0a364873e695cdacf44194bd1128a53a1e7a93"
        ),
        Fixture(
            name: "quant-phase-above-8-of-32",
            pattern: .asymmetricRGB,
            salt: 8,
            points: [
                SFacePoint(x: Float(38.54557800292969), y: Float(51.6963005065918)),
                SFacePoint(x: Float(73.78277587890625), y: Float(51.501399993896484)),
                SFacePoint(x: Float(56.27617645263672), y: Float(71.73660278320312)),
                SFacePoint(x: Float(41.80027770996094), y: Float(92.3655014038086)),
                SFacePoint(x: Float(70.98087310791016), y: Float(92.2041015625))
            ],
            expectedForwardMatrix: [Double(0.9999999901097394), Double(2.309674939884841e-9), Double(-0.2509380249992148), Double(-2.3096749381188854e-9), Double(0.9999999901097396), Double(0.00002372928292970755)],
            expectedCropSHA256: "57cd79c0076fd310d15cdc21839d7e271ec5ace676873b540f209881c0c736d7",
            expectedTensorSHA256: "e4a7accec131cb727c06e1f146b4a651c62e8ba372996a7485d6fa8075bac114"
        ),
        Fixture(
            name: "uint8-half-rounding",
            pattern: .halfRounding,
            salt: 9,
            points: [
                SFacePoint(x: Float(38.79460144042969), y: Float(51.6963005065918)),
                SFacePoint(x: Float(74.03179931640625), y: Float(51.501399993896484)),
                SFacePoint(x: Float(56.52519989013672), y: Float(71.73660278320312)),
                SFacePoint(x: Float(42.04930114746094), y: Float(92.3655014038086)),
                SFacePoint(x: Float(71.22989654541016), y: Float(92.2041015625))
            ],
            expectedForwardMatrix: [Double(0.9999999901097394), Double(2.309674939884841e-9), Double(-0.49996146003630315), Double(-2.3096749381188854e-9), Double(0.9999999901097396), Double(0.00002372985808563044)],
            expectedCropSHA256: "6ffc4e9be76de5f81e422bcb33d5a17ea15adc7f43696f92bcbe4bfa2c2dc3aa",
            expectedTensorSHA256: "f2ad77994e0f79fd46324f822a0840c7f7d3c202f89a835e3109b9da50c84cd8"
        )
    ]

    func testOpenCV410FixtureCropsAndTensorsAreBitExact() throws {
        for fixture in Self.fixtures {
            let raster = try makeRaster(pattern: fixture.pattern, salt: fixture.salt)
            let result = try SFacePreprocessor.prepare(raster: raster, points: fivePoints(fixture.points))
            let deltas = zip(result.diagnostics.forwardMatrix, fixture.expectedForwardMatrix).map {
                abs($0 - $1)
            }
            let maxDelta = deltas.max() ?? 0
            print("[SFace preprocessing] case=\(fixture.name) maxForwardCoefficientDelta=\(maxDelta)")
            XCTAssertEqual(sha256(Data(result.alignedRGB8.bytes)), fixture.expectedCropSHA256,
                           "OpenCV 4.10 crop hash mismatch for \(fixture.name)")
            XCTAssertEqual(sha256(float32LEBytes(result.modelInput.values)), fixture.expectedTensorSHA256,
                           "OpenCV 4.10 NCHW tensor hash mismatch for \(fixture.name)")
            XCTAssertEqual(result.modelInput.shape, [1, 3, 112, 112], fixture.name)
            XCTAssertEqual(result.modelInput.values.count, 3 * 112 * 112, fixture.name)
        }
    }

    func testPaddedRGBRowsMatchPackedOpenCVReference() throws {
        let fixture = try XCTUnwrap(Self.fixtures.first { $0.name == "channel-stride-sentinel" })
        let packed = try makeRaster(pattern: fixture.pattern, salt: fixture.salt)
        let paddedRowBytes = packed.width * 3 + 7
        var padded = [UInt8](repeating: 0xA5, count: paddedRowBytes * packed.height)
        for y in 0..<packed.height {
            let src = y * packed.rowBytes
            let dst = y * paddedRowBytes
            padded[dst..<(dst + packed.width * 3)] =
                packed.bytes[src..<(src + packed.width * 3)]
        }
        let raster = try RGB8Raster(width: packed.width, height: packed.height,
                                    rowBytes: paddedRowBytes, bytes: padded)
        let result = try SFacePreprocessor.prepare(raster: raster, points: fivePoints(fixture.points))
        XCTAssertEqual(sha256(Data(result.alignedRGB8.bytes)), fixture.expectedCropSHA256)
        XCTAssertEqual(sha256(float32LEBytes(result.modelInput.values)), fixture.expectedTensorSHA256)
    }

    func testInvalidInputsFailClosed() throws {
        XCTAssertThrowsError(try RGB8Raster(width: 0, height: 1, bytes: []))
        let maximumWidth = try RGB8Raster(width: 32_766, height: 1,
                                         bytes: [UInt8](repeating: 0, count: 32_766 * 3))
        let maximumHeight = try RGB8Raster(width: 1, height: 32_766,
                                          bytes: [UInt8](repeating: 0, count: 32_766 * 3))
        XCTAssertEqual(maximumWidth.width, RGB8Raster.maximumDimension)
        XCTAssertEqual(maximumHeight.height, RGB8Raster.maximumDimension)
        XCTAssertThrowsError(try RGB8Raster(width: 32_767, height: 1, bytes: [])) {
            XCTAssertEqual($0 as? SFacePreprocessingError, .invalidDimensions)
        }
        XCTAssertThrowsError(try RGB8Raster(width: 1, height: 32_767, bytes: [])) {
            XCTAssertEqual($0 as? SFacePreprocessingError, .invalidDimensions)
        }
        XCTAssertThrowsError(try RGB8Raster(width: 2, height: 1, rowBytes: 5, bytes: [UInt8](repeating: 0, count: 5)))
        XCTAssertThrowsError(try RGB8Raster(width: 2, height: 2, rowBytes: 6, bytes: [0]))
        XCTAssertThrowsError(try RGB8Raster(width: 2, height: 10, rowBytes: Int.max, bytes: []))

        XCTAssertThrowsError(try SFaceFivePoints(
            SFacePoint(x: .nan, y: 0), SFacePoint(x: 0, y: 0), SFacePoint(x: 1, y: 0),
            SFacePoint(x: 0, y: 1), SFacePoint(x: 1, y: 1)
        ))
        let repeated = try SFaceFivePoints(
            SFacePoint(x: 4, y: 4), SFacePoint(x: 4, y: 4), SFacePoint(x: 4, y: 4),
            SFacePoint(x: 4, y: 4), SFacePoint(x: 4, y: 4)
        )
        let raster = try RGB8Raster(width: 2, height: 2, bytes: [UInt8](repeating: 0, count: 12))
        XCTAssertThrowsError(try SFacePreprocessor.prepare(raster: raster, points: repeated))
        XCTAssertThrowsError(try SFaceSimilarityTransform(
            m00: 1, m01: 2, m02: 0, m10: 2, m11: 4, m12: 0
        ))

        let tinyScale = try SFaceSimilarityTransform(
            m00: 1e-20, m01: 0, m02: 0, m10: 0, m11: 1e-20, m12: 0
        )
        XCTAssertThrowsError(try SFacePreprocessor.warp(raster, using: tinyScale))
    }

    private func fivePoints(_ points: [SFacePoint]) throws -> SFaceFivePoints {
        guard points.count == 5 else { throw SFacePreprocessingError.degeneratePoints }
        return try SFaceFivePoints(points[0], points[1], points[2], points[3], points[4])
    }

    private func makeRaster(pattern: Pattern, salt: UInt32) throws -> RGB8Raster {
        let width = 192
        let height = 160
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let xx = UInt32(x)
                let yy = UInt32(y)
                let red: UInt32
                let green: UInt32
                let blue: UInt32
                switch pattern {
                case .asymmetricRGB:
                    red = (3 * xx + 7 * yy + 11 * salt) % 256
                    green = (11 * xx + 5 * yy + 29 * salt + 17) % 256
                    blue = ((xx ^ (3 * yy + salt)) + 59 + 13 * salt) % 256
                case .channelStrideSentinel:
                    red = (17 + 3 * xx + 7 * yy) % 256
                    green = (83 + 11 * xx + 5 * yy) % 256
                    blue = (211 + 13 * xx + 17 * yy) % 256
                case .halfRounding:
                    red = UInt32(100 + x % 2)
                    green = UInt32(70 + (x + y) % 2)
                    blue = UInt32(210 - (x / 2 + y) % 2)
                }
                bytes.append(UInt8(red))
                bytes.append(UInt8(green))
                bytes.append(UInt8(blue))
            }
        }
        return try RGB8Raster(width: width, height: height, bytes: bytes)
    }

    private func float32LEBytes(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * MemoryLayout<UInt32>.size)
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
