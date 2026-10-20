import AppKit
import SwiftUI
import ConverterCore

final class Job: ObservableObject, Identifiable {
    enum State: Equatable { case running, done, failed(String), cancelled }

    let id = UUID()
    let title: String
    let detail: String
    let started = Date()
    @Published var progress: Double = 0
    @Published var state: State = .running
    @Published var outputs: [URL] = []
    var task: Task<Void, Never>?

    init(title: String, detail: String) { self.title = title; self.detail = detail }

    var isRunning: Bool { state == .running }
}

/// Runs operations in the background and shows their progress in a small floating panel.
final class JobCenter: ObservableObject {
    static let shared = JobCenter()
    @Published private(set) var jobs: [Job] = []
    private lazy var hud = JobHUD(center: self)
    private var hideWork: DispatchWorkItem?

    var recent: [Job] { Array(jobs.suffix(8).reversed()) }

    func start(_ op: FileOp, files: [URL], options: Options) {
        let names = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
        let job = Job(title: op.kind == .convert ? "\(names) → \(op.title)" : "\(op.title): \(names)", detail: names)
        jobs.append(job)
        if jobs.count > 30 { jobs.removeFirst(jobs.count - 30) }
        showHUD()
        let outputDir = Prefs.shared.outputDirectory
        job.task = Task {
            do {
                let outs = try await Engine.shared.run(op, inputs: files, options: options, outputDir: outputDir) { p in
                    DispatchQueue.main.async { job.progress = p }
                }
                await MainActor.run {
                    job.outputs = outs
                    job.progress = 1
                    job.state = .done
                    if Prefs.shared.revealWhenDone { NSWorkspace.shared.activateFileViewerSelecting(outs) }
                }
            } catch {
                let cancelled = (error as? ConvertError).map { if case .cancelled = $0 { return true } else { return false } } ?? (error is CancellationError)
                await MainActor.run { job.state = cancelled ? .cancelled : .failed(error.localizedDescription) }
            }
            await MainActor.run { JobCenter.shared.scheduleHide() }
        }
    }

    func cancel(_ job: Job) { job.task?.cancel() }

    func clearFinished() {
        jobs.removeAll { !$0.isRunning }
        if jobs.isEmpty { hud.orderOut(nil) }
    }

    func showHUD() {
        hideWork?.cancel()
        hud.present()
    }

    fileprivate func scheduleHide() {
        guard !jobs.contains(where: \.isRunning) else { return }
        let hasFailure = jobs.contains { if case .failed = $0.state { return true }; return false }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.jobs.contains(where: \.isRunning), !self.hud.isMouseInside else {
                self?.scheduleHide(); return
            }
            self.hud.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (hasFailure ? 12 : 6), execute: work)
    }
}

/// Floating list of jobs in the top-right corner.
final class JobHUD: NSPanel {
    init(center: JobCenter) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 80),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        let host = NSHostingView(rootView: JobListView(center: center, onResize: { [weak self] h in self?.resize(height: h) }))
        contentView = host
    }

    override var canBecomeKey: Bool { false }

    var isMouseInside: Bool { isVisible && NSMouseInRect(NSEvent.mouseLocation, frame, false) }

    func present() {
        place(height: frame.height)
        orderFrontRegardless()
    }

    private func resize(height: CGFloat) { place(height: height) }

    private func place(height: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        setFrame(NSRect(x: vf.maxX - 352, y: vf.maxY - height - 12, width: 340, height: height), display: true)
    }
}

struct JobListView: View {
    @ObservedObject var center: JobCenter
    var onResize: (CGFloat) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(center.recent.prefix(5)) { job in JobRow(job: job) }
        }
        .padding(8)
        .frame(width: 340)
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { onResize(g.size.height) }
                    .onChange(of: g.size.height) { onResize($0) }
            }
        )
    }
}

struct JobRow: View {
    @ObservedObject var job: Job

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                switch job.state {
                case .running:
                    ProgressView(value: job.progress).progressViewStyle(.linear).tint(.wheelAccent)
                case .done:
                    Text(job.outputs.count == 1 ? job.outputs[0].lastPathComponent : "\(job.outputs.count) items")
                        .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                case .failed(let msg):
                    Text(msg).font(.system(size: 10)).foregroundColor(.red).lineLimit(4).textSelection(.enabled)
                case .cancelled:
                    Text("Cancelled").font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
            if job.isRunning {
                Button { JobCenter.shared.cancel(job) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundColor(.secondary).help("Cancel")
            } else if job.state == .done {
                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting(job.outputs) }
                    .buttonStyle(.borderless).font(.system(size: 11, weight: .semibold))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
        .onTapGesture(count: 2) { if job.state == .done, let f = job.outputs.first { NSWorkspace.shared.open(f) } }
    }

    @ViewBuilder var icon: some View {
        switch job.state {
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.system(size: 18))
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.system(size: 18))
        case .cancelled: Image(systemName: "slash.circle").foregroundColor(.secondary).font(.system(size: 18))
        }
    }
}
