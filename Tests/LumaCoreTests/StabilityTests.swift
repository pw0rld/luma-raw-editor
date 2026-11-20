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

    func testCurrentRecipeAndV2Migration() throws {
        var settings = Adjustments(); settings.localMasks = [LocalMask(kind: .linear, exposure: 1)]
        let recipe = Recipe(sourceName: "source.jpg", sourceSHA256: String(repeating: "a", count: 64), rawProfile: nil, adjustments: settings)
        XCTAssertEqual(recipe.version, Recipe.currentVersion)
        XCTAssertEqual(recipe.pipeline, Recipe.currentPipeline)
        var json = try JSONSerialization.jsonObject(with: recipe.encoded()) as! [String: Any]
        json["version"] = 2; json["pipeline"] = "luma-sdr-p3-v2"
        let migrated = try Recipe.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(migrated.version, Recipe.currentVersion)
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
        let draftURL = directory.appendingPathComponent("nested/workspace.json")
        let store = DraftStore(url: draftURL)
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

        var legacy = draft
        legacy.entries[0].recipe.version = 2
        legacy.entries[0].recipe.pipeline = "luma-sdr-p3-v2"
        var linearEdit = settings
        linearEdit.tint = 20
        linearEdit.localMasks[0].kind = .linear
        linearEdit.localMasks[0].temperatureDelta = 600
        var earlier = linearEdit
        earlier.exposure = -1
        var later = linearEdit
        later.exposure = 1
        var linearHistory = EditHistory()
        linearHistory.record(from: earlier, to: linearEdit)
        linearHistory.record(from: linearEdit, to: later)
        _ = linearHistory.undo(current: later)
        legacy.entries[0].recipe.adjustments = linearEdit
        legacy.entries[0].saved = earlier
        legacy.entries[0].history = linearHistory
        let rawURL = directory.appendingPathComponent("source.dng")
        let rawProfile = RAWProfile(decoderVersion: "test", values: [
            "baselineExposure": 0, "shadowBias": 0, "boostAmount": 1, "boostShadowAmount": 0
        ], lensCorrection: false)
        var rawSettings = settings
        rawSettings.temperature = 5200
        rawSettings.legacyWhiteBalance = true
        rawSettings.localMasks[0].tintDelta = 12
        rawSettings.localMasks[0].legacyWhiteBalance = true
        var editedRAW = rawSettings
        editedRAW.exposure = 1
        var rawHistory = EditHistory()
        rawHistory.record(from: rawSettings, to: editedRAW)
        rawHistory.record(from: editedRAW, to: rawSettings)
        _ = rawHistory.undo(current: rawSettings)
        var rawRecipe = Recipe(sourceName: "source.dng", sourceSHA256: recipe.sourceSHA256,
            rawProfile: rawProfile, adjustments: rawSettings)
        rawRecipe.version = 3
        rawRecipe.pipeline = "luma-sdr-p3-v3"
        legacy.photos.append(rawURL)
        legacy.entries.append(DraftEntry(sourceURL: rawURL, recipe: rawRecipe, saved: rawSettings,
            history: rawHistory, selectedMaskID: nil))

        func omittingWhiteBalanceFlags(_ json: Any) -> Any {
            if var dictionary = json as? [String: Any] {
                dictionary.removeValue(forKey: "legacyWhiteBalance")
                return dictionary.mapValues(omittingWhiteBalanceFlags)
            }
            if let array = json as? [Any] { return array.map(omittingWhiteBalanceFlags) }
            return json
        }
        func writeWithoutFlags(_ workspace: WorkspaceDraft) throws {
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace))
            try JSONSerialization.data(withJSONObject: omittingWhiteBalanceFlags(json)).write(to: draftURL)
        }
        try writeWithoutFlags(legacy)
        let migrated = try await store.load()
        guard let migrated,
              let rgb = migrated.entries.first(where: { $0.sourceURL == sourceURL }),
              let raw = migrated.entries.first(where: { $0.sourceURL == rawURL }) else {
            XCTFail("Missing migrated drafts")
            return
        }
        XCTAssertEqual(rgb.recipe.version, Recipe.currentVersion)
        XCTAssertEqual(rgb.saved.exposure, -1)
        XCTAssertEqual(rgb.history.undoStack.first?.exposure, -1)
        XCTAssertEqual(rgb.history.redoStack.first?.exposure, 1)
        let oldStates = [rgb.recipe.adjustments, rgb.saved] + rgb.history.undoStack + rgb.history.redoStack
        for state in oldStates {
            XCTAssertTrue(state.localMasks[0].legacyLinearFalloff)
            XCTAssertTrue(state.localMasks[0].legacyWhiteBalance)
            XCTAssertTrue(state.legacyWhiteBalance)
        }
        rawSettings.legacyWhiteBalance = false
        XCTAssertEqual(raw.recipe.adjustments, rawSettings)
        XCTAssertEqual(raw.saved, rawSettings)
        XCTAssertEqual(raw.history.undoStack, [rawSettings])
        XCTAssertEqual(raw.history.redoStack, [rawSettings])

        // A second startup after saving the migrated workspace retains the flags explicitly.
        try await store.save(migrated)
        let reopened = try await store.load()
        XCTAssertEqual(reopened?.entries[0].recipe.adjustments, rgb.recipe.adjustments)
        XCTAssertEqual(reopened?.entries[0].saved, rgb.saved)
        XCTAssertEqual(reopened?.entries[0].history.undoStack, rgb.history.undoStack)
        XCTAssertEqual(reopened?.entries[0].history.redoStack, rgb.history.redoStack)

        legacy.entries[0].recipe.version = Recipe.currentVersion
        legacy.entries[0].recipe.pipeline = Recipe.currentPipeline
        try writeWithoutFlags(legacy)
        let current = try await store.load()?.entries[0]
        XCTAssertEqual(current?.recipe.adjustments, linearEdit)
        XCTAssertEqual(current?.saved, earlier)
        XCTAssertEqual(current?.history.undoStack, [earlier])
        XCTAssertEqual(current?.history.redoStack, [later])

        try Data("corrupt".utf8).write(to: draftURL)
        do { _ = try await store.load(); XCTFail("Corrupt draft accepted") } catch { }
    }
}
