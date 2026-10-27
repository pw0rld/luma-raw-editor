#if !STANDALONE_CHECK
import XCTest
#endif
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import LumaCore

final class DetailPreviewTests: XCTestCase {
    private func pattern(_ url: URL) throws {
        let width = 3073, height = 2051
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: ImageEngine.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0..<width {
            context.setFillColor(CGColor(red: x % 2 == 0 ? 0.1 : 0.9, green: CGFloat(x % 256) / 255, blue: x % 2 == 0 ? 0.8 : 0.2, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.3, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 137, width: width, height: 319))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    private func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress!, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: ImageEngine.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
    private func error(_ a: CGImage, _ b: CGImage) -> Double {
        guard a.width == b.width, a.height == b.height else { return .infinity }
        let lhs = rgba(a), rhs = rgba(b)
        return zip(lhs, rhs).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(lhs.count)
    }
    private func decoded(_ url: URL) -> CGImage {
        CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
    }

    func testNativeTilesMatchExportAndPreserveFineDetail() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("pattern.png"); try pattern(source)
        print("DETAIL: patterned RGB fixture created")
        let engine = ImageEngine(detailCacheLimit: 6 * 1024 * 1024), info = try await engine.open(source)
        var settings = info.initial
        settings.exposure = -0.4; settings.saturation = 0.8
        settings.quarterTurns = 1; settings.cropRect = CropRect(x: 0.07, y: 0.11, width: 0.86, height: 0.78)
        settings.localMasks = [LocalMask(x: 0.1, y: 0.15, width: 0.7, height: 0.65, exposure: 1, feather: 0.9),
            LocalMask(kind: .linear, x: 0.15, y: 0.2, width: 0.6, height: 0.5, angle: 37, temperatureDelta: 800, opacity: 0.4, feather: 0.6)]
        let reference = ImageEngine()
        let refURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Samples/match-reference.png")
        let refInfo = try await reference.open(refURL)
        let a = try await engine.analyzeForMatch(settings, profile: nil, clusterCount: 3)
        let b = try await reference.analyzeForMatch(refInfo.initial, profile: nil, clusterCount: 3)
        settings.colorMatch = try ColorMatch.make(source: a, reference: b, referenceName: "reference", referenceSHA256: refInfo.sha256)
        print("DETAIL: analysis and complex recipe ready")
        let output = folder.appendingPathComponent("export.tiff")
        try await engine.export(settings, profile: nil, to: output, format: .tiff)
        let full = decoded(output)
        print("DETAIL: full TIFF rendered \(full.width)x\(full.height)")
        XCTAssertEqual(info.outputSize(for: settings), CGSize(width: full.width, height: full.height))
        var measured = 0.0
        for id in [DetailTileID(x: 0, y: 0), DetailTileID(x: 1, y: 0), DetailTileID(x: 0, y: 1), DetailTileID(x: 1, y: 2)] {
            print("DETAIL: tile \(id.x),\(id.y)")
            let tile = try await engine.detailTile(settings, profile: nil, tile: id)
            let expected = full.cropping(to: tile.sourceRect)!
            let difference = error(tile.image, expected)
            measured = max(measured, difference)
            XCTAssertLessThan(difference, 1)
            XCTAssertEqual(tile.fullSize, CGSize(width: full.width, height: full.height))
        }
        print("VALIDATION native detail versus 16-bit TIFF mean byte error: \(measured)")
        let id = DetailTileID(x: 0, y: 0)
        let first = try await engine.detailTile(settings, profile: nil, tile: id)
        let cached = try await engine.detailTile(settings, profile: nil, tile: id)
        XCTAssertTrue(first.image === cached.image)
        _ = try await engine.preview(info.initial, profile: nil, maxDimension: 123)
        let interleaved = try await engine.detailTile(settings, profile: nil, tile: id)
        XCTAssertEqual(error(first.image, interleaved.image), 0)
        let changedID = DetailTileID(x: 1, y: 0)
        _ = try await engine.detailTile(settings, profile: nil, tile: changedID)
        let usage = await engine.detailCacheUsage()
        XCTAssertTrue(usage.bytes <= 6 * 1024 * 1024 && usage.tiles == 1)
        let evicted = try await engine.detailTile(settings, profile: nil, tile: id)
        XCTAssertFalse(first.image === evicted.image)
        var changed = settings; changed.exposure = 0.8
        let different = try await engine.detailTile(changed, profile: nil, tile: id)
        XCTAssertTrue(error(first.image, different.image) > 1)
        // A native tile must preserve the one-pixel stripe pattern, not the 1800px preview.
        let native = try await engine.detailTile(info.initial, profile: nil, tile: id)
        let pixels = rgba(native.image)
        XCTAssertTrue(abs(Int(pixels[0]) - Int(pixels[4])) > 100)
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await engine.detailTile(settings, profile: nil, tile: id) }
        do { _ = try await task.value; XCTFail("Cancelled detail task completed") } catch is CancellationError { }
    }

    func testSampledTileEdgesAndRAWDetail() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("pattern.png"); try pattern(source)
        let engine = ImageEngine(), info = try await engine.open(source)
        for id in [DetailTileID(divisor: 2, x: 0, y: 0), DetailTileID(divisor: 2, x: 1, y: 1), DetailTileID(divisor: 4, x: 0, y: 0)] {
            let tile = try await engine.detailTile(info.initial, profile: nil, tile: id)
            XCTAssertTrue(tile.image.width <= 1028 && tile.image.height <= 1028)
            XCTAssertEqual(tile.sourceRect.width, CGFloat(tile.image.width * id.divisor))
        }
        let left = try await engine.detailTile(info.initial, profile: nil, tile: DetailTileID(divisor: 2, x: 0, y: 0))
        let right = try await engine.detailTile(info.initial, profile: nil, tile: DetailTileID(divisor: 2, x: 1, y: 0))
        let overlap = left.sourceRect.intersection(right.sourceRect)
        func local(_ tile: DetailTile) -> CGRect {
            CGRect(x: (overlap.minX - tile.sourceRect.minX) / 2, y: (overlap.minY - tile.sourceRect.minY) / 2,
                   width: overlap.width / 2, height: overlap.height / 2)
        }
        XCTAssertLessThan(error(left.image.cropping(to: local(left))!, right.image.cropping(to: local(right))!), 0.1)
        if let path = ProcessInfo.processInfo.environment["LUMA_RAW_FIXTURE"] {
            let raw = ImageEngine(), rawInfo = try await raw.open(URL(fileURLWithPath: path))
            var settings = rawInfo.initial
            settings.exposure = -0.7; settings.quarterTurns = 1
            settings.localMasks = [LocalMask(kind: .linear, angle: 39, exposure: 1, feather: 0.7)]
            settings.cropRect = CropRect(x: 0.1, y: 0.2, width: 0.7, height: 0.6)
            let destination = folder.appendingPathComponent("raw.tiff")
            try await raw.export(settings, profile: rawInfo.profile, to: destination, format: .tiff)
            let tile = try await raw.detailTile(settings, profile: rawInfo.profile, tile: DetailTileID(x: 0, y: 0))
            XCTAssertLessThan(error(tile.image, decoded(destination)), 1)
            _ = try await raw.preview(rawInfo.initial, profile: rawInfo.profile, maxDimension: 200)
            let same = try await raw.detailTile(settings, profile: rawInfo.profile, tile: DetailTileID(x: 0, y: 0))
            XCTAssertEqual(error(tile.image, same.image), 0)
        } else { print("SKIP: RAW detail fixture not provided") }
    }
}
