#if !STANDALONE_CHECK
import XCTest
#endif
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import LumaCore

final class WhiteBalanceTests: XCTestCase {
    private func imageMeans(_ image: CGImage) -> (warmth: Double, magenta: Double) {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { storage in
            let context = CGContext(data: storage.baseAddress!, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: ImageEngine.outputSpace,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var warmth = 0.0, magenta = 0.0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let r = Double(bytes[index]), g = Double(bytes[index + 1]), b = Double(bytes[index + 2])
            warmth += r - b
            magenta += (r + b) / 2 - g
        }
        let count = Double(image.width * image.height)
        return (warmth / count, magenta / count)
    }

    func testRGBAndMaskDirectionsAndLegacyRecipe() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: url) }
        let canvas = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                               space: ImageEngine.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        canvas.setFillColor(CGColor(red: 0.57, green: 0.57, blue: 0.57, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, canvas.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let engine = ImageEngine()
        let info = try await engine.open(url)
        func center(_ settings: Adjustments) async throws -> (warmth: Double, magenta: Double) {
            let image = try await engine.preview(settings, profile: nil, maxDimension: 64)
            return imageMeans(image.cropping(to: CGRect(x: 31, y: 31, width: 2, height: 2))!)
        }
        func settings(temperature: Double = 6500, tint: Double = 0, local: Bool) -> Adjustments {
            var value = info.initial
            if local {
                value.localMasks = [LocalMask(x: 0, y: 0, width: 1, height: 1,
                                              temperatureDelta: temperature - 6500, tintDelta: tint, feather: 0)]
            } else {
                value.temperature = temperature
                value.tint = tint
            }
            return value
        }
        for local in [false, true] {
            let cool = try await center(settings(temperature: 4500, local: local))
            let warm = try await center(settings(temperature: 8500, local: local))
            let green = try await center(settings(tint: -50, local: local))
            let magenta = try await center(settings(tint: 50, local: local))
            XCTAssertTrue(cool.warmth < -5 && warm.warmth > 5)
            XCTAssertTrue(green.magenta < -5 && magenta.magenta > 5)

            let corrected = settings(temperature: 8500, tint: 25, local: local)
            let recipe = Recipe(sourceName: url.lastPathComponent, sourceSHA256: info.sha256, rawProfile: nil, adjustments: corrected)
            XCTAssertEqual(try Recipe.decode(recipe.encoded()).adjustments, corrected)
            var json = try JSONSerialization.jsonObject(with: recipe.encoded()) as! [String: Any]
            json["version"] = 3
            json["pipeline"] = "luma-sdr-p3-v3"
            var stored = json["adjustments"] as! [String: Any]
            stored.removeValue(forKey: "legacyWhiteBalance")
            if local {
                var masks = stored["localMasks"] as! [[String: Any]]
                masks[0].removeValue(forKey: "legacyWhiteBalance")
                stored["localMasks"] = masks
            }
            json["adjustments"] = stored
            let legacy = try Recipe.decode(JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(legacy.adjustments.legacyWhiteBalance, !local)
            XCTAssertEqual(legacy.adjustments.localMasks.first?.legacyWhiteBalance, local ? true : nil)
            XCTAssertEqual(try Recipe.decode(legacy.encoded()).adjustments, legacy.adjustments)
            let oldPixels = try await center(legacy.adjustments)
            let correctedPixels = try await center(corrected)
            XCTAssertTrue(oldPixels.warmth < correctedPixels.warmth - 10)
            XCTAssertTrue(oldPixels.magenta < correctedPixels.magenta - 10)
        }
    }

    func testSyntheticRAWTemperatureAndTintDirections() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engine = ImageEngine()
        let info = try await engine.open(root.appendingPathComponent("Samples/synthetic-bayer.dng"))
        XCTAssertTrue(info.isRAW)
        var settings = info.initial
        settings.exposure = -3
        settings.temperature = 4500
        let cool = imageMeans(try await engine.preview(settings, profile: info.profile, maxDimension: 256))
        settings.temperature = 8500
        let warm = imageMeans(try await engine.preview(settings, profile: info.profile, maxDimension: 256))
        XCTAssertTrue(warm.warmth > cool.warmth + 5)
        settings.temperature = info.initial.temperature
        settings.tint = -50
        let green = imageMeans(try await engine.preview(settings, profile: info.profile, maxDimension: 256))
        settings.tint = 50
        let magenta = imageMeans(try await engine.preview(settings, profile: info.profile, maxDimension: 256))
        XCTAssertTrue(magenta.magenta > green.magenta + 5)
    }
}
