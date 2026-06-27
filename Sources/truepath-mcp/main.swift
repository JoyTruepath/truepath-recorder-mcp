import Foundation

// truepath-mcp — an MCP (Model Context Protocol) server, over stdio, that lets a
// user's AI agent (Claude Desktop / Claude Code / Codex / Cursor) drive
// TruePath Recorder. A thin bridge: MCP tool calls → the app's localhost control
// API (AgentControlServer). Bundled inside the .app; the host spawns it.
//
// Flow: read {port, token} the app wrote to its container handshake file → HTTP
// to 127.0.0.1:port with X-Agent-Token. If the app isn't running, launch it and
// wait. initialize/tools-list work without the app; only tool *calls* need it.

let BUNDLE_ID = "com.joytruepath.recorder"
let DEFAULT_PROTOCOL = "2024-11-05"
let SERVER_NAME = "truepath-recorder"
let SERVER_VERSION = "0.1.0"

// MARK: - Handshake + control-API client

struct Handshake { let port: Int; let token: String }

let APP_GROUP = "G2KGFJ9D9T.com.joytruepath.recorder"

func handshakeURL() -> URL {
    // Bundled (sandboxed) build: resolve the shared App Group container.
    if let c = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: APP_GROUP) {
        return c.appendingPathComponent("TruePathRecorder/agent-control.json")
    }
    // Standalone (non-sandboxed) build: read the same App Group container directly.
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/\(APP_GROUP)/TruePathRecorder/agent-control.json")
}

func readHandshake() -> Handshake? {
    guard let data = try? Data(contentsOf: handshakeURL()),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let port = obj["port"] as? Int, let token = obj["token"] as? String else { return nil }
    return Handshake(port: port, token: token)
}

/// Synchronous request to the control API. Returns (statusCode, jsonObject).
func apiRequest(_ method: String, _ path: String, _ h: Handshake) -> (Int, [String: Any])? {
    guard let url = URL(string: "http://127.0.0.1:\(h.port)\(path)") else { return nil }
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.setValue(h.token, forHTTPHeaderField: "X-Agent-Token")
    req.timeoutInterval = 120
    let sem = DispatchSemaphore(value: 0)
    var out: (Int, [String: Any])?
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        defer { sem.signal() }
        guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        out = ((resp as? HTTPURLResponse)?.statusCode ?? 0, obj)
    }.resume()
    sem.wait()
    return out
}

func reachable(_ h: Handshake) -> Bool { apiRequest("GET", "/status", h) != nil }

/// Return a live handshake, launching the app if needed.
func ensureApp() -> Handshake? {
    if let h = readHandshake(), reachable(h) { return h }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-g", "-b", BUNDLE_ID]
    try? p.run()
    p.waitUntilExit()
    for _ in 0..<16 {                       // ~8s for launch + server bind
        Thread.sleep(forTimeInterval: 0.5)
        if let h = readHandshake(), reachable(h) { return h }
    }
    return nil
}

// MARK: - JSON-RPC / MCP plumbing

let stdout = FileHandle.standardOutput

func send(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    stdout.write(data)
    stdout.write(Data("\n".utf8))
}

func respond(id: Any, _ result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
func respondError(id: Any, _ code: Int, _ message: String) {
    send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

func textResult(_ text: String, isError: Bool = false) -> [String: Any] {
    ["content": [["type": "text", "text": text]], "isError": isError]
}

// MARK: - Tools

let TOOLS: [[String: Any]] = [
    ["name": "get_status",
     "description": "Check whether TruePath Recorder is currently recording (idle / starting / recording / paused) and the elapsed time.",
     "inputSchema": ["type": "object", "properties": [String: Any]()]],
    ["name": "list_sources",
     "description": "List capturable displays and windows (with ids) so you can pick one for window/area recording.",
     "inputSchema": ["type": "object", "properties": [String: Any]()]],
    ["name": "start_recording",
     "description": "Start a screen recording in TruePath Recorder. All settings are optional and fall back to the app's current values. The recording stays on the user's Mac.",
     "inputSchema": [
        "type": "object",
        "properties": [
            "mode": ["type": "string", "enum": ["display", "window", "area"], "description": "What to capture."],
            "mic": ["type": "boolean", "description": "Include microphone audio."],
            "system_audio": ["type": "boolean", "description": "Include system audio."],
            "codec": ["type": "string", "enum": ["h264", "hevc"], "description": "Video codec (hevc = smaller files)."],
            "display_id": ["type": "integer", "description": "Display to capture (from list_sources) when mode=display."],
            "window_id": ["type": "integer", "description": "Window to capture (from list_sources) when mode=window."],
        ],
     ]],
    ["name": "stop_recording",
     "description": "Stop the current recording and save the file. Returns the saved file path.",
     "inputSchema": ["type": "object", "properties": [String: Any]()]],
]

func startQuery(_ args: [String: Any]) -> String {
    var items: [String] = []
    if let m = args["mode"] as? String { items.append("mode=\(m)") }
    if let b = args["mic"] as? Bool { items.append("mic=\(b ? 1 : 0)") }
    if let b = args["system_audio"] as? Bool { items.append("system_audio=\(b ? 1 : 0)") }
    if let c = args["codec"] as? String { items.append("codec=\(c)") }
    if let d = args["display_id"] as? Int { items.append("display_id=\(d)") }
    if let w = args["window_id"] as? Int { items.append("window_id=\(w)") }
    return items.isEmpty ? "" : "?" + items.joined(separator: "&")
}

func callTool(_ name: String, _ args: [String: Any]) -> [String: Any] {
    guard let h = ensureApp() else {
        return textResult("Can't reach TruePath Recorder. Open the app and turn on Settings → AI Agent Control (off by default).", isError: true)
    }
    let result: (Int, [String: Any])?
    switch name {
    case "get_status":      result = apiRequest("GET", "/status", h)
    case "list_sources":    result = apiRequest("GET", "/sources", h)
    case "start_recording": result = apiRequest("POST", "/start" + startQuery(args), h)
    case "stop_recording":  result = apiRequest("POST", "/stop", h)
    default: return textResult("Unknown tool: \(name)", isError: true)
    }
    guard let (_, obj) = result else { return textResult("No response from TruePath Recorder.", isError: true) }
    if let err = obj["error"] as? String { return textResult("TruePath Recorder: \(err)", isError: true) }

    switch name {
    case "list_sources":
        let displays = (obj["displays"] as? [[String: Any]]) ?? []
        let windows = (obj["windows"] as? [[String: Any]]) ?? []
        var lines = ["Displays:"]
        lines += displays.map { "  • id \($0["id"] ?? "?"): \($0["title"] ?? "")" }
        lines.append("Windows:")
        lines += windows.map { "  • id \($0["id"] ?? "?"): \($0["app"] ?? "") — \($0["title"] ?? "")" }
        return textResult(lines.joined(separator: "\n"))
    case "stop_recording":
        let state = obj["state"] as? String ?? "idle"
        if let path = obj["path"] as? String {
            let dur = obj["duration"] as? String ?? "?"
            let size = obj["size"] as? String ?? "?"
            return textResult("Saved: \(path)\nDuration \(dur), \(size). State: \(state).")
        }
        return textResult("Stopped. State: \(state).")
    default:
        let state = obj["state"] as? String ?? "unknown"
        let elapsed = obj["elapsed_seconds"] as? Int ?? 0
        return textResult(elapsed > 0 ? "State: \(state) (\(elapsed)s)." : "State: \(state).")
    }
}

// MARK: - stdio loop (newline-delimited JSON-RPC)

while let line = readLine(strippingNewline: true) {
    if line.isEmpty { continue }
    guard let data = line.data(using: .utf8),
          let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
    let method = msg["method"] as? String
    let id = msg["id"]

    switch method {
    case "initialize":
        let clientProto = (msg["params"] as? [String: Any])?["protocolVersion"] as? String
        respond(id: id ?? NSNull(), [
            "protocolVersion": clientProto ?? DEFAULT_PROTOCOL,
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": SERVER_NAME, "version": SERVER_VERSION],
        ])
    case "notifications/initialized", "notifications/cancelled":
        break
    case "ping":
        if let id { respond(id: id, [:]) }
    case "tools/list":
        if let id { respond(id: id, ["tools": TOOLS]) }
    case "tools/call":
        guard let id else { break }
        let params = msg["params"] as? [String: Any]
        let name = params?["name"] as? String ?? ""
        let args = params?["arguments"] as? [String: Any] ?? [:]
        respond(id: id, callTool(name, args))
    default:
        if let id { respondError(id: id, -32601, "Method not found: \(method ?? "")") }
    }
}
