#!/bin/bash
# InstaBox 保活 v3：探针 + exec + wake 三级唤醒。
#
# 背景（2026-11-23 实测踩坑）：
#   v1 只访问公开探针 URL。机器一旦被平台挂起，探针只会返回 409/502，
#   而**探针和 wake 都不会唤醒处于冷却中的机器** —— 冷却期内所有唤醒手段
#   统一返回 409 machine_cooldown，必须等 cooldownUntil 到点后再发一次请求。
#   结果：v1 连续 7 次 409 从未把机器叫醒，代理彻底失联（用户连不上谷歌）。
#
# 官方规则（instabox.sh/docs/machines/auto-pause）：
#   - 空闲 30 分钟自动暂停；免费档不可改。
#   - 每次唤醒从 120 分钟重新起算；「使用中」会把它涨回 480 分钟。
#     判定：过去 30 分钟里至少 5 分钟算使用 → +120 分钟；1~4 分钟 → +30 分钟。
#   - 算「使用中」：命令执行、文件读写、端口请求、桌面、终端/SSH 流量、CPU ≥ 0.25 vCPU。
#   - **不算**「使用中」：Activity lease、wake 调用（只能防空闲暂停，救不回来）。
#   - 冷却阶梯：第 1 次 5~20 分钟，第 2 次 60~75 分钟，第 3 次起 120~135 分钟。
#     冷却期内一切唤醒（exec/SSH/文件/公网 URL/wake/resume/start）都返回 409 machine_cooldown。
#     冷却长度在开始时就固定，重复调用不会延长或缩短。
#
# v3 策略：
#   1) 每 8 分钟探活一次公开端口（探针算「使用中」，用于把运行上限养回 480）
#   2) 探活失败 → 用 exec 主动唤醒（exec 会等 resume 完成，最强手段，且算使用中）
#   3) exec 失败 → 退化为 wake（最弱，仅防空闲暂停）
#   4) 冷却期内记住 cooldownUntil，到点后自动重试；不空转
#
# 频率取 8 分钟：30 分钟空闲上限留近 4 倍余量；过去 30 分钟内有 3~4 次探针，
# 足以满足「至少 5 分钟使用中」的涨限条件。
set -uo pipefail

MID="${INSTABOX_MACHINE_ID:-m_agq72vcykb5a6rh5unklogksla}"
PROBE_URL="${INSTABOX_PROBE_URL:-https://8899-agq72vcykb5a6rh5unklogksla.instabox.tech}"
API_BASE="${INSTABOX_API_BASE:-https://api.instabox.sh}"
LOG="${INSTABOX_KEEPALIVE_LOG:-$HOME/.config/instabox-keepalive.log}"
KEYFILE="${INSTABOX_API_KEY_FILE:-$HOME/.config/instabox/api_key}"
STATEFILE="${INSTABOX_KEEPALIVE_STATE:-$HOME/.config/instabox-keepalive.state}"

mkdir -p "$(dirname "$LOG")"

now() { date '+%F %T'; }
logline() { echo "$(now) $*" >> "$LOG"; }

read_key() { [ -s "$KEYFILE" ] && cat "$KEYFILE"; }

# ---------------------------------------------------------------- JSON 解析
# 提取 error.code 和 retryAfterSeconds（兼容 Python3.6，无 f-string 依赖）
parse_err() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("unparsable|0"); sys.exit(0)
e = d.get("error") or {}
print("%s|%s" % (e.get("code") or "unknown", e.get("retryAfterSeconds") or 0))
' 2>/dev/null
}

api_post() {
  # $1=path  $2=body  -> 输出响应体
  local key; key=$(read_key)
  [ -n "$key" ] || { echo '{"error":{"code":"no_key"}}'; return; }
  curl -s --max-time 60 \
    -X POST \
    -H "X-API-Key: $key" \
    -H "Content-Type: application/json" \
    -d "$2" \
    "$API_BASE/v1/machines/$MID$1" 2>/dev/null
}

# ---------------------------------------------------------------- 探活
probe() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 25 "$PROBE_URL" 2>/dev/null || echo "000"
}

# ---------------------------------------------------------------- 冷却状态
cooldown_until() {
  [ -f "$STATEFILE" ] || { echo 0; return; }
  local v; v=$(cat "$STATEFILE" 2>/dev/null)
  case "$v" in (''|*[!0-9]*) echo 0; return;; esac
  if [ "$v" -lt "$(date +%s)" ]; then echo 0; return; fi
  echo "$v"
}
set_cooldown() { echo "$1" > "$STATEFILE"; }
clear_cooldown() { rm -f "$STATEFILE"; }

# ---------------------------------------------------------------- 唤醒（exec 优先）
# exec 会等待 resume 完成（最多 45s），是最强唤醒手段，且计入「使用中」。
try_wake() {
  local body out code retry
  body=$(api_post "/exec" '{"cmd":"true"}')
  out=$(printf '%s' "$body" | parse_err)
  code=${out%%|*}; retry=${out##*|}

  if [ "$code" = "unknown" ] || [ "$code" = "unparsable" ]; then
    # 没有 error 字段 → 成功（ExecResult）
    clear_cooldown
    logline "wake EXEC_OK"
    echo "ok"; return
  fi

  if [ "$code" = "machine_cooldown" ]; then
    local until; until=$(( $(date +%s) + ${retry:-600} + 45 ))
    set_cooldown "$until"
    logline "wake COOLDOWN retryAfter=${retry:-?}s until=$(date -d @$until '+%F %T' 2>/dev/null || echo $until)"
    echo "cooldown"; return
  fi

  logline "wake EXEC_FAIL code=$code body=$(printf '%s' "$body" | head -c 200)"
  echo "fail:$code"; return
}

# 退化手段：wake（只防空闲暂停，不算使用中）
try_wake_weak() {
  local body out code retry
  body=$(api_post "/wake" '{}')
  out=$(printf '%s' "$body" | parse_err)
  code=${out%%|*}; retry=${out##*|}

  if [ "$code" = "unknown" ] || [ "$code" = "unparsable" ]; then
    clear_cooldown
    logline "wake WAKE_OK"
    echo "ok"; return
  fi
  if [ "$code" = "machine_cooldown" ]; then
    local until; until=$(( $(date +%s) + ${retry:-600} + 45 ))
    set_cooldown "$until"
    logline "wake WAKE_COOLDOWN retryAfter=${retry:-?}s"
    echo "cooldown"; return
  fi
  logline "wake WAKE_FAIL code=$code"
  echo "fail:$code"; return
}

# ================================================================ 主流程
COOL=$(cooldown_until)
NOW=$(date +%s)

if [ "$COOL" -gt "$NOW" ]; then
  # 冷却尚未结束：不空转，等下一轮 cron
  logline "tick state=cooldown remaining=$(( COOL - NOW ))s action=skip"
  exit 0
fi

if [ "$COOL" -gt 0 ] && [ "$COOL" -le "$NOW" ]; then
  # 冷却刚过点 → 立刻尝试唤醒
  logline "tick state=cooldown_expired action=wake"
  R=$(try_wake)
  if [ "$R" = "ok" ]; then
    for i in 1 2 3 4 5 6 7 8 9 10; do
      sleep 15
      CODE=$(probe)
      logline "tick verify attempt=$i http=$CODE"
      [ "$CODE" = "200" ] && { logline "tick RECOVERED"; exit 0; }
    done
    logline "tick woke_but_probe_bad"
  fi
  exit 0
fi

# 正常路径：探活
CODE=$(probe)
logline "tick probe http=$CODE"

if [ "$CODE" = "200" ]; then
  clear_cooldown
  exit 0
fi

# 探活失败 → 尝试唤醒
logline "tick probe_failed http=$CODE -> exec"
R=$(try_wake)

if [ "$R" = "ok" ]; then
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 15
    CODE=$(probe)
    logline "tick verify attempt=$i http=$CODE"
    [ "$CODE" = "200" ] && { logline "tick RECOVERED"; exit 0; }
  done
  logline "tick woke_but_probe_bad"
  exit 0
fi

if [ "$R" = "cooldown" ]; then
  exit 0
fi

# exec 也失败 → 退化到 wake
logline "tick exec_failed -> wake"
try_wake_weak >/dev/null
exit 0
