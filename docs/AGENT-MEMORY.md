# 这台 VPS 的工作记忆（由用户本机的 Claude 于 2026-10-08 整理，2026-10-09 最后更新）

用中文回答。动手前先看现状，改动前先备份，结论以实际命令输出为准，不要凭推测说"已完成"。

## 一、这台机器是什么

- 华纳云新加坡 VPS：Ubuntu 24.04 / 4 核 / 7.8 GiB / 48 GB；公网 IP `<VPS_IP>`；**出口限速 5 Mbps**；没有 IPv6。
- 用途：**用户（在中国大陆）的代理落地服务器**，跑 sing-box 1.14.2 服务端。用户日常上网、日常 SSH 都经过它。
- **这个 IP 从中国大陆入站被墙**（TCP 黑洞）；从 VPS 往外访问一切正常（GitHub、Anthropic 都通）。
- 详细记录（只读快照）：`/root/vps-docs/`——`OPERATIONS.md`（全过程，最全）、`CDN-SETUP.md`、`CF-TUNNEL-SSH.md`、`PROXY-MODE.md`。
  主副本在用户 Windows 电脑的 `F:\vps\singbox\`，这里的可能过时。

## 二、服务与端口

| 服务 | 监听 | 作用 |
| --- | --- | --- |
| sing-box `vless-ws-in` | `0.0.0.0:8443` TCP | **主力**：VLESS + WebSocket(`/ws`) + TLS（自签证书 CN=`localhost`，`/etc/ssl/singbox-ws/`），开着 multiplex。Cloudflare 回源到这里；**防火墙只放行 Cloudflare** |
| sing-box `vless-reality-in` | `0.0.0.0:443` TCP | VLESS Reality，握手目标 `dl.google.com`。IP 被墙，目前用户用不上 |
| sing-box `fwd-http-in` / `fwd-quic-in` | `80` TCP / `443` UDP | 转发到 Reality 握手目标，让探测看起来像真站 |
| sing-box `mixed-in` | `127.0.0.1:2080` | 本机自用 HTTP/SOCKS5（测试用） |
| cloudflared（systemd `cloudflared`） | 只出站 | Cloudflare Tunnel `vps-ssh`：`ssh.example.com` → `ssh://localhost:22`，**用户的 SSH 应急通道** |
| nftables 表 `inet cf8443` | —— | 8443 只接受 Cloudflare IP 段 + 本机回环，其余丢弃。`/usr/local/sbin/cf8443-firewall.sh update/apply/remove/status`；`cf8443-firewall.service` 开机加载，`cf8443-update.timer` 每周刷新 CF 段 |
| sshd | `22` | **只接受密钥**（10-08 起；`/etc/ssh/sshd_config.d/01-no-password.conf`）。公网机器人每天上万次猜密码，已全部无效 |

- sing-box：`/usr/local/bin/sing-box`，配置 `/etc/sing-box/config.json`（0600），systemd `sing-box`，历史备份 `config.json.bak.*`。
- 路由规则（自上而下）：`fwd-*` 入站 → direct；sniff；`geosite-cn` → reject；`geoip-cn` → reject；最终 direct。
  规则集是**本地文件** `/etc/sing-box/rules/{geosite,geoip}-cn.srs`（remote 规则集下载失败会让 sing-box 起不来）。
- 内核调优 `/etc/sysctl.d/99-singbox-tuning.conf`（BBR + fq）。ufw 没开；唯一的防火墙规则是上面那张 `inet cf8443` 表。
- 证书原 CN=`node.example.com`（会让直连者看到域名），10-08 换成 `localhost`；CF 用 SSL Full 模式不校验源站证书，名字随意，**别换回带域名的**。

## 三、用户是怎么连进来的（改错就会把用户锁在外面）

```
用户电脑 sing-box ──TLS──► Cloudflare 边缘 ──Origin Rule: ws.example.com 回源 8443──► vless-ws-in ──► 互联网
   入口：优选 IP 172.64.229.94 / .32（东京节点）或 ws.example.com，SNI/Host = ws.example.com
   （客户端用 urltest 自动择优；便携客户端还能在用户自己的网络上扫描优选 IP，所以各用户的入口 IP 可能不同）
```

- **日常 SSH**：用户电脑上的 sing-box 把发往 `<VPS_IP>:22` 的连接经上面这条线路送过来，由这里的 sing-box 连 `127.0.0.1:22`。
  所以 **vless-ws-in 挂了 = 用户境外上网和日常 SSH 一起断**。
  用户本机的 `sing-box-local` 和分发出去的便携客户端（SGProxy，Windows / mac）都带这条规则——
  **拿到便携客户端的人都能连到这里的 sshd 登录界面**——所以 sshd 只接受密钥（10-08 已关密码登录）。
  用户 Windows 上的 Claude 也是这样 SSH 进来的（日志里来源都是 `127.0.0.1`），它重启这里的 sing-box 时会话会断，
  所以它改服务端都用 `systemd-run` 脱离会话执行、写日志再回来读。
- **应急 SSH**：用户本地 `cloudflared access tcp` → Cloudflare Access（只放行用户邮箱）→ 本机 cloudflared → `localhost:22`。
  与 sing-box 无关，**sing-box 坏了时它是唯一的远程入口**。
- **最后保底**：华纳云网页 VNC 控制台（密码登录，不经 sshd）。
- Cloudflare 侧（DNS、Origin Rule、SSL 模式 Full、Access、隧道路由）只能在 CF 后台改，这里改不了。

## 四、改动规矩

1. **改 `/etc/sing-box/config.json` 前先备份**：`cp -p config.json config.json.bak.$(date +%Y%m%d%H%M%S)`。
2. **`sing-box check` 只校验格式，不保证能跑起来**（实例：`detour to an empty direct outbound` 能过 check、run 时 FATAL）。
   重启后必须确认 `systemctl is-active sing-box`；失败**立刻拷回备份并重启**。
   要验证运行时行为，用临时配置在别的端口起一个临时实例测，测完再动正式配置。
3. 改 vless-ws-in（端口、路径、TLS、multiplex、UUID）会直接影响所有客户端——**先和用户确认**，客户端配置在用户电脑上（`F:\vps\local\`、`F:\vps\portable\`），这里改不到。
   multiplex 不能关：客户端开着 h2mux，服务端一关客户端就连不上。
4. 不要停用、卸载、重装 `cloudflared` 服务，也不要动它的 Token。
5. 写脚本时 heredoc 可以用；只是不要在 sed/tr 模式里写 `\r` 字面量（用户那边传输时反斜杠曾被吞，`\r` 变成删字母 r），用 `CR=$'\015'`。

## 五、sing-box 1.14 的坑

| 坑 | 正确做法 |
| --- | --- |
| DNS server 必须带 `type` | `{"type":"tls","server":"8.8.8.8","tag":"..."}` |
| inbound 的 `sniff` 字段已删 | 用 route rule `{"action":"sniff"}` |
| DNS `detour` 指向空的 direct 会 FATAL | 去掉 detour，或让 direct 出站带上 `domain_resolver` |
| `direct` 出站缺 `domain_resolver` | 1.14 直接 FATAL；要么出站写，要么 `route.default_domain_resolver` |
| 单个 DNS server 上写 `strategy` | 不允许；放 `dns` 顶层，或写成 `"domain_resolver": {"server": "...", "strategy": "ipv4_only"}` |
| `sing-box generate` | 只有 uuid / reality-keypair / rand 等，没有 `generate config` |

权威字段定义：`https://sing-box.sagernet.org/schema.json`。

## 六、绝对不要做的事

- **不要打印、复制、上传 Reality 私钥和凭证**（`/etc/sing-box/config.json` 里的 `private_key`、`/root/.claude/.credentials.json`）。
  尤其不要发到 paste 服务——以前把整份 config 传到 paste.rs 过，私钥已视为可能泄露，计划换 IP 时一起轮换。
- **不要启用 ufw / iptables 默认拒绝**，除非先放行 443/TCP、443/UDP、80/TCP；8443 由 `inet cf8443` 表管，别另加规则挡住 Cloudflare。
- 不要删 `inet cf8443` 表或停用 `cf8443-firewall.service`（会重新暴露 8443）；改 vless-ws-in 端口时同步改脚本里的 `PORT=8443`。
  验证 8443 是否被挡要从**外部**测（本机连自己的公网 IP 走 lo，永远放行）。
- **不要删除或改写 `/etc/ssh/sshd_config.d/01-no-password.conf`**，不要重新打开密码登录。
  `authorized_keys` 现有两把：用户 Windows（`admin@DESKTOP-XXXXXXX`）和 Mac（`mac`）。动这个文件前先备份，
  并且**保持当前会话不断开、另开一个连接验证**还能登录。
- 不要在没有恢复手段的情况下重启 sing-box 或改网络配置。

## 七、待办（用户决定后再做）

1. 换一个**不同 /24 网段**的 IP（当前 IP 和之前的 `<OLD_VPS_IP>` 同段，都被墙），恢复 Reality 快路。
2. 换 IP 时轮换 Reality keypair / UUID / shortId（私钥只留在服务器，只把公钥、UUID、shortId 交给客户端）。
3. ~~8443 只放行 Cloudflare IP 段~~ ✅ 10-08 已完成（证书也换成了 CN=localhost）。
4. ~~关 SSH 密码登录~~ ✅ 10-08 已完成。root 密码（VNC 控制台用）由用户自己改。

## 八、其它

- Claude Code 本身：原生安装器装在 `/root/.local/share/claude/`，命令 `/root/.local/bin/claude`（PATH 在 `/root/.bashrc` 末尾），自动更新开着。
- 查服务：`systemctl status sing-box cloudflared`；`journalctl -u sing-box -n 50`；`ss -lntup`。

## 九、常见操作

**给新设备开通 SSH**：让用户在那台设备上 `ssh-keygen -t ed25519 -C "<名字>"`，把 `.pub` 那一行发来；
`cp -p /root/.ssh/authorized_keys{,.bak.$(date +%Y%m%d%H%M%S)}` 后追加，`ssh-keygen -lf` 回读指纹，让用户实测能登录。
告诉用户核对主机指纹：ED25519 `SHA256:<主机密钥指纹>`。

**换 IP 时要改的地方**（服务端配置本身不含 IP，监听都是 0.0.0.0；cloudflared 和 `inet cf8443` 表不受影响）：
1. Cloudflare DNS：`ws`（和 `node`）的 A 记录 → 新 IP（只能在 CF 后台改）。
2. 客户端里写死 `<VPS_IP>` 的两条规则（SSH 走 CF、该 IP 直连）和 Reality 出站的 `server`：
   用户电脑 `F:\vps\local\config*.json`、便携客户端四份模板，以及已发出去的便携客户端（要重新分发）。
3. 各客户端的 `known_hosts` 按 IP 记录主机指纹，换 IP 后首次连接会再问一次（主机密钥不变，指纹同上）。
4. 同时轮换 Reality keypair / UUID / shortId（见第七节）。

**今天的状态（10-09）**：sing-box、cloudflared、`cf8443-firewall` 全部正常；sshd 仅密钥；两把钥匙（Windows、Mac）都验证过。

