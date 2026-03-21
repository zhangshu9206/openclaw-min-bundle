#!/usr/bin/env bash
# safe-gateway-restart.sh — Restart OpenClaw gateway with optional Claude Code auto-fix.
# Usage:
#   ./safe-gateway-restart.sh [reason]

set -euo pipefail

REASON="${1:-manual restart}"
MAX_RETRIES="${SAFE_RESTART_MAX_RETRIES:-2}"
SERVICE_NAME="${OPENCLAW_GATEWAY_UNIT:-openclaw-gateway.service}"
LOG_FILE="${OPENCLAW_LOG_FILE:-/tmp/openclaw/openclaw-$(date -u +%Y-%m-%d).log}"

# Optional: Telegram notify (set to your own chat_id). Leave empty to disable.
TELEGRAM_TARGET="${SAFE_RESTART_TELEGRAM_TARGET:-}"

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

notify() {
  local msg="$1"
  echo "[$(date -u +%H:%M:%S)] message send (TG_ID: $TELEGRAM_TARGET): $msg"
  [[ -z "$TELEGRAM_TARGET" ]] && return 0
  openclaw message send --channel telegram --target "$TELEGRAM_TARGET" --message "$msg" 2>/dev/null || true
}

check_gateway_errors() {
  local errors=""

  # 错误模式：配置错误、插件错误、网络/端口错误、权限错误
  local error_pattern="invalid config|Runtime: unknown|config validation failed|plugin.*not found|error.*plugin|address already in use|port.*in use|connection.*refused|connection.*timeout|permission denied|access denied|certificate.*error|key.*not found|failed to bind|socket.*error"

  if [[ -f "$LOG_FILE" ]]; then
    errors=$(tail -60 "$LOG_FILE" | grep -iE "$error_pattern" | tail -10 || true)
  fi

  # Also check CLI status output
  local status_output
  status_output=$(openclaw gateway status 2>&1 || true)
  if echo "$status_output" | grep -qiE "$error_pattern"; then
    errors="$errors
$status_output"
  fi

  echo "$errors"
}

do_restart() {
  echo "[$(date -u +%H:%M:%S)] Restarting gateway (reason: $REASON)…"
  systemctl --user restart "$SERVICE_NAME" 2>&1 || openclaw gateway restart 2>&1 || true
  echo "[$(date -u +%H:%M:%S)] Waiting 6s for gateway to stabilize…"
  sleep 6
}

CLAUDE_CODE="$(find_claude)"
CLAUDE_TIMEOUT="${SAFE_RESTART_CLAUDE_TIMEOUT_SECS:-300}"
OPENCLAW_VERSION="$(openclaw --version 2>&1 || echo 'unknown')"

echo "=== Safe Gateway Restart ==="
echo "Service: $SERVICE_NAME"
echo "Reason: $REASON"
echo "Claude: ${CLAUDE_CODE:-NOT FOUND}"
echo "Version: $OPENCLAW_VERSION"
echo "LOG_FILE: $LOG_FILE"
echo "TG_ID: $TELEGRAM_TARGET"
echo

for attempt in $(seq 1 $((MAX_RETRIES + 1))); do
  echo "--- Attempt $attempt ---"
  do_restart

  errors="$(check_gateway_errors)"

  if [[ -z "$errors" || "$errors" =~ ^[[:space:]]*$ ]]; then
    echo "[$(date -u +%H:%M:%S)] ✅ Gateway restarted successfully (attempt $attempt)"
    notify " ✅ Gateway restarted successfully"
    exit 0
  fi

  echo "[$(date -u +%H:%M:%S)] ❌ Errors detected:"
  echo "$errors"

  if [[ $attempt -gt $MAX_RETRIES ]]; then
    notify "🔴 Gateway restart failed after $MAX_RETRIES fix attempts. Errors: $(echo "$errors" | head -3)"
    exit 1
  fi

  if [[ -z "$CLAUDE_CODE" ]]; then
    notify "🔴 Gateway restart failed and Claude Code not available. Errors: $(echo "$errors" | head -3)"
    exit 1
  fi

  FIX_PROMPT="OpenClaw gateway restart failed with these errors:

$errors

Fix the issue. Common causes:
- Invalid JSON in ~/.openclaw/openclaw.json
- OpenClaw Version: $OPENCLAW_VERSION
- 删除无效的 JSON成员 in ~/.openclaw/openclaw.json
- Broken plugin references in plugins.load.paths

Rules:
- Prefer minimal changes.
- After fixing, verify JSON: cat ~/.openclaw/openclaw.json | python3 -m json.tool > /dev/null

Show what you changed."

  fix_output=$(timeout "$CLAUDE_TIMEOUT" "$CLAUDE_CODE" -p "$FIX_PROMPT" \
    --allowedTools "Read,Write,Edit,Bash" \
    --max-turns 10 \
    2>&1 || echo "Claude Code failed or timed out")

  echo "[safe-restart] Claude fix output (tail):"
  echo "$fix_output" | tail -40
  echo

done
