import Foundation
import CoreGraphics

/// Shared by the renderer, canvas controls, and independent coverage checks.
/// All points here use the displayed image's top-left origin.
public struct MaskGeometry {
    public let mask: LocalMask
    public let bounds: CGRect
    public let imageSize: CGSize
    public init(_ mask: LocalMask, imageSize: CGSize) {
        self.mask = mask; self.imageSize = imageSize
        bounds = CGRect(x: mask.x * imageSize.width, y: mask.y * imageSize.height,
                        width: mask.width * imageSize.width, height: mask.height * imageSize.height)
    }
    public var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    public var linearEndpoints: (start: CGPoint, end: CGPoint) {
        let radians = mask.angle * .pi / 180
        let dx = cos(radians), dy = sin(radians)
        let half = mask.legacyLinearFalloff ? hypot(imageSize.width, imageSize.height)
            : min(abs(dx) > 1e-9 ? bounds.width / (2 * abs(dx)) : .infinity,
                  abs(dy) > 1e-9 ? bounds.height / (2 * abs(dy)) : .infinity)
        return (CGPoint(x: center.x - dx * half, y: center.y - dy * half),
                CGPoint(x: center.x + dx * half, y: center.y + dy * half))
    }
    public var featherRadius: Double { mask.feather * min(bounds.width, bounds.height) * 0.18 }
    /// The unblurred weight. Linear feather is applied by the renderer to this
    /// finite field, so Gaussian support may extend a little outside the box.
    public func unblurredWeight(at point: CGPoint) -> Double {
        let weight: Double
        if mask.kind == .radial {
            let rx = max(1e-9, bounds.width / 2), ry = max(1e-9, bounds.height / 2)
            let distance = hypot((point.x - center.x) / rx, (point.y - center.y) / ry)
            let inner = min(0.999, max(0, 1 - mask.feather))
            weight = min(1, max(0, (1 - distance) / (1 - inner)))
        } else if bounds.contains(point) {
            let (start, end) = linearEndpoints
            let dx = end.x - start.x, dy = end.y - start.y
            let t = ((point.x - start.x) * dx + (point.y - start.y) * dy) / max(1e-9, dx * dx + dy * dy)
            weight = min(1, max(0, 1 - t))
        } else { weight = 0 }
        return (mask.inverted ? 1 - weight : weight) * mask.opacity
    }
}
