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
        }
        print("PASS: mask/crop rotation, undo selection, busy protection, valid mask limit, atomic draft and selection persistence")
    }
}
