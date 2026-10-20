import SwiftUI
import ConverterCore

extension Color {
    static let wheelAccent = Color(red: 1.0, green: 0.55, blue: 0.12)
}

struct ArcSegment: Shape {
    var start: Double, end: Double
    var inner: CGFloat, outer: CGFloat
    var gap: Double = 1.2

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        let s = Angle.degrees(start + gap / 2), e = Angle.degrees(end - gap / 2)
        p.addArc(center: c, radius: outer, startAngle: s, endAngle: e, clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: e, endAngle: s, clockwise: true)
        p.closeSubpath()
        return p
    }
}

struct WheelView: View {
    @ObservedObject var model: WheelModel
    @ObservedObject var prefs = Prefs.shared
    @Environment(\.colorScheme) var scheme

    private var ringFill: Color { scheme == .dark ? Color(white: 0.16).opacity(0.94) : Color(white: 0.98).opacity(0.95) }
    private var ringStroke: Color { scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08) }

    var body: some View {
        ZStack {
            let n = model.items.count
            ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                let mid = WheelGeometry.centerAngle(i, of: n)
                let span = WheelGeometry.span(n)
                let hovered = model.hoverTop == i
                ArcSegment(start: mid - span / 2, end: mid + span / 2,
                           inner: WheelGeometry.ring1.lowerBound, outer: WheelGeometry.ring1.upperBound, gap: n == 1 ? 0 : 1.2)
                    .fill(hovered ? (item.enabled ? Color.wheelAccent : Color.gray.opacity(0.5)) : ringFill)
                    .overlay(ArcSegment(start: mid - span / 2, end: mid + span / 2,
                                        inner: WheelGeometry.ring1.lowerBound, outer: WheelGeometry.ring1.upperBound,
                                        gap: n == 1 ? 0 : 1.2).stroke(ringStroke, lineWidth: 1))
                label(item, highlighted: hovered, compact: n > 8)
                    .position(WheelGeometry.point(radius: (WheelGeometry.ring1.lowerBound + WheelGeometry.ring1.upperBound) / 2 + 4, angle: mid))
            }
            if let e = model.expanded, model.items.indices.contains(e) {
                let kids = model.items[e].children
                let layout = WheelGeometry.childLayout(parent: e, parents: n, children: kids.count)
                ForEach(Array(kids.enumerated()), id: \.element.id) { j, child in
                    let s = layout.start + Double(j) * layout.span
                    let hovered = model.hoverChild == j
                    ArcSegment(start: s, end: s + layout.span, inner: WheelGeometry.ring2.lowerBound, outer: WheelGeometry.ring2.upperBound)
                        .fill(hovered ? (child.enabled ? Color.wheelAccent : Color.gray.opacity(0.5)) : ringFill)
                        .overlay(ArcSegment(start: s, end: s + layout.span, inner: WheelGeometry.ring2.lowerBound,
                                            outer: WheelGeometry.ring2.upperBound).stroke(ringStroke, lineWidth: 1))
                    label(child, highlighted: hovered, compact: true)
                        .position(WheelGeometry.point(radius: (WheelGeometry.ring2.lowerBound + WheelGeometry.ring2.upperBound) / 2,
                                                      angle: s + layout.span / 2))
                }
                .transition(.opacity)
            }
            hub
        }
        .frame(width: WheelGeometry.size, height: WheelGeometry.size)
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .animation(.easeOut(duration: 0.12), value: model.expanded)
        .animation(.easeOut(duration: 0.08), value: model.hoverTop)
        .animation(.easeOut(duration: 0.08), value: model.hoverChild)
    }

    @ViewBuilder
    func label(_ item: WheelItem, highlighted: Bool, compact: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: item.symbol)
                .font(.system(size: compact ? 13 : 16, weight: .medium))
            Text(item.title)
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: compact ? 52 : 74)
            if item.isGroup {
                Text("\(item.children.count)").font(.system(size: 8, weight: .bold)).opacity(0.6)
            }
        }
        .foregroundColor(highlighted ? .white : (item.enabled ? .primary : .secondary))
        .opacity(item.enabled ? 1 : 0.55)
    }

    var hub: some View {
        let h = model.highlighted
        return ZStack {
            Circle().fill(ringFill).overlay(Circle().stroke(ringStroke, lineWidth: 1))
            VStack(spacing: 2) {
                if let h {
                    Text(h.title).font(.system(size: 13, weight: .bold)).lineLimit(2).multilineTextAlignment(.center)
                    if let note = h.note {
                        Text(note).font(.system(size: 8)).foregroundColor(.red).lineLimit(3).multilineTextAlignment(.center)
                    }
                } else if model.items.isEmpty {
                    Text("Nothing for\nthese files").font(.system(size: 10, weight: .medium)).multilineTextAlignment(.center)
                } else {
                    Text(model.mode.title).font(.system(size: 13, weight: .bold))
                    Text(model.files.count == 1 ? model.files[0].lastPathComponent : "\(model.files.count) files")
                        .font(.system(size: 8)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 5) {
                    ForEach(WheelMode.allCases) { m in
                        Text(prefs.key(for: m).symbol)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(m == model.mode ? .wheelAccent : .secondary.opacity(0.6))
                    }
                }
                .padding(.top, 2)
            }
            .padding(8)
            .frame(width: WheelGeometry.hub * 2 - 6)
        }
        .frame(width: WheelGeometry.hub * 2, height: WheelGeometry.hub * 2)
        .position(WheelGeometry.center)
    }
}
