import SwiftUI
import AppKit
import LumaCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: EditorModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if ProcessInfo.processInfo.environment["LUMA_SMOKE_SNAPSHOT"] != nil { return .terminateNow }
        if model?.busy == true { return .terminateCancel }
        guard let model else { return .terminateNow }
        Task { @MainActor in NSApp.reply(toApplicationShouldTerminate: await model.prepareToQuit()) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main struct LumaRAWApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = EditorModel(draftURL: ProcessInfo.processInfo.environment["LUMA_DRAFT_PATH"]
        .map { URL(fileURLWithPath: $0) } ?? DraftStore.defaultURL)
    var body: some Scene {
        Window("Luma RAW", id: "editor") {
            EditorView(model: model).onAppear {
                delegate.model = model
                if let folder = ProcessInfo.processInfo.environment["LUMA_SMOKE_FOLDER"], model.photos.isEmpty {
                    model.addFolder(URL(fileURLWithPath: folder))
                } else if let path = ProcessInfo.processInfo.environment["LUMA_SMOKE_INPUT"], model.photo == nil {
                    model.open(URL(fileURLWithPath: path))
                } else {
                    Task { await model.restoreDrafts() }
                }
            }
                .frame(minWidth: 1000, minHeight: 720)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("导入照片…", action: model.importPhoto).keyboardShortcut("o").disabled(model.busy)
                Button("添加文件夹…", action: { model.addFolder() }).keyboardShortcut("o", modifiers: [.command, .option]).disabled(model.busy)
            }
            CommandGroup(replacing: .saveItem) {
                Button("保存配方…", action: model.saveRecipe).keyboardShortcut("s")
                    .disabled(model.photo == nil || model.busy)
                Button("恢复配方…", action: model.loadRecipe).keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.photo == nil || model.busy)
                Button("导出照片…", action: model.exportPhoto).keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.photo == nil || model.busy)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("撤销", action: model.undo).keyboardShortcut("z").disabled(!model.canUndo || model.busy)
                Button("重做", action: model.redo).keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedo || model.busy)
            }
            CommandMenu("追色") {
                Button("导入参考图…", action: model.importReference).keyboardShortcut("r", modifiers: [.command, .option]).disabled(model.busy)
                Button("一键追色", action: { model.applyColorMatch() }).keyboardShortcut("m", modifiers: [.command, .shift]).disabled(!model.canMatch)
                Button("移除追色", action: model.clearColorMatch).disabled(model.settings.colorMatch == nil || model.busy)
            }
        }
    }
}

struct EditorView: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: "camera.aperture").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("LUMA RAW").font(.system(size: 14, weight: .bold, design: .rounded)).tracking(2)
                    Text(model.photo?.url.lastPathComponent ?? "单张照片 · 非破坏性显影").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if model.dirty { Circle().fill(.orange).frame(width: 6, height: 6).help("配方尚未保存") }
                Spacer()
                Button(action: model.importPhoto) { Label("导入", systemImage: "plus") }
                Button(action: { model.addFolder() }) { Label("添加文件夹", systemImage: "folder.badge.plus") }
                Button(action: model.importReference) { Label("参考图", systemImage: "photo.on.rectangle") }
                Button(action: model.saveRecipe) { Label("保存配方", systemImage: "arrow.up.doc") }.disabled(model.photo == nil)
                Button(action: model.loadRecipe) { Image(systemName: "arrow.down.doc") }.help("恢复 JSON 配方").disabled(model.photo == nil)
                Button(action: model.exportPhoto) { Label("导出", systemImage: "square.and.arrow.up") }.buttonStyle(AccentButtonStyle()).disabled(model.photo == nil)
            }.padding(18).disabled(model.busy)
            Divider()
            HStack(spacing: 0) {
                if !model.photos.isEmpty {
                    photoList.frame(width: 200)
                    Divider()
                }
                VStack(spacing: 0) {
                    HStack(spacing: 1) {
                        if let reference = model.referencePreview {
                            PhotoPreviewPane(image: reference, title: "参考图", subtitle: model.referenceName)
                        }
                        targetCanvas
                    }.background(Color(white: 0.20))
                    HStack {
                        Button(action: model.undo) { Image(systemName: "arrow.uturn.backward") }.disabled(!model.canUndo)
                        Button(action: model.redo) { Image(systemName: "arrow.uturn.forward") }.disabled(!model.canRedo)
                        Picker("编辑工具", selection: $model.tool) {
                            ForEach(EditorTool.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).frame(width: 180)
                        Spacer()
                        Toggle("查看原片", isOn: $model.compare).toggleStyle(.switch).controlSize(.small).keyboardShortcut("\\", modifiers: [])
                        Spacer()
                        Text("适合窗口 · SDR").font(.caption).foregroundStyle(.secondary)
                    }.padding(14).disabled(model.photo == nil || model.busy)
                }
                Divider()
                inspector.frame(width: 290)
            }
            Divider()
            HStack {
                Text(model.status).lineLimit(1)
                Spacer()
                Text(model.draftStatus).lineLimit(1).help(model.draftStatus)
                Text("原片只读").foregroundStyle(.orange.opacity(0.8))
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 9)
        }
        .buttonStyle(.borderless)
        .alert("无法完成操作", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private var targetCanvas: some View {
        ZStack {
            if model.compare, let image = model.originalPreview {
                PhotoPreviewPane(image: image, title: "原片显影",
                                 subtitle: model.photo?.url.lastPathComponent,
                                 progress: model.rendering || model.busy)
            } else if let image = model.cropPreview ?? model.preview {
                if model.tool == .browse || !model.previewIsFullFrame {
                    PhotoPreviewPane(image: image, title: "调整后 · 成片构图",
                                     subtitle: model.photo?.url.lastPathComponent, progress: model.rendering || model.busy)
                } else { ZStack {
                    CropPreviewPane(image: image,
                                    title: model.settings.colorMatch == nil ? "调整后" : "调整后 · 已追色",
                                    subtitle: model.photo?.url.lastPathComponent,
                                    progress: model.rendering || model.busy,
                                    cropRect: model.cropRect,
                                    canEdit: model.tool == .crop && model.canEditCanvas,
                                    onChange: { model.setCropRect($0) },
                                    onEditingChanged: model.gesture)
                        .allowsHitTesting(model.tool == .crop && model.canEditCanvas)
                    if model.tool == .mask, let mask = model.selectedMask {
                        MaskOverlayPane(image: image, mask: mask, overlay: model.showMaskOverlay ? model.maskOverlayPreview : nil,
                                        onChange: { model.setSelectedMask($0) },
                                        onEditingChanged: model.gesture)
                            .id(mask.id)
                    }
                }.allowsHitTesting(model.canEditCanvas) }
            } else {
                Color(white: 0.075)
                VStack(spacing: 18) {
                    Image(systemName: "camera.aperture").font(.system(size: 60, weight: .ultraLight)).foregroundStyle(.orange)
                    Text("给照片一点光").font(.system(size: 25, weight: .light))
                    Text("RAW / DNG / JPEG / TIFF / PNG / HEIC").font(.caption).foregroundStyle(.secondary)
                    Button("导入照片…", action: model.importPhoto).buttonStyle(AccentButtonStyle()).disabled(model.busy)
                    Button("添加文件夹…", action: { model.addFolder() }).disabled(model.busy)
                    Toggle("包含子文件夹", isOn: $model.includeSubfolders).font(.caption).fixedSize().disabled(model.busy)
                    if model.busy { ProgressView().controlSize(.small) }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var photoList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("照片 · \(model.photos.count)").font(.headline).padding(.horizontal, 12)
            Toggle("包含子文件夹", isOn: $model.includeSubfolders).font(.caption).padding(.horizontal, 12)
                .help("下次添加文件夹时使用")
            ScrollViewReader { proxy in
                List {
                    ForEach(model.photos, id: \.self) { url in
                        Button(action: { model.open(url) }) {
                            HStack(spacing: 8) {
                                Image(systemName: "photo").foregroundStyle(model.photo?.url == url ? .orange : .secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                                    Text(url.deletingLastPathComponent().lastPathComponent).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if model.isUnsaved(url) { Circle().fill(.orange).frame(width: 5, height: 5) }
                            }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(url.path).id(url)
                            .listRowBackground(model.photo?.url == url ? Color.orange.opacity(0.16) : Color.clear)
                    }
                }.listStyle(.plain)
                    .onChange(of: model.photo?.url) { url in if let url { proxy.scrollTo(url) } }
            }
            Text("切换保留调整与撤销记录\n退出前请分别保存配方")
                .font(.caption2).foregroundStyle(.secondary).padding(12)
        }.padding(.top, 16).background(Color(white: 0.10)).disabled(model.busy)
    }
    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack { Text("显影").font(.title3.weight(.semibold)); Spacer(); Button("重置", action: model.reset).font(.caption) }
                colorMatchControls
                Divider()
                masksControls
                Divider()
                groupTitle("白平衡", symbol: "thermometer.medium")
                slider("色温", key: \.temperature, range: 2000...50000, format: "%.0f K")
                slider("色调", key: \.tint, range: -150...150, format: "%+.0f")
                Text(model.photo?.isRAW == true ? "初始值来自相机白平衡" : "普通图片以 6500 K 为相对中性点").font(.caption2).foregroundStyle(.secondary)
                Divider()
                groupTitle("光线与颜色", symbol: "sun.max")
                slider("曝光", key: \.exposure, range: -5...5, format: "%+.2f EV")
                slider("饱和度", key: \.saturation, range: 0...2, format: "%.2f")
                Divider()
                groupTitle("色调曲线", symbol: "point.topleft.down.to.point.bottomright.curvepath")
                CurveView(settings: model.settings).frame(height: 105)
                slider("暗部", key: \.shadows, range: 0...model.settings.midtones, format: "%.2f")
                slider("中间调", key: \.midtones, range: 0.01...0.99, format: "%.2f")
                slider("亮部", key: \.highlights, range: model.settings.midtones...1, format: "%.2f")
                Divider()
                HStack { groupTitle("构图", symbol: "crop.rotate"); Spacer(); Button("旋转 90°", action: model.rotate).font(.caption) }
                Button(model.tool == .crop ? "完成裁剪" : "编辑裁剪") { model.tool = model.tool == .crop ? .browse : .crop }
                Button(action: model.resetCrop) {
                    Label("重置裁剪框", systemImage: "arrow.counterclockwise")
                }.font(.caption)
                Text("切换到裁剪工具后拖动边框；四角可自由调整比例。浏览工具显示最终成片。")
                    .font(.caption2).foregroundStyle(.secondary)
                Divider()
                groupTitle("导出", symbol: "square.and.arrow.up")
                Picker("格式", selection: $model.exportFormat) { Text("JPEG · 8 bit").tag(ExportFormat.jpeg); Text("TIFF · 16 bit").tag(ExportFormat.tiff) }.labelsHidden()
                Toggle("保留 GPS 位置", isOn: $model.includeGPS).font(.caption)
                Text("sRGB 配置 · 保留可用 EXIF/IPTC\n透明区域合成黑底；原片不覆盖。").font(.caption2).foregroundStyle(.secondary)
            }.padding(20)
        }.background(Color(white: 0.115)).disabled(model.photo == nil || model.busy)
    }
    private var colorMatchControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            groupTitle("参考图追色", symbol: "paintpalette")
            Button(action: model.importReference) {
                Label(model.referenceName == nil ? "导入参考图…" : "更换参考图…", systemImage: "photo.on.rectangle")
            }.font(.caption)
            if let referenceName = model.referenceName {
                HStack {
                    Text("参考：\(referenceName)").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(); Button("关闭", action: model.clearReference).font(.caption)
                }
            }
            HStack {
                Text("颜色分组").font(.caption)
                Picker("颜色分组", selection: $model.matchClusterCount) {
                    ForEach(1...5, id: \.self) { count in Text("\(count)").tag(count) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            Button(action: { model.applyColorMatch() }) {
                Label("一键追色", systemImage: "wand.and.stars")
            }.buttonStyle(AccentButtonStyle()).disabled(!model.canMatch)
            if let match = model.settings.colorMatch {
                HStack(alignment: .firstTextBaseline) {
                    Text("已应用：\(match.referenceName)").font(.caption2).foregroundStyle(.orange).lineLimit(2)
                    Spacer(minLength: 2)
                    Button("移除", action: model.clearColorMatch).font(.caption)
                }
                ClusterPalette(title: "当前颜色", clusters: match.sourceClusters)
                ClusterPalette(title: "参考颜色", clusters: match.referenceClusters)
                slider("颜色强度", key: \.matchColorStrength, range: 0...1, format: "%.0f%%", displayScale: 100)
                slider("明暗匹配", key: \.matchLuminanceStrength, range: 0...1, format: "%.0f%%", displayScale: 100)
                slider("颜色占比权重", key: \.matchDominance, range: 0...1, format: "%.0f%%", displayScale: 100)
                Text("重新追色使用当前基础调整；更换分组后需再次追色。配方包含匹配结果，恢复和导出无需参考图。").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("借鉴颜色分簇映射；先匹配颜色，按需加入明暗。不同场景或肤色请降低强度并微调。").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private var masksControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            maskHeader
            maskOverlayToggle
            maskContent
        }
    }
    private var maskOverlayToggle: some View {
        Toggle("显示画布覆盖", isOn: $model.showMaskOverlay).font(.caption)
    }
    private var maskHeader: some View {
        HStack {
            groupTitle("蒙版", symbol: "circle.lefthalf.filled")
            Spacer()
            Menu {
                Button { model.addMask(kind: .radial) } label: { Label("径向蒙版", systemImage: "circle.dashed") }
                Button { model.addMask(kind: .linear) } label: { Label("线性蒙版", systemImage: "line.diagonal") }
            } label: { Label("新建", systemImage: "plus") }.font(.caption).disabled(!model.canAddMask)
        }
    }
    @ViewBuilder private var maskContent: some View {
        if model.masks.isEmpty {
            Text("新建径向或线性蒙版，在画布上拖动位置，再调整局部曝光和颜色.")
                .font(.caption2).foregroundStyle(.secondary)
        } else {
            maskList
            if let mask = model.selectedMask { selectedMaskControls(mask) }
        }
    }
    private var maskList: some View {
        VStack(spacing: 4) {
            ForEach(model.masks) { mask in maskRow(mask) }
        }
    }
    private func maskRow(_ mask: LocalMask) -> some View {
        Button { model.selectMask(mask.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: mask.kind == .radial ? "circle.dashed" : "line.diagonal")
                    .foregroundStyle(mask.enabled ? .orange : .secondary)
                Text("\(mask.kind == .radial ? "径向蒙版" : "线性蒙版") \((model.masks.firstIndex(where: { $0.id == mask.id }) ?? 0) + 1)")
                Spacer()
                Text(mask.enabled ? "启用" : "停用")
                    .foregroundStyle(mask.enabled ? Color.secondary : Color.orange).font(.caption2)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(model.selectedMaskID == mask.id ? Color.orange.opacity(0.18) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }
    private func selectedMaskControls(_ mask: LocalMask) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack {
                Toggle("启用", isOn: maskBoolBinding(\.enabled)).font(.caption)
                Spacer()
                Button("删除", role: .destructive, action: model.removeSelectedMask).font(.caption)
            }
            Toggle("反向蒙版", isOn: maskBoolBinding(\.inverted)).font(.caption)
            maskSlider("局部曝光", key: \.exposure, range: -5...5, format: "%+.2f EV")
            maskSlider("色温偏移", key: \.temperatureDelta, range: -4000...4000, format: "%+.0f K")
            maskSlider("色调偏移", key: \.tintDelta, range: -150...150, format: "%+.0f")
            maskSlider("饱和度", key: \.saturation, range: 0...2, format: "%.2f")
            maskSlider("强度", key: \.opacity, range: 0...1, format: "%.0f%%", displayScale: 100)
            maskSlider("羽化", key: \.feather, range: 0...1, format: "%.0f%%", displayScale: 100)
            if mask.kind == .linear {
                maskSlider("渐变方向", key: \.angle, range: -180...180, format: "%+.0f°")
                if mask.legacyLinearFalloff {
                    Button("转换为新版渐变宽度") {
                        var next = mask; next.legacyLinearFalloff = false; model.setSelectedMask(next)
                    }.font(.caption)
                }
            }
            Text("拖动框体或四角调整范围。线性渐变以矩形为范围，羽化向外平滑扩展；覆盖色显示实际权重。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func maskBoolBinding(_ key: WritableKeyPath<LocalMask, Bool>) -> Binding<Bool> {
        Binding(get: { model.selectedMask?[keyPath: key] ?? false }, set: { value in
            model.gesture(true); model.setSelectedMask(key, value: value); model.gesture(false)
        })
    }
    private func groupTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
    }
    private func slider(_ title: String, key: WritableKeyPath<Adjustments, Double>, range: ClosedRange<Double>, format: String, displayScale: Double = 1) -> some View {
        VStack(spacing: 6) {
            HStack { Text(title); Spacer(); Text(String(format: format, model.settings[keyPath: key] * displayScale)).monospacedDigit().foregroundStyle(.secondary) }.font(.caption)
            Slider(value: Binding(get: { model.settings[keyPath: key] }, set: { model.set(key, value: $0) }), in: range, onEditingChanged: model.gesture).tint(.orange)
        }
    }
    private func maskSlider(_ title: String, key: WritableKeyPath<LocalMask, Double>, range: ClosedRange<Double>, format: String, displayScale: Double = 1) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title); Spacer()
                Text(String(format: format, (model.selectedMask?[keyPath: key] ?? range.lowerBound) * displayScale)).monospacedDigit().foregroundStyle(.secondary)
            }.font(.caption)
            Slider(value: Binding(get: {
                model.selectedMask?[keyPath: key] ?? range.lowerBound
            }, set: { value in
                model.setSelectedMask(key, value: value)
            }), in: range, onEditingChanged: model.gesture).tint(.orange)
        }
    }
}
struct PhotoPreviewPane: View {
    let image: CGImage
    let title: String
    let subtitle: String?
    var progress = false
    var body: some View {
        ZStack {
            Color(white: 0.075)
            GeometryReader { proxy in
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }.padding(26)
            VStack {
                HStack {
                    Text(title).font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: Capsule())
                    Spacer()
                    if progress { ProgressView().controlSize(.small).padding(8) }
                }
                Spacer()
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 10).padding(.vertical, 4).background(.black.opacity(0.5), in: Capsule())
                }
            }.padding(14)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Image canvas with a normalized, free-form crop box. The model owns the
/// normalized rectangle; this view only translates pointer movement into it.
private struct CropPreviewPane: View {
    let image: CGImage
    let title: String
    let subtitle: String?
    let progress: Bool
    let cropRect: CropRect
    let canEdit: Bool
    let onChange: (CropRect) -> Void
    let onEditingChanged: (Bool) -> Void

    @State private var gestureStart: CropRect?
    @State private var interaction: CropInteraction?

    private let inset: CGFloat = 26
    private let minimumCropFraction = 0.02

    private enum Corner: Hashable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private enum CropInteraction {
        case move
        case resize(Corner)
    }

    var body: some View {
        ZStack {
            Color(white: 0.075)
            GeometryReader { proxy in
                let imageRect = fittedImageRect(in: proxy.size)
                let visibleCrop = cropFrame(for: cropRect, in: imageRect)

                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)

                CropShade(cropFrame: visibleCrop, canvas: proxy.size)

                Path { path in
                    path.move(to: CGPoint(x: visibleCrop.minX + visibleCrop.width / 3, y: visibleCrop.minY))
                    path.addLine(to: CGPoint(x: visibleCrop.minX + visibleCrop.width / 3, y: visibleCrop.maxY))
                    path.move(to: CGPoint(x: visibleCrop.minX + visibleCrop.width * 2 / 3, y: visibleCrop.minY))
                    path.addLine(to: CGPoint(x: visibleCrop.minX + visibleCrop.width * 2 / 3, y: visibleCrop.maxY))
                    path.move(to: CGPoint(x: visibleCrop.minX, y: visibleCrop.minY + visibleCrop.height / 3))
                    path.addLine(to: CGPoint(x: visibleCrop.maxX, y: visibleCrop.minY + visibleCrop.height / 3))
                    path.move(to: CGPoint(x: visibleCrop.minX, y: visibleCrop.minY + visibleCrop.height * 2 / 3))
                    path.addLine(to: CGPoint(x: visibleCrop.maxX, y: visibleCrop.minY + visibleCrop.height * 2 / 3))
                }
                .stroke(Color.white.opacity(canEdit ? 0.38 : 0.15), lineWidth: 1)

                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .frame(width: visibleCrop.width, height: visibleCrop.height)
                    .position(x: visibleCrop.midX, y: visibleCrop.midY)
                    .gesture(moveGesture(imageRect: imageRect))

                RoundedRectangle(cornerRadius: 1)
                    .stroke(canEdit ? Color.white : Color.white.opacity(0.35), lineWidth: 2)
                    .frame(width: visibleCrop.width, height: visibleCrop.height)
                    .position(x: visibleCrop.midX, y: visibleCrop.midY)

                if canEdit {
                    ForEach([Corner.topLeft, .topRight, .bottomLeft, .bottomRight], id: \.self) { corner in
                        CropHandle()
                            .position(handlePosition(corner, frame: visibleCrop))
                            .gesture(resizeGesture(corner, imageRect: imageRect))
                    }
                }
            }
            VStack {
                HStack {
                    Text(title).font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: Capsule())
                    Spacer()
                    if progress { ProgressView().controlSize(.small).padding(8) }
                }
                Spacer()
                HStack {
                    if canEdit {
                        Text("拖动边框调整裁剪 · 四角自由裁剪")
                            .font(.caption2).foregroundStyle(.white.opacity(0.72))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(.black.opacity(0.48), in: Capsule())
                    }
                    Spacer()
                    if let subtitle {
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .padding(.horizontal, 10).padding(.vertical, 4).background(.black.opacity(0.5), in: Capsule())
                    }
                }
            }.padding(14)
        }
        .padding(inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fittedImageRect(in canvas: CGSize) -> CGRect {
        let available = CGSize(width: max(1, canvas.width), height: max(1, canvas.height))
        let imageRatio = CGFloat(image.width) / CGFloat(max(1, image.height))
        let availableRatio = available.width / available.height
        if imageRatio >= availableRatio {
            let width = available.width
            let height = width / imageRatio
            return CGRect(x: 0, y: (available.height - height) / 2, width: width, height: height)
        } else {
            let height = available.height
            let width = height * imageRatio
            return CGRect(x: (available.width - width) / 2, y: 0, width: width, height: height)
        }
    }

    private func cropFrame(for rect: CropRect, in imageRect: CGRect) -> CGRect {
        CGRect(x: imageRect.minX + imageRect.width * CGFloat(rect.x),
               y: imageRect.minY + imageRect.height * CGFloat(rect.y),
               width: imageRect.width * CGFloat(rect.width),
               height: imageRect.height * CGFloat(rect.height))
    }

    private func handlePosition(_ corner: Corner, frame: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: frame.minX, y: frame.minY)
        case .topRight: return CGPoint(x: frame.maxX, y: frame.minY)
        case .bottomLeft: return CGPoint(x: frame.minX, y: frame.maxY)
        case .bottomRight: return CGPoint(x: frame.maxX, y: frame.maxY)
        }
    }

    private func moveGesture(imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if gestureStart == nil {
                    gestureStart = cropRect
                    interaction = .move
                    onEditingChanged(true)
                }
                guard let start = gestureStart else { return }
                let dx = Double(value.translation.width / max(1, imageRect.width))
                let dy = Double(value.translation.height / max(1, imageRect.height))
                let x = min(1 - start.width, max(0, start.x + dx))
                let y = min(1 - start.height, max(0, start.y + dy))
                onChange(CropRect(x: x, y: y, width: start.width, height: start.height))
            }
            .onEnded { _ in
                gestureStart = nil
                interaction = nil
                onEditingChanged(false)
            }
    }

    private func resizeGesture(_ corner: Corner, imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if gestureStart == nil {
                    gestureStart = cropRect
                    interaction = .resize(corner)
                    onEditingChanged(true)
                }
                guard let start = gestureStart else { return }
                let dx = Double(value.translation.width / max(1, imageRect.width))
                let dy = Double(value.translation.height / max(1, imageRect.height))
                onChange(resized(start, corner: corner, dx: dx, dy: dy))
            }
            .onEnded { _ in
                gestureStart = nil
                interaction = nil
                onEditingChanged(false)
            }
    }

    private func resized(_ start: CropRect, corner: Corner, dx: Double, dy: Double) -> CropRect {
        let minimum = minimumCropFraction
        var left = start.x
        var top = start.y
        var right = start.x + start.width
        var bottom = start.y + start.height
        switch corner {
        case .topLeft:
            left = min(right - minimum, max(0, start.x + dx))
            top = min(bottom - minimum, max(0, start.y + dy))
        case .topRight:
            right = max(left + minimum, min(1, start.x + start.width + dx))
            top = min(bottom - minimum, max(0, start.y + dy))
        case .bottomLeft:
            left = min(right - minimum, max(0, start.x + dx))
            bottom = max(top + minimum, min(1, start.y + start.height + dy))
        case .bottomRight:
            right = max(left + minimum, min(1, start.x + start.width + dx))
            bottom = max(top + minimum, min(1, start.y + start.height + dy))
        }
        return CropRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

private struct CropHandle: View {
    var body: some View {
        Circle()
            .fill(Color.clear)
            .frame(width: 28, height: 28)
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.7), radius: 2)
            }
            .contentShape(Rectangle())
    }
}

/// Interactive first-generation local mask overlay. Coordinates match LocalMask's
/// normalized top-left coordinate system and the crop canvas's fitted image.
private struct MaskOverlayPane: View {
    let image: CGImage
    let mask: LocalMask
    let overlay: CGImage?
    let onChange: (LocalMask) -> Void
    let onEditingChanged: (Bool) -> Void
    @State private var startMask: LocalMask?

    private let inset: CGFloat = 26

    var body: some View {
        GeometryReader { proxy in
            let imageRect = fittedImageRect(in: proxy.size)
            let frame = maskFrame(mask, in: imageRect)
            ZStack {
                if let overlay {
                    Image(decorative: overlay, scale: 1).resizable()
                        .frame(width: imageRect.width, height: imageRect.height)
                        .position(x: imageRect.midX, y: imageRect.midY).allowsHitTesting(false)
                }
                maskShape(frame: frame, imageRect: imageRect)
                    .allowsHitTesting(false)
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .gesture(moveGesture(imageRect: imageRect))
                MaskHandle().position(x: frame.midX, y: frame.midY)
                    .gesture(moveGesture(imageRect: imageRect))
                ForEach(MaskCorner.allCases, id: \.self) { corner in
                    MaskHandle()
                        .position(handlePosition(corner, frame: frame))
                        .gesture(resizeGesture(corner, imageRect: imageRect))
                }
            }
        }
        .clipped()
        .padding(inset)
    }

    @ViewBuilder private func maskShape(frame: CGRect, imageRect: CGRect) -> some View {
        let color = mask.inverted ? Color.purple : Color.orange
        if mask.kind == .radial {
            Ellipse()
                .stroke(color.opacity(0.95), style: StrokeStyle(lineWidth: 2, dash: [7, 4]))
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
            Ellipse()
                .stroke(color.opacity(0.65), lineWidth: 1)
                .frame(width: frame.width * (1 - mask.feather), height: frame.height * (1 - mask.feather))
                .position(x: frame.midX, y: frame.midY)
        } else {
            RoundedRectangle(cornerRadius: 2)
                .stroke(color.opacity(0.95), style: StrokeStyle(lineWidth: 2, dash: [7, 4]))
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
            Path { path in
                let geometry = MaskGeometry(mask, imageSize: imageRect.size)
                let points = geometry.linearEndpoints
                path.move(to: CGPoint(x: imageRect.minX + points.start.x, y: imageRect.minY + points.start.y))
                path.addLine(to: CGPoint(x: imageRect.minX + points.end.x, y: imageRect.minY + points.end.y))
            }.stroke(color.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
    }

    private func fittedImageRect(in canvas: CGSize) -> CGRect {
        let available = CGSize(width: max(1, canvas.width), height: max(1, canvas.height))
        let imageRatio = CGFloat(image.width) / CGFloat(max(1, image.height))
        let availableRatio = available.width / available.height
        if imageRatio >= availableRatio {
            let width = available.width
            let height = width / imageRatio
            return CGRect(x: 0, y: (available.height - height) / 2, width: width, height: height)
        } else {
            let height = available.height
            let width = height * imageRatio
            return CGRect(x: (available.width - width) / 2, y: 0, width: width, height: height)
        }
    }

    private func maskFrame(_ mask: LocalMask, in imageRect: CGRect) -> CGRect {
        CGRect(x: imageRect.minX + imageRect.width * CGFloat(mask.x),
               y: imageRect.minY + imageRect.height * CGFloat(mask.y),
               width: imageRect.width * CGFloat(mask.width),
               height: imageRect.height * CGFloat(mask.height))
    }

    private enum MaskCorner: CaseIterable, Hashable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private func handlePosition(_ corner: MaskCorner, frame: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: frame.minX, y: frame.minY)
        case .topRight: return CGPoint(x: frame.maxX, y: frame.minY)
        case .bottomLeft: return CGPoint(x: frame.minX, y: frame.maxY)
        case .bottomRight: return CGPoint(x: frame.maxX, y: frame.maxY)
        }
    }

    private func moveGesture(imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if startMask == nil {
                    startMask = mask
                    onEditingChanged(true)
                }
                guard let startMask else { return }
                let dx = Double(value.translation.width / max(1, imageRect.width))
                let dy = Double(value.translation.height / max(1, imageRect.height))
                var next = startMask
                next.x = min(max(0, startMask.x + dx), 1 - startMask.width)
                next.y = min(max(0, startMask.y + dy), 1 - startMask.height)
                onChange(next)
            }
            .onEnded { _ in
                startMask = nil
                onEditingChanged(false)
            }
    }

    private func resizeGesture(_ corner: MaskCorner, imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if startMask == nil {
                    startMask = mask
                    onEditingChanged(true)
                }
                guard let startMask else { return }
                let dx = Double(value.translation.width / max(1, imageRect.width))
                let dy = Double(value.translation.height / max(1, imageRect.height))
                let minimum = 0.02
                var left = startMask.x, top = startMask.y
                var right = startMask.x + startMask.width, bottom = startMask.y + startMask.height
                switch corner {
                case .topLeft:
                    left = min(max(0, startMask.x + dx), right - minimum)
                    top = min(max(0, startMask.y + dy), bottom - minimum)
                case .topRight:
                    right = max(min(1, startMask.x + startMask.width + dx), left + minimum)
                    top = min(max(0, startMask.y + dy), bottom - minimum)
                case .bottomLeft:
                    left = min(max(0, startMask.x + dx), right - minimum)
                    bottom = max(min(1, startMask.y + startMask.height + dy), top + minimum)
                case .bottomRight:
                    right = max(min(1, startMask.x + startMask.width + dx), left + minimum)
                    bottom = max(min(1, startMask.y + startMask.height + dy), top + minimum)
                }
                var next = startMask
                next.x = left; next.y = top; next.width = right - left; next.height = bottom - top
                onChange(next)
            }
            .onEnded { _ in
                startMask = nil
                onEditingChanged(false)
            }
    }
}

private struct MaskHandle: View {
    var body: some View {
        Circle().fill(Color.clear).frame(width: 28, height: 28)
            .overlay(Circle().fill(Color.white).frame(width: 9, height: 9)
                .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 1)))
            .contentShape(Rectangle()).shadow(color: .black.opacity(0.7), radius: 2)
    }
}

private struct CropShade: View {
    let cropFrame: CGRect
    let canvas: CGSize
    var body: some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: canvas))
            path.addRect(cropFrame)
        }
        .fill(Color.black.opacity(0.58), style: FillStyle(eoFill: true))
    }
}

struct ClusterPalette: View {
    let title: String
    let clusters: [ColorCluster]
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            ForEach(Array(clusters.enumerated()), id: \.offset) { entry in
                RoundedRectangle(cornerRadius: 3).fill(swatch(entry.element)).frame(width: 22, height: 14)
                    .help(String(format: "占比 %.0f%%", entry.element.weight * 100))
            }
        }
    }
    private func swatch(_ cluster: ColorCluster) -> Color {
        let components = cluster.linearP3Swatch
        guard components.count == 3 else { return .gray }
        func encoded(_ value: Double) -> Double {
            let value = min(1, max(0, value))
            return value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
        }
        return Color(.displayP3, red: encoded(components[0]), green: encoded(components[1]), blue: encoded(components[2]))
    }
}
struct CurveView: View {
    let settings: Adjustments
    var body: some View {
        GeometryReader { g in
            let points = [CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: settings.shadows), CGPoint(x: 0.5, y: settings.midtones), CGPoint(x: 0.75, y: settings.highlights), CGPoint(x: 1, y: 1)]
            ZStack {
                Color.black.opacity(0.25)
                Path { p in
                    for v in [0.25, 0.5, 0.75] {
                        p.move(to: CGPoint(x: g.size.width * v, y: 0)); p.addLine(to: CGPoint(x: g.size.width * v, y: g.size.height))
                        p.move(to: CGPoint(x: 0, y: g.size.height * v)); p.addLine(to: CGPoint(x: g.size.width, y: g.size.height * v))
                    }
                }.stroke(.white.opacity(0.08), lineWidth: 1)
                Path { p in
                    for (i, point) in points.enumerated() {
                        let q = CGPoint(x: point.x * g.size.width, y: (1 - point.y) * g.size.height)
                        if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
                    }
                }.stroke(.orange, lineWidth: 2)
            }.clipShape(RoundedRectangle(cornerRadius: 6))
        }.help("控制点示意图；实际由 Core Image 插值")
    }
}

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Color.orange.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 6))
    }
}
