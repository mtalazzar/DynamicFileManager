import Foundation

/// Broad family a file belongs to. Used to decide which operations apply.
public enum Category: String, CaseIterable, Sendable {
    case image, video, audio, pdf, document, slides, spreadsheet, subtitle, archive, folder, other
}

/// A concrete file format, identified by extension.
public enum FileKind: String, CaseIterable, Sendable {
    // Images
    case jpg, png, webp, heic, tiff, avif, bmp, gif, svg
    // Video
    case mp4, mov, mkv, webm, avi, wmv, m4v
    // Audio
    case mp3, m4a, wav, flac, ogg, opus, aiff, wma, aac
    // PDF
    case pdf
    // Documents
    case docx, doc, odt, pages, md, txt, epub, html, rtf, rtfd, textClipping
    // Slides
    case pptx, ppt, odp, key
    // Spreadsheets
    case xlsx, xls, ods, csv, tsv, numbers
    // Subtitles
    case srt, vtt
    // Archives
    case zip, tar, gz, tgz, rar, sevenZip
    // Other
    case folder, other

    public var category: Category {
        switch self {
        case .jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .gif, .svg: return .image
        case .mp4, .mov, .mkv, .webm, .avi, .wmv, .m4v: return .video
        case .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma, .aac: return .audio
        case .pdf: return .pdf
        case .docx, .doc, .odt, .pages, .md, .txt, .epub, .html, .rtf, .rtfd, .textClipping: return .document
        case .pptx, .ppt, .odp, .key: return .slides
        case .xlsx, .xls, .ods, .csv, .tsv, .numbers: return .spreadsheet
        case .srt, .vtt: return .subtitle
        case .zip, .tar, .gz, .tgz, .rar, .sevenZip: return .archive
        case .folder: return .folder
        case .other: return .other
        }
    }

    /// File extension used when writing this kind.
    public var ext: String {
        switch self {
        case .sevenZip: return "7z"
        case .textClipping: return "textClipping"
        case .tgz: return "tar.gz"
        default: return rawValue
        }
    }

    /// Label shown in the wheel.
    public var label: String {
        switch self {
        case .sevenZip: return "7Z"
        case .textClipping: return "Clipping"
        case .pages: return "Pages"
        case .numbers: return "Numbers"
        case .key: return "Keynote"
        case .tgz: return "TAR.GZ"
        case .gz: return "GZIP"
        case .md: return "MD"
        default: return rawValue.uppercased()
        }
    }

    public static func of(_ url: URL) -> FileKind {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") { return .tgz }
        let e = url.pathExtension.lowercased()
        // Packages (.pages, .key, .numbers, .rtfd) can be directories.
        switch e {
        case "jpg", "jpeg", "jpe", "jfif": return .jpg
        case "png": return .png
        case "webp": return .webp
        case "heic", "heif": return .heic
        case "tif", "tiff": return .tiff
        case "avif": return .avif
        case "bmp": return .bmp
        case "gif": return .gif
        case "svg": return .svg
        case "mp4": return .mp4
        case "m4v": return .m4v
        case "mov", "qt": return .mov
        case "mkv": return .mkv
        case "webm": return .webm
        case "avi": return .avi
        case "wmv": return .wmv
        case "mp3": return .mp3
        case "m4a": return .m4a
        case "aac": return .aac
        case "wav", "wave": return .wav
        case "flac": return .flac
        case "ogg", "oga": return .ogg
        case "opus": return .opus
        case "aif", "aiff", "aifc": return .aiff
        case "wma": return .wma
        case "pdf": return .pdf
        case "docx": return .docx
        case "doc": return .doc
        case "odt": return .odt
        case "pages": return .pages
        case "md", "markdown": return .md
        case "txt", "text": return .txt
        case "epub": return .epub
        case "html", "htm": return .html
        case "rtf": return .rtf
        case "rtfd": return .rtfd
        case "textclipping": return .textClipping
        case "pptx": return .pptx
        case "ppt": return .ppt
        case "odp": return .odp
        case "key": return .key
        case "xlsx": return .xlsx
        case "xls": return .xls
        case "ods": return .ods
        case "csv": return .csv
        case "tsv", "tab": return .tsv
        case "numbers": return .numbers
        case "srt": return .srt
        case "vtt": return .vtt
        case "zip": return .zip
        case "tar": return .tar
        case "gz", "gzip": return .gz
        case "tgz": return .tgz
        case "rar": return .rar
        case "7z": return .sevenZip
        default:
            if exists && isDir.boolValue { return .folder }
            return .other
        }
    }
}
