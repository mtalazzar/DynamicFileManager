import Foundation

/// Picks unique destination names so nothing is ever overwritten.
public enum OutputNamer {
    public static func uniqueURL(in dir: URL, fileName: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(fileName)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let lower = fileName.lowercased()
        let (stem, ext): (String, String) = {
            if lower.hasSuffix(".tar.gz") { return (String(fileName.dropLast(7)), "tar.gz") }
            let u = URL(fileURLWithPath: fileName)
            return (u.deletingPathExtension().lastPathComponent, u.pathExtension)
        }()
        var n = 1
        repeat {
            let name = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            candidate = dir.appendingPathComponent(name)
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }
}

public enum OperationRegistry {
    public static let all: [FileOp] = {
        var ops: [FileOp] = []
        ops += ImageBackend.operations
        ops += AVBackend.operations
        ops += PDFBackend.operations
        ops += DocumentBackend.operations
        ops += SlidesBackend.operations
        ops += SheetBackend.operations
        ops += SubtitleBackend.operations
        ops += ArchiveBackend.operations
        ops += ImageTools.operations
        ops += AVTools.operations
        ops += PDFTools.operations
        ops += MergeTools.operations
        return ops
    }()

    public static func operation(id: String) -> FileOp? { all.first { $0.id == id } }

    /// Operations that accept every one of `urls`. Merges only appear for 2+ files.
    public static func operations(for urls: [URL], kind: OpKind) -> [FileOp] {
        guard !urls.isEmpty else { return [] }
        return all.filter { $0.kind == kind && $0.accepts(urls) && (!$0.combinesInputs || urls.count >= 2 || $0.minInputs == 1) }
    }
}

public final class Engine: @unchecked Sendable {
    public static let shared = Engine()

    /// Runs `op` and returns the final output locations.
    /// - Parameter outputDir: where to save results; nil means next to each input.
    public func run(_ op: FileOp, inputs: [URL], options: Options = [:], outputDir: URL? = nil,
                    progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [URL] {
        if let missing = op.missingHelpers.first { throw ConvertError.missingHelper(missing) }
        var merged = Options()
        for spec in op.options { merged[spec.key] = spec.defaultValue }
        merged.merge(options) { $1 }

        let batches: [[URL]] = op.combinesInputs ? [inputs] : inputs.map { [$0] }
        var results: [URL] = []
        for (i, batch) in batches.enumerated() {
            try Task.checkCancellation()
            let share = 1.0 / Double(batches.count)
            let base = Double(i) * share
            let outs = try await runOne(op, batch, merged, outputDir) { p in progress(base + p * share) }
            results += outs
        }
        progress(1)
        return results
    }

    private func runOne(_ op: FileOp, _ inputs: [URL], _ options: Options, _ outputDir: URL?,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("DynamicFileConverter", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let ctx = JobContext(inputs: inputs, options: options, workDir: work, progress: progress)
        let produced: [URL]
        do {
            produced = try await op.perform(ctx)
        } catch is CancellationError {
            throw ConvertError.cancelled
        }
        try Task.checkCancellation()
        guard !produced.isEmpty else { throw ConvertError.failed("\(op.title) produced no output.") }

        let dest = destinationDir(for: inputs[0], preferred: outputDir)
        var finals: [URL] = []
        for url in produced {
            guard fm.fileExists(atPath: url.path) else {
                throw ConvertError.failed("\(op.title) did not produce \(url.lastPathComponent).")
            }
            let target = OutputNamer.uniqueURL(in: dest, fileName: url.lastPathComponent)
            try fm.moveItem(at: url, to: target)
            finals.append(target)
        }
        return finals
    }

    private func destinationDir(for input: URL, preferred: URL?) -> URL {
        let fm = FileManager.default
        if let preferred {
            try? fm.createDirectory(at: preferred, withIntermediateDirectories: true)
            if fm.isWritableFile(atPath: preferred.path) { return preferred }
        }
        let dir = input.deletingLastPathComponent()
        if fm.isWritableFile(atPath: dir.path) { return dir }
        return fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }
}
