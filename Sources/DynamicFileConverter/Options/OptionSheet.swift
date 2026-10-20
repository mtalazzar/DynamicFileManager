import AppKit
import SwiftUI
import ConverterCore

/// Small floating form shown after dropping onto a tool that has settings.
final class OptionSheet: NSPanel {
    private static var current: OptionSheet?

    static func present(for op: FileOp, files: [URL], at point: NSPoint, onRun: @escaping (Options) -> Void) {
        current?.close()
        let sheet = OptionSheet(op: op, files: files, onRun: onRun)
        current = sheet
        var origin = NSPoint(x: point.x - sheet.frame.width / 2, y: point.y - sheet.frame.height / 2)
        if let vf = (NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - sheet.frame.width - 8)
            origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - sheet.frame.height - 8)
        }
        sheet.setFrameOrigin(origin)
        NSApp.activate(ignoringOtherApps: true)
        sheet.makeKeyAndOrderFront(nil)
    }

    private init(op: FileOp, files: [URL], onRun: @escaping (Options) -> Void) {
        super.init(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        title = op.title
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        level = .floating
        let view = OptionForm(op: op, files: files, onRun: { [weak self] opts in
            self?.close()
            onRun(opts)
        }, onCancel: { [weak self] in self?.close() })
        let host = NSHostingView(rootView: view)
        contentView = host
        setContentSize(host.fittingSize)
    }

    override func close() {
        super.close()
        if OptionSheet.current === self { OptionSheet.current = nil }
    }

    override func cancelOperation(_ sender: Any?) { close() }
}

struct OptionForm: View {
    let op: FileOp
    let files: [URL]
    let onRun: (Options) -> Void
    let onCancel: () -> Void
    @State private var values: [String: String] = [:]

    init(op: FileOp, files: [URL], onRun: @escaping (Options) -> Void, onCancel: @escaping () -> Void) {
        self.op = op; self.files = files; self.onRun = onRun; self.onCancel = onCancel
        var v: [String: String] = [:]
        let saved = Prefs.shared.savedOptions(for: op.id)
        for spec in op.options {
            if case .secure = spec.kind { v[spec.key] = ""; continue }
            v[spec.key] = saved[spec.key] ?? spec.defaultValue
        }
        _values = State(initialValue: v)
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: op.symbol).font(.system(size: 18)).foregroundColor(.wheelAccent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(op.title).font(.headline)
                    Text(files.count == 1 ? files[0].lastPathComponent : "\(files.count) files")
                        .font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Form {
                ForEach(op.options, id: \.key) { spec in
                    switch spec.kind {
                    case .choice(let choices):
                        if choices.count <= 3 {
                            Picker(spec.label, selection: binding(spec.key)) {
                                ForEach(choices, id: \.self) { Text($0).tag($0) }
                            }.pickerStyle(.segmented)
                        } else {
                            Picker(spec.label, selection: binding(spec.key)) {
                                ForEach(choices, id: \.self) { Text($0).tag($0) }
                            }
                        }
                    case .text(let placeholder):
                        TextField(spec.label, text: binding(spec.key), prompt: Text(placeholder))
                    case .secure:
                        SecureField(spec.label, text: binding(spec.key))
                    case .toggle:
                        Toggle(spec.label, isOn: Binding(get: { values[spec.key] == "true" }, set: { values[spec.key] = $0 ? "true" : "false" }))
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Run") { run() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .padding(.top, 8)
        .frame(width: 380)
    }

    private func run() {
        var toSave = values
        for spec in op.options { if case .secure = spec.kind { toSave.removeValue(forKey: spec.key) } }
        Prefs.shared.saveOptions(toSave, for: op.id)
        onRun(values)
    }
}
