#if !STANDALONE_CHECK
import XCTest
#endif
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import LumaCore

final class OutputDiagnosticsTests: XCTestCase {
    private func image(_ bytes: [UInt8], width: Int, height: Int, rowBytes: Int? = nil,
                       space: CGColorSpace = ImageEngine.outputSpace,
                       layout: UInt32 = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) -> CGImage {
        CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: rowBytes ?? width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: layout),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    private func write(_ image: CGImage, to url: URL) throws {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    private func decoded(_ url: URL) -> CGImage {
        CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
    }
    private func bytes(_ image: CGImage) -> [UInt8] { Array(image.dataProvider!.data! as Data) }

    func testKnownBinsEndpointsAlphaAndLayouts() throws {
        let pixels: [UInt8] = [0,0,0,255, 255,255,255,255, 255,32,32,255, 1,1,1,255,
                               254,254,254,255, 128,128,128,128, 0,0,0,0, 0,128,0,255]
        let source = image(pixels, width: 4, height: 2)
        let histogram = try OutputDiagnostics.histogram(source)
        XCTAssertEqual(histogram.sampleCount, 8)
        XCTAssertEqual(histogram.highlights, 2); XCTAssertEqual(histogram.shadows, 2)
        XCTAssertEqual(histogram.highlightFraction, 0.25); XCTAssertEqual(histogram.shadowFraction, 0.25)
        XCTAssertEqual(histogram.red[255], 2); XCTAssertEqual(histogram.red[0], 3)
        for bins in [histogram.red, histogram.green, histogram.blue, histogram.luma] {
            XCTAssertEqual(bins.count, 256); XCTAssertEqual(bins.reduce(0, +), 8)
        }
        XCTAssertEqual(histogram.luma[79], 1); XCTAssertEqual(histogram.luma[92], 1)
        XCTAssertEqual(histogram.luma[128], 1)
        for options in [ClippingOptions(), .highlights, .shadows, .all] {
            let overlay = try OutputDiagnostics.clippingOverlay(source, options: options)
            if options.isEmpty { XCTAssertNil(overlay); continue }
            XCTAssertEqual(overlay!.width, 4); XCTAssertEqual(overlay!.height, 2)
            let output = bytes(overlay!)
            for index in 0..<8 {
                let high = options.contains(.highlights) && [1, 2].contains(index)
                let low = options.contains(.shadows) && [0, 6].contains(index)
                XCTAssertEqual(Array(output[index * 4..<index * 4 + 4]), high ? [255,0,0,255] : low ? [0,0,255,255] : [0,0,0,0])
            }
        }
        let straight = image([255,255,255,128], width: 1, height: 1, layout: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.last.rawValue)
        let alpha = try OutputDiagnostics.histogram(straight)
        XCTAssertEqual(alpha.highlights, 0); XCTAssertEqual(alpha.shadows, 0)
        XCTAssertEqual(alpha.red[128], 1)
        let bgra = image([0,0,255,255, 0,0,0,255, 255,255,255,255], width: 2, height: 1, rowBytes: 12,
            layout: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        let padded = try OutputDiagnostics.histogram(bgra)
        XCTAssertEqual(padded.sampleCount, 2); XCTAssertEqual(padded.highlights, 1); XCTAssertEqual(padded.shadows, 1)
        let p3 = image([128,128,128,255], width: 1, height: 1, space: CGColorSpace(name: CGColorSpace.displayP3)!)
        let managed = try OutputDiagnostics.histogram(p3)
        XCTAssertEqual(managed.highlights, 0); XCTAssertEqual(managed.shadows, 0)
        XCTAssertEqual(managed.red[128], 1)
    }

    func testSamplingBoundsCropAlignmentAndCancellation() async throws {
        let wide = image(Array(repeating: [UInt8(128),128,128,255], count: 1600 * 20).flatMap { $0 }, width: 1600, height: 20)
        let histogram = try OutputDiagnostics.histogram(wide)
        XCTAssertEqual(histogram.sampleWidth, 512); XCTAssertEqual(histogram.sampleHeight, 6)
        XCTAssertEqual(histogram.red[128], 3072)
        XCTAssertEqual(histogram.previewWidth, 1600); XCTAssertEqual(histogram.previewHeight, 20)
        let crop = CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let left = OutputDiagnostics.overlayRegion(crop: crop, fullSize: CGSize(width: 100, height: 80), sourceRect: CGRect(x: 0, y: 0, width: 50, height: 40))
        XCTAssertEqual(left, CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        let outside = OutputDiagnostics.overlayRegion(crop: crop, fullSize: CGSize(width: 100, height: 80), sourceRect: CGRect(x: 75, y: 0, width: 25, height: 80))
        XCTAssertEqual(outside, .zero)
        let odd = OutputDiagnostics.overlayRegion(crop: crop, fullSize: CGSize(width: 100, height: 81), sourceRect: CGRect(x: 0, y: 0, width: 100, height: 81))
        XCTAssertEqual(odd.minY, 21.0 / 81); XCTAssertEqual(odd.height, 40.0 / 81)
        XCTAssertEqual(OutputDiagnostics.overlayRegion(crop: crop, fullSize: CGSize(width: CGFloat.infinity, height: 81), sourceRect: .zero), .zero)
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try OutputDiagnostics.histogram(wide) }
        do { _ = try await task.value; XCTFail("Cancelled histogram completed") } catch is CancellationError { }
        let overlayTask = Task { withUnsafeCurrentTask { $0?.cancel() }; return try OutputDiagnostics.clippingOverlay(wide, options: .all) }
        do { _ = try await overlayTask.value; XCTFail("Cancelled overlay completed") } catch is CancellationError { }
    }

    func testFinalCropPipelineAndRAW() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var pixels: [UInt8] = []
        for y in 0..<48 { for x in 0..<64 {
            let value: [UInt8] = x < 16 ? [0,0,0,255] : x < 32 ? [255,255,255,255] : y < 24 ? [80,160,100,255] : [0,0,0,0]
            pixels.append(contentsOf: value)
        } }
        let url = directory.appendingPathComponent("patches.png")
        try write(image(pixels, width: 64, height: 48), to: url)
        let engine = ImageEngine(), info = try await engine.open(url)
        let full = try await engine.histogram(info.initial, profile: nil)
        XCTAssertEqual(full.highlights, 16 * 48); XCTAssertEqual(full.shadows, 16 * 48 + 32 * 24)
        var crop = info.initial; crop.cropRect = CropRect(x: 0.25, y: 0, width: 0.25, height: 1)
        let white = try await engine.histogram(crop, profile: nil)
        XCTAssertEqual(white.highlightFraction, 1); XCTAssertEqual(white.shadows, 0)
        _ = try await engine.preview(info.initial, profile: nil, maxDimension: 20)
        let reused = try await engine.histogram(crop, profile: nil)
        XCTAssertEqual(reused, white)
        let basePreview = try await engine.preview(info.initial, profile: nil)
        XCTAssertEqual(try OutputDiagnostics.histogram(basePreview), full)
        let native = try await engine.detailTile(info.initial, profile: nil, tile: DetailTileID(x: 0, y: 0))
        XCTAssertEqual(try OutputDiagnostics.histogram(native.image), full)

        var edited = info.initial; edited.exposure = 0.8; edited.quarterTurns = 1
        edited.cropRect = CropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.7)
        edited.localMasks = [LocalMask(exposure: -2, feather: 0.7), LocalMask(kind: .linear, angle: 32, exposure: 1.3)]
        let refURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Samples/match-reference.png")
        let reference = ImageEngine(), refInfo = try await reference.open(refURL)
        let a = try await engine.analyzeForMatch(edited, profile: nil, clusterCount: 3)
        let b = try await reference.analyzeForMatch(refInfo.initial, profile: nil, clusterCount: 3)
        edited.colorMatch = try ColorMatch.make(source: a, reference: b, referenceName: "reference", referenceSHA256: refInfo.sha256)
        try await compareExport(engine, settings: edited, profile: nil, directory: directory)
        let transparentExport = directory.appendingPathComponent("alpha.tiff")
        try await engine.export(info.initial, profile: nil, to: transparentExport, format: .tiff)
        let transparentStats = try OutputDiagnostics.histogram(decoded(transparentExport))
        XCTAssertEqual(transparentStats.highlights, full.highlights); XCTAssertEqual(transparentStats.shadows, full.shadows)
        _ = try await engine.open(refURL)
        let reset = try await engine.histogram(info.initial, profile: nil)
        XCTAssertEqual(reset.previewWidth, refInfo.width)
        if let path = ProcessInfo.processInfo.environment["LUMA_RAW_FIXTURE"] {
            let raw = ImageEngine(), rawInfo = try await raw.open(URL(fileURLWithPath: path))
            var state = rawInfo.initial; state.exposure = 1.5; state.quarterTurns = 1
            state.cropRect = CropRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5)
            state.localMasks = [LocalMask(exposure: -2, feather: 0.6)]
            try await compareExport(raw, settings: state, profile: rawInfo.profile, directory: directory)
        } else { print("SKIP: RAW histogram fixture not provided") }
    }
    private func compareExport(_ engine: ImageEngine, settings: Adjustments, profile: RAWProfile?, directory: URL) async throws {
        let stats = try await engine.histogram(settings, profile: profile)
        let destination = directory.appendingPathComponent("edited.tiff")
        try await engine.export(settings, profile: profile, to: destination, format: .tiff)
        let expected = try OutputDiagnostics.histogram(decoded(destination))
        XCTAssertEqual(stats.sampleCount, expected.sampleCount)
        for (lhs, rhs) in zip([stats.red, stats.green, stats.blue], [expected.red, expected.green, expected.blue]) {
            let difference = abs(zip(lhs, rhs).enumerated().reduce(0.0) { $0 + Double($1.offset * ($1.element.0 - $1.element.1)) }) / Double(stats.sampleCount)
            XCTAssertLessThan(difference, 1)
        }
        XCTAssertLessThan(abs(stats.highlightFraction - expected.highlightFraction), 0.02)
        XCTAssertLessThan(abs(stats.shadowFraction - expected.shadowFraction), 0.02)
    }
}
