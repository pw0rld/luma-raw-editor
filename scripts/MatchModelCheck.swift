import Foundation
import LumaCore

@main struct MatchModelCheck {
    @MainActor static func main() async throws {
        precondition(CommandLine.arguments.count > 1, "Usage: MatchModelCheck Samples")
        let samples = URL(fileURLWithPath: CommandLine.arguments[1])
        let generatedSource = samples.appendingPathComponent("match-source.png")
        let generatedReference = samples.appendingPathComponent("match-reference.png")
        let hasMatchFixtures = FileManager.default.fileExists(atPath: generatedSource.path)
            && FileManager.default.fileExists(atPath: generatedReference.path)
        let sourceFixture = hasMatchFixtures ? generatedSource : samples.appendingPathComponent("orientation-test.jpg")
        let referenceFixture = hasMatchFixtures ? generatedReference : samples.appendingPathComponent("synthetic-bayer.dng")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LumaMatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("image1.\(sourceFixture.pathExtension)")
        let second = folder.appendingPathComponent("image2.\(sourceFixture.pathExtension)")
        try FileManager.default.copyItem(at: sourceFixture, to: first)
        try FileManager.default.copyItem(at: sourceFixture, to: second)

        let model = EditorModel()
        await model.open(first).value
        precondition(model.photo?.url == first && model.preview != nil && !model.busy && model.error == nil,
                     "Source import failed")
        let baseline = model.settings
        await model.openReference(referenceFixture).value
        precondition(model.referencePreview != nil && model.referenceName == referenceFixture.lastPathComponent
                     && model.settings == baseline && !model.busy && model.error == nil,
                     "Reference import should preserve source adjustments")
        await model.applyColorMatch().value
        guard let firstMatch = model.settings.colorMatch else { preconditionFailure("Match was not applied") }
        let matchedSettings = model.settings
        precondition(model.dirty && model.canUndo && model.error == nil && !model.busy,
                     "Match must participate in dirty state and history")
        model.undo()
        precondition(model.settings == baseline && !model.dirty && model.canRedo,
                     "Undo should restore pre-match adjustments")
        model.redo()
        precondition(model.settings == matchedSettings && model.dirty,
                     "Redo should restore embedded match")

        let undoCount = model.history.undoStack.count
        await model.applyColorMatch().value
        precondition(model.settings.colorMatch == firstMatch && model.history.undoStack.count == undoCount,
                     "Repeated matching must be deterministic and must not compound")
        model.clearColorMatch()
        precondition(model.settings == baseline && !model.dirty, "Clear should remove only matching")
        model.undo()
        precondition(model.settings == matchedSettings, "Undo clear should restore matching")

        model.gesture(true)
        model.set(\.matchColorStrength, value: 0.4)
        model.set(\.matchLuminanceStrength, value: 0.2)
        model.set(\.matchDominance, value: 0.6)
        model.gesture(false)
        let tunedSettings = model.settings
        precondition(tunedSettings.matchColorStrength == 0.4 && tunedSettings.matchLuminanceStrength == 0.2
                     && tunedSettings.matchDominance == 0.6, "Matching sliders should edit recipe values")
        model.undo()
        precondition(model.settings == matchedSettings, "Slider gesture must undo as one operation")
        model.redo()
        precondition(model.settings == tunedSettings, "Slider redo must restore matching strengths")

        await model.addFolder(folder).value
        precondition(model.photos.count == 2, "Folder must deduplicate source and add second photo")
        await model.open(second).value
        precondition(model.settings.colorMatch == nil && !model.dirty && model.isUnsaved(first),
                     "Each photo needs its own match state")
        await model.open(first).value
        precondition(model.settings == tunedSettings && model.canUndo && model.dirty,
                     "Switching photos must restore matching and history")
        model.undo()
        precondition(model.settings == matchedSettings, "Per-photo match history must survive switching")
        model.redo()
        precondition(model.settings == tunedSettings, "Per-photo redo must survive switching")

        let previousReferenceName = model.referenceName
        let previousReferenceWidth = model.referencePreview?.width
        await model.openReference(folder.appendingPathComponent("missing-reference.png")).value
        precondition(model.error != nil && model.referenceName == previousReferenceName
                     && model.referencePreview?.width == previousReferenceWidth && model.settings == tunedSettings
                     && model.photo?.url == first && !model.busy,
                     "Failed reference import must retain reference and source edits")
        model.error = nil
        await model.applyColorMatch().value
        precondition(model.settings.colorMatch == firstMatch && model.error == nil,
                     "Failed replacement must not corrupt the previous reference engine")
        print("PASS: reference import, one-click match, non-compounding repeat, strengths, dirty state, undo/redo, clear/undo, folder sessions and failed-reference preservation")
    }
}
