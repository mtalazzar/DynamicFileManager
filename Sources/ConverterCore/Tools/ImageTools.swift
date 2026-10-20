import Foundation
import CoreGraphics

enum ImageTools {
    static let inputs = ImageBackend.readable
    static let writable: Set<FileKind> = [.jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .gif]

    static func outKind(_ url: URL) -> FileKind {
        let k = FileKind.of(url)
        return writable.contains(k) ? k : .png
    }

    static func tool(_ id: String, _ title: String, _ symbol: String, suffix: String, options: [OptionSpec] = [],
                     keepMetadata: Bool = true, quality: @escaping @Sendable (Options) -> Double = { _ in 0.92 },
                     transform: @escaping @Sendable (CGImage, Options) throws -> CGImage) -> FileOp {
        FileOp(id: "tool.image.\(id)", kind: .tool, title: title, symbol: symbol, group: "Image",
                  inputs: inputs, options: options) { ctx in
            let kind = outKind(ctx.input)
            if kind == .webp { _ = try Helper.cwebp.require() }
            if kind == .avif { _ = try Helper.avifenc.require() }
            let loaded = try await ImageIOUtil.load(ctx.input)
            let img = try transform(loaded.image, ctx.options)
            let out = ctx.out("\(ctx.baseName) \(suffix)", kind.ext)
            try await ImageIOUtil.write(img, to: out, kind: kind, quality: quality(ctx.options),
                                        metadata: keepMetadata ? loaded.metadata : [:])
            return [out]
        }
    }

    static func fail(_ what: String) -> ConvertError { .failed("Could not \(what) the image.") }

    /// "16:9" → 16/9.
    static func ratio(_ s: String) -> Double? {
        let p = s.split(separator: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard p.count == 2, p[0] > 0, p[1] > 0 else { return nil }
        return p[0] / p[1]
    }

    static var operations: [FileOp] {
        [
            tool("compress", "Compress", "arrow.down.right.and.arrow.up.left", suffix: "compressed",
                 options: [OptionSpec("quality", "Quality", .choice(["High", "Medium", "Low"]), default: "Medium"),
                           OptionSpec("maxSize", "Max size", .choice(["Original", "3840", "2560", "1920", "1280"]), default: "Original")],
                 keepMetadata: false,
                 quality: { o in ["High": 0.82, "Medium": 0.68, "Low": 0.5][o["quality"] ?? ""] ?? 0.68 }) { img, o in
                guard let limit = Int(o["maxSize"] ?? ""), max(img.width, img.height) > limit else { return img }
                let s = Double(limit) / Double(max(img.width, img.height))
                guard let r = ImageIOUtil.resized(img, width: Int(Double(img.width) * s), height: Int(Double(img.height) * s)) else { throw fail("compress") }
                return r
            },
            tool("resize", "Resize", "arrow.up.left.and.arrow.down.right", suffix: "resized",
                 options: [OptionSpec("size", "Size", .choice(["50%", "25%", "75%", "200%", "3840 px", "1920 px", "1280 px", "1024 px", "640 px", "Custom"]), default: "50%"),
                           OptionSpec("custom", "Custom longest side (px)", .text(placeholder: "e.g. 1600"), default: "")]) { img, o in
                let choice = o["size"] ?? "50%"
                let longest = Double(max(img.width, img.height))
                var scale: Double
                if choice.hasSuffix("%") { scale = (Double(choice.dropLast()) ?? 50) / 100 }
                else if choice == "Custom" {
                    guard let px = Double(o["custom"] ?? ""), px > 0 else { throw ConvertError.failed("Enter a custom size in pixels.") }
                    scale = px / longest
                } else { scale = (Double(choice.split(separator: " ")[0]) ?? longest) / longest }
                guard let r = ImageIOUtil.resized(img, width: max(1, Int((Double(img.width) * scale).rounded())),
                                                  height: max(1, Int((Double(img.height) * scale).rounded()))) else { throw fail("resize") }
                return r
            },
            tool("crop", "Crop", "crop", suffix: "cropped",
                 options: [OptionSpec("ratio", "Aspect ratio", .choice(["1:1", "4:3", "3:2", "16:9", "9:16", "4:5", "3:4", "2:3", "Custom"]), default: "1:1"),
                           OptionSpec("custom", "Custom ratio (W:H)", .text(placeholder: "e.g. 21:9"), default: ""),
                           OptionSpec("anchor", "Keep", .choice(["Center", "Top", "Bottom", "Left", "Right"]), default: "Center")]) { img, o in
                let choice = o["ratio"] ?? "1:1"
                guard let r = ratio(choice == "Custom" ? (o["custom"] ?? "") : choice) else { throw ConvertError.failed("Enter a ratio like 16:9.") }
                let W = Double(img.width), H = Double(img.height)
                let w = min(W, H * r), h = min(H, W / r)
                var x = (W - w) / 2, yTop = (H - h) / 2
                switch o["anchor"] ?? "Center" {
                case "Top": yTop = 0
                case "Bottom": yTop = H - h
                case "Left": x = 0
                case "Right": x = W - w
                default: break
                }
                // CGImage.cropping uses a top-left origin.
                guard let c = img.cropping(to: CGRect(x: x.rounded(), y: yTop.rounded(), width: w.rounded(), height: h.rounded())) else { throw fail("crop") }
                return c
            },
            tool("rotate", "Rotate", "rotate.right", suffix: "rotated",
                 options: [OptionSpec("angle", "Rotate", .choice(["90° right", "90° left", "180°"]), default: "90° right")]) { img, o in
                let deg = ["90° right": 90, "90° left": 270, "180°": 180][o["angle"] ?? ""] ?? 90
                guard let r = ImageIOUtil.rotated(img, degrees: deg) else { throw fail("rotate") }
                return r
            },
            tool("flip", "Flip", "arrow.left.and.right.righttriangle.left.righttriangle.right", suffix: "flipped",
                 options: [OptionSpec("direction", "Direction", .choice(["Horizontal", "Vertical"]), default: "Horizontal")]) { img, o in
                guard let r = ImageIOUtil.flipped(img, horizontal: (o["direction"] ?? "Horizontal") == "Horizontal") else { throw fail("flip") }
                return r
            },
            tool("grayscale", "Black & White", "circle.lefthalf.filled", suffix: "bw") { img, _ in
                guard let r = ImageIOUtil.grayscale(img) else { throw fail("convert") }
                return r
            },
            tool("strip", "Strip Metadata", "eye.slash", suffix: "clean", keepMetadata: false, quality: { _ in 0.95 }) { img, _ in img },
        ]
    }
}
