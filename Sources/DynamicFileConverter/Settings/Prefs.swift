import AppKit
import Combine

enum ModifierKey: String, CaseIterable, Identifiable {
    case shift, command, control, option
    var id: String { rawValue }
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .command: return .command
        case .control: return .control
        case .option: return .option
        }
    }
    var symbol: String {
        switch self {
        case .shift: return "⇧"
        case .command: return "⌘"
        case .control: return "⌃"
        case .option: return "⌥"
        }
    }
    var name: String { "\(symbol) \(rawValue.capitalized)" }
}

enum WheelMode: Int, CaseIterable, Identifiable {
    case convert, tools, actions
    var id: Int { rawValue }
    var title: String { ["Convert", "Tools", "Actions"][rawValue] }
    var next: WheelMode { WheelMode(rawValue: (rawValue + 1) % 3)! }
}

/// User preferences, persisted in UserDefaults.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    @Published var convertKey: ModifierKey { didSet { d.set(convertKey.rawValue, forKey: "convertKey") } }
    @Published var toolsKey: ModifierKey { didSet { d.set(toolsKey.rawValue, forKey: "toolsKey") } }
    @Published var actionsKey: ModifierKey { didSet { d.set(actionsKey.rawValue, forKey: "actionsKey") } }
    @Published var dragWheelEnabled: Bool { didSet { d.set(dragWheelEnabled, forKey: "dragWheelEnabled") } }
    @Published var useOutputFolder: Bool { didSet { d.set(useOutputFolder, forKey: "useOutputFolder") } }
    @Published var outputFolder: String { didSet { d.set(outputFolder, forKey: "outputFolder") } }
    @Published var hotkeyEnabled: Bool { didSet { d.set(hotkeyEnabled, forKey: "hotkeyEnabled") } }
    @Published var revealWhenDone: Bool { didSet { d.set(revealWhenDone, forKey: "revealWhenDone") } }
    @Published var recentMoveFolders: [String] { didSet { d.set(recentMoveFolders, forKey: "recentMoveFolders") } }

    private init() {
        convertKey = ModifierKey(rawValue: d.string(forKey: "convertKey") ?? "") ?? .shift
        toolsKey = ModifierKey(rawValue: d.string(forKey: "toolsKey") ?? "") ?? .command
        actionsKey = ModifierKey(rawValue: d.string(forKey: "actionsKey") ?? "") ?? .control
        dragWheelEnabled = d.object(forKey: "dragWheelEnabled") as? Bool ?? true
        useOutputFolder = d.bool(forKey: "useOutputFolder")
        outputFolder = d.string(forKey: "outputFolder")
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Converted").path
        hotkeyEnabled = d.object(forKey: "hotkeyEnabled") as? Bool ?? true
        revealWhenDone = d.bool(forKey: "revealWhenDone")
        recentMoveFolders = d.stringArray(forKey: "recentMoveFolders") ?? []
    }

    /// nil = save next to the original.
    var outputDirectory: URL? { useOutputFolder ? URL(fileURLWithPath: outputFolder, isDirectory: true) : nil }

    func mode(for key: ModifierKey) -> WheelMode? {
        if key == convertKey { return .convert }
        if key == toolsKey { return .tools }
        if key == actionsKey { return .actions }
        return nil
    }

    func key(for mode: WheelMode) -> ModifierKey {
        switch mode {
        case .convert: return convertKey
        case .tools: return toolsKey
        case .actions: return actionsKey
        }
    }

    // MARK: Last-used tool options

    func savedOptions(for opID: String) -> [String: String] {
        d.dictionary(forKey: "options.\(opID)") as? [String: String] ?? [:]
    }

    func saveOptions(_ options: [String: String], for opID: String) {
        d.set(options, forKey: "options.\(opID)")
    }

    func rememberMoveFolder(_ path: String) {
        recentMoveFolders = Array(([path] + recentMoveFolders.filter { $0 != path }).prefix(5))
    }
}
