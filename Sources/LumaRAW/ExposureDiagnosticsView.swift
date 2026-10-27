import SwiftUI
import LumaCore

struct ExposureDiagnosticsPanel: View {
    @ObservedObject var model: EditorModel
    @State private var showLuma = false
    private var scope: String { model.compare ? "原片全图" : "最终成片" }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("直方图", systemImage: "chart.bar.xaxis").font(.headline)
                Spacer()
                Menu(showLuma ? "亮度" : "RGB") {
                    Button("RGB") { showLuma = false }
                    Button("亮度") { showLuma = true }
                }.menuStyle(.borderlessButton).fixedSize().font(.caption).help("切换 RGB 与 sRGB 加权亮度")
            }
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.28))
                if let histogram = model.histogram {
                    HistogramPlot(histogram: histogram, showLuma: showLuma).padding(5)
                } else {
                    Text(model.histogramError ?? (model.photo == nil ? "导入照片后显示" : "更新中…"))
                        .font(.caption2).foregroundStyle(.secondary).padding(8)
                }
            }.frame(height: 96)
                .accessibilityLabel("\(scope)\(showLuma ? "加权亮度" : "RGB")直方图")
                .help("横轴为 sRGB 8 位数值 0–255；纵轴为 log(1+采样数)，RGB 共用纵轴。亮度为编码后 RGB 的加权值。")
            HStack {
                Text("0"); Spacer(); Text("\(scope) · sRGB"); Spacer(); Text("255")
            }.font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Toggle(isOn: $model.showShadowClipping) {
                    Label("暗部 \(percent(model.histogram?.shadowFraction))", systemImage: model.showShadowClipping ? "checkmark.square.fill" : "square").font(.caption)
                }.toggleStyle(.button).tint(.blue)
                    .help("蓝色：三个 sRGB 8 位通道均为 0；百分比来自整张图的预览采样。")
                Toggle(isOn: $model.showHighlightClipping) {
                    Label("高光 \(percent(model.histogram?.highlightFraction))", systemImage: model.showHighlightClipping ? "checkmark.square.fill" : "square").font(.caption)
                }.toggleStyle(.button).tint(.red)
                    .help("红色：任一 sRGB 8 位通道为 255；百分比来自整张图的预览采样。")
            }
            Text(sampleDescription).font(.caption2).foregroundStyle(.secondary)
            if !model.clippingOptions.isEmpty, model.tool == .mask, model.showMaskOverlay {
                Text("溢出提示开启时暂隐藏蒙版覆盖色。").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private var sampleDescription: String {
        let sample = model.histogram.map { "\($0.sampleWidth)×\($0.sampleHeight) 预览采样" } ?? "预览采样"
        return "\(sample) · 画布内 J 切换提示\n成片黑白端点提示，非 RAW 可恢复性判定。"
    }
    private func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        if fraction > 0, fraction < 0.001 { return "<0.1%" }
        return String(format: "%.1f%%", fraction * 100)
    }
}

private struct HistogramPlot: View {
    let histogram: OutputHistogram
    let showLuma: Bool
    var body: some View {
        Canvas { context, size in
            var grid = Path()
            for fraction in [0.25, 0.5, 0.75] {
                grid.move(to: CGPoint(x: size.width * fraction, y: 0))
                grid.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
            }
            context.stroke(grid, with: .color(.white.opacity(0.10)), lineWidth: 1)
            let channels: [([Int], Color)] = showLuma ? [(histogram.luma, .white)]
                : [(histogram.red, .red), (histogram.green, .green), (histogram.blue, .blue)]
            let peak = max(1, channels.flatMap { $0.0 }.max() ?? 1)
            for (bins, color) in channels {
                var line = Path()
                for index in 0..<256 {
                    let height = CGFloat(log1p(Double(bins[index])) / log1p(Double(peak)))
                    let point = CGPoint(x: CGFloat(index) * size.width / CGFloat(255), y: size.height * (1 - height))
                    if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height)); area.closeSubpath()
                context.fill(area, with: .color(color.opacity(0.18)))
                context.stroke(line, with: .color(color.opacity(0.9)), lineWidth: 1)
            }
        }.accessibilityHidden(true)
    }
}

private struct ClippingRequest: Equatable {
    let imageID: ObjectIdentifier
    let source: CanvasRenderState?
    let options: ClippingOptions
}

/// Overlay classification runs off the main actor on the immutable displayed
/// image. Native tiles replace both the base pixels and their endpoint overlay.
struct ClippedPhotoImage: View {
    @ObservedObject var model: EditorModel
    let image: CGImage
    let source: CanvasRenderState?
    var interpolation: Image.Interpolation = .high
    var region = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var overlay: CGImage?
    @State private var completed: ClippingRequest?
    @State private var failure: String?
    private var request: ClippingRequest {
        ClippingRequest(imageID: ObjectIdentifier(image), source: source, options: model.clippingOptions)
    }
    var body: some View {
        ZStack {
            Image(decorative: image, scale: 1).resizable().interpolation(interpolation)
            if completed == request, let overlay, source != nil, !request.options.isEmpty {
                Image(decorative: overlay, scale: 1).resizable().interpolation(.none)
                    .mask(GeometryReader { proxy in
                        Rectangle().frame(width: proxy.size.width * region.width, height: proxy.size.height * region.height)
                            .position(x: proxy.size.width * region.midX, y: proxy.size.height * region.midY)
                    })
            }
            if completed == request, let failure {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(failure)
            }
        }.allowsHitTesting(false)
            .task(id: request, priority: .utility) {
                let current = request
                overlay = nil; failure = nil; completed = nil
                guard let source = current.source, !current.options.isEmpty else { return }
                do {
                    let result = try await model.renderClipping(image, source: source, options: current.options)
                    try Task.checkCancellation()
                    guard request == current else { return }
                    overlay = result; completed = current
                    model.recordClippingSmoke(source: source, image: image)
                } catch is CancellationError { }
                catch { if request == current { failure = error.localizedDescription; completed = current } }
            }
    }
}
