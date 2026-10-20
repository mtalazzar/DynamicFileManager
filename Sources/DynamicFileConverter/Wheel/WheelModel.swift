import AppKit
import ConverterCore

struct WheelItem: Identifiable {
    enum Payload {
        case op(FileOp)
        case action(FileAction)
    }

    let id: String
    let title: String
    let symbol: String
    var enabled = true
    var note: String?
    var children: [WheelItem] = []
    var payload: Payload?

    var isGroup: Bool { payload == nil }
}

/// Ring sizes and angle maths shared by drawing and hit-testing. Angles are in degrees,
/// clockwise from 3 o'clock in a y-down coordinate space; item 0 sits at 12 o'clock.
struct WheelGeometry {
    static let size: CGFloat = 580
    static let hub: CGFloat = 54
    static let ring1: ClosedRange<CGFloat> = 58...158
    static let ring2: ClosedRange<CGFloat> = 164...258
    static var center: CGPoint { CGPoint(x: size / 2, y: size / 2) }

    static func span(_ count: Int) -> Double { 360 / Double(max(count, 1)) }
    static func centerAngle(_ index: Int, of count: Int) -> Double { -90 + Double(index) * span(count) }

    /// Start angle and per-child span for the outer ring of `parent`.
    static func childLayout(parent: Int, parents: Int, children: Int) -> (start: Double, span: Double) {
        let each = min(36, 340 / Double(max(children, 1)))
        let mid = centerAngle(parent, of: parents)
        return (mid - each * Double(children) / 2, each)
    }

    static func polar(_ p: CGPoint) -> (r: CGFloat, angle: Double) {
        let dx = p.x - center.x, dy = p.y - center.y
        return (hypot(dx, dy), atan2(Double(dy), Double(dx)) * 180 / .pi)
    }

    /// Normalises `a` into [start, start + 360).
    static func normalize(_ a: Double, from start: Double) -> Double {
        var v = a
        while v < start { v += 360 }
        while v >= start + 360 { v -= 360 }
        return v
    }

    static func point(radius: CGFloat, angle: Double) -> CGPoint {
        let rad = angle * .pi / 180
        return CGPoint(x: center.x + radius * CGFloat(cos(rad)), y: center.y + radius * CGFloat(sin(rad)))
    }
}

final class WheelModel: ObservableObject {
    @Published var mode: WheelMode = .convert
    @Published var files: [URL] = []
    @Published var items: [WheelItem] = []
    @Published var hoverTop: Int?
    @Published var hoverChild: Int?
    @Published var expanded: Int?
    /// Keyboard / click mode (no drag in progress).
    @Published var interactive = false

    func load(files: [URL], mode: WheelMode) {
        self.files = files
        self.mode = mode
        rebuild()
    }

    func switchMode(_ m: WheelMode) {
        guard m != mode else { return }
        mode = m
        rebuild()
    }

    private func rebuild() {
        hoverTop = nil; hoverChild = nil; expanded = nil
        switch mode {
        case .actions:
            items = FileAction.allCases.map { WheelItem(id: "action.\($0.rawValue)", title: $0.title, symbol: $0.symbol, payload: .action($0)) }
        case .convert, .tools:
            let ops = OperationRegistry.operations(for: files, kind: mode == .convert ? .convert : .tool)
            items = Self.layout(ops)
        }
    }

    static func leaf(_ op: FileOp) -> WheelItem {
        let missing = op.missingHelpers
        return WheelItem(id: op.id, title: op.title, symbol: op.symbol, enabled: missing.isEmpty,
                         note: missing.isEmpty ? nil : "Needs \(missing.map(\.displayName).joined(separator: ", "))",
                         payload: .op(op))
    }

    /// Flat when small, otherwise grouped into an inner ring of categories.
    static func layout(_ ops: [FileOp]) -> [WheelItem] {
        if ops.count <= 10 || Set(ops.map(\.group)).count == 1 { return ops.map(leaf) }
        var order: [String] = []
        var groups: [String: [FileOp]] = [:]
        for op in ops {
            if groups[op.group] == nil { order.append(op.group) }
            groups[op.group, default: []].append(op)
        }
        return order.map { g in
            let members = groups[g]!
            if members.count == 1 { return leaf(members[0]) }
            return WheelItem(id: "group.\(g)", title: g, symbol: groupSymbol(g, members), children: members.map(leaf))
        }
    }

    static func groupSymbol(_ group: String, _ ops: [FileOp]) -> String {
        switch group {
        case "Image": return "photo"
        case "Video": return "film"
        case "Audio": return "waveform"
        case "Media": return "play.rectangle"
        case "Document": return "doc.text"
        case "PDF": return "doc.richtext"
        case "Slides": return "rectangle.on.rectangle"
        case "Spreadsheet": return "tablecells"
        case "Archive": return "archivebox"
        case "Subtitle": return "captions.bubble"
        case "Merge": return "square.stack.3d.down.right"
        default: return ops.first?.symbol ?? "circle"
        }
    }

    /// The actionable item under the pointer, if any.
    var selected: WheelItem? {
        guard let t = hoverTop, items.indices.contains(t) else { return nil }
        let top = items[t]
        if top.isGroup {
            guard let c = hoverChild, top.children.indices.contains(c) else { return nil }
            return top.children[c]
        }
        return top
    }

    /// Item shown in the hub (hovered group or leaf).
    var highlighted: WheelItem? {
        if let s = selected { return s }
        if let t = hoverTop, items.indices.contains(t) { return items[t] }
        return nil
    }

    /// Updates hover state for a point in wheel coordinates (y-down).
    func hover(at p: CGPoint) {
        let (r, angle) = WheelGeometry.polar(p)
        let n = items.count
        guard n > 0 else { return }
        if r < WheelGeometry.hub {
            hoverTop = nil; hoverChild = nil
            return
        }
        if r <= WheelGeometry.ring1.upperBound + 2 {
            let span = WheelGeometry.span(n)
            let a = WheelGeometry.normalize(angle, from: -90 - span / 2)
            let i = min(n - 1, Int((a - (-90 - span / 2)) / span))
            hoverTop = i
            hoverChild = nil
            expanded = items[i].isGroup ? i : nil
            return
        }
        if let e = expanded, r <= WheelGeometry.ring2.upperBound + 30 {
            let kids = items[e].children.count
            let (start, each) = WheelGeometry.childLayout(parent: e, parents: n, children: kids)
            let a = WheelGeometry.normalize(angle, from: start)
            let idx = Int((a - start) / each)
            if idx >= 0 && idx < kids {
                hoverTop = e
                hoverChild = idx
                return
            }
        }
        hoverChild = nil
        if expanded == nil { hoverTop = nil }
    }

    func clearHover() {
        hoverTop = nil; hoverChild = nil
    }

    // MARK: Keyboard navigation

    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        if let e = expanded, hoverChild != nil {
            let kids = items[e].children.count
            hoverChild = ((hoverChild ?? 0) + delta + kids) % kids
            return
        }
        let i = ((hoverTop ?? (delta > 0 ? -1 : 0)) + delta + items.count) % items.count
        hoverTop = i
        hoverChild = nil
        expanded = items[i].isGroup ? i : nil
    }

    /// Enter a group (returns nil) or return the leaf to run.
    func activate() -> WheelItem? {
        guard let t = hoverTop, items.indices.contains(t) else { return nil }
        if items[t].isGroup && hoverChild == nil {
            expanded = t
            hoverChild = 0
            return nil
        }
        return selected
    }

    func back() -> Bool {
        if hoverChild != nil { hoverChild = nil; return true }
        return false
    }
}
