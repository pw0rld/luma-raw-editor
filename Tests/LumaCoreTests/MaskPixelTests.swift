#if !STANDALONE_CHECK
import XCTest
#endif
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import LumaCore

final class MaskPixelTests: XCTestCase {
    private func fixture(_ url: URL, width: Int = 160, height: Int = 120) throws {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: ImageEngine.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.25, green: 0.25, blue: 0.25, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let sample = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))!
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress!, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: ImageEngine.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
    private func linear(_ byte: UInt8) -> Double {
        let value = Double(byte) / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    func testLocalCoverageAndLinearOpacity() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("gray.png"); try fixture(source)
        let engine = ImageEngine(), info = try await engine.open(source)
        let base = try await engine.preview(info.initial, profile: nil)
        var fullSettings = info.initial; fullSettings.exposure = 1
        let full = try await engine.preview(fullSettings, profile: nil)
        var settings = info.initial
        settings.localMasks = [LocalMask(x: 0.25, y: 0.25, width: 0.5, height: 0.5, exposure: 1, feather: 0.2)]
        let masked = try await engine.preview(settings, profile: nil)
        XCTAssertEqual(pixel(masked, x: 5, y: 5), pixel(base, x: 5, y: 5))
        XCTAssertTrue(pixel(masked, x: 80, y: 60)[0] > pixel(base, x: 80, y: 60)[0])
        for strength in [0.0, 0.25, 0.5, 1.0] {
            settings.localMasks[0].opacity = strength
            let output = try await engine.preview(settings, profile: nil)
            let low = linear(pixel(base, x: 80, y: 60)[0]), high = linear(pixel(full, x: 80, y: 60)[0])
            let fraction = (linear(pixel(output, x: 80, y: 60)[0]) - low) / (high - low)
            XCTAssertLessThan(abs(fraction - strength), 0.06)
        }
        settings.localMasks[0].opacity = 1; settings.localMasks[0].inverted = true
        let inverted = try await engine.preview(settings, profile: nil)
        XCTAssertEqual(pixel(inverted, x: 80, y: 60), pixel(base, x: 80, y: 60))
        XCTAssertTrue(pixel(inverted, x: 5, y: 5)[0] > pixel(base, x: 5, y: 5)[0])
        settings.localMasks[0].inverted = false; settings.localMasks[0].feather = 0
        let hard = try await engine.preview(settings, profile: nil)
        settings.localMasks[0].feather = 1
        let soft = try await engine.preview(settings, profile: nil)
        XCTAssertTrue(pixel(hard, x: 115, y: 60)[0] > pixel(soft, x: 115, y: 60)[0])
    }
    func testLinearRotationOverlayAndExport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("linear.png"); try fixture(source)
        let engine = ImageEngine(), info = try await engine.open(source)
        var settings = info.initial
        settings.localMasks = [LocalMask(kind: .linear, x: 0.1, y: 0.1, width: 0.8, height: 0.8, exposure: 1, feather: 0)]
        let first = try await engine.preview(settings, profile: nil)
        XCTAssertTrue(pixel(first, x: 20, y: 60)[0] > pixel(first, x: 135, y: 60)[0])
        settings.quarterTurns = 1; settings.localMasks = settings.localMasks.map(\.rotatedClockwise)
        let rotated = try await engine.preview(settings, profile: nil)
        // A clockwise turn maps top-left pixel (x,y) to (H-1-y,x).
        for (x, y) in [(20, 60), (135, 60), (5, 5)] {
            let a = pixel(first, x: x, y: y), b = pixel(rotated, x: 119 - y, y: x)
            XCTAssertLessThan(abs(Int(a[0]) - Int(b[0])), 2)
        }
        let overlay = try await engine.previewMask(settings.localMasks[0], width: rotated.width, height: rotated.height)
        XCTAssertEqual(pixel(overlay, x: 5, y: 5)[3], 0)
        XCTAssertTrue(pixel(overlay, x: 60, y: 80)[3] > 0)
        let destination = folder.appendingPathComponent("result.tiff")
        try await engine.export(settings, profile: nil, to: destination, format: .tiff)
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(destination as CFURL, nil)!, 0, nil)!
        XCTAssertEqual(image.width, rotated.width); XCTAssertEqual(image.height, rotated.height)
        XCTAssertLessThan(abs(Int(pixel(image, x: 60, y: 20)[0]) - Int(pixel(rotated, x: 60, y: 20)[0])), 2)
        settings.localMasks[0].angle = 37
        let angled = try await engine.preview(settings, profile: nil)
        var fullSettings = info.initial; fullSettings.quarterTurns = 1; fullSettings.exposure = 1
        let full = try await engine.preview(fullSettings, profile: nil)
        let geometry = MaskGeometry(settings.localMasks[0], imageSize: CGSize(width: angled.width, height: angled.height))
        for (x, y) in [(60, 45), (60, 115)] {
            let low = linear(pixel(first, x: 5, y: 5)[0]), high = linear(pixel(full, x: x, y: y)[0])
            let fraction = (linear(pixel(angled, x: x, y: y)[0]) - low) / (high - low)
            XCTAssertLessThan(abs(fraction - geometry.unblurredWeight(at: CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5))), 0.06)
        }
        settings.localMasks[0].feather = 1
        let feathered = try await engine.preview(settings, profile: nil)
        XCTAssertEqual(feathered.width, rotated.width)
        XCTAssertTrue(pixel(feathered, x: 8, y: 80)[0] > pixel(angled, x: 8, y: 80)[0])
    }
    func testTightCropRetainsEnoughAnalysisSamples() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("tight.png"); try fixture(source, width: 1000, height: 1000)
        let engine = ImageEngine(), info = try await engine.open(source)
        var settings = info.initial; settings.cropRect = CropRect(x: 0.4, y: 0.4, width: 0.02, height: 0.02)
        let analysis = try await engine.analyzeForMatch(settings, profile: nil, clusterCount: 3)
        XCTAssertTrue(analysis.lightnessSamples.count >= 32)
    }
    func testRAWMaskExportIfProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUMA_RAW_FIXTURE"] else { return }
        let engine = ImageEngine(), info = try await engine.open(URL(fileURLWithPath: path))
        let base = try await engine.preview(info.initial, profile: info.profile)
        var settings = info.initial
        settings.localMasks = [LocalMask(exposure: -1, feather: 0.2)]
        let edited = try await engine.preview(settings, profile: info.profile)
        let x = edited.width / 2, y = edited.height / 2
        XCTAssertTrue(pixel(edited, x: x, y: y)[0] < pixel(base, x: x, y: y)[0])
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tiff")
        defer { try? FileManager.default.removeItem(at: target) }
        try await engine.export(settings, profile: info.profile, to: target, format: .tiff)
        let exported = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(target as CFURL, nil)!, 0, nil)!
        XCTAssertLessThan(abs(Int(pixel(exported, x: x, y: y)[0]) - Int(pixel(edited, x: x, y: y)[0])), 2)
    }
}
