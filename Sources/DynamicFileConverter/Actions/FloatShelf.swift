import AppKit
import SwiftUI
import QuickLookThumbnailing

/// Always-on-top shelf that holds files so they can be dragged somewhere else later.
final class FloatShelf: ObservableObject {
    static let shared = FloatShelf()
    @Published var items: [URL] = []
    private lazy var panel: NSPanel = makePanel()

    func add(_ urls: [URL]) {
        for u in urls where !items.contains(u) { items.append(u) }
        if !panel.isVisible {
            let vf = NSScreen.main?.visibleFrame ?? .zero
            panel.setFrameOrigin(NSPoint(x: vf.maxX - 200, y: vf.midY))
        }
        resize()
        panel.orderFrontRegardless()
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
        if items.isEmpty { panel.orderOut(nil) } else { resize() }
    }

    func clear() {
        items.removeAll()
        panel.orderOut(nil)
    }

    private func resize() {
        let height = CGFloat(min(items.count, 6)) * 118 + 38
        var f = panel.frame
        f.origin.y += f.height - height
        f.size = NSSize(width: 150, height: height)
        panel.setFrame(f, display: true, animate: false)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 150, height: 160),
                        styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.title = "Float"
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: ShelfView(shelf: self))
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { [weak self] _ in
            self?.items.removeAll()
        }
        return p
    }
}

struct ShelfView: View {
    @ObservedObject var shelf: FloatShelf

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(shelf.items, id: \.self) { url in ShelfTile(url: url) }
            }
            .padding(.horizontal, 10)
            .padding(.top, 26)
            .padding(.bottom, 10)
        }
    }
}

struct ShelfTile: View {
    let url: URL
    @State private var thumb: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: thumb ?? NSWorkspace.shared.icon(forFile: url.path))
                .resizable().aspectRatio(contentMode: .fit).frame(width: 72, height: 72)
            Text(url.lastPathComponent).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.center)
                .truncationMode(.middle)
        }
        .frame(width: 124, height: 110)
        .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { FloatShelf.shared.remove(url) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundColor(.secondary).padding(4)
            }
        }
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(object: url as NSURL) }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .help(url.path)
        .task {
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 72, height: 72),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { thumb = rep.nsImage }
        }
    }
}
