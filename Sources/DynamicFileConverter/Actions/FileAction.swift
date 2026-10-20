import AppKit
import SwiftUI
import ConverterCore

enum FileAction: String, CaseIterable {
    case airdrop, float, copy, move, copyPath, terminal

    var title: String {
        switch self {
        case .airdrop: return "AirDrop"
        case .float: return "Float"
        case .copy: return "Copy"
        case .move: return "Move"
        case .copyPath: return "Copy Path"
        case .terminal: return "Terminal"
        }
    }

    var symbol: String {
        switch self {
        case .airdrop: return "airplayaudio"
        case .float: return "pin"
        case .copy: return "doc.on.doc"
        case .move: return "folder"
        case .copyPath: return "link"
        case .terminal: return "terminal"
        }
    }

    func perform(_ urls: [URL], at point: NSPoint) {
        switch self {
        case .airdrop:
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
                return Self.alert("AirDrop is not available", "Turn on Wi-Fi and Bluetooth, or check AirDrop in Finder.")
            }
            NSApp.activate(ignoringOtherApps: true)
            service.perform(withItems: urls)
        case .float:
            FloatShelf.shared.add(urls)
        case .copy:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(urls as [NSURL])
            Toast.show("Copied \(Self.describe(urls))", at: point)
        case .copyPath:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            Toast.show("Copied path", at: point)
        case .terminal:
            var isDir: ObjCBool = false
            let first = urls[0]
            FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir)
            let dir = isDir.boolValue ? first : first.deletingLastPathComponent()
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([dir], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        case .move:
            MoveMenu.show(urls, at: point)
        }
    }

    static func describe(_ urls: [URL]) -> String {
        urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
    }

    static func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

/// Popup menu of recent folders plus "Choose…".
enum MoveMenu {
    private static var target: MenuTarget?

    static func show(_ urls: [URL], at point: NSPoint) {
        let menu = NSMenu(title: "Move to")
        let t = MenuTarget(urls: urls)
        target = t
        let header = NSMenuItem(title: "Move \(FileAction.describe(urls)) to", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for path in Prefs.shared.recentMoveFolders where FileManager.default.fileExists(atPath: path) {
            let item = NSMenuItem(title: (path as NSString).abbreviatingWithTildeInPath, action: #selector(MenuTarget.moveTo(_:)), keyEquivalent: "")
            item.representedObject = path
            item.target = t
            item.image = NSWorkspace.shared.icon(forFile: path)
            item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
        }
        for (name, dir) in [("Desktop", FileManager.SearchPathDirectory.desktopDirectory), ("Documents", .documentDirectory), ("Downloads", .downloadsDirectory)] {
            let path = FileManager.default.urls(for: dir, in: .userDomainMask)[0].path
            if Prefs.shared.recentMoveFolders.contains(path) { continue }
            let item = NSMenuItem(title: name, action: #selector(MenuTarget.moveTo(_:)), keyEquivalent: "")
            item.representedObject = path
            item.target = t
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let choose = NSMenuItem(title: "Choose Folder…", action: #selector(MenuTarget.choose(_:)), keyEquivalent: "")
        choose.target = t
        menu.addItem(choose)
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    final class MenuTarget: NSObject {
        let urls: [URL]
        init(urls: [URL]) { self.urls = urls }

        @objc func moveTo(_ sender: NSMenuItem) {
            guard let path = sender.representedObject as? String else { return }
            move(to: URL(fileURLWithPath: path, isDirectory: true))
        }

        @objc func choose(_ sender: NSMenuItem) {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Move Here"
            panel.message = "Move \(FileAction.describe(urls)) to…"
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK, let dir = panel.url { move(to: dir) }
        }

        func move(to dir: URL) {
            var moved: [URL] = []
            for u in urls where u.deletingLastPathComponent().standardizedFileURL != dir.standardizedFileURL {
                let dest = OutputNamer.uniqueURL(in: dir, fileName: u.lastPathComponent)
                do { try FileManager.default.moveItem(at: u, to: dest); moved.append(dest) }
                catch { FileAction.alert("Could not move \(u.lastPathComponent)", error.localizedDescription) }
            }
            Prefs.shared.rememberMoveFolder(dir.path)
            if !moved.isEmpty { Toast.show("Moved to \(dir.lastPathComponent)", at: NSEvent.mouseLocation) }
        }
    }
}

/// Brief confirmation bubble near the cursor.
enum Toast {
    private static var panel: NSPanel?

    static func show(_ text: String, at point: NSPoint) {
        panel?.orderOut(nil)
        let host = NSHostingView(rootView:
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().stroke(Color.primary.opacity(0.1)))
        )
        let size = host.fittingSize
        let p = NSPanel(contentRect: NSRect(x: point.x - size.width / 2, y: point.y + 24, width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .popUpMenu
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.contentView = host
        p.orderFrontRegardless()
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if panel === p { p.orderOut(nil); panel = nil }
        }
    }
}
