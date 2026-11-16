import AppKit
import SwiftUI
import Darwin
import LumaCore

private final class CheckWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
private final class HostingView: NSHostingView<OverlayCheckRoot> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
@MainActor private final class OverlayCheckState: ObservableObject {
    @Published var visible = true
    @Published var crop = CropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    @Published var mask = LocalMask(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
    var began: [UUID] = []
    var ended: [UUID] = []
    func editing(_ active: Bool, owner: UUID) {
        if active { began.append(owner) } else { ended.append(owner) }
    }
}
private struct OverlayCheckRoot: View {
    @ObservedObject var state: OverlayCheckState
    let mask: Bool
    private let transform = ViewportTransform(imageSize: CGSize(width: 800, height: 600), viewportSize: CGSize(width: 800, height: 600))
    var body: some View {
        ZStack {
            Color.black
            if state.visible {
                if mask {
                    MaskOverlayPane(transform: transform, mask: state.mask, overlay: nil,
                        onChange: { state.mask = $0 }, onEditingChanged: state.editing)
                } else {
                    CropOverlayPane(transform: transform, cropRect: state.crop, canEdit: true,
                        onChange: { state.crop = $0 }, onEditingChanged: state.editing)
                }
            }
        }.frame(width: 800, height: 600)
    }
}

/// Real SwiftUI drags and view removal in a window behind the desktop. Does not
/// move the pointer, take key focus, or inject events into another application.
@main struct OverlayLifecycleCheck {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        for isMask in [false, true] {
            let state = OverlayCheckState()
            let window = CheckWindow(contentRect: CGRect(x: -20000, y: -20000, width: 800, height: 600),
                styleMask: .borderless, backing: .buffered, defer: false)
            let host = HostingView(rootView: OverlayCheckRoot(state: state, mask: isMask))
            window.contentView = host; window.orderBack(nil)
            defer { window.orderOut(nil) }
            settle()
            func send(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat) {
                let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                window.sendEvent(event)
            }
            send(.leftMouseDown, x: 400, y: 300)
            send(.leftMouseDragged, x: 450, y: 320)
            settle()
            send(.leftMouseDragged, x: 470, y: 330)
            settle()
            precondition(state.began.count == 1, "A real overlay drag must begin before testing cancellation")
            precondition(isMask ? state.mask.x != 0.2 : state.crop.x != 0.1)
            state.visible = false
            settle()
            precondition(state.ended == state.began, "Removing an active overlay must finish its own transaction exactly once")
            send(.leftMouseUp, x: 470, y: 330)
            settle()
            precondition(state.ended.count == 1, "A late mouse-up must not end the transaction twice")
            print("PASS: native SwiftUI \(isMask ? "mask" : "crop") drag cancellation ends its owner exactly once")
        }
    }
    @MainActor private static func settle() {
        for _ in 0..<5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }
}
