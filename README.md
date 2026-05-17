# DMUX

🔔 **Warp Terminal toasts when your AI agent finishes.**

Works with **Claude Code**, **Codex CLI**, **OpenCode**, and **Gemini CLI**.

When the agent finishes a turn, asks for input, or goes idle — you get a real OS notification in Warp's top-right corner.

|   |   |
|---|---|
| ✅ | `project — claude done` |
| ⚠️ | `project — codex needs input` |
| 💬 | `project — gemini waiting` |

---

## Install (one command)

```bash
git clone https://github.com/HaD0Yun/DMUX.git ~/.dmux && ~/.dmux/install.sh
```

The installer detects which agents you have installed, asks once, and wires everything for you. Existing hooks in your config files are preserved.

Restart your agent sessions after install. Done.

---

## Uninstall

```bash
~/.dmux/install.sh --uninstall
```

Removes only the DMUX entries; your other hooks stay.

---

## Requirements

- Warp Terminal (any recent build).
- `bash`, `jq` (recommended).
- `tmux ≥ 3.3` if you run agents inside tmux. The installer will add
  `set -g allow-passthrough on` to your `~/.tmux.conf` for you — this is
  required so OSC 9 / OSC 777 toast sequences pass through tmux to Warp.

If you already had agents running before installing, **restart them**
afterwards. Hooks load at agent startup; existing sessions won't fire toasts
until they restart. The installer will warn when it sees a pre-existing
agent process.

### Smoke test

```bash
# must run from a real terminal (not via a piped subshell)
~/.dmux/hooks/dmux-event.sh stop claude < /dev/tty
tail -1 ~/.dmux/dmux.log
```

You should see `emit=ok` in the log line and a toast in Warp's top-right.
If the log shows `emit=fail tty=/dev/tty err=... No such device`, you're
invoking the hook from a non-TTY context — use the form above.

MIT — see [LICENSE](LICENSE).
