import AppKit
import SwiftUI

/// Borderless, transparent panel that floats above everything without stealing focus during a drag.
final class WheelPanel: NSPanel {
    var allowKey = false
    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: WheelGeometry.size, height: WheelGeometry.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
    }
}

/// Hosts the SwiftUI wheel and does all the hit-testing for drops, clicks and keys.
final class WheelHostView: NSView {
    let model: WheelModel
    var onActivate: ((WheelItem, [URL]) -> Void)?
    var onCancel: (() -> Void)?
    private var tracking: NSTrackingArea?

    init(model: WheelModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: WheelGeometry.size, height: WheelGeometry.size))
        let host = NSHostingView(rootView: WheelView(model: model))
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Only the rings are solid; clicks elsewhere in the square fall through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let r = WheelGeometry.polar(local).r
        let outer = model.expanded != nil ? WheelGeometry.ring2.upperBound : WheelGeometry.ring1.upperBound
        return r <= outer ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(tracking!)
    }

    // MARK: Drag destination

    private func urls(from info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        model.hover(at: convert(sender.draggingLocation, from: nil))
        if let s = model.selected, s.enabled { return .copy }
        return .generic
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { model.clearHover() }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        model.hover(at: convert(sender.draggingLocation, from: nil))
        return model.selected?.enabled == true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let item = model.selected, item.enabled else { return false }
        let files = urls(from: sender)
        DispatchQueue.main.async { self.onActivate?(item, files.isEmpty ? self.model.files : files) }
        return true
    }

    // MARK: Mouse & keyboard (interactive mode)

    override func mouseMoved(with event: NSEvent) {
        if model.interactive { model.hover(at: convert(event.locationInWindow, from: nil)) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        model.hover(at: p)
        if WheelGeometry.polar(p).r < WheelGeometry.hub {
            model.switchMode(model.mode.next)
            return
        }
        if let s = model.selected, s.enabled { onActivate?(s, model.files) }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // esc
            if !model.back() { onCancel?() }
        case 36, 76: // return, enter
            if let s = model.activate(), s.enabled { onActivate?(s, model.files) }
        case 123, 126: model.moveSelection(-1) // left, up
        case 124, 125: model.moveSelection(1)  // right, down
        case 48: model.switchMode(model.mode.next) // tab
        default:
            super.keyDown(with: event)
        }
    }
}

/// Shows and hides the wheel.
final class WheelController {
    let model = WheelModel()
    private let panel = WheelPanel()
    private lazy var host = WheelHostView(model: model)
    private var resignObserver: Any?
    var onActivate: ((WheelItem, [URL], NSPoint) -> Void)?

    var isVisible: Bool { panel.isVisible }

    init() {
        panel.contentView = host
        host.onActivate = { [weak self] item, files in
            guard let self else { return }
            let at = NSEvent.mouseLocation
            self.hide()
            self.onActivate?(item, files, at)
        }
        host.onCancel = { [weak self] in self?.hide() }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            if self?.model.interactive == true { self?.hide() }
        }
    }

    /// Opens centred on `point` (screen coordinates). `interactive` = keyboard/click mode.
    func show(files: [URL], mode: WheelMode, at point: NSPoint, interactive: Bool) {
        model.interactive = interactive
        model.load(files: files, mode: mode)
        let size = WheelGeometry.size
        var origin = NSPoint(x: point.x - size / 2, y: point.y - size / 2)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.frame
            // Keep at least the inner ring on screen.
            let margin = size / 2 - WheelGeometry.ring1.upperBound - 10
            origin.x = min(max(origin.x, f.minX - margin), f.maxX - size + margin)
            origin.y = min(max(origin.y, f.minY - margin), f.maxY - size + margin)
        }
        panel.setFrameOrigin(origin)
        panel.allowKey = interactive
        if interactive {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(host)
        } else {
            panel.orderFrontRegardless()
        }
        // Hover whatever is under the cursor right away.
        let local = host.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        model.hover(at: local)
    }

    func switchMode(_ mode: WheelMode) { model.switchMode(mode) }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        model.clearHover()
        model.interactive = false
    }
}
