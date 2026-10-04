#if os(macOS)
import AFITCCore
import AFITCRuntime
import CryptoKit
import Darwin
import Foundation
import OnnxRuntimeBindings

extension SFaceOutputParity {
    static func run(
        runtime: FaceEmbeddingRuntime,
        provenance: FaceEmbeddingProvenance,
        manifest: ModelManifest,
        modelURL: URL,
        modelDigestBefore: String,
        wrongExpectedModelDigest: String?,
        defaultEvidenceRoot: URL
    ) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard try parityRequested() else {
            report("parity opt-in is off; the existing one-tensor actual-model diagnostic still ran")
            return
        }
        let wrongDigest = try required(
            wrongExpectedModelDigest,
            "Parity opt-in did not verify the wrong-digest rejection before session creation")
        let outputRootPath = environment["AFITC_SFACE_PARITY_EVIDENCE_ROOT"]
            ?? defaultEvidenceRoot.path
        let referenceRootPath = environment["AFITC_SFACE_REFERENCE_EVIDENCE_ROOT"] ?? outputRootPath
        let outputRoot = URL(fileURLWithPath: outputRootPath).standardizedFileURL
        let referenceEvidenceRoot = URL(fileURLWithPath: referenceRootPath).standardizedFileURL
        let fixtureRoot = referenceEvidenceRoot.appendingPathComponent(
            ".logs/verification/phase2.preprocessing-fixtures", isDirectory: true)
        let referenceRoot = referenceEvidenceRoot.appendingPathComponent(
            ".logs/verification/phase2.reference-output/attempt-optimized-true", isDirectory: true)
        let fixtureReceiptURL = fixtureRoot.appendingPathComponent("receipt.json")
        let referenceReceiptURL = referenceRoot.appendingPathComponent("reference-output.json")
        let outputBase = outputRoot.appendingPathComponent(
            ".logs/verification/phase2.ort-parity", isDirectory: true)
        let runID = UUID().uuidString.lowercased()
        let runRoot = outputBase.appendingPathComponent(runID, isDirectory: true)
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: runRoot.appendingPathComponent("outputs", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: runRoot.appendingPathComponent("controls", isDirectory: true),
            withIntermediateDirectories: true)

        let fixtureReceiptData = try Data(contentsOf: fixtureReceiptURL)
        let fixtureReceiptSHA = digest(fixtureReceiptData)
        try require(fixtureReceiptSHA == expectedFixtureReceiptSHA256,
                    "Frozen preprocessing fixture receipt SHA-256 changed")
        let fixtureJSON = try jsonObject(fixtureReceiptData, label: "fixture receipt")
        try require(string(fixtureJSON, "status") == "passed", "Fixture receipt is not passed")
        let fixtureCases = try array(fixtureJSON, "cases")
        try require(integer(fixtureJSON, "caseCount") == caseNames.count &&
                    fixtureCases.count == caseNames.count,
                    "Fixture receipt case count does not equal nine")

        let referenceReceiptData = try Data(contentsOf: referenceReceiptURL)
        let referenceReceiptSHA = digest(referenceReceiptData)
        try require(referenceReceiptSHA == expectedReferenceReceiptSHA256,
                    "Frozen OpenCV reference receipt SHA-256 changed")
        let referenceJSON = try jsonObject(referenceReceiptData, label: "reference output receipt")
        try require(string(referenceJSON, "status") == "counterfactual-passed",
                    "OpenCV reference is not the preserved optimized=true counterfactual")
        try require(string(referenceJSON, "canonicalConfigurationStatus") ==
                    "failed-optimized-false-Winograd-assertion",
                    "OpenCV canonical optimized=false failure status changed")
        try require(string(referenceJSON, "fixtureReceiptSHA256") == fixtureReceiptSHA,
                    "Reference output is not bound to the verified fixture receipt")
        let referenceModel = try object(referenceJSON, "model")
        try require(string(referenceModel, "sha256Before") == expectedModelSHA256 &&
                    integer(referenceModel, "bytesBefore") == expectedModelBytes,
                    "OpenCV reference was generated with different model bytes")
        try require(string(referenceModel, "sha256After") == expectedModelSHA256 &&
                    integer(referenceModel, "bytesAfter") == expectedModelBytes,
                    "OpenCV reference model was changed during inference")
        try require(modelDigestBefore == expectedModelSHA256,
                    "Swift ORT model digest does not match the pinned artifact")
        try require(try fileByteCount(modelURL) == expectedModelBytes,
                    "Swift ORT model byte count does not match the pinned artifact")
        let fixtureVerification = try object(referenceJSON, "fixtureVerification")
        try require(string(fixtureVerification, "status") == "passed" &&
                    integer(fixtureVerification, "caseCount") == 9 &&
                    integer(fixtureVerification, "fileCount") == 72,
                    "Frozen reference does not attest all nine cases and 72 input files")
        let tensorContract = try object(fixtureJSON, "tensorContract")
        try require(string(tensorContract, "savedFormat") ==
                    "raw little-endian float32, [1,3,112,112], RGB NCHW, values 0..255" &&
                    (tensorContract["allDirectPlanarComparisonsExact"] as? Bool) == true,
                    "Frozen tensor contract differs from the SFace manifest")

        var inputRecords = [[String: Any]]()
        var inputsByCase = [String: FixtureInput]()
        for caseObject in fixtureCases {
            let entry = try asObject(caseObject, label: "fixture case")
            let caseName = try string(entry, "case")
            try require(caseNames.contains(caseName) && inputsByCase[caseName] == nil,
                        "Unexpected or duplicate fixture case: \(caseName)")
            let caseTensorContract = try object(entry, "tensorContract")
            try require(integerArray(caseTensorContract, "shape") == manifest.inputShape &&
                        string(caseTensorContract, "dtype") == "float32" &&
                        string(caseTensorContract, "order") == "RGB NCHW" &&
                        string(caseTensorContract, "range") == "raw 0..255",
                        "Fixture \(caseName) tensor contract differs from the SFace manifest")
            let files = try object(entry, "files")
            try require(files.count == 8, "Fixture \(caseName) does not enumerate eight input files")
            for key in files.keys.sorted() {
                let record = try asObject(files[key]!, label: "fixture file \(key)")
                let (relative, data, sha) = try verifiedFile(root: fixtureRoot, record: record)
                inputRecords.append([
                    "case": caseName, "key": key, "file": relative,
                    "bytes": data.count, "sha256": sha, "verified": true
                ])
                if key == "tensorRGBNCHWFloat32LE" {
                    try require(data.count == tensorElementCount * MemoryLayout<Float>.size,
                                "Fixture \(caseName) tensor byte count is not 150528")
                    inputsByCase[caseName] = FixtureInput(file: relative, data: data, sha256: sha)
                }
            }
        }
        try require(Set(inputsByCase.keys) == Set(caseNames) && inputRecords.count == 72,
                    "Did not verify all 72 frozen input files and nine tensors")

        let referenceOutputs = try array(referenceJSON, "outputs")
        try require(referenceOutputs.count == caseNames.count,
                    "Reference receipt does not contain nine output pairs")
        var outputsByCase = [String: ReferenceOutput]()
        var referenceRecords = [[String: Any]]()
        for outputObject in referenceOutputs {
            let entry = try asObject(outputObject, label: "reference output")
            let caseName = try string(entry, "case")
            try require(caseNames.contains(caseName) && outputsByCase[caseName] == nil,
                        "Unexpected or duplicate reference case: \(caseName)")
            let feature = try object(entry, "featureOutput")
            let direct = try object(entry, "directTensorForwardOutput")
            let (featureFile, featureData, featureSHA) = try verifiedFile(root: referenceRoot, record: feature)
            let (directFile, directData, directSHA) = try verifiedFile(root: referenceRoot, record: direct)
            try require(featureData.count == outputElementCount * MemoryLayout<Float>.size &&
                        directData.count == featureData.count,
                        "Reference \(caseName) is not two complete 128-float outputs")
            try require(string(feature, "dtype") == "float32" &&
                        string(direct, "dtype") == "float32" &&
                        integer(feature, "elementCount") == outputElementCount &&
                        integer(direct, "elementCount") == outputElementCount &&
                        integerArray(feature, "shape") == manifest.outputShape &&
                        integerArray(direct, "shape") == manifest.outputShape,
                        "Reference \(caseName) output dtype or count changed")
            let featureValues = try floats(featureData, expectedCount: outputElementCount)
            let directValues = try floats(directData, expectedCount: outputElementCount)
            try require(featureValues.allSatisfy(\.isFinite) && directValues.allSatisfy(\.isFinite),
                        "Reference \(caseName) has a non-finite output")
            try require(featureData == directData,
                        "OpenCV feature and direct-tensor outputs differ for \(caseName)")
            let input = try required(inputsByCase[caseName], "Missing tensor for \(caseName)")
            let savedTensor = try object(entry, "savedTensor")
            try require(string(savedTensor, "sha256") == input.sha256 &&
                        string(savedTensor, "file") == input.file,
                        "Reference tensor binding differs for \(caseName)")
            outputsByCase[caseName] = ReferenceOutput(
                featureFile: featureFile, featureData: featureData, featureValues: featureValues,
                featureSHA256: featureSHA, directFile: directFile, directData: directData,
                directSHA256: directSHA)
            referenceRecords.append([
                "case": caseName, "featureFile": featureFile, "featureBytes": featureData.count,
                "featureSHA256": featureSHA, "directTensorFile": directFile,
                "directTensorBytes": directData.count, "directTensorSHA256": directSHA,
                "featureAndDirectTensorExactlyEqual": true
            ])
        }
        try require(Set(outputsByCase.keys) == Set(caseNames) && referenceRecords.count * 2 == 18,
                    "Did not verify all 18 frozen OpenCV output files")

        var progress: [String: Any] = [
            "runID": runID, "status": "running", "startedUTC": timestamp(),
            "fixtureReceiptSHA256": fixtureReceiptSHA,
            "referenceReceiptSHA256": referenceReceiptSHA,
            "modelPath": modelURL.standardizedFileURL.path,
            "modelSHA256Before": modelDigestBefore,
            "wrongExpectedModelDigestRejectedBeforeSession": true,
            "wrongExpectedModelDigestSHA256": digest(Data(wrongDigest.utf8)),
            "completedCases": [String]()
        ]
        let progressURL = runRoot.appendingPathComponent("run.json")
        try writeJSON(progress, to: progressURL)
        report("verified 72 fixture input hashes, 18 OpenCV output hashes, model digest, and pre-session bad-digest rejection")

        var caseMetrics = [[String: Any]]()
        for caseName in caseNames {
            report("running Swift ORT CPU fixture \(caseName)")
            let fixture = try required(inputsByCase[caseName], "Missing input for \(caseName)")
            let reference = try required(outputsByCase[caseName], "Missing output for \(caseName)")
            let inference = try await infer(runtime: runtime, provenance: provenance,
                                                   manifest: manifest, tensorData: fixture.data)
            try require(inference.values.count == outputElementCount &&
                        inference.values.allSatisfy(\.isFinite),
                        "Swift ORT produced a non-finite or incomplete output for \(caseName)")
            let outputData = inference.data
            let outputURL = runRoot.appendingPathComponent("outputs/\(caseName).f32le")
            try outputData.write(to: outputURL, options: .atomic)
            let metrics = compare(inference.values, reference.featureValues,
                                  byteIdentical: outputData == reference.featureData)
            caseMetrics.append([
                "case": caseName,
                "inputFile": fixture.file,
                "inputSHA256": fixture.sha256,
                "referenceFeatureFile": reference.featureFile,
                "referenceFeatureSHA256": reference.featureSHA256,
                "referenceDirectTensorFile": reference.directFile,
                "referenceDirectTensorSHA256": reference.directSHA256,
                "referenceFeatureAndDirectTensorExactlyEqual": reference.featureData == reference.directData,
                "outputFile": "outputs/\(caseName).f32le",
                "outputBytes": outputData.count,
                "outputSHA256": digest(outputData),
                "outputShape": inference.shape,
                "outputDtype": inference.elementType,
                "finiteCount": inference.values.filter(\.isFinite).count,
                "metricsAgainstOpenCVFeature": metrics,
                "metricsAgainstOpenCVDirectTensor": compare(
                    inference.values, try floats(reference.directData, expectedCount: outputElementCount),
                    byteIdentical: outputData == reference.directData)
            ])
            var completed = progress["completedCases"] as? [String] ?? []
            completed.append(caseName)
            progress["completedCases"] = completed
            progress["updatedUTC"] = timestamp()
            try writeJSON(progress, to: progressURL)
            report("saved 128-float output for \(caseName); finite=128; maxAbs=\(metrics["maxAbsoluteDelta"] ?? "n/a"), rms=\(metrics["rmsDelta"] ?? "n/a"), bitwiseExact=\(metrics["all128BitsEqual"] ?? false)")
        }

        let channelSource = try required(inputsByCase["channel-stride-sentinel"], "Missing channel sentinel")
        let channelReference = try required(outputsByCase["channel-stride-sentinel"], "Missing channel reference")
        let channelValues = try floats(channelSource.data, expectedCount: tensorElementCount)
        var wrongChannels = channelValues
        let plane = 112 * 112
        for index in 0..<plane {
            wrongChannels.swapAt(index, 2 * plane + index)
        }
        let channelControlData = encoded(wrongChannels)
        try require(digest(channelControlData) != channelSource.sha256,
                    "Wrong-RGB-plane control failed to change the input digest")
        let channelControl = try await runControl(
            name: "wrong-rgb-plane-order", caseName: "channel-stride-sentinel",
            tensorData: channelControlData, sourceData: channelSource.data,
            reference: channelReference.featureValues, runtime: runtime, provenance: provenance,
            manifest: manifest,
            runRoot: runRoot)

        let scaleSource = try required(inputsByCase["near-identity"], "Missing scale control input")
        let scaleReference = try required(outputsByCase["near-identity"], "Missing scale reference")
        let scaledValues = try floats(scaleSource.data, expectedCount: tensorElementCount).map { $0 / 255 }
        let scaleControlData = encoded(scaledValues)
        try require(digest(scaleControlData) != scaleSource.sha256,
                    "Wrong-scale control failed to change the input digest")
        let scaleControl = try await runControl(
            name: "wrong-scale-1-over-255", caseName: "near-identity",
            tensorData: scaleControlData, sourceData: scaleSource.data,
            reference: scaleReference.featureValues, runtime: runtime, provenance: provenance,
            manifest: manifest,
            runRoot: runRoot)

        let modelDigestAfter = try sha256(file: modelURL)
        let modelBytesAfter = try fileByteCount(modelURL)
        try require(modelDigestAfter == expectedModelSHA256 &&
                    modelBytesAfter == expectedModelBytes &&
                    modelDigestAfter == modelDigestBefore,
                    "Pinned model bytes changed during Swift ORT inference")
        let exactVectorCount = caseMetrics.filter {
            (($0["metricsAgainstOpenCVFeature"] as? [String: Any])?["all128BitsEqual"] as? Bool) == true
        }.count
        progress["status"] = "diagnostic-complete"
        progress["completedUTC"] = timestamp()
        progress["modelSHA256After"] = modelDigestAfter
        try writeJSON(progress, to: progressURL)
        let receipt: [String: Any] = [
            "task": "phase2.swift-ort-sface-nine-case-output-parity",
            "status": "diagnostic-complete",
            "numericalAcceptance": "No cross-backend tolerance is defined; differences are measured, not auto-accepted.",
            "parityClassification": exactVectorCount == caseNames.count
                ? "all-nine-bitwise-exact" : "one-or-more-measured-nonexact-differences",
            "automaticUsefulnessOrIdentityClaim": false,
            "runID": runID,
            "completedUTC": timestamp(),
            "runtime": [
                "onnxRuntimeVersion": ORTVersion() ?? "unknown",
                "hostOS": ProcessInfo.processInfo.operatingSystemVersionString,
                "provider": "CPU default only",
                "intraOpThreads": 1,
                "coreMLProviderAppended": false
            ],
            "provenance": [
                "fixtureReceipt": fixtureReceiptURL.path,
                "fixtureReceiptSHA256": fixtureReceiptSHA,
                "referenceOutputReceipt": referenceReceiptURL.path,
                "referenceOutputReceiptSHA256": referenceReceiptSHA,
                "referenceStatus": "optimized=true counterfactual",
                "canonicalOptimizedFalseStatus": "failed-optimized-false-Winograd-assertion",
                "referenceFeatureAndDirectTensorExactlyEqualForAllCases": true
            ],
            "model": [
                "path": modelURL.standardizedFileURL.path,
                "expectedBytes": expectedModelBytes,
                "expectedSHA256": expectedModelSHA256,
                "bytesBefore": try fileByteCount(modelURL),
                "sha256Before": modelDigestBefore,
                "bytesAfter": modelBytesAfter,
                "sha256After": modelDigestAfter,
                "unchanged": true
            ],
            "wrongExpectedModelDigestControl": [
                "testedBeforeSessionConstruction": true,
                "rejected": true,
                "wrongDigestSHA256": digest(Data(wrongDigest.utf8))
            ],
            "fixtureInputsVerified": inputRecords,
            "referenceOutputsVerified": referenceRecords,
            "caseOutputs": caseMetrics,
            "causalControls": [channelControl, scaleControl]
        ]
        try writeJSON(receipt, to: runRoot.appendingPathComponent("receipt.json"))
        report("complete: nine full outputs and two isolated control outputs saved at \(runRoot.path); no vector values printed")
    }

    private static func runControl(
        name: String,
        caseName: String,
        tensorData: Data,
        sourceData: Data,
        reference: [Float],
        runtime: FaceEmbeddingRuntime,
        provenance: FaceEmbeddingProvenance,
        manifest: ModelManifest,
        runRoot: URL
    ) async throws -> [String: Any] {
        report("running isolated control \(name)")
        let inputURL = runRoot.appendingPathComponent("controls/\(name).input.rgb-nchw.f32le")
        try tensorData.write(to: inputURL, options: .atomic)
        let inference = try await infer(runtime: runtime, provenance: provenance,
                                       manifest: manifest, tensorData: tensorData)
        try require(inference.values.count == outputElementCount &&
                    inference.values.allSatisfy(\.isFinite),
                    "Control \(name) produced a non-finite or incomplete output")
        let output = runRoot.appendingPathComponent("controls/\(name).output.f32le")
        try inference.data.write(to: output, options: .atomic)
        let metrics = compare(inference.values, reference, byteIdentical: inference.data == encoded(reference))
        return [
            "name": name,
            "case": caseName,
            "inputFile": "controls/\(name).input.rgb-nchw.f32le",
            "inputBytes": tensorData.count,
            "inputSHA256": digest(tensorData),
            "sourceInputSHA256": digest(sourceData),
            "inputChanged": digest(tensorData) != digest(sourceData),
            "outputFile": "controls/\(name).output.f32le",
            "outputBytes": inference.data.count,
            "outputSHA256": digest(inference.data),
            "outputShape": inference.shape,
            "outputDtype": inference.elementType,
            "finiteCount": inference.values.filter(\.isFinite).count,
            "metricsAgainstSameCaseOpenCVFeature": metrics
        ]
    }

    private static func infer(
        runtime: FaceEmbeddingRuntime,
        provenance: FaceEmbeddingProvenance,
        manifest: ModelManifest,
        tensorData: Data
    ) async throws -> Inference {
        try require(tensorData.count == tensorElementCount * MemoryLayout<Float>.size,
                    "Inference input is not 150528 Float32 bytes")
        let values = try floats(tensorData, expectedCount: tensorElementCount)
        let input = try ModelTensor(shape: manifest.inputShape, values: values)
        let result = try await runtime.embedding(from: input, provenance: provenance)
        let output = result.embedding.values
        try require(output.count == outputElementCount && output.allSatisfy(\.isFinite),
                    "AFITCRuntime returned a non-finite or incomplete output")
        return Inference(data: encoded(output), values: output,
                         shape: manifest.outputShape, elementType: "float32")
    }

    private static func compare(
        _ actual: [Float],
        _ reference: [Float],
        byteIdentical: Bool
    ) -> [String: Any] {
        let deltas = zip(actual, reference).map { Double($0.0) - Double($0.1) }
        let maxAbsoluteDelta = deltas.map { abs($0) }.max() ?? 0
        let rmsDelta = sqrt(deltas.reduce(0.0) { $0 + $1 * $1 } / Double(outputElementCount))
        let actualNorm = sqrt(actual.reduce(0.0) { $0 + Double($1) * Double($1) })
        let referenceNorm = sqrt(reference.reduce(0.0) { $0 + Double($1) * Double($1) })
        let dot = zip(actual, reference).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        let cosine = actualNorm > 0 && referenceNorm > 0 ? dot / (actualNorm * referenceNorm) : 0
        return [
            "all128BitsEqual": byteIdentical,
            "exactElementCount": zip(actual, reference).filter { $0.0.bitPattern == $0.1.bitPattern }.count,
            "maxAbsoluteDelta": maxAbsoluteDelta,
            "rmsDelta": rmsDelta,
            "actualL2Norm": actualNorm,
            "referenceL2Norm": referenceNorm,
            "rawCosineSimilarity": cosine
        ]
    }


}
#endif
