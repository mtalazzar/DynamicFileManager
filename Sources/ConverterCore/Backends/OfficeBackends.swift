import Foundation

enum SlidesBackend {
    static let inputs: Set<FileKind> = [.pptx, .ppt, .odp, .key]
    static let targets: [FileKind] = [.pdf, .jpg, .png, .pptx, .key, .odp]

    static func pdf(_ ctx: JobContext) async throws -> URL {
        if FileKind.of(ctx.input) == .key {
            let out = ctx.temp("slides.pdf")
            try await IWork.export(ctx.input, with: .keynote, to: out, format: "PDF")
            return out
        }
        return try await LibreOffice.convert(ctx.input, to: "pdf", ext: "pdf", ctx: ctx)
    }

    static func pptx(_ ctx: JobContext) async throws -> URL {
        switch FileKind.of(ctx.input) {
        case .pptx: return ctx.input
        case .key:
            let out = ctx.temp("slides.pptx")
            try await IWork.export(ctx.input, with: .keynote, to: out, format: "Microsoft PowerPoint")
            return out
        default:
            return try await LibreOffice.convert(ctx.input, to: "pptx", ext: "pptx", ctx: ctx)
        }
    }

    static func convert(_ ctx: JobContext, to target: FileKind) async throws -> [URL] {
        let out = ctx.out(ctx.baseName, target.ext)
        switch target {
        case .pdf:
            try FileManager.default.moveItem(at: try await pdf(ctx), to: out)
        case .jpg, .png:
            ctx.progress(0.1)
            return try await PDFUtil.renderAll(ctx, pdf: try await pdf(ctx), kind: target, dpi: 200)
        case .pptx:
            try FileManager.default.copyItem(at: try await pptx(ctx), to: out)
        case .key:
            try await IWork.saveNative(try await pptx(ctx), with: .keynote, to: out)
        case .odp:
            let src = FileKind.of(ctx.input) == .key ? try await pptx(ctx) : ctx.input
            try FileManager.default.moveItem(at: try await LibreOffice.convert(src, to: "odp", ext: "odp", ctx: ctx), to: out)
        default:
            throw ConvertError.unsupported(target.label)
        }
        return [out]
    }

    static var operations: [FileOp] {
        targets.map { target in
            var inputs = inputs.subtracting([target])
            // Keynote → Keynote-only paths still need LibreOffice for odp; Keynote app covers pdf/pptx.
            var helpers: [Helper] = [.libreoffice]
            if target == .key { helpers = [.keynote]; inputs.remove(.odp) }
            return FileOp(id: "convert.slides.\(target.rawValue)", kind: .convert, title: target.label,
                             symbol: target == .jpg || target == .png ? "photo" : "rectangle.on.rectangle",
                             group: target == .pdf ? "PDF" : (target == .jpg || target == .png) ? "Image" : "Slides",
                             inputs: inputs, helpers: helpers) { ctx in
                try await convert(ctx, to: target)
            }
        }
    }
}

enum SheetBackend {
    static let inputs: Set<FileKind> = [.xlsx, .xls, .ods, .csv, .tsv, .numbers]
    static let targets: [FileKind] = [.xlsx, .ods, .csv, .tsv, .pdf, .numbers]

    /// A file LibreOffice can open, plus the input filter it needs.
    static func source(_ ctx: JobContext) async throws -> (URL, String?) {
        switch FileKind.of(ctx.input) {
        case .numbers:
            let xlsx = ctx.temp("sheet.xlsx")
            try await IWork.export(ctx.input, with: .numbers, to: xlsx, format: "Microsoft Excel")
            return (xlsx, nil)
        case .tsv: return (ctx.input, "CSV:9,34,76")
        case .csv: return (ctx.input, "CSV:44,34,76")
        default: return (ctx.input, nil)
        }
    }

    static func convert(_ ctx: JobContext, to target: FileKind) async throws -> URL {
        let out = ctx.out(ctx.baseName, target.ext)
        if target == .pdf, FileKind.of(ctx.input) == .numbers {
            try await IWork.export(ctx.input, with: .numbers, to: out, format: "PDF")
            return out
        }
        let (src, infilter) = try await source(ctx)
        let produced: URL
        switch target {
        case .xlsx:
            if FileKind.of(src) == .xlsx && src != ctx.input { produced = src; break }
            produced = try await LibreOffice.convert(src, to: "xlsx:Calc MS Excel 2007 XML", ext: "xlsx", ctx: ctx, infilter: infilter)
        case .ods: produced = try await LibreOffice.convert(src, to: "ods", ext: "ods", ctx: ctx, infilter: infilter)
        case .csv:
            produced = try await LibreOffice.convert(src, to: "csv:Text - txt - csv (StarCalc):44,34,76,1", ext: "csv", ctx: ctx, infilter: infilter)
        case .tsv:
            produced = try await LibreOffice.convert(src, to: "csv:Text - txt - csv (StarCalc):9,34,76,1", ext: "csv", ctx: ctx, infilter: infilter)
        case .pdf: produced = try await LibreOffice.convert(src, to: "pdf", ext: "pdf", ctx: ctx, infilter: infilter)
        case .numbers:
            var xlsx = src
            if FileKind.of(src) != .xlsx {
                xlsx = try await LibreOffice.convert(src, to: "xlsx:Calc MS Excel 2007 XML", ext: "xlsx", ctx: ctx, infilter: infilter)
            }
            try await IWork.saveNative(xlsx, with: .numbers, to: out)
            return out
        default: throw ConvertError.unsupported(target.label)
        }
        try FileManager.default.moveItem(at: produced, to: out)
        return out
    }

    static var operations: [FileOp] {
        targets.map { target in
            FileOp(id: "convert.sheet.\(target.rawValue)", kind: .convert, title: target.label,
                      symbol: target == .pdf ? "doc.richtext" : "tablecells", group: target == .pdf ? "PDF" : "Spreadsheet",
                      inputs: inputs.subtracting([target]),
                      helpers: target == .numbers ? [.numbers, .libreoffice] : [.libreoffice]) { ctx in
                [try await convert(ctx, to: target)]
            }
        }
    }
}

enum SubtitleBackend {
    struct Cue { var start: Double; var end: Double; var text: [String] }

    static func parseTime(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for p in parts { guard let v = Double(p) else { return nil }; total = total * 60 + v }
        return total
    }

    static func format(_ t: Double, sep: String) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, sep, ms % 1000)
    }

    static func parse(_ text: String) -> [Cue] {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{FEFF}", with: "")
            .components(separatedBy: "\n\n")
        var cues: [Cue] = []
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let i = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let times = lines[i].components(separatedBy: "-->")
            guard times.count == 2, let a = parseTime(times[0]),
                  let b = parseTime(times[1].split(separator: " ").first.map(String.init) ?? "") else { continue }
            let body = lines[(i + 1)...].filter { !$0.isEmpty }
            cues.append(Cue(start: a, end: b, text: body))
        }
        return cues
    }

    static func write(_ cues: [Cue], as kind: FileKind) -> String {
        switch kind {
        case .srt:
            return cues.enumerated().map { i, c in
                "\(i + 1)\n\(format(c.start, sep: ",")) --> \(format(c.end, sep: ","))\n" + c.text.joined(separator: "\n")
            }.joined(separator: "\n\n") + "\n"
        case .vtt:
            return "WEBVTT\n\n" + cues.map { c in
                "\(format(c.start, sep: ".")) --> \(format(c.end, sep: "."))\n" + c.text.joined(separator: "\n")
            }.joined(separator: "\n\n") + "\n"
        default:
            let stripTags = { (s: String) in s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }
            return cues.map { $0.text.map(stripTags).joined(separator: " ") }.joined(separator: "\n") + "\n"
        }
    }

    static var operations: [FileOp] {
        [FileKind.srt, .vtt, .txt].map { target in
            FileOp(id: "convert.subtitle.\(target.rawValue)", kind: .convert, title: target.label, symbol: "captions.bubble",
                      group: "Subtitle", inputs: Set([FileKind.srt, .vtt]).subtracting([target])) { ctx in
                let text = try String(contentsOf: ctx.input, encoding: .utf8)
                let cues = parse(text)
                guard !cues.isEmpty else { throw ConvertError.failed("No subtitles found in \(ctx.input.lastPathComponent).") }
                let out = ctx.out(ctx.baseName, target.ext)
                try write(cues, as: target).write(to: out, atomically: true, encoding: .utf8)
                return [out]
            }
        }
    }
}

enum ArchiveBackend {
    static let archives: Set<FileKind> = [.zip, .tar, .gz, .tgz, .rar, .sevenZip]
    static let anything = Set(FileKind.allCases)

    /// Extracts into a new folder; returns the folder, or the single item inside it.
    static func extract(_ url: URL, into parent: URL, name: String) async throws -> URL {
        let fm = FileManager.default
        let dir = parent.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        switch FileKind.of(url) {
        case .zip: try await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", url.path, dir.path])
        case .tar, .tgz: try await ProcessRunner.run("/usr/bin/tar", ["-xf", url.path, "-C", dir.path])
        case .gz:
            let copy = dir.appendingPathComponent(url.lastPathComponent)
            try fm.copyItem(at: url, to: copy)
            try await ProcessRunner.run("/usr/bin/gunzip", ["-f", copy.path])
        case .rar, .sevenZip:
            // macOS's bsdtar (libarchive) reads RAR, RAR5 and 7z; unar is used when installed.
            if let unar = Helper.unar.path {
                try await ProcessRunner.run(unar, ["-q", "-f", "-D", "-o", dir.path, url.path])
            } else {
                try await ProcessRunner.run("/usr/bin/tar", ["-xf", url.path, "-C", dir.path])
            }
        default: throw ConvertError.unsupported("extracting \(url.lastPathComponent)")
        }
        let items = try fm.contentsOfDirectory(atPath: dir.path).filter { $0 != "__MACOSX" && $0 != ".DS_Store" }
        if items.count == 1 {
            let only = dir.appendingPathComponent(items[0])
            let target = parent.appendingPathComponent("\(UUID().uuidString)-\(items[0])")
            try fm.moveItem(at: only, to: target)
            try fm.removeItem(at: dir)
            let final = parent.appendingPathComponent(items[0])
            try fm.moveItem(at: target, to: final)
            return final
        }
        return dir
    }

    /// Source to compress: the input itself, or its extracted contents if it is an archive.
    static func payload(_ ctx: JobContext) async throws -> URL {
        if archives.contains(FileKind.of(ctx.input)) {
            return try await extract(ctx.input, into: ctx.temp("x-\(UUID().uuidString)"), name: ctx.baseName)
        }
        return ctx.input
    }

    static func zip(_ src: URL, to out: URL) async throws {
        try await ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", src.path, out.path])
    }

    static func tar(_ items: [URL], to out: URL, gzip: Bool) async throws {
        let parent = items[0].deletingLastPathComponent()
        try await ProcessRunner.run("/usr/bin/tar", [gzip ? "-czf" : "-cf", out.path, "-C", parent.path]
                                    + items.map(\.lastPathComponent), environment: ["COPYFILE_DISABLE": "1"])
    }

    static var operations: [FileOp] {
        [
            FileOp(id: "convert.archive.zip", kind: .convert, title: "ZIP", symbol: "doc.zipper", group: "Archive",
                      inputs: anything.subtracting([.zip])) { ctx in
                let src = try await payload(ctx)
                let out = ctx.out(ctx.baseName, "zip")
                try await zip(src, to: out)
                return [out]
            },
            FileOp(id: "convert.archive.tar", kind: .convert, title: "TAR", symbol: "doc.zipper", group: "Archive",
                      inputs: anything.subtracting([.tar])) { ctx in
                let src = try await payload(ctx)
                let out = ctx.out(ctx.baseName, "tar")
                try await tar([src], to: out, gzip: false)
                return [out]
            },
            FileOp(id: "convert.archive.gz", kind: .convert, title: "GZIP", symbol: "doc.zipper", group: "Archive",
                      inputs: anything.subtracting([.gz, .tgz])) { ctx in
                let src = try await payload(ctx)
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: src.path, isDirectory: &isDir)
                if isDir.boolValue {
                    let out = ctx.out(ctx.baseName, "tar.gz")
                    try await tar([src], to: out, gzip: true)
                    return [out]
                }
                let copy = ctx.out(src.lastPathComponent, "")
                try FileManager.default.copyItem(at: src, to: copy)
                try await ProcessRunner.run("/usr/bin/gzip", ["-f", copy.path])
                return [copy.appendingPathExtension("gz")]
            },
            FileOp(id: "convert.archive.extract", kind: .convert, title: "Extract", symbol: "archivebox", group: "Archive",
                      inputs: archives) { ctx in
                [try await extract(ctx.input, into: ctx.workDir, name: ctx.baseName)]
            },
        ]
    }
}
