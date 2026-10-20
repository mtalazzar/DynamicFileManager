import Foundation

/// Thin wrapper around ffmpeg/ffprobe with progress reporting.
public enum FFmpeg {
    public struct Info: Sendable {
        public var duration: Double = 0
        public var width: Int = 0
        public var height: Int = 0
        public var hasVideo = false
        public var hasAudio = false
    }

    public static func probe(_ url: URL) async throws -> Info {
        let r = try await ProcessRunner.runAllowingFailure(try Helper.ffprobe.require(), [
            "-v", "error", "-show_entries", "format=duration:stream=codec_type,width,height",
            "-of", "json", url.path,
        ])
        var info = Info()
        guard let data = r.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return info }
        if let f = json["format"] as? [String: Any], let d = f["duration"] as? String { info.duration = Double(d) ?? 0 }
        for s in (json["streams"] as? [[String: Any]]) ?? [] {
            switch s["codec_type"] as? String {
            case "video":
                if !info.hasVideo { info.width = s["width"] as? Int ?? 0; info.height = s["height"] as? Int ?? 0 }
                info.hasVideo = true
            case "audio": info.hasAudio = true
            default: break
            }
        }
        return info
    }

    /// Runs ffmpeg with `args` (which must include `-i`) writing `output`.
    /// `duration` is the expected output length in seconds, used for progress.
    public static func run(_ args: [String], output: URL, duration: Double, ctx: JobContext,
                           progressRange: ClosedRange<Double> = 0...1) async throws {
        let full = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats"]
            + args + [output.path]
        let lo = progressRange.lowerBound, span = progressRange.upperBound - progressRange.lowerBound
        try await ProcessRunner.run(try Helper.ffmpeg.require(), full) { line in
            guard duration > 0, line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") else { return }
            let v = Double(line.split(separator: "=").last ?? "") ?? 0
            ctx.progress(lo + span * min(1, v / 1_000_000 / duration))
        }
    }

    static let evenScale = "scale=trunc(iw/2)*2:trunc(ih/2)*2"

    /// Encoder arguments for writing `kind`.
    static func codecArgs(for kind: FileKind, videoFilter: String? = nil, audioFilter: String? = nil,
                          crf: Int? = nil) -> [String] {
        func vf(_ base: String?) -> [String] {
            let chain = [videoFilter, base].compactMap { $0 }.joined(separator: ",")
            return chain.isEmpty ? [] : ["-vf", chain]
        }
        let af = audioFilter.map { ["-af", $0] } ?? []
        switch kind {
        case .mp4, .m4v, .mov, .mkv:
            var a = vf(evenScale) + ["-c:v", "libx264", "-preset", "medium", "-crf", String(crf ?? 20), "-pix_fmt", "yuv420p"]
            a += af + ["-c:a", "aac", "-b:a", "192k"]
            if kind != .mkv { a += ["-movflags", "+faststart"] }
            return a
        case .webm:
            return vf(evenScale) + ["-c:v", "libvpx-vp9", "-crf", String((crf ?? 20) + 12), "-b:v", "0", "-row-mt", "1",
                                    "-deadline", "good", "-cpu-used", "4", "-pix_fmt", "yuv420p"] + af + ["-c:a", "libopus", "-b:a", "128k"]
        case .avi:
            return vf(evenScale) + ["-c:v", "mpeg4", "-q:v", "4"] + af + ["-c:a", "libmp3lame", "-q:a", "3"]
        case .wmv:
            return vf(evenScale) + ["-c:v", "wmv2", "-q:v", "4"] + af + ["-c:a", "wmav2", "-b:a", "192k"]
        case .gif:
            let pre = videoFilter.map { "\($0)," } ?? "fps=12,scale='min(480,iw)':-2:flags=lanczos,"
            return ["-an", "-filter_complex", "[0:v]\(pre)split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=sierra2_4a",
                    "-loop", "0"]
        case .mp3: return ["-vn"] + af + ["-c:a", "libmp3lame", "-q:a", "2"]
        case .m4a, .aac: return ["-vn"] + af + ["-c:a", "aac", "-b:a", "256k"]
        case .wav: return ["-vn"] + af + ["-c:a", "pcm_s16le"]
        case .aiff: return ["-vn"] + af + ["-c:a", "pcm_s16be"]
        case .flac: return ["-vn"] + af + ["-c:a", "flac"]
        case .ogg, .opus: return ["-vn"] + af + ["-c:a", "libopus", "-b:a", "160k"]
        case .wma: return ["-vn"] + af + ["-c:a", "wmav2", "-b:a", "192k"]
        default: return []
        }
    }
}

enum AVBackend {
    static let videoIn: Set<FileKind> = [.mp4, .mov, .mkv, .webm, .avi, .wmv, .m4v]
    static let audioIn: Set<FileKind> = [.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma, .aac]
    static let videoOut: [FileKind] = [.mp4, .mov, .mkv, .webm, .avi, .wmv, .gif]
    static let audioOut: [FileKind] = [.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma]
    static let lossyAudio: Set<FileKind> = [.mp3, .m4a, .aac, .ogg, .opus, .wma]

    static var operations: [FileOp] {
        var ops: [FileOp] = []
        for target in videoOut {
            var inputs = videoIn.union([.gif]).subtracting([target])
            if target == .gif { inputs.remove(.gif) }
            ops.append(convert(target, inputs: inputs, group: "Video", symbol: target == .gif ? "photo.stack" : "film"))
        }
        for target in audioOut {
            ops.append(convert(target, inputs: audioIn.union(videoIn).subtracting([target]), group: "Audio", symbol: "waveform"))
        }
        return ops
    }

    static func convert(_ target: FileKind, inputs: Set<FileKind>, group: String, symbol: String) -> FileOp {
        FileOp(id: "convert.av.\(target.rawValue)", kind: .convert, title: target.label, symbol: symbol, group: group,
                  inputs: inputs, helpers: [.ffmpeg, .ffprobe]) { ctx in
            let info = try await FFmpeg.probe(ctx.input)
            if FFmpeg.codecArgs(for: target).first == "-vn", !info.hasAudio {
                throw ConvertError.failed("\(ctx.input.lastPathComponent) has no audio track.")
            }
            let out = ctx.out(ctx.baseName, target.ext)
            try await FFmpeg.run(["-i", ctx.input.path] + FFmpeg.codecArgs(for: target), output: out,
                                 duration: info.duration, ctx: ctx)
            return [out]
        }
    }
}
