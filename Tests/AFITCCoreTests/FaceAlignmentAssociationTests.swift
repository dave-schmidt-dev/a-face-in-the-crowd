import XCTest
@testable import AFITCCore

final class FaceAlignmentAssociationTests: XCTestCase {
    private let visionRevision = "vision-fixture-r3"
    private let yuNetRevision = "yunet-fixture-r1"

    private func frame(photoID: UUID = UUID(), version: Int = 4, width: Int = 100, height: Int = 40,
                       token: UUID = UUID()) -> FaceAlignmentFrame {
        FaceAlignmentFrame(photoID: photoID, contentVersion: version, rasterWidth: width,
                           rasterHeight: height, operationToken: token)
    }

    private func visionFace(_ id: UUID = UUID(), x: Double, y: Double,
                            width: Double, height: Double) -> FaceAlignmentVisionFace {
        FaceAlignmentVisionFace(faceID: id,
            box: FaceAlignmentNormalizedBox(x: x, y: y, width: width, height: height))
    }

    private func yuNetFace(_ points: SFaceFivePoints, x: Double, y: Double,
                           width: Double, height: Double) -> FaceAlignmentYuNetFace {
        FaceAlignmentYuNetFace(box: FaceAlignmentPixelBox(x: x, y: y, width: width, height: height),
                               points: points)
    }

    private func points(_ x: Float, _ y: Float) throws -> SFaceFivePoints {
        try SFaceFivePoints(
            SFacePoint(x: x, y: y),
            SFacePoint(x: x + 1, y: y + 0.25),
            SFacePoint(x: x + 2, y: y + 0.5),
            SFacePoint(x: x + 3, y: y + 0.75),
            SFacePoint(x: x + 4, y: y + 1)
        )
    }

    private func associate(_ current: FaceAlignmentFrame,
                           vision: FaceAlignmentVisionInput,
                           yuNet: FaceAlignmentYuNetInput,
                           expectedVisionRevision: String? = nil,
                           expectedYuNetRevision: String? = nil) -> FaceAlignmentAssociationResult {
        FaceAlignmentAssociator.associate(
            currentFrame: current,
            expectedVisionDetectorRevision: expectedVisionRevision ?? visionRevision,
            expectedYuNetDetectorRevision: expectedYuNetRevision ?? yuNetRevision,
            vision: vision,
            yuNet: yuNet
        )
    }

    private func visionInput(_ current: FaceAlignmentFrame, _ faces: [FaceAlignmentVisionFace],
                             revision: String? = nil) -> FaceAlignmentVisionInput {
        FaceAlignmentVisionInput(frame: current, detectorRevision: revision ?? visionRevision, faces: faces)
    }

    private func yuNetInput(_ current: FaceAlignmentFrame, _ faces: [FaceAlignmentYuNetFace],
                            revision: String? = nil) -> FaceAlignmentYuNetInput {
        FaceAlignmentYuNetInput(frame: current, detectorRevision: revision ?? yuNetRevision, faces: faces)
    }

    private func assertUnavailable(_ result: FaceAlignmentAssociationResult,
                                   _ expected: FaceAlignmentUnavailableReason,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(result.rows.isEmpty, file: file, line: line)
        XCTAssertTrue(result.rows.allSatisfy {
            $0.resolution == .unavailable(expected)
        }, file: file, line: line)
    }

    func testAsymmetricNonSquareCoordinatesAndVisionOrderPermutations() throws {
        let current = frame(width: 100, height: 40)
        let firstID = UUID(), secondID = UUID()
        let firstPoints = try points(12, 30)
        let secondPoints = try points(70, 10)
        let firstVision = visionFace(firstID, x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        let secondVision = visionFace(secondID, x: 0.7, y: 0.55, width: 0.2, height: 0.25)
        let firstYuNet = yuNetFace(firstPoints, x: 10, y: 28, width: 20, height: 8)
        let secondYuNet = yuNetFace(secondPoints, x: 70, y: 8, width: 20, height: 10)

        let forward = associate(current, vision: visionInput(current, [firstVision, secondVision]),
                                yuNet: yuNetInput(current, [firstYuNet, secondYuNet]))
        XCTAssertEqual(forward.rows.map(\.visionFaceID), [firstID, secondID])
        XCTAssertEqual(forward.rows.map(\.resolution), [.available(firstPoints), .available(secondPoints)])

        let reversed = associate(current, vision: visionInput(current, [secondVision, firstVision]),
                                 yuNet: yuNetInput(current, [secondYuNet, firstYuNet]))
        XCTAssertEqual(reversed.rows.map(\.visionFaceID), [secondID, firstID])
        XCTAssertEqual(reversed.rows.map(\.resolution), [.available(secondPoints), .available(firstPoints)])
    }

    func testNestedCrowdedAndMissingCandidatesAreUnavailable() throws {
        let current = frame(width: 100, height: 100)
        let outerID = UUID(), innerID = UUID()
        let nested = associate(current,
            vision: visionInput(current, [
                visionFace(outerID, x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                visionFace(innerID, x: 0.2, y: 0.2, width: 0.4, height: 0.4)
            ]),
            yuNet: yuNetInput(current, [yuNetFace(try points(22, 42), x: 20, y: 40, width: 40, height: 40)]))
        XCTAssertEqual(nested.rows.map(\.visionFaceID), [outerID, innerID])
        assertUnavailable(nested, .ambiguousOverlap)

        let crowded = associate(current,
            vision: visionInput(current, [visionFace(x: 0.1, y: 0.1, width: 0.6, height: 0.6)]),
            yuNet: yuNetInput(current, [
                yuNetFace(try points(12, 12), x: 10, y: 10, width: 30, height: 30),
                yuNetFace(try points(32, 32), x: 30, y: 30, width: 30, height: 30)
            ]))
        assertUnavailable(crowded, .ambiguousOverlap)

        let disjoint = associate(current,
            vision: visionInput(current, [visionFace(x: 0.1, y: 0.7, width: 0.1, height: 0.1)]),
            yuNet: yuNetInput(current, [yuNetFace(try points(40, 10), x: 40, y: 10, width: 10, height: 10)]))
        assertUnavailable(disjoint, .noPositiveIoU)

        let missing = associate(current,
            vision: visionInput(current, [visionFace(x: 0.1, y: 0.7, width: 0.1, height: 0.1)]),
            yuNet: yuNetInput(current, []))
        assertUnavailable(missing, .noPositiveIoU)
    }

    func testNonfiniteRepeatedZeroAndOutOfRasterGeometryReject() throws {
        let current = frame()
        let id = UUID()
        let goodVision = visionInput(current, [visionFace(id, x: 0.1, y: 0.5, width: 0.2, height: 0.2)])
        let goodPoints = try points(12, 20)

        let nonfiniteBox = yuNetInput(current, [
            yuNetFace(goodPoints, x: .nan, y: 20, width: 20, height: 10)
        ])
        assertUnavailable(associate(current, vision: goodVision, yuNet: nonfiniteBox), .invalidYuNetGeometry)

        let zeroBox = yuNetInput(current, [
            yuNetFace(goodPoints, x: 10, y: 20, width: 0, height: 10)
        ])
        assertUnavailable(associate(current, vision: goodVision, yuNet: zeroBox), .invalidYuNetGeometry)

        let repeated = try SFaceFivePoints(
            SFacePoint(x: 12, y: 20), SFacePoint(x: 12, y: 20), SFacePoint(x: 13, y: 21),
            SFacePoint(x: 14, y: 22), SFacePoint(x: 15, y: 23)
        )
        let repeatedInput = yuNetInput(current, [yuNetFace(repeated, x: 10, y: 20, width: 20, height: 10)])
        assertUnavailable(associate(current, vision: goodVision, yuNet: repeatedInput), .invalidYuNetGeometry)

        let outside = try points(-0.25, 20)
        let outsideInput = yuNetInput(current, [yuNetFace(outside, x: 0, y: 19, width: 20, height: 10)])
        assertUnavailable(associate(current, vision: goodVision, yuNet: outsideInput), .landmarksOutsideRaster)

        XCTAssertThrowsError(try SFaceFivePoints(
            SFacePoint(x: .infinity, y: 1), SFacePoint(x: 2, y: 2), SFacePoint(x: 3, y: 3),
            SFacePoint(x: 4, y: 4), SFacePoint(x: 5, y: 5)
        ))
    }

    func testPositiveWeakOverlapStillRequiresHalfPixelVisionContainment() throws {
        let current = frame(width: 100, height: 40)
        let id = UUID()
        let vision = visionInput(current, [visionFace(id, x: 0.1, y: 0.4, width: 0.1, height: 0.5)])
        // The candidate overlaps the Vision box by only 0.1 raster pixels, a positive-IoU edge.
        // One point is 0.8 pixels past the Vision right edge, beyond the fixed 0.5-pixel allowance.
        let candidate = yuNetFace(
            try SFaceFivePoints(
                SFacePoint(x: 20.8, y: 21), SFacePoint(x: 19.95, y: 21.25),
                SFacePoint(x: 19.96, y: 21.5), SFacePoint(x: 19.97, y: 21.75),
                SFacePoint(x: 19.98, y: 22)
            ),
            x: 19.9, y: 20, width: 1, height: 5
        )
        let result = associate(current, vision: vision, yuNet: yuNetInput(current, [candidate]))
        assertUnavailable(result, .landmarksOutsideVisionBounds)
        XCTAssertEqual(result.rows.map(\.visionFaceID), [id])
    }

    func testPhotoGenerationRasterTokenAndDetectorRevisionsMustMatch() throws {
        let current = frame()
        let id = UUID()
        let sourceVision = visionInput(current, [visionFace(id, x: 0.1, y: 0.5, width: 0.2, height: 0.2)])
        let sourceYuNet = yuNetInput(current, [yuNetFace(try points(12, 20), x: 10, y: 20, width: 20, height: 10)])

        let staleFrames = [
            frame(photoID: UUID(), version: current.contentVersion, width: current.rasterWidth,
                  height: current.rasterHeight, token: current.operationToken),
            frame(photoID: current.photoID, version: current.contentVersion + 1, width: current.rasterWidth,
                  height: current.rasterHeight, token: current.operationToken),
            frame(photoID: current.photoID, version: current.contentVersion, width: current.rasterWidth + 1,
                  height: current.rasterHeight, token: current.operationToken),
            frame(photoID: current.photoID, version: current.contentVersion, width: current.rasterWidth,
                  height: current.rasterHeight, token: UUID())
        ]
        for stale in staleFrames {
            let result = associate(current, vision: visionInput(stale, sourceVision.faces),
                                   yuNet: sourceYuNet)
            assertUnavailable(result, .staleProvenance)
            XCTAssertEqual(result.rows.map(\.visionFaceID), [id])
        }

        let badVisionRevision = associate(current,
            vision: visionInput(current, sourceVision.faces, revision: "wrong-vision-revision"),
            yuNet: sourceYuNet)
        assertUnavailable(badVisionRevision, .detectorRevisionMismatch)
        let badYuNetRevision = associate(current, vision: sourceVision,
            yuNet: yuNetInput(current, sourceYuNet.faces, revision: "wrong-yunet-revision"))
        assertUnavailable(badYuNetRevision, .detectorRevisionMismatch)

        let invalidFrame = frame(version: 0)
        let invalid = associate(invalidFrame, vision: visionInput(invalidFrame, sourceVision.faces),
                                yuNet: yuNetInput(invalidFrame, sourceYuNet.faces))
        assertUnavailable(invalid, .invalidFrame)
    }

    func testVisionAnalysisAndManualStatePayloadsRemainUnchanged() throws {
        let current = frame()
        let faceID = UUID(), personID = UUID()
        let geometry = FaceGeometry(id: faceID, rectangle: [0.1, 0.5, 0.2, 0.2],
                                    landmarks: [[0.1, 0.2], [0.3, 0.4]])
        let analysis = FaceAnalysisState(status: .successful, contentVersion: current.contentVersion,
                                        faces: [geometry])
        let photo = PhotoIdentity(id: current.photoID, relativePath: "fixture/one.jpg",
                                  contentVersion: current.contentVersion, analysis: analysis)
        let key = FaceKey(photo: photo, face: geometry)
        let person = PersonRecord(id: personID, displayName: "Fixture Person", cover: key)
        let manual = ManualFaceState(key: key, personID: personID, isAnchor: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let photoBefore = try encoder.encode(photo)
        let analysisBefore = try encoder.encode(analysis)
        let personBefore = try encoder.encode(person)
        let manualBefore = try encoder.encode(manual)

        let result = associate(current,
            vision: visionInput(current, [visionFace(faceID, x: 0.1, y: 0.45, width: 0.2, height: 0.2)]),
            yuNet: yuNetInput(current, [yuNetFace(try points(12, 20), x: 10, y: 12, width: 20, height: 10)]))
        XCTAssertEqual(result.rows.map(\.visionFaceID), [faceID])
        XCTAssertEqual(result.rows.first?.resolution, .available(try points(12, 20)))

        XCTAssertEqual(try encoder.encode(photo), photoBefore)
        XCTAssertEqual(try encoder.encode(analysis), analysisBefore)
        XCTAssertEqual(try encoder.encode(person), personBefore)
        XCTAssertEqual(try encoder.encode(manual), manualBefore)
    }
}
