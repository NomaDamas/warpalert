# warp-agent-hooks

Multi-agent **Warp Terminal** integration hooks for **Claude Code**, **Codex CLI**, **OpenCode**, **Gemini CLI** — anything that finishes a turn or asks for input deserves a Warp toast.

This is the third-party answer to "I want Claude Code's sidebar entry to also work for Codex / Gemini / OpenCode, and I want a real OS toast on every turn, not just a structured payload Warp may or may not render."

> The official `warpdotdev/claude-code-warp` plugin only supports Claude Code, only emits OSC 777, and silently no-ops on hosts where the hook subprocess has no controlling `/dev/tty`. This repo fixes all three.

---

## What it does

| Surface | Mechanism | Source |
|---|---|---|
| **Warp left sidebar entry** | OSC 777 with title `warp://cli-agent` + v1 JSON payload | Warp's structured CLI Agent Protocol |
| **Desktop toast** (top-right) | OSC 9 with localizable body | iTerm-compatible system notification |
| **tmux passthrough** | Auto DCS-wraps both sequences when `$TMUX` is set | tmux `allow-passthrough` (≥ 3.3 default on) |
| **No controlling tty fallback** | Falls back to `tmux display-message -p '#{pane_tty}'` when `/dev/tty` open fails | Required for headless agent harnesses |

Per-event behavior:

| Event | Sidebar | Toast |
|---|---|---|
| `session_start` | yes (with `plugin_version`) | — |
| `prompt_submit` | yes | — |
| `tool_complete` | yes | — |
| `permission_request` | yes (with `tool_name`, `tool_input`, `summary`) | ⚠️ `{project} — {agent} needs input` |
| `idle_prompt` | yes (with `summary`) | 💬 `{project} — {agent} waiting` |
| `stop` | yes (with `query`, `response`, `transcript_path` extracted from Claude-format transcripts) | ✅ `{project} — {agent} done` |

---

## Why not the official plugin?

The official `warpdotdev/claude-code-warp` plugin:

1. **Hardcoded to `agent="claude"`** in the v1 schema. Codex / Gemini / OpenCode get nothing.
2. **Uses `> /dev/tty 2>/dev/null`** which does **not** suppress bash's redirection-failed error. On a host where the hook subprocess has no controlling tty, the official `warp-notify.sh` prints `/dev/tty: No such device or address` to the parent agent's stderr and emits nothing to Warp.
3. **Emits only OSC 777**, not OSC 9. If Warp's sidebar isn't visible (collapsed, different workspace, etc.) the user gets zero visible feedback. OSC 9 → real OS toast → user always sees it.
4. **No tmux DCS wrapping** in the notify path. Works only if `allow-passthrough` is on. Older tmux configs silently drop the OSC.
5. **Floods Warp during loop-based runners** (oh-my-codex team mode fires 1600+ stop events per task). No suppression.

This repo addresses all five. Claude Code users who want the richest sidebar can keep the official plugin AND wire this for Codex/Gemini/OpenCode — no conflict.

---

## Install

```bash
git clone https://github.com/HaD0Yun/warp-agent-hooks.git ~/.warp-agent-hooks
~/.warp-agent-hooks/install.sh
```

The installer:
1. Symlinks `~/.warp-agent-hooks/hooks/warp-agent-event.sh` (does not modify your existing hook files).
2. Prints the **exact JSON / TOML snippets** to paste into each agent's config (`~/.claude/settings.json`, `~/.codex/hooks.json`, `~/.codex/config.toml`, `~/.config/opencode/opencode.json`).
3. Does **not** auto-edit your config files — you stay in control.

Manual wiring snippets are in [`examples/`](examples/).

### Prerequisites

- Warp Terminal — any build that exports `WARP_CLI_AGENT_PROTOCOL_VERSION` and `WARP_CLIENT_VERSION` (i.e. HOA notifications enabled). All recent builds qualify.
- `bash` (any version) for the script itself.
- `jq` for the richest JSON payloads (recommended). `python3` is used as a fallback.
- `tmux` ≥ 3.3 if you run agents inside tmux (`allow-passthrough` is on by default).

---

## Wiring

### Claude Code (`~/.claude/settings.json`)

Add to your `hooks` block (see [`examples/claude-settings-hooks.json`](examples/claude-settings-hooks.json) for the full file shape):

```jsonc
{
  "hooks": {
    "SessionStart": [{
      "matcher": "",
      "hooks": [{ "type": "command",
        "command": "$HOME/.warp-agent-hooks/hooks/warp-agent-event.sh session_start claude" }]
    }],
    "Stop": [{
      "matcher": "",
      "hooks": [{ "type": "command",
        "command": "$HOME/.warp-agent-hooks/hooks/warp-agent-event.sh stop claude" }]
    }],
    "Notification": [{
      "matcher": "",
      "hooks": [{ "type": "command",
        "command": "$HOME/.warp-agent-hooks/hooks/warp-agent-event.sh idle_prompt claude" }]
    }],
    "PermissionRequest": [{
      "matcher": "",
      "hooks": [{ "type": "command",
        "command": "$HOME/.warp-agent-hooks/hooks/warp-agent-event.sh permission_request claude" }]
    }]
  }
}
```

> If you keep the official `warp@claude-code-warp` plugin, **remove the Claude wiring above** to avoid duplicate toasts — let the official plugin own Claude and use this repo only for Codex/Gemini/OpenCode.

### Codex CLI

Two pieces.

**(a) `~/.codex/hooks.json`** — for `pre_tool_use`, `post_tool_use`, `permission_request`, `user_prompt_submit`, `session_start`, `pre_compact`, `post_compact`. See [`examples/codex-hooks.json`](examples/codex-hooks.json).

```jsonc
{
  "hooks": {
    "SessionStart": [{
      "matcher": "startup|resume",
      "hooks": [{ "type": "command",
        "command": "$HOME/.warp-agent-hooks/hooks/warp-agent-event.sh session_start codex" }]
    }],
    "PermissionRequest": [{
      "hooks": [{ "type": "command",
        "command": "$HOME/.warp-agent-hooks/hooks/warp-agent-event.sh permission_request codex" }]
    }]
  }
}
```

**(b) `~/.codex/config.toml`** — for **agent-turn-complete**, which Codex CLI does **not** fire through `hooks.json`. The only path is the `notify` directive. Use the bridge:

```toml
notify = ["/home/youruser/.warp-agent-hooks/hooks/codex-notify-bridge.sh"]
```

If you were already chaining a previous `notify` handler (e.g. oh-my-codex's `notify-hook.js`), set:

```bash
export WARP_AGENT_CODEX_NOTIFY_INNER=/path/to/your/previous/notify-hook.js
```

and the bridge will fan out to both.

### OpenCode

```jsonc
{
  "hooks": {
    "SessionStart": [{ "matcher": "",
      "hooks": [{ "type": "command",
        "command": "$HOME/.warp-agent-hooks/hooks/warp-agent-event.sh session_start opencode" }] }],
    "Stop": [{ "matcher": "",
      "hooks": [{ "type": "command",
        "command": "$HOME/.warp-agent-hooks/hooks/warp-agent-event.sh stop opencode" }] }]
  }
}
```

### Gemini CLI

Gemini's hook system uses snake_case events. Wire `session_start`, `stop`, and `user_prompt_submit` similarly. See [`examples/gemini-settings-hooks.json`](examples/gemini-settings-hooks.json).

---

## Configuration

Everything is via environment variables. No config file.

| Variable | Default | Effect |
|---|---|---|
| `WARP_AGENT_LOG_FILE` | `$HOME/.warp-agent-hooks/warp-agent-event.log` | Debug log path (rotates at 1 MB → `.log.1`) |
| `WARP_AGENT_LOG_MAX_BYTES` | `1048576` | Rotation threshold |
| `WARP_AGENT_SUPPRESS_STOP` | unset | Set to `1` to drop `stop` events (use from loop runners) |
| `WARP_AGENT_TOAST_STOP` | `✅ {project} — {agent} done` | OSC 9 body for stop |
| `WARP_AGENT_TOAST_PERMISSION` | `⚠️ {project} — {agent} needs input` | OSC 9 body for permission_request |
| `WARP_AGENT_TOAST_IDLE` | `💬 {project} — {agent} waiting` | OSC 9 body for idle_prompt |
| `WARP_AGENT_HOOK` | auto-discovered | Path to `warp-agent-event.sh` (for the codex bridge) |
| `WARP_AGENT_CODEX_NOTIFY_INNER` | unset | Inner `notify` handler the bridge should also dispatch to |
| `WARP_AGENT_CODEX_NOTIFY_INNER_INTERPRETER` | auto (`node` for `.js`) | Interpreter for the inner handler |

Toast templates support `{project}` and `{agent}` placeholders.

oh-my-codex team mode is auto-detected via `OMX_TEAM_WORKER` / `OMX_TEAM_INTERNAL_WORKER` / `OMX_TEAM_STATE_ROOT` / `OMX_TEAM_LEADER_CWD` — for non-OMX users these env vars are simply never set and the suppression branch is dead code.

---

## How it works

When an agent CLI invokes the hook:

1. Validate `event` against the v1 set (`session_start | stop | permission_request | idle_prompt | prompt_submit | tool_complete`). Unknown → silent no-op.
2. Gate on `WARP_CLI_AGENT_PROTOCOL_VERSION` + `WARP_CLIENT_VERSION` — if either is missing we either aren't in Warp or the build can't render structured events. Silent no-op.
3. Honor `stop_hook_active=true` from stdin (Claude/Codex re-entrant flag).
4. Drop `stop` events if any team-mode env var or `WARP_AGENT_SUPPRESS_STOP=1` is set.
5. Build the JSON payload (v=1, `agent`, `event`, `session_id`, `cwd`, `project=basename(cwd)`, plus event-specific fields). Uses `jq` when present, `python3` fallback.
6. Resolve target tty: try `/dev/tty` first, fall back to `tmux display-message -p '#{pane_tty}'` if it isn't writable.
7. Emit OSC 777 `notify;warp://cli-agent;{JSON}` — DCS-wrapped if inside tmux.
8. Emit OSC 9 toast body — DCS-wrapped if inside tmux.
9. Append a one-line debug entry to the log, flock-serialized.

Total per-call cost: ~10 ms with `jq` (single `jq -nc` invocation), ~30 ms with `python3` fallback. Concurrent calls (e.g. 50 parallel hook fires) are flock-serialized for the log writer; the OSC emission itself is lock-free.

### Protocol references

- Warp CLI Agent Protocol v1 schema: [`warpdotdev/warp/.../cli_agent_sessions/event/v1.rs`](https://github.com/warpdotdev/warp/blob/main/app/src/terminal/cli_agent_sessions/event/v1.rs)
- Recognized agent slugs: [`warpdotdev/warp/.../cli_agent.rs`](https://github.com/warpdotdev/warp/blob/main/app/src/terminal/cli_agent.rs)
- Official Claude Code plugin: [`warpdotdev/claude-code-warp`](https://github.com/warpdotdev/claude-code-warp)
- Codex hook spec: [developers.openai.com/codex/hooks](https://developers.openai.com/codex/hooks)
- Claude Code hook spec: [code.claude.com/docs/en/hooks](https://code.claude.com/docs/en/hooks.md)

---

## Manual test

```bash
WARP_CLI_AGENT_PROTOCOL_VERSION=1 \
WARP_CLIENT_VERSION=v0.2026.04.29.test \
~/.warp-agent-hooks/hooks/warp-agent-event.sh stop codex <<< '{"session_id":"manual-test"}'

tail -1 ~/.warp-agent-hooks/warp-agent-event.log
```

You should see `emit=ok ...` in the log and a `✅ home — codex done` toast in the top-right of Warp.

If you see `emit=fail` instead, check the `err=` field — common causes are `tmux allow-passthrough off` (run `tmux set -g allow-passthrough on`) or running outside both a controlling tty and a tmux session.

---

## License

MIT — see [LICENSE](LICENSE).

## Contributing

Issues and PRs welcome. Useful additions:
- Configurable toast emoji set
- Native macOS / Windows notification fallback when `WARP_*` env is unset (so the hook still beeps the user in non-Warp terminals)
- Helper to scrub stale `~/.warp-agent-hooks/warp-agent-event.log.1` rotation files
- OS-specific install flow (Homebrew tap?)

This is a community tool — not affiliated with Warp, Anthropic, OpenAI, or Google.
