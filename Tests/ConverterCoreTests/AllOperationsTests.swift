import XCTest
import PDFKit
import ImageIO
@testable import ConverterCore

/// Generates a fixture of every kind it can, runs every available operation on it, and checks the output opens.
final class AllOperationsTests: XCTestCase {
    static var dir: URL!
    static var fixtures: [URL] = []

    /// Options for operations whose defaults need a value.
    let overrides: [String: Options] = [
        "tool.pdf.encrypt": ["password": "test"],
        "tool.pdf.delete": ["pages": "1"],
        "tool.av.trim": ["start": "0:00.5", "end": "0:01.5"],
    ]
    /// Errors that are expected outcomes rather than bugs.
    let acceptable = ["already well compressed", "no audio track"]

    override class func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dfc-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sema = DispatchSemaphore(value: 0)
        Task { fixtures = (try? await makeFixtures(in: dir)) ?? []; sema.signal() }
        sema.wait()
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    static func sh(_ cmd: String) async throws {
        try await ProcessRunner.run("/bin/sh", ["-c", cmd], cwd: dir)
    }

    static func makeFixtures(in dir: URL) async throws -> [URL] {
        var urls: [URL] = []
        // Image with transparency.
        let ctx = ImageIOUtil.context(width: 400, height: 300)!
        ctx.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 40, y: 40, width: 200, height: 150))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 0.6))
        ctx.fillEllipse(in: CGRect(x: 180, y: 100, width: 180, height: 160))
        let img = ctx.makeImage()!
        for k in [FileKind.png, .jpg, .heic, .tiff, .bmp, .gif, .webp, .avif] {
            let u = dir.appendingPathComponent("image.\(k.ext)")
            try await ImageIOUtil.write(img, to: u, kind: k)
            urls.append(u)
        }
        let svg = dir.appendingPathComponent("vector.svg")
        try #"<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><rect width="200" height="100" fill="tomato"/><circle cx="100" cy="50" r="40" fill="navy"/></svg>"#
            .write(to: svg, atomically: true, encoding: .utf8)
        urls.append(svg)

        // Text documents.
        let md = dir.appendingPathComponent("notes.md")
        try "# Title\n\nSome **bold** text and a list:\n\n- one\n- two\n\n## Section\n\nMore text here.\n".write(to: md, atomically: true, encoding: .utf8)
        let txt = dir.appendingPathComponent("plain.txt")
        try "Hello world.\nSecond line.\n\nNew paragraph with <symbols> & such.\n".write(to: txt, atomically: true, encoding: .utf8)
        let html = dir.appendingPathComponent("page.html")
        try "<html><body><h1>Heading</h1><p>Paragraph <b>bold</b>.</p></body></html>".write(to: html, atomically: true, encoding: .utf8)
        urls += [md, txt, html]
        try await sh("/usr/bin/textutil -convert rtf plain.txt -output letter.rtf")
        try await sh("/usr/bin/textutil -convert doc plain.txt -output legacy.doc")
        urls += [dir.appendingPathComponent("letter.rtf"), dir.appendingPathComponent("legacy.doc")]
        if Helper.pandoc.isAvailable {
            try await sh("'\(Helper.pandoc.path!)' notes.md -o report.docx && '\(Helper.pandoc.path!)' notes.md -o book.epub --metadata title=Book && '\(Helper.pandoc.path!)' notes.md -o open.odt")
            urls += ["report.docx", "book.epub", "open.odt"].map { dir.appendingPathComponent($0) }
        }

        // Multi-page text PDF.
        let longText = (1...3).map { "Page \($0)\n\n" + String(repeating: "Lorem ipsum dolor sit amet. ", count: 120) }.joined(separator: "\u{0C}")
        try longText.write(to: dir.appendingPathComponent("long.txt"), atomically: true, encoding: .utf8)
        try await sh("/usr/sbin/cupsfilter long.txt > doc.pdf 2>/dev/null")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("long.txt"))
        urls.append(dir.appendingPathComponent("doc.pdf"))
        if let d = PDFDocument(url: dir.appendingPathComponent("doc.pdf")) {
            d.page(at: 0)?.rotation = 90
            d.write(to: dir.appendingPathComponent("rotated.pdf"))
        }
        if let py = Helper.python.path {
            let script = "from pptx import Presentation\np=Presentation()\nfor t in ['One','Two']:\n  s=p.slides.add_slide(p.slide_layouts[1]); s.shapes.title.text=t; s.placeholders[1].text='Body '+t\np.save('deck.pptx')\n"
            try script.write(to: dir.appendingPathComponent("mk.py"), atomically: true, encoding: .utf8)
            try await sh("'\(py)' mk.py && rm mk.py")
            urls.append(dir.appendingPathComponent("deck.pptx"))
        }

        // Audio / video.
        if Helper.ffmpeg.isAvailable {
            let ff = Helper.ffmpeg.path!
            try await sh("'\(ff)' -loglevel error -f lavfi -i testsrc=size=320x240:rate=25 -f lavfi -i sine=frequency=440 -t 2 -c:v libx264 -pix_fmt yuv420p -c:a aac clip.mp4")
            try await sh("'\(ff)' -loglevel error -f lavfi -i testsrc=size=640x360:rate=30 -t 1 -c:v libx264 -pix_fmt yuv420p silent.mov")
            try await sh("'\(ff)' -loglevel error -f lavfi -i sine=frequency=330 -t 2 tone.wav && '\(ff)' -loglevel error -i tone.wav tone.mp3")
            urls += ["clip.mp4", "silent.mov", "tone.wav", "tone.mp3"].map { dir.appendingPathComponent($0) }
        }

        // Spreadsheets, slides, subtitles, archives.
        let csv = dir.appendingPathComponent("table.csv")
        try "name,qty,price\napple,3,1.20\npear,5,0.80\n".write(to: csv, atomically: true, encoding: .utf8)
        let tsv = dir.appendingPathComponent("table.tsv")
        try "name\tqty\nplum\t7\n".write(to: tsv, atomically: true, encoding: .utf8)
        urls += [csv, tsv]
        let srt = dir.appendingPathComponent("subs.srt")
        try "1\n00:00:01,000 --> 00:00:02,500\nHello <i>there</i>\n\n2\n00:00:03,000 --> 00:00:04,000\nSecond line\n".write(to: srt, atomically: true, encoding: .utf8)
        urls.append(srt)
        try await sh("mkdir -p folder && cp plain.txt notes.md folder/ && /usr/bin/ditto -c -k --keepParent folder bundle.zip && tar -czf bundle.tar.gz folder && tar -cf bundle.tar folder")
        urls += ["folder", "bundle.zip", "bundle.tar.gz", "bundle.tar"].map { dir.appendingPathComponent($0) }
        if Helper.libreoffice.isAvailable {
            try await sh("'\(Helper.libreoffice.path!)' --headless --convert-to xlsx table.csv >/dev/null && '\(Helper.libreoffice.path!)' --headless --convert-to pptx open.odt >/dev/null 2>&1 || true")
            for f in ["table.xlsx"] where FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path) {
                urls.append(dir.appendingPathComponent(f))
            }
        }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Checks that an output file is real and readable.
    func validate(_ url: URL) async -> String? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return "missing" }
        let kind = FileKind.of(url)
        if isDir.boolValue && ![.pages, .key, .numbers, .rtfd].contains(kind) {
            let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            if items.isEmpty { return "empty folder" }
            for i in items { if let p = await validate(i) { return p } }
            return nil
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size == 0 && !isDir.boolValue { return "empty file" }
        switch kind.category {
        case .image:
            if kind == .svg { return nil }
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceCreateImageAtIndex(src, 0, nil) != nil else { return "unreadable image" }
        case .pdf:
            guard let d = PDFDocument(url: url) else { return "unreadable pdf" }
            if !d.isLocked && d.pageCount == 0 { return "pdf has no pages" }
        case .video, .audio:
            if kind == .gif { break }
            let dur = (try? await FFmpeg.probe(url).duration) ?? 0
            if dur <= 0 { return "media has no duration" }
        default:
            if [.docx, .xlsx, .pptx, .epub, .odt, .ods, .odp, .zip].contains(kind) {
                let head = (try? FileHandle(forReadingFrom: url).readData(ofLength: 2)) ?? Data()
                if head != Data([0x50, 0x4B]) { return "not a zip container" }
            }
        }
        return nil
    }

    func testEveryOperation() async throws {
        let fixtures = Self.fixtures
        XCTAssertGreaterThan(fixtures.count, 20, "fixtures were not generated")
        var failures: [String] = []
        var ran = 0, skipped = 0
        let iWork: Set<Helper> = [.pages, .keynote, .numbers]
        for input in fixtures {
            for kind in [OpKind.convert, .tool] {
                for op in OperationRegistry.operations(for: [input], kind: kind) {
                    // iWork apps need Automation permission; LibreOffice etc. may not be installed yet.
                    if !op.isAvailable || !Set(op.helpers).isDisjoint(with: iWork) || [.pages, .key, .numbers].contains(FileKind.of(input)) {
                        skipped += 1; continue
                    }
                    ran += 1
                    let label = "\(op.id) ← \(input.lastPathComponent)"
                    let outDir = Self.dir.appendingPathComponent("out", isDirectory: true)
                    do {
                        let outs = try await Engine.shared.run(op, inputs: [input], options: overrides[op.id] ?? [:], outputDir: outDir)
                        for o in outs { if let problem = await validate(o) { failures.append("\(label): \(problem) (\(o.lastPathComponent))") } }
                    } catch {
                        let msg = error.localizedDescription
                        if !acceptable.contains(where: msg.contains) { failures.append("\(label): \(msg)") }
                    }
                }
            }
        }
        print("Ran \(ran) operations, skipped \(skipped).")
        XCTAssert(failures.isEmpty, "\(failures.count) failures:\n" + failures.joined(separator: "\n"))
    }

    func testMerges() async throws {
        let f = Self.fixtures
        func find(_ name: String) -> URL? { f.first { $0.lastPathComponent == name } }
        let outDir = Self.dir.appendingPathComponent("merge", isDirectory: true)
        let cases: [(String, [String])] = [
            ("tool.merge.pdf", ["doc.pdf", "image.png", "image.jpg"]),
            ("tool.merge.video", ["clip.mp4", "silent.mov"]),
            ("tool.merge.audio", ["tone.wav", "tone.mp3"]),
            ("tool.merge.zip", ["plain.txt", "folder"]),
        ]
        for (id, names) in cases {
            let inputs = names.compactMap(find)
            guard inputs.count == names.count, let op = OperationRegistry.operation(id: id), op.isAvailable else { continue }
            XCTAssertTrue(op.accepts(inputs), id)
            do {
                let outs = try await Engine.shared.run(op, inputs: inputs, outputDir: outDir)
                XCTAssertEqual(outs.count, 1, id)
                if let o = outs.first { let problem = await validate(o); XCTAssertNil(problem, "\(id): \(problem ?? "")") }
                if id == "tool.merge.pdf", let o = outs.first { XCTAssertEqual(PDFDocument(url: o)?.pageCount, (PDFDocument(url: inputs[0])?.pageCount ?? 0) + 2) }
            } catch { XCTFail("\(id): \(error.localizedDescription)") }
        }
    }

    func testRotatedPDFRendersLandscape() throws {
        guard let d = PDFDocument(url: Self.dir.appendingPathComponent("rotated.pdf")), let page = d.page(at: 0),
              let img = PDFUtil.render(page, dpi: 72) else { return XCTFail("no rotated fixture") }
        XCTAssertGreaterThan(img.width, img.height)
    }

    func testPageRanges() throws {
        XCTAssertEqual(try PDFTools.pages("1-3, 5", count: 6), [0, 1, 2, 4])
        XCTAssertEqual(try PDFTools.pages("4-", count: 6), [3, 4, 5])
        XCTAssertEqual(try PDFTools.pages("3-1", count: 6), [2, 1, 0])
        XCTAssertThrowsError(try PDFTools.pages("9", count: 6))
    }

    func testOutputNamerNeverOverwrites() throws {
        let a = OutputNamer.uniqueURL(in: Self.dir, fileName: "plain.txt")
        XCTAssertEqual(a.lastPathComponent, "plain (1).txt")
        let b = OutputNamer.uniqueURL(in: Self.dir, fileName: "bundle.tar.gz")
        XCTAssertEqual(b.lastPathComponent, "bundle (1).tar.gz")
    }

    func testSubtitleRoundTrip() {
        let cues = SubtitleBackend.parse("WEBVTT\n\n00:01.000 --> 00:02.500 align:start\nHi\n")
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].start, 1, accuracy: 0.001)
        XCTAssertTrue(SubtitleBackend.write(cues, as: .srt).contains("00:00:01,000 --> 00:00:02,500"))
    }
}
