#!/usr/bin/env bash
# InstaBox 保活：访问机器的公开端口 URL。
#
# 为什么这样做：
#   - 官方规则：空闲 30 分钟自动暂停；命令/文件/端口访问/SSH/CPU 都算「使用中」，
#     能同时防止空闲暂停并延长单轮运行时限（120 -> 480 分钟）。
#   - Activity lease 和 wake 调用不算「使用中」，只能防暂停不延长时限。
#   - 访问公网 URL 不需要 API Key，Key 不出本仓库。
#
# 频率：每 10 分钟一次。30 分钟空闲上限留 3 倍余量，20 分钟延迟也不至于暂停。
set -uo pipefail

URL="${INSTABOX_PROBE_URL:-https://8899-agq72vcykb5a6rh5unklogksla.instabox.tech}"

for i in 1 2 3; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 "$URL" || echo "000")
  if [ "$code" = "200" ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) OK http=$code url=$URL"
    exit 0
  fi
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) attempt=$i http=$code"
  sleep 10
done

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) FAILED after 3 attempts"
exit 1
