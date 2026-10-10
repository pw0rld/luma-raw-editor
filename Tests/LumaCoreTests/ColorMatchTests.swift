#if !STANDALONE_CHECK
import XCTest
#endif
import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import LumaCore

final class ColorMatchTests: XCTestCase {
    private let referenceHash = String(repeating: "b", count: 64)

    private func samples(shiftA: Double = 0, shiftB: Double = 0, shiftL: Double = 0) -> [LabColor] {
        let colors: [(Double, Double)] = [(25, 20), (-24, 22), (8, -27)]
        return (0..<150).map { index in
            let center = colors[index % colors.count]
            return LabColor(lightness: 25 + Double(index % 50) + shiftL,
                a: center.0 + Double(index % 7) * 0.4 + shiftA,
                b: center.1 + Double(index % 11) * 0.3 + shiftB)
        }
    }

    func testLabConversionDeterministicAnalysisAndIdentity() throws {
        // Extended linear RGB values must survive the color-space conversion.
        let extended = [-0.025, 0.18, 1.4]
        let recovered = LabColor.fromLinearP3(extended).linearP3
        XCTAssertLessThan(zip(extended, recovered).map { abs($0 - $1) }.max()!, 0.000001)
        let input = samples()
        let first = try MatchAnalysis.analyze(input, clusterCount: 3)
        XCTAssertEqual(first, try MatchAnalysis.analyze(input, clusterCount: 3))
        XCTAssertEqual(first.clusters.count, 3)
        XCTAssertLessThan(abs(first.clusters.map(\.weight).reduce(0, +) - 1), 0.000001)
        var identity = try ColorMatch.make(source: first, reference: first,
            referenceName: "same.png", referenceSHA256: referenceHash)
        identity.colorStrength = 1
        identity.luminanceStrength = 1
        let error = input.map { original -> Double in
            let result = identity.mapped(original)
            return max(abs(result.a - original.a), abs(result.b - original.b))
        }.max()!
        XCTAssertLessThan(error, 0.000001)
        // The identity tone curve stays close to the identity even between sample points.
        XCTAssertLessThan(abs(identity.mapped(LabColor(lightness: 50, a: 8, b: -25)).lightness - 50), 0.5)
        XCTAssertThrowsError(try MatchAnalysis.analyze([], clusterCount: 3))
        XCTAssertThrowsError(try MatchAnalysis.analyze(input, clusterCount: 0))
        XCTAssertThrowsError(try MatchAnalysis.analyze(input, clusterCount: 6))
        XCTAssertThrowsError(try MatchAnalysis.analyze(Array(repeating: LabColor(lightness: .nan, a: 0, b: 0), count: 64), clusterCount: 1))
    }

    func testIndependentStrengthsToneMonotonicityAndFlatProtection() throws {
        let source = try MatchAnalysis.analyze(samples(), clusterCount: 1)
        let reference = try MatchAnalysis.analyze(samples(shiftA: 12, shiftB: -8, shiftL: 10), clusterCount: 1)
        var match = try ColorMatch.make(source: source, reference: reference,
            referenceName: "reference.png", referenceSHA256: referenceHash)
        match.colorStrength = 1
        match.luminanceStrength = 0
        let input = LabColor(lightness: 50, a: 10, b: 7)
        let colorOnly = match.mapped(input)
        XCTAssertEqual(colorOnly.lightness, input.lightness)
        XCTAssertLessThan(abs(colorOnly.a - (input.a + 12)), 0.01)
        XCTAssertLessThan(abs(colorOnly.b - (input.b - 8)), 0.01)
        match.colorStrength = 0
        match.luminanceStrength = 1
        let toneOnly = match.mapped(input)
        XCTAssertEqual(toneOnly.a, input.a)
        XCTAssertEqual(toneOnly.b, input.b)
        XCTAssertLessThan(abs(toneOnly.lightness - 60), 1)
        XCTAssertEqual(match.toneCurve.count, 257)
        XCTAssertTrue(zip(match.toneCurve, match.toneCurve.dropFirst()).allSatisfy { $0 <= $1 })
        XCTAssertTrue(match.toneCurve.allSatisfy { $0.isFinite && (0...100).contains($0) })
        match.luminanceStrength = 0
        XCTAssertEqual(match.mapped(input), input)

        let flat = try MatchAnalysis.analyze(Array(repeating: LabColor(lightness: 50, a: 0, b: 0), count: 80), clusterCount: 5)
        let warmFlat = try MatchAnalysis.analyze(Array(repeating: LabColor(lightness: 65, a: 10, b: 8), count: 80), clusterCount: 5)
        var flatMatch = try ColorMatch.make(source: flat, reference: warmFlat,
            referenceName: "flat.png", referenceSHA256: referenceHash)
        flatMatch.colorStrength = 1; flatMatch.luminanceStrength = 1
        let finite = flatMatch.mapped(LabColor(lightness: 50, a: 0, b: 0))
        XCTAssertTrue([finite.lightness, finite.a, finite.b].allSatisfy(\.isFinite))
        XCTAssertLessThan(abs(finite.a), 40)
        XCTAssertLessThan(abs(finite.b), 40)
        XCTAssertTrue(flatMatch.toneCurve.allSatisfy(\.isFinite))
    }

    func testMatchValidationRecipeMigrationAndHistory() throws {
        let analysis = try MatchAnalysis.analyze(samples(), clusterCount: 3)
        let match = try ColorMatch.make(source: analysis, reference: analysis,
            referenceName: "reference.png", referenceSHA256: referenceHash)
        try match.validate()
        XCTAssertThrowsError(try ColorMatch.make(source: analysis, reference: analysis,
            referenceName: "reference.png", referenceSHA256: "not-a-hash"))
        var invalid = match; invalid.colorStrength = 1.1
        XCTAssertThrowsError(try invalid.validate())
        invalid = match; invalid.luminanceStrength = .nan
        XCTAssertThrowsError(try invalid.validate())
        invalid = match; invalid.dominance = -0.1
        XCTAssertThrowsError(try invalid.validate())

        let encoder = JSONEncoder()
        var json = try JSONSerialization.jsonObject(with: encoder.encode(match)) as! [String: Any]
        json["sourceClusters"] = []
        let empty = try JSONDecoder().decode(ColorMatch.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try empty.validate())
        json = try JSONSerialization.jsonObject(with: encoder.encode(match)) as! [String: Any]
        var clusters = json["referenceClusters"] as! [[String: Any]]
        clusters[0]["stdA"] = -1
        json["referenceClusters"] = clusters
        let negative = try JSONDecoder().decode(ColorMatch.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try negative.validate())

        let initial = Adjustments()
        var edited = initial; edited.colorMatch = match
        edited.matchColorStrength = 0.62; edited.matchLuminanceStrength = 0.33; edited.matchDominance = 0.45
        let recipe = Recipe(sourceName: "photo.png", sourceSHA256: referenceHash, rawProfile: nil, adjustments: edited)
        let restored = try Recipe.decode(recipe.encoded())
        XCTAssertEqual(restored, recipe)
        XCTAssertEqual(restored.adjustments.colorMatch?.referenceName, "reference.png")
        XCTAssertEqual(restored.adjustments.matchColorStrength, 0.62)
        var history = EditHistory()
        history.record(from: initial, to: edited)
        XCTAssertEqual(history.undo(current: edited), initial)
        XCTAssertEqual(history.redo(current: initial), edited)

        let legacy = Recipe(sourceName: "old.png", sourceSHA256: referenceHash, rawProfile: nil, adjustments: initial)
        var legacyJSON = try JSONSerialization.jsonObject(with: legacy.encoded()) as! [String: Any]
        legacyJSON["version"] = 1; legacyJSON["pipeline"] = "luma-sdr-p3-v1"
        var adjustmentsJSON = legacyJSON["adjustments"] as! [String: Any]
        adjustmentsJSON.removeValue(forKey: "colorMatch")
        legacyJSON["adjustments"] = adjustmentsJSON
        let migrated = try Recipe.decode(JSONSerialization.data(withJSONObject: legacyJSON))
        XCTAssertEqual(migrated.version, Recipe.currentVersion)
        XCTAssertEqual(migrated.pipeline, "luma-sdr-p3-v2")
        XCTAssertEqual(migrated.adjustments, initial)
        legacyJSON["adjustments"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edited))
        XCTAssertThrowsError(try Recipe.decode(JSONSerialization.data(withJSONObject: legacyJSON)))
    }

    private func fixture(at url: URL, reference: Bool) throws {
        let width = 180, height = 120
        let colors: [[Double]] = reference
            ? [[0.84, 0.44, 0.32], [0.38, 0.68, 0.30], [0.40, 0.46, 0.72]]
            : [[0.60, 0.28, 0.18], [0.18, 0.52, 0.26], [0.18, 0.28, 0.60]]
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: ImageEngine.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for row in 0..<height {
            let brightness = 0.82 + 0.18 * Double(row) / Double(height - 1)
            for index in 0..<colors.count {
                let c = colors[index]
                context.setFillColor(CGColor(red: c[0] * brightness, green: c[1] * brightness,
                    blue: c[2] * brightness, alpha: 1))
                context.fill(CGRect(x: index * 60, y: row, width: 60, height: 1))
            }
        }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testMatchedBitmapPipelineAndEmbeddedRecipe() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("match-source.png")
        let reference = directory.appendingPathComponent("match-reference.png")
        try fixture(at: source, reference: false); try fixture(at: reference, reference: true)
        let sourceData = try Data(contentsOf: source), referenceData = try Data(contentsOf: reference)
        let engine = ImageEngine(), referenceEngine = ImageEngine()
        let info = try await engine.open(source), referenceInfo = try await referenceEngine.open(reference)
        let sourceAnalysis = try await engine.analyzeForMatch(info.initial, profile: nil, clusterCount: 3)
        let referenceAnalysis = try await referenceEngine.analyzeForMatch(referenceInfo.initial, profile: nil, clusterCount: 3)
        var match = try ColorMatch.make(source: sourceAnalysis, reference: referenceAnalysis,
            referenceName: reference.lastPathComponent, referenceSHA256: referenceInfo.sha256)
        match.colorStrength = 0.85; match.luminanceStrength = 0.4
        var edited = info.initial; edited.colorMatch = match
        let before = try await engine.preview(info.initial, profile: nil)
        let after = try await engine.preview(edited, profile: nil)
        XCTAssertTrue(pixelDifference(before, after) > 3)
        XCTAssertEqual(after.width, before.width); XCTAssertEqual(after.height, before.height)
        let referencePreview = try await referenceEngine.preview(referenceInfo.initial, profile: nil)
        let beforeReferenceError = pixelDifference(before, referencePreview)
        let afterReferenceError = pixelDifference(after, referencePreview)
        print("VALIDATION reference mean RGB difference before/after: \(beforeReferenceError) / \(afterReferenceError)")
        XCTAssertLessThan(afterReferenceError, beforeReferenceError)
        let reanalysis = try await engine.analyzeForMatch(edited, profile: nil, clusterCount: 3)
        XCTAssertEqual(reanalysis, sourceAnalysis) // Applying repeatedly must not analyze the previous match.
        var zeroStrength = edited
        zeroStrength.matchColorStrength = 0; zeroStrength.matchLuminanceStrength = 0
        let zeroPreview = try await engine.preview(zeroStrength, profile: nil)
        XCTAssertEqual(pixelDifference(before, zeroPreview), 0)

        // Compare the GPU shader with a separate CPU evaluation in linear P3.
        let oracle = try cpuOracle(source: source, match: match)
        let cpuError = pixelDifference(after, oracle)
        print("VALIDATION match GPU versus CPU mean RGB error: \(cpuError)")
        XCTAssertLessThan(cpuError, 1.2)
        var toneOnlyMatch = match
        toneOnlyMatch.colorStrength = 0; toneOnlyMatch.luminanceStrength = 0.8
        var toneOnlyEdit = info.initial; toneOnlyEdit.colorMatch = toneOnlyMatch
        let toneOnlyPreview = try await engine.preview(toneOnlyEdit, profile: nil)
        let toneOnlyOracle = try cpuOracle(source: source, match: toneOnlyMatch)
        let toneOnlyError = pixelDifference(toneOnlyPreview, toneOnlyOracle)
        print("VALIDATION tone-only GPU versus CPU mean RGB error: \(toneOnlyError)")
        XCTAssertLessThan(toneOnlyError, 1.2)
        XCTAssertTrue(pixelDifference(before, toneOnlyPreview) > 1)

        let recipe = Recipe(sourceName: source.lastPathComponent, sourceSHA256: info.sha256,
            rawProfile: nil, adjustments: edited)
        let recipeData = try recipe.encoded()
        try FileManager.default.removeItem(at: reference)
        let reopened = ImageEngine(), reopenedInfo = try await reopened.open(source)
        let restored = try Recipe.decode(recipeData)
        let restoredPreview = try await reopened.preview(restored.adjustments, profile: reopenedInfo.profile)
        XCTAssertEqual(pixelDifference(after, restoredPreview), 0)
        for format in ExportFormat.allCases {
            let result = directory.appendingPathComponent("matched.\(format.rawValue)")
            try await engine.export(edited, profile: nil, to: result, format: format)
            let imageSource = CGImageSourceCreateWithURL(result as CFURL, nil)!
            let decoded = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)!
            XCTAssertEqual(decoded.bitsPerComponent, format == .tiff ? 16 : 8)
            XCTAssertLessThan(pixelDifference(after, decoded), format == .tiff ? 1 : 5)
        }
        XCTAssertEqual(try Data(contentsOf: source), sourceData)
        if let samplePath = ProcessInfo.processInfo.environment["LUMA_SAMPLE_DIR"] {
            let samples = URL(fileURLWithPath: samplePath)
            try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
            try sourceData.write(to: samples.appendingPathComponent("match-source.png"))
            try referenceData.write(to: samples.appendingPathComponent("match-reference.png"))
            try recipeData.write(to: samples.appendingPathComponent("match-source.luma.json"))
            try await engine.export(edited, profile: nil, to: samples.appendingPathComponent("match-result.tiff"), format: .tiff)
        }
    }

    func testMatchedRAWPipelineIfProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUMA_RAW_FIXTURE"] else {
            print("SKIP: RAW match fixture not provided"); return
        }
        let source = URL(fileURLWithPath: path), engine = ImageEngine()
        let info = try await engine.open(source)
        let analysis = try await engine.analyzeForMatch(info.initial, profile: info.profile, clusterCount: 3)
        var identityMatch = try ColorMatch.make(source: analysis, reference: analysis,
            referenceName: source.lastPathComponent, referenceSHA256: info.sha256)
        identityMatch.colorStrength = 1; identityMatch.luminanceStrength = 0
        var identityEdit = info.initial; identityEdit.colorMatch = identityMatch
        let before = try await engine.preview(info.initial, profile: info.profile)
        let identity = try await engine.preview(identityEdit, profile: info.profile)
        XCTAssertLessThan(pixelDifference(before, identity), 1)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reference = directory.appendingPathComponent("reference.png")
        try fixture(at: reference, reference: true)
        let referenceEngine = ImageEngine(), referenceInfo = try await referenceEngine.open(reference)
        let referenceAnalysis = try await referenceEngine.analyzeForMatch(referenceInfo.initial, profile: nil, clusterCount: 3)
        var edited = info.initial
        edited.colorMatch = try ColorMatch.make(source: analysis, reference: referenceAnalysis,
            referenceName: reference.lastPathComponent, referenceSHA256: referenceInfo.sha256)
        edited.matchLuminanceStrength = 0.25
        let matched = try await engine.preview(edited, profile: info.profile)
        XCTAssertTrue(pixelDifference(before, matched) > 1)
        let recipe = Recipe(sourceName: source.lastPathComponent, sourceSHA256: info.sha256,
            rawProfile: info.profile, adjustments: edited)
        let restored = try Recipe.decode(recipe.encoded())
        let again = try await engine.preview(restored.adjustments, profile: restored.rawProfile)
        XCTAssertEqual(pixelDifference(matched, again), 0)
        let target = directory.appendingPathComponent("matched-raw.tiff")
        try await engine.export(edited, profile: info.profile, to: target, format: .tiff)
        let decodedSource = CGImageSourceCreateWithURL(target as CFURL, nil)!
        let decoded = CGImageSourceCreateImageAtIndex(decodedSource, 0, nil)!
        XCTAssertEqual(decoded.bitsPerComponent, 16)
        XCTAssertLessThan(pixelDifference(matched, decoded), 1)
        print("PASS RAW reference match: \(info.profile!.decoderVersion)")
    }

    func testCustomCropAndLegacyRecipeMigration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("crop.png")
        try fixture(at: source, reference: false)
        let engine = ImageEngine(), info = try await engine.open(source)
        var edited = info.initial
        edited.cropRect = CropRect(x: 0.25, y: 0.125, width: 0.5, height: 0.75)
        try edited.cropRect.validate()
        let cropped = try await engine.preview(edited, profile: nil)
        XCTAssertEqual(cropped.width, 90)
        XCTAssertEqual(cropped.height, 90)

        let recipe = Recipe(sourceName: source.lastPathComponent, sourceSHA256: info.sha256,
                            rawProfile: nil, adjustments: edited)
        let roundTrip = try Recipe.decode(recipe.encoded())
        XCTAssertEqual(roundTrip.adjustments.cropRect, edited.cropRect)
        // A v1 JSON without cropRect is interpreted as the old symmetric trim.
        var legacyJSON = try JSONSerialization.jsonObject(with: recipe.encoded()) as! [String: Any]
        legacyJSON["version"] = 1; legacyJSON["pipeline"] = "luma-sdr-p3-v1"
        var adjustmentsJSON = legacyJSON["adjustments"] as! [String: Any]
        adjustmentsJSON.removeValue(forKey: "cropRect")
        adjustmentsJSON["horizontalTrim"] = 0.1; adjustmentsJSON["verticalTrim"] = 0.2
        legacyJSON["adjustments"] = adjustmentsJSON
        let migrated = try Recipe.decode(JSONSerialization.data(withJSONObject: legacyJSON))
        XCTAssertEqual(migrated.adjustments.cropRect, CropRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6))
        let migratedImage = try await engine.preview(migrated.adjustments, profile: nil)
        XCTAssertEqual(migratedImage.width, 144)
        XCTAssertEqual(migratedImage.height, 72)
    }

    private func cpuOracle(source: URL, match: ColorMatch) throws -> CGImage {
        let image = CIImage(contentsOf: source, options: [.applyOrientationProperty: true])!
        let width = Int(image.extent.width), height = Int(image.extent.height)
        let context = CIContext(options: [.workingColorSpace: ImageEngine.workingSpace, .workingFormat: CIFormat.RGBAh])
        var floats = [Float](repeating: 0, count: width * height * 4)
        floats.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: width * 16,
                bounds: image.extent, format: .RGBAf, colorSpace: ImageEngine.workingSpace)
        }
        for index in stride(from: 0, to: floats.count, by: 4) {
            let lab = LabColor.fromLinearP3([Double(floats[index]), Double(floats[index + 1]), Double(floats[index + 2])])
            let rgb = match.mapped(lab).linearP3
            floats[index] = Float(rgb[0]); floats[index + 1] = Float(rgb[1]); floats[index + 2] = Float(rgb[2])
        }
        let data = floats.withUnsafeBytes { Data($0) }
        let result = CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: height),
            format: .RGBAf, colorSpace: ImageEngine.workingSpace)
        guard let output = context.createCGImage(result, from: result.extent, format: .RGBA8,
            colorSpace: ImageEngine.outputSpace) else { throw EditorError.message("CPU oracle failed") }
        return output
    }

    private func pixelDifference(_ lhs: CGImage, _ rhs: CGImage) -> Double {
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return .infinity }
        func bytes(_ image: CGImage) -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            pixels.withUnsafeMutableBytes { raw in
                let context = CGContext(data: raw.baseAddress!, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: ImageEngine.outputSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return pixels
        }
        let a = bytes(lhs), b = bytes(rhs)
        var difference = 0.0
        for index in stride(from: 0, to: a.count, by: 4) {
            for channel in 0..<3 { difference += Double(abs(Int(a[index + channel]) - Int(b[index + channel]))) }
        }
        return difference / Double(lhs.width * lhs.height * 3)
    }
}
