import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

/// Runs external programs asynchronously, with cancellation and line-by-line stdout streaming.
public enum ProcessRunner {
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let extra = "/usr/local/bin:/opt/homebrew/bin:/opt/local/bin"
        env["PATH"] = extra + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        env["LC_ALL"] = env["LC_ALL"] ?? "en_US.UTF-8"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        return env
    }()

    /// Runs `executable` and throws if it exits non-zero.
    @discardableResult
    public static func run(_ executable: String, _ args: [String], cwd: URL? = nil,
                           environment extraEnv: [String: String] = [:],
                           onLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        let result = try await runAllowingFailure(executable, args, cwd: cwd, environment: extraEnv, onLine: onLine)
        guard result.status == 0 else {
            let name = URL(fileURLWithPath: executable).lastPathComponent
            let detail = (result.stderr.isEmpty ? result.stdout : result.stderr)
                .split(separator: "\n").suffix(6).joined(separator: "\n")
            throw ConvertError.failed("\(name) failed (exit \(result.status)).\n\(detail)")
        }
        return result
    }

    public static func runAllowingFailure(_ executable: String, _ args: [String], cwd: URL? = nil,
                                          environment extraEnv: [String: String] = [:],
                                          onLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = environment.merging(extraEnv) { $1 }
        if let cwd { process.currentDirectoryURL = cwd }
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let collector = OutputCollector(onLine: onLine)
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { collector.appendOut(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { collector.appendErr(d) }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, Error>) in
                process.terminationHandler = { p in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    collector.appendOut(outPipe.fileHandleForReading.readDataToEndOfFile())
                    collector.appendErr(errPipe.fileHandleForReading.readDataToEndOfFile())
                    if collector.cancelled {
                        cont.resume(throwing: ConvertError.cancelled)
                    } else {
                        cont.resume(returning: ProcessResult(status: p.terminationStatus,
                                                             stdout: collector.out, stderr: collector.err))
                    }
                }
                do { try process.run() } catch {
                    cont.resume(throwing: ConvertError.failed("Could not start \(executable): \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            collector.cancelled = true
            if process.isRunning { process.terminate() }
        }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var outData = Data(), errData = Data(), lineBuffer = Data()
    private let onLine: (@Sendable (String) -> Void)?
    var cancelled = false

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func appendOut(_ d: Data) {
        guard !d.isEmpty else { return }
        lock.lock()
        outData.append(d)
        var lines: [String] = []
        if onLine != nil {
            lineBuffer.append(d)
            while let nl = lineBuffer.firstIndex(of: 0x0A) {
                let line = lineBuffer[lineBuffer.startIndex..<nl]
                lines.append(String(decoding: line, as: UTF8.self))
                lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            }
        }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }

    func appendErr(_ d: Data) {
        guard !d.isEmpty else { return }
        lock.lock(); errData.append(d); lock.unlock()
    }

    var out: String { lock.lock(); defer { lock.unlock() }; return String(decoding: outData, as: UTF8.self) }
    var err: String { lock.lock(); defer { lock.unlock() }; return String(decoding: errData, as: UTF8.self) }
}
