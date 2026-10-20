import Foundation

public enum OpKind: String, Sendable { case convert, tool }

/// A user-tweakable parameter for an operation.
public struct OptionSpec: Sendable {
    public enum Kind: Sendable {
        case choice([String])
        case text(placeholder: String)
        case secure
        case toggle
    }
    public let key: String
    public let label: String
    public let kind: Kind
    public let defaultValue: String

    public init(_ key: String, _ label: String, _ kind: Kind, default value: String) {
        self.key = key; self.label = label; self.kind = kind; self.defaultValue = value
    }
}

public typealias Options = [String: String]

public enum ConvertError: LocalizedError {
    case failed(String)
    case missingHelper(Helper)
    case unsupported(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .failed(let m): return m
        case .missingHelper(let h): return "\(h.displayName) is not installed. Open Settings → Helpers to install it."
        case .unsupported(let m): return "Not supported: \(m)"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Everything an operation needs while it runs.
public final class JobContext: @unchecked Sendable {
    public let inputs: [URL]
    public let options: Options
    /// Private scratch folder. Operations write their results here; the engine moves them into place.
    public let workDir: URL
    private let progressHandler: @Sendable (Double) -> Void

    init(inputs: [URL], options: Options, workDir: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.inputs = inputs; self.options = options; self.workDir = workDir; self.progressHandler = progress
    }

    public var input: URL { inputs[0] }
    /// Input file name without extension (handles `.tar.gz`).
    public var baseName: String { Self.baseName(of: input) }

    public static func baseName(of url: URL) -> String {
        let name = url.lastPathComponent
        if name.lowercased().hasSuffix(".tar.gz") { return String(name.dropLast(7)) }
        return url.deletingPathExtension().lastPathComponent
    }

    public func option(_ key: String, _ fallback: String = "") -> String {
        let v = options[key] ?? ""
        return v.isEmpty ? fallback : v
    }

    /// A path in the work dir: `<name>.<ext>`.
    public func out(_ name: String, _ ext: String) -> URL {
        workDir.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
    }

    /// A scratch path that will never be returned as output.
    public func temp(_ name: String) -> URL {
        let dir = workDir.appendingPathComponent(".tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    public func progress(_ value: Double) { progressHandler(min(max(value, 0), 1)) }

    public func checkCancelled() throws {
        if Task.isCancelled { throw ConvertError.cancelled }
    }
}

/// A conversion or tool. Built from closures so backends can declare many of them compactly.
public struct FileOp: Sendable, Identifiable {
    public let id: String
    public let kind: OpKind
    public let title: String
    /// SF Symbol name.
    public let symbol: String
    /// Wheel group (e.g. "Image", "Audio", "PDF").
    public let group: String
    public let inputs: Set<FileKind>
    public let helpers: [Helper]
    public let options: [OptionSpec]
    /// When true the operation receives all inputs at once (merge); otherwise it runs once per input.
    public let combinesInputs: Bool
    public let minInputs: Int
    let perform: @Sendable (JobContext) async throws -> [URL]

    public init(id: String, kind: OpKind, title: String, symbol: String, group: String,
                inputs: Set<FileKind>, helpers: [Helper] = [], options: [OptionSpec] = [],
                combinesInputs: Bool = false, minInputs: Int = 1,
                perform: @escaping @Sendable (JobContext) async throws -> [URL]) {
        self.id = id; self.kind = kind; self.title = title; self.symbol = symbol; self.group = group
        self.inputs = inputs; self.helpers = helpers; self.options = options
        self.combinesInputs = combinesInputs; self.minInputs = minInputs; self.perform = perform
    }

    public func accepts(_ urls: [URL]) -> Bool {
        guard urls.count >= minInputs else { return false }
        return urls.allSatisfy { inputs.contains(FileKind.of($0)) }
    }

    public var missingHelpers: [Helper] { helpers.filter { !$0.isAvailable } }
    public var isAvailable: Bool { missingHelpers.isEmpty }
}
