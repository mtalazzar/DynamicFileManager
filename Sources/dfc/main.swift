import Foundation
import ConverterCore

// dfc — command-line front end to the DynamicFileConverter engine.
//
//   dfc list <file>...                       operations available for the files
//   dfc convert <file>... --to <FORMAT>      e.g. --to docx
//   dfc run <operation-id> <file>... [key=value ...]
//   dfc helpers                              helper tool status

func usage() -> Never {
    print("""
    usage:
      dfc list <file>...
      dfc convert <file>... --to <format> [--out <dir>]
      dfc run <operation-id> <file>... [key=value ...] [--out <dir>]
      dfc helpers
    """)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
args.removeFirst()

var outDir: URL?
if let i = args.firstIndex(of: "--out"), i + 1 < args.count {
    outDir = URL(fileURLWithPath: args[i + 1]); args.removeSubrange(i...(i + 1))
}

func files(_ list: [String]) -> [URL] {
    list.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
}

func execute(_ op: FileOp, _ inputs: [URL], _ options: Options) async -> Int32 {
    let start = Date()
    do {
        let outs = try await Engine.shared.run(op, inputs: inputs, options: options, outputDir: outDir) { p in
            FileHandle.standardError.write("\r\(op.title): \(Int(p * 100))%   ".data(using: .utf8)!)
        }
        FileHandle.standardError.write("\n".data(using: .utf8)!)
        outs.forEach { print($0.path) }
        FileHandle.standardError.write(String(format: "done in %.1fs\n", Date().timeIntervalSince(start)).data(using: .utf8)!)
        return 0
    } catch {
        FileHandle.standardError.write("\nerror: \(error.localizedDescription)\n".data(using: .utf8)!)
        return 1
    }
}

func list(_ urls: [URL]) {
    for kind in [OpKind.convert, .tool] {
        print(kind == .convert ? "Convert:" : "Tools:")
        let ops = OperationRegistry.operations(for: urls, kind: kind)
        for (group, items) in Dictionary(grouping: ops, by: \.group).sorted(by: { $0.key < $1.key }) {
            let names = items.map { $0.isAvailable ? $0.title : "\($0.title) (needs \($0.missingHelpers.map(\.displayName).joined(separator: ", ")))" }
            print("  \(group): \(names.joined(separator: ", "))")
        }
    }
}

let code: Int32 = await {
    switch command {
    case "list":
        let urls = files(args)
        guard !urls.isEmpty else { usage() }
        list(urls)
        return 0
    case "helpers":
        for h in Helper.allCases { print("\(h.isAvailable ? "✓" : "✗") \(h.displayName)\(h.path.map { "  \($0)" } ?? "")") }
        return 0
    case "convert":
        guard let i = args.firstIndex(of: "--to"), i + 1 < args.count else { usage() }
        let target = args[i + 1].lowercased()
        args.removeSubrange(i...(i + 1))
        let urls = files(args)
        guard !urls.isEmpty else { usage() }
        let ops = OperationRegistry.operations(for: urls, kind: .convert)
        guard let op = ops.first(where: { $0.title.lowercased() == target || $0.id.hasSuffix(".\(target)") }) else {
            FileHandle.standardError.write("No conversion to \(target) for these files. Try `dfc list`.\n".data(using: .utf8)!)
            return 1
        }
        return await execute(op, urls, [:])
    case "run":
        guard let id = args.first, let op = OperationRegistry.operation(id: id) else {
            print("FileOp ids:"); OperationRegistry.all.forEach { print("  \($0.id)") }
            return 2
        }
        let rest = args.dropFirst()
        var options = Options()
        var paths: [String] = []
        for a in rest {
            if let eq = a.firstIndex(of: "="), !FileManager.default.fileExists(atPath: a) {
                options[String(a[..<eq])] = String(a[a.index(after: eq)...])
            } else { paths.append(a) }
        }
        let urls = files(paths)
        guard op.accepts(urls) else {
            FileHandle.standardError.write("\(op.id) does not accept these files.\n".data(using: .utf8)!)
            return 1
        }
        return await execute(op, urls, options)
    default:
        usage()
    }
}()
exit(code)
