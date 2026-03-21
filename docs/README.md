# OpenClaw Bundle (Minimal)

This bundle contains exactly:

- `skills/codex-deep-search/` (skill code)
- `systemd-user/` (systemd **user** services):
  - `openclaw-gateway.service` (template; **no secrets included**)
  - `openclaw-gateway.service.d/auto-fix.conf` (OnFailure + start limits)
  - `openclaw-fix.service` (runs the fixer script)
- `scripts/`
  - `safe-gateway-restart.sh`
  - `openclaw-fix.sh`

## 1) Security model (read this first)

- **Never hardcode secrets** (API keys, gateway tokens) in unit files or scripts you plan to share.
- Put secrets into an env file referenced by systemd:
  - `%h/.config/openclaw/gateway.env`
  - set permissions: `chmod 600 ~/.config/openclaw/gateway.env`

Example `~/.config/openclaw/gateway.env`:

```bash
# Required (example):
OPENCLAW_GATEWAY_TOKEN=REPLACE_WITH_RANDOM_HEX

# Optional (only if you actually need them):
# GEMINI_API_KEY=...
# OPENAI_API_KEY=...
```

Generate a token:

```bash
openssl rand -hex 32
```

## 2) Install codex-deep-search skill

Copy `skills/codex-deep-search` into your OpenClaw workspace.

Notes:
- `skills/codex-deep-search/scripts/search.sh` contains **hardcoded paths** (e.g. `/home/ubuntu/...`).
  Adjust these paths for your machine:
  - `RESULT_DIR`
  - `OPENCLAW_BIN`
  - `OPENCLAW_CONFIG`

## 3) Install scripts

Recommended location (matches the unit file template):

```bash
mkdir -p ~/clawd/scripts
cp -a scripts/*.sh ~/clawd/scripts/
chmod +x ~/clawd/scripts/*.sh
```

Optional notifications:
- `safe-gateway-restart.sh` uses env var `SAFE_RESTART_TELEGRAM_TARGET`.
- `openclaw-fix.sh` uses env var `OPENCLAW_FIX_TELEGRAM_TARGET`.

If you don’t want Telegram notifications, leave them empty.

## 4) Install systemd user services

```bash
mkdir -p ~/.config/systemd/user/openclaw-gateway.service.d
cp -a systemd-user/openclaw-gateway.service ~/.config/systemd/user/
cp -a systemd-user/openclaw-fix.service ~/.config/systemd/user/
cp -a systemd-user/openclaw-gateway.service.d/auto-fix.conf ~/.config/systemd/user/openclaw-gateway.service.d/

systemctl --user daemon-reload
systemctl --user enable --now openclaw-gateway.service
```

If you want the user service to run after reboot (even without an active login session):

```bash
loginctl enable-linger "$USER"
```

## 5) How auto-fix works

- `openclaw-gateway.service` is configured with restart.
- If it keeps failing quickly, systemd will eventually hit the start limit and mark it as **failed**.
- When it becomes failed, `OnFailure=openclaw-fix.service` triggers `openclaw-fix.sh`.
- `openclaw-fix.sh` can call **Claude Code** (`claude -p`) to apply minimal fixes (usually config/plugin issues), then restarts the gateway.

## 6) Safe restart (manual)

```bash
cd ~/clawd/scripts
./safe-gateway-restart.sh "upgrade" 
```

## 7) Troubleshooting

- Check service:
  - `systemctl --user status openclaw-gateway.service -l`
  - `journalctl --user -u openclaw-gateway.service -n 200 --no-pager`

- Check gateway health:
  - `openclaw gateway status`

- If `claude` is missing:
  - disable auto-fix, or install Claude Code CLI.

---

## CN Quick Start (very short)

1) secrets 写到：`~/.config/openclaw/gateway.env`（chmod 600）
2) 拷贝 systemd user unit → `systemctl --user daemon-reload` → `enable --now`
3) 脚本放 `~/clawd/scripts/`，需要通知就设置 `SAFE_RESTART_TELEGRAM_TARGET / OPENCLAW_FIX_TELEGRAM_TARGET`
