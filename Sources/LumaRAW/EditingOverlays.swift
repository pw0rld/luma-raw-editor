import SwiftUI
import LumaCore

/// Overlay dimensions and input use the same transform as the photograph.
struct CropOverlayPane: View {
    let transform: ViewportTransform
    let cropRect: CropRect
    let canEdit: Bool
    let onChange: (CropRect) -> Void
    let onEditingChanged: (Bool, UUID) -> Void
    @State private var gestureStart: CropRect?
    @State private var gestureOwner = UUID()
    private let minimumCropFraction = 0.02
    private enum Corner: Hashable { case topLeft, topRight, bottomLeft, bottomRight }

    var body: some View {
        let imageRect = transform.imageRect
        let visibleCrop = transform.viewRect(for: CGRect(x: cropRect.x, y: cropRect.y, width: cropRect.width, height: cropRect.height))
        ZStack(alignment: .topLeading) {
            CropShade(cropFrame: visibleCrop, canvas: transform.viewportSize).allowsHitTesting(false)
            Path { path in
                for fraction in [1.0 / 3, 2.0 / 3] {
                    let x = visibleCrop.minX + visibleCrop.width * fraction
                    let y = visibleCrop.minY + visibleCrop.height * fraction
                    path.move(to: CGPoint(x: x, y: visibleCrop.minY))
                    path.addLine(to: CGPoint(x: x, y: visibleCrop.maxY))
                    path.move(to: CGPoint(x: visibleCrop.minX, y: y))
                    path.addLine(to: CGPoint(x: visibleCrop.maxX, y: y))
                }
            }.stroke(Color.white.opacity(canEdit ? 0.38 : 0.15), lineWidth: 1).allowsHitTesting(false)
            Rectangle().fill(.clear).contentShape(Rectangle())
                .frame(width: visibleCrop.width, height: visibleCrop.height)
                .position(x: visibleCrop.midX, y: visibleCrop.midY)
                .gesture(moveGesture(imageRect: imageRect))
            Rectangle().stroke(canEdit ? Color.white : Color.white.opacity(0.35), lineWidth: 2)
                .frame(width: visibleCrop.width, height: visibleCrop.height)
                .position(x: visibleCrop.midX, y: visibleCrop.midY).allowsHitTesting(false)
            if canEdit {
                ForEach([Corner.topLeft, .topRight, .bottomLeft, .bottomRight], id: \.self) { corner in
                    CropHandle().position(handlePosition(corner, frame: visibleCrop))
                        .gesture(resizeGesture(corner, imageRect: imageRect))
                }
            }
        }.frame(width: transform.viewportSize.width, height: transform.viewportSize.height, alignment: .topLeading)
            .onDisappear(perform: endGesture)
    }

    private func endGesture() {
        guard gestureStart != nil else { return }
        gestureStart = nil
        onEditingChanged(false, gestureOwner)
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
                    onEditingChanged(true, gestureOwner)
                }
                guard let start = gestureStart else { return }
                let dx = Double(value.translation.width / max(1, imageRect.width))
                let dy = Double(value.translation.height / max(1, imageRect.height))
                let x = min(1 - start.width, max(0, start.x + dx))
                let y = min(1 - start.height, max(0, start.y + dy))
                onChange(CropRect(x: x, y: y, width: start.width, height: start.height))
            }
            .onEnded { _ in endGesture() }
    }

    private func resizeGesture(_ corner: Corner, imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if gestureStart == nil {
                    gestureStart = cropRect
                    onEditingChanged(true, gestureOwner)
                }
                guard let start = gestureStart else { return }
                let dx = Double(value.translation.width / max(1, imageRect.width))
                let dy = Double(value.translation.height / max(1, imageRect.height))
                onChange(resized(start, corner: corner, dx: dx, dy: dy))
            }
            .onEnded { _ in endGesture() }
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

/// Mask controls stay in view points while their image geometry follows zoom/pan.
struct MaskOverlayPane: View {
    let transform: ViewportTransform
    let mask: LocalMask
    let overlay: CGImage?
    let onChange: (LocalMask) -> Void
    let onEditingChanged: (Bool, UUID) -> Void
    @State private var startMask: LocalMask?
    @State private var gestureOwner = UUID()

    var body: some View {
        let imageRect = transform.imageRect
        let frame = transform.viewRect(for: CGRect(x: mask.x, y: mask.y, width: mask.width, height: mask.height))
        ZStack(alignment: .topLeading) {
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
        }.frame(width: transform.viewportSize.width, height: transform.viewportSize.height, alignment: .topLeading)
            .onDisappear(perform: endGesture)
    }

    private func endGesture() {
        guard startMask != nil else { return }
        startMask = nil
        onEditingChanged(false, gestureOwner)
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
                let geometry = MaskGeometry(mask, imageSize: transform.imageSize)
                let points = geometry.linearEndpoints
                path.move(to: transform.viewPoint(forImagePoint: points.start))
                path.addLine(to: transform.viewPoint(forImagePoint: points.end))
            }.stroke(color.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
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
                    onEditingChanged(true, gestureOwner)
                }
                guard let startMask else { return }
                let dx = Double(value.translation.width / max(1, imageRect.width))
                let dy = Double(value.translation.height / max(1, imageRect.height))
                var next = startMask
                next.x = min(max(0, startMask.x + dx), 1 - startMask.width)
                next.y = min(max(0, startMask.y + dy), 1 - startMask.height)
                onChange(next)
            }
            .onEnded { _ in endGesture() }
    }

    private func resizeGesture(_ corner: MaskCorner, imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if startMask == nil {
                    startMask = mask
                    onEditingChanged(true, gestureOwner)
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
            .onEnded { _ in endGesture() }
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

