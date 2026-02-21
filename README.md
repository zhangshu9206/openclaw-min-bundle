# OpenClaw 最小化自愈网关 + Codex Deep Search 打包

这是一个“可公开分享”的最小化打包，用于：

1) 使用 **systemd user service** 运行 OpenClaw Gateway
2) 在网关反复崩溃/启动失败时，触发一个 **auto-fix** 脚本（可选：调用 Claude Code）进行最小化修复并重启
3) 提供 `codex-deep-search` skill（用 Codex CLI 做更深度的网页检索）

> 安全原则：仓库内 **不包含任何 token / API key**。敏感信息必须放在你本机的环境文件里（见下文）。

---

## 包含内容

- `systemd-user/`
  - `openclaw-gateway.service`：网关 systemd **user** service（模板，不含密钥）
  - `openclaw-gateway.service.d/auto-fix.conf`：OnFailure + 启动限流配置
  - `openclaw-fix.service`：触发修复脚本的 oneshot service
- `scripts/`
  - `openclaw-fix.sh`：网关失败后的自动修复入口（可选：调用 Claude Code）
  - `safe-gateway-restart.sh`：手动“安全重启”（检测错误→可选修复→再重启）
- `skills/codex-deep-search/`
  - `scripts/search.sh`：使用 Codex CLI 执行 deep search（支持后台 dispatch + Telegram 回调）
- `dist/openclaw-min-bundle.zip`
  - 同内容的加密压缩包（为方便离线传输；密码不在仓库公开）

---

## 重要安全提醒（必须看）

1. **不要把任何密钥写进 service 文件 / 脚本 / 仓库**。
2. 推荐把敏感信息放到：`~/.config/openclaw/gateway.env`，并设置权限：

```bash
mkdir -p ~/.config/openclaw
chmod 700 ~/.config/openclaw

# 创建 env 文件（示例）
cat > ~/.config/openclaw/gateway.env <<'EOF'
# 网关 token（示例：请替换成你自己的随机值）
OPENCLAW_GATEWAY_TOKEN=REPLACE_WITH_RANDOM_HEX

# 如需其他 API KEY 也放这里（按需）
# GEMINI_API_KEY=...
# OPENAI_API_KEY=...
EOF

chmod 600 ~/.config/openclaw/gateway.env
```

生成随机 token：

```bash
openssl rand -hex 32
```

---

## 安装：systemd user service（网关自愈）

把 service 文件安装到 systemd user 目录：

```bash
mkdir -p ~/.config/systemd/user/openclaw-gateway.service.d

cp -a systemd-user/openclaw-gateway.service ~/.config/systemd/user/
cp -a systemd-user/openclaw-fix.service ~/.config/systemd/user/
cp -a systemd-user/openclaw-gateway.service.d/auto-fix.conf \
  ~/.config/systemd/user/openclaw-gateway.service.d/

systemctl --user daemon-reload
systemctl --user enable --now openclaw-gateway.service
```

如果希望“重启后无需登录也能自动拉起 user service”：

```bash
loginctl enable-linger "$USER"
```

查看状态：

```bash
systemctl --user status openclaw-gateway.service -l
journalctl --user -u openclaw-gateway.service -n 200 --no-pager
```

---

## 自动修复（openclaw-fix.sh）说明

- 当 `openclaw-gateway.service` 反复失败并进入 failed 状态时：
  - `OnFailure=openclaw-fix.service` 会触发 `scripts/openclaw-fix.sh`
- `openclaw-fix.sh` 会：
  - 收集日志/`journalctl` 的错误上下文
  - （可选）调用 **Claude Code CLI**（命令 `claude -p`）进行最小化修复
  - 再重启 gateway 并检查是否恢复

> 如果你机器上没有 Claude Code CLI，可以把它当作“报警/收集日志”脚本使用，或自行改造成别的修复方式。

可选 Telegram 通知：

```bash
export OPENCLAW_FIX_TELEGRAM_TARGET="<你的 chat_id>"
```

---

## Codex Deep Search（skills/codex-deep-search）

位置：`skills/codex-deep-search/`。

注意：`skills/codex-deep-search/scripts/search.sh` 里有一些路径是示例（例如 `/home/ubuntu/...`），你需要根据自己的机器修改：

- `RESULT_DIR`
- `OPENCLAW_BIN`
- `CODEX_BIN`
- `OPENCLAW_CONFIG`（用于读取 hooks.token 做 wake）

用法示例（后台 dispatch + Telegram 回调）：

```bash
nohup bash skills/codex-deep-search/scripts/search.sh \
  --prompt "你的深度检索问题" \
  --task-name "my-research" \
  --telegram-group "<你的 Telegram chat_id>" \
  --timeout 120 > /tmp/codex-search.log 2>&1 &
```

---

## 免责声明

- 这是模板/示例工程，默认不保证适配所有系统路径。
- 请务必按你自己的环境调整路径与权限。
- **不要在公开仓库提交任何密钥**。
