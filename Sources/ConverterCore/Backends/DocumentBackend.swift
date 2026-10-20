import Foundation

enum DocumentBackend {
    static let inputs: Set<FileKind> = [.docx, .doc, .odt, .pages, .md, .txt, .epub, .html, .rtf, .rtfd, .textClipping]
    static let targets: [FileKind] = [.docx, .pages, .md, .txt, .epub, .html, .pdf, .rtf, .odt]

    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Plain text → simple HTML (paragraphs on blank lines, line breaks kept).
    static func textToHTML(_ text: String, title: String) -> String {
        let paras = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
            .map { "<p>" + htmlEscape($0).replacingOccurrences(of: "\n", with: "<br>\n") + "</p>" }
        return "<!doctype html><html><head><meta charset=\"utf-8\"><title>\(htmlEscape(title))</title></head><body>\n"
            + paras.joined(separator: "\n") + "\n</body></html>\n"
    }

    /// Text inside a Finder .textClipping (a property list in the data fork).
    static func clippingText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let utis = plist["UTI-Data"] as? [String: Any] else {
            throw ConvertError.failed("Could not read the text clipping.")
        }
        for key in ["public.utf8-plain-text", "public.plain-text", "public.utf16-plain-text"] {
            if let s = utis[key] as? String { return s }
            if let d = utis[key] as? Data, let s = String(data: d, encoding: key.contains("utf16") ? .utf16 : .utf8) { return s }
        }
        if let rtf = utis["public.rtf"] as? Data,
           let attr = NSAttributedString(rtf: rtf, documentAttributes: nil) { return attr.string }
        throw ConvertError.failed("The text clipping contains no text.")
    }

    /// Returns a file pandoc can read, plus its pandoc reader name.
    static func pandocSource(_ ctx: JobContext) async throws -> (URL, String) {
        let input = ctx.input
        switch FileKind.of(input) {
        case .docx: return (input, "docx")
        case .odt: return (input, "odt")
        case .md: return (input, "markdown")
        case .epub: return (input, "epub")
        case .html: return (input, "html")
        case .txt:
            let html = ctx.temp("text.html")
            let text = try (try? String(contentsOf: input, encoding: .utf8)) ?? String(contentsOf: input, encoding: .isoLatin1)
            try textToHTML(text, title: ctx.baseName).write(to: html, atomically: true, encoding: .utf8)
            return (html, "html")
        case .textClipping:
            let html = ctx.temp("clip.html")
            try textToHTML(try clippingText(input), title: ctx.baseName).write(to: html, atomically: true, encoding: .utf8)
            return (html, "html")
        case .rtf, .rtfd, .doc:
            let docx = ctx.temp("textutil.docx")
            try await ProcessRunner.run("/usr/bin/textutil", ["-convert", "docx", input.path, "-output", docx.path])
            return (docx, "docx")
        case .pages:
            let docx = ctx.temp("pages.docx")
            try await IWork.export(input, with: .pages, to: docx, format: "Microsoft Word")
            return (docx, "docx")
        default:
            throw ConvertError.unsupported(input.lastPathComponent)
        }
    }

    static func pandoc(_ src: (URL, String), to writer: String, out: URL, extra: [String] = [], cwd: URL? = nil) async throws {
        try await ProcessRunner.run(try Helper.pandoc.require(),
                                    [src.0.path, "-f", src.1, "-t", writer, "-o", out.path] + extra,
                                    cwd: cwd ?? src.0.deletingLastPathComponent())
    }

    /// Any document → DOCX (used by the Pages and PDF paths).
    static func docx(_ ctx: JobContext) async throws -> URL {
        let kind = FileKind.of(ctx.input)
        if kind == .docx { return ctx.input }
        let src = try await pandocSource(ctx)
        if src.1 == "docx" { return src.0 }
        let out = ctx.temp("doc.docx")
        try await pandoc(src, to: "docx", out: out)
        return out
    }

    static func convert(_ ctx: JobContext, to target: FileKind) async throws -> URL {
        let out = ctx.out(ctx.baseName, target.ext)
        let title = ["--metadata", "title=\(ctx.baseName)"]
        switch target {
        case .pdf:
            if FileKind.of(ctx.input) == .pages {
                try await IWork.export(ctx.input, with: .pages, to: out, format: "PDF")
                return out
            }
            let kind = FileKind.of(ctx.input)
            let direct: Set<FileKind> = [.docx, .doc, .odt, .rtf, .html, .txt]
            let source = direct.contains(kind) ? ctx.input : try await docx(ctx)
            let pdf = try await LibreOffice.convert(source, to: "pdf", ext: "pdf", ctx: ctx)
            try FileManager.default.moveItem(at: pdf, to: out)
        case .pages:
            try await IWork.saveNative(try await docx(ctx), with: .pages, to: out)
        case .docx:
            let d = try await docx(ctx)
            try FileManager.default.copyItem(at: d, to: out)
        case .md:
            try await pandoc(try await pandocSource(ctx), to: "gfm", out: out, extra: ["--wrap=none"])
        case .txt:
            try await pandoc(try await pandocSource(ctx), to: "plain", out: out, extra: ["--wrap=none"])
        case .epub:
            try await pandoc(try await pandocSource(ctx), to: "epub", out: out, extra: title)
        case .html:
            try await pandoc(try await pandocSource(ctx), to: "html", out: out,
                             extra: ["--standalone", "--embed-resources"] + title)
        case .rtf:
            try await pandoc(try await pandocSource(ctx), to: "rtf", out: out, extra: ["--standalone"])
        case .odt:
            try await pandoc(try await pandocSource(ctx), to: "odt", out: out)
        default:
            throw ConvertError.unsupported(target.label)
        }
        return out
    }

    static var operations: [FileOp] {
        targets.map { target in
            let helpers: [Helper]
            switch target {
            case .pdf: helpers = [.libreoffice, .pandoc]
            case .pages: helpers = [.pages, .pandoc]
            default: helpers = [.pandoc]
            }
            var inputs = inputs.subtracting([target])
            if target == .rtf { inputs.remove(.rtfd) }
            return FileOp(id: "convert.doc.\(target.rawValue)", kind: .convert, title: target.label,
                             symbol: target == .pdf ? "doc.richtext" : "doc.text",
                             group: target == .pdf ? "PDF" : "Document", inputs: inputs, helpers: helpers) { ctx in
                [try await convert(ctx, to: target)]
            }
        }
    }
}
