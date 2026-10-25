#if !STANDALONE_CHECK
import XCTest
#endif
import Foundation
import CoreGraphics
import LumaCore

final class StabilityTests: XCTestCase {
    func testMaskAndCropRotationPreservesContent() throws {
        let size = CGSize(width: 600, height: 400)
        for kind in [LocalMaskKind.radial, .linear] {
            let original = LocalMask(kind: kind, x: 0.1, y: 0.2, width: 0.3, height: 0.4,
                                     angle: 31, exposure: 1, opacity: 0.7, feather: 0.4)
            let rotated = original.rotatedClockwise
            try rotated.validate()
            let a = MaskGeometry(original, imageSize: size)
            let b = MaskGeometry(rotated, imageSize: CGSize(width: size.height, height: size.width))
            var error = 0.0
            for x in stride(from: 3.0, to: 600, by: 23) {
                for y in stride(from: 7.0, to: 400, by: 19) {
                    error = max(error, abs(a.unblurredWeight(at: CGPoint(x: x, y: y))
                        - b.unblurredWeight(at: CGPoint(x: size.height - y, y: x))))
                }
            }
            XCTAssertLessThan(error, 1e-10)
            let four = rotated.rotatedClockwise.rotatedClockwise.rotatedClockwise
            XCTAssertLessThan(abs(four.x - original.x) + abs(four.y - original.y)
                + abs(four.width - original.width) + abs(four.height - original.height), 1e-10)
        }
        let crop = CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4).rotatedClockwise
        XCTAssertLessThan(abs(crop.x - 0.4), 1e-10)
        XCTAssertEqual(crop.y, 0.1); XCTAssertEqual(crop.width, 0.4); XCTAssertEqual(crop.height, 0.3)
    }

    func testLinearCoverageOpacityAndFeatherGeometry() {
        var mask = LocalMask(kind: .linear, x: 0.25, y: 0.25, width: 0.5, height: 0.5, feather: 0)
        let size = CGSize(width: 6000, height: 4000)
        var geometry = MaskGeometry(mask, imageSize: size)
        XCTAssertEqual(geometry.unblurredWeight(at: CGPoint(x: 1500, y: 2000)), 1)
        XCTAssertEqual(geometry.unblurredWeight(at: CGPoint(x: 3000, y: 2000)), 0.5)
        XCTAssertEqual(geometry.unblurredWeight(at: CGPoint(x: 4499.999, y: 2000)) < 0.00001, true)
        XCTAssertEqual(geometry.unblurredWeight(at: CGPoint(x: 500, y: 2000)), 0)
        mask.opacity = 0.5; geometry = MaskGeometry(mask, imageSize: size)
        XCTAssertEqual(geometry.unblurredWeight(at: CGPoint(x: 3000, y: 2000)), 0.25)
        mask.inverted = true; geometry = MaskGeometry(mask, imageSize: size)
        XCTAssertEqual(geometry.unblurredWeight(at: CGPoint(x: 500, y: 2000)), 0.5)
        mask.opacity = 0; geometry = MaskGeometry(mask, imageSize: size)
        XCTAssertEqual(geometry.unblurredWeight(at: CGPoint(x: 3000, y: 2000)), 0)
        var radial = LocalMask(kind: .radial, feather: 0)
        let point = CGPoint(x: 425, y: 200)
        let hard = MaskGeometry(radial, imageSize: CGSize(width: 600, height: 400)).unblurredWeight(at: point)
        radial.feather = 1
        let soft = MaskGeometry(radial, imageSize: CGSize(width: 600, height: 400)).unblurredWeight(at: point)
        XCTAssertTrue(hard > soft)
    }

    func testV3RecipeAndV2Migration() throws {
        var settings = Adjustments(); settings.localMasks = [LocalMask(kind: .linear, exposure: 1)]
        let recipe = Recipe(sourceName: "source.jpg", sourceSHA256: String(repeating: "a", count: 64), rawProfile: nil, adjustments: settings)
        XCTAssertEqual(recipe.version, 3); XCTAssertEqual(recipe.pipeline, "luma-sdr-p3-v3")
        var json = try JSONSerialization.jsonObject(with: recipe.encoded()) as! [String: Any]
        json["version"] = 2; json["pipeline"] = "luma-sdr-p3-v2"
        let migrated = try Recipe.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(migrated.version, 3)
        XCTAssertTrue(migrated.adjustments.localMasks[0].legacyLinearFalloff)
        XCTAssertFalse(recipe.adjustments.localMasks[0].legacyLinearFalloff)
        var invalid = settings; invalid.localMasks.append(settings.localMasks[0])
        XCTAssertThrowsError(try invalid.validate())
    }

    func testGlobalClusterAssignmentAndLegacyPreservation() throws {
        func cluster(_ a: Double) -> ColorCluster {
            ColorCluster(meanA: a, meanB: 0, meanL: 50, stdA: 2, stdB: 2, weight: 0.5)
        }
        let source = MatchAnalysis(clusters: [cluster(-10), cluster(10)], lightnessSamples: Array(repeating: 50, count: 32))
        let reference = MatchAnalysis(clusters: [cluster(0), cluster(80)], lightnessSamples: Array(repeating: 50, count: 32))
        let match = try ColorMatch.make(source: source, reference: reference, referenceName: "ref", referenceSHA256: String(repeating: "a", count: 64))
        XCTAssertEqual(Set(match.mappedReferenceClusters().map(\.meanA)).count, 2)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(match)) as! [String: Any]
        json["algorithm"] = "lab-clusters-quantiles-v1"
        let legacy = try JSONDecoder().decode(ColorMatch.self, from: JSONSerialization.data(withJSONObject: json))
        try legacy.validate()
        XCTAssertEqual(legacy.mappedReferenceClusters().map(\.meanA), [0, 0])
    }

    func testAtomicDraftRoundTripAndCorruptRejection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DraftStore(url: directory.appendingPathComponent("nested/workspace.json"))
        let initial = try await store.load(); XCTAssertNil(initial)
        var settings = Adjustments(); settings.localMasks = [LocalMask(exposure: 1)]
        let recipe = Recipe(sourceName: "source.jpg", sourceSHA256: String(repeating: "a", count: 64), rawProfile: nil, adjustments: settings)
        var history = EditHistory(); history.record(from: Adjustments(), to: settings)
        let sourceURL = directory.appendingPathComponent("source.jpg")
        let draft = WorkspaceDraft(photos: [sourceURL], activeURL: sourceURL, entries: [
            DraftEntry(sourceURL: sourceURL, recipe: recipe, saved: Adjustments(), history: history, selectedMaskID: settings.localMasks[0].id)])
        try await store.save(draft)
        let restored = try await store.load()
        XCTAssertEqual(restored?.entries[0].recipe, recipe)
        XCTAssertEqual(restored?.entries[0].history.undoStack.count, 1)
        XCTAssertEqual(restored?.entries[0].selectedMaskID, settings.localMasks[0].id)
        var invalid = draft
        invalid.entries[0].recipe.adjustments.localMasks.append(settings.localMasks[0])
        do { try await store.save(invalid); XCTFail("Invalid draft accepted") } catch { }
        let afterFailure = try await store.load()
        XCTAssertEqual(afterFailure?.entries[0].recipe, recipe)
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent("nested/workspace.json"))
        do { _ = try await store.load(); XCTFail("Corrupt draft accepted") } catch { }
    }
}
