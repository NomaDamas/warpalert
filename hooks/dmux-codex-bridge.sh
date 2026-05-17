#!/bin/bash
# Codex `notify` bridge — fire Warp Terminal toasts on Codex agent turns.
#
# Codex CLI does NOT expose a "stop" event in its hooks.json system. The only
# way to detect "Codex turn finished" is the `notify` directive in
# ~/.codex/config.toml, which calls a user-supplied command after every
# agent turn with the event JSON as the LAST argv argument.
#
# This bridge sits in that slot. It dispatches the payload to:
#   1. The user's existing `notify` handler (e.g. oh-my-codex's notify-hook.js)
#      — synchronously, because state-bearing handlers must finish before the
#      next turn begins.
#   2. dmux-event.sh — fire-and-forget, so a Warp glitch never blocks
#      the codex turn loop.
#
# Wire it into ~/.codex/config.toml like:
#   notify = ["/path/to/DMUX/hooks/dmux-codex-bridge.sh"]
#
# If the user wants the bridge to chain to a previous notify handler, set:
#   DMUX_CODEX_INNER=/path/to/previous/notify-script.js
# and (optionally) DMUX_CODEX_INNER_INTERP=node
# (defaults to node when the inner path ends with .js, otherwise direct exec).

set -u
exec 2>/dev/null

WARP_HOOK="${DMUX_HOOK:-$HOME/.dmux/dmux-event.sh}"
if [ ! -x "$WARP_HOOK" ]; then
    ALT="$(dirname "$(readlink -f "$0")")/dmux-event.sh"
    if [ -x "$ALT" ]; then
        WARP_HOOK="$ALT"
    fi
fi

INNER_HOOK="${DMUX_CODEX_INNER:-}"
INNER_INTERP="${DMUX_CODEX_INNER_INTERP:-}"
INNER_ARGV_FILE="${DMUX_CODEX_INNER_ARGV_FILE:-$HOME/.dmux/state/codex-inner.argv}"

PAYLOAD="${!#}"

INNER_PID=""
if [ -n "$INNER_HOOK" ] && [ -f "$INNER_HOOK" ]; then
    # Back-compat path: explicit single-file inner handler via env var.
    if [ -z "$INNER_INTERP" ] && [ "${INNER_HOOK##*.}" = "js" ]; then
        INNER_INTERP="node"
    fi
    if [ -n "$INNER_INTERP" ]; then
        "$INNER_INTERP" "$INNER_HOOK" "$@" &
    else
        "$INNER_HOOK" "$@" &
    fi
    INNER_PID=$!
elif [ -s "$INNER_ARGV_FILE" ]; then
    # Auto-chain: installer persisted the previous notify argv tokens here,
    # so users don't have to export DMUX_CODEX_INNER themselves.
    INNER_ARGV=()
    while IFS= read -r _line || [ -n "$_line" ]; do
        [ -z "$_line" ] && continue
        INNER_ARGV+=("$_line")
    done < "$INNER_ARGV_FILE"
    if [ "${#INNER_ARGV[@]}" -gt 0 ]; then
        "${INNER_ARGV[@]}" "$@" &
        INNER_PID=$!
    fi
fi

{
    EVENT="stop"
    if command -v jq >/dev/null 2>&1; then
        TYPE="$(printf '%s' "$PAYLOAD" | jq -r '.type // empty' 2>/dev/null || true)"
        case "$TYPE" in
            agent-turn-complete) EVENT="stop" ;;
            ask-user-question)   EVENT="permission_request" ;;
            session-end)         EVENT="stop" ;;
            session-idle)        EVENT="idle_prompt" ;;
            session-start)       EVENT="session_start" ;;
        esac
    fi
    if [ -x "$WARP_HOOK" ]; then
        printf '%s' "$PAYLOAD" | "$WARP_HOOK" "$EVENT" codex
    fi
} &

if [ -n "$INNER_PID" ]; then
    wait "$INNER_PID"
fi
exit 0
