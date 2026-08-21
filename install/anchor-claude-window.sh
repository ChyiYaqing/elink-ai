#!/bin/sh
# 把 Claude 的 5 小时用量窗口锚定在固定时刻，让窗口边界对齐作息。
#
# 窗口从窗口内第一条消息开始计时，5 小时后过期；不发消息，窗口就不会开始。
# 这个脚本因此不制造额度，它只决定窗口的起点：在每天固定的几个时刻检查，
# 若当前没有活跃窗口，就发一条最小消息把边界钉在 09:00 / 14:00 这样的整点
# 上，而不是让它跟着当天第一次随手提问漂移，之后每次午休又漂一点。
#
# 每次锚定都会占掉一个 5 小时块，而块内额度不累积。所以调用它的时刻表里只
# 应该放你确实会工作到的边界；给一个你已经下班的时刻排班，等于整夜空转一个
# 块。见 local.elink-ai-anchor.plist.example。
#
# 读不到凭据或用量接口失败时一律选择锚定：多发一条 hello 的代价约等于零，
# 漏掉一次锚定却会让接下来一整天的边界错位。
set -eu

USAGE_URL=https://api.anthropic.com/api/oauth/usage
CLAUDE=${CLAUDE_BIN:-claude}

# 写 stderr：window_reset_at 的 stdout 会被命令替换捕获成返回值，日志混进去
# 既污染返回值，又让诊断信息恰好在出问题时消失。plist 把两个流写同一个文件。
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') anchor: $*" >&2; }

# Claude Code 在 macOS 上刷新的是 Keychain 条目，~/.claude/.credentials.json
# 可能是登录方式变更前留下的过期文件，因此 Keychain 优先——与 Swift 侧
# UsageFetcher.claudeToken 的取舍一致，否则用量接口会一直 401。
claude_token() {
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN"
    return 0
  fi
  raw=$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null || true)
  if [ -z "$raw" ]; then
    raw=$(cat "$HOME/.claude/.credentials.json" 2>/dev/null || true)
  fi
  [ -n "$raw" ] || return 0
  printf '%s' "$raw" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null || true
}

# 用量接口是 Claude Code 自己的；发别人的 User-Agent 只是在宣告
# "这不是 Claude Code"，没有任何好处。
user_agent() {
  version=$("$CLAUDE" --version 2>/dev/null | awk '{print $1}')
  printf 'claude-code/%s' "${version:-2.1.0}"
}

# 5 小时窗口的重置时刻（epoch 秒）。0 表示未知或当前没有活跃窗口，两种情况
# 都走锚定分支。
window_reset_at() {
  token=$(claude_token)
  if [ -z "$token" ]; then
    log '读不到 OAuth 凭据，按无活跃窗口处理'
    echo 0
    return 0
  fi
  body=$(curl -sf --max-time 10 "$USAGE_URL" \
    -H "Authorization: Bearer $token" \
    -H 'anthropic-beta: oauth-2025-04-20' \
    -H 'Accept: application/json' \
    -H "User-Agent: $(user_agent)" 2>/dev/null || true)
  if [ -z "$body" ]; then
    log '用量接口无响应，按无活跃窗口处理'
    echo 0
    return 0
  fi
  # resets_at 实际返回形如 2026-08-12T15:19:59.848656+00:00：带小数秒，且时区
  # 是偏移量而非 Z，而 fromdateiso8601 只认整秒的 Z。Rust 侧用 chrono 做完整
  # RFC3339 解析，这里没有那种奢侈，所以拆出偏移量自己减。不写死 +00:00：
  # 把带偏移的串当 UTC 读，错的是小时数，而不会报错，这种错静悄悄。
  printf '%s' "$body" | jq -r '
    (.five_hour.resets_at // "")
    | if . == "" then 0
      else capture("^(?<t>\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2})(\\.\\d+)?(?<z>Z|[+-]\\d{2}:\\d{2})?$")
        | (.t + "Z" | fromdateiso8601)
          - (if (.z // "Z") == "Z" then 0
             else (.z | (.[1:3] | tonumber) * 3600 + (.[4:6] | tonumber) * 60)
                  * (if .z[0:1] == "-" then -1 else 1 end)
             end)
      end' 2>/dev/null || echo 0
}

now=$(date +%s)
reset_at=$(window_reset_at)

if [ "$reset_at" -gt "$now" ] 2>/dev/null; then
  log "窗口已在运行，$(( (reset_at - now) / 60 )) 分钟后重置，无需锚定"
  exit 0
fi

# 用 Haiku 发这条消息。实测 --model haiku 确实路由到 claude-haiku-4-5，且确实
# 计进 five_hour：连发 8 条 haiku 请求（各约 900 输出 token），窗口占用从 4%
# 涨到 7%，期间没有其他流量。这一句 hello 只有约 205 输出 token，代价远小于
# 一个百分点，而同样一句走 Opus 会按重得多的权重记账。
if ! "$CLAUDE" -p hello --model haiku >/dev/null 2>&1; then
  log '锚定请求失败'
  exit 1
fi

# 不假设它生效：回读一次 resets_at，把真实的窗口边界写进日志。这样排班时刻
# 是否真的钉住了边界，看日志就能确认，而不是靠推断。
reset_at=$(window_reset_at)
if [ "$reset_at" -gt "$now" ] 2>/dev/null; then
  log "已锚定，窗口边界 $(date -r "$reset_at" '+%Y-%m-%d %H:%M')"
else
  log '已发送锚定消息，但用量接口未确认新窗口'
fi
