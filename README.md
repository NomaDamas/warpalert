# Wmux

> Created by **[@HaD0Yun](https://github.com/HaD0Yun)** · Maintained under [NomaDamas](https://github.com/NomaDamas)

### 🔔 Warp alert — native toasts when your AI agent finishes a turn.

Works with **Claude Code**, **Codex CLI**, **OpenCode**, and **Gemini CLI**.

When the agent finishes a turn, asks for input, or goes idle, you get a real OS notification in Warp's top-right corner. No polling, no daemons — just the agent's own lifecycle hooks firing OSC sequences that Warp natively interprets.

|   |   |
|---|---|
| ✅ | `project — claude done` |
| ⚠️ | `project — codex needs input` |
| 💬 | `project — gemini waiting` |

---

## TL;DR

```bash
# 1. Open Warp Terminal (notifications need a Warp-attached TTY)
# 2. Install
git clone https://github.com/NomaDamas/warpalert.git ~/.wmux && ~/.wmux/install.sh

# 3. Restart your agent sessions (existing sessions won't fire toasts)
# 4. Run an agent and finish a turn — toast appears in Warp's top-right
```

For unattended / AI-agent / CI use, pass `--yes`:

```bash
git clone https://github.com/NomaDamas/warpalert.git ~/.wmux && ~/.wmux/install.sh --yes
```

---

## Prerequisites

| Requirement | Why |
|---|---|
| **Warp Terminal**, running, and the install must happen *inside* a Warp tab | Wmux emits OSC 9 + OSC 777 sequences that only Warp interprets. The installer checks `WARP_CLI_AGENT_PROTOCOL_VERSION` and `WARP_CLIENT_VERSION`. If you install from a non-Warp terminal, the hooks still get wired but they will silently no-op. |
| `bash` ≥ 4 | Used by installer and event hook. |
| `jq` | Used by installer for safe JSON config merging. `apt install jq` / `brew install jq` / `pacman -S jq`. |
| `tmux` ≥ 3.3 (only if you run agents inside tmux) | Installer auto-appends `set -g allow-passthrough on` to `~/.tmux.conf` and live-applies it to every running tmux server. Without passthrough, tmux silently drops the OSC sequences. |
| At least one supported agent installed | Claude Code (`~/.claude`), Codex CLI (`~/.codex`), OpenCode (`~/.config/opencode`), Gemini CLI (`~/.gemini`). The installer auto-detects which exist and only wires those. |

---

## Install

### Interactive (humans)

```bash
git clone https://github.com/NomaDamas/warpalert.git ~/.wmux && ~/.wmux/install.sh
```

You'll see a "Detected agents" list and a `[Y/n]` prompt. Press Enter to accept.

### Non-interactive (AI agents, CI, scripts)

```bash
# Flag form
git clone https://github.com/NomaDamas/warpalert.git ~/.wmux && ~/.wmux/install.sh --yes

# Env form (useful when you can't pass flags, e.g. piping into a shell)
git clone https://github.com/NomaDamas/warpalert.git ~/.wmux && WMUX_YES=1 ~/.wmux/install.sh
```

Equivalent. Both skip the confirmation prompt.

---

## What the installer modifies

The installer touches **only** the agents it detects. Every file it writes gets a timestamped `.bak-wmux-YYYYMMDD-HHMMSS` backup next to it before being changed, and uninstall restores from that record.

| Path | Change | Backed up? |
|---|---|---|
| `~/.claude/settings.json` | Adds `SessionStart`, `Stop`, `Notification`, `PermissionRequest` hooks pointing at `~/.wmux/wmux-event.sh`. | Yes |
| `~/.codex/hooks.json` | Adds `SessionStart` and `PermissionRequest` hooks. | Yes |
| `~/.codex/config.toml` | Replaces the `notify = [...]` line with the Wmux bridge. The previous value is parsed and persisted to `~/.wmux/state/codex-inner.argv` so the prior notify handler keeps firing automatically (see [Codex notify chaining](#codex-notify-chaining)). | Yes |
| `~/.config/opencode/opencode.json` | Adds `SessionStart` and `Stop` hooks. | Yes |
| `~/.gemini/settings.json` | Adds `session_start`, `stop`, `user_prompt_submit` hooks. | Yes |
| `~/.tmux.conf` (only if `tmux` is on PATH) | Appends `set -g allow-passthrough on` once. Idempotent — re-running the installer will not duplicate the line. | Yes |
| `~/.wmux/state/` | Created. Holds `previous-codex-notify.txt` and `codex-inner.argv` for uninstall + auto-chain. | n/a |
| Live tmux servers | `tmux set -g allow-passthrough on` is invoked on every active tmux socket so the change takes effect immediately. | n/a (runtime only) |

**Your other hooks in those files are preserved.** The installer uses `jq` for JSON files so existing entries are merged, not overwritten.

---

## Verify

After install, the installer prints a "Heads up" section listing any agent processes that were already running before install — those must be restarted (see below). Then verify the install:

### 1. Config wiring check

```bash
grep -l wmux ~/.claude/settings.json ~/.codex/hooks.json ~/.codex/config.toml \
            ~/.config/opencode/opencode.json ~/.gemini/settings.json 2>/dev/null
```

Should list one line per detected agent.

### 2. Smoke test

```bash
# Must run from a real terminal. Piped/subshell calls won't have /dev/tty.
~/.wmux/hooks/wmux-event.sh stop claude < /dev/tty
tail -1 ~/.wmux/wmux.log
```

Expected log line:

```
[HH:MM:SS] agent=claude event=stop emit=ok proto=1 tty=<...> tty_src=<...> ... osc9='✅ <project> — claude done'
```

Key fields:

- `emit=ok` — the OSC sequence was written to a TTY successfully.
- `tty_src=dev_tty` — wrote to the calling shell's controlling TTY. Normal for direct-from-Warp invocation.
- `tty_src=pane_tty` — wrote to the tmux pane TTY. Normal when running inside tmux.
- `tty_src=session_client` or `any_client` — wrote to an attached tmux client TTY (fallback for detached-pane setups).
- `tty_src=dev_tty_unreachable` — no writable TTY found anywhere. The toast will not appear. See [Troubleshooting](#troubleshooting).

If `emit=ok` shows up *and* you're inside a Warp tab, you should see a toast in Warp's top-right at the moment the hook ran.

### 3. End-to-end check

Start a fresh agent session (after restarting, see next section), make it do one full turn, and watch Warp's top-right.

---

## Restart your agent sessions

Hooks are read at agent startup. **Sessions that were already running before install will not fire toasts.** Restart each one.

Pick the method that matches how you launched the agent:

| Launcher | How to restart |
|---|---|
| Direct shell invocation (`claude`, `codex`, `opencode`, `gemini`) | Exit the agent (Ctrl-D, `/exit`, or `quit`), then re-run the command. |
| Inside tmux | `tmux kill-session -t <name>` then re-create, or exit the agent inside the pane and re-run. |
| OMX / oh-my-codex / tmuxinator-style detached managers | Use the manager's restart command. For OMX-style: `omx restart` or `omx kill && omx ...`. |
| `pkill` style brute force (last resort) | `pkill -f claude\|codex\|opencode\|gemini` then launch fresh. |

To list pre-existing agent processes the installer warned about:

```bash
pgrep -af '(^|/)(claude|codex|opencode|gemini)( |$|--)'
```

---

## Customization

All optional. Set env vars before launching the agent (or in `~/.bashrc` / `~/.zshrc`).

### Toast message templates

`{project}` is replaced with the agent's CWD basename. `{agent}` is replaced with the agent name (`claude`, `codex`, `opencode`, `gemini`).

```bash
export WMUX_TOAST_STOP='✅ {project} — {agent} done'                  # default
export WMUX_TOAST_PERMISSION='⚠️ {project} — {agent} needs input'    # default
export WMUX_TOAST_IDLE='💬 {project} — {agent} waiting'              # default
```

### Codex notify chaining

If you already had `notify = [...]` set in `~/.codex/config.toml` before install (for example, oh-my-codex users), the installer parses your previous argv and persists it to `~/.wmux/state/codex-inner.argv`. The Wmux bridge auto-chains to it on every invocation, so **your previous notify handler keeps firing alongside Wmux with no manual setup.**

Override:

```bash
# Force a specific inner handler (overrides the auto-chain state file)
export WMUX_CODEX_INNER=/path/to/your/notify-hook.js
export WMUX_CODEX_INNER_INTERP=node   # optional; inferred from .js suffix
```

### Logging

```bash
export WMUX_LOG_FILE="$HOME/.wmux/wmux.log"   # default
export WMUX_LOG_MAX_BYTES=131072              # default; rotates to .1 above this
```

---

## Troubleshooting

### Toast doesn't appear in Warp

Walk this list top to bottom — it matches the order Wmux needs things to work.

| Check | Command | Fix |
|---|---|---|
| You're actually inside Warp | `echo $WARP_CLIENT_VERSION` should print a version | Reopen the shell from Warp |
| Hooks are wired | `grep -l wmux ~/.claude/settings.json ~/.codex/hooks.json ~/.codex/config.toml ~/.config/opencode/opencode.json` | Re-run `~/.wmux/install.sh` |
| Agent process was started **after** install | `pgrep -af '(^|/)(claude\|codex\|opencode\|gemini)'` and compare start time to `stat ~/.wmux/install.sh` | Restart the agent (see above) |
| tmux passthrough is on | `tmux show-options -g allow-passthrough` should print `allow-passthrough on` | Re-run the installer, or run `tmux set -g allow-passthrough on` and add it to `~/.tmux.conf` |
| Hook actually fires | `tail -f ~/.wmux/wmux.log` while you make the agent end a turn | If no log line appears: hook not wired or agent not restarted. If `emit=fail`: see next row. |
| OSC reached a real Warp TTY | Find the log line for your test event: `tty_src=` field | If `dev_tty_unreachable`: no Warp-attached TTY was found anywhere. Either run the agent inside a Warp-attached pane, or `tmux attach -t <session>` from Warp before triggering. |

### `emit=fail tty=/dev/tty err=... No such device`

You ran the smoke test from a piped subshell (`<<<` or `echo ... |`). That closes `/dev/tty`. Use the documented form:

```bash
~/.wmux/hooks/wmux-event.sh stop claude < /dev/tty
```

### Codex's previous notify handler stopped firing

The bridge auto-chains via `~/.wmux/state/codex-inner.argv`. If that file is missing or empty, the installer failed to parse your previous `notify = [...]` line. Restore it manually:

```bash
# Inspect what the installer captured
cat ~/.wmux/state/codex-inner.argv

# Or override via env var (one token per argv element, joined by spaces)
export WMUX_CODEX_INNER=/your/handler.js
export WMUX_CODEX_INNER_INTERP=node
```

### "Already-running agents detected" warning at install time

This is expected if you had any agent running before install. Restart those processes — the hooks only load at startup.

---

## Uninstall

```bash
~/.wmux/install.sh --uninstall
```

What it does:

1. Removes Wmux entries from every detected agent's config (Claude / Codex / OpenCode / Gemini).
2. Restores `~/.codex/config.toml`'s `notify = [...]` to the previous value (recorded at install time in `~/.wmux/state/previous-codex-notify.txt`).
3. Removes `~/.wmux/state/codex-inner.argv` (auto-chain state).
4. Leaves your other hooks alone.

Then delete the install dir:

```bash
rm -rf ~/.wmux
```

The `~/.tmux.conf` `allow-passthrough` line is **not** removed automatically — it's a generally useful setting and uninstall keeps it. Remove it manually if you want:

```bash
sed -i '/# Wmux: required so OSC 9/,+1d' ~/.tmux.conf
```

---

## How it works (one paragraph)

Each supported agent has a hook system that fires on lifecycle events (`SessionStart`, `Stop`, `PermissionRequest`, etc.). The installer wires those hooks to call `~/.wmux/wmux-event.sh`, which writes two escape sequences to a TTY: **OSC 777** (Warp's CLI Agent Protocol — adds a sidebar entry) and **OSC 9** (iTerm-style desktop toast — Warp shows it in the top-right). Codex CLI doesn't expose a `Stop` hook, so Wmux bridges through `~/.codex/config.toml`'s `notify` directive instead. To survive detached-tmux setups (e.g. OMX, tmuxinator), the hook walks fallbacks: `/dev/tty` → tmux pane TTY → attached tmux client TTY anywhere.

---

MIT — see [LICENSE](LICENSE). Issues and PRs welcome at [NomaDamas/warpalert](https://github.com/NomaDamas/warpalert).
