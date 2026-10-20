import AppKit
import ConverterCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let wheel = WheelController()
    private let drag = DragMonitor()
    private let services = ServiceProvider()
    private var hotKey: HotKey?
    private var hideWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setUpStatusItem()

        wheel.onActivate = { [weak self] item, files, point in self?.perform(item, files: files, at: point) }

        drag.onModifier = { [weak self] mode, files in
            guard let self else { return }
            self.hideWork?.cancel()
            if self.wheel.isVisible && !self.wheel.model.interactive {
                self.wheel.switchMode(mode)
            } else {
                self.wheel.show(files: files, mode: mode, at: NSEvent.mouseLocation, interactive: false)
            }
        }
        drag.onDragEnded = { [weak self] in
            guard let self, self.wheel.isVisible, !self.wheel.model.interactive else { return }
            // Give a drop on the wheel time to be delivered before closing it.
            let work = DispatchWorkItem { [weak self] in
                if self?.wheel.model.interactive == false { self?.wheel.hide() }
            }
            self.hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
        drag.start()

        services.onFiles = { [weak self] urls in self?.openWheel(urls) }
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()

        updateHotKey()
        NotificationCenter.default.addObserver(forName: .hotkeyPrefChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateHotKey()
        }

        if !UserDefaults.standard.bool(forKey: "didShowWelcome") {
            UserDefaults.standard.set(true, forKey: "didShowWelcome")
            SettingsWindow.shared.show(tab: .welcome)
        }
    }

    /// "Open With" from Finder or dropping on the app icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        openWheel(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.shared.show()
        return false
    }

    // MARK: Running things

    private func perform(_ item: WheelItem, files: [URL], at point: NSPoint) {
        guard !files.isEmpty else { return }
        switch item.payload {
        case .action(let action):
            action.perform(files, at: point)
        case .op(let op):
            if op.options.isEmpty {
                JobCenter.shared.start(op, files: files, options: [:])
            } else {
                OptionSheet.present(for: op, files: files, at: point) { options in
                    JobCenter.shared.start(op, files: files, options: options)
                }
            }
        case .none:
            break
        }
    }

    private func openWheel(_ urls: [URL], mode: WheelMode = .convert) {
        guard !urls.isEmpty else { return }
        wheel.show(files: urls, mode: mode, at: NSEvent.mouseLocation, interactive: true)
    }

    @objc private func convertFinderSelection() {
        var files = FinderSelection.get()
        if files.isEmpty {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = true
            panel.message = "Choose files to convert"
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK else { return }
            files = panel.urls
        }
        openWheel(files)
    }

    @objc private func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            let urls = panel.urls
            DispatchQueue.main.async { self.openWheel(urls) }
        }
    }

    private func updateHotKey() {
        hotKey = Prefs.shared.hotkeyEnabled ? HotKey { [weak self] in self?.convertFinderSelection() } : nil
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "DynamicFileConverter")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let convert = NSMenuItem(title: "Convert Finder Selection", action: #selector(convertFinderSelection), keyEquivalent: "c")
        convert.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(convert)
        menu.addItem(NSMenuItem(title: "Open Files…", action: #selector(openFiles), keyEquivalent: "o"))
        menu.addItem(.separator())

        let jobs = JobCenter.shared.recent
        if jobs.isEmpty {
            let none = NSMenuItem(title: "No recent conversions", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for job in jobs {
                let suffix: String
                switch job.state {
                case .running: suffix = " — \(Int(job.progress * 100))%"
                case .failed: suffix = " — failed"
                case .cancelled: suffix = " — cancelled"
                case .done: suffix = ""
                }
                let item = NSMenuItem(title: job.title + suffix, action: #selector(showJob(_:)), keyEquivalent: "")
                item.representedObject = job
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem(title: "Show Progress Panel", action: #selector(showJobs), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Clear Finished", action: #selector(clearJobs), keyEquivalent: ""))
        }
        if !FloatShelf.shared.items.isEmpty {
            menu.addItem(NSMenuItem(title: "Clear Float Shelf", action: #selector(clearShelf), keyEquivalent: ""))
        }
        menu.addItem(.separator())
        let drag = NSMenuItem(title: "Wheel While Dragging", action: #selector(toggleDrag), keyEquivalent: "")
        drag.state = Prefs.shared.dragWheelEnabled ? .on : .off
        menu.addItem(drag)
        menu.addItem(NSMenuItem(title: "How to Use", action: #selector(showHelp), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit DynamicFileConverter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) && item.target == nil && item.action != nil {
            item.target = self
        }
    }

    @objc private func showJob(_ sender: NSMenuItem) {
        guard let job = sender.representedObject as? Job else { return }
        if job.state == .done { NSWorkspace.shared.activateFileViewerSelecting(job.outputs) } else { JobCenter.shared.showHUD() }
    }

    @objc private func showJobs() { JobCenter.shared.showHUD() }
    @objc private func clearJobs() { JobCenter.shared.clearFinished() }
    @objc private func clearShelf() { FloatShelf.shared.clear() }
    @objc private func toggleDrag() { Prefs.shared.dragWheelEnabled.toggle() }
    @objc private func showSettings() { SettingsWindow.shared.show(tab: .general) }
    @objc private func showHelp() { SettingsWindow.shared.show(tab: .welcome) }
}
