import Foundation
import PDFKit

public enum PDFUtil {
    public static func open(_ url: URL, password: String? = nil) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw ConvertError.failed("Could not open \(url.lastPathComponent) as a PDF.") }
        if doc.isLocked {
            guard let password, doc.unlock(withPassword: password) else {
                throw ConvertError.failed("\(url.lastPathComponent) is password protected. Use Tools → Unlock first.")
            }
        }
        return doc
    }

    /// Renders one page to a bitmap at `dpi`, on a white background.
    public static func render(_ page: PDFPage, dpi: Double) -> CGImage? {
        let box = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let wPt = rotated ? box.height : box.width, hPt = rotated ? box.width : box.height
        let scale = dpi / 72
        let w = Int((wPt * scale).rounded()), h = Int((hPt * scale).rounded())
        guard let ctx = ImageIOUtil.context(width: w, height: h, alpha: false) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: ctx)
        return ctx.makeImage()
    }

    /// Renders every page as `kind` (jpg/png). One page → one file, more → a folder.
    static func renderAll(_ ctx: JobContext, pdf: URL? = nil, kind: FileKind, dpi: Double = 300) async throws -> [URL] {
        let doc = try open(pdf ?? ctx.input, password: ctx.options["password"])
        let n = doc.pageCount
        guard n > 0 else { throw ConvertError.failed("The PDF has no pages.") }
        let folder = ctx.out(ctx.baseName, "")
        if n > 1 { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let digits = String(n).count
        var single: URL?
        for i in 0..<n {
            try ctx.checkCancelled()
            guard let page = doc.page(at: i), let img = render(page, dpi: dpi) else { continue }
            let num = String(repeating: "0", count: digits - String(i + 1).count) + String(i + 1)
            let url = n > 1 ? folder.appendingPathComponent("\(ctx.baseName) \(num).\(kind.ext)") : ctx.out(ctx.baseName, kind.ext)
            try await ImageIOUtil.write(img, to: url, kind: kind, quality: 0.92)
            if n == 1 { single = url }
            ctx.progress(Double(i + 1) / Double(n))
        }
        return [single ?? folder]
    }

    /// Text with a light Markdown structure: larger fonts become headings, blank-line separated paragraphs.
    static func markdown(_ doc: PDFDocument) -> String {
        var sizes: [CGFloat] = []
        var pages: [[(String, CGFloat)]] = []
        for i in 0..<doc.pageCount {
            guard let attr = doc.page(at: i)?.attributedString else { pages.append([]); continue }
            var lines: [(String, CGFloat)] = []
            let ns = attr.string as NSString
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines]) { sub, range, _, _ in
                var size: CGFloat = 0
                attr.enumerateAttribute(.font, in: range) { v, _, _ in
                    if let f = v as? NSFont { size = max(size, f.pointSize) }
                }
                let text = (sub ?? "").trimmingCharacters(in: .whitespaces)
                lines.append((text, size))
                if !text.isEmpty && size > 0 { sizes.append(size) }
            }
            pages.append(lines)
        }
        let body = sizes.sorted().dropFirst(sizes.count / 2).first ?? 12
        var out: [String] = []
        var para: [String] = []
        func flush() { if !para.isEmpty { out.append(para.joined(separator: " ")); para.removeAll() } }
        for lines in pages {
            for (text, size) in lines {
                if text.isEmpty { flush(); continue }
                if size >= body * 1.5 { flush(); out.append("# " + text); continue }
                if size >= body * 1.2 { flush(); out.append("## " + text); continue }
                let bullet = text.hasPrefix("•") || text.hasPrefix("- ") || text.hasPrefix("* ")
                if bullet { flush(); out.append("- " + text.drop(while: { "•-* ".contains($0) })); continue }
                para.append(text)
            }
            flush()
        }
        return out.joined(separator: "\n\n") + "\n"
    }
}

enum PDFBackend {
    static let pdf: Set<FileKind> = [.pdf]

    static func op(_ target: FileKind, symbol: String, group: String, helpers: [Helper] = [],
                   _ perform: @escaping @Sendable (JobContext) async throws -> [URL]) -> FileOp {
        FileOp(id: "convert.pdf.\(target.rawValue)", kind: .convert, title: target.label, symbol: symbol,
                  group: group, inputs: pdf, helpers: helpers, perform: perform)
    }

    static func docx(_ ctx: JobContext) async throws -> URL {
        let out = ctx.out(ctx.baseName, "docx")
        try await PythonScripts.run(PythonScripts.pdfToDocx, args: [ctx.input.path, out.path], ctx: ctx)
        return out
    }

    static var operations: [FileOp] {
        [
            op(.docx, symbol: "doc.text", group: "Document", helpers: [.python]) { ctx in [try await docx(ctx)] },
            op(.pages, symbol: "doc.text", group: "Document", helpers: [.python, .pages]) { ctx in
                let d = try await docx(ctx)
                let tmp = ctx.temp("doc.docx")
                try FileManager.default.moveItem(at: d, to: tmp)
                let out = ctx.out(ctx.baseName, "pages")
                try await IWork.saveNative(tmp, with: .pages, to: out)
                return [out]
            },
            op(.pptx, symbol: "rectangle.on.rectangle", group: "Slides", helpers: [.python]) { ctx in
                let out = ctx.out(ctx.baseName, "pptx")
                try await PythonScripts.run(PythonScripts.pdfToPptx, args: [ctx.input.path, out.path], ctx: ctx)
                return [out]
            },
            op(.xlsx, symbol: "tablecells", group: "Spreadsheet", helpers: [.python]) { ctx in
                let out = ctx.out(ctx.baseName, "xlsx")
                try await PythonScripts.run(PythonScripts.pdfToXlsx, args: [ctx.input.path, out.path], ctx: ctx)
                return [out]
            },
            op(.jpg, symbol: "photo", group: "Image") { ctx in try await PDFUtil.renderAll(ctx, kind: .jpg) },
            op(.png, symbol: "photo", group: "Image") { ctx in try await PDFUtil.renderAll(ctx, kind: .png) },
            op(.txt, symbol: "text.alignleft", group: "Document") { ctx in
                let doc = try PDFUtil.open(ctx.input)
                let out = ctx.out(ctx.baseName, "txt")
                try (doc.string ?? "").write(to: out, atomically: true, encoding: .utf8)
                return [out]
            },
            op(.md, symbol: "number", group: "Document") { ctx in
                let out = ctx.out(ctx.baseName, "md")
                try PDFUtil.markdown(try PDFUtil.open(ctx.input)).write(to: out, atomically: true, encoding: .utf8)
                return [out]
            },
            op(.epub, symbol: "book", group: "Document", helpers: [.pandoc]) { ctx in
                let md = ctx.temp("book.md")
                try PDFUtil.markdown(try PDFUtil.open(ctx.input)).write(to: md, atomically: true, encoding: .utf8)
                let out = ctx.out(ctx.baseName, "epub")
                try await ProcessRunner.run(try Helper.pandoc.require(),
                                            [md.path, "-f", "markdown", "-o", out.path, "--metadata", "title=\(ctx.baseName)"])
                return [out]
            },
            op(.html, symbol: "chevron.left.forwardslash.chevron.right", group: "Document", helpers: [.pandoc]) { ctx in
                let md = ctx.temp("page.md")
                try PDFUtil.markdown(try PDFUtil.open(ctx.input)).write(to: md, atomically: true, encoding: .utf8)
                let out = ctx.out(ctx.baseName, "html")
                try await ProcessRunner.run(try Helper.pandoc.require(),
                                            [md.path, "-f", "markdown", "-s", "-o", out.path, "--metadata", "title=\(ctx.baseName)"])
                return [out]
            },
        ]
    }
}
