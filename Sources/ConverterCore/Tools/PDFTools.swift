import Foundation
import PDFKit
import CoreText
import ImageIO

enum PDFTools {
    static let pdf: Set<FileKind> = [.pdf]

    /// Parses "1-3, 5, 8-" into zero-based page indexes (in the given order, duplicates kept).
    static func pages(_ spec: String, count: Int) throws -> [Int] {
        var result: [Int] = []
        for raw in spec.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let part = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if part.isEmpty { continue }
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            func num(_ s: String, _ fallback: Int) throws -> Int {
                if s.isEmpty || s == "end" { return fallback }
                guard let v = Int(s), v >= 1, v <= count else { throw ConvertError.failed("Page \"\(s)\" is out of range (1–\(count)).") }
                return v
            }
            if bounds.count == 1 {
                result.append(try num(bounds[0], count) - 1)
            } else if bounds.count == 2 {
                let a = try num(bounds[0], 1), b = try num(bounds[1], count)
                result += a <= b ? Array((a - 1)...(b - 1)) : Array(stride(from: a - 1, through: b - 1, by: -1))
            } else {
                throw ConvertError.failed("Could not read the page range \"\(part)\".")
            }
        }
        guard !result.isEmpty else { throw ConvertError.failed("Enter page numbers, e.g. 1-3, 5.") }
        return result
    }

    static func write(_ doc: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any] = [:]) throws {
        guard doc.write(to: url, withOptions: options) else { throw ConvertError.failed("Could not save \(url.lastPathComponent).") }
    }

    static func subset(_ doc: PDFDocument, _ indexes: [Int]) -> PDFDocument {
        let out = PDFDocument()
        for (i, idx) in indexes.enumerated() {
            if let p = doc.page(at: idx)?.copy() as? PDFPage { out.insert(p, at: i) }
        }
        return out
    }

    static func op(_ id: String, _ title: String, _ symbol: String, helpers: [Helper] = [], options: [OptionSpec] = [],
                   _ perform: @escaping @Sendable (JobContext) async throws -> [URL]) -> FileOp {
        FileOp(id: "tool.pdf.\(id)", kind: .tool, title: title, symbol: symbol, group: "PDF", inputs: pdf,
                  helpers: helpers, options: options, perform: perform)
    }

    static func ghostscript(_ ctx: JobContext, out: URL, args: [String]) async throws {
        try await ProcessRunner.run(try Helper.ghostscript.require(),
                                    ["-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.5", "-dNOPAUSE", "-dQUIET", "-dBATCH", "-dSAFER"]
                                    + args + ["-sOutputFile=\(out.path)", ctx.input.path])
    }

    /// Redraws every page into a new PDF and lets `overlay` draw on top (page-space coordinates, upright).
    static func stamp(_ doc: PDFDocument, to url: URL, ctx: JobContext,
                      overlay: (CGContext, CGRect, Int, Int) -> Void) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else { throw ConvertError.failed("Could not create PDF.") }
        var box = CGRect.zero
        guard let pdfCtx = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw ConvertError.failed("Could not create PDF.") }
        let n = doc.pageCount
        for i in 0..<n {
            guard let page = doc.page(at: i) else { continue }
            let b = page.bounds(for: .cropBox)
            let rotated = page.rotation % 180 != 0
            var rect = CGRect(x: 0, y: 0, width: rotated ? b.height : b.width, height: rotated ? b.width : b.height)
            let info = [kCGPDFContextMediaBox as String: NSData(bytes: &rect, length: MemoryLayout<CGRect>.size)] as CFDictionary
            pdfCtx.beginPDFPage(info)
            pdfCtx.saveGState()
            page.draw(with: .cropBox, to: pdfCtx)
            pdfCtx.restoreGState()
            overlay(pdfCtx, rect, i, n)
            pdfCtx.endPDFPage()
            ctx.progress(Double(i + 1) / Double(n))
        }
        pdfCtx.closePDF()
    }

    static func drawText(_ text: String, in ctx: CGContext, at point: CGPoint, size: CGFloat, alpha: CGFloat,
                         angle: CGFloat = 0, bold: Bool = false, centered: Bool = true) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.2, alpha: alpha),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.saveGState()
        ctx.translateBy(x: point.x, y: point.y)
        ctx.rotate(by: angle)
        ctx.textPosition = centered ? CGPoint(x: -bounds.midX, y: -bounds.midY) : .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    static var operations: [FileOp] {
        [
            op("compress", "Compress", "arrow.down.right.and.arrow.up.left", helpers: [.ghostscript],
               options: [OptionSpec("quality", "Quality", .choice(["Balanced", "Smallest", "High"]), default: "Balanced")]) { ctx in
                let preset = ["Balanced": "/ebook", "Smallest": "/screen", "High": "/printer"][ctx.option("quality")] ?? "/ebook"
                let out = ctx.out("\(ctx.baseName) compressed", "pdf")
                ctx.progress(0.1)
                try await ghostscript(ctx, out: out, args: ["-dPDFSETTINGS=\(preset)", "-dDetectDuplicateImages=true"])
                let before = (try? ctx.input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let after = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if after >= before { throw ConvertError.failed("This PDF is already well compressed; the result would not be smaller.") }
                return [out]
            },
            op("split", "Split", "square.split.2x1",
               options: [OptionSpec("mode", "Split", .choice(["Every page", "By ranges"]), default: "Every page"),
                         OptionSpec("ranges", "Ranges (one file each)", .text(placeholder: "1-3, 4-6, 7-"), default: "")]) { ctx in
                let doc = try PDFUtil.open(ctx.input)
                let n = doc.pageCount
                let folder = ctx.out("\(ctx.baseName) split", "")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var groups: [(String, [Int])] = []
                if ctx.option("mode") == "By ranges" {
                    for part in ctx.option("ranges").split(separator: ",") {
                        let label = part.trimmingCharacters(in: .whitespaces)
                        groups.append((label, try pages(label, count: n)))
                    }
                    if groups.isEmpty { throw ConvertError.failed("Enter ranges, e.g. 1-3, 4-6.") }
                } else {
                    groups = (0..<n).map { (String($0 + 1), [$0]) }
                }
                for (i, g) in groups.enumerated() {
                    try write(subset(doc, g.1), to: folder.appendingPathComponent("\(ctx.baseName) \(g.0).pdf"))
                    ctx.progress(Double(i + 1) / Double(groups.count))
                }
                return [folder]
            },
            op("extract", "Extract Pages", "doc.on.doc",
               options: [OptionSpec("pages", "Pages to keep", .text(placeholder: "1-3, 5"), default: "1")]) { ctx in
                let doc = try PDFUtil.open(ctx.input)
                let spec = ctx.option("pages", "1")
                let out = ctx.out("\(ctx.baseName) pages \(spec.replacingOccurrences(of: " ", with: ""))", "pdf")
                try write(subset(doc, try pages(spec, count: doc.pageCount)), to: out)
                return [out]
            },
            op("delete", "Delete Pages", "trash",
               options: [OptionSpec("pages", "Pages to delete", .text(placeholder: "2, 4-5"), default: "")]) { ctx in
                let doc = try PDFUtil.open(ctx.input)
                let drop = Set(try pages(ctx.option("pages"), count: doc.pageCount))
                let keep = (0..<doc.pageCount).filter { !drop.contains($0) }
                guard !keep.isEmpty else { throw ConvertError.failed("That would delete every page.") }
                let out = ctx.out("\(ctx.baseName) edited", "pdf")
                try write(subset(doc, keep), to: out)
                return [out]
            },
            op("reorder", "Reorder Pages", "arrow.up.arrow.down",
               options: [OptionSpec("mode", "Order", .choice(["Reverse", "Custom"]), default: "Reverse"),
                         OptionSpec("order", "Custom order", .text(placeholder: "3, 1, 2, 4-"), default: "")]) { ctx in
                let doc = try PDFUtil.open(ctx.input)
                let n = doc.pageCount
                let order = ctx.option("mode") == "Custom" ? try pages(ctx.option("order"), count: n) : Array((0..<n).reversed())
                let out = ctx.out("\(ctx.baseName) reordered", "pdf")
                try write(subset(doc, order), to: out)
                return [out]
            },
            op("rotate", "Rotate", "rotate.right",
               options: [OptionSpec("angle", "Rotate", .choice(["90° right", "90° left", "180°"]), default: "90° right"),
                         OptionSpec("pages", "Pages (empty = all)", .text(placeholder: "all"), default: "")]) { ctx in
                let doc = try PDFUtil.open(ctx.input)
                let deg = ["90° right": 90, "90° left": -90, "180°": 180][ctx.option("angle")] ?? 90
                let spec = ctx.option("pages")
                let which = spec.isEmpty || spec.lowercased() == "all" ? Array(0..<doc.pageCount) : try pages(spec, count: doc.pageCount)
                for i in Set(which) { if let p = doc.page(at: i) { p.rotation = ((p.rotation + deg) % 360 + 360) % 360 } }
                let out = ctx.out("\(ctx.baseName) rotated", "pdf")
                try write(doc, to: out)
                return [out]
            },
            op("ocr", "OCR", "text.viewfinder", helpers: [.tesseract],
               options: [OptionSpec("lang", "Language", .choice(["eng", "ita", "eng+ita", "deu", "fra", "spa"]), default: "eng")]) { ctx in
                let doc = try PDFUtil.open(ctx.input)
                let tess = try Helper.tesseract.require()
                let result = PDFDocument()
                let n = doc.pageCount
                for i in 0..<n {
                    try ctx.checkCancelled()
                    guard let page = doc.page(at: i), let img = PDFUtil.render(page, dpi: 300) else { continue }
                    let png = ctx.temp("p\(i).png")
                    try ImageIOUtil.writeImageIO(img, to: png, type: "public.png", quality: 1,
                                                 metadata: [kCGImagePropertyDPIWidth: 300, kCGImagePropertyDPIHeight: 300])
                    let base = ctx.temp("p\(i)")
                    let r = try await ProcessRunner.runAllowingFailure(tess, [png.path, base.path, "-l", ctx.option("lang", "eng"), "--dpi", "300", "pdf"])
                    if r.status != 0 {
                        if r.stderr.contains("Failed loading language") {
                            throw ConvertError.failed("Tesseract language \"\(ctx.option("lang"))\" is not installed (brew install tesseract-lang).")
                        }
                        throw ConvertError.failed("Tesseract failed: \(r.stderr.suffix(300))")
                    }
                    if let pd = PDFDocument(url: base.appendingPathExtension("pdf")), let p = pd.page(at: 0) {
                        result.insert(p, at: result.pageCount)
                    }
                    ctx.progress(Double(i + 1) / Double(n))
                }
                let out = ctx.out("\(ctx.baseName) OCR", "pdf")
                try write(result, to: out)
                return [out]
            },
            op("encrypt", "Lock", "lock",
               options: [OptionSpec("password", "Password", .secure, default: "")]) { ctx in
                let pw = ctx.option("password")
                guard !pw.isEmpty else { throw ConvertError.failed("Enter a password.") }
                let doc = try PDFUtil.open(ctx.input)
                let out = ctx.out("\(ctx.baseName) protected", "pdf")
                try write(doc, to: out, options: [.userPasswordOption: pw, .ownerPasswordOption: pw])
                return [out]
            },
            op("decrypt", "Unlock", "lock.open",
               options: [OptionSpec("password", "Current password", .secure, default: "")]) { ctx in
                guard let doc = PDFDocument(url: ctx.input) else { throw ConvertError.failed("Could not open the PDF.") }
                if doc.isLocked && !doc.unlock(withPassword: ctx.option("password")) {
                    throw ConvertError.failed("Wrong password.")
                }
                let out = ctx.out("\(ctx.baseName) unlocked", "pdf")
                try write(doc, to: out)
                return [out]
            },
            op("watermark", "Watermark", "seal",
               options: [OptionSpec("text", "Text", .text(placeholder: "CONFIDENTIAL"), default: "CONFIDENTIAL"),
                         OptionSpec("opacity", "Opacity", .choice(["15%", "25%", "40%", "60%"]), default: "15%")]) { ctx in
                let doc = try PDFUtil.open(ctx.input)
                let text = ctx.option("text", "CONFIDENTIAL")
                let alpha = (Double(ctx.option("opacity", "15%").dropLast()) ?? 15) / 100
                let out = ctx.out("\(ctx.baseName) watermarked", "pdf")
                try stamp(doc, to: out, ctx: ctx) { c, rect, _, _ in
                    let diag = sqrt(rect.width * rect.width + rect.height * rect.height)
                    let size = min(140, diag * 0.75 / CGFloat(max(text.count, 1)) * 1.6)
                    drawText(text, in: c, at: CGPoint(x: rect.midX, y: rect.midY), size: size, alpha: alpha,
                             angle: atan2(rect.height, rect.width), bold: true)
                }
                return [out]
            },
            op("numbers", "Page Numbers", "number",
               options: [OptionSpec("format", "Format", .choice(["1", "Page 1", "1 / N", "Page 1 of N"]), default: "1"),
                         OptionSpec("position", "Position", .choice(["Bottom center", "Bottom right", "Top right", "Top center"]), default: "Bottom center")]) { ctx in
                let doc = try PDFUtil.open(ctx.input)
                let fmt = ctx.option("format", "1"), pos = ctx.option("position", "Bottom center")
                let out = ctx.out("\(ctx.baseName) numbered", "pdf")
                try stamp(doc, to: out, ctx: ctx) { c, rect, i, n in
                    let label = fmt.replacingOccurrences(of: "1", with: String(i + 1)).replacingOccurrences(of: "N", with: String(n))
                    let y = pos.hasPrefix("Top") ? rect.maxY - 28 : rect.minY + 24
                    let x = pos.hasSuffix("right") ? rect.maxX - 48 : rect.midX
                    drawText(label, in: c, at: CGPoint(x: x, y: y), size: 10, alpha: 1)
                }
                return [out]
            },
            op("grayscale", "Black & White", "circle.lefthalf.filled", helpers: [.ghostscript]) { ctx in
                let out = ctx.out("\(ctx.baseName) bw", "pdf")
                ctx.progress(0.1)
                try await ghostscript(ctx, out: out, args: ["-sColorConversionStrategy=Gray", "-dProcessColorModel=/DeviceGray",
                                                            "-dOverrideICC"])
                return [out]
            },
        ]
    }
}

enum MergeTools {
    static let mergeablePDF: Set<FileKind> = ImageBackend.readable.union([.pdf])

    static var operations: [FileOp] {
        [
            FileOp(id: "tool.merge.pdf", kind: .tool, title: "Merge into PDF", symbol: "square.stack.3d.down.right",
                      group: "Merge", inputs: mergeablePDF, combinesInputs: true, minInputs: 2) { ctx in
                let result = PDFDocument()
                for (i, url) in ctx.inputs.enumerated() {
                    try ctx.checkCancelled()
                    if FileKind.of(url) == .pdf {
                        let doc = try PDFUtil.open(url)
                        for p in 0..<doc.pageCount { if let page = doc.page(at: p) { result.insert(page, at: result.pageCount) } }
                    } else {
                        let img = try await ImageIOUtil.load(url).image
                        let tmp = ctx.temp("img\(i).pdf")
                        try ImageIOUtil.writePDF([img], to: tmp, dpi: 150)
                        if let page = PDFDocument(url: tmp)?.page(at: 0) { result.insert(page, at: result.pageCount) }
                    }
                    ctx.progress(Double(i + 1) / Double(ctx.inputs.count))
                }
                let out = ctx.out("\(JobContext.baseName(of: ctx.inputs[0])) merged", "pdf")
                try PDFTools.write(result, to: out)
                return [out]
            },
            FileOp(id: "tool.merge.video", kind: .tool, title: "Merge Videos", symbol: "film.stack", group: "Merge",
                      inputs: AVBackend.videoIn, helpers: [.ffmpeg, .ffprobe], combinesInputs: true, minInputs: 2) { ctx in
                // Normalise every clip to the first clip's size so they can be joined losslessly.
                let first = try await FFmpeg.probe(ctx.inputs[0])
                let W = max(2, first.width / 2 * 2), H = max(2, first.height / 2 * 2)
                var infos: [FFmpeg.Info] = []
                for u in ctx.inputs { infos.append(try await FFmpeg.probe(u)) }
                let total = infos.reduce(0) { $0 + $1.duration }
                var parts: [URL] = []
                var done = 0.0
                for (i, url) in ctx.inputs.enumerated() {
                    let part = ctx.temp("part\(i).mp4")
                    var args: [String] = []
                    if !infos[i].hasAudio { args += ["-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000"] }
                    args += ["-i", url.path]
                    let vIndex = infos[i].hasAudio ? 0 : 1
                    args += ["-map", "\(vIndex):v:0", "-map", infos[i].hasAudio ? "0:a:0" : "0:a:0", "-shortest",
                             "-vf", "scale=\(W):\(H):force_original_aspect_ratio=decrease,pad=\(W):\(H):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30",
                             "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
                             "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2"]
                    let lo = total > 0 ? done / total : Double(i) / Double(ctx.inputs.count)
                    done += infos[i].duration
                    let hi = total > 0 ? done / total : Double(i + 1) / Double(ctx.inputs.count)
                    try await FFmpeg.run(args, output: part, duration: infos[i].duration, ctx: ctx, progressRange: lo * 0.95...hi * 0.95)
                    parts.append(part)
                }
                let list = ctx.temp("list.txt")
                try parts.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n")
                    .write(to: list, atomically: true, encoding: .utf8)
                let out = ctx.out("\(JobContext.baseName(of: ctx.inputs[0])) merged", "mp4")
                try await FFmpeg.run(["-f", "concat", "-safe", "0", "-i", list.path, "-c", "copy", "-movflags", "+faststart"],
                                     output: out, duration: 0, ctx: ctx)
                return [out]
            },
            FileOp(id: "tool.merge.audio", kind: .tool, title: "Merge Audio", symbol: "waveform.badge.plus", group: "Merge",
                      inputs: AVBackend.audioIn, helpers: [.ffmpeg, .ffprobe], combinesInputs: true, minInputs: 2) { ctx in
                var args: [String] = []
                var total = 0.0
                for u in ctx.inputs { args += ["-i", u.path]; total += try await FFmpeg.probe(u).duration }
                let n = ctx.inputs.count
                let filter = (0..<n).map { "[\($0):a:0]aresample=48000,aformat=channel_layouts=stereo[a\($0)]" }.joined(separator: ";")
                    + ";" + (0..<n).map { "[a\($0)]" }.joined() + "concat=n=\(n):v=0:a=1[out]"
                let kind = FileKind.of(ctx.inputs[0])
                let out = ctx.out("\(JobContext.baseName(of: ctx.inputs[0])) merged", kind.ext)
                args += ["-filter_complex", filter, "-map", "[out]"] + FFmpeg.codecArgs(for: kind)
                try await FFmpeg.run(args, output: out, duration: total, ctx: ctx)
                return [out]
            },
            FileOp(id: "tool.merge.zip", kind: .tool, title: "Zip Together", symbol: "doc.zipper", group: "Merge",
                      inputs: Set(FileKind.allCases), combinesInputs: true, minInputs: 2) { ctx in
                let folder = ctx.temp("Archive")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for u in ctx.inputs {
                    try FileManager.default.copyItem(at: u, to: OutputNamer.uniqueURL(in: folder, fileName: u.lastPathComponent))
                }
                let out = ctx.out("Archive", "zip")
                try await ArchiveBackend.zip(folder, to: out)
                return [out]
            },
        ]
    }
}
