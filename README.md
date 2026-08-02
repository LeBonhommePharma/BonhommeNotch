# BonhommeNotch

Local multi-session telemetry HUD for AI coding agents on macOS. Clean-room reimplementation of the **AgentNotch-class** local architecture (Unix socket + NDJSON hooks + needs-you ranking + inline Approve/Deny), not a clone of commercial branding or binaries.

## Requirements

- macOS 14+
- Swift 5.9+ / Xcode command-line tools

## Build & run

```bash
cd ~/Projects/BonhommeNotch
swift build -c release
swift run BonhommeNotch                 # menu bar + socket
swift run BonhommeNotch --socket-selftest
swift run BonhommeNotch --status
swift run BonhommeNotch --print-paths
swift test
```

Release binary: `.build/release/BonhommeNotch`

The app is a **menu-bar accessory** (`LSUIElement`-style). Title shows `BN`, `BN·N`, or `BN·!` when something needs you. Expand the menu for the live roster and Approve/Deny on Claude/Codex gates.

## Socket protocol (NDJSON v1)

Default path:

```text
~/Library/Application Support/BonhommeNotch/notch.sock
```

Override: `BONHOMME_NOTCH_SOCKET` or `AGENT_NOTCH_SOCKET`.

Each line is one JSON object:

| Field | Required | Notes |
|-------|----------|--------|
| `v` | yes | `1` |
| `source` | yes | `claude` · `codex` · `cursor` · `kimi` |
| `session_id` | yes | stable session key |
| `action` | yes | see below |
| `cwd`, `tool_name`, `detail`, `model`, `kind`, … | optional | |

**Actions:** `start` · `busy` · `busydone` · `done` · `clear` · `marker` · `gate` · `pending` · `pending-clear` · `activity` · `activity-clear` · `observe`

**Ranking:** needs-you (gate / question / plan / pending) → working → done → idle.

**Gate replies** (blocking only for Claude/Codex; Cursor is observe-only):

- Claude allow: `{ "behavior": "allow", "updatedInput": { … } }`
- Deny: `{ "behavior": "deny", "message": "…" }`
- Timeout / socket down: **fail-open** (hook prints nothing → agent’s own prompt)

Status mirror for automation:

```text
~/Library/Application Support/BonhommeNotch/status.json
```

## Hook bridges

Managed scripts in `hooks/`:

| Script | Agent |
|--------|--------|
| `hooks/notch-hook.py` | Claude Code |
| `hooks/notch-cursor-hook.py` | Cursor (observe-only) |
| `hooks/notch-codex-hook.py` | Codex |

Install copies:

```bash
./Scripts/install-hooks.sh
```

### Claude Code (`~/.claude/settings.json` sketch)

```json
{
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "\"/usr/bin/python3\" \"$HOME/.claude/bonhomme-notch/notch-hook.py\" start" }] }],
    "PermissionRequest": [{ "matcher": "*", "hooks": [{ "type": "command", "timeout": 1800, "command": "\"/usr/bin/python3\" \"$HOME/.claude/bonhomme-notch/notch-hook.py\" gate" }] }],
    "PreToolUse": [
      { "matcher": "AskUserQuestion|ExitPlanMode", "hooks": [{ "type": "command", "command": "\"/usr/bin/python3\" \"$HOME/.claude/bonhomme-notch/notch-hook.py\" ask" }] },
      { "matcher": "*", "hooks": [{ "type": "command", "command": "\"/usr/bin/python3\" \"$HOME/.claude/bonhomme-notch/notch-hook.py\" busy" }] }
    ],
    "PostToolUse": [
      { "matcher": "AskUserQuestion|ExitPlanMode", "hooks": [{ "type": "command", "command": "\"/usr/bin/python3\" \"$HOME/.claude/bonhomme-notch/notch-hook.py\" clear" }] },
      { "matcher": "*", "hooks": [{ "type": "command", "command": "\"/usr/bin/python3\" \"$HOME/.claude/bonhomme-notch/notch-hook.py\" busydone" }] }
    ],
    "Stop": [{ "hooks": [{ "type": "command", "command": "\"/usr/bin/python3\" \"$HOME/.claude/bonhomme-notch/notch-hook.py\" done" }] }]
  }
}
```

Dry-run (fail-open if app not running):

```bash
python3 Scripts/hook-dry-run.py start
```

## Tests

```bash
swift test
swift run BonhommeNotch --socket-selftest
```

Unit tests drive real `HookProtocol`, `SessionStore`, and `GateDecisionBuilder` with NDJSON fixtures. The socket self-test starts the **same** `SocketBridge` used by the app, injects multi-session traffic, and asserts ranking + Claude allow / Codex deny reply shapes.

## Layout

```text
Sources/BonhommeNotchCore/   Pure protocol, store, ranking, gate decisions
Sources/BonhommeNotch/       Menu bar app + SocketBridge + --socket-selftest
Tests/BonhommeNotchCoreTests/
hooks/                       Claude / Cursor / Codex bridges
Scripts/                     install-hooks.sh, hook-dry-run.py
```

## Non-goals

Commercial branding, Sparkle/license, OTEL, full AgentPeek matrix, spend/usage API scraping, jump-to-terminal AX automation.

## License

MIT — clean-room; no proprietary Agent Notch sources.
