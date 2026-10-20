import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut via Carbon's RegisterEventHotKey (no Accessibility permission needed).
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static var instances: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32

    /// Default: ⌥⌘C.
    init(keyCode: UInt32 = UInt32(kVK_ANSI_C), modifiers: UInt32 = UInt32(cmdKey | optionKey), action: @escaping () -> Void) {
        self.action = action
        id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.instances[id] = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async { HotKey.instances[hk.id]?.action() }
            return noErr
        }, 1, &spec, nil, &handler)
        let hkID = EventHotKeyID(signature: OSType(0x4446_4321), id: id) // "DFC!"
        RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        HotKey.instances[id] = nil
    }
}

enum FinderSelection {
    /// POSIX paths of the items selected in Finder (asks for Automation permission the first time).
    static func get() -> [URL] {
        let source = """
        tell application "Finder"
            set out to ""
            repeat with f in (selection as alias list)
                set out to out & POSIX path of f & linefeed
            end repeat
            return out
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue else { return [] }
        return result.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }
}

/// Finder → Services → "Convert with DynamicFileConverter".
final class ServiceProvider: NSObject {
    var onFiles: (([URL]) -> Void)?

    @objc func convertFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty { onFiles?(urls) }
    }
}
