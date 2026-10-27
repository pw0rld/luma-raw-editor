import Foundation
import CoreGraphics

/// Integer tiles in a power-of-two sampled version of the final image.
public struct DetailTileID: Equatable, Hashable {
    public let divisor: Int
    public let x: Int
    public let y: Int
    public init(divisor: Int = 1, x: Int, y: Int) { self.divisor = divisor; self.x = x; self.y = y }
}
public struct DetailTile {
    public let id: DetailTileID
    public let image: CGImage
    /// Top-left pixel bounds in the full-resolution processed image, including overlap.
    public let sourceRect: CGRect
    public let fullSize: CGSize
}
public struct DetailPlan: Equatable {
    public static let tileSide = 1024
    public static let maximumTiles = 64
    public let imageSize: CGSize
    public let tiles: [DetailTileID]

    public static func needsTiles(transform: ViewportTransform, previewSize: CGSize) -> Bool {
        transform.pixelScale >= 1 || transform.imageRect.width * transform.displayScale > previewSize.width + 0.01
            || transform.imageRect.height * transform.displayScale > previewSize.height + 0.01
    }

    public init(transform: ViewportTransform) throws {
        imageSize = transform.imageSize
        let visible = transform.visibleImageRect
        guard visible.width > 0, visible.height > 0, imageSize.width <= 1_000_000, imageSize.height <= 1_000_000 else {
            throw EditorError.message("细节预览的范围无效。")
        }
        // Never undersample the display. At 100% and above this is always 1.
        let level = max(0, min(16, Int(floor(log2(1 / max(1e-9, min(1, transform.pixelScale)))))))
        let divisor = 1 << level
        let side = CGFloat(Self.tileSide * divisor)
        let left = max(0, Int(floor(visible.minX / side))), right = Int(ceil(visible.maxX / side))
        let top = max(0, Int(floor(visible.minY / side))), bottom = Int(ceil(visible.maxY / side))
        guard (right - left) * (bottom - top) <= Self.maximumTiles else {
            throw EditorError.message("当前细节视口过大，请缩小窗口后重试。")
        }
        let center = CGPoint(x: visible.midX / side, y: visible.midY / side)
        var ids: [DetailTileID] = []
        for y in top..<bottom { for x in left..<right { ids.append(DetailTileID(divisor: divisor, x: x, y: y)) } }
        // Resolve the area under the user's gaze first.
        tiles = ids.sorted {
            let a = hypot(CGFloat($0.x) + 0.5 - center.x, CGFloat($0.y) + 0.5 - center.y)
            let b = hypot(CGFloat($1.x) + 0.5 - center.x, CGFloat($1.y) + 0.5 - center.y)
            return a == b ? ($0.y == $1.y ? $0.x < $1.x : $0.y < $1.y) : a < b
        }
    }

    public static func renderRect(for tile: DetailTileID, fullSize: CGSize) throws -> CGRect {
        guard tile.divisor > 0, tile.divisor <= 65536, tile.divisor.nonzeroBitCount == 1,
              tile.x >= 0, tile.y >= 0, tile.x < 1024, tile.y < 1024,
              fullSize.width.isFinite, fullSize.height.isFinite, fullSize.width > 0, fullSize.height > 0 else {
            throw EditorError.message("细节分块参数无效。")
        }
        let bounds = CGRect(x: 0, y: 0, width: ceil(fullSize.width / CGFloat(tile.divisor)), height: ceil(fullSize.height / CGFloat(tile.divisor)))
        let rect = CGRect(x: tile.x * tileSide, y: tile.y * tileSide, width: tileSide, height: tileSide)
            .insetBy(dx: -2, dy: -2).intersection(bounds)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { throw EditorError.message("细节分块超出照片范围。") }
        return rect
    }
}

extension PhotoInfo {
    /// Matches the full-resolution rotation and integer crop in ImageEngine.
    public func outputSize(for settings: Adjustments) -> CGSize {
        let w = settings.quarterTurns % 2 == 0 ? width : height
        let h = settings.quarterTurns % 2 == 0 ? height : width
        return CGSize(width: max(1, floor(CGFloat(w) * settings.cropRect.width)),
                      height: max(1, floor(CGFloat(h) * settings.cropRect.height)))
    }
}
