#if !STANDALONE_CHECK
import XCTest
#endif
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import LumaCore

final class LumaCoreTests: XCTestCase {
    func testRecipeRoundTripAndRejection() throws {
        var settings = Adjustments(); settings.exposure = -1.75; settings.quarterTurns = 3
        let recipe = Recipe(sourceName: "test.dng", sourceSHA256: String(repeating: "a", count: 64), rawProfile: nil, adjustments: settings)
        XCTAssertEqual(try Recipe.decode(recipe.encoded()), recipe)
        var bad = recipe; bad.version = 99
        XCTAssertThrowsError(try bad.encoded())
        bad = recipe; bad.adjustments.horizontalTrim = 0.9
        XCTAssertThrowsError(try bad.encoded())
        bad = recipe; bad.adjustments.exposure = .nan
        XCTAssertThrowsError(try bad.encoded())
        bad = recipe; bad.rawProfile = RAWProfile(decoderVersion: "8", values: ["maliciousKey": 1], lensCorrection: false)
        XCTAssertThrowsError(try bad.encoded())
        XCTAssertThrowsError(try Recipe.decode(Data("{}".utf8)))
    }
    func testHistoryBranchingAndBound() {
        var history = EditHistory(), state = Adjustments()
        let initial = state
        state.exposure = 1; history.record(from: initial, to: state)
        XCTAssertEqual(history.undo(current: state), initial)
        XCTAssertEqual(history.redo(current: initial), state)
        _ = history.undo(current: state)
        var branch = initial; branch.saturation = 0
        history.record(from: initial, to: branch)
        XCTAssertNil(history.redo(current: branch))
        for index in 0...150 { let old = state; state.exposure = Double(index); history.record(from: old, to: state) }
        XCTAssertEqual(history.undoStack.count, 100)
    }
    func testLocalMaskRecipeValidationAndLegacyDefaults() throws {
        let id = UUID()
        let mask = LocalMask(id: id, kind: .radial, x: 0.1, y: 0.2, width: 0.6, height: 0.5,
                             angle: 12, exposure: 1.5, temperatureDelta: 700,
                             tintDelta: -8, saturation: 0.8, opacity: 0.75,
                             feather: 0.4, inverted: true, enabled: false)
        var adjustments = Adjustments(); adjustments.localMasks = [mask]
        let recipe = Recipe(sourceName: "mask.jpg", sourceSHA256: String(repeating: "c", count: 64),
                            rawProfile: nil, adjustments: adjustments)
        let restored = try Recipe.decode(recipe.encoded())
        XCTAssertEqual(restored.adjustments.localMasks, [mask])

        // A recipe written before local masks existed still decodes to an empty list.
        let oldJSON = """
        {"version":2,"pipeline":"luma-sdr-p3-v2","sourceName":"old.jpg",
         "sourceSHA256":"\(String(repeating: "d", count: 64))","adjustments":{}}
        """
        let old = try Recipe.decode(Data(oldJSON.utf8))
        XCTAssertTrue(old.adjustments.localMasks.isEmpty)

        var invalid = mask; invalid.width = 0.01
        var bad = adjustments; bad.localMasks = [invalid]
        XCTAssertThrowsError(try bad.validate())
    }
    private func fixture(at url: URL) throws {
        let ctx = CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                            space: ImageEngine.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.35, blue: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        ctx.setFillColor(CGColor(red: 0.85, green: 0.1, blue: 0.05, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 28, height: 17))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let props: [String: Any] = [kCGImagePropertyOrientation as String: 6,
            kCGImageDestinationLossyCompressionQuality as String: 1,
            kCGImagePropertyTIFFDictionary as String: ["Model": "Luma Test Camera", "Artist": "Luma Test"],
            kCGImagePropertyExifDictionary as String: ["DateTimeOriginal": "2026:10:09 10:20:30", "ExposureTime": 0.01],
            kCGImagePropertyIPTCDictionary as String: ["Keywords": ["luma", "integration"]],
            kCGImagePropertyGPSDictionary as String: ["Latitude": 22.5, "LatitudeRef": "N", "Longitude": 114.0, "LongitudeRef": "E"]]
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
    func testPipelineOrientationMetadataAndOriginalProtection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("oriented.jpg")
        try fixture(at: source)
        let sourceData = try Data(contentsOf: source)
        let engine = ImageEngine(), info = try await engine.open(source)
        print("VALIDATION backend: \(info.backend)")
        XCTAssertFalse(info.isRAW); XCTAssertEqual(info.width, 40); XCTAssertEqual(info.height, 80)
        let original = try await engine.preview(info.initial, profile: nil)
        XCTAssertEqual(original.width, 40); XCTAssertEqual(original.height, 80)
        // Pixel-level orientation oracle: compare to ImageIO's oriented thumbnail.
        let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil)!
        let oracle = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 80] as CFDictionary)!
        XCTAssertLessThan(pixelDifference(original, oracle), 3)
        var edit = info.initial; edit.exposure = -0.5; edit.saturation = 0.5
        edit.shadows = 0.18; edit.quarterTurns = 1; edit.horizontalTrim = 0.1; edit.verticalTrim = 0.1
        let preview = try await engine.preview(edit, profile: nil)
        XCTAssertEqual(preview.width, 64); XCTAssertEqual(preview.height, 32)
        let recipe = Recipe(sourceName: source.lastPathComponent, sourceSHA256: info.sha256, rawProfile: nil, adjustments: edit)
        let restored = try Recipe.decode(recipe.encoded())
        let restoredPreview = try await engine.preview(restored.adjustments, profile: restored.rawProfile)
        XCTAssertEqual(pixelDifference(preview, restoredPreview), 0)
        for format in ExportFormat.allCases {
            let target = directory.appendingPathComponent("result.\(format.rawValue)")
            try await engine.export(edit, profile: nil, to: target, format: format)
            let output = CGImageSourceCreateWithURL(target as CFURL, nil)!
            let image = CGImageSourceCreateImageAtIndex(output, 0, nil)!
            let props = CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as! [String: Any]
            XCTAssertEqual(image.width, 64); XCTAssertEqual(image.height, 32)
            XCTAssertEqual(image.bitsPerComponent, format == .tiff ? 16 : 8)
            XCTAssertEqual((props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue, 1)
            XCTAssertNotNil(image.colorSpace?.copyICCData())
            XCTAssertNil(props[kCGImagePropertyGPSDictionary as String])
            let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
            XCTAssertEqual(exif?["DateTimeOriginal"] as? String, "2026:10:09 10:20:30")
            let iptc = props[kCGImagePropertyIPTCDictionary as String] as? [String: Any]
            XCTAssertEqual(iptc?["Keywords"] as? [String], ["luma", "integration"])
            XCTAssertLessThan(pixelDifference(preview, image), format == .jpeg ? 8 : 1)
        }
        let gpsTarget = directory.appendingPathComponent("gps.jpg")
        try await engine.export(edit, profile: nil, to: gpsTarget, format: .jpeg, includeGPS: true)
        let gpsSource = CGImageSourceCreateWithURL(gpsTarget as CFURL, nil)!
        let gpsProps = CGImageSourceCopyPropertiesAtIndex(gpsSource, 0, nil) as! [String: Any]
        XCTAssertNotNil(gpsProps[kCGImagePropertyGPSDictionary as String])
        do { try await engine.export(edit, profile: nil, to: source, format: .jpeg); XCTFail("Original overwrite accepted") } catch { }
        let link = directory.appendingPathComponent("alias.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try ImageEngine.protectOriginal(destination: link, original: source))
        XCTAssertEqual(try Data(contentsOf: source), sourceData)
        // Failed import must preserve the prior document.
        do { _ = try await engine.open(directory.appendingPathComponent("missing.jpg")); XCTFail("Invalid import accepted") } catch { }
        let afterFailure = try await engine.preview(edit, profile: nil)
        XCTAssertEqual(pixelDifference(preview, afterFailure), 0)
        if let samplePath = ProcessInfo.processInfo.environment["LUMA_SAMPLE_DIR"] {
            let samples = URL(fileURLWithPath: samplePath)
            try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
            try sourceData.write(to: samples.appendingPathComponent("orientation-test.jpg"))
            try recipe.encoded().write(to: samples.appendingPathComponent("orientation-test.luma.json"))
            try await engine.export(edit, profile: nil, to: samples.appendingPathComponent("expected-edited.tiff"), format: .tiff)
        }
    }

    func testLocalMaskChangesOnlyMaskedRenderAndCanBeDisabled() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("mask.jpg")
        try fixture(at: source)
        let engine = ImageEngine(), info = try await engine.open(source)
        let base = try await engine.preview(info.initial, profile: nil, maxDimension: 80)
        var edit = info.initial
        edit.localMasks = [LocalMask(kind: .radial, x: 0, y: 0, width: 0.5, height: 1,
                                     exposure: 1.5, feather: 0.2)]
        let masked = try await engine.preview(edit, profile: nil, maxDimension: 80)
        XCTAssertTrue(pixelDifference(base, masked) > 0.5)
        var disabled = edit; disabled.localMasks[0].enabled = false
        let disabledImage = try await engine.preview(disabled, profile: nil, maxDimension: 80)
        XCTAssertLessThan(pixelDifference(base, disabledImage), 0.1)
        let recipe = Recipe(sourceName: source.lastPathComponent, sourceSHA256: info.sha256,
                            rawProfile: nil, adjustments: edit)
        let restored = try Recipe.decode(recipe.encoded())
        let replay = try await engine.preview(restored.adjustments, profile: nil, maxDimension: 80)
        XCTAssertLessThan(pixelDifference(masked, replay), 0.1)
    }
    func testRAWFixtureIfProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUMA_RAW_FIXTURE"] else {
            print("SKIP: RAW fixture not provided"); return
        }
        let source = URL(fileURLWithPath: path), engine = ImageEngine()
        let info = try await engine.open(source)
        XCTAssertTrue(info.isRAW); XCTAssertNotNil(info.profile)
        let original = try await engine.preview(info.initial, profile: info.profile)
        var edit = info.initial; edit.exposure = -1; edit.temperature = 5200; edit.tint = 12
        let edited = try await engine.preview(edit, profile: info.profile)
        XCTAssertTrue(pixelDifference(original, edited) > 1)
        let recipe = Recipe(sourceName: source.lastPathComponent, sourceSHA256: info.sha256, rawProfile: info.profile, adjustments: edit)
        let restored = try Recipe.decode(recipe.encoded())
        let again = try await engine.preview(restored.adjustments, profile: restored.rawProfile)
        XCTAssertEqual(pixelDifference(edited, again), 0)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tiff")
        defer { try? FileManager.default.removeItem(at: target) }
        try await engine.export(edit, profile: info.profile, to: target, format: .tiff)
        let decoded = CGImageSourceCreateWithURL(target as CFURL, nil)!
        let cg = CGImageSourceCreateImageAtIndex(decoded, 0, nil)!
        XCTAssertEqual(cg.bitsPerComponent, 16)
        XCTAssertLessThan(pixelDifference(edited, cg), 1)
        let thumbnail = await engine.embeddedThumbnail()
        XCTAssertNotNil(thumbnail)
        print("PASS RAW: \(source.lastPathComponent), decoder \(info.profile!.decoderVersion), \(info.width)×\(info.height)")
    }
    private func pixelDifference(_ a: CGImage, _ b: CGImage) -> Double {
        guard a.width == b.width, a.height == b.height else { return .infinity }
        func bytes(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            bytes.withUnsafeMutableBytes { raw in
                let ctx = CGContext(data: raw.baseAddress!, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: ImageEngine.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return bytes
        }
        let lhs = bytes(a), rhs = bytes(b)
        return zip(lhs, rhs).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / Double(lhs.count)
    }
}
