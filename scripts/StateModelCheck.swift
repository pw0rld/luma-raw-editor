import Foundation
import LumaCore

@main struct StateModelCheck {
    @MainActor static func main() async throws {
        let sampleURL = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("orientation-test.jpg")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let draftURL = directory.appendingPathComponent("workspace.json")
        let engine = ImageEngine(), info = try await engine.open(sampleURL)
        let model = EditorModel(draftURL: draftURL, engine: engine)
        // Isolate document operations from GPU availability. --render additionally
        // exercises the actual application reopen/restore path on CI.
        model.photo = info; model.photos = [sampleURL]; model.settings = info.initial
        model.addMask(kind: .linear)
        var mask = model.selectedMask!
        mask.x = 0.1; mask.y = 0.2; mask.width = 0.3; mask.height = 0.4; mask.angle = 31; mask.exposure = 1
        model.setSelectedMask(mask)
        model.setCropRect(CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        let before = model.settings
        model.rotate()
        precondition(model.settings.localMasks[0] == mask.rotatedClockwise)
        precondition(model.settings.cropRect == before.cropRect.rotatedClockwise)
        model.undo(); precondition(model.settings == before)
        model.redo(); precondition(model.settings.localMasks[0] == mask.rotatedClockwise)
        model.removeSelectedMask(); model.undo()
        precondition(model.selectedMask?.id == mask.id, "Undo deletion must restore a usable selection")

        let fixed = model.settings
        model.busy = true
        model.setCropRect(.full); model.setSelectedMask(\.exposure, value: 2)
        model.rotate(); model.reset(); model.removeSelectedMask(); model.addMask(kind: .radial); model.undo()
        precondition(model.settings == fixed, "Busy canvas mutations must be rejected")
        model.busy = false
        model.setSelectedMask(\.exposure, value: .nan)
        precondition(model.settings == fixed, "Invalid parameters must not enter document state")
        for _ in 0..<70 { model.addMask(kind: .radial) }
        precondition(model.masks.count == LocalMask.maximumCount && !model.canAddMask)
        try model.settings.validate()
        let savedDraft = await model.flushDraft()
        precondition(savedDraft)
        let loaded = try await DraftStore(url: draftURL).load()!
        precondition(loaded.entries[0].recipe.adjustments == model.settings)
        precondition(loaded.entries[0].selectedMaskID == model.selectedMaskID)
        let brokenURL = directory.appendingPathComponent("broken.json")
        let brokenData = Data("broken draft".utf8)
        try brokenData.write(to: brokenURL)
        let broken = EditorModel(draftURL: brokenURL)
        await broken.restoreDrafts()
        precondition(broken.error != nil && !broken.busy)
        let replacedBrokenDraft = await broken.flushDraft()
        precondition(!replacedBrokenDraft, "An empty workspace must not overwrite an unreadable draft")
        let retained = try Data(contentsOf: brokenURL)
        precondition(retained == brokenData)

        if CommandLine.arguments.contains("--render") {
            let restored = EditorModel(draftURL: draftURL)
            await restored.restoreDrafts()
            precondition(restored.error == nil && restored.preview != nil)
            precondition(restored.settings == model.settings && restored.selectedMaskID == model.selectedMaskID)
            precondition(restored.canUndo && restored.dirty)
            restored.tool = .crop
            await restored.waitForPreview()
            precondition(restored.previewIsFullFrame)
            restored.tool = .browse
            await restored.waitForPreview()
            precondition(!restored.previewIsFullFrame)
            let source = restored.canvasRenderState!
            let stateBeforeDetail = restored.settings, undoCount = restored.history.undoStack.count
            let detail = try await restored.renderDetail(DetailTileID(x: 0, y: 0), source: source)
            precondition(detail.fullSize == source.size)
            precondition(restored.settings == stateBeforeDetail && restored.history.undoStack.count == undoCount,
                         "Loading detail must not alter the recipe or edit history")
            let histogramSource = restored.histogramRenderState!
            await restored.loadHistogram(histogramSource)
            let histogram = restored.histogram!
            precondition(histogram.previewWidth == Int(histogramSource.size.width))
            precondition(histogram.previewHeight == Int(histogramSource.size.height))
            restored.toggleClipping()
            precondition(restored.clippingOptions == .all)
            let overlay = try await restored.renderClipping(detail.image, source: source, options: .all)
            precondition(overlay?.width == detail.image.width)
            restored.showShadowClipping = false
            do { _ = try await restored.renderClipping(detail.image, source: source, options: .all); preconditionFailure("Stale clipping options accepted") }
            catch is CancellationError { }
            restored.toggleClipping()
            precondition(restored.clippingOptions.isEmpty)
            precondition(restored.settings == stateBeforeDetail && restored.history.undoStack.count == undoCount,
                         "Histogram and clipping switches must not change the recipe/history")
            restored.tool = .mask; await restored.waitForPreview()
            precondition(restored.histogramRenderState == histogramSource, "Edit-tool full frame must not change the histogram's final crop")
            await restored.loadHistogram(restored.histogramRenderState)
            precondition(restored.histogram == histogram)
            restored.tool = .browse; await restored.waitForPreview()
            restored.set(\.exposure, value: restored.settings.exposure + 0.4)
            precondition(restored.histogram == nil, "Stale statistics must immediately disappear while rendering a new edit")
            await restored.loadHistogram(histogramSource)
            precondition(restored.histogram == nil)
            do { _ = try await restored.renderDetail(DetailTileID(x: 0, y: 0), source: source); preconditionFailure("Stale exposure detail accepted") }
            catch is CancellationError { }
            await restored.waitForPreview()
            let edited = restored.canvasRenderState!
            precondition(edited != source)
            let pendingSource = restored.histogramRenderState
            let pendingHistogram = Task { await restored.loadHistogram(pendingSource) }
            await Task.yield()
            restored.compare = true
            await pendingHistogram.value
            precondition(restored.histogram == nil)
            await restored.loadHistogram(restored.histogramRenderState)
            precondition(restored.histogram!.previewWidth == restored.photo!.width)
            let original = restored.canvasRenderState!
            precondition(original.settings == restored.photo!.initial)
            precondition(original.size == CGSize(width: restored.photo!.width, height: restored.photo!.height))
            _ = try await restored.renderDetail(DetailTileID(x: 0, y: 0), source: original)
            restored.compare = false
            restored.tool = .crop; await restored.waitForPreview()
            precondition(restored.canvasRenderState!.settings.cropRect == .full)
            await restored.open(sampleURL.deletingLastPathComponent().appendingPathComponent("match-source.png")).value
            await restored.loadHistogram(histogramSource)
            precondition(restored.histogram == nil, "An old photo's histogram must be rejected")
            await restored.loadHistogram(restored.histogramRenderState)
            precondition(restored.histogram != nil)
            do { _ = try await restored.renderDetail(DetailTileID(x: 0, y: 0), source: edited); preconditionFailure("Previous photo detail accepted") }
            catch is CancellationError { }
            print("PASS: native detail state, stale edit/photo rejection, original/full-frame geometry and unchanged recipe/history")
            print("PASS: final-crop histogram, original comparison, independent clipping switches, stale analysis/options rejection and unchanged recipe/history")
        }
        print("PASS: mask/crop rotation, undo selection, busy protection, valid mask limit, atomic draft, selection persistence and failed draft preservation")
    }
}
