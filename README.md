# instabox-keepalive

定时访问 InstaBox 机器的公开探针端口，阻止 30 分钟空闲自动暂停，并延长单轮运行时限。

- 机器：`jgp`（`m_agq72vcykb5a6rh5unklogksla`）
- 探针：远端 `ib-keepalive.service`（systemd 常驻，监听 8899）
- 触发：GitHub Actions，`*/10 * * * *`
- 不依赖本地电脑；不使用 API Key

## 手动触发

GitHub Actions 页面 → `instabox-keepalive` → Run workflow

## 远端探针状态

```bash
ssh -p 2222 ibssh_el3nfkt5jxi73wjhapkwut7bda@ssh.instabox.sh
systemctl status ib-keepalive.service
journalctl -u ib-keepalive.service -n 20
```
