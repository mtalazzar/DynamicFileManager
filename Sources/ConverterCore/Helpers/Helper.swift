import Foundation
import AppKit

/// External programs the engine can call.
public enum Helper: String, CaseIterable, Sendable {
    case ffmpeg, ffprobe, ghostscript, tesseract, cwebp, avifenc, pandoc, libreoffice, unar, python
    case pages, keynote, numbers

    public var displayName: String {
        switch self {
        case .ffmpeg: return "ffmpeg"
        case .ffprobe: return "ffprobe"
        case .ghostscript: return "Ghostscript"
        case .tesseract: return "Tesseract"
        case .cwebp: return "cwebp (WebP)"
        case .avifenc: return "avifenc (AVIF)"
        case .pandoc: return "pandoc"
        case .libreoffice: return "LibreOffice"
        case .unar: return "unar"
        case .python: return "Python PDF tools"
        case .pages: return "Pages"
        case .keynote: return "Keynote"
        case .numbers: return "Numbers"
        }
    }

    /// Shell command that installs the helper (nil for Apple apps).
    public var installCommand: String? {
        switch self {
        case .ffmpeg, .ffprobe: return "brew install ffmpeg"
        case .ghostscript: return "brew install ghostscript"
        case .tesseract: return "brew install tesseract"
        case .cwebp: return "brew install webp"
        case .avifenc: return "brew install libavif"
        case .pandoc:
            return "mkdir -p \"\(Helper.binDir.path)\" && cd /tmp && curl -sL -o pandoc.zip https://github.com/jgm/pandoc/releases/download/3.12.1/pandoc-3.12.1-x86_64-macOS.zip && unzip -q -o pandoc.zip && cp pandoc-3.12.1-x86_64/bin/pandoc \"\(Helper.binDir.path)/pandoc\""
        case .libreoffice: return "brew install --cask libreoffice"
        case .unar: return "brew install unar"
        case .python:
            return "python3 -m venv \"\(Helper.venvDir.path)\" && \"\(Helper.venvDir.path)/bin/pip\" install --only-binary=:all: pdf2docx python-pptx pdfplumber openpyxl"
        case .pages, .keynote, .numbers: return nil
        }
    }

    public static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DynamicFileConverter", isDirectory: true)
    }
    public static var venvDir: URL { supportDir.appendingPathComponent("venv", isDirectory: true) }

    /// Private tools (e.g. a downloaded pandoc) live in Application Support/DynamicFileConverter/bin.
    public static var binDir: URL { supportDir.appendingPathComponent("bin", isDirectory: true) }
    private static var searchDirs: [String] {
        [binDir.path, "/usr/local/bin", "/opt/homebrew/bin", "/opt/local/bin", "/usr/bin", "/bin"]
    }
    private static let cache = PathCache()

    /// Absolute path of the executable, or nil when not installed.
    public var path: String? {
        if let cached = Helper.cache.get(self) { return cached }
        let found = locate()
        Helper.cache.set(self, found)
        return found
    }

    public var isAvailable: Bool { path != nil }

    public func require() throws -> String {
        guard let p = path else { throw ConvertError.missingHelper(self) }
        return p
    }

    /// Forget cached lookups (after installing something).
    public static func refresh() { cache.clear() }

    private func locate() -> String? {
        let fm = FileManager.default
        func find(_ names: [String]) -> String? {
            for dir in Helper.searchDirs {
                for n in names where fm.isExecutableFile(atPath: "\(dir)/\(n)") { return "\(dir)/\(n)" }
            }
            return nil
        }
        switch self {
        case .ffmpeg: return find(["ffmpeg"])
        case .ffprobe: return find(["ffprobe"])
        case .ghostscript: return find(["gs"])
        case .tesseract: return find(["tesseract"])
        case .cwebp: return find(["cwebp"])
        case .avifenc: return find(["avifenc"])
        case .pandoc: return find(["pandoc"])
        case .unar: return find(["unar"])
        case .libreoffice:
            for p in ["/Applications/LibreOffice.app/Contents/MacOS/soffice",
                      NSHomeDirectory() + "/Applications/LibreOffice.app/Contents/MacOS/soffice"]
            where fm.isExecutableFile(atPath: p) { return p }
            return find(["soffice"])
        case .python:
            let py = Helper.venvDir.appendingPathComponent("bin/python").path
            return fm.isExecutableFile(atPath: py) ? py : nil
        case .pages: return Helper.app("com.apple.iWork.Pages")
        case .keynote: return Helper.app("com.apple.iWork.Keynote")
        case .numbers: return Helper.app("com.apple.iWork.Numbers")
        }
    }

    private static func app(_ bundleID: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
    }
}

private final class PathCache: @unchecked Sendable {
    private var values: [Helper: String?] = [:]
    private let lock = NSLock()
    func get(_ h: Helper) -> String?? { lock.lock(); defer { lock.unlock() }; return values[h] }
    func set(_ h: Helper, _ v: String?) { lock.lock(); values[h] = .some(v); lock.unlock() }
    func clear() { lock.lock(); values.removeAll(); lock.unlock() }
}
