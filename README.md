# instabox-keepalive

定时探活并**主动唤醒** InstaBox 机器 `jgp`，保证 VLESS+WS 代理长期在线。

## 为什么要保活

InstaBox 免费档的两条硬规则（来源：官方文档 `instabox.sh/docs/machines/auto-pause`）：

| 规则 | 数值 | 影响 |
|---|---|---|
| 空闲自动暂停 | 30 分钟（免费档写死，不可改） | 机器被冻结后要靠外部请求唤醒 |
| 单轮运行时限 | 每次唤醒从 120 分钟起，用得多最长 480 分钟 | 用满后强制冷却 |

**算「使用中」**（能防空闲暂停 **且** 延长时限）：命令执行、文件读写、端口请求、桌面操作、终端/SSH 流量、CPU ≥ 0.25 vCPU。

**不算「使用中」**（只能防空闲暂停，救不回运行时限）：Activity lease、`wake` 调用。

限时的涨法：过去 30 分钟里，≥5 分钟算使用 → +120 分钟；1~4 分钟 → +30 分钟；完全没有 → 到点即暂停。

## ⚠️ 关键教训：只探活是不够的（2026-11-23 实战）

机器撞上 480 分钟上限后进入**冷却期**，此时：

- 探针 URL 一律返回 **409**（不是 200，也不是 503）
- **`wake` 和 `exec` 也一样返回 409 `machine_cooldown`**，带 `retryAfterSeconds`
- 冷却期内**没有任何办法唤醒**，必须等 `cooldownUntil` 到点后再发一次请求
- 冷却长度在开始时固定，重复调用不会延长也不会缩短

实测后果：v1 方案（只探活）在冷却后连续 7 次 409，**从来没把机器叫醒**，
代理就此彻底失联 —— 用户手机上连不上谷歌。

**冷却阶梯**（免费档，连续撞上限会越来越久）：

| 次数 | 冷却时长 |
|---|---|
| 第 1 次 | 5~20 分钟 |
| 第 2 次 | 60~75 分钟 |
| 第 3 次起 | 120~135 分钟 |

> 冷却计数在「空闲暂停」或「手动暂停」后重置；距上次冷却结束 2 小时以上再启动也会重置。

## v4 方案：exec 养时长 + 探针验证 + 三级唤醒

`keepalive-v4.sh` 的逻辑：

1. **探活**公开端口，确认机器状态
2. **无论机器死活都跑 `exec`**（一条真实命令，有 CPU 消耗）
   —— 这是 v4 相比 v3 的关键改进，见下
3. 探活失败 → `exec` 主动唤醒（会等 resume 完成，最多 45 秒；最强手段）
4. `exec` 也失败 → 退化为 **`wake`**（最弱，仅防空闲暂停）
5. 冷却期内记下 `cooldownUntil`，**不空转**，到点后自动重试唤醒

### 为什么 v3 还不够（v4 的关键改进）

平台的涨限判定是**按分钟粒度**统计的：「过去 30 分钟里有 ≥5 分钟算使用 → +120 分钟」。

v3 正常路径只探活 —— 探针每 8 分钟一次、每次只持续几毫秒，CPU 负载几乎为零，
很可能凑不满「≥5 分钟使用中」。于是 run 涨到 480 分钟后**卡住不再增长**，
最终撞上限被强制冷却 —— 2026-11-23 04:50 就是这么挂的。

v4 每次都跑 `exec`（真实命令 + CPU 消耗），稳定计入「使用中」，
把运行上限牢牢养在 480 分钟，从根上避免再次撞限进入冷却。

频率 **8 分钟**：30 分钟空闲上限留近 4 倍余量；30 分钟窗口内有 3~4 次 exec，
足以满足「≥5 分钟使用中」的涨限条件。

## 三层部署

| 层 | 位置 | 频率 | 状态 |
|---|---|---|---|
| **主力** | 阿里云 `wb2a` crontab | 8 分钟 | ✅ 24/7 常开，不依赖本机 |
| 内部续命 | 机器内 `ib-selfkeep.service` | 10 分钟 | ✅ 机器自己调 API exec |
| 辅助 | 本仓库 GitHub Actions | 8 分钟 | ⚠️ 该账号 schedule 实测未触发，作冗余 |

> 本仓库的 GitHub schedule 在本账号下实测 30 分钟内 0 次自动运行
> （账号内所有仓库的 schedule 运行数均为 0），故**不作为依赖项**。

## 密钥

唤醒需要 API Key。本仓库**不含**密钥。

- 主力层：`wb2a` 上 `~/.config/instabox/api_key`（600 权限）
- GitHub 层：仓库 Secret `INSTABOX_API_KEY`（需手动配置，未配置则只探活不唤醒）

## 探针

远端 `ib-keepalive.service`（systemd 常驻，监听 8899），任何 GET 返回 200 + 时间戳。

- 公开 URL：`https://8899-agq72vcykb5a6rh5unklogksla.instabox.tech`
- 只回 200，不泄露任何信息

## 手动触发

GitHub Actions → `instabox-keepalive` → Run workflow

## 状态检查

```bash
# 机器状态（state / cooldownUntil / runStartedAt）
curl -s -H "X-API-Key: $(cat ~/.config/instabox/api_key)" \
  https://api.instabox.sh/v1/machines/m_agq72vcykb5a6rh5unklogksla

# 保活日志
ssh wb2a 'tail -20 ~/.config/instabox-keepalive.log'

# 远端服务
ssh -p 2222 ibssh_el3nfkt5jxi73wjhapkwut7bda@ssh.instabox.sh \
  'systemctl is-active ib-xray ib-keepalive ib-selfkeep'
```
