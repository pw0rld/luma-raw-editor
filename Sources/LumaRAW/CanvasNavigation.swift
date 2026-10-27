import AppKit
import Foundation
import SwiftUI

/// Observes events only in this canvas. Its NSView never covers SwiftUI's edit
/// handles; unconsumed events keep their normal responder/hit-testing behavior.
struct CanvasNavigation: NSViewRepresentable {
    var enabled: Bool
    var dragToPan: Bool
    var onZoom: (CGFloat, CGPoint) -> Void
    var onPan: (CGSize) -> Void
    var onDoubleClick: (CGPoint) -> Void
    var onDisplayScale: (CGFloat) -> Void = { _ in }
    var onToggleClipping: () -> Void = {}

    func makeNSView(context: Context) -> CanvasNavigationView { CanvasNavigationView() }
    func updateNSView(_ view: CanvasNavigationView, context: Context) {
        view.enabled = enabled; view.dragToPan = dragToPan
        view.onZoom = onZoom; view.onPan = onPan; view.onDoubleClick = onDoubleClick
        view.onDisplayScale = onDisplayScale; view.reportDisplayScale()
        view.onToggleClipping = onToggleClipping
        if !enabled { view.cancelNavigation() }
    }
    static func dismantleNSView(_ view: CanvasNavigationView, coordinator: ()) { view.stopMonitoring() }
}

final class CanvasNavigationView: NSView {
    var enabled = true
    var dragToPan = true
    var onZoom: (CGFloat, CGPoint) -> Void = { _, _ in }
    var onPan: (CGSize) -> Void = { _ in }
    var onDoubleClick: (CGPoint) -> Void = { _ in }
    var onDisplayScale: (CGFloat) -> Void = { _ in }
    var onToggleClipping: () -> Void = {}
    private var reportedScale: CGFloat?
    private var monitor: Any?
    private var windowObserver: NSObjectProtocol?
    private var spaceHeld = false
    private var dragPoint: CGPoint?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard let window else { return }
        reportDisplayScale()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel, .magnify, .smartMagnify]) { [weak self] event in
            guard let self else { return event }
            return self.consume(event)
        }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: nil) { [weak self] _ in
            self?.cancelNavigation()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties(); reportDisplayScale()
    }
    func reportDisplayScale() {
        guard let window, reportedScale != window.backingScaleFactor else { return }
        let scale = window.backingScaleFactor
        reportedScale = scale
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.backingScaleFactor == scale else { return }
            self.onDisplayScale(scale)
        }
    }

    func cancelNavigation() { spaceHeld = false; dragPoint = nil }
    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        monitor = nil; windowObserver = nil; reportedScale = nil; cancelNavigation()
    }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    }

    func consume(_ event: NSEvent) -> NSEvent? {
        guard enabled, let window, event.window === window, window.isKeyWindow else { return event }
        if event.type == .keyUp, event.keyCode == 49, spaceHeld {
            spaceHeld = false
            return nil
        }
        if event.type == .leftMouseUp, dragPoint != nil {
            dragPoint = nil
            return nil
        }
        let point = convert(event.locationInWindow, from: nil)
        if event.type == .leftMouseDragged, let last = dragPoint {
            onPan(CGSize(width: point.x - last.x, height: point.y - last.y))
            dragPoint = point
            return nil
        }
        let location = event.type == .keyDown || event.type == .keyUp
            ? convert(window.mouseLocationOutsideOfEventStream, from: nil) : point
        guard bounds.contains(location), !isHiddenOrHasHiddenAncestor else { return event }
        let hasCommandModifier = !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        let editingText = window.firstResponder is NSTextView || window.firstResponder is NSTextField
        switch event.type {
        case .keyDown where event.charactersIgnoringModifiers?.lowercased() == "j":
            guard !hasCommandModifier, !editingText else { return event }
            if !event.isARepeat { onToggleClipping() }
            return nil
        case .keyDown where event.keyCode == 49:
            // In particular, preserve spaces typed into file names or values.
            guard !hasCommandModifier, !editingText else { return event }
            spaceHeld = true
            return nil
        case .leftMouseDown:
            guard !hasCommandModifier, dragToPan || spaceHeld else { return event }
            dragPoint = point
            if event.clickCount == 2 { onDoubleClick(point) }
            return nil
        case .scrollWheel:
            guard dragPoint == nil, NSEvent.pressedMouseButtons == 0 else { return event }
            if event.modifierFlags.contains(.command) {
                onZoom(exp(event.scrollingDeltaY * 0.015), point)
            } else if !hasCommandModifier {
                let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
                onPan(CGSize(width: event.scrollingDeltaX * factor, height: event.scrollingDeltaY * factor))
            } else { return event }
            return nil
        case .magnify:
            guard dragPoint == nil, NSEvent.pressedMouseButtons == 0 else { return event }
            onZoom(exp(event.magnification), point)
            return nil
        case .smartMagnify:
            guard dragPoint == nil, NSEvent.pressedMouseButtons == 0 else { return event }
            onDoubleClick(point)
            return nil
        default: return event
        }
    }
}
