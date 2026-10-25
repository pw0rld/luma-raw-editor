import Foundation

public struct DraftEntry: Codable {
    public var sourceURL: URL
    public var recipe: Recipe
    public var saved: Adjustments
    public var history: EditHistory
    public var selectedMaskID: UUID?
    public init(sourceURL: URL, recipe: Recipe, saved: Adjustments, history: EditHistory, selectedMaskID: UUID?) {
        self.sourceURL = sourceURL; self.recipe = recipe; self.saved = saved
        self.history = history; self.selectedMaskID = selectedMaskID
    }
}

public struct WorkspaceDraft: Codable {
    public var version = 1
    public var photos: [URL]
    public var activeURL: URL?
    public var entries: [DraftEntry]
    public init(photos: [URL], activeURL: URL?, entries: [DraftEntry]) {
        self.photos = photos; self.activeURL = activeURL; self.entries = entries
    }
    public mutating func validateAndMigrate() throws {
        let photoSet = Set(photos)
        guard version == 1, photos.count <= 10000, entries.count <= 10000,
              photos.allSatisfy(\.isFileURL), photoSet.count == photos.count,
              Set(entries.map(\.sourceURL)).count == entries.count,
              entries.allSatisfy({ $0.sourceURL.isFileURL && photoSet.contains($0.sourceURL) }) else {
            throw EditorError.message("自动草稿格式无效。")
        }
        for index in entries.indices {
            entries[index].recipe = try Recipe.decode(JSONEncoder().encode(entries[index].recipe))
            try entries[index].saved.validate()
            guard entries[index].history.undoStack.count <= 100,
                  entries[index].history.redoStack.count <= 100 else { throw EditorError.message("草稿历史过长。") }
            for state in entries[index].history.undoStack + entries[index].history.redoStack { try state.validate() }
        }
    }
}

/// Atomic, serialized writes; callers may inject a temporary URL for checks.
public actor DraftStore {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Luma RAW/Drafts/workspace.json")
    }
    private let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> WorkspaceDraft? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 64 * 1024 * 1024 else { throw EditorError.message("自动草稿文件过大。") }
        var value = try JSONDecoder().decode(WorkspaceDraft.self, from: Data(contentsOf: url))
        try value.validateAndMigrate()
        return value
    }
    public func save(_ draft: WorkspaceDraft) throws {
        var checked = draft; try checked.validateAndMigrate()
        let data = try JSONEncoder().encode(checked)
        guard data.count <= 64 * 1024 * 1024 else { throw EditorError.message("自动草稿超过大小限制。请手动保存配方。") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
