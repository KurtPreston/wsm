#!/usr/bin/env bash
# docent-verify.sh -- THROWAWAY diagnostic hook. Wire it into one Cursor event on
# the dev box to confirm (a) hooks run on the remote machine and (b) the stdin
# payload / environment docent relies on. It only appends to a log; it never
# talks to docent. Remove it once verified.
#
# Example ~/.cursor/hooks.json entry:
#   "stop": [ { "command": "./hooks/docent-verify.sh", "timeout": 5 } ]
set -u

log="${DOCENT_VERIFY_LOG:-/tmp/docent-hook-verify.log}"
input="$(cat 2>/dev/null || true)"

{
  echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "hostname:           $(hostname 2>/dev/null)"
  echo "pwd:                $(pwd)"
  echo "CURSOR_CODE_REMOTE: ${CURSOR_CODE_REMOTE:-<unset>}"
  echo "CURSOR_PROJECT_DIR: ${CURSOR_PROJECT_DIR:-<unset>}"
  echo "CURSOR_REMOTE_SSH_HOST: ${CURSOR_REMOTE_SSH_HOST:-<unset>}"
  if command -v jq >/dev/null 2>&1; then
    echo "hook_event_name:    $(printf '%s' "$input" | jq -r '.hook_event_name // "<none>"' 2>/dev/null)"
    echo "conversation_id:    $(printf '%s' "$input" | jq -r '.conversation_id // "<none>"' 2>/dev/null)"
    echo "workspace_roots:    $(printf '%s' "$input" | jq -c '.workspace_roots // "<none>"' 2>/dev/null)"
  else
    echo "stdin (raw):        $input"
  fi
} >> "$log" 2>&1

exit 0
