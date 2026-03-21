#!/usr/bin/env bash
# openclaw-fix.sh — Called by systemd OnFailure when Gateway repeatedly fails.
# Purpose:
#   - Collect recent gateway error context
#   - (Optionally) call Claude Code to propose a fix (config/files)
#   - Restart the gateway and verify it becomes active
#
# IMPORTANT:
#   - Do NOT hardcode API keys/tokens here.
#   - This script assumes a systemd *user* service: openclaw-gateway.service

set -euo pipefail

SERVICE_NAME="${OPENCLAW_GATEWAY_UNIT:-openclaw-gateway.service}"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

# Optional: Telegram notify (set to your own chat_id). Leave empty to disable.
TELEGRAM_TARGET="${OPENCLAW_FIX_TELEGRAM_TARGET:-}"

# Paths (adjust to your environment)
OPENCLAW_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$HOME/.openclaw/openclaw.json}"
LOG_DIR="${OPENCLAW_LOG_DIR:-/tmp/openclaw-1000}"
LOG_DATE="$(date -u +%Y-%m-%d)"
LOG_FILE="${LOG_DIR}/openclaw-${LOG_DATE}.log"

MAX_RETRIES="${OPENCLAW_FIX_MAX_RETRIES:-2}"
CLAUDE_TIMEOUT_SECS="${OPENCLAW_FIX_CLAUDE_TIMEOUT_SECS:-300}"

# Single-instance lock
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/openclaw-fix.lock"
exec 9>"$LOCK_FILE"
flock -n 9 || { echo "Another openclaw-fix is already running, exiting."; exit 0; }

notify() {
  local msg="$1"
  [[ -z "$TELEGRAM_TARGET" ]] && return 0
  openclaw message send --channel telegram --target "$TELEGRAM_TARGET" --message "$msg" 2>/dev/null || true
}

write_result() {
  local status="$1" message="$2"
  local out="${XDG_RUNTIME_DIR:-/tmp}/openclaw-fix-result.json"
  cat > "$out" <<EOF
{"status":"$status","message":"$message","timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
  echo "[openclaw-fix] result: $out"
}

find_claude() {
  local c
  c="$(command -v claude 2>/dev/null || true)"
  if [[ -n "$c" && -x "$c" ]]; then
    echo "$c"; return 0
  fi
  for candidate in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" /usr/local/bin/claude; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"; return 0
    fi
  done
  echo ""
}

collect_errors() {
  local errors=""
  if [[ -f "$LOG_FILE" ]]; then
    errors+=$(tail -80 "$LOG_FILE" 2>/dev/null | grep -i "error\|fatal\|invalid\|failed\|EADDRINUSE" | tail -20 || true)
  fi

  local journal
  journal=$(journalctl --user -u "$SERVICE_NAME" --no-pager -n 40 2>/dev/null || true)

  echo "=== tail(log) errors ==="
  echo "$errors"
  echo ""
  echo "=== journalctl ($SERVICE_NAME) ==="
  echo "$journal"
}

validate_config_json() {
  # Hard validation to avoid restarting into a broken config
  if [[ -f "$OPENCLAW_CONFIG_PATH" ]]; then
    python3 -m json.tool "$OPENCLAW_CONFIG_PATH" >/dev/null 2>&1
  fi
}

restart_and_check() {
  systemctl --user reset-failed "$SERVICE_NAME" 2>/dev/null || true
  systemctl --user restart "$SERVICE_NAME" 2>/dev/null || true
  sleep 8
  systemctl --user is-active "$SERVICE_NAME" >/dev/null 2>&1
}

# ---- Main ----
ERROR_CONTEXT="$(collect_errors)"

# If config JSON is invalid, surface it early
if [[ -f "$OPENCLAW_CONFIG_PATH" ]]; then
  if ! validate_config_json; then
    notify "🔴 Gateway config JSON invalid: $OPENCLAW_CONFIG_PATH (fix required)."
    write_result "invalid-config" "Invalid JSON: $OPENCLAW_CONFIG_PATH"
    exit 1
  fi
fi

CLAUDE_CODE="$(find_claude)"
if [[ -z "$CLAUDE_CODE" ]]; then
  notify "🔴 $SERVICE_NAME failed. Claude Code not found; cannot auto-fix."
  write_result "no-claude" "Claude Code not found"
  exit 1
fi

notify "🔧 $SERVICE_NAME failed. Attempting auto-fix via Claude Code…"

for attempt in $(seq 1 "$MAX_RETRIES"); do
  FIX_PROMPT="OpenClaw Gateway repeatedly failed. Fix the issue and verify.

Service: $SERVICE_NAME
Gateway port: $GATEWAY_PORT

Error context:
$ERROR_CONTEXT

Rules:
- Prefer minimal changes.
- Do NOT remove known-good baseline plugins unless clearly broken.
- After changes, verify JSON (if present): python3 -m json.tool $OPENCLAW_CONFIG_PATH > /dev/null
- Then restart systemd user service: systemctl --user restart $SERVICE_NAME

Show what you changed."

  fix_output=$(timeout "$CLAUDE_TIMEOUT_SECS" "$CLAUDE_CODE" -p "$FIX_PROMPT" \
    --allowedTools "Read,Write,Edit" \
    --max-turns 10 \
    2>&1 || echo "Claude Code failed or timed out")

  echo "[openclaw-fix] Attempt $attempt Claude output (tail):"
  echo "$fix_output" | tail -40

  # Validate config before restart
  if [[ -f "$OPENCLAW_CONFIG_PATH" ]]; then
    if ! validate_config_json; then
      notify "🔴 Auto-fix attempt $attempt produced invalid JSON: $OPENCLAW_CONFIG_PATH. Not restarting."
      continue
    fi
  fi

  if restart_and_check; then
    notify "✅ Gateway auto-fixed and restarted successfully (attempt $attempt)."
    write_result "ok" "Fixed on attempt $attempt"
    exit 0
  fi

  # Refresh error context for next loop
  ERROR_CONTEXT="$(collect_errors)"
done

notify "🔴 Gateway auto-fix failed after $MAX_RETRIES attempts. Manual intervention needed."
write_result "failed" "Failed after $MAX_RETRIES attempts"
exit 1
