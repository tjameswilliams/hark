import SwiftUI

// The "Connect to AI tools" tab: a walkthrough that registers the bundled
// hark-mcp binary (a read-only stdio MCP server over the Hark knowledge base)
// with Claude Code, OpenCode, and Codex — detection, one-click install via
// `hark-mcp install`, manual config snippets, and a live handshake test.

// MARK: - Clients

enum MCPClient: String, CaseIterable, Identifiable, Sendable {
    case claude
    case opencode
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .opencode: return "OpenCode"
        case .codex: return "Codex"
        }
    }
}

// MARK: - Process plumbing (blocking; always run via Task.detached)

enum MCPRunner {
    struct CommandResult: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        var ok: Bool { exitCode == 0 }
    }

    enum HandshakeOutcome: Sendable {
        case ok(toolCount: Int)
        case failed(String)
    }

    /// Runs `hark-mcp <args>` to completion and captures both streams.
    /// Blocking — call from a detached task.
    nonisolated static func run(binaryPath: String, args: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = args
        // The app's cwd is meaningless (often "/"); anchor at $HOME so any
        // relative path the CLI prints is at least predictable.
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return CommandResult(
                exitCode: -1, stdout: "",
                stderr: "could not launch \(binaryPath): \(error.localizedDescription)")
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }

    /// Spawns `hark-mcp serve`, performs the newline-delimited JSON-RPC
    /// initialize -> initialized -> tools/list handshake over stdio, and
    /// counts the advertised tools. Closing stdin ends the server (verified
    /// against the real binary). Blocking — call from a detached task.
    nonisolated static func testHandshake(binaryPath: String) -> HandshakeOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["serve"]
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return .failed("Could not launch the server: \(error.localizedDescription)")
        }

        // Watchdog: a wedged server is killed after 10 s so readDataToEndOfFile
        // can't hang forever; cancelled on a normal exit.
        let pid = process.processIdentifier
        let watchdog = DispatchWorkItem { kill(pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)

        let messages = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"hark-settings","version":"0.1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#,
        ].joined(separator: "\n") + "\n"
        inPipe.fileHandleForWriting.write(Data(messages.utf8))
        try? inPipe.fileHandleForWriting.close()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        for line in String(decoding: outData, as: UTF8.self).split(separator: "\n") {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any],
                (object["id"] as? Int) == 2
            else { continue }
            if let result = object["result"] as? [String: Any],
               let tools = result["tools"] as? [Any] {
                return .ok(toolCount: tools.count)
            }
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String {
                return .failed("Server error: \(message)")
            }
        }
        let stderrText = String(decoding: errData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let firstErrLine = stderrText.split(separator: "\n").first.map(String.init) ?? ""
        return .failed(
            "No tools/list reply (exit \(process.terminationStatus))"
                + (firstErrLine.isEmpty ? "" : " — \(firstErrLine)"))
    }
}

// MARK: - Model

@MainActor
@Observable
final class MCPModel {
    struct RowState {
        var status = "Checking…"
        var installed = false
        var installing = false
        /// Raw install output (stdout+stderr) shown inline.
        var installOutput: String?
        var installFailed = false
        /// Claude user scope: the `claude mcp add` command the CLI printed,
        /// surfaced in a copyable field.
        var pendingCommand: String?
    }

    var rows: [MCPClient: RowState] = Dictionary(
        uniqueKeysWithValues: MCPClient.allCases.map { ($0, RowState()) })
    var testing = false
    var testResult: String?
    var testSucceeded = false

    /// The hark-mcp binary: bundled next to the app executable, with a dev
    /// fallback to <repo>/target/release/hark-mcp for unbundled runs.
    let binaryPath: String? = {
        if let exe = Bundle.main.executableURL {
            let bundled = exe.deletingLastPathComponent().appendingPathComponent("hark-mcp")
            if FileManager.default.isExecutableFile(atPath: bundled.path) {
                return bundled.path
            }
        }
        // #filePath = <repo>/apps/Hark/Sources/Hark/Settings/MCPSettingsView.swift
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Settings/
            .deletingLastPathComponent()   // Hark/
            .deletingLastPathComponent()   // Sources/
            .deletingLastPathComponent()   // Hark/ (package)
            .deletingLastPathComponent()   // apps/
            .deletingLastPathComponent()   // repo
        let dev = repo.appendingPathComponent("target/release/hark-mcp").path
        return FileManager.default.isExecutableFile(atPath: dev) ? dev : nil
    }()

    // MARK: Detection

    /// Cheap config-file checks (no CLIs spawned): ~/.codex/config.toml for
    /// Codex, ~/.config/opencode/opencode.json + ./opencode.json for
    /// OpenCode, ./.mcp.json (project scope) for Claude Code. Anything else
    /// shows "Not detected" — a Claude user-scope install can't be cheaply
    /// verified, so it stays "Not detected" even after the command is run.
    func refreshDetection() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        // Codex — substring check is enough for "[mcp_servers.hark]".
        var codex = RowState(status: "Not detected", installed: false)
        if let toml = try? String(
            contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8),
            toml.contains("mcp_servers.hark") || toml.contains("[mcp_servers]") && toml.contains("hark") {
            codex.status = "Installed (~/.codex/config.toml)"
            codex.installed = true
        }
        setDetection(.codex, codex)

        // OpenCode — user then project config.
        var opencode = RowState(status: "Not detected", installed: false)
        if jsonHasKeyPath(home.appendingPathComponent(".config/opencode/opencode.json"), ["mcp", "hark"]) {
            opencode.status = "Installed (~/.config/opencode/opencode.json)"
            opencode.installed = true
        } else if jsonHasKeyPath(cwd.appendingPathComponent("opencode.json"), ["mcp", "hark"]) {
            opencode.status = "Installed (./opencode.json)"
            opencode.installed = true
        }
        setDetection(.opencode, opencode)

        // Claude Code — project scope only (user scope lives inside the
        // claude CLI's own config).
        var claude = RowState(status: "Not detected", installed: false)
        if jsonHasKeyPath(cwd.appendingPathComponent(".mcp.json"), ["mcpServers", "hark"]) {
            claude.status = "Installed (./.mcp.json)"
            claude.installed = true
        }
        setDetection(.claude, claude)
    }

    /// Updates status/installed while keeping any install output on screen.
    private func setDetection(_ client: MCPClient, _ detection: RowState) {
        var row = rows[client] ?? RowState()
        row.status = detection.status
        row.installed = detection.installed
        rows[client] = row
    }

    private func jsonHasKeyPath(_ url: URL, _ path: [String]) -> Bool {
        guard let data = try? Data(contentsOf: url),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        for (index, key) in path.enumerated() {
            if index == path.count - 1 { return object[key] != nil }
            guard let next = object[key] as? [String: Any] else { return false }
            object = next
        }
        return false
    }

    // MARK: Install / test

    func install(_ client: MCPClient) {
        guard let binaryPath, !(rows[client]?.installing ?? false) else { return }
        rows[client]?.installing = true
        rows[client]?.installOutput = nil
        rows[client]?.pendingCommand = nil
        let clientArg = client.rawValue
        Task { @MainActor in
            let result = await Task.detached {
                MCPRunner.run(
                    binaryPath: binaryPath,
                    args: ["install", "--client", clientArg, "--scope", "user"])
            }.value
            var row = self.rows[client] ?? RowState()
            row.installing = false
            row.installFailed = !result.ok
            let combined = (result.stdout + "\n" + result.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if client == .claude, result.ok {
                // The CLI doesn't write Claude's user-scope config — it prints
                // the `claude mcp add` command to run. Surface it copyably.
                row.pendingCommand = combined
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { $0.hasPrefix("claude mcp add") }
                row.installOutput = row.pendingCommand == nil ? combined
                    : "Run this in a terminal to finish the user-scope install:"
            } else {
                row.installOutput = combined.isEmpty
                    ? (result.ok ? "Done." : "Failed (exit \(result.exitCode)).")
                    : combined
            }
            self.rows[client] = row
            self.refreshDetection()
        }
    }

    func testServer() {
        guard let binaryPath, !testing else { return }
        testing = true
        testResult = nil
        Task { @MainActor in
            let outcome = await Task.detached {
                MCPRunner.testHandshake(binaryPath: binaryPath)
            }.value
            self.testing = false
            switch outcome {
            case .ok(let toolCount):
                self.testSucceeded = true
                self.testResult = "\(toolCount) tool\(toolCount == 1 ? "" : "s") available ✓"
            case .failed(let why):
                self.testSucceeded = false
                self.testResult = why
            }
        }
    }

    // MARK: Manual snippets

    func manualSnippet(for client: MCPClient) -> String {
        let path = binaryPath ?? "/path/to/hark-mcp"
        switch client {
        case .claude:
            return """
                # User scope (all projects), via the claude CLI:
                claude mcp add --scope user hark -- \(path) serve

                # Or per project, in <project>/.mcp.json:
                {
                  "mcpServers": {
                    "hark": { "command": "\(path)", "args": ["serve"] }
                  }
                }
                """
        case .opencode:
            return """
                // ~/.config/opencode/opencode.json
                {
                  "mcp": {
                    "hark": {
                      "type": "local",
                      "command": ["\(path)", "serve"],
                      "enabled": true
                    }
                  }
                }
                """
        case .codex:
            return """
                # ~/.codex/config.toml
                [mcp_servers.hark]
                command = "\(path)"
                args = ["serve"]
                """
        }
    }
}

// MARK: - View

struct MCPSettingsView: View {
    @State private var model = MCPModel()

    var body: some View {
        Form {
            Section("Connect to AI Tools") {
                Text("Hark ships a local MCP server that lets AI coding tools search and read your meeting transcripts and dictations — everything stays on this Mac, read-only. Register it once per tool below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let path = model.binaryPath {
                    LabeledContent("Server binary") {
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                } else {
                    Label("hark-mcp binary not found next to the app — reinstall Hark.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

            ForEach(MCPClient.allCases) { client in
                Section(client.displayName) {
                    MCPClientRow(model: model, client: client)
                }
            }

            Section {
                HStack {
                    Button(model.testing ? "Testing…" : "Test Server") {
                        model.testServer()
                    }
                    .disabled(model.testing || model.binaryPath == nil)
                    if model.testing { ProgressView().controlSize(.small) }
                    Spacer()
                    if let result = model.testResult {
                        Label(
                            result,
                            systemImage: model.testSucceeded
                                ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(model.testSucceeded ? .green : .red)
                            .font(.callout)
                    }
                }
            } footer: {
                Text("Starts the server, performs the MCP handshake over stdio, and lists its tools.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshDetection() }
    }
}

private struct MCPClientRow: View {
    @Bindable var model: MCPModel
    let client: MCPClient
    @State private var showManual = false
    @State private var copiedCommand = false

    private var row: MCPModel.RowState {
        model.rows[client] ?? MCPModel.RowState()
    }

    var body: some View {
        HStack {
            Image(systemName: row.installed ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(row.installed ? .green : .secondary)
            Text(row.status)
                .foregroundStyle(row.installed ? .primary : .secondary)
                .font(.callout)
            Spacer()
            if row.installing { ProgressView().controlSize(.small) }
            Button("Install") { model.install(client) }
                .disabled(row.installing || model.binaryPath == nil)
        }

        if let output = row.installOutput {
            Text(output)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(row.installFailed ? .red : .secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        if let command = row.pendingCommand {
            HStack(spacing: 8) {
                TextField("", text: .constant(command))
                    .font(.system(.caption, design: .monospaced))
                    .labelsHidden()
                    .truncationMode(.middle)
                Button(copiedCommand ? "Copied" : "Copy") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(command, forType: .string)
                    copiedCommand = true
                }
            }
        }

        DisclosureGroup("Manual configuration", isExpanded: $showManual) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.manualSnippet(for: client))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy Snippet") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(model.manualSnippet(for: client), forType: .string)
                }
                .controlSize(.small)
            }
            .padding(.top, 4)
        }
        .font(.callout)
    }
}
