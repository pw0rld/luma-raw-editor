import Foundation
import LumaCore

/// Uses temporary copies only: importing a changed or unreadable source must
/// never replace another document or destroy an existing editing draft.
@main struct DocumentRecoveryCheck {
    @MainActor static func main() async throws {
        let samples = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await changedSource(samples: samples, directory: directory)
        try await relinkOfflineSource(samples: samples, directory: directory)
        try await failedImport(samples: samples, directory: directory)
        try await gestureCancellation(samples: samples)
        try await changedRAWProfile(directory: directory)
    }

    @MainActor private static func relinkOfflineSource(samples: URL, directory: URL) async throws {
        let source = directory.appendingPathComponent("offline.png")
        let other = directory.appendingPathComponent("still-online.jpg")
        let replacement = directory.appendingPathComponent("relocated.png")
        let wrong = directory.appendingPathComponent("mismatch.png")
        let sourceData = try Data(contentsOf: samples.appendingPathComponent("match-source.png"))
        try sourceData.write(to: source)
        try Data(contentsOf: samples.appendingPathComponent("orientation-test.jpg")).write(to: other)
        try Data(contentsOf: samples.appendingPathComponent("match-reference.png")).write(to: wrong)
        let draftURL = directory.appendingPathComponent("relink-draft.json")
        let store = DraftStore(url: draftURL)
        let model = EditorModel(draftURL: draftURL)
        await model.open(source).value
        model.set(\.exposure, value: 1.25)
        model.addMask(kind: .radial)
        model.addMask(kind: .linear)
        model.undo()
        await model.waitForPreview()
        await model.open(other).value
        await model.open(source).value
        let saved = await model.flushDraft(); precondition(saved)
        let initial = try await store.load()!
        let edit = initial.entries.first { $0.sourceURL == source }!
        precondition(!edit.history.undoStack.isEmpty && !edit.history.redoStack.isEmpty && edit.selectedMaskID != nil)

        try FileManager.default.moveItem(at: source, to: replacement)
        let restored = EditorModel(draftURL: draftURL)
        await restored.restoreDrafts()
        precondition(restored.error == nil && restored.photo?.url == other && restored.unavailablePhotos == [source])
        precondition(restored.canRelink(source))
        let activeBefore = restored.settings
        await restored.relinkOriginal(source, to: other).value
        precondition(restored.error != nil && restored.photos == initial.photos && restored.photo?.url == other)
        restored.error = nil
        let cancelled = restored.relinkOriginal(source, to: replacement)
        cancelled.cancel()
        await cancelled.value
        precondition(restored.error == nil && restored.photos == initial.photos && restored.settings == activeBefore)
        await restored.relinkOriginal(source, to: wrong).value
        precondition(restored.error != nil && restored.photo?.url == other && restored.settings == activeBefore)
        precondition(restored.photos == initial.photos && restored.unavailablePhotos == [source])
        let savedAfterMismatch = await restored.flushDraft(); precondition(savedAfterMismatch)
        let retained = try await store.load()!.entries.first { $0.sourceURL == source }!
        checkRetained(retained, edit)

        restored.error = nil
        await restored.relinkOriginal(source, to: replacement).value
        precondition(restored.error == nil && restored.photo?.url == replacement)
        precondition(restored.photos == [replacement, other] && restored.unavailablePhotos.isEmpty)
        precondition(restored.settings == edit.recipe.adjustments && restored.selectedMaskID == edit.selectedMaskID)
        precondition(restored.history.undoStack == edit.history.undoStack && restored.history.redoStack == edit.history.redoStack)
        let relinkSaved = await restored.flushDraft(); precondition(relinkSaved)
        let updated = try await store.load()!
        precondition(updated.activeURL == replacement && updated.photos == [replacement, other])
        precondition(!updated.entries.contains { $0.sourceURL == source })
        let entry = updated.entries.first { $0.sourceURL == replacement }!
        precondition(entry.recipe.sourceName == replacement.lastPathComponent && entry.recipe.sourceSHA256 == edit.recipe.sourceSHA256)
        precondition(entry.saved == edit.saved && entry.selectedMaskID == edit.selectedMaskID)
        let unchanged = try Data(contentsOf: replacement); precondition(unchanged == sourceData)
        let reopened = EditorModel(draftURL: draftURL)
        await reopened.restoreDrafts()
        precondition(reopened.error == nil && reopened.photo?.url == replacement && reopened.settings == edit.recipe.adjustments)
        restored.redo(); precondition(restored.settings == edit.history.redoStack.last)

        let allOffline = directory.appendingPathComponent("all-offline.json")
        let allOfflineStore = DraftStore(url: allOffline)
        try await allOfflineStore.save(WorkspaceDraft(photos: [source], activeURL: source, entries: [edit]))
        let empty = EditorModel(draftURL: allOffline)
        await empty.restoreDrafts()
        precondition(empty.photo == nil && empty.unavailablePhotos == [source] && empty.canRelink(source))
        let emptySaved = await empty.flushDraft(); precondition(emptySaved)
        let missingDraft = try await allOfflineStore.load()!
        precondition(missingDraft.activeURL == source)
        checkRetained(missingDraft.entries[0], edit)
        await empty.relinkOriginal(source, to: replacement).value
        precondition(empty.error == nil && empty.photo?.url == replacement && empty.settings == edit.recipe.adjustments)
        print("PASS: offline relink validates bytes before changing the path; cancellation, workspace order, edits and undo/redo survive")
    }

    @MainActor private static func changedSource(samples: URL, directory: URL) async throws {
        let source = directory.appendingPathComponent("edited.png")
        let other = directory.appendingPathComponent("other.jpg")
        let originalData = try Data(contentsOf: samples.appendingPathComponent("match-source.png"))
        try originalData.write(to: source)
        try Data(contentsOf: samples.appendingPathComponent("orientation-test.jpg")).write(to: other)
        let draftURL = directory.appendingPathComponent("source-draft.json")
        let model = EditorModel(draftURL: draftURL)
        await model.open(source).value
        precondition(model.error == nil && model.photo?.url == source)
        model.set(\.exposure, value: 1.25); model.addMask(kind: .radial)
        await model.waitForPreview()
        let initiallySaved = await model.flushDraft(); precondition(initiallySaved)
        let before = try await DraftStore(url: draftURL).load()!.entries.first { $0.sourceURL == source }!
        await model.open(other).value
        let current = model.settings, currentHistory = model.history.undoStack, list = model.photos
        try Data(contentsOf: samples.appendingPathComponent("match-reference.png")).write(to: source, options: .atomic)
        await model.open(source).value
        await model.waitForPreview()
        precondition(model.error != nil && model.photo?.url == other && !model.busy)
        precondition(model.settings == current && model.history.undoStack == currentHistory && model.photos == list)
        precondition(model.canvasRenderState != nil)
        let rejectedSaved = await model.flushDraft(); precondition(rejectedSaved)
        let snapshot = try await DraftStore(url: draftURL).load()!
        let retained = snapshot.entries.first { $0.sourceURL == source }!
        checkRetained(retained, before)

        // Startup must also preserve an incompatible active draft, even after a
        // later flush. Restoring the original bytes must recover all old edits.
        var activeChanged = snapshot; activeChanged.activeURL = source
        let restoreURL = directory.appendingPathComponent("restore-changed.json")
        try await DraftStore(url: restoreURL).save(activeChanged)
        let restored = EditorModel(draftURL: restoreURL)
        await restored.restoreDrafts()
        precondition(restored.error != nil && restored.photo == nil && !restored.busy)
        let restoredSaved = await restored.flushDraft(); precondition(restoredSaved)
        let afterRestore = try await DraftStore(url: restoreURL).load()!.entries.first { $0.sourceURL == source }!
        checkRetained(afterRestore, before)
        try originalData.write(to: source, options: .atomic)
        restored.error = nil
        await restored.open(source).value
        precondition(restored.error == nil && restored.settings == before.recipe.adjustments)
        precondition(restored.history.undoStack == before.history.undoStack && restored.selectedMaskID == before.selectedMaskID)
        print("PASS: changed source rejected before commit; active photo, old draft/history and startup recovery preserved")
    }

    @MainActor private static func failedImport(samples: URL, directory: URL) async throws {
        let source = samples.appendingPathComponent("match-source.png")
        let model = EditorModel()
        await model.open(source).value
        let list = model.photos
        model.set(\.exposure, value: 1.5)
        let settings = model.settings, undo = model.history.undoStack
        let missing = directory.appendingPathComponent("missing.png")
        await model.open(missing).value
        await model.waitForPreview()
        precondition(model.error != nil && !model.busy && !model.rendering)
        precondition(model.photos == list && model.photo?.url == source)
        precondition(model.settings == settings && model.history.undoStack == undo)
        let state = model.canvasRenderState!
        precondition(state.settings == settings)
        _ = try await model.renderDetail(DetailTileID(x: 0, y: 0), source: state)
        await model.loadHistogram(model.histogramRenderState)
        precondition(model.histogram != nil)

        let broken = directory.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: broken)
        model.error = nil
        await model.open(broken).value; await model.waitForPreview()
        precondition(model.error != nil && model.photos == list && model.canvasRenderState != nil)

        // Cached pixels alone are insufficient: selection-only work was also
        // cancelled, so a failed import must rebuild the current mask overlay.
        model.error = nil
        model.addMask(kind: .radial)
        let radial = model.selectedMaskID!
        model.addMask(kind: .linear)
        await model.waitForPreview()
        let previousOverlay = model.maskOverlayPreview!
        model.selectMask(radial)
        await model.open(missing).value; await model.waitForPreview()
        precondition(model.selectedMaskID == radial && model.previewIsFullFrame)
        precondition(model.maskOverlayPreview != nil && model.maskOverlayPreview !== previousOverlay)
        precondition(model.canvasRenderState != nil && model.photos == list)
        print("PASS: failed import preserves list/settings/history and resumes pending pixels, detail, histogram and selected-mask overlay")
    }

    @MainActor private static func gestureCancellation(samples: URL) async throws {
        let model = EditorModel()
        await model.open(samples.appendingPathComponent("match-source.png")).value
        model.tool = .crop; await model.waitForPreview()
        let original = model.settings
        let oldOwner = UUID(), newOwner = UUID()
        model.gesture(true, owner: oldOwner)
        model.setCropRect(CropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        let cropped = model.settings
        model.compare = true; model.compare = false
        precondition(model.history.undoStack.count == 1)
        model.gesture(true, owner: newOwner)
        model.set(\.exposure, value: 0.75)
        model.gesture(false, owner: oldOwner) // delayed old view.onDisappear
        model.set(\.exposure, value: 1)
        precondition(model.history.undoStack.count == 1, "Old cleanup must not close a newer gesture")
        model.gesture(false, owner: newOwner)
        model.gesture(false, owner: newOwner) // onEnded after onDisappear
        precondition(model.history.undoStack.count == 2)
        model.undo(); precondition(model.settings == cropped)
        model.undo(); precondition(model.settings == original)
        model.redo(); precondition(model.settings == cropped)

        // A late owned callback must not close an ordinary slider transaction.
        model.gesture(true)
        model.set(\.exposure, value: 0.5)
        model.gesture(false, owner: oldOwner)
        model.set(\.exposure, value: 0.9)
        model.gesture(false)
        precondition(model.history.undoStack.count == 2)
        model.undo(); precondition(model.settings == cropped)
        model.addMask(kind: .linear); await model.waitForPreview()
        let beforeMask = model.settings, count = model.history.undoStack.count
        model.gesture(true, owner: oldOwner)
        model.setSelectedMask(\.exposure, value: 1)
        model.compare = true; model.compare = false
        model.gesture(false, owner: oldOwner)
        precondition(model.history.undoStack.count == count + 1)
        model.undo(); precondition(model.settings == beforeMask)
        print("PASS: compare closes crop/mask transactions; stale owner cleanup, duplicate endings and later slider edits keep independent undo")
    }

    @MainActor private static func changedRAWProfile(directory: URL) async throws {
        guard let path = ProcessInfo.processInfo.environment["LUMA_RAW_FIXTURE"] else {
            print("SKIP: changed RAW profile recovery fixture not provided"); return
        }
        let source = directory.appendingPathComponent("profile.dng")
        try Data(contentsOf: URL(fileURLWithPath: path)).write(to: source)
        let engine = ImageEngine(), info = try await engine.open(source)
        var storedProfile = info.profile!
        let baseline = storedProfile.values["baselineExposure"]!
        storedProfile.values["baselineExposure"] = baseline < 19 ? baseline + 0.125 : baseline - 0.125
        var edited = info.initial; edited.exposure = 0.75
        var history = EditHistory(); history.record(from: info.initial, to: edited)
        let entry = DraftEntry(sourceURL: source,
            recipe: Recipe(sourceName: source.lastPathComponent, sourceSHA256: info.sha256, rawProfile: storedProfile, adjustments: edited),
            saved: info.initial, history: history, selectedMaskID: nil)
        let url = directory.appendingPathComponent("raw-profile-draft.json")
        try await DraftStore(url: url).save(WorkspaceDraft(photos: [source], activeURL: source, entries: [entry]))
        let model = EditorModel(draftURL: url)
        await model.restoreDrafts()
        precondition(model.error != nil && model.photo == nil && !model.busy)
        let profileSaved = await model.flushDraft(); precondition(profileSaved)
        let retained = try await DraftStore(url: url).load()!.entries[0]
        checkRetained(retained, entry)
        let moved = directory.appendingPathComponent("moved-profile.dng")
        try FileManager.default.moveItem(at: source, to: moved)
        model.error = nil
        await model.relinkOriginal(source, to: moved).value
        precondition(model.error != nil && model.photo == nil && model.photos == [source])
        let savedAfterRelink = await model.flushDraft(); precondition(savedAfterRelink)
        let afterRelink = try await DraftStore(url: url).load()!
        precondition(afterRelink.activeURL == source)
        checkRetained(afterRelink.entries[0], entry)
        print("PASS: same-SHA RAW profile mismatch rejected on startup and relink; draft retained")
    }

    private static func checkRetained(_ value: DraftEntry, _ before: DraftEntry) {
        precondition(value.recipe == before.recipe && value.saved == before.saved)
        precondition(value.history.undoStack == before.history.undoStack && value.history.redoStack == before.history.redoStack)
        precondition(value.selectedMaskID == before.selectedMaskID)
    }
}
