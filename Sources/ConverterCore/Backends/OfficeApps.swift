import Foundation

/// Drives Pages, Keynote and Numbers through AppleScript.
enum IWork {
    enum App: String {
        case pages = "Pages", keynote = "Keynote", numbers = "Numbers"
        var helper: Helper { self == .pages ? .pages : self == .keynote ? .keynote : .numbers }
    }

    static func quote(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Exports `input` with the app's Export command. `format` is an AppleScript export format,
    /// e.g. `PDF`, `Microsoft Word`, `Microsoft PowerPoint`, `Microsoft Excel`, `CSV`, `EPUB`.
    static func export(_ input: URL, with app: App, to output: URL, format: String) async throws {
        _ = try app.helper.require()
        let script = """
        with timeout of 900 seconds
            tell application "\(app.rawValue)"
                set theDoc to open (POSIX file \(quote(input.path)))
                export theDoc to (POSIX file \(quote(output.path))) as \(format)
                close theDoc saving no
            end tell
        end timeout
        """
        try await ProcessRunner.run("/usr/bin/osascript", ["-e", script])
    }

    /// Opens a foreign document (docx/pptx/xlsx) and saves it in the app's native format.
    static func saveNative(_ input: URL, with app: App, to output: URL) async throws {
        _ = try app.helper.require()
        let script = """
        with timeout of 900 seconds
            tell application "\(app.rawValue)"
                set theDoc to open (POSIX file \(quote(input.path)))
                save theDoc in (POSIX file \(quote(output.path)))
                close theDoc saving no
            end tell
        end timeout
        """
        try await ProcessRunner.run("/usr/bin/osascript", ["-e", script])
    }
}

/// Headless LibreOffice conversions.
enum LibreOffice {
    /// Converts `input` with `soffice --convert-to <filter>`; returns the produced file.
    static func convert(_ input: URL, to filter: String, ext: String, ctx: JobContext,
                        infilter: String? = nil) async throws -> URL {
        let soffice = try Helper.libreoffice.require()
        let outDir = ctx.temp("lo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        // A private profile lets conversions run even while LibreOffice is open.
        let profile = Helper.supportDir.appendingPathComponent("lo-profile", isDirectory: true)
        var args = ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--norestore", "--nologo"]
        if let infilter { args.append("--infilter=\(infilter)") }
        args += ["--convert-to", filter, "--outdir", outDir.path, input.path]
        try await ProcessRunner.run(soffice, args)
        let produced = try FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)
            .first { $0.pathExtension.lowercased() == ext.lowercased() }
        guard let produced else { throw ConvertError.failed("LibreOffice did not produce a .\(ext) file.") }
        return produced
    }
}

/// Python helpers (pdf2docx, python-pptx, pdfplumber) run inside the managed venv.
enum PythonScripts {
    static let pdfToDocx = """
    import sys, logging
    logging.disable(logging.CRITICAL)
    from pdf2docx import Converter
    cv = Converter(sys.argv[1])
    cv.convert(sys.argv[2], multi_processing=False)
    cv.close()
    """

    static let pdfToPptx = """
    import sys, io
    import pymupdf as fitz
    from pptx import Presentation
    from pptx.util import Emu
    doc = fitz.open(sys.argv[1])
    prs = Presentation()
    first = doc[0].rect
    prs.slide_width = Emu(int(first.width * 12700))
    prs.slide_height = Emu(int(first.height * 12700))
    blank = prs.slide_layouts[6]
    n = len(doc)
    for i, page in enumerate(doc):
        pix = page.get_pixmap(dpi=200)
        slide = prs.slides.add_slide(blank)
        slide.shapes.add_picture(io.BytesIO(pix.tobytes("png")), 0, 0, prs.slide_width, prs.slide_height)
        text = page.get_text().strip()
        if text:
            slide.notes_slide.notes_text_frame.text = text
        print(f"P {i+1} {n}", flush=True)
    prs.save(sys.argv[2])
    """

    static let pdfToXlsx = """
    import sys, re
    import pdfplumber
    from openpyxl import Workbook
    wb = Workbook()
    wb.remove(wb.active)
    found = False
    with pdfplumber.open(sys.argv[1]) as pdf:
        n = len(pdf.pages)
        lines = []
        for i, page in enumerate(pdf.pages):
            tables = page.extract_tables()
            for t, table in enumerate(tables):
                found = True
                title = f"Page {i+1}" + (f" ({t+1})" if len(tables) > 1 else "")
                ws = wb.create_sheet(title[:31])
                for row in table:
                    ws.append([("" if c is None else c) for c in row])
            for line in (page.extract_text() or "").splitlines():
                lines.append(re.split(r"\\s{2,}", line.strip()))
            print(f"P {i+1} {n}", flush=True)
    if not found:
        ws = wb.create_sheet("Text")
        for row in lines:
            ws.append(row)
    wb.save(sys.argv[2])
    """

    static func run(_ script: String, args: [String], ctx: JobContext) async throws {
        let python = try Helper.python.require()
        let file = ctx.temp("script-\(UUID().uuidString).py")
        try script.write(to: file, atomically: true, encoding: .utf8)
        try await ProcessRunner.run(python, [file.path] + args) { line in
            let parts = line.split(separator: " ")
            if parts.count == 3, parts[0] == "P", let i = Double(parts[1]), let n = Double(parts[2]), n > 0 {
                ctx.progress(i / n * 0.95)
            }
        }
    }
}
