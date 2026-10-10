import Foundation
import LumaCore

@main struct FolderCheck {
    @MainActor static func main() async throws {
        let samples = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("image2.jpg")
        let second = root.appendingPathComponent("image10.jpg")
        let third = nested.appendingPathComponent("z-raw.dng")
        for url in [first, second, root.appendingPathComponent(".hidden.jpg")] {
            try FileManager.default.copyItem(at: samples.appendingPathComponent("orientation-test.jpg"), to: url)
        }
        try FileManager.default.copyItem(at: samples.appendingPathComponent("synthetic-bayer.dng"), to: third)
        try Data("not a photo".utf8).write(to: root.appendingPathComponent("notes.txt"))
        let shallow = try PhotoFolder.scan(root, recursive: false)
        precondition(shallow == [first, second], "Natural sorting / shallow scan / filtering failed")
        let recursive = try PhotoFolder.scan(root, recursive: true)
        precondition(recursive == [first, second, third], "Recursive scan failed")
        let model = EditorModel()
        await model.addFolder(root).value
        precondition(model.photos == recursive && model.photo?.url == first)
        model.set(\.exposure, value: 1.25)
        await model.open(second).value
        precondition(model.settings.exposure == 0 && model.isUnsaved(first) && !model.dirty)
        model.set(\.saturation, value: 0.2)
        await model.open(first).value
        precondition(model.settings.exposure == 1.25 && model.settings.saturation == 1 && model.canUndo)
        precondition(model.isUnsaved(second))
        model.undo()
        precondition(model.settings.exposure == 0 && !model.dirty && model.canRedo)
        await model.open(second).value
        precondition(model.settings.saturation == 0.2 && model.dirty)
        await model.open(first).value
        precondition(model.canRedo && !model.dirty)
        model.redo()
        precondition(model.settings.exposure == 1.25 && model.dirty)
        await model.addFolder(root).value
        precondition(model.photos.count == 3 && model.photo?.url == first && model.settings.exposure == 1.25)
        await model.open(root.appendingPathComponent("missing.jpg")).value
        precondition(model.photo?.url == first && model.settings.exposure == 1.25 && model.error != nil)
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        await model.addFolder(empty).value
        precondition(model.photo?.url == first && model.settings.exposure == 1.25)
        print("PASS: folder scanning/filtering/natural order/recursion/deduplication; per-photo edits, dirty state, undo/redo; failed import and empty folder preservation")
    }
}
