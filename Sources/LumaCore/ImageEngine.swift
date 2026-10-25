import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import Metal
import UniformTypeIdentifiers
import CryptoKit

public struct PhotoInfo {
    public let url: URL
    public let sha256: String
    public let isRAW: Bool
    public let width: Int
    public let height: Int
    public let initial: Adjustments
    public let profile: RAWProfile?
    public let backend: String
    public let camera: String
}
public enum ExportFormat: String, CaseIterable { case jpeg, tiff }

// All mutable CIRAWFilter and CIContext work is serialized off the main actor.
public actor ImageEngine {
    private let context: CIContext
    public static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    public static let outputSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let backend: String
    private var info: PhotoInfo?
    private var raw: CIRAWFilter?
    private var bitmap: CIImage?
    private var properties: [String: Any] = [:]
    private let optionalRAWKeys = [
        ("isLocalToneMapSupported", "localToneMapAmount"),
        ("isLuminanceNoiseReductionSupported", "luminanceNoiseReductionAmount"),
        ("isColorNoiseReductionSupported", "colorNoiseReductionAmount"),
        ("isSharpnessSupported", "sharpnessAmount"), ("isContrastSupported", "contrastAmount"),
        ("isDetailSupported", "detailAmount"), ("isMoireReductionSupported", "moireReductionAmount")]

    public init() {
        let options: [CIContextOption: Any] = [.workingColorSpace: Self.workingSpace,
            .workingFormat: CIFormat.RGBAh, .cacheIntermediates: true]
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: options); backend = "Metal · \(device.name)"
        } else {
            context = CIContext(options: options.merging([.useSoftwareRenderer: true]) { _, new in new })
            backend = "CPU（Metal 不可用）"
        }
    }

    public func open(_ url: URL) throws -> PhotoInfo {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) else { throw EditorError.message("无法读取此照片。") }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let rawExtensions = ["dng", "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "raw", "rwl", "3fr", "iiq"]
        let isRAW = UTType(type as String)?.conforms(to: .rawImage) == true || rawExtensions.contains(url.pathExtension.lowercased())
        var nextRaw: CIRAWFilter?
        var nextBitmap: CIImage?
        var profile: RAWProfile?
        var initial = Adjustments()
        let extent: CGRect
        if isRAW {
            guard let filter = CIRAWFilter(imageURL: url) else {
                throw EditorError.message("系统 RAW 解码器不支持此文件/相机。请检查 macOS 的相机支持。")
            }
            filter.extendedDynamicRangeAmount = 0 // Single decoder-owned SDR rendering; no second automatic tone map.
            filter.scaleFactor = 1
            guard let image = filter.outputImage else { throw EditorError.message("RAW 显影失败。") }
            extent = image.extent; nextRaw = filter
            initial.temperature = Double(filter.neutralTemperature); initial.tint = Double(filter.neutralTint)
            var values: [String: Double] = [:]
            for key in ["baselineExposure", "shadowBias", "boostAmount", "boostShadowAmount"] {
                values[key] = (filter.value(forKey: key) as? NSNumber)?.doubleValue
            }
            for (support, key) in optionalRAWKeys where (filter.value(forKey: support) as? NSNumber)?.boolValue == true {
                values[key] = (filter.value(forKey: key) as? NSNumber)?.doubleValue
            }
            profile = RAWProfile(decoderVersion: filter.decoderVersion.rawValue, values: values, lensCorrection: filter.isLensCorrectionEnabled)
        } else {
            guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
                throw EditorError.message("无法解码普通图片。")
            }
            // ImageIO's embedded profile is honored; untagged RGB follows CI's sRGB default.
            nextBitmap = image; extent = image.extent
        }
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { throw EditorError.message("无效的图片尺寸。") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation(); hash.update(data: chunk)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let nextInfo = PhotoInfo(url: url, sha256: digest, isRAW: isRAW, width: Int(extent.width), height: Int(extent.height), initial: initial, profile: profile, backend: backend, camera: tiff[kCGImagePropertyTIFFModel as String] as? String ?? "")
        // Commit only after a successful open, so a bad file doesn't destroy the current document.
        raw = nextRaw; bitmap = nextBitmap; properties = props; info = nextInfo
        context.clearCaches()
        return nextInfo
    }

    public func embeddedThumbnail(maxDimension: Int = 1200) -> CGImage? {
        guard let info, let source = CGImageSourceCreateWithURL(info.url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension] as CFDictionary)
    }

    private func applyProfile(_ profile: RAWProfile, to raw: CIRAWFilter) throws {
        let version = CIRAWDecoderVersion(rawValue: profile.decoderVersion)
        guard raw.supportedDecoderVersions.contains(version) else { throw EditorError.message("此系统不支持配方指定的 RAW 解码器版本。") }
        raw.decoderVersion = version
        let supported = Set(["baselineExposure", "shadowBias", "boostAmount", "boostShadowAmount"] + optionalRAWKeys.compactMap { pair in
            (raw.value(forKey: pair.0) as? NSNumber)?.boolValue == true ? pair.1 : nil
        })
        guard Set(profile.values.keys).isSubset(of: supported) else { throw EditorError.message("配方包含此 RAW 文件不支持的参数。") }
        for (key, value) in profile.values { raw.setValue(value, forKey: key) }
        if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = profile.lensCorrection }
        raw.extendedDynamicRangeAmount = 0
        raw.isGamutMappingEnabled = true
    }

    // Local masks are evaluated on the upright, uncropped image. Keeping this
    // stage here makes preview, export, and recipe replays use the same geometry.
    private func localMaskImage(_ mask: LocalMask, extent e: CGRect) -> CIImage {
        let center = CGPoint(x: e.minX + mask.x * e.width + mask.width * e.width / 2,
                             y: e.minY + (1 - mask.y - mask.height / 2) * e.height)
        let bounds = CGRect(x: e.minX + mask.x * e.width,
                            y: e.minY + (1 - mask.y - mask.height) * e.height,
                            width: mask.width * e.width,
                            height: mask.height * e.height)
        let white = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        let black = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        let gradient: CIImage
        switch mask.kind {
        case .radial:
            // Build a unit radial gradient and scale it around the center so
            // non-square mask bounds remain elliptical.
            // Keep the radii strictly ordered; equal radii are rejected by
            // some Core Image implementations when feather is zero.
            let inner = min(0.999, max(0, 1 - mask.feather))
            let source = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: center.x, y: center.y),
                "inputRadius0": inner,
                "inputRadius1": 1,
                "inputColor0": white,
                "inputColor1": black])?.outputImage ?? CIImage(color: black).cropped(to: e)
            let rx = max(1, bounds.width / 2), ry = max(1, bounds.height / 2)
            let transform = CGAffineTransform(translationX: center.x, y: center.y)
                .scaledBy(x: rx, y: ry)
                .translatedBy(x: -center.x, y: -center.y)
            gradient = source.transformed(by: transform).cropped(to: e)
        case .linear:
            let geometry = MaskGeometry(mask, imageSize: e.size)
            let endpoints = geometry.linearEndpoints
            let start = CGPoint(x: e.minX + endpoints.start.x, y: e.maxY - endpoints.start.y)
            let end = CGPoint(x: e.minX + endpoints.end.x, y: e.maxY - endpoints.end.y)
            let line = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(cgPoint: start), "inputPoint1": CIVector(cgPoint: end),
                "inputColor0": white, "inputColor1": black])?.outputImage
                ?? CIImage(color: black).cropped(to: e)
            // Restrict a linear gradient to its normalized rectangle; blur the
            // finite crop so feather also softens the rectangle's outer edge.
            let blackFrame = CIImage(color: black).cropped(to: e)
            var lineInside = line.cropped(to: bounds)
            if mask.feather > 0 {
                let radius = geometry.featherRadius
                lineInside = lineInside.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            }
            gradient = lineInside.composited(over: blackFrame).cropped(to: e)
        }
        var result = gradient
        if mask.inverted { result = result.applyingFilter("CIColorInvert") }
        // CIBlendWithMask reads grayscale. Keep alpha opaque, so premultiplication
        // cannot apply opacity/feather a second time.
        let strength = mask.opacity
        result = result.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: strength, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: strength, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: strength, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        return result.cropped(to: e)
    }

    private func applying(_ mask: LocalMask, to image: CIImage) -> CIImage {
        if mask.isNeutral { return image }
        var variant = image
        if mask.temperatureDelta != 0 || mask.tintDelta != 0 {
            variant = variant.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 + mask.temperatureDelta, y: mask.tintDelta)])
        }
        if mask.exposure != 0 {
            variant = variant.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: mask.exposure])
        }
        if mask.saturation != 1 {
            variant = variant.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: mask.saturation])
        }
        let maskImage = localMaskImage(mask, extent: image.extent)
        return variant.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: maskImage])
    }

    // Preview and export differ only in decoding/output resolution, never in adjustment order.
    private func processed(_ settings: Adjustments, profile: RAWProfile?, maxDimension: CGFloat?) throws -> CIImage {
        try Task.checkCancellation(); try settings.validate()
        guard let info else { throw EditorError.message("请先导入照片。") }
        var image: CIImage
        if let raw {
            guard let profile else { throw EditorError.message("缺少 RAW 显影配置。") }
            let recipe = Recipe(sourceName: info.url.lastPathComponent, sourceSHA256: info.sha256, rawProfile: profile, adjustments: settings)
            try recipe.validate(); try applyProfile(profile, to: raw)
            let upright = settings.quarterTurns % 2 == 0
                ? CGSize(width: info.width, height: info.height) : CGSize(width: info.height, height: info.width)
            let cropDimension = max(upright.width * settings.cropRect.width, upright.height * settings.cropRect.height)
            raw.scaleFactor = Float(maxDimension.map { min(1, $0 / max(1, cropDimension)) } ?? 1)
            raw.isDraftModeEnabled = false
            raw.exposure = Float(settings.exposure)
            raw.neutralTemperature = Float(settings.temperature); raw.neutralTint = Float(settings.tint)
            guard let output = raw.outputImage else { throw EditorError.message("RAW 显影未产生图像。") }
            image = output
        } else if let bitmap {
            image = bitmap
            if settings.temperature != 6500 || settings.tint != 0 {
                image = image.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(x: settings.temperature, y: settings.tint)])
            }
            if settings.exposure != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: settings.exposure]) }
        } else { throw EditorError.message("原片不可用。") }
        if settings.shadows != 0.25 || settings.midtones != 0.5 || settings.highlights != 0.75 {
            image = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.25, y: settings.shadows),
                "inputPoint2": CIVector(x: 0.5, y: settings.midtones), "inputPoint3": CIVector(x: 0.75, y: settings.highlights),
                "inputPoint4": CIVector(x: 1, y: 1)])
        }
        if settings.saturation != 1 { image = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: settings.saturation]) }
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        image = image.oriented(orientations[settings.quarterTurns])
        for mask in settings.localMasks {
            if mask.enabled { image = applying(mask, to: image) }
        }
        let e = image.extent
        // CropRect uses top-left normalized coordinates; Core Image uses a bottom-left origin.
        // Integral pixel bounds avoid transparent edge pixels and keep preview/export identical.
        let crop = settings.cropRect
        let cropWidth = max(1, floor(e.width * crop.width))
        let cropHeight = max(1, floor(e.height * crop.height))
        let cropX = floor(e.width * crop.x)
        let cropY = floor(e.height * (1 - crop.y - crop.height))
        image = image.cropped(to: CGRect(x: e.minX + cropX, y: e.minY + cropY,
                                          width: min(cropWidth, e.width - cropX),
                                          height: min(cropHeight, e.height - cropY)))
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if let maxDimension { image = scaled(image, maxDimension: maxDimension) }
        if let match = settings.colorMatch { image = try match.applying(to: image) }
        return image
    }
    private func scaled(_ image: CIImage, maxDimension: CGFloat) -> CIImage {
        let factor = min(1, maxDimension / max(image.extent.width, image.extent.height))
        return factor < 1 ? image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: factor, kCIInputAspectRatioKey: 1]) : image
    }
    public func preview(_ settings: Adjustments, profile: RAWProfile?, maxDimension: CGFloat = 1800) throws -> CGImage {
        let image = try processed(settings, profile: profile, maxDimension: maxDimension)
        try Task.checkCancellation()
        guard let result = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: Self.outputSpace) else { throw EditorError.message("预览渲染失败。") }
        return result
    }
    /// Exact coverage, rendered separately from the photograph for the canvas.
    public func previewMask(_ mask: LocalMask, width: Int, height: Int) throws -> CGImage {
        try mask.validate(); try Task.checkCancellation()
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let coverage = localMaskImage(mask, extent: extent)
        let overlay = coverage.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0.38, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 1, y: 0.25, z: 0.03, w: 0)])
        guard let result = context.createCGImage(overlay, from: extent, format: .RGBA8, colorSpace: Self.outputSpace) else {
            throw EditorError.message("蒙版覆盖图渲染失败。")
        }
        return result
    }
    public func analyzeForMatch(_ settings: Adjustments, profile: RAWProfile?, clusterCount: Int) throws -> MatchAnalysis {
        // Always analyze the current base edit, without re-applying an earlier transfer.
        var base = settings; base.colorMatch = nil
        let image = try processed(base, profile: profile, maxDimension: 256)
        let bounds = CGRect(x: 0, y: 0, width: floor(image.extent.width), height: floor(image.extent.height))
        let width = Int(bounds.width), height = Int(bounds.height)
        guard width > 0, height > 0 else { throw EditorError.message("图片过小，无法追色。") }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: width * 16,
                           bounds: bounds, format: .RGBAf, colorSpace: Self.workingSpace)
        }
        try Task.checkCancellation()
        var samples: [LabColor] = []; samples.reserveCapacity(width * height)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3])
            guard alpha >= 0.99, alpha.isFinite else { continue }
            let rgb = (0..<3).map { Double(pixels[index + $0]) / alpha }
            guard rgb.allSatisfy({ $0.isFinite }) else { continue }
            samples.append(LabColor.fromLinearP3(rgb))
        }
        return try MatchAnalysis.analyze(samples, clusterCount: clusterCount)
    }
    public func export(_ settings: Adjustments, profile: RAWProfile?, to url: URL, format: ExportFormat, includeGPS: Bool = false) throws {
        guard let info else { throw EditorError.message("请先导入照片。") }
        try Self.protectOriginal(destination: url, original: info.url)
        let image = try processed(settings, profile: profile, maxDimension: nil)
        let opaque = image.composited(over: CIImage(color: .black).cropped(to: image.extent))
        guard let cg = context.createCGImage(opaque, from: image.extent, format: format == .tiff ? .RGBA16 : .RGBA8, colorSpace: Self.outputSpace) else { throw EditorError.message("导出渲染失败。") }
        let data = NSMutableData()
        let type = format == .jpeg ? UTType.jpeg.identifier : UTType.tiff.identifier
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { throw EditorError.message("无法创建导出文件。") }
        var metadata = exportMetadata(width: cg.width, height: cg.height, includeGPS: includeGPS)
        if format == .jpeg { metadata[kCGImageDestinationLossyCompressionQuality as String] = 0.94 }
        CGImageDestinationAddImage(destination, cg, metadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EditorError.message("图片编码失败。") }
        try (data as Data).write(to: url, options: .atomic)
    }
    public static func protectOriginal(destination: URL, original: URL) throws {
        let a = destination.resolvingSymlinksInPath().standardizedFileURL
        let b = original.resolvingSymlinksInPath().standardizedFileURL
        let aID = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
        let bID = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
        guard a != b, !(aID != nil && aID == bID) else { throw EditorError.message("不能覆盖原片，请选择新文件名。") }
    }
    private func exportMetadata(width: Int, height: Int, includeGPS: Bool) -> [String: Any] {
        var result: [String: Any] = [kCGImagePropertyOrientation as String: 1,
            kCGImagePropertyPixelWidth as String: width, kCGImagePropertyPixelHeight as String: height]
        var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        // Keep capture metadata, remove stale image/thumbnail/vendor payloads.
        for key in ["PixelXDimension", "PixelYDimension", "ColorSpace", "MakerNote", "UserComment", "CFAPattern", "SubjectArea", "SubjectLocation"] { exif.removeValue(forKey: key) }
        exif[kCGImagePropertyExifPixelXDimension as String] = width
        exif[kCGImagePropertyExifPixelYDimension as String] = height
        exif[kCGImagePropertyExifColorSpace as String] = 1
        result[kCGImagePropertyExifDictionary as String] = exif
        let originalTIFF = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        var tiff = originalTIFF.filter { ["Make", "Model", "Artist", "Copyright", "DateTime", "ImageDescription"].contains($0.key) }
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        tiff[kCGImagePropertyTIFFSoftware as String] = "Luma RAW 0.4"
        result[kCGImagePropertyTIFFDictionary as String] = tiff
        if var iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any] {
            for key in ["Preview", "PreviewFormat", "PreviewVersion", "ImageOrientation"] { iptc.removeValue(forKey: key) }
            result[kCGImagePropertyIPTCDictionary as String] = iptc
        }
        if includeGPS { result[kCGImagePropertyGPSDictionary as String] = properties[kCGImagePropertyGPSDictionary as String] }
        return result
    }
}
