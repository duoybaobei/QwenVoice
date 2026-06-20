import Foundation
import QwenVoiceCore

/// `vocello models` — read-only inventory of the contract's models: install state,
/// on-disk size, and (for `status`) any missing required files. No download
/// machinery — honors the no-bundled-weights framing. Uses the lightweight
/// registry bootstrap (no engine boot).
enum ModelsCommand {
    struct ModelJSON: Encodable {
        let id: String
        let mode: String
        let name: String
        let installed: Bool
        let missingPaths: [String]
        let installedBytes: Int64
        let estimatedDownloadBytes: Int64?
    }

    @MainActor
    static func run(_ argv: [String]) async throws {
        var argv = argv
        let action = argv.first?.lowercased() ?? "list"
        if action == "help" || action == "--help" { printHelp(); return }
        let detailed = (action == "status")
        if !argv.isEmpty, action == "list" || action == "ls" || action == "status" { argv.removeFirst() }
        guard action == "list" || action == "ls" || action == "status" || action.hasPrefix("--") else {
            throw CLIError("unknown models action '\(action)' (use list | status [<id>])")
        }

        let args = Args(argv)
        CLIOutput.configure(args)
        let ctx = try CLIRuntime.bootstrapRegistryOnly(
            dataDirectory: CLIPaths.dataDirectory(override: args.string("data-dir")),
            manifestOverride: args.string("manifest").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })

        let onlyID = args.positionals.first  // optional `status <id>` / `list <id>` filter

        var rows: [ModelJSON] = []
        for m in ctx.registry.models {
            if let onlyID, m.id != onlyID { continue }
            let installed: Bool
            let missing: [String]
            switch ctx.registry.availability(forModelID: m.id, in: ctx.modelsDirectory) {
            case .available: installed = true; missing = []
            case .unavailable(_, let paths): installed = false; missing = paths
            case .unknown: installed = false; missing = []
            }
            rows.append(ModelJSON(
                id: m.id, mode: m.mode.rawValue, name: m.name,
                installed: installed, missingPaths: missing,
                installedBytes: directorySize(m.installDirectory(in: ctx.modelsDirectory)),
                estimatedDownloadBytes: m.estimatedDownloadBytes))
        }
        if let onlyID, rows.isEmpty { throw CLIError("no model '\(onlyID)' in the contract") }

        if args.flag("json") { emitJSON(rows); return }

        guard !rows.isEmpty else { print("(no models in contract)"); return }
        for r in rows {
            let mark = r.installed ? "✓" : (r.missingPaths.isEmpty ? "?" : "✗")
            let size = r.installed
                ? humanBytes(r.installedBytes)
                : (r.estimatedDownloadBytes.map { "~\(humanBytes($0)) to download" } ?? "not installed")
            print("\(mark) \(r.id)\t[\(r.mode)]\t\(size)")
            if detailed {
                for p in r.missingPaths { print("    missing: \(p)") }
            }
        }
    }

    static func printHelp() {
        print("""
        vocello models — inventory installed/available models (read-only)

        Usage:
          vocello models list [--json]
          vocello models status [<id>] [--json]     # adds missing-file detail

        Variant-scoped ids (…_speed / …_quality) are what `generate --variant` selects.

        Options:
          --json       emit JSON instead of a table
          --data-dir   runtime dir (default ~/Library/Application Support/QwenVoice-Local[-Debug])
          --manifest   override path to qwenvoice_contract.json
        """)
    }
}
