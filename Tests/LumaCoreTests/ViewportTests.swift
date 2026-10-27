#if !STANDALONE_CHECK
import XCTest
#endif
import Foundation
import CoreGraphics
import LumaCore

final class ViewportTests: XCTestCase {
    func testFitAndPixelCoordinateRoundTrip() {
        let viewport = CGSize(width: 900, height: 600)
        let landscape = ViewportTransform(imageSize: CGSize(width: 6000, height: 4000), viewportSize: viewport)
        XCTAssertEqual(landscape.imageRect, CGRect(x: 0, y: 0, width: 900, height: 600))
        let portrait = ViewportTransform(imageSize: CGSize(width: 4000, height: 6000), viewportSize: viewport)
        XCTAssertEqual(portrait.imageRect, CGRect(x: 250, y: 0, width: 400, height: 600))
        for transform in [landscape, portrait] {
            for point in [CGPoint.zero, CGPoint(x: 0.17, y: 0.83), CGPoint(x: 1, y: 1)] {
                let view = transform.viewPoint(for: point)
                let restored = transform.normalizedPoint(at: view)
                XCTAssertLessThan(hypot(restored.x - point.x, restored.y - point.y), 1e-12)
                let pixel = transform.imagePoint(at: view)
                XCTAssertLessThan(hypot(pixel.x - point.x * transform.imageSize.width,
                                        pixel.y - point.y * transform.imageSize.height), 1e-9)
                let back = transform.viewPoint(forImagePoint: pixel)
                XCTAssertLessThan(hypot(back.x - view.x, back.y - view.y), 1e-9)
            }
        }
    }

    func testAnchoredZoomAndBoundedPan() {
        let image = CGSize(width: 6000, height: 4000), canvas = CGSize(width: 900, height: 600)
        let anchor = CGPoint(x: 250, y: 200)
        var state = ViewportState()
        let original = ViewportTransform(imageSize: image, viewportSize: canvas)
        let point = original.normalizedPoint(at: anchor)
        state.zoom(by: 3, at: anchor, imageSize: image, viewportSize: canvas)
        var transform = ViewportTransform(imageSize: image, viewportSize: canvas, state: state)
        let anchored = transform.viewPoint(for: point)
        XCTAssertLessThan(hypot(anchored.x - anchor.x, anchored.y - anchor.y), 1e-9)
        state.pan(by: CGSize(width: 1e6, height: 1e6), imageSize: image, viewportSize: canvas)
        transform = ViewportTransform(imageSize: image, viewportSize: canvas, state: state)
        XCTAssertLessThan(abs(transform.imageRect.minX) + abs(transform.imageRect.minY), 1e-9)
        state.pan(by: CGSize(width: -1e6, height: -1e6), imageSize: image, viewportSize: canvas)
        transform = ViewportTransform(imageSize: image, viewportSize: canvas, state: state)
        XCTAssertLessThan(abs(transform.imageRect.maxX - canvas.width) + abs(transform.imageRect.maxY - canvas.height), 1e-9)
        state.zoom(by: 1e6, at: anchor, imageSize: image, viewportSize: canvas)
        XCTAssertEqual(state.pixelScale, ViewportState.maximumPixelScale)
        state.zoom(by: 1e-6, at: anchor, imageSize: image, viewportSize: canvas)
        XCTAssertEqual(state.pixelScale, ViewportState.minimumPixelScale)
        state.fit(); XCTAssertEqual(state, ViewportState())
    }

    func testOverlayAndDragGeometryAtDifferentZooms() {
        let image = CGSize(width: 4000, height: 6000), canvas = CGSize(width: 900, height: 600)
        let normalized = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        var state = ViewportState()
        for factor: CGFloat in [1, 2, 3] {
            state.zoom(by: factor, at: CGPoint(x: 450, y: 300), imageSize: image, viewportSize: canvas)
            let transform = ViewportTransform(imageSize: image, viewportSize: canvas, state: state)
            let frame = transform.viewRect(for: normalized)
            let topLeft = transform.imagePoint(at: frame.origin)
            XCTAssertLessThan(abs(topLeft.x - 400) + abs(topLeft.y - 1200), 1e-9)
            let bottomRight = transform.imagePoint(at: CGPoint(x: frame.maxX, y: frame.maxY))
            XCTAssertLessThan(abs(bottomRight.x - 1600) + abs(bottomRight.y - 3600), 1e-9)
            // Moving by 5% of the rendered width always edits by 5% of the image.
            let delta = transform.normalizedTranslation(CGSize(width: transform.imageRect.width * 0.05, height: -transform.imageRect.height * 0.07))
            XCTAssertLessThan(abs(delta.width - 0.05) + abs(delta.height + 0.07), 1e-12)
            // The same image-relative point stays aligned after a quarter-turn.
            let rotated = ViewportTransform(imageSize: CGSize(width: image.height, height: image.width), viewportSize: canvas, state: state)
            let mask = LocalMask(x: 0.1, y: 0.2, width: 0.3, height: 0.4).rotatedClockwise
            let rotatedFrame = rotated.viewRect(for: CGRect(x: mask.x, y: mask.y, width: mask.width, height: mask.height))
            let corner = rotated.imagePoint(at: rotatedFrame.origin)
            XCTAssertLessThan(abs(corner.x - 2400) + abs(corner.y - 400), 1e-9)
        }
    }

    func testResizeContinuityAndInvalidInput() {
        let image = CGSize(width: 6000, height: 4000), canvas = CGSize(width: 600, height: 400)
        var state = ViewportState()
        state.zoom(by: 4, at: CGPoint(x: 300, y: 200), imageSize: image, viewportSize: canvas)
        state.pan(by: CGSize(width: -1e6, height: 0), imageSize: image, viewportSize: canvas)
        let resized = CGSize(width: 1400, height: 400)
        let before = ViewportTransform(imageSize: image, viewportSize: resized, state: state)
        state.pan(by: CGSize(width: 100, height: 0), imageSize: image, viewportSize: resized)
        let after = ViewportTransform(imageSize: image, viewportSize: resized, state: state)
        XCTAssertLessThan(abs(after.imageRect.minX - before.imageRect.minX - 100), 1e-9)
        let saved = state
        state.zoom(by: .nan, at: .zero, imageSize: image, viewportSize: canvas)
        state.zoom(by: -1, at: .zero, imageSize: image, viewportSize: canvas)
        state.zoom(by: 2, at: CGPoint(x: CGFloat.infinity, y: 0), imageSize: image, viewportSize: canvas)
        state.pan(by: CGSize(width: CGFloat.nan, height: 0), imageSize: image, viewportSize: canvas)
        XCTAssertEqual(state, saved)
        let empty = ViewportTransform(imageSize: .zero, viewportSize: .zero)
        XCTAssertTrue(empty.imageRect.width > 0 && empty.imageRect.height > 0)
        state.fit()
        XCTAssertEqual(state, ViewportState())
    }

    func testNativeScaleRetinaAndTilePlans() throws {
        let image = CGSize(width: 6001, height: 4003), canvas = CGSize(width: 901, height: 601)
        for backing: CGFloat in [1, 2] {
            var state = ViewportState()
            state.setPixelScale(1, at: CGPoint(x: canvas.width / 2, y: canvas.height / 2), imageSize: image, viewportSize: canvas, displayScale: backing)
            var geometry = ViewportTransform(imageSize: image, viewportSize: canvas, state: state, displayScale: backing)
            XCTAssertEqual(geometry.imageRect.width * backing, image.width)
            XCTAssertEqual(geometry.imageRect.height * backing, image.height)
            XCTAssertEqual(geometry.imageRect.minX * backing, (geometry.imageRect.minX * backing).rounded())
            let plan = try DetailPlan(transform: geometry)
            XCTAssertTrue(plan.tiles.allSatisfy { $0.divisor == 1 })
            XCTAssertTrue(plan.tiles.count > 0 && plan.tiles.count <= DetailPlan.maximumTiles)
            state.zoom(by: 2, at: CGPoint(x: 450, y: 300), imageSize: image, viewportSize: canvas, displayScale: backing)
            geometry = ViewportTransform(imageSize: image, viewportSize: CGSize(width: 711, height: 539), state: state, displayScale: backing)
            XCTAssertEqual(geometry.imageRect.width * backing, image.width * 2)
            XCTAssertEqual(geometry.pixelScale, 2)
            // Changing screens changes the point dimensions, preserving physical 100%.
            state.setPixelScale(1, at: .zero, imageSize: image, viewportSize: canvas, displayScale: backing)
            geometry = ViewportTransform(imageSize: image, viewportSize: canvas, state: state, displayScale: 3 - backing)
            XCTAssertEqual(geometry.imageRect.width * (3 - backing), image.width)
        }
        let fit = ViewportTransform(imageSize: image, viewportSize: canvas, displayScale: 2)
        let plan = try DetailPlan(transform: fit)
        XCTAssertTrue(plan.tiles.allSatisfy { 1 / CGFloat($0.divisor) >= fit.pixelScale })
        let edge = try DetailPlan.renderRect(for: DetailTileID(x: 5, y: 3), fullSize: image)
        XCTAssertEqual(edge.maxX, image.width); XCTAssertEqual(edge.maxY, image.height)
        XCTAssertThrowsError(try DetailPlan.renderRect(for: DetailTileID(divisor: 3, x: 0, y: 0), fullSize: image))
        XCTAssertThrowsError(try DetailPlan.renderRect(for: DetailTileID(x: -1, y: 0), fullSize: image))
        XCTAssertThrowsError(try DetailPlan.renderRect(for: DetailTileID(x: 99, y: 99), fullSize: image))
        var native = ViewportState()
        native.setPixelScale(1, at: .zero, imageSize: CGSize(width: 50000, height: 50000), viewportSize: CGSize(width: 20000, height: 20000))
        XCTAssertThrowsError(try DetailPlan(transform: ViewportTransform(imageSize: CGSize(width: 50000, height: 50000), viewportSize: CGSize(width: 20000, height: 20000), state: native)))
        let regular = CGSize(width: 6000, height: 4000)
        XCTAssertFalse(DetailPlan.needsTiles(transform: ViewportTransform(imageSize: regular, viewportSize: CGSize(width: 900, height: 600), displayScale: 2), previewSize: CGSize(width: 1800, height: 1200)))
        XCTAssertTrue(DetailPlan.needsTiles(transform: ViewportTransform(imageSize: regular, viewportSize: CGSize(width: 1200, height: 800), displayScale: 2), previewSize: CGSize(width: 1800, height: 1200)))
        native.setPixelScale(1, at: .zero, imageSize: regular, viewportSize: canvas, displayScale: 2)
        XCTAssertTrue(DetailPlan.needsTiles(transform: ViewportTransform(imageSize: regular, viewportSize: canvas, state: native, displayScale: 2), previewSize: CGSize(width: 1800, height: 1200)))
    }
}
