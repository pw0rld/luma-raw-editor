import Foundation
import CoreGraphics

/// Viewing state only: never stored in an image recipe or edit history.
/// nil uses Fit; an explicit scale is screen pixels per full-resolution pixel.
public struct ViewportState: Equatable {
    public static let minimumPixelScale: CGFloat = 0.01
    public static let maximumPixelScale: CGFloat = 8
    public private(set) var pixelScale: CGFloat?
    public private(set) var center = CGPoint(x: 0.5, y: 0.5)
    public init() {}
    public mutating func fit() { self = ViewportState() }

    public mutating func setPixelScale(_ value: CGFloat, at anchor: CGPoint, imageSize: CGSize, viewportSize: CGSize, displayScale: CGFloat = 1) {
        guard value.isFinite, value > 0, anchor.x.isFinite, anchor.y.isFinite else { return }
        let before = ViewportTransform(imageSize: imageSize, viewportSize: viewportSize, state: self, displayScale: displayScale)
        let point = before.normalizedPoint(at: anchor)
        pixelScale = min(Self.maximumPixelScale, max(Self.minimumPixelScale, value))
        let after = ViewportTransform(imageSize: imageSize, viewportSize: viewportSize, state: self, displayScale: displayScale)
        center = after.boundedCenter(CGPoint(
            x: point.x - (anchor.x - after.viewportSize.width / 2) / after.imageRect.width,
            y: point.y - (anchor.y - after.viewportSize.height / 2) / after.imageRect.height))
    }
    public mutating func zoom(by factor: CGFloat, at anchor: CGPoint, imageSize: CGSize, viewportSize: CGSize, displayScale: CGFloat = 1) {
        guard factor.isFinite, factor > 0 else { return }
        let before = ViewportTransform(imageSize: imageSize, viewportSize: viewportSize, state: self, displayScale: displayScale)
        setPixelScale(before.pixelScale * factor, at: anchor, imageSize: imageSize, viewportSize: viewportSize, displayScale: displayScale)
    }
    public mutating func pan(by translation: CGSize, imageSize: CGSize, viewportSize: CGSize, displayScale: CGFloat = 1) {
        guard translation.width.isFinite, translation.height.isFinite else { return }
        let transform = ViewportTransform(imageSize: imageSize, viewportSize: viewportSize, state: self, displayScale: displayScale)
        let delta = transform.normalizedTranslation(translation)
        let visibleCenter = transform.normalizedPoint(at: CGPoint(x: transform.viewportSize.width / 2, y: transform.viewportSize.height / 2))
        center = transform.boundedCenter(CGPoint(x: visibleCenter.x - delta.width, y: visibleCenter.y - delta.height))
    }
}

/// Shared top-left transform. Image dimensions are full-resolution pixels;
/// viewport positions are points. Backing scale converts points to screen pixels.
public struct ViewportTransform {
    public let imageSize: CGSize
    public let viewportSize: CGSize
    public let imageRect: CGRect
    public let pixelScale: CGFloat
    public let displayScale: CGFloat

    public init(imageSize: CGSize, viewportSize: CGSize, state: ViewportState = ViewportState(), displayScale: CGFloat = 1) {
        func positive(_ value: CGFloat) -> CGFloat { value.isFinite && value > 0 ? value : 1 }
        self.imageSize = CGSize(width: positive(imageSize.width), height: positive(imageSize.height))
        self.viewportSize = CGSize(width: positive(viewportSize.width), height: positive(viewportSize.height))
        self.displayScale = positive(displayScale)
        let fit = min(self.viewportSize.width / self.imageSize.width, self.viewportSize.height / self.imageSize.height)
        pixelScale = state.pixelScale ?? fit * self.displayScale
        let scale = pixelScale / self.displayScale
        let size = CGSize(width: self.imageSize.width * scale, height: self.imageSize.height * scale)
        func bounded(_ center: CGFloat, length: CGFloat, visible: CGFloat) -> CGFloat {
            if length <= visible { return 0.5 }
            let half = visible / (2 * length)
            return min(1 - half, max(half, center))
        }
        let center = CGPoint(x: bounded(state.center.x, length: size.width, visible: self.viewportSize.width),
                             y: bounded(state.center.y, length: size.height, visible: self.viewportSize.height))
        var origin = CGPoint(x: self.viewportSize.width / 2 - center.x * size.width,
                             y: self.viewportSize.height / 2 - center.y * size.height)
        // At native size, align the pixel grid instead of blending half pixels.
        if state.pixelScale != nil, pixelScale >= 1 {
            origin.x = (origin.x * self.displayScale).rounded() / self.displayScale
            origin.y = (origin.y * self.displayScale).rounded() / self.displayScale
        }
        imageRect = CGRect(origin: origin, size: size)
    }
    public func boundedCenter(_ point: CGPoint) -> CGPoint {
        func bounded(_ value: CGFloat, length: CGFloat, visible: CGFloat) -> CGFloat {
            if length <= visible { return 0.5 }
            let half = visible / (2 * length)
            return min(1 - half, max(half, value))
        }
        return CGPoint(x: bounded(point.x, length: imageRect.width, visible: viewportSize.width),
                       y: bounded(point.y, length: imageRect.height, visible: viewportSize.height))
    }
    public func normalizedPoint(at viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: (viewPoint.x - imageRect.minX) / imageRect.width, y: (viewPoint.y - imageRect.minY) / imageRect.height)
    }
    public func viewPoint(for normalizedPoint: CGPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + normalizedPoint.x * imageRect.width, y: imageRect.minY + normalizedPoint.y * imageRect.height)
    }
    public func imagePoint(at viewPoint: CGPoint) -> CGPoint {
        let point = normalizedPoint(at: viewPoint)
        return CGPoint(x: point.x * imageSize.width, y: point.y * imageSize.height)
    }
    public func viewPoint(forImagePoint point: CGPoint) -> CGPoint {
        viewPoint(for: CGPoint(x: point.x / imageSize.width, y: point.y / imageSize.height))
    }
    public func viewRect(for normalizedRect: CGRect) -> CGRect {
        CGRect(origin: viewPoint(for: normalizedRect.origin), size: CGSize(width: normalizedRect.width * imageRect.width, height: normalizedRect.height * imageRect.height))
    }
    public func normalizedTranslation(_ translation: CGSize) -> CGSize {
        CGSize(width: translation.width / imageRect.width, height: translation.height / imageRect.height)
    }
    public var visibleImageRect: CGRect {
        let visible = imageRect.intersection(CGRect(origin: .zero, size: viewportSize))
        guard !visible.isNull else { return .zero }
        return CGRect(origin: imagePoint(at: visible.origin), size: CGSize(width: visible.width / imageRect.width * imageSize.width, height: visible.height / imageRect.height * imageSize.height))
            .intersection(CGRect(origin: .zero, size: imageSize))
    }
}
