#!/usr/bin/env bash
# docent-notify.sh -- Cursor hook that reports session activity to docent running
# on the workstation, reaching it through the reverse SSH tunnel
# (127.0.0.1:<port> on the dev box -> docent on the workstation).
#
# Wire it into ~/.cursor/hooks.json for the events docent cares about:
#   stop                -> agent-stop   (a turn finished -> maybe needs follow-up)
#   sessionStart        -> session-start (also reads the exact title-bar color)
#   sessionEnd          -> session-end
#   afterShellExecution -> shell-done   (a long shell command finished)
#
# The docent event "kind" is taken from the first argument when present (e.g.
# `docent-notify.sh agent-stop`), otherwise mapped from the stdin
# `hook_event_name`. Fire-and-forget: this script ALWAYS exits 0 with a short
# timeout, so a down tunnel or stopped docent never blocks Cursor.
set -u

input="$(cat 2>/dev/null || true)"

have_jq=1
command -v jq >/dev/null 2>&1 || have_jq=0

json_get() {
  # json_get <jq-filter> ; echoes the value or empty string.
  [ "$have_jq" -eq 1 ] || { echo ""; return; }
  printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null
}

# Resolve docent kind: explicit $1 wins, else map the Cursor event name.
kind="${1:-}"
if [ -z "$kind" ]; then
  event="$(json_get '.hook_event_name')"
  case "$event" in
    stop)                kind="agent-stop" ;;
    afterShellExecution) kind="shell-done" ;;
    sessionStart)        kind="session-start" ;;
    sessionEnd)          kind="session-end" ;;
    *)                   kind="" ;;
  esac
fi
[ -z "$kind" ] && exit 0

# Worktree root -> session name (its leaf).
root="$(json_get '.workspace_roots[0]')"
[ -z "$root" ] && root="$(json_get '.projectPath')"
[ -z "$root" ] && root="${CURSOR_PROJECT_DIR:-}"
[ -z "$root" ] && exit 0
name="$(basename "$root")"

convo="$(json_get '.conversation_id')"
[ -z "$convo" ] && convo="$(json_get '.session_id')"

# Remote SSH host (best-effort; docent also derives its own from the title).
host="${CURSOR_REMOTE_SSH_HOST:-}"
[ -z "$host" ] && host="$(hostname 2>/dev/null || true)"

# Exact title-bar color, read on session start from the worktree settings. This
# guarantees the dashboard swatch matches Cursor's title bar (grove writes it).
color=""
if [ "$kind" = "session-start" ] && [ "$have_jq" -eq 1 ]; then
  settings="$root/.vscode/settings.json"
  if [ -f "$settings" ]; then
    color="$(jq -r '."workbench.colorCustomizations"."titleBar.activeBackground" // empty' "$settings" 2>/dev/null)"
  fi
fi

# Shared-secret token: a mode-600 file dropped by `docent install-hooks`, or the
# DOCENT_TOKEN env var.
token="${DOCENT_TOKEN:-}"
if [ -z "$token" ] && [ -f "$HOME/.cursor/docent-token" ]; then
  # tr strips any stray CR/LF so it can never corrupt the Authorization header.
  token="$(tr -d '\r\n' < "$HOME/.cursor/docent-token" 2>/dev/null || true)"
fi

port="${DOCENT_PORT:-39787}"
url="http://127.0.0.1:${port}/event"

# Build the JSON payload (jq when available, else a hand-rolled object).
if [ "$have_jq" -eq 1 ]; then
  payload="$(jq -nc \
    --arg name "$name" \
    --arg kind "$kind" \
    --arg host "$host" \
    --arg path "$root" \
    --arg convo "$convo" \
    --arg color "$color" \
    '{name:$name, kind:$kind, host:$host, path:$path}
     + (if $convo != "" then {conversationId:$convo} else {} end)
     + (if $color != "" then {color:$color} else {} end)')"
else
  payload="{\"name\":\"${name}\",\"kind\":\"${kind}\",\"host\":\"${host}\",\"path\":\"${root}\"}"
fi

if [ -n "$token" ]; then
  curl -s --max-time 2 -X POST "$url" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${token}" \
    --data "$payload" >/dev/null 2>&1 || true
else
  curl -s --max-time 2 -X POST "$url" \
    -H 'Content-Type: application/json' \
    --data "$payload" >/dev/null 2>&1 || true
fi

exit 0
