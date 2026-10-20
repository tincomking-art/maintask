# SZMINI（SZOP）OpenClaw 修复 + 切到订阅版 GPT-6.1 Sol

一键脚本：[`fix-openclaw.sh`](./fix-openclaw.sh)。在 SZMINI 上以跑网关的那个用户执行（不要 sudo）：

```bash
# 默认实例（~/.openclaw），Clash mixed-port 7890
bash fix-openclaw.sh

# SZOP 是用 --profile szop 建的独立实例（~/.openclaw-szop）时
OC_PROFILE=szop bash fix-openclaw.sh

# 代理端口不同 / 不需要代理
PROXY=http://127.0.0.1:7897 bash fix-openclaw.sh
PROXY= bash fix-openclaw.sh
```

脚本会做：检查 Node 版本 → 升级到最新稳定版（目前 2026.10.5）→ `doctor --fix` →
补 `gateway.mode=local` → 把代理写进配置 → ChatGPT 订阅登录（device-code）→
`models set openai/gpt-6.1-sol` → 探测 → 重装 launchd 服务并重启 → 验证。
可以重复跑：已有可用凭据时会跳过登录。

## 前提

| 项 | 要求 |
|---|---|
| ChatGPT 套餐 | Plus / Pro / Business / Enterprise / Edu。**Free、Go 没有 GPT-6.1 Sol**；Enterprise/Edu 要管理员先在工作区开启 |
| Node | `>=24.16 <25` 或 `>=26.1`（`node -v`） |
| OpenClaw | 2026.9.33 / 2026.10.3 及以后的版本目录里才有 `gpt-6.1-sol`，直接升最新 |
| 网络 | 网关进程要能访问 `chatgpt.com`、`auth.openai.com`（深圳需要走 Clash） |

## 关键点（手动排查时对照）

1. **模型引用是 `openai/gpt-6.1-sol`**，不是 `openai-codex/...`。2026.7 起订阅和 API Key
   共用 `openai` provider，旧的 `openai-codex/*` 引用和 `openai-codex:*` 凭据由
   `openclaw doctor --fix` 自动迁移。旧配置没迁移会表现为模型找不到、401、或静默不回复。
2. **订阅登录**：`openclaw models auth login --provider openai --method device-code`
   （SSH 或 Mac mini 没开屏幕时用 device-code，在手机或电脑浏览器上输入代码即可；本机有浏览器就用
   `--method oauth`）。新版 onboarding 不再从 `~/.codex` 导入凭据，必须在 OpenClaw 里登录一次。
3. **`models status --probe` 要先停网关**（它需要独占状态目录），所以脚本先
   `gateway stop`，最后才 `gateway install --force && gateway restart`。
4. **代理写进配置，不要依赖 shell**：launchd 启动的网关不会读 `~/.zshrc`，`doctor --fix`
   还会清掉安装时写进服务的 `HTTP(S)_PROXY`。脚本写入 `env.vars.HTTPS_PROXY` 等变量
   （进程环境里没有时才生效）。
5. **Mac mini 上网关时不时自己挂掉**：先确认已经升级（≥2026.5.26 修了 `ENETDOWN` 崩溃），再关掉维护睡眠：
   ```bash
   sudo pmset -a sleep 0 disksleep 0 standby 0 powernap 0
   ```
   如果网关还是会停，看 `launchctl print gui/$UID/ai.openclaw.gateway | grep -E "state|last exit|runs"`，
   并检查 `ai.openclaw.gateway` 和 `ai.openclaw.node` 两个 LaunchAgent 是否在互相抢端口（`openclaw gateway status --deep`）。

## 验证

```bash
openclaw models status
openclaw models auth list --provider openai
openclaw config get agents.defaults.model --json   # primary 应为 openai/gpt-6.1-sol
openclaw gateway status                           # Runtime: running
```

在聊天里：`/status` 应显示 `openai/gpt-6.1-sol`、`Runtime: OpenAI Codex`；`/codex models` 列表里有 `gpt-6.1-sol`。

## 常见报错

| 报错 / 现象 | 处理 |
|---|---|
| `Gateway start blocked: set gateway.mode=local` | `openclaw config set gateway.mode local`（脚本已处理） |
| `EADDRINUSE` / `another gateway instance is already listening` | `openclaw gateway status --deep` 找到重复的服务并删掉，只保留一个 |
| `refusing to bind gateway ... without auth` | 绑定了 lan/tailnet 却没配 `gateway.auth.token`，补上 token 或改回 loopback |
| 升级后 401 | `openclaw doctor --fix` 会清掉各 agent 里过期的 OAuth 副本，然后重新 `models auth login` |
| `models list` 里没有 gpt-6.1-sol | 套餐不对、Enterprise 未开启，或登录的是另一个 ChatGPT 账号；`models auth list --provider openai` 看是哪个账号 |
| 配置是新版本写的，旧二进制拒绝启动 | `which -a openclaw` 修 PATH，再 `openclaw gateway install --force` |
| 登录 / 调用超时 | 代理没通：`curl -x http://127.0.0.1:7890 -I https://chatgpt.com` |

日志：`openclaw logs --follow`，或 `~/Library/Logs/openclaw/gateway.log`。
