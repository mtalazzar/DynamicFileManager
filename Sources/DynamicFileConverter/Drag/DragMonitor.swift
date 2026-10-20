import AppKit

/// Watches for file drags anywhere on screen (Finder, Desktop, other apps) and reports when one of the
/// wheel's modifier keys is pressed during the drag.
///
/// Detection works without special permissions: a global mouse-down monitor records the drag pasteboard's
/// change count, and while the button is held a timer polls the pasteboard and the modifier keys.
final class DragMonitor {
    /// Called on the main thread: (mode, dragged files).
    var onModifier: ((WheelMode, [URL]) -> Void)?
    /// Called when the mouse button is released.
    var onDragEnded: (() -> Void)?

    private var monitors: [Any] = []
    private var timer: Timer?
    private var startChangeCount = 0
    private var dragFiles: [URL] = []
    private var previousFlags: NSEvent.ModifierFlags = []

    func start() {
        stop()
        startTimer()
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in self?.mouseDown() }) {
            monitors.append(m)
        }
        // Drags that start inside our own windows (e.g. the Float shelf).
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] e in self?.mouseDown(); return e }) {
            monitors.append(m)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        timer?.invalidate()
        timer = nil
    }

    private var buttonDown = false
    private var armed = false

    private func mouseDown() {
        startChangeCount = NSPasteboard(name: .drag).changeCount
        armed = true
        dragFiles = []
        previousFlags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if timer == nil { startTimer() }
    }

    /// The timer also catches mouse-downs the global monitor misses, at the cost of a little precision.
    private func startTimer() {
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let down = NSEvent.pressedMouseButtons & 1 != 0
        defer { buttonDown = down }
        if !down {
            armed = false
            if buttonDown {
                let wasDragging = !dragFiles.isEmpty
                dragFiles = []
                if wasDragging { onDragEnded?() }
            }
            return
        }
        if !buttonDown && !armed {
            startChangeCount = NSPasteboard(name: .drag).changeCount
            previousFlags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        }
        let pb = NSPasteboard(name: .drag)
        if dragFiles.isEmpty, pb.changeCount != startChangeCount {
            dragFiles = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        }
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        defer { previousFlags = flags }
        guard !dragFiles.isEmpty, Prefs.shared.dragWheelEnabled else { return }
        // A key that just went down.
        let pressed = flags.subtracting(previousFlags)
        for key in ModifierKey.allCases where pressed.contains(key.flag) {
            if let mode = Prefs.shared.mode(for: key) {
                onModifier?(mode, dragFiles)
                return
            }
        }
    }
}
