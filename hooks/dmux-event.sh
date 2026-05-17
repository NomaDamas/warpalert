#!/bin/bash
# DMUX — Warp Terminal toasts when AI CLI agents finish a turn.
#
# Wraps the Warp CLI Agent Protocol (OSC 777 with title "warp://cli-agent")
# plus iTerm-style OSC 9 desktop notifications so the user sees both a
# sidebar entry and a system toast when an agent finishes a turn, asks for
# input, or goes idle.
#
# Designed to be wired into the hook system of any agent CLI:
#   - Claude Code   (~/.claude/settings.json hooks block)
#   - Codex CLI     (~/.codex/hooks.json)
#   - OpenCode      (~/.config/opencode/opencode.json hooks block)
#   - Gemini CLI    (~/.gemini/settings.json hooks block)
#   - any other agent that can exec a script on lifecycle events
#
# Usage: dmux-event.sh <event> [agent]
#   event ∈ {session_start | stop | permission_request | idle_prompt
#            | prompt_submit | tool_complete}
#   agent ∈ {claude | codex | gemini | opencode | amp | droid | copilot | ...}
#           default: codex
#
# The agent reads JSON from stdin (the standard Claude Code / Codex hook
# contract: session_id, transcript_path, tool_name, tool_input, prompt,
# message, stop_hook_active are all picked up if present).
#
# Protocol reference:
#   github.com/warpdotdev/warp/blob/main/app/src/terminal/\
#   cli_agent_sessions/event/v1.rs
#
# Behavior:
#   • Writes OSC 777 + OSC 9 to /dev/tty (silent on failure)
#   • stdout/stderr stay empty (most agent CLIs parse hook stdout as control)
#   • Debug log at $DMUX_LOG_FILE (rotates at 1 MB)
#
# Silently no-ops (still logs the reason) when:
#   • Not running in Warp (WARP_CLI_AGENT_PROTOCOL_VERSION or
#     WARP_CLIENT_VERSION env var unset)
#   • Stdin payload has stop_hook_active=true (re-entrant stop hook)
#   • Event is "stop" and DMUX_SUPPRESS_STOP=1 (or any OMX_TEAM_*
#     env var is set — loop-suppression for oh-my-codex team mode)
#   • The event name isn't in the v1 recognized set

set -u
exec 2>/dev/null

PLUGIN_VERSION="0.3.0"
PLUGIN_PROTO_V=1

DMUX_LOG_FILE="${DMUX_LOG_FILE:-$HOME/.dmux/dmux.log}"
DMUX_LOG_MAX_BYTES="${DMUX_LOG_MAX_BYTES:-1048576}"
DMUX_LOG_LOCK="${DMUX_LOG_FILE}.lock"

mkdir -p "$(dirname "$DMUX_LOG_FILE")" 2>/dev/null

EVENT="${1:-}"
AGENT="${2:-codex}"

HOOK_INPUT="$(cat 2>/dev/null || true)"

_log_line() {
    local dir="${DMUX_LOG_FILE%/*}"
    [ -d "$dir" ] || return 0
    local line
    line="$(printf '[%s] agent=%s event=%s %s' \
        "$(date '+%H:%M:%S')" "$AGENT" "${EVENT:-<none>}" "$*")"
    if command -v flock >/dev/null 2>&1; then
        (
            flock -w 1 9 || exit 0
            if [ -f "$DMUX_LOG_FILE" ]; then
                local sz
                sz=$(wc -c <"$DMUX_LOG_FILE" 2>/dev/null || echo 0)
                if [ "${sz:-0}" -gt "$DMUX_LOG_MAX_BYTES" ] 2>/dev/null; then
                    mv -f "$DMUX_LOG_FILE" "${DMUX_LOG_FILE}.1" 2>/dev/null || true
                fi
            fi
            printf '%s\n' "$line" >>"$DMUX_LOG_FILE" 2>/dev/null || true
        ) 9>"$DMUX_LOG_LOCK"
    else
        printf '%s\n' "$line" >>"$DMUX_LOG_FILE" 2>/dev/null || true
    fi
}

_json_get() {
    local field="$1" input="$2"
    [ -z "$input" ] && return 0
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$input" | jq -r --arg f "$field" '
            (.[$f]) |
            if . == null then empty
            elif type == "boolean" then if . then "true" else "false" end
            elif type == "object" or type == "array" then tojson
            else tostring end
        ' 2>/dev/null
    else
        FIELD="$field" INPUT="$input" python3 - <<'PY' 2>/dev/null
import json, os, sys
try:
    d = json.loads(os.environ.get('INPUT', ''))
    if not isinstance(d, dict): sys.exit(0)
    v = d.get(os.environ['FIELD'])
    if v is None: sys.exit(0)
    if isinstance(v, bool):  sys.stdout.write('true' if v else 'false')
    elif isinstance(v, (str, int, float)): sys.stdout.write(str(v))
    else: sys.stdout.write(json.dumps(v, separators=(',', ':')))
except Exception:
    pass
PY
    fi
}

_truncate() {
    local s="$1"
    if [ "${#s}" -gt 200 ]; then
        printf '%s...' "${s:0:197}"
    else
        printf '%s' "$s"
    fi
}

case "$EVENT" in
    session_start|stop|permission_request|idle_prompt|prompt_submit|tool_complete) ;;
    *)
        _log_line "skip=invalid_event"
        exit 0
        ;;
esac

if [ -z "${WARP_CLI_AGENT_PROTOCOL_VERSION:-}" ] || \
   [ -z "${WARP_CLIENT_VERSION:-}" ]; then
    _log_line "skip=not_warp"
    exit 0
fi

if [ "$EVENT" = "stop" ] && [ -n "$HOOK_INPUT" ]; then
    if [ "$(_json_get stop_hook_active "$HOOK_INPUT")" = "true" ]; then
        _log_line "skip=stop_hook_active"
        exit 0
    fi
fi

# Loop-suppression for orchestrated team modes (e.g. oh-my-codex team mode
# loops the leader's stop hook 20-50× per task; sending each to Warp = flood).
# Generic override: set DMUX_SUPPRESS_STOP=1 from any loop runner.
if [ "$EVENT" = "stop" ]; then
    if [ "${DMUX_SUPPRESS_STOP:-}" = "1" ] || \
       [ -n "${OMX_TEAM_WORKER:-}" ] || \
       [ -n "${OMX_TEAM_INTERNAL_WORKER:-}" ] || \
       [ -n "${OMX_TEAM_STATE_ROOT:-}" ] || \
       [ -n "${OMX_TEAM_LEADER_CWD:-}" ]; then
        _log_line "skip=team_mode_stop worker='${OMX_TEAM_WORKER:-}' state_root='${OMX_TEAM_STATE_ROOT:-}'"
        exit 0
    fi
fi

WARP_PROTO_V="${WARP_CLI_AGENT_PROTOCOL_VERSION:-1}"
if [ "$WARP_PROTO_V" -lt "$PLUGIN_PROTO_V" ] 2>/dev/null; then
    PROTO_V="$WARP_PROTO_V"
else
    PROTO_V="$PLUGIN_PROTO_V"
fi

SESSION_ID=""
[ -n "$HOOK_INPUT" ] && SESSION_ID="$(_json_get session_id "$HOOK_INPUT")"

CWD="$PWD"
PROJECT="$(basename "$CWD")"
[ -z "$PROJECT" ] && PROJECT="home"

QUERY=""
RESPONSE=""
TRANSCRIPT_PATH=""
SUMMARY=""
TOOL_NAME=""
TOOL_INPUT_JSON=""

case "$EVENT" in
    stop)
        TRANSCRIPT_PATH="$(_json_get transcript_path "$HOOK_INPUT")"
        # Best-effort transcript extraction using Claude Code's JSONL format.
        # Codex/Gemini transcripts have different shapes — the query returns
        # empty for those and we just omit query/response from the payload.
        if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ] && \
           command -v jq >/dev/null 2>&1; then
            sleep 0.3
            QUERY="$(jq -rs '
                [ .[] | select(.type == "user") |
                  if .message.content | type == "string" then .
                  elif [.message.content[]? | select(.type == "text")] | length > 0 then .
                  else empty end
                ] | last |
                if (.message.content // null) | type == "array"
                  then [.message.content[] | select(.type == "text") | .text] | join(" ")
                  else (.message.content // "") end
            ' "$TRANSCRIPT_PATH" 2>/dev/null)"
            RESPONSE="$(jq -rs '
                [ .[] | select(.type == "assistant" and (.message.content // null)) ] | last |
                [ .message.content[]? | select(.type == "text") | .text ] | join(" ")
            ' "$TRANSCRIPT_PATH" 2>/dev/null)"
            QUERY="$(_truncate "$QUERY")"
            RESPONSE="$(_truncate "$RESPONSE")"
        fi
        ;;
    permission_request)
        TOOL_NAME="$(_json_get tool_name "$HOOK_INPUT")"
        [ -z "$TOOL_NAME" ] && TOOL_NAME="unknown"
        TOOL_INPUT_JSON="$(_json_get tool_input "$HOOK_INPUT")"
        case "${TOOL_INPUT_JSON:0:1}" in
            '{'|'['|'"') : ;;
            *)         TOOL_INPUT_JSON='{}' ;;
        esac
        PREVIEW="$(_json_get command "$TOOL_INPUT_JSON")"
        [ -z "$PREVIEW" ] && PREVIEW="$(_json_get file_path "$TOOL_INPUT_JSON")"
        if [ -n "$PREVIEW" ]; then
            SUMMARY="$(_truncate "Wants to run $TOOL_NAME: $PREVIEW")"
        else
            SUMMARY="$(_truncate "Wants to run $TOOL_NAME")"
        fi
        ;;
    idle_prompt)
        SUMMARY="$(_json_get message "$HOOK_INPUT")"
        [ -z "$SUMMARY" ] && SUMMARY="Input needed"
        SUMMARY="$(_truncate "$SUMMARY")"
        ;;
    prompt_submit)
        QUERY="$(_json_get prompt "$HOOK_INPUT")"
        QUERY="$(_truncate "$QUERY")"
        ;;
    tool_complete)
        TOOL_NAME="$(_json_get tool_name "$HOOK_INPUT")"
        ;;
    session_start)
        :
        ;;
esac

if command -v jq >/dev/null 2>&1; then
    JSON="$(jq -nc \
        --argjson v "$PROTO_V" \
        --arg agent "$AGENT" \
        --arg event "$EVENT" \
        --arg session_id "$SESSION_ID" \
        --arg cwd "$CWD" \
        --arg project "$PROJECT" \
        --arg plugin_version "$PLUGIN_VERSION" \
        --arg query "$QUERY" \
        --arg response "$RESPONSE" \
        --arg transcript_path "$TRANSCRIPT_PATH" \
        --arg summary "$SUMMARY" \
        --arg tool_name "$TOOL_NAME" \
        --argjson tool_input "${TOOL_INPUT_JSON:-null}" \
        '{v:$v, agent:$agent, event:$event, session_id:$session_id, cwd:$cwd, project:$project}
         + (if $event == "session_start" then {plugin_version:$plugin_version} else {} end)
         + (if $query != ""           then {query:$query}                       else {} end)
         + (if $response != ""        then {response:$response}                 else {} end)
         + (if $transcript_path != "" then {transcript_path:$transcript_path}   else {} end)
         + (if $summary != ""         then {summary:$summary}                   else {} end)
         + (if $tool_name != ""       then {tool_name:$tool_name}               else {} end)
         + (if $tool_input != null    then {tool_input:$tool_input}             else {} end)
        ' 2>/dev/null)"
else
    JSON="$(
        PROTO_V="$PROTO_V" AGENT="$AGENT" EVENT="$EVENT" \
        SESSION_ID="$SESSION_ID" CWD="$CWD" PROJECT="$PROJECT" \
        PLUGIN_VERSION="$PLUGIN_VERSION" \
        QUERY="$QUERY" RESPONSE="$RESPONSE" TRANSCRIPT_PATH="$TRANSCRIPT_PATH" \
        SUMMARY="$SUMMARY" TOOL_NAME="$TOOL_NAME" TOOL_INPUT_JSON="$TOOL_INPUT_JSON" \
        python3 - <<'PY' 2>/dev/null
import json, os, sys
out = {
    "v": int(os.environ.get("PROTO_V", "1") or "1"),
    "agent":      os.environ.get("AGENT", ""),
    "event":      os.environ.get("EVENT", ""),
    "session_id": os.environ.get("SESSION_ID", ""),
    "cwd":        os.environ.get("CWD", ""),
    "project":    os.environ.get("PROJECT", ""),
}
if out["event"] == "session_start":
    pv = os.environ.get("PLUGIN_VERSION", "")
    if pv: out["plugin_version"] = pv
for k in ("query", "response", "transcript_path", "summary", "tool_name"):
    v = os.environ.get(k.upper(), "")
    if v: out[k] = v
ti = os.environ.get("TOOL_INPUT_JSON", "")
if ti:
    try:
        parsed = json.loads(ti)
        out["tool_input"] = parsed
    except Exception:
        pass
sys.stdout.write(json.dumps(out, separators=(",", ":"), ensure_ascii=False))
PY
    )"
fi

if [ -z "$JSON" ]; then
    _log_line "skip=json_build_failed"
    exit 0
fi

# Resolve a TTY the user is actually looking at. The original logic only
# considered /dev/tty and the current pane's TTY, both of which can point at
# a detached tmux pane (e.g. agents launched inside `tmux new-session -d` by
# orchestration layers like OMX). When no client is attached to that pane,
# OSC sequences die in the void. Walk through fallbacks in priority order:
#   1. /dev/tty (interactive caller)
#   2. $TMUX_PANE's pane_tty (the agent's own pane)
#   3. any client TTY currently attached to the agent's tmux session
#   4. any client TTY currently attached to any tmux session
# Anything that's writable wins.
OUT_TTY="/dev/tty"
OUT_TTY_SOURCE="dev_tty"
_try_tty() {
    local candidate="$1" label="$2"
    [ -n "$candidate" ] || return 1
    [ -w "$candidate" ] || return 1
    OUT_TTY="$candidate"
    OUT_TTY_SOURCE="$label"
    return 0
}
if ! { : >/dev/tty; } 2>/dev/null; then
    OUT_TTY=""
    if [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
        _FB="$(tmux display-message -p -t "$TMUX_PANE" '#{pane_tty}' 2>/dev/null)"
        _try_tty "$_FB" pane_tty || true
    fi
    if [ -z "$OUT_TTY" ] && command -v tmux >/dev/null 2>&1; then
        _SESS=""
        if [ -n "${TMUX_PANE:-}" ]; then
            _SESS="$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)"
        fi
        if [ -n "$_SESS" ]; then
            while IFS= read -r _CT; do
                _try_tty "$_CT" session_client && break
            done < <(tmux list-clients -t "$_SESS" -F '#{client_tty}' 2>/dev/null)
        fi
    fi
    if [ -z "$OUT_TTY" ] && command -v tmux >/dev/null 2>&1; then
        while IFS= read -r _CT; do
            _try_tty "$_CT" any_client && break
        done < <(tmux list-clients -F '#{client_tty}' 2>/dev/null)
    fi
    if [ -z "$OUT_TTY" ]; then
        OUT_TTY="/dev/tty"
        OUT_TTY_SOURCE="dev_tty_unreachable"
    fi
fi

ESC=$'\033'
BEL=$'\007'
ST=$'\033\\'

wrap_for_tmux() {
    local seq="$1"
    # Writing directly to an attached client's TTY bypasses tmux entirely,
    # so we must NOT add the tmux passthrough wrapper in that case — Warp
    # would see literal `\ePtmux;...` bytes instead of an OSC sequence.
    case "$OUT_TTY_SOURCE" in
        session_client|any_client)
            printf '%s' "$seq"
            return
            ;;
    esac
    if [ -n "${TMUX:-}" ]; then
        local doubled="${seq//$ESC/$ESC$ESC}"
        printf '%sPtmux;%s%s' "$ESC" "$doubled" "$ST"
    else
        printf '%s' "$seq"
    fi
}

WRITE_ERR=""
emit_to_tty() {
    local payload="$1"
    { printf '%s' "$payload" > "$OUT_TTY"; } 2>/tmp/.dmux-write-err.$$
    local rc=$?
    if [ -s /tmp/.dmux-write-err.$$ ]; then
        WRITE_ERR="$(head -1 /tmp/.dmux-write-err.$$)"
    fi
    rm -f /tmp/.dmux-write-err.$$
    return $rc
}

OSC777="${ESC}]777;notify;warp://cli-agent;${JSON}${BEL}"
emit_to_tty "$(wrap_for_tmux "$OSC777")"

# OSC 9 desktop toast bodies. Customizable via env vars; substitute {project}
# and {agent} placeholders.
# bash's ${VAR:-default} terminates at the first '}' in the default value,
# so an inline default that contains '{project}' gets parsed as '{project'
# plus a literal tail, which then breaks {project} substitution downstream.
# Use a -z guard instead so braces inside the default stay intact.
[ -z "${DMUX_TOAST_STOP:-}" ]       && DMUX_TOAST_STOP='✅ {project} — {agent} done'
[ -z "${DMUX_TOAST_PERMISSION:-}" ] && DMUX_TOAST_PERMISSION='⚠️ {project} — {agent} needs input'
[ -z "${DMUX_TOAST_IDLE:-}" ]       && DMUX_TOAST_IDLE='💬 {project} — {agent} waiting'
TOAST_STOP_TEMPLATE="$DMUX_TOAST_STOP"
TOAST_PERMISSION_TEMPLATE="$DMUX_TOAST_PERMISSION"
TOAST_IDLE_TEMPLATE="$DMUX_TOAST_IDLE"

_render_toast() {
    local tpl="$1"
    tpl="${tpl//\{project\}/$PROJECT}"
    tpl="${tpl//\{agent\}/$AGENT}"
    printf '%s' "$tpl"
}

case "$EVENT" in
    stop)               OSC9_BODY="$(_render_toast "$TOAST_STOP_TEMPLATE")" ;;
    permission_request) OSC9_BODY="$(_render_toast "$TOAST_PERMISSION_TEMPLATE")" ;;
    idle_prompt)        OSC9_BODY="$(_render_toast "$TOAST_IDLE_TEMPLATE")" ;;
    *)                  OSC9_BODY="" ;;
esac

if [ -n "$OSC9_BODY" ]; then
    OSC9="${ESC}]9;${OSC9_BODY}${BEL}"
    emit_to_tty "$(wrap_for_tmux "$OSC9")"
fi

if [ -n "$WRITE_ERR" ]; then
    _log_line "emit=fail tty=$OUT_TTY tmux=${TMUX:+y} tmux_pane=${TMUX_PANE:-<unset>} err=${WRITE_ERR:0:100}"
else
    _log_line "emit=ok proto=$PROTO_V tty=$OUT_TTY tty_src=$OUT_TTY_SOURCE tmux=${TMUX:+y} tmux_pane=${TMUX_PANE:-<unset>} session_id=${SESSION_ID:-<none>} cwd=$CWD osc9='${OSC9_BODY:-<none>}'"
fi
exit 0
