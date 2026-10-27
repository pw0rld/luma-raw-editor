import Foundation
import CoreGraphics

/// Display aids only; never part of a recipe, export or edit history.
public struct ClippingOptions: OptionSet, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let highlights = ClippingOptions(rawValue: 1)
    public static let shadows = ClippingOptions(rawValue: 2)
    public static let all: ClippingOptions = [.highlights, .shadows]
}

/// Counts point-sampled from the entire final, black-composited sRGB preview.
/// Luma is weighted *encoded* RGB, not scene-linear luminance.
public struct OutputHistogram: Equatable {
    public let red: [Int]
    public let green: [Int]
    public let blue: [Int]
    public let luma: [Int]
    public let sampleWidth: Int
    public let sampleHeight: Int
    public let previewWidth: Int
    public let previewHeight: Int
    public let highlights: Int
    public let shadows: Int
    public var sampleCount: Int { sampleWidth * sampleHeight }
    public var highlightFraction: Double { Double(highlights) / Double(sampleCount) }
    public var shadowFraction: Double { Double(shadows) / Double(sampleCount) }
}

public enum OutputDiagnostics {
    public static let maximumSampleDimension = 512

    /// Restrict edit-tool overlays to the final integer crop, in an image or
    /// tile's normalized coordinates. Source rectangles use top-left pixels.
    public static func overlayRegion(crop: CropRect, fullSize: CGSize, sourceRect: CGRect) -> CGRect {
        guard [fullSize.width, fullSize.height, sourceRect.minX, sourceRect.minY, sourceRect.width, sourceRect.height].allSatisfy(\.isFinite),
              fullSize.width > 0, fullSize.height > 0, sourceRect.width > 0, sourceRect.height > 0,
              (try? crop.validate()) != nil else { return .zero }
        let width = max(1, floor(fullSize.width * crop.width))
        let height = max(1, floor(fullSize.height * crop.height))
        let left = floor(fullSize.width * crop.x)
        let top = fullSize.height - floor(fullSize.height * (1 - crop.y - crop.height)) - height
        let region = CGRect(x: left, y: top, width: width, height: height).intersection(sourceRect)
        guard !region.isNull, !region.isEmpty else { return .zero }
        return CGRect(x: (region.minX - sourceRect.minX) / sourceRect.width,
            y: (region.minY - sourceRect.minY) / sourceRect.height,
            width: region.width / sourceRect.width, height: region.height / sourceRect.height)
    }

    // Canonical byte order and color space, independent of CGImage storage,
    // ICC profile, alpha type or scanline padding. Premultiplied RGB is the
    // visible value over black, matching the opaque preview/export composite.
    private static func rgba(_ image: CGImage) throws -> [UInt8] {
        try Task.checkCancellation()
        guard image.width > 0, image.height > 0,
              image.width <= 16_777_216 / image.height else {
            throw EditorError.message("诊断图像过大，请使用预览或细节分块。")
        }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress!, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: ImageEngine.outputSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw EditorError.message("无法读取 sRGB 预览用于诊断。") }
        try Task.checkCancellation()
        return bytes
    }

    public static func histogram(_ image: CGImage) throws -> OutputHistogram {
        let bytes = try rgba(image)
        let scale = min(1, Double(maximumSampleDimension) / Double(max(image.width, image.height)))
        let width = max(1, Int(floor(Double(image.width) * scale)))
        let height = max(1, Int(floor(Double(image.height) * scale)))
        var red = [Int](repeating: 0, count: 256), green = red, blue = red, luma = red
        var highlights = 0, shadows = 0
        for y in 0..<height {
            try Task.checkCancellation()
            let sourceY = min(image.height - 1, (2 * y + 1) * image.height / (2 * height))
            for x in 0..<width {
                let sourceX = min(image.width - 1, (2 * x + 1) * image.width / (2 * width))
                let index = (sourceY * image.width + sourceX) * 4
                let r = Int(bytes[index]), g = Int(bytes[index + 1]), b = Int(bytes[index + 2])
                red[r] += 1; green[g] += 1; blue[b] += 1
                luma[Int((0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)).rounded())] += 1
                if r == 255 || g == 255 || b == 255 { highlights += 1 }
                if r == 0 && g == 0 && b == 0 { shadows += 1 }
            }
        }
        return OutputHistogram(red: red, green: green, blue: blue, luma: luma,
            sampleWidth: width, sampleHeight: height, previewWidth: image.width, previewHeight: image.height,
            highlights: highlights, shadows: shadows)
    }

    /// Exact endpoint classification at the supplied preview/tile resolution.
    /// Red: any sRGB8 channel == 255. Blue: all three channels == 0.
    public static func clippingOverlay(_ image: CGImage, options: ClippingOptions) throws -> CGImage? {
        try Task.checkCancellation()
        guard !options.intersection(.all).isEmpty else { return nil }
        var bytes = try rgba(image)
        for y in 0..<image.height {
            if y % 32 == 0 { try Task.checkCancellation() }
            for x in 0..<image.width {
                let index = (y * image.width + x) * 4
                let highlight = options.contains(.highlights) && (bytes[index] == 255 || bytes[index + 1] == 255 || bytes[index + 2] == 255)
                let shadow = options.contains(.shadows) && bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 0
                bytes[index] = highlight ? 255 : 0
                bytes[index + 1] = 0
                bytes[index + 2] = shadow ? 255 : 0
                bytes[index + 3] = highlight || shadow ? 255 : 0
            }
        }
        try Task.checkCancellation()
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let result = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: image.width * 4, space: ImageEngine.outputSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw EditorError.message("溢出提示生成失败。")
        }
        return result
    }
}
