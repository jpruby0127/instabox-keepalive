# instabox-keepalive

定时访问 InstaBox 机器 `jgp` 的公开探针端口，阻止 30 分钟空闲自动暂停，并延长单轮运行时限。

## 为什么要保活

InstaBox 免费档的两条硬规则：

| 规则 | 数值 | 影响 |
|---|---|---|
| 空闲自动暂停 | 30 分钟（免费档写死，不可改） | 机器被冻结后**自己唤不醒自己** |
| 单轮运行时限 | 120 分钟起，用得多最长 480 分钟 | 8 小时后强制冷却 5~20 分钟 |

官方规则里，**命令、文件访问、端口访问、SSH、CPU≥0.25 核**算「使用中」，能同时防空闲暂停并延长时限；
而 Activity lease 和 wake 调用**不算**使用中，只能防暂停。

所以保活的关键是：**从外部定期访问机器的公开端口 URL**。

## 三层保活

| 层 | 位置 | 频率 | 说明 |
|---|---|---|---|
| 主力 | 阿里云 `wb2a` 的 crontab | 10 分钟 | 24/7 常开，不依赖本机 |
| 内部续命 | 机器内 `ib-selfkeep.service` | 10 分钟 | 机器自己调 API exec，叠加使用时长 |
| 辅助 | 本仓库 GitHub Actions | 10 分钟 | 错峰 cron；实测该账号 schedule 未触发，作备份 |

> 本仓库的 GitHub schedule 在本账号下实测 30 分钟内 0 次自动运行
> （账号内所有仓库的 schedule 运行数均为 0），故**不作为依赖项**。
> 公开仓库可无限使用 Actions 额度，保留作冗余。

## 探针

远端 `ib-keepalive.service`（systemd 常驻，监听 8899），任何 GET 返回 200 + 时间戳。

- 公开 URL：`https://8899-agq72vcykb5a6rh5unklogksla.instabox.tech`
- 只回 200，不泄露任何信息；探针 URL 本身即公开入口

## 手动触发

GitHub Actions → `instabox-keepalive` → Run workflow

## 远端探针状态

```bash
ssh -p 2222 ibssh_el3nfkt5jxi73wjhapkwut7bda@ssh.instabox.sh
systemctl status ib-keepalive.service ib-selfkeep.service
journalctl -u ib-selfkeep.service -n 20
journalctl -u ib-keepalive.service -n 20
```

## wb2a 侧状态

```bash
ssh wb2a
crontab -l | grep instabox
tail -20 ~/.config/instabox-keepalive.log
```
