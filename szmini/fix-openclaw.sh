#!/usr/bin/env bash
# SZMINI（SZOP）OpenClaw 修复 + 切换到 ChatGPT 订阅版 GPT-6.1 Sol
#
# 在 SZMINI 上以「跑 OpenClaw 网关的那个用户」执行（不要 sudo）：
#   bash fix-openclaw.sh
#
# 可选环境变量：
#   OC_PROFILE=szop        SZOP 如果是用 `openclaw --profile szop` 建的独立实例就设置它
#                          （状态目录 ~/.openclaw-szop）；默认实例留空
#   OC_AGENT=<agentId>     凭据登录到指定 agent；留空 = 默认 agent
#                          （模型写的是全局默认 agents.defaults.model，models set 不支持 --agent）
#   PROXY=http://127.0.0.1:7890   网关访问 chatgpt.com 用的代理（Clash mixed-port）；
#                          设为空字符串则不写代理
#   SKIP_UPDATE=1          不升级 OpenClaw
#   LOGIN_METHOD=device-code | oauth   SSH/无桌面用 device-code（默认），本机有浏览器可用 oauth
set -uo pipefail

MODEL="openai/gpt-6.1-sol"
PROXY="${PROXY-http://127.0.0.1:7890}"
LOGIN_METHOD="${LOGIN_METHOD:-device-code}"

oc() {
  local args=()
  [ -n "${OC_PROFILE:-}" ] && args+=(--profile "$OC_PROFILE")
  openclaw ${args[@]+"${args[@]}"} "$@"
}
agent_args=()
[ -n "${OC_AGENT:-}" ] && agent_args=(--agent "$OC_AGENT")

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*"; exit 1; }

# ---------------------------------------------------------------- 0. 环境
step "0. 基本环境"
command -v openclaw >/dev/null || die "找不到 openclaw；先 npm i -g openclaw@latest，或修 PATH（which -a openclaw）"
which -a openclaw
node -v
NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]')
NODE_MINOR=$(node -p 'process.versions.node.split(".")[1]')
if [ "$NODE_MAJOR" -lt 24 ] || { [ "$NODE_MAJOR" -eq 24 ] && [ "$NODE_MINOR" -lt 16 ]; } || [ "$NODE_MAJOR" -eq 25 ]; then
  die "Node $(node -v) 不满足 OpenClaw 要求（>=24.16 <25 或 >=26.1）。先升级 Node（brew upgrade node@24 / nvm install 24）再重跑"
fi
CUR=$(oc --version 2>/dev/null | grep -Eo '[0-9]{4}\.[0-9]+\.[0-9]+' | head -1)
echo "OpenClaw 当前版本: ${CUR:-未知}"

if [ -n "$PROXY" ]; then
  if curl -sS -m 10 -o /dev/null -w '%{http_code}\n' -x "$PROXY" https://chatgpt.com/ >/dev/null 2>&1; then
    echo "代理 $PROXY 可访问 chatgpt.com"
  else
    warn "通过 $PROXY 访问 chatgpt.com 失败——先确认 Clash 在跑、端口正确，否则登录和模型调用都会超时"
  fi
fi

# ---------------------------------------------------------------- 1. 升级
step "1. 升级 OpenClaw 到最新稳定版（旧版目录里没有 gpt-6.1-sol；<2026.5.26 还有 macOS ENETDOWN 崩溃 bug）"
if [ "${SKIP_UPDATE:-0}" != "1" ]; then
  oc update || npm i -g openclaw@latest || die "升级失败，看上面的 npm 报错"
  hash -r
  oc --version
fi

# ---------------------------------------------------------------- 2. 诊断 + 自动修复
step "2. 诊断"
oc status --all || true
oc gateway status --deep || true

step "3. doctor --fix（迁移旧 openai-codex/* 引用和 auth profile、修 launchd、清理服务里写死的代理变量）"
oc doctor --fix || warn "doctor 还有没修掉的项，记下上面的输出"
oc config validate || die "配置校验失败，按上面提示修 ~/.openclaw${OC_PROFILE:+-$OC_PROFILE}/openclaw.json 后重跑"

# gateway.mode 丢失是网关起不来最常见的原因
if [ "$(oc config get gateway.mode 2>/dev/null | tr -d '"[:space:]')" != "local" ]; then
  warn "gateway.mode 不是 local，补上"
  oc config set gateway.mode local
fi

# ---------------------------------------------------------------- 4. 代理（写进配置，不依赖 shell 环境）
if [ -n "$PROXY" ]; then
  step "4. 给网关配置代理 $PROXY"
  oc config set env.vars.HTTPS_PROXY "$PROXY"
  oc config set env.vars.HTTP_PROXY "$PROXY"
  oc config set env.vars.NO_PROXY "localhost,127.0.0.1,::1"
  oc config set env.vars.NODE_USE_ENV_PROXY "1"
fi

# ---------------------------------------------------------------- 5. 订阅登录
# models status --probe 需要独占状态目录，所以先停网关，最后再统一重装/启动
step "5. 停网关，检查 / 登录 ChatGPT·Codex 订阅（Plus/Pro/Business/Enterprise/Edu 才有 GPT-6.1 Sol）"
oc gateway stop || true
oc models auth list ${agent_args[@]+"${agent_args[@]}"} --provider openai || true
if oc models status ${agent_args[@]+"${agent_args[@]}"} --probe --probe-provider openai >/dev/null 2>&1; then
  echo "已有可用的 openai 订阅凭据，跳过登录（要换账号就手动跑 models auth login）"
else
  echo "按提示在任意设备浏览器里打开链接、输入代码并同意授权"
  oc models auth login ${agent_args[@]+"${agent_args[@]}"} --provider openai --method "$LOGIN_METHOD" \
    || die "登录失败：检查代理、账号是否付费订阅；Enterprise/Edu 需要管理员先在工作区开启 GPT-6.1 Sol"
fi

# ---------------------------------------------------------------- 6. 切模型
step "6. 设置默认模型 $MODEL"
oc config set plugins.entries.codex.enabled true
oc models set "$MODEL"
if ! oc models list ${agent_args[@]+"${agent_args[@]}"} --provider openai 2>/dev/null | grep -q 'gpt-6.1-sol'; then
  warn "账号模型目录里没看到 gpt-6.1-sol（Free/Go 套餐没有；Enterprise/Edu 需管理员开启；或目录未刷新）"
fi
oc models status ${agent_args[@]+"${agent_args[@]}"} --probe --probe-provider openai \
  || warn "探测失败：多半是代理不通或账号无权限，看上面报错"

# ---------------------------------------------------------------- 7. 重装服务并启动
step "7. 重装 launchd 服务并启动网关"
oc gateway install --force
oc gateway restart || oc gateway start
sleep 5
oc gateway status

# ---------------------------------------------------------------- 8. 验证
step "8. 验证"
oc models status ${agent_args[@]+"${agent_args[@]}"} || true
oc config get agents.defaults.model --json
cat <<MSG

完成。在任意聊天渠道里再确认一次：
  /status        → 应显示 Model: openai/gpt-6.1-sol，Runtime: OpenAI Codex
  /codex models  → 列表里应有 gpt-6.1-sol
有问题：openclaw${OC_PROFILE:+ --profile $OC_PROFILE} logs --follow
MSG
