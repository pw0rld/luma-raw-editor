import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import LumaCore

/// Run `create path.png` separately from `run path.png` so fixture generation
/// does not inflate the measured viewing process's peak memory.
@main struct DetailBench {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw EditorError.message("Usage: DetailBench create|run path.png") }
        let url = URL(fileURLWithPath: CommandLine.arguments[2])
        if CommandLine.arguments[1] == "create" {
            let width = 6000, height = 4000
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: ImageEngine.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            for x in 0..<width {
                context.setFillColor(CGColor(red: CGFloat(x) / CGFloat(width), green: x % 2 == 0 ? 0.1 : 0.9,
                                             blue: x % 2 == 0 ? 0.8 : 0.2, alpha: 1))
                context.fill(CGRect(x: x, y: 0, width: 1, height: height))
            }
            context.setFillColor(CGColor(red: 0.7, green: 0.15, blue: 0.1, alpha: 0.6))
            context.fillEllipse(in: CGRect(x: 1500, y: 1000, width: 3000, height: 2000))
            let target = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(target, context.makeImage()!, nil)
            guard CGImageDestinationFinalize(target) else { throw EditorError.message("Fixture write failed") }
            print("Created 24MP synthetic RGB fixture: \(url.path)")
            return
        }
        guard CommandLine.arguments[1] == "run" else { throw EditorError.message("Unknown benchmark mode") }
        let engine = ImageEngine(), started = Date()
        let info = try await engine.open(url)
        let openTime = Date().timeIntervalSince(started)
        var settings = info.initial; settings.exposure = -0.2; settings.saturation = 0.9
        settings.localMasks = [LocalMask(exposure: 0.6, feather: 0.8)]
        var clock = Date()
        _ = try await engine.preview(settings, profile: info.profile)
        let previewTime = Date().timeIntervalSince(clock)
        let size = info.outputSize(for: settings), viewportSize = CGSize(width: 900, height: 600)
        var state = ViewportState()
        state.setPixelScale(1, at: CGPoint(x: 450, y: 300), imageSize: size, viewportSize: viewportSize, displayScale: 2)
        func plan(_ state: ViewportState) throws -> DetailPlan {
            try DetailPlan(transform: ViewportTransform(imageSize: size, viewportSize: viewportSize, state: state, displayScale: 2))
        }
        let first = try plan(state)
        clock = Date()
        for id in first.tiles { _ = try await engine.detailTile(settings, profile: info.profile, tile: id) }
        let nativeTime = Date().timeIntervalSince(clock)
        clock = Date()
        for id in first.tiles { _ = try await engine.detailTile(settings, profile: info.profile, tile: id) }
        let cachedTime = Date().timeIntervalSince(clock)
        clock = Date()
        for _ in 0..<5 {
            state.pan(by: CGSize(width: 350, height: 70), imageSize: size, viewportSize: viewportSize, displayScale: 2)
            for id in try plan(state).tiles { _ = try await engine.detailTile(settings, profile: info.profile, tile: id) }
        }
        let panTime = Date().timeIntervalSince(clock), usage = await engine.detailCacheUsage()
        guard usage.bytes <= ImageEngine.detailCacheByteLimit else { throw EditorError.message("Cache budget exceeded") }
        let report: [String: Any] = ["format": info.isRAW ? "RAW" : "RGB", "width": info.width, "height": info.height,
            "openSeconds": openTime, "basePreviewSeconds": previewTime, "firstNativeViewportSeconds": nativeTime,
            "cachedViewportSeconds": cachedTime, "fivePansSeconds": panTime, "firstViewportTiles": first.tiles.count,
            "cacheTiles": usage.tiles, "cacheBytes": usage.bytes]
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
}
