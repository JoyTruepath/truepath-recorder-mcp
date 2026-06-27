# TruePath Recorder MCP (`truepath-mcp`)

An [MCP](https://modelcontextprotocol.io) server that lets your AI agent — **Claude Desktop, Claude Code, Codex, Cursor**, or any MCP client — drive [**TruePath Recorder**](https://joytruepath.com/recorder), the native macOS screen recorder: start, stop, and check recordings, list capture sources, and get the saved file path back.

It's a thin, **local** bridge. **Your recordings never leave your Mac.**

> This server ships **bundled inside TruePath Recorder** (`Contents/MacOS/truepath-mcp`) — most users don't need to clone or build anything. This repo is the open source of that binary: for transparency, and for building it standalone.

## Requirements

- [TruePath Recorder](https://apps.apple.com/app/id6778513925) on the Mac App Store.
- In the app: **Settings → AI Agent Control → on** (off by default). That starts a local, token-protected control server this MCP talks to.

## Quick start

1. Open TruePath Recorder → **Settings → AI Agent Control** → turn it on.
2. Click **Copy** next to your agent (Claude Desktop / Claude Code / Codex / Cursor) — it copies the snippet below with the bundled binary path already filled in.
3. Paste it into your host's MCP config and restart the host.
4. Ask your agent: *"Record a 10-second screen clip with TruePath."*

### Config snippets

The bundled binary is typically at:
`/Applications/TruePath Recorder.app/Contents/MacOS/truepath-mcp`

**Claude Desktop** — `~/Library/Application Support/Claude/claude_desktop_config.json`
```json
{ "mcpServers": { "truepath": { "command": "/Applications/TruePath Recorder.app/Contents/MacOS/truepath-mcp" } } }
```

**Claude Code**
```sh
claude mcp add truepath -- "/Applications/TruePath Recorder.app/Contents/MacOS/truepath-mcp"
```

**Codex** — `~/.codex/config.toml`
```toml
[mcp_servers.truepath]
command = "/Applications/TruePath Recorder.app/Contents/MacOS/truepath-mcp"
```

**Cursor** — `~/.cursor/mcp.json`
```json
{ "mcpServers": { "truepath": { "command": "/Applications/TruePath Recorder.app/Contents/MacOS/truepath-mcp" } } }
```

## Tools

| Tool | What it does |
|---|---|
| `get_status` | `idle` / `starting` / `recording` / `paused` + elapsed seconds |
| `list_sources` | capturable displays + windows (with ids) for window/area capture |
| `start_recording` | start a recording. All optional: `mode` (`display`/`window`/`area`), `mic`, `system_audio`, `codec` (`h264`/`hevc`), `display_id`, `window_id` |
| `stop_recording` | stop + return the saved file **path**, duration, and size |

## How it works

```
AI host ──(MCP, stdio)──> truepath-mcp ──(HTTP 127.0.0.1 + token)──> TruePath Recorder
```

The app writes a `{port, token}` handshake into a shared App Group container; `truepath-mcp` reads it and calls the app's localhost-only control server. Nothing is exposed off-device.

**Privacy & security**
- Off by default; you opt in, per agent.
- The control server binds to `127.0.0.1` only and requires the per-launch token.
- The server only starts/stops the same capture the app's UI does — it never uploads recordings or anything else.

## Build from source (standalone)

```sh
swift build -c release
# binary at .build/release/truepath-mcp — point your host's config there
```

A standalone build still needs the TruePath Recorder app (with AI Agent Control on); it reads the same App Group handshake the app writes.

## License

MIT © Joy Truepath Pte. Ltd. — see [LICENSE](LICENSE).
