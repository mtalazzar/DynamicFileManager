import Foundation

enum AVTools {
    static let video = AVBackend.videoIn
    static let audio = AVBackend.audioIn
    static let media = video.union(audio)

    /// "1:30", "90", "00:01:30.5" → seconds.
    static func seconds(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return SubtitleBackend.parseTime(t.contains(":") ? t : "0:\(t)")
    }

    /// atempo only accepts 0.5...2, so chain it for other speeds.
    static func atempo(_ speed: Double) -> String {
        var s = speed, parts: [String] = []
        while s > 2 { parts.append("atempo=2.0"); s /= 2 }
        while s < 0.5 { parts.append("atempo=0.5"); s /= 0.5 }
        parts.append("atempo=\(s)")
        return parts.joined(separator: ",")
    }

    static func op(_ id: String, _ title: String, _ symbol: String, group: String = "Video", inputs: Set<FileKind>,
                   options: [OptionSpec] = [], perform: @escaping @Sendable (JobContext, FFmpeg.Info) async throws -> [URL]) -> FileOp {
        FileOp(id: "tool.av.\(id)", kind: .tool, title: title, symbol: symbol, group: group, inputs: inputs,
                  helpers: [.ffmpeg, .ffprobe], options: options) { ctx in
            try await perform(ctx, try await FFmpeg.probe(ctx.input))
        }
    }

    /// Re-encodes the input into its own format with extra filters.
    static func reencode(_ ctx: JobContext, _ info: FFmpeg.Info, suffix: String, pre: [String] = [], vf: String? = nil,
                         af: String? = nil, crf: Int? = nil, duration: Double? = nil, extra: [String] = []) async throws -> [URL] {
        let kind = FileKind.of(ctx.input)
        let out = ctx.out("\(ctx.baseName) \(suffix)", kind.ext)
        let args = pre + ["-i", ctx.input.path] + FFmpeg.codecArgs(for: kind, videoFilter: vf, audioFilter: info.hasAudio ? af : nil, crf: crf) + extra
        try await FFmpeg.run(args, output: out, duration: duration ?? info.duration, ctx: ctx)
        return [out]
    }

    static var operations: [FileOp] {
        [
            op("compress-video", "Compress", "arrow.down.right.and.arrow.up.left", inputs: video,
               options: [OptionSpec("quality", "Quality", .choice(["Balanced", "High", "Small"]), default: "Balanced"),
                         OptionSpec("height", "Max height", .choice(["Original", "1080p", "720p", "480p"]), default: "Original")]) { ctx, info in
                let crf = ["High": 23, "Balanced": 27, "Small": 31][ctx.option("quality")] ?? 27
                var vf: String?
                if let h = Int(ctx.option("height").dropLast()), info.height > h { vf = "scale=-2:\(h)" }
                let out = ctx.out("\(ctx.baseName) compressed", "mp4")
                let args = ["-i", ctx.input.path] + (vf.map { ["-vf", $0 + "," + FFmpeg.evenScale] } ?? ["-vf", FFmpeg.evenScale])
                    + ["-c:v", "libx264", "-preset", "slow", "-crf", String(crf), "-pix_fmt", "yuv420p",
                       "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"]
                try await FFmpeg.run(args, output: out, duration: info.duration, ctx: ctx)
                return [out]
            },
            op("compress-audio", "Compress", "arrow.down.right.and.arrow.up.left", group: "Audio", inputs: audio,
               options: [OptionSpec("bitrate", "Bitrate", .choice(["128k", "96k", "192k", "64k"]), default: "128k")]) { ctx, info in
                let kind = FileKind.of(ctx.input)
                let target: FileKind = AVBackend.lossyAudio.contains(kind) ? kind : .m4a
                let codec: [String]
                switch target {
                case .mp3: codec = ["-c:a", "libmp3lame"]
                case .ogg, .opus: codec = ["-c:a", "libopus"]
                case .wma: codec = ["-c:a", "wmav2"]
                default: codec = ["-c:a", "aac"]
                }
                let out = ctx.out("\(ctx.baseName) compressed", target.ext)
                try await FFmpeg.run(["-i", ctx.input.path, "-vn"] + codec + ["-b:a", ctx.option("bitrate", "128k")],
                                     output: out, duration: info.duration, ctx: ctx)
                return [out]
            },
            op("trim", "Trim", "scissors", group: "Media", inputs: media,
               options: [OptionSpec("start", "Start (h:mm:ss)", .text(placeholder: "0:00"), default: "0:00"),
                         OptionSpec("end", "End (h:mm:ss, empty = end)", .text(placeholder: "end"), default: "")]) { ctx, info in
                let start = seconds(ctx.option("start")) ?? 0
                let end = seconds(ctx.option("end")) ?? info.duration
                guard end > start else { throw ConvertError.failed("The end time must be after the start time.") }
                return try await reencode(ctx, info, suffix: "trimmed", pre: ["-ss", String(start)],
                                          duration: end - start, extra: ["-t", String(end - start)])
            },
            op("mute", "Remove Audio", "speaker.slash", inputs: video) { ctx, info in
                let out = ctx.out("\(ctx.baseName) muted", FileKind.of(ctx.input).ext)
                try await FFmpeg.run(["-i", ctx.input.path, "-an", "-c:v", "copy"], output: out, duration: info.duration, ctx: ctx)
                return [out]
            },
            op("extract-audio", "Extract Audio", "waveform", inputs: video,
               options: [OptionSpec("format", "Format", .choice(["M4A", "MP3", "WAV"]), default: "M4A")]) { ctx, info in
                guard info.hasAudio else { throw ConvertError.failed("This video has no audio track.") }
                let kind = FileKind(rawValue: ctx.option("format", "M4A").lowercased()) ?? .m4a
                let out = ctx.out(ctx.baseName, kind.ext)
                try await FFmpeg.run(["-i", ctx.input.path] + FFmpeg.codecArgs(for: kind), output: out, duration: info.duration, ctx: ctx)
                return [out]
            },
            op("speed", "Change Speed", "gauge.with.dots.needle.67percent", group: "Media", inputs: media,
               options: [OptionSpec("speed", "Speed", .choice(["2×", "1.5×", "1.25×", "0.75×", "0.5×", "0.25×", "4×"]), default: "2×")]) { ctx, info in
                let s = Double(ctx.option("speed", "2×").dropLast()) ?? 2
                let vf = info.hasVideo ? "setpts=PTS/\(s)" : nil
                return try await reencode(ctx, info, suffix: "\(ctx.option("speed", "2×"))", vf: vf, af: atempo(s),
                                          duration: info.duration / s)
            },
            op("gif", "Make GIF", "photo.stack", inputs: video,
               options: [OptionSpec("fps", "Frame rate", .choice(["12", "15", "24", "8"]), default: "12"),
                         OptionSpec("width", "Width", .choice(["480", "320", "640", "800", "Original"]), default: "480")]) { ctx, info in
                let w = ctx.option("width", "480")
                let scale = w == "Original" ? "scale=iw:-2" : "scale='min(\(w),iw)':-2:flags=lanczos"
                let out = ctx.out(ctx.baseName, "gif")
                try await FFmpeg.run(["-i", ctx.input.path] + FFmpeg.codecArgs(for: .gif, videoFilter: "fps=\(ctx.option("fps", "12")),\(scale)"),
                                     output: out, duration: info.duration, ctx: ctx)
                return [out]
            },
            op("frames", "Extract Frames", "square.grid.3x3", inputs: video,
               options: [OptionSpec("every", "One frame every", .choice(["1 second", "5 seconds", "10 seconds", "0.5 seconds"]), default: "1 second")]) { ctx, info in
                let every = Double(ctx.option("every", "1 second").split(separator: " ")[0]) ?? 1
                let folder = ctx.out("\(ctx.baseName) frames", "")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await FFmpeg.run(["-i", ctx.input.path, "-vf", "fps=1/\(every)", "-q:v", "2"],
                                     output: folder.appendingPathComponent("\(ctx.baseName) %04d.jpg"), duration: info.duration, ctx: ctx)
                return [folder]
            },
            op("normalize", "Normalize Volume", "speaker.wave.2", group: "Media", inputs: media) { ctx, info in
                guard info.hasAudio else { throw ConvertError.failed("This file has no audio track.") }
                let kind = FileKind.of(ctx.input)
                let out = ctx.out("\(ctx.baseName) normalized", kind.ext)
                var args = ["-i", ctx.input.path]
                if info.hasVideo { args += ["-c:v", "copy"] + Array(FFmpeg.codecArgs(for: kind).drop { $0 != "-c:a" }) }
                else { args += FFmpeg.codecArgs(for: kind) }
                args += ["-af", "loudnorm=I=-16:TP=-1.5:LRA=11"]
                try await FFmpeg.run(args, output: out, duration: info.duration, ctx: ctx)
                return [out]
            },
            op("resize-video", "Resize", "arrow.up.left.and.arrow.down.right", inputs: video,
               options: [OptionSpec("height", "Height", .choice(["720p", "1080p", "480p", "360p", "2160p"]), default: "720p")]) { ctx, info in
                let h = Int(ctx.option("height", "720p").dropLast()) ?? 720
                return try await reencode(ctx, info, suffix: "\(h)p", vf: "scale=-2:\(h)")
            },
            op("rotate-video", "Rotate", "rotate.right", inputs: video,
               options: [OptionSpec("angle", "Rotate", .choice(["90° right", "90° left", "180°"]), default: "90° right")]) { ctx, info in
                let vf = ["90° right": "transpose=1", "90° left": "transpose=2", "180°": "transpose=1,transpose=1"][ctx.option("angle")] ?? "transpose=1"
                return try await reencode(ctx, info, suffix: "rotated", vf: vf)
            },
            op("crop-video", "Crop", "crop", inputs: video,
               options: [OptionSpec("ratio", "Aspect ratio", .choice(["9:16", "1:1", "16:9", "4:5", "4:3"]), default: "9:16")]) { ctx, info in
                guard let r = ImageTools.ratio(ctx.option("ratio", "9:16")) else { throw ConvertError.failed("Bad ratio.") }
                let vf = "crop=trunc(min(iw\\,ih*\(r))/2)*2:trunc(min(ih\\,iw/\(r))/2)*2"
                return try await reencode(ctx, info, suffix: "cropped", vf: vf)
            },
        ]
    }
}
