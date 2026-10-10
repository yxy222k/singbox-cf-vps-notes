# sing-box + Cloudflare 代理落地服务器：实操记录

一台新加坡 VPS 从零搭成代理落地服务器的完整记录：sing-box 1.14 服务端（VLESS Reality + VLESS/WS/TLS 经 Cloudflare CDN 回源）、
源站 IP 被墙后的 CDN 兜底与优选 IP、Cloudflare Tunnel 独立 SSH 应急通道、8443 只放行 Cloudflare 的 nftables 防火墙，
以及一路踩过的坑和改正过的错误判断。所有结论都来自实际命令输出。

## 目录

| 文件 | 内容 |
| --- | --- |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | 全过程记录（最全）：安装、Reality、Windows TUN 客户端、DNS 污染与 fake-ip、IP 被墙判定、CDN 双路、multiplex、优选 IP、8443 加固、传输通道的坑、错误与更正 |
| [docs/CDN-SETUP.md](docs/CDN-SETUP.md) | Cloudflare CDN 双路架构（Origin Rule 改回源端口、SSL Full、客户端配置） |
| [docs/CF-TUNNEL-SSH.md](docs/CF-TUNNEL-SSH.md) | Cloudflare Tunnel + Access 做 SSH 应急通道；关闭 SSH 密码登录 |
| [docs/PROXY-MODE.md](docs/PROXY-MODE.md) | 客户端代理模式说明：TUN、分流、fake-ip、selector |
| [docs/AGENT-MEMORY.md](docs/AGENT-MEMORY.md) | 给 AI 助手（Claude Code）的服务器工作记忆：服务与端口、连接路径、改动规矩、sing-box 1.14 的坑 |
| [server/cf8443-firewall.sh](server/cf8443-firewall.sh) | nftables：8443 只接受 Cloudflare IP 段 + 本机回环 |
| [server/systemd/](server/systemd/) | sing-box 与防火墙的 systemd unit / timer |
| [server/99-singbox-tuning.conf](server/99-singbox-tuning.conf) | BBR + fq 内核调优 |
| [server/99-swap.conf](server/99-swap.conf) | `vm.swappiness=10`（配 2 GiB `/swapfile`，做法见 OPERATIONS.md 文件表） |

## 脱敏说明

个人信息与凭证已替换为占位符：`<VPS_IP>`、`<OLD_VPS_IP>`、`example.com`（及其子域 `ws.` / `ssh.` / `node.`）、
`<UUID>`、`<REALITY_PUBLIC_KEY>`、`<SHORT_ID>`、`<TUNNEL_ID>`、`<team-name>`、`<你的邮箱>`、主机名、SSH 指纹、运营商等。
私钥、Token 从未出现在文档中。文中出现的 `172.64.x.x` 等是 Cloudflare 的公共边缘 IP。

文档中的路径（`F:\vps\...`）、日期和测量数据保留原样，供参考；照做时请换成自己的值。
