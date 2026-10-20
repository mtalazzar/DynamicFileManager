import SwiftUI
import ServiceManagement
import ConverterCore

final class SettingsWindow: NSWindow {
    static let shared = SettingsWindow()

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                   styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        title = "DynamicFileConverter"
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: SettingsView())
        center()
    }

    func show(tab: SettingsView.Tab = .general) {
        NotificationCenter.default.post(name: .selectSettingsTab, object: tab)
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }
}

extension Notification.Name {
    static let selectSettingsTab = Notification.Name("selectSettingsTab")
    static let hotkeyPrefChanged = Notification.Name("hotkeyPrefChanged")
}

struct SettingsView: View {
    enum Tab: Hashable { case welcome, general, helpers }
    @State private var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            WelcomeTab().tabItem { Label("How to Use", systemImage: "hand.draw") }.tag(Tab.welcome)
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
            HelpersTab().tabItem { Label("Helpers", systemImage: "wrench.and.screwdriver") }.tag(Tab.helpers)
        }
        .padding(16)
        .frame(width: 560, height: 460)
        .onReceive(NotificationCenter.default.publisher(for: .selectSettingsTab)) { n in
            if let t = n.object as? Tab { tab = t }
        }
    }
}

struct WelcomeTab: View {
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "circle.circle.fill").font(.system(size: 36)).foregroundColor(.wheelAccent)
                VStack(alignment: .leading) {
                    Text("Convert anything by dragging").font(.title2.bold())
                    Text("Everything runs locally on this Mac.").foregroundColor(.secondary)
                }
            }
            step("1", "Start dragging a file in Finder or on the Desktop.")
            step("2", "While dragging, press \(prefs.convertKey.name) for Convert, \(prefs.toolsKey.name) for Tools or \(prefs.actionsKey.name) for Actions.")
            step("3", "Drop the file on a slice. Hover a category to open its formats. Drop anywhere else to cancel.")
            step("⌨︎", "Or select files in Finder and press ⌥⌘C, then use the arrow keys and Return (Tab switches wheel).")
            step("📁", "New files are saved next to the original; originals are never changed.")
            Spacer()
            Text("The first time you use ⌥⌘C, macOS asks to let DynamicFileConverter control Finder. That's only used to read the Finder selection.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(n).font(.system(size: 12, weight: .bold)).frame(width: 22, height: 22)
                .background(Circle().fill(Color.wheelAccent.opacity(0.2)))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct GeneralTab: View {
    @ObservedObject var prefs = Prefs.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var duplicateKeys: Bool { Set([prefs.convertKey, prefs.toolsKey, prefs.actionsKey]).count < 3 }

    var body: some View {
        Form {
            Section("Wheel keys (press while dragging)") {
                Toggle("Show the wheel while dragging files", isOn: $prefs.dragWheelEnabled)
                keyPicker("Convert", $prefs.convertKey)
                keyPicker("Tools", $prefs.toolsKey)
                keyPicker("Actions", $prefs.actionsKey)
                if duplicateKeys { Text("Each wheel needs a different key.").foregroundColor(.red).font(.caption) }
            }
            Section("Output") {
                Picker("Save results", selection: $prefs.useOutputFolder) {
                    Text("Next to the original").tag(false)
                    Text("In a folder").tag(true)
                }
                .pickerStyle(.radioGroup)
                if prefs.useOutputFolder {
                    HStack {
                        Text((prefs.outputFolder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { chooseFolder() }
                    }
                }
                Toggle("Reveal results in Finder when done", isOn: $prefs.revealWhenDone)
            }
            Section("Other") {
                Toggle("Global shortcut ⌥⌘C (convert Finder selection)", isOn: $prefs.hotkeyEnabled)
                    .onChange(of: prefs.hotkeyEnabled) { _ in NotificationCenter.default.post(name: .hotkeyPrefChanged, object: nil) }
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch { loginError = error.localizedDescription }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundColor(.red) }
            }
        }
        .formStyle(.grouped)
    }

    func keyPicker(_ title: String, _ binding: Binding<ModifierKey>) -> some View {
        Picker(title, selection: binding) {
            ForEach(ModifierKey.allCases) { Text($0.name).tag($0) }
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { prefs.outputFolder = url.path }
    }
}

struct HelpersTab: View {
    @State private var refresh = 0
    @State private var installing: Helper?
    @State private var log = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Some formats use free helper programs. Missing ones show up greyed out in the wheel.")
                .font(.callout).foregroundColor(.secondary)
            List {
                ForEach(Helper.allCases.filter { $0 != .ffprobe && $0 != .unar }, id: \.self) { h in
                    HStack {
                        Image(systemName: h.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundColor(h.isAvailable ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(h.displayName)
                            Text(h.path ?? (h.installCommand ?? "Install from the App Store"))
                                .font(.caption2).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if !h.isAvailable, h.installCommand != nil {
                            if installing == h { ProgressView().controlSize(.small) }
                            else { Button("Install") { install(h) }.disabled(installing != nil) }
                        }
                    }
                }
            }
            .id(refresh)
            if !log.isEmpty {
                ScrollView { Text(log).font(.system(size: 10, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(height: 70)
            }
            HStack {
                Spacer()
                Button("Refresh") { Helper.refresh(); refresh += 1 }
            }
        }
    }

    func install(_ h: Helper) {
        guard let cmd = h.installCommand else { return }
        installing = h
        log = "$ \(cmd)\n"
        Task {
            let result = try? await ProcessRunner.runAllowingFailure("/bin/zsh", ["-lc", cmd + " 2>&1"],
                                                                     environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"])
            await MainActor.run {
                log += String((result?.stdout ?? "failed to start").suffix(2000))
                if result?.status == 0 { log += "\nInstalled." }
                Helper.refresh()
                installing = nil
                refresh += 1
            }
        }
    }
}
