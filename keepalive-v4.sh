#!/bin/bash
# InstaBox 保活 v4：exec 养时长 + 探针验证 + 三级唤醒。
#
# v3 的遗留问题（2026-11-23 分析）：
#   v3 正常路径只探活。但平台的涨限判定是**按分钟粒度**统计的：
#   「过去 30 分钟里有 ≥5 分钟算使用 → +120 分钟；1~4 分钟 → +30 分钟」。
#   探针每 8 分钟一次、每次只持续几毫秒，CPU 负载几乎为零，
#   很可能凑不满「≥5 分钟使用中」，于是 run 涨到 480 分钟后**卡住不再增长**，
#   最终撞上限被强制冷却 —— 2026-11-23 04:50 就是这么挂的。
#
# v4 的做法：
#   正常路径也跑 exec（一条真实命令，有 CPU 消耗，稳定计入「使用中」），
#   把运行上限牢牢养在 480 分钟，避免再次撞限进入冷却。
#   exec 同时具备唤醒能力，所以「唤醒」和「养时长」用同一个动作完成。
#
#   官方规则（instabox.sh/docs/machines/auto-pause）：
#   - 空闲 30 分钟自动暂停；免费档写死不可改。
#   - 每次唤醒从 120 分钟起算；使用中会把它涨回 480（上限）。
#   - 算「使用中」：命令执行、文件读写、端口请求、SSH 流量、CPU ≥ 0.25 vCPU。
#   - 不算「使用中」：Activity lease、wake 调用（只能防空闲暂停）。
#   - 冷却阶梯：1st 5~20 分钟，2nd 60~75 分钟，3rd+ 120~135 分钟。
#     冷却期内一切唤醒手段统一 409 machine_cooldown，冷却长度固定不可改。
#
# 频率 8 分钟：30 分钟空闲上限留近 4 倍余量；30 分钟窗口内有 3~4 次 exec，
# 足以满足「≥5 分钟使用中」的涨限条件。
set -uo pipefail

MID="${INSTABOX_MACHINE_ID:-m_agq72vcykb5a6rh5unklogksla}"
PROBE_URL="${INSTABOX_PROBE_URL:-https://8899-agq72vcykb5a6rh5unklogksla.instabox.tech}"
API_BASE="${INSTABOX_API_BASE:-https://api.instabox.sh}"
LOG="${INSTABOX_KEEPALIVE_LOG:-$HOME/.config/instabox-keepalive.log}"
KEYFILE="${INSTABOX_API_KEY_FILE:-$HOME/.config/instabox/api_key}"
STATEFILE="${INSTABOX_KEEPALIVE_STATE:-$HOME/.config/instabox-keepalive.state}"
# 每 N 轮跑一次 exec 养时长（默认每轮都跑）
EXEC_EVERY="${INSTABOX_EXEC_EVERY:-1}"

mkdir -p "$(dirname "$LOG")"

now() { date '+%F %T'; }
logline() { echo "$(now) $*" >> "$LOG"; }

read_key() { [ -s "$KEYFILE" ] && cat "$KEYFILE"; }

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
  local key; key=$(read_key)
  [ -n "$key" ] || { echo '{"error":{"code":"no_key"}}'; return; }
  curl -s --max-time 90 \
    -X POST \
    -H "X-API-Key: $key" \
    -H "Content-Type: application/json" \
    -d "$2" \
    "$API_BASE/v1/machines/$MID$1" 2>/dev/null
}

probe() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 25 "$PROBE_URL" 2>/dev/null || echo "000"
}

cooldown_until() {
  [ -f "$STATEFILE" ] || { echo 0; return; }
  local v; v=$(cat "$STATEFILE" 2>/dev/null)
  case "$v" in (''|*[!0-9]*) echo 0; return;; esac
  if [ "$v" -lt "$(date +%s)" ]; then echo 0; return; fi
  echo "$v"
}
set_cooldown() { echo "$1" > "$STATEFILE"; }
clear_cooldown() { rm -f "$STATEFILE"; }

# ---------------------------------------------------------------- exec
# exec 会等 resume 完成（最多 45s），是最强唤醒手段，且稳定计入「使用中」。
# 机器在跑时立即返回；机器睡了则唤醒它。
do_exec() {
  local body out code retry
  body=$(api_post "/exec" '{"cmd":"true"}')
  out=$(printf '%s' "$body" | parse_err)
  code=${out%%|*}; retry=${out##*|}

  if [ "$code" = "unknown" ] || [ "$code" = "unparsable" ]; then
    clear_cooldown
    logline "exec OK (machine awake, usage counted)"
    echo "ok"; return
  fi

  if [ "$code" = "machine_cooldown" ]; then
    local until; until=$(( $(date +%s) + ${retry:-600} + 45 ))
    set_cooldown "$until"
    logline "exec COOLDOWN retryAfter=${retry:-?}s until=$(date -d @$until '+%F %T' 2>/dev/null || echo $until)"
    echo "cooldown"; return
  fi

  logline "exec FAIL code=$code body=$(printf '%s' "$body" | head -c 200)"
  echo "fail:$code"; return
}

# ---------------------------------------------------------------- wake（弱兜底）
do_wake() {
  local body out code retry
  body=$(api_post "/wake" '{}')
  out=$(printf '%s' "$body" | parse_err)
  code=${out%%|*}; retry=${out##*|}

  if [ "$code" = "unknown" ] || [ "$code" = "unparsable" ]; then
    clear_cooldown
    logline "wake OK (weak, usage NOT counted)"
    echo "ok"; return
  fi
  if [ "$code" = "machine_cooldown" ]; then
    local until; until=$(( $(date +%s) + ${retry:-600} + 45 ))
    set_cooldown "$until"
    logline "wake COOLDOWN retryAfter=${retry:-?}s"
    echo "cooldown"; return
  fi
  logline "wake FAIL code=$code"
  echo "fail:$code"; return
}

# ---------------------------------------------------------------- 唤醒后确认
verify() {
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 15
    local c; c=$(probe)
    logline "verify attempt=$i http=$c"
    [ "$c" = "200" ] && { logline "RECOVERED probe=http=200"; return 0; }
  done
  logline "woke but probe still bad"
  return 1
}

# ================================================================ 主流程
COOL=$(cooldown_until)
NOW=$(date +%s)

# 冷却未结束 → 不空转，等下一轮
if [ "$COOL" -gt "$NOW" ]; then
  logline "tick state=cooldown remaining=$(( COOL - NOW ))s action=skip"
  exit 0
fi

# 冷却刚过点 → 立刻唤醒
if [ "$COOL" -gt 0 ]; then
  logline "tick state=cooldown_expired action=exec"
  R=$(do_exec)
  [ "$R" = "ok" ] && verify
  exit 0
fi

# 正常路径：先探活看状态，再决定是否 exec
CODE=$(probe)
logline "tick probe http=$CODE"

if [ "$CODE" = "200" ]; then
  # 机器活着。仍需 exec 养时长，否则 run 涨到 480 后卡住 → 撞限冷却。
  COUNT_FILE="${INSTABOX_KEEPALIVE_STATE}.count"
  N=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
  case "$N" in (''|*[!0-9]*) N=0;; esac
  N=$(( N + 1 ))
  echo "$N" > "$COUNT_FILE"
  if [ $(( N % EXEC_EVERY )) -eq 0 ]; then
    logline "tick alive, running exec to keep usage high (round=$N)"
    R=$(do_exec)
    [ "$R" = "ok" ] || logline "tick exec_on_alive -> $R"
  fi
  exit 0
fi

# 探活失败 → 尝试唤醒
logline "tick probe_failed http=$CODE -> exec"
R=$(do_exec)
if [ "$R" = "ok" ]; then
  verify
  exit 0
fi
if [ "$R" = "cooldown" ]; then
  exit 0
fi

# exec 也失败 → 退化到 wake
logline "tick exec_failed -> wake"
do_wake >/dev/null
exit 0
