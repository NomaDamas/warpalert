#!/bin/bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SRC="$SCRIPT_DIR/hooks/warp-agent-event.sh"
BRIDGE_SRC="$SCRIPT_DIR/hooks/codex-notify-bridge.sh"

if [ ! -x "$HOOK_SRC" ]; then
    chmod +x "$HOOK_SRC" "$BRIDGE_SRC"
fi

echo
echo "warp-agent-hooks installer"
echo "──────────────────────────"
echo "  source dir : $SCRIPT_DIR"
echo "  main hook  : $HOOK_SRC"
echo "  codex bridge: $BRIDGE_SRC"
echo

if ! command -v jq >/dev/null 2>&1; then
    echo "WARNING: 'jq' is not installed — script will fall back to python3."
    echo "         Install jq for ~3x faster JSON building (apt: jq, brew: jq)."
    echo
fi

if [ -z "${WARP_CLI_AGENT_PROTOCOL_VERSION:-}" ] || [ -z "${WARP_CLIENT_VERSION:-}" ]; then
    echo "WARNING: WARP_CLI_AGENT_PROTOCOL_VERSION / WARP_CLIENT_VERSION are not set."
    echo "         The hook will silently no-op outside Warp Terminal. That's fine"
    echo "         if you only run agent CLIs inside Warp; just be aware."
    echo
fi

cat <<'EOF'
Paste the snippets below into your agent config files.
The installer does NOT auto-edit them; you stay in control.

══════════════════════════════════════════════════════════════════════════════
Claude Code  →  ~/.claude/settings.json
══════════════════════════════════════════════════════════════════════════════
EOF

cat "$SCRIPT_DIR/examples/claude-settings-hooks.json"

cat <<'EOF'

> If you also have the official warpdotdev/claude-code-warp plugin enabled,
> SKIP the Claude wiring above — that plugin already handles Claude (just
> not Codex / Gemini / OpenCode). Use this repo for the other agents only.

══════════════════════════════════════════════════════════════════════════════
Codex CLI  →  ~/.codex/hooks.json
══════════════════════════════════════════════════════════════════════════════
EOF

cat "$SCRIPT_DIR/examples/codex-hooks.json"

cat <<'EOF'

══════════════════════════════════════════════════════════════════════════════
Codex CLI  →  ~/.codex/config.toml  (top-level notify directive)
══════════════════════════════════════════════════════════════════════════════
EOF

cat "$SCRIPT_DIR/examples/codex-config-notify.toml"

cat <<'EOF'

══════════════════════════════════════════════════════════════════════════════
OpenCode  →  ~/.config/opencode/opencode.json  (hooks block)
══════════════════════════════════════════════════════════════════════════════
EOF

cat "$SCRIPT_DIR/examples/opencode-hooks.json"

cat <<'EOF'

══════════════════════════════════════════════════════════════════════════════
Gemini CLI  →  ~/.gemini/settings.json  (hooks block)
══════════════════════════════════════════════════════════════════════════════
EOF

cat "$SCRIPT_DIR/examples/gemini-settings-hooks.json"

cat <<EOF

Smoke test (works without restarting any agent):

  WARP_CLI_AGENT_PROTOCOL_VERSION=1 \\
  WARP_CLIENT_VERSION=v0.2026.04.29.test \\
  $HOOK_SRC stop codex <<< '{"session_id":"manual-test"}'

  tail -1 \$HOME/.warp-agent-hooks/warp-agent-event.log

You should see 'emit=ok' in the log and a toast in Warp's top-right corner.

Done. Restart your agent CLI sessions to pick up the new wiring.
EOF
