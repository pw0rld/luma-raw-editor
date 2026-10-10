import Foundation

public enum EditorError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public struct CropRect: Codable, Equatable {
    // Normalized coordinates in the displayed upright image. x/y are measured from the top-left.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public static let full = CropRect()
    public func validate() throws {
        let values = [x, y, width, height]
        guard values.allSatisfy(\.isFinite), x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1, y + height <= 1, width >= 0.02, height >= 0.02 else {
            throw EditorError.message("裁剪框超出图像范围或太小。")
        }
    }
}

public struct Adjustments: Codable, Equatable {
    public var temperature = 6500.0
    public var tint = 0.0
    public var exposure = 0.0
    public var saturation = 1.0
    public var shadows = 0.25
    public var midtones = 0.5
    public var highlights = 0.75
    public var quarterTurns = 0
    public var cropRect = CropRect()
    public var colorMatch: ColorMatch?
    public var matchColorStrength: Double {
        get { colorMatch?.colorStrength ?? 0 }
        set { colorMatch?.colorStrength = newValue }
    }
    public var matchLuminanceStrength: Double {
        get { colorMatch?.luminanceStrength ?? 0 }
        set { colorMatch?.luminanceStrength = newValue }
    }
    public var matchDominance: Double {
        get { colorMatch?.dominance ?? 0.25 }
        set { colorMatch?.dominance = newValue }
    }
    public init() {}
    // Kept as writable compatibility properties for v1 callers. New edits use cropRect.
    @available(*, deprecated, message: "Use cropRect for an asymmetric crop box.")
    public var horizontalTrim: Double {
        get { min(cropRect.x, 1 - cropRect.x - cropRect.width) }
        set {
            cropRect.x = newValue; cropRect.width = 1 - newValue * 2
        }
    }
    @available(*, deprecated, message: "Use cropRect for an asymmetric crop box.")
    public var verticalTrim: Double {
        get { min(cropRect.y, 1 - cropRect.y - cropRect.height) }
        set {
            cropRect.y = newValue; cropRect.height = 1 - newValue * 2
        }
    }
    private enum CodingKeys: String, CodingKey {
        case temperature, tint, exposure, saturation, shadows, midtones, highlights, quarterTurns
        case horizontalTrim, verticalTrim, cropRect, colorMatch
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 6500
        tint = try container.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        exposure = try container.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
        shadows = try container.decodeIfPresent(Double.self, forKey: .shadows) ?? 0.25
        midtones = try container.decodeIfPresent(Double.self, forKey: .midtones) ?? 0.5
        highlights = try container.decodeIfPresent(Double.self, forKey: .highlights) ?? 0.75
        quarterTurns = try container.decodeIfPresent(Int.self, forKey: .quarterTurns) ?? 0
        let oldHorizontal = try container.decodeIfPresent(Double.self, forKey: .horizontalTrim) ?? 0
        let oldVertical = try container.decodeIfPresent(Double.self, forKey: .verticalTrim) ?? 0
        cropRect = try container.decodeIfPresent(CropRect.self, forKey: .cropRect)
            ?? CropRect(x: oldHorizontal, y: oldVertical,
                        width: 1 - 2 * oldHorizontal, height: 1 - 2 * oldVertical)
        colorMatch = try container.decodeIfPresent(ColorMatch.self, forKey: .colorMatch)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(temperature, forKey: .temperature); try container.encode(tint, forKey: .tint)
        try container.encode(exposure, forKey: .exposure); try container.encode(saturation, forKey: .saturation)
        try container.encode(shadows, forKey: .shadows); try container.encode(midtones, forKey: .midtones)
        try container.encode(highlights, forKey: .highlights); try container.encode(quarterTurns, forKey: .quarterTurns)
        // Keep these keys so older readers can still see the closest symmetric crop.
        try container.encode(horizontalTrim, forKey: .horizontalTrim)
        try container.encode(verticalTrim, forKey: .verticalTrim)
        try container.encode(cropRect, forKey: .cropRect)
        try container.encodeIfPresent(colorMatch, forKey: .colorMatch)
    }
    public func validate() throws {
        let values = [temperature, tint, exposure, saturation, shadows, midtones, highlights]
        guard values.allSatisfy({ $0.isFinite }), (2000...50000).contains(temperature),
              (-150...150).contains(tint), (-5...5).contains(exposure), (0...2).contains(saturation),
              0 <= shadows, shadows <= midtones, midtones <= highlights, highlights <= 1,
              (0...3).contains(quarterTurns)
        else { throw EditorError.message("配方包含越界或无效参数。") }
        try cropRect.validate()
        try colorMatch?.validate()
    }
}

public struct RAWProfile: Codable, Equatable {
    public var decoderVersion: String
    public var values: [String: Double]
    public var lensCorrection: Bool
    public init(decoderVersion: String, values: [String: Double], lensCorrection: Bool) {
        self.decoderVersion = decoderVersion; self.values = values; self.lensCorrection = lensCorrection
    }
}

public struct Recipe: Codable, Equatable {
    public static let currentVersion = 2
    public var version = 2
    public var pipeline = "luma-sdr-p3-v2"
    public var sourceName: String
    public var sourceSHA256: String
    public var rawProfile: RAWProfile?
    public var adjustments: Adjustments
    public init(sourceName: String, sourceSHA256: String, rawProfile: RAWProfile?, adjustments: Adjustments) {
        self.sourceName = sourceName; self.sourceSHA256 = sourceSHA256
        self.rawProfile = rawProfile; self.adjustments = adjustments
    }
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
    public static func decode(_ data: Data) throws -> Recipe {
        var value = try JSONDecoder().decode(Recipe.self, from: data)
        if value.version == 1, value.pipeline == "luma-sdr-p3-v1", value.adjustments.colorMatch == nil {
            value.version = Self.currentVersion; value.pipeline = "luma-sdr-p3-v2"
        }
        try value.validate(); return value
    }
    public func validate() throws {
        guard version == Self.currentVersion, pipeline == "luma-sdr-p3-v2" else {
            throw EditorError.message("不支持此配方版本或处理管线。")
        }
        guard sourceSHA256.count == 64, sourceSHA256.allSatisfy({ $0.isHexDigit }) else {
            throw EditorError.message("配方缺少有效的原片校验值。")
        }
        try adjustments.validate()
        if let profile = rawProfile {
            let ranges: [String: ClosedRange<Double>] = [
                "baselineExposure": -20...20, "shadowBias": -10...10, "boostAmount": 0...1,
                "boostShadowAmount": 0...2, "localToneMapAmount": 0...1,
                "luminanceNoiseReductionAmount": 0...1, "colorNoiseReductionAmount": 0...1,
                "sharpnessAmount": 0...1, "contrastAmount": 0...1, "detailAmount": 0...3,
                "moireReductionAmount": 0...1]
            guard !profile.decoderVersion.isEmpty,
                  Set(["baselineExposure", "shadowBias", "boostAmount", "boostShadowAmount"]).isSubset(of: Set(profile.values.keys)),
                  profile.values.allSatisfy({ key, value in value.isFinite && (ranges[key]?.contains(value) ?? false) }) else {
                throw EditorError.message("RAW 解码配置无效。")
            }
        }
    }
}

public struct EditHistory {
    public private(set) var undoStack: [Adjustments] = []
    public private(set) var redoStack: [Adjustments] = []
    public init() {}
    public mutating func record(from: Adjustments, to: Adjustments) {
        guard from != to else { return }
        undoStack.append(from)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }
    public mutating func undo(current: Adjustments) -> Adjustments? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current); return previous
    }
    public mutating func redo(current: Adjustments) -> Adjustments? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current); return next
    }
}
