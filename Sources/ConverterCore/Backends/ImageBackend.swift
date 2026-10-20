import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Reading, transforming and writing still images with ImageIO / CoreGraphics.
public enum ImageIOUtil {
    public struct Loaded {
        public let image: CGImage
        /// EXIF/GPS/TIFF metadata with orientation normalised (pixels are already upright).
        public let metadata: [CFString: Any]
    }

    public static func load(_ url: URL) async throws -> Loaded {
        if FileKind.of(url) == .svg { return Loaded(image: try await loadSVG(url), metadata: [:]) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(src) > 0 else {
            throw ConvertError.failed("Could not read image \(url.lastPathComponent).")
        }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ConvertError.failed("Could not decode image \(url.lastPathComponent).")
        }
        var meta: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let v = props[key] { meta[key] = v }
        }
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            meta[kCGImagePropertyTIFFDictionary] = tiff
        }
        for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] { if let v = props[key] { meta[key] = v } }
        meta[kCGImagePropertyOrientation] = 1
        return Loaded(image: img, metadata: meta)
    }

    private static func loadSVG(_ url: URL) async throws -> CGImage {
        if let ns = NSImage(contentsOf: url), ns.size.width > 0 {
            let scale = max(1, 2048 / max(ns.size.width, ns.size.height))
            let size = NSSize(width: ns.size.width * scale, height: ns.size.height * scale)
            var rect = NSRect(origin: .zero, size: size)
            if let cg = ns.cgImage(forProposedRect: &rect, context: nil, hints: nil) { return cg }
        }
        // Quick Look renders SVG reliably.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("svg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await ProcessRunner.run("/usr/bin/qlmanage", ["-t", "-s", "2048", "-o", dir.path, url.path])
        let png = dir.appendingPathComponent(url.lastPathComponent + ".png")
        guard let src = CGImageSourceCreateWithURL(png as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ConvertError.failed("Could not render SVG \(url.lastPathComponent).")
        }
        return img
    }

    static func utType(for kind: FileKind) -> String? {
        switch kind {
        case .jpg: return UTType.jpeg.identifier
        case .png: return UTType.png.identifier
        case .heic: return "public.heic"
        case .tiff: return UTType.tiff.identifier
        case .bmp: return UTType.bmp.identifier
        case .gif: return UTType.gif.identifier
        default: return nil
        }
    }

    /// Writes `image` as `kind`. `quality` is 0...1 for lossy formats.
    public static func write(_ image: CGImage, to url: URL, kind: FileKind, quality: Double = 0.9,
                             metadata: [CFString: Any] = [:]) async throws {
        switch kind {
        case .webp:
            let png = url.deletingPathExtension().appendingPathExtension("src.png")
            try writeImageIO(image, to: png, type: UTType.png.identifier, quality: 1, metadata: [:])
            defer { try? FileManager.default.removeItem(at: png) }
            try await ProcessRunner.run(try Helper.cwebp.require(),
                                        ["-quiet", "-metadata", "none", "-q", String(Int(quality * 100)), png.path, "-o", url.path])
        case .avif:
            let png = url.deletingPathExtension().appendingPathExtension("src.png")
            try writeImageIO(image, to: png, type: UTType.png.identifier, quality: 1, metadata: [:])
            defer { try? FileManager.default.removeItem(at: png) }
            try await ProcessRunner.run(try Helper.avifenc.require(),
                                        ["-q", String(Int(quality * 100)), "-s", "6", png.path, url.path])
        case .pdf:
            try writePDF([image], to: url)
        default:
            guard let type = utType(for: kind) else { throw ConvertError.unsupported("writing \(kind.label) images") }
            var meta = metadata
            if kind == .bmp || kind == .gif { meta = [:] }
            try writeImageIO(image, to: url, type: type, quality: quality, metadata: meta)
        }
    }

    static func writeImageIO(_ image: CGImage, to url: URL, type: String, quality: Double, metadata: [CFString: Any]) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
            throw ConvertError.failed("Could not create \(url.lastPathComponent).")
        }
        var props = metadata
        props[kCGImageDestinationLossyCompressionQuality] = quality
        var img = image
        // JPEG/BMP have no alpha: flatten onto white so transparent areas don't turn black.
        if (type == UTType.jpeg.identifier || type == UTType.bmp.identifier), image.hasAlpha {
            img = flatten(image) ?? image
        }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        if CGImageDestinationFinalize(dest) { return }
        // Some encoders (HEIC, BMP) reject gray or unusual pixel layouts: retry with plain 8-bit RGB.
        guard let plain = normalized(img, alpha: type != UTType.bmp.identifier && img.hasAlpha),
              let retry = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
            throw ConvertError.failed("Could not encode \(url.lastPathComponent).")
        }
        CGImageDestinationAddImage(retry, plain, props as CFDictionary)
        guard CGImageDestinationFinalize(retry) else {
            throw ConvertError.failed("Could not encode \(url.lastPathComponent) (this Mac may lack an encoder for this format).")
        }
    }

    static func normalized(_ image: CGImage, alpha: Bool) -> CGImage? {
        guard let ctx = context(width: image.width, height: image.height, alpha: alpha) else { return nil }
        if !alpha {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// One image per page, page size = pixel size at 72 dpi (or the image's own dpi).
    public static func writePDF(_ images: [CGImage], to url: URL, dpi: Double = 72) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else { throw ConvertError.failed("Could not create PDF.") }
        var box = CGRect.zero
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw ConvertError.failed("Could not create PDF.") }
        for img in images {
            var rect = CGRect(x: 0, y: 0, width: Double(img.width) * 72 / dpi, height: Double(img.height) * 72 / dpi)
            let info = [kCGPDFContextMediaBox as String: NSData(bytes: &rect, length: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(info)
            ctx.draw(img, in: rect)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    // MARK: - Transforms

    static func context(width: Int, height: Int, gray: Bool = false, alpha: Bool = true) -> CGContext? {
        let space = gray ? CGColorSpaceCreateDeviceGray() : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
        let info: UInt32 = gray ? CGImageAlphaInfo.none.rawValue
            : (alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
        let ctx = CGContext(data: nil, width: max(width, 1), height: max(height, 1), bitsPerComponent: 8,
                            bytesPerRow: 0, space: space, bitmapInfo: info)
        ctx?.interpolationQuality = .high
        return ctx
    }

    static func flatten(_ image: CGImage) -> CGImage? {
        guard let ctx = context(width: image.width, height: image.height, alpha: false) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    public static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let ctx = context(width: width, height: height) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    public static func rotated(_ image: CGImage, degrees: Int) -> CGImage? {
        let d = ((degrees % 360) + 360) % 360
        let swap = d == 90 || d == 270
        let w = swap ? image.height : image.width, h = swap ? image.width : image.height
        guard let ctx = context(width: w, height: h) else { return nil }
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        // Positive degrees = clockwise.
        ctx.rotate(by: -CGFloat(d) * .pi / 180)
        ctx.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        return ctx.makeImage()
    }

    public static func flipped(_ image: CGImage, horizontal: Bool) -> CGImage? {
        guard let ctx = context(width: image.width, height: image.height) else { return nil }
        if horizontal {
            ctx.translateBy(x: CGFloat(image.width), y: 0); ctx.scaleBy(x: -1, y: 1)
        } else {
            ctx.translateBy(x: 0, y: CGFloat(image.height)); ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    public static func grayscale(_ image: CGImage) -> CGImage? {
        guard let flat = image.hasAlpha ? flatten(image) : image,
              let ctx = context(width: image.width, height: image.height, gray: true) else { return nil }
        ctx.draw(flat, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}

extension CGImage {
    var hasAlpha: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }
}

enum ImageBackend {
    static let readable: Set<FileKind> = [.jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .gif, .svg]
    static let targets: [FileKind] = [.jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .gif, .pdf]

    static func helpers(for kind: FileKind) -> [Helper] {
        switch kind {
        case .webp: return [.cwebp]
        case .avif: return [.avifenc]
        default: return []
        }
    }

    static var operations: [FileOp] {
        targets.map { target in
            FileOp(id: "convert.image.\(target.rawValue)", kind: .convert, title: target.label,
                      symbol: target == .pdf ? "doc.richtext" : "photo", group: target == .pdf ? "PDF" : "Image",
                      inputs: readable.subtracting([target]), helpers: helpers(for: target)) { ctx in
                let loaded = try await ImageIOUtil.load(ctx.input)
                let out = ctx.out(ctx.baseName, target.ext)
                try await ImageIOUtil.write(loaded.image, to: out, kind: target, quality: 0.9, metadata: loaded.metadata)
                return [out]
            }
        }
    }
}
