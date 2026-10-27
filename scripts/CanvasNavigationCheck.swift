import AppKit

// No image rendering: exercise the native event routing without taking focus,
// moving the user's pointer or registering any global keyboard hooks.
private final class CheckWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var mouseLocationOutsideOfEventStream: NSPoint { NSPoint(x: 400, y: 300) }
}

@main struct CanvasNavigationCheck {
    @MainActor static func main() {
        _ = NSApplication.shared
        let window = CheckWindow(contentRect: CGRect(x: -20000, y: -20000, width: 800, height: 600),
                                 styleMask: .borderless, backing: .buffered, defer: false)
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let view = CanvasNavigationView(frame: host.bounds)
        window.contentView = host; host.addSubview(view)
        window.orderBack(nil)
        defer { view.stopMonitoring(); window.orderOut(nil) }
        var pans: [CGSize] = [], doubles = 0
        view.onPan = { pans.append($0) }; view.onDoubleClick = { _ in doubles += 1 }
        func mouseEvent(_ type: NSEvent.EventType, x: CGFloat = 300, y: CGFloat = 300, clicks: Int = 1, windowNumber: Int? = nil) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                windowNumber: windowNumber ?? window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
        }
        func space(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        }
        precondition(view.hitTest(CGPoint(x: 10, y: 10)) == nil, "Navigation must not cover edit handles")
        let down = mouseEvent(.leftMouseDown)
        let consumedDown = view.consume(down)
        if consumedDown != nil {
            FileHandle.standardError.write(Data("Navigation test window=\(window.windowNumber), event=\(down.windowNumber), attached=\(view.window === window), key=\(window.isKeyWindow), resolved=\(down.window === window), hidden=\(view.isHiddenOrHasHiddenAncestor), bounds=\(view.bounds), point=\(view.convert(down.locationInWindow, from: nil))\n".utf8))
        }
        precondition(consumedDown == nil)
        precondition(view.consume(mouseEvent(.leftMouseDragged, x: 350, y: 280)) == nil)
        precondition(pans.last == CGSize(width: 50, height: 20), "Native bottom-left locations must become top-left canvas deltas")
        // Finish outside the canvas, then verify there is no stuck drag.
        precondition(view.consume(mouseEvent(.leftMouseUp, x: 1000, y: 900)) == nil)
        precondition(view.consume(mouseEvent(.leftMouseDragged)) != nil)
        precondition(view.consume(mouseEvent(.leftMouseDown, clicks: 2)) == nil && doubles == 1)
        precondition(view.consume(mouseEvent(.leftMouseUp)) == nil)
        view.dragToPan = false
        precondition(view.consume(mouseEvent(.leftMouseDown)) != nil, "Normal drags must reach the crop/mask handles")
        precondition(view.consume(space(.keyDown)) == nil)
        precondition(view.consume(mouseEvent(.leftMouseDown)) == nil, "Space-drag pans even in edit modes")
        precondition(view.consume(mouseEvent(.leftMouseUp)) == nil)
        precondition(view.consume(space(.keyUp)) == nil)
        precondition(view.consume(mouseEvent(.leftMouseDown)) != nil)
        let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
        host.addSubview(text); window.makeFirstResponder(text)
        precondition(view.consume(space(.keyDown)) != nil, "Typing a space must not enable panning")
        precondition(view.consume(mouseEvent(.leftMouseDown)) != nil)
        window.makeFirstResponder(nil)
        precondition(view.consume(mouseEvent(.leftMouseDown, x: -10)) != nil, "Events outside this canvas must pass through")
        let other = CheckWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        precondition(view.consume(mouseEvent(.leftMouseDown, windowNumber: other.windowNumber)) != nil, "Other windows must remain unaffected")
        precondition(view.consume(space(.keyDown)) == nil)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        precondition(view.consume(mouseEvent(.leftMouseDown)) != nil, "Losing focus must release the space modifier")
        view.enabled = false
        precondition(view.consume(space(.keyDown)) != nil)
        precondition(pans.count == 1)
        print("PASS: canvas native drag, flipped coordinates, paired events, space/edit routing, text input, window isolation and focus reset")
    }
}
