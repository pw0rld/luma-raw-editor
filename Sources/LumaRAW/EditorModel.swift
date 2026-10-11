import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LumaCore

@MainActor final class EditorModel: ObservableObject {
    @Published var photos: [URL] = []
    @Published var includeSubfolders = true
    private struct Session {
        let sha256: String
        let profile: RAWProfile?
        let settings: Adjustments
        let saved: Adjustments
        let history: EditHistory
    }
    @Published private var sessions: [URL: Session] = [:]
    @Published var photo: PhotoInfo?
    @Published var settings = Adjustments()
    @Published var preview: CGImage?
    // Full-frame preview with all adjustments except the crop, used underneath the crop overlay.
    @Published var cropPreview: CGImage?
    @Published var originalPreview: CGImage?
    @Published private(set) var referencePreview: CGImage?
    @Published private(set) var referenceName: String?
    @Published var matchClusterCount = 3
    @Published var compare = false
    @Published var busy = false
    @Published var rendering = false
    @Published var status = "导入一张照片，开始显影"
    @Published var error: String?
    @Published var history = EditHistory()
    @Published var exportFormat: ExportFormat = .jpeg
    @Published var includeGPS = false
    @Published var selectedMaskID: UUID?
    @Published var showMaskOverlay = true
    private let engine = ImageEngine()
    private var referenceEngine: ImageEngine?
    private var referencePhoto: PhotoInfo?
    private var referenceURLs: Set<URL> = []
    private var previewTask: Task<Void, Never>?
    private var generation = 0
    private var gestureStart: Adjustments?
    private var savedSettings = Adjustments()
    var dirty: Bool { photo != nil && settings != savedSettings }
    var canUndo: Bool { !history.undoStack.isEmpty }
    var canRedo: Bool { !history.redoStack.isEmpty }
    var canMatch: Bool { photo != nil && referencePhoto != nil && !busy }
    var masks: [LocalMask] { settings.localMasks }
    var selectedMask: LocalMask? {
        guard let selectedMaskID else { return nil }
        return settings.localMasks.first { $0.id == selectedMaskID }
    }

    func confirmDiscard() -> Bool {
        let count = photos.filter { isUnsaved($0) }.count
        guard count > 0 else { return true }
        let alert = NSAlert(); alert.messageText = "尚有未保存的编辑配方"
        alert.informativeText = "有 \(count) 张照片的配方尚未保存。退出将丢失这些会话调整，原片不会改变。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "放弃调整")
        return alert.runModal() == .alertSecondButtonReturn
    }
    func importPhoto() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image, .rawImage]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }
    func importReference() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image, .rawImage]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.prompt = "选择参考图"; panel.message = "选择希望接近其色调的照片，可使用 RAW 或普通图片。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openReference(url)
    }
    @discardableResult func openReference(_ inputURL: URL) -> Task<Void, Never> {
        guard !busy else { return Task {} }
        let url = inputURL.resolvingSymlinksInPath().standardizedFileURL
        previewTask?.cancel(); generation += 1; rendering = false
        busy = true; status = "读取参考图…"
        return Task {
            do {
                let candidate = ImageEngine()
                let result = try await candidate.open(url)
                let image = try await candidate.preview(result.initial, profile: result.profile)
                referenceEngine = candidate; referencePhoto = result
                referenceURLs.insert(url); referenceName = url.lastPathComponent; referencePreview = image
                status = "参考图已载入 · 点击一键追色"
            } catch { self.error = error.localizedDescription; status = "参考图读取失败" }
            busy = false
            schedulePreview()
        }
    }
    @discardableResult func applyColorMatch() -> Task<Void, Never> {
        guard let photo, let referencePhoto, let referenceEngine, !busy else { return Task {} }
        if gestureStart != nil { gesture(false) }
        previewTask?.cancel(); generation += 1; rendering = false
        var sourceSettings = settings; sourceSettings.colorMatch = nil
        let clusters = min(5, max(1, matchClusterCount))
        busy = true; status = "分析颜色与明暗分布…"
        return Task {
            do {
                let source = try await engine.analyzeForMatch(sourceSettings, profile: photo.profile, clusterCount: clusters)
                let reference = try await referenceEngine.analyzeForMatch(referencePhoto.initial, profile: referencePhoto.profile, clusterCount: clusters)
                let match = try ColorMatch.make(source: source, reference: reference,
                                               referenceName: referencePhoto.url.lastPathComponent,
                                               referenceSHA256: referencePhoto.sha256)
                let previous = settings; settings.colorMatch = match
                history.record(from: previous, to: settings)
                status = "追色已应用 · \(referencePhoto.url.lastPathComponent) · 可继续调节强度"
            } catch { self.error = error.localizedDescription; status = "追色失败" }
            busy = false
            schedulePreview()
        }
    }
    func clearColorMatch() {
        guard settings.colorMatch != nil, !busy else { return }
        if gestureStart != nil { gesture(false) }
        let previous = settings; settings.colorMatch = nil
        history.record(from: previous, to: settings); schedulePreview()
        status = "已移除追色 · 可撤销"
    }
    func addFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "添加文件夹"
        panel.message = includeSubfolders ? "添加照片（包含子文件夹；忽略隐藏文件）" : "仅添加此文件夹中的照片"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addFolder(url)
    }
    @discardableResult func addFolder(_ url: URL) -> Task<Void, Never> {
        guard !busy else { return Task {} }
        busy = true; status = "扫描文件夹…"
        let recursive = includeSubfolders
        return Task {
            do {
                let files = try await Task.detached(priority: .userInitiated) {
                    try PhotoFolder.scan(url, recursive: recursive)
                }.value
                let existing = Set(photos)
                let added = files.filter { !existing.contains($0) }
                photos.append(contentsOf: added)
                busy = false
                status = "新增 \(added.count) 张 · 共 \(photos.count) 张"
                if files.isEmpty { status = "文件夹中没有支持的照片" }
                if photo == nil, let first = photos.first { await open(first).value }
            } catch { busy = false; self.error = error.localizedDescription; status = "扫描失败" }
        }
    }
    func isUnsaved(_ url: URL) -> Bool {
        if photo?.url == url { return dirty }
        guard let session = sessions[url] else { return false }
        return session.settings != session.saved
    }
    private func stashCurrent() {
        guard let photo else { return }
        if gestureStart != nil { gesture(false) }
        sessions[photo.url] = Session(sha256: photo.sha256, profile: photo.profile, settings: settings, saved: savedSettings, history: history)
    }
    private func protectPhotos(_ destination: URL) throws {
        for original in photos { try ImageEngine.protectOriginal(destination: destination, original: original) }
        for original in referenceURLs { try ImageEngine.protectOriginal(destination: destination, original: original) }
    }
    @discardableResult func open(_ inputURL: URL) -> Task<Void, Never> {
        guard !busy else { return Task {} }
        let url = inputURL.resolvingSymlinksInPath().standardizedFileURL
        if photo?.url == url { return Task {} }
        stashCurrent()
        if !photos.contains(url) { photos.append(url) }
        previewTask?.cancel(); generation += 1; busy = true; status = "读取照片与校验原片…"
        return Task {
            do {
                let result = try await engine.open(url)
                photo = result; settings = result.initial; savedSettings = result.initial
                history = EditHistory(); compare = false; selectedMaskID = nil; preview = nil; cropPreview = nil; originalPreview = nil
                preview = await engine.embeddedThumbnail()
                originalPreview = try await engine.preview(result.initial, profile: result.profile)
                if let session = sessions[url], session.sha256 == result.sha256, session.profile == result.profile {
                    settings = session.settings; savedSettings = session.saved; history = session.history
                } else if sessions[url] != nil {
                    self.error = "此原片或 RAW 解码配置已改变，未自动套用旧调整。"
                }
                selectedMaskID = settings.localMasks.first?.id
                preview = settings == result.initial ? originalPreview : try await engine.preview(settings, profile: result.profile)
                var uncropped = settings; uncropped.cropRect = .full
                cropPreview = try await engine.preview(uncropped, profile: result.profile)
                status = "\(result.isRAW ? "RAW" : "RGB") · \(result.width) × \(result.height) · \(result.backend)"
            } catch { self.error = error.localizedDescription; status = "读取失败" }
            busy = false; rendering = false
            if let path = ProcessInfo.processInfo.environment["LUMA_SMOKE_SNAPSHOT"], preview != nil {
                if let reference = ProcessInfo.processInfo.environment["LUMA_SMOKE_REFERENCE"] {
                    await openReference(URL(fileURLWithPath: reference)).value
                    await applyColorMatch().value
                    await previewTask?.value
                    print(settings.colorMatch != nil && referencePreview != nil && self.error == nil
                          ? "UI_SMOKE_MATCH: reference loaded and color match rendered"
                          : "UI_SMOKE_MATCH: FAILED \(self.error ?? "missing reference or match")")
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
                if let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
                        print("UI_SMOKE: imported, rendered, captured \(path)")
                    }
                }
                NSApp.terminate(nil)
            }
        }
    }
    func set(_ key: WritableKeyPath<Adjustments, Double>, value: Double) {
        let previous = settings
        settings[keyPath: key] = value
        settings.shadows = min(settings.shadows, settings.midtones)
        settings.highlights = max(settings.highlights, settings.midtones)
        if gestureStart == nil { history.record(from: previous, to: settings) }
        schedulePreview()
    }
    var cropRect: CropRect { settings.cropRect }
    func setCropRect(_ proposed: CropRect) {
        let minimum = 0.02
        let width = min(1, max(minimum, proposed.width)), height = min(1, max(minimum, proposed.height))
        let x = min(max(0, proposed.x), 1 - width), y = min(max(0, proposed.y), 1 - height)
        let next = CropRect(x: x, y: y, width: width, height: height)
        guard next != settings.cropRect else { return }
        let previous = settings; settings.cropRect = next
        if gestureStart == nil { history.record(from: previous, to: settings) }
        schedulePreview()
    }
    func resetCrop() {
        guard settings.cropRect != .full else { return }
        let previous = settings; settings.cropRect = .full
        history.record(from: previous, to: settings); schedulePreview()
    }
    func gesture(_ editing: Bool) {
        if editing { gestureStart = settings }
        else if let start = gestureStart { history.record(from: start, to: settings); gestureStart = nil }
    }
    func rotate() {
        let before = settings; settings.quarterTurns = (settings.quarterTurns + 1) % 4
        history.record(from: before, to: settings); schedulePreview()
    }
    func reset() {
        guard let photo else { return }
        let before = settings; settings = photo.initial; history.record(from: before, to: settings); schedulePreview()
    }
    func addMask(kind: LocalMaskKind) {
        guard photo != nil, !busy else { return }
        let before = settings
        let mask = LocalMask(kind: kind)
        settings.localMasks.append(mask)
        selectedMaskID = mask.id
        showMaskOverlay = true
        history.record(from: before, to: settings)
        status = "已添加\(kind == .radial ? "径向" : "线性")蒙版 · 可拖动调整范围"
        schedulePreview()
    }
    func removeSelectedMask() {
        guard let selectedMaskID, let index = settings.localMasks.firstIndex(where: { $0.id == selectedMaskID }), !busy else { return }
        let before = settings
        settings.localMasks.remove(at: index)
        self.selectedMaskID = settings.localMasks.indices.contains(max(0, index - 1)) ? settings.localMasks[max(0, index - 1)].id : settings.localMasks.first?.id
        history.record(from: before, to: settings)
        status = "已删除蒙版 · 可撤销"
        schedulePreview()
    }
    func selectMask(_ id: UUID) {
        selectedMaskID = id
        showMaskOverlay = true
    }
    func setSelectedMask(_ key: WritableKeyPath<LocalMask, Double>, value: Double) {
        guard let selectedMaskID, let index = settings.localMasks.firstIndex(where: { $0.id == selectedMaskID }) else { return }
        let before = settings
        settings.localMasks[index][keyPath: key] = value
        if gestureStart == nil { history.record(from: before, to: settings) }
        schedulePreview()
    }
    func setSelectedMask(_ key: WritableKeyPath<LocalMask, Bool>, value: Bool) {
        guard let selectedMaskID, let index = settings.localMasks.firstIndex(where: { $0.id == selectedMaskID }) else { return }
        let before = settings
        settings.localMasks[index][keyPath: key] = value
        if gestureStart == nil { history.record(from: before, to: settings) }
        schedulePreview()
    }
    func setSelectedMask(_ value: LocalMask) {
        guard let index = settings.localMasks.firstIndex(where: { $0.id == value.id }) else { return }
        let before = settings
        settings.localMasks[index] = value
        if gestureStart == nil { history.record(from: before, to: settings) }
        schedulePreview()
    }
    func undo() { if let value = history.undo(current: settings) { settings = value; schedulePreview() } }
    func redo() { if let value = history.redo(current: settings) { settings = value; schedulePreview() } }
    private func schedulePreview() {
        guard let photo else { return }
        previewTask?.cancel(); generation += 1
        let token = generation, state = settings
        rendering = true
        previewTask = Task {
            do {
                try await Task.sleep(nanoseconds: 90_000_000)
                let image = try await engine.preview(state, profile: photo.profile)
                var uncroppedState = state; uncroppedState.cropRect = .full
                let uncroppedImage = try await engine.preview(uncroppedState, profile: photo.profile)
                try Task.checkCancellation()
                guard token == generation else { return }
                preview = image; cropPreview = uncroppedImage; rendering = false
            } catch is CancellationError { }
            catch { if token == generation { self.error = error.localizedDescription; rendering = false } }
        }
    }
    func saveRecipe() {
        guard let photo, !busy else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = photo.url.deletingPathExtension().lastPathComponent + ".luma.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try protectPhotos(url)
            let recipe = Recipe(sourceName: photo.url.lastPathComponent, sourceSHA256: photo.sha256, rawProfile: photo.profile, adjustments: settings)
            try recipe.encoded().write(to: url, options: .atomic)
            savedSettings = settings; status = "配方已保存 · \(url.lastPathComponent)"
        } catch { self.error = error.localizedDescription }
    }
    func loadRecipe() {
        guard let photo, !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let recipe = try Recipe.decode(Data(contentsOf: url))
            guard recipe.sourceSHA256 == photo.sha256 else { throw EditorError.message("配方与当前原片不匹配。请先导入配方对应的原片：\(recipe.sourceName)") }
            guard recipe.rawProfile == photo.profile else { throw EditorError.message("此配方的 RAW 默认显影配置与本机不同，不能保证重现。请使用创建配方时的系统版本。") }
            history.record(from: settings, to: recipe.adjustments); settings = recipe.adjustments
            selectedMaskID = settings.localMasks.first?.id
            savedSettings = settings; schedulePreview(); status = "配方已恢复 · 可撤销"
        } catch { self.error = error.localizedDescription }
    }
    func exportPhoto() {
        guard let photo, !busy else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [exportFormat == .jpeg ? .jpeg : .tiff]
        panel.nameFieldStringValue = photo.url.deletingPathExtension().lastPathComponent + "-edited." + (exportFormat == .jpeg ? "jpg" : "tiff")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try protectPhotos(url) } catch { self.error = error.localizedDescription; return }
        let state = settings, format = exportFormat, gps = includeGPS
        busy = true; status = "全分辨率渲染与导出…"
        Task {
            do {
                try await engine.export(state, profile: photo.profile, to: url, format: format, includeGPS: gps)
                status = "已导出 \(url.lastPathComponent) · sRGB · \(format == .tiff ? "16" : "8") bit"
            } catch { self.error = error.localizedDescription; status = "导出失败" }
            busy = false
        }
    }
}
