# 完整操作记录：从 SSH 到 CDN 双路代理

> 本文档记录本会话中所有实际执行的操作、验证结果、遇到的问题与结论。
> 所有数据均来自实际命令输出，非推测。日期以机器时间为准，跨 `2026-09-28` 至 `2026-10-08`。

## 目录

- [一、起点与环境](#一起点与环境)
- [二、远端：安装 sing-box](#二远端安装-sing-box)
- [三、远端：VLESS Reality 服务端](#三远端vless-reality-服务端)
- [四、本机：Windows 全局代理](#四本机windows-全局代理)
- [五、故障：浏览器无法联网](#五故障浏览器无法联网)
- [六、故障：IP 被墙](#六故障ip-被墙)
- [七、CDN 双路架构](#七cdn-双路架构)
- [八、传输通道的坑](#八传输通道的坑)
- [九、我犯的错误与更正](#九我犯的错误与更正)
- [十、文件清单](#十文件清单)
- [十一、速查表](#十一速查表)

---

## 一、起点与环境

### 1.1 初始请求

用户要求 `ssh 到 <OLD_VPS_IP>`，提供 `root` 账号和密码（密码已从文档移除，不再明文记录）。

### 1.2 本机环境探查结果

| 项目 | 结果 |
| --- | --- |
| OpenSSH | `C:\WINDOWS\System32\OpenSSH\ssh.exe`，无 `sshpass` |
| Python | `3.13.5`（`py -3.13`），`paramiko 5.0.0` 可用 |
| SSH 私钥 | `~/.ssh/id_rsa`（无密码） |
| `~/.ssh/config` | 无该主机条目，且**不可写**（沙箱限制） |
| `~/.ssh/known_hosts` | **不可写**（`Access is denied`） |
| 目标主机 | ping 不通但 TCP 22 通 |

### 1.3 建立的连接方式

`~/.ssh/known_hosts` 不可写，所以用**工作区内的独立 known_hosts**：

```cmd
ssh -i "%USERPROFILE%\.ssh\id_rsa" ^
    -o UserKnownHostsFile="F:\vps\.ssh_known_hosts" ^
    -o StrictHostKeyChecking=accept-new ^
    -o IdentitiesOnly=yes ^
    root@<host>
```

封装为 `F:\vps\ssh-vps.cmd`，并新增 `scp` 子命令。

用 paramiko 把本机公钥写入远端 `~/.ssh/authorized_keys`（`F:\vps\ssh_remote.py --install-key`），
实现免密登录（当时验证 `KEY_AUTH_OK`）。

### 1.4 远端初始状态

```
主机名  : <hostname>
系统    : Ubuntu 24.04.3 LTS / Linux 6.8.0-90-generic x86_64
规格    : 4 核 / 7.8 GiB 内存 / 系统盘 48G（已用 5%）
IP      : <OLD_VPS_IP>（Cloudflare trace 显示 colo=SIN，即新加坡）
端口    : 仅 22 监听
工具    : curl/wget/tar/gzip/jq 有，unzip 缺
网络    : GitHub 通（api.github.com 返回 200）
```

---

## 二、远端：安装 sing-box

### 2.1 版本与资产命名

- 最新稳定版：**v1.14.2**
- 该版本资产命名格式：`sing-box-<ver>-linux-<arch>-glibc.tar.gz`
  （不是旧的 `sing-box_<ver>_linux_<arch>.tar.gz`，我最初按旧格式请求得到 404）
- 官方**未发布** `.sha256` 资产，所以脚本跳过校验

### 2.2 安装脚本 `install.sh`

幂等设计，流程：

```
识别架构 → 拉取 releases/latest → 下载 tar.gz → 解压取二进制
→ 安装到 /usr/local/bin/sing-box
→ 停服务（为了下面能真跑，见 2.3）
→ 写入基线配置 → sing-box check（schema）
→ sing-box run 真跑一次（运行时校验）
→ 写 systemd unit → 启动 → 轮询确认 SubState=running
```

### 2.3 关键发现：`sing-box check` 不做运行时校验

`sing-box check` **只校验 schema**，通过后 `run` 仍可能 FATAL。实测反例：

```
check 通过，但 run 报:
FATAL start service: start dns/tls[google]: detour to an empty direct outbound makes no sense
```

而做运行时校验时 `run` 会**占用 2080 端口**，导致与正在运行的服务冲突：

```
FATAL start inbound/mixed[mixed-in]: listen tcp 127.0.0.1:2080: bind: address already in use
```

**解法**：校验前先 `systemctl stop sing-box`，校验完再启动。脚本已按此调整。

### 2.4 权限与自启

- `/usr/local/bin/sing-box`（0755）
- `/etc/sing-box/config.json`（0600）
- `sing-box.service`：`enabled` + `active`，`WantedBy=multi-user.target`
- 覆盖配置前自动备份为 `config.json.bak.<时间戳>`

### 2.5 内核调优

`/etc/sysctl.d/99-singbox-tuning.conf`：

```
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
```

**注意**：BBR 最初静默失效，原因见[第八节](#八传输通道的坑)（`bbr` 被改写成 `bb`，
而 `sysctl` 的报错被 `>/dev/null` 吞掉了）。

---

## 三、远端：VLESS Reality 服务端

### 3.1 前置探测

| 检查项 | 结果 |
| --- | --- |
| 443 端口 | 空闲 |
| ufw 防火墙 | inactive（无需放行） |
| 默认拥塞控制 | cubic（后改为 bbr） |
| 公网 IP | <OLD_VPS_IP> |

Reality 握手目标候选（要求 TLS1.3 + ALPN h2），6 个全部满足，
按**真实握手延迟**选优：

```
dl.google.com     connect 2ms   appconnect 48ms   http/2   ← 最低，选中
aws.amazon.com                         50ms        http/2
www.apple.com                          55ms        http/2
www.microsoft.com                      73ms        http/0（非 h2）
www.yahoo.com                          79ms        http/2
www.bing.com                          125ms        http/2
```

> **选目标的标准（事后补充）**：延迟不是主要标准。[XTLS/REALITY README](https://github.com/XTLS/REALITY)
> 的要求是"国外网站，支持 TLSv1.3 与 H2，域名非跳转用"，加分项是"IP 相近、Server Hello
> 后的握手消息一起加密（README 原文举例正是 `dl.google.com`）、有 OCSP Stapling"。
> 所以 `dl.google.com` 本身是合格的好目标，只缺"IP 相近"一项；要补这一项得在 VPS 上用
> [RealiTLScanner](https://github.com/XTLS/RealiTLScanner) 扫同网段，扫不到合格站点就继续用它。

### 3.2 生成的凭据

用 `sing-box generate reality-keypair` / `generate uuid` / `generate rand --hex 8`：

| 字段 | 值 |
| --- | --- |
| 地址 | `<OLD_VPS_IP>`（后改为 `<VPS_IP>`） |
| 端口 | `443` |
| UUID | `<UUID>` |
| Flow | `xtls-rprx-vision` |
| SNI / 握手目标 | `dl.google.com` |
| Fingerprint | `chrome` |
| PublicKey | `<REALITY_PUBLIC_KEY>` |
| shortId | `<SHORT_ID>` |
| PrivateKey | 只存于 `server-config-backup.json`，文档不再明文记录 |

### 3.3 服务端配置（最终形态）

`/etc/sing-box/config.json`，五个入站：

| tag | 类型 | 监听 | 用途 |
| --- | --- | --- | --- |
| `vless-reality-in` | vless + reality | `0.0.0.0:443` (TCP) | 直连快路 |
| `mixed-in` | mixed | `127.0.0.1:2080` | 本机自用 HTTP+SOCKS5 |
| `vless-ws-in` | vless + ws + tls | `0.0.0.0:8443` | CF 回源稳路（后加），已开 multiplex（7.8） |
| `fwd-http-in` | direct | `0.0.0.0:80` (TCP) | 转发到握手目标 `:80`（见 3.6） |
| `fwd-quic-in` | direct | `0.0.0.0:443` (UDP) | 转发到握手目标 `:443`（见 3.6） |

出站只有 `direct` 和 `block`；`route.final = direct`（服务端只做落地，不代理出去）。
路由规则（自上而下）：`fwd-*` 入站 → direct；sniff；`geosite-cn` → reject；`geoip-cn` → reject。

### 3.4 端到端验证

在本机（VPS）上用临时客户端配置做回环测试：

```
配置 schema 检查         : CHECK_OK
隧道出口 IP              : <OLD_VPS_IP>
geo                      : colo=SIN loc=SG
HTTP CONNECT 代理        : 200
SOCKS5 代理              : 200
```

### 3.5 1.14 的迁移坑（逐个踩过）

| 坑 | 报错 / 表现 | 正确做法 |
| --- | --- | --- |
| DNS server 必须带 `type` | `legacy DNS server formats are deprecated ... removed in 1.14.0` | `{"type":"tls","server":"8.8.8.8","tag":"..."}` |
| inbound 的 `sniff` 字段被删 | `legacy inbound fields are deprecated ... removed in 1.13.0` | 改用 route rule `{"action":"sniff"}` |
| DNS `detour` 不能指向空 direct | `detour to an empty direct outbound makes no sense` | 去掉 `detour`，或指向有内容的出站 |
| `generate config` 不存在 | 输出变成了帮助文本，被写进 config 导致 `invalid character 'G'` | `generate` 下只有 uuid/keypair/rand 等 |
| `route.default_http_client` 只接受字符串 | `cannot unmarshal object into Go struct field ... of type string` | 指向顶层 `http_clients` 里的 tag |
| `independent_cache` 已废弃 | `WARN ... deprecated in 1.14.0` | 不再使用 |
| `geolocation-cn.srs` 覆盖不足 | qq/taobao/jd 被误判走代理 | 用 `geosite/cn.srs`（446KB vs 27KB） |

权威字段定义来源：`https://sing-box.sagernet.org/schema.json`（`$defs` 下，
需要递归解引用 `$ref` 才能读）。

### 3.6 REALITY 配置加分项（`server-reality-camo.sh`，2026-10-08 部署）

REALITY README 的"配置加分项"是**禁回国流量，TCP/80、UDP/443 也转发**，此前两项都没做：
真 `dl.google.com` 会应答 80 和 HTTP/3，而本机这两个端口是关的，探测时对不上。

脚本做的事：

| 项 | 实现 |
| --- | --- |
| 禁回国 | 下载 MetaCubeX 的 `geosite/cn.srs` 与 `geoip/cn.srs` 到 `/etc/sing-box/rules/`，作为 **local** 规则集引用，sniff 之后 reject |
| TCP/80 转发 | `direct` 入站 `fwd-http-in`，`override_address` = 握手目标，端口 80 |
| UDP/443 转发 | `direct` 入站 `fwd-quic-in`，`override_address` = 握手目标，端口 = `handshake.server_port` |

设计要点：

- 规则集用**本地文件**而不是 remote：remote 规则集启动时下载失败会让 sing-box 起不来。
  下载失败时有旧文件就沿用，没有就跳过禁回国、只做转发。
- 转发规则**排在 sniff 和禁回国之前**：握手目标域名可能就在 `geosite-cn` 里，不能被误拦。
- 握手目标从 Reality 入站的 `handshake.server` 读，**换目标后重跑脚本即可同步**；重跑也是刷新规则集的方法。
- 先备份；`check` 失败或重启后不 active 会**真的还原备份**（老脚本只打印 restoring、并不还原，见 9.8）。
- 不含任何密钥、不打印私钥，所以可以走 paste 服务。Python 部分用 `python3 -c` 传入，
  当时是为了遵守"禁用 heredoc"；8.2 已查明 heredoc 无辜，这样写只是风格，不是必需。

部署方式（控制台每行 < 80 字符，带完整性校验）：

```bash
curl -so c.sh https://paste.rs/<短码>
sha256sum c.sh        # 与本地 sha256 对上才执行
bash c.sh
```

服务端实测（脚本第 6 步自检）：

```
tcp:80 / udp:443 / tcp:443 / tcp:8443   全部由 sing-box 监听
tcp/80 forward : 302   (direct to dl.google.com: 302)   ← 与真站一致
block by domain: 000   (baidu.com，经服务端 2080)
block by IP    : 000   (223.5.5.5)
abroad allowed : 204   (gstatic generate_204)
RESULT_OK
```

UDP/443 只确认了监听（服务端 curl 不支持 HTTP/3）。验证转发通路：
`echo hi > /dev/udp/127.0.0.1/443` 后 `journalctl -u sing-box -n 20 | grep fwd-quic`，
应看到 `connection to dl.google.com:443`。改动前的配置：`/etc/sing-box/config.json.bak.20261008130600`。

---

## 四、本机：Windows 全局代理

### 4.1 本机 sing-box 部署

用户本机已有 `D:\GUI.for.SingBox.exe`（GUI），其 core **无法工作** —— 见 4.4。

于是下载官方 Windows 版自建：

| 项目 | 路径 |
| --- | --- |
| Core | `F:\vps\local\core\sing-box-1.14.2-windows-amd64\sing-box.exe` |
| 配置（TUN） | `F:\vps\local\config-tun.json` |
| 配置（纯代理） | `F:\vps\local\config.json` |
| 启动脚本 | `F:\vps\local\run-singbox.ps1` |
| 日志 | `F:\vps\local\run.log` / `console.log` |

**下载方式**：本机 `curl` 因 schannel 凭据问题失败
（`SEC_E_NO_CREDENTIALS`），改由 VPS 下载再 scp 回本机（32MB，SHA256 双向一致）。

### 4.2 计划任务（持久化 + 管理员权限）

问题是**沙箱/工具调用结束后子进程被回收**，所以用 Windows 计划任务：

```
任务名    : sing-box-local
触发      : AtLogOn
RunLevel  : Highest（TUN 需要管理员）
执行      : pwsh -NoProfile -File F:\vps\local\run-singbox.ps1
工作目录  : F:\vps\local
```

**踩坑**：`RunLevel Highest` 注册本身需要管理员令牌，沙箱提权给不了；
最终用 `Start-Process -Verb RunAs` 弹 UAC 让用户确认，在提权进程里注册成功。

TUN 能力验证（提权后）：

```
process alive : True
tun adapter   : singbox-tun / Up / sing-tun Tunnel
port 2080     : LISTENING
```

### 4.3 发现：TUN 必须管理员

首次试跑（非管理员）：

```
FATAL start service: start inbound/tun[tun-in]: configure tun interface: Access is denied.
```

于是提供两种配置：

| 配置 | 模式 | 需要管理员 |
| --- | --- | --- |
| `config-tun.json` | TUN 全局 | 是 |
| `config.json` | 仅 `127.0.0.1:2080` | 否 |

### 4.4 用户 GUI 配置无法工作的原因

`D:\myProxy.json` 有 3 个致命问题（所以它的 core 起来了却一个端口都没监听）：

1. **`routing` 键已移除**（1.11 废弃 → 1.14 删除），必须是 `route`
2. **`"final": "🐟 Fallback"` 指向不存在的出站**（fallback 出站是 GUI 运行时注入的，脱离 GUI 就报错）
3. 已删字段：DNS server 的 `address`、`geolocation`、`geoip` 规则集

### 4.5 分流设计（客户端）

```
DNS：geosite-cn → 本地 DNS 直连；其余 → 加密 DNS 走代理
路由（自上而下，首个匹配生效）：
  1. sniff                解析真实域名
  2. DNS 查询             hijack-dns
  3. 节点 IP /32          direct（防止回源流量绕回 TUN）
  4. 私有 IP              direct
  5. geosite-cn 域名      direct
  6. geoip-cn  IP         direct
  7. 其余                 proxy
```

规则集用 **MetaCubeX 官方 `.srs`**，走 jsDelivr，每 3 天自动更新：

| tag | URL | 大小 |
| --- | --- | --- |
| `geosite-cn` | `.../geo/geosite/cn.srs` | 446 KB |
| `geoip-cn` | `.../geo/geoip/cn.srs` | 36 KB |

实测分流（debug 日志逐条确认）：

```
baidu / qq / taobao / jd  → direct
google / github / youtube → proxy
```

### 4.6 关键修复：DNS 污染 → fake-ip

**症状**：TUN 模式下国内正常，`google.com`/`youtube.com` 全部 TLS EOF 失败，
但**显式走 2080 代理时同样域名完全正常**。

**根因**（日志实锤）：

```
dns: cached A www.google.com. 542 IN A 104.244.42.197
```

`104.244.42.197` 是 **Twitter 网段**，不是 Google 的 IP —— 典型 DNS 污染。
本机 DNS 是 `<运营商 DNS>`（本地运营商）。虽然 `singbox-tun` 网卡已绑定 DNS `172.19.0.2`，
但 TUN 与 WLAN 的默认路由度量都是 0，Windows 仍走了 WLAN 的 DNS。
拿到污染 IP 后，sing-box 只看到 IP，**域名分流彻底失效**。

**解法 fake-ip**：境外域名统一返回 `198.18.x.x` 合成地址，由 sing-box 反查域名：

```json
"dns": {
  "servers": [
    { "tag": "dns-local",  "type": "local" },
    { "tag": "dns-fakeip", "type": "fakeip",
      "inet4_range": "198.18.0.0/15", "inet6_range": "fc00::/18" },
    { "tag": "dns-remote", "type": "https", "server": "1.1.1.1",
      "detour": "proxy", "domain_resolver": "dns-local" }
  ],
  "rules": [
    { "rule_set": ["geosite-cn"], "server": "dns-local" },
    { "query_type": ["A", "AAAA"], "server": "dns-fakeip" }
  ],
  "final": "dns-remote",
  "strategy": "prefer_ipv4"
}
```

修复后：`google -> 198.18.0.6`（合成），`baidu -> 180.101.49.44`（真实），
`google`/`youtube` 立刻恢复。

> 旁证：`generativelanguage.googleapis.com` 在修复前就能通 ——
> 因为它恰好没被污染、拿到了真实 Google IP。这解释了"为什么只有部分域名失败"。

### 4.7 fake-ip 映射跨重启保留（`store_fakeip`，2026-10-08）

**症状**：每次重启代理后，日志刷出一批
`router: missing fakeip record, try enable experimental.cache_file`，相关连接失败一阵才恢复。

**原因**：fake-ip 的"合成地址 ↔ 域名"映射表默认只在内存里。重启前已经拿到 `198.18.x.x` 的程序
（浏览器、系统 DNS 缓存）重启后还在用旧地址，sing-box 查不到对应域名。

**修复**：`cache_file` 原本就开着，加一项即可（`config-tun.json` / `config.json`，旧版 `*.pre-fakeip`；
`client-split.json` 不用 fake-ip，未改）：

```json
"experimental": {
  "cache_file": {
    "enabled": true,
    "path": "F:/vps/local/cache.db",
    "store_fakeip": true
  }
}
```

**验证**：拿到 `www.google.com → 198.18.0.8`，等 25 秒后强制重启；重启后直连旧地址 204，
重新解析仍是 `198.18.0.8`，`missing fakeip` 报错 0 条。

**机制与坑**（读 sing-box v1.14.2 源码 `dns/transport/fakeip/store.go`、`experimental/cachefile/fakeip.go`）：

| 数据 | 何时写盘 |
| --- | --- |
| 映射记录（地址 ↔ 域名） | 每次分配新地址时**同步**写入 |
| 元数据（分配到哪个地址了） | 分配新地址后**防抖 10 秒**（`FakeIPMetadataSaveInterval`）才写；正常退出时同步写 |

- 启动时读取元数据会**顺手把它从磁盘删掉**；读不到元数据（或地址段变了）就**清空整个缓存**、从头分配。
- 所以**最后一次分配新地址后 10 秒内被强制结束**，元数据还没写盘，下次启动缓存被清空，等于没开。
  计划任务的 `/End` 和 `Stop-Process -Force` 都是强制结束，不走正常退出。日常用着用着重启很少碰上，未做处理。
- 第一次验证就踩了这个坑：拿到地址后约 5 秒就重启，结果旧地址失效，一度误以为 `store_fakeip` 不起作用。
  **测这个功能必须等 10 秒以上再重启。**
  （那次测试的时间段 14:01–14:06 恰好另有人在改配置、手动重启代理（见 4.8），结果也受了干扰；
  上面的验证是在无人改动时重测的，可靠。）

### 4.8 出站服务器的专用解析器 `dns-dial`（2026-10-08，加固）

**改动**（14:05，另一个助手所做，备份 `*.pre-ipfix`；14:01 的 `*.pre-ipv6fix` 是它改之前的版本）：

```json
{ "tag": "dns-dial", "type": "udp", "server": "223.5.5.5", "detour": "direct" }
```

`proxy-ws` / `proxy-reality` / `direct` 三个出站的 `domain_resolver` 由 `dns-local` 改为 `dns-dial`。
`config-tun.json` 与 `config.json` 相同。

**定性：加固，不是修故障。** 出站服务器的域名（`ws.example.com`）改由一个用 IP 指定的解析器解析，
不再依赖系统 DNS 的状态，原则正确，**保留**。代价：阿里 DNS 能看到对节点域名的明文查询，
直连流量的域名解析也改由它负责；原先用系统 DNS 时运营商同样可见，不算新增风险。

**对方给的原因（"DNS 死环"）不成立**，记下以免以后照着误判：

| 说法 | 实际 |
| --- | --- |
| `domain_resolver` 指向 `type: local` 时，查询经 TUN 回到 fake-ip，形成死环 | 原配置用 `dns-local` 从 11:31 跑到 14:01，期间 A/B 测试、多次重启、测速全部正常。Windows 实际用 WLAN 的 DNS，不经 TUN（4.6） |
| fake-ip 返回 `198.18.x`，于是日志报 `lookup …: NXDOMAIN` | 自相矛盾：fake-ip 返回合成地址，失败也该是连接失败；fake-ip 不会返回 NXDOMAIN |
| `198.18.0.x` 不在任何路由表 | `auto_route` 正是把 `198.18.0.0/15` 路由进 TUN |
| `strategy` 只能放在 `dns` 顶层 | 单个出站可写 `"domain_resolver": {"server": "dns-dial", "strategy": "ipv4_only"}`，1.14.2 实测 `check` 通过 |
| 403 = `server` 写成了 IP | 仅当没设 Host 头时：WS 默认拿 `server` 当 Host，CF 不知转给哪个站。做优选 IP 时设 Host 为 `ws.example.com` 即可 |

- 按对方自述，故障出现在它把 `strategy` 改成 `ipv4_only` **之后**，更可能是这次尝试本身导致的。
  当时的 run.log 已被下次启动覆盖，**无法核实**（这也是改日志轮转的原因，见 4.9）。
- 唯一留下的痕迹是 console.log 里的 `dns.servers[0].strategy: json: unknown field "strategy"`：
  **单个 DNS 服务器上不能写 `strategy`**，这一点对方说得对。
- `network is unreachable`（IPv6）是 VPS 没有 IPv6 的无害噪声，这一点也对。
- ⚠️ 对方的示例配置里写着 `"insecure": true`，**不要照抄**，会撤销 7.4 的 TLS 修复。实际配置未被改动（已核对）。
- `direct` 出站必须带 `domain_resolver`：1.14 里去掉它，启动直接 FATAL（`missing domain_resolver ... removed in 1.14.0`）。

### 4.9 run.log 按会话保留（2026-10-08）

sing-box 每次启动会把 `log.output`（`run.log`）**从头写**，`check` 也会，于是重启一次就丢掉上次的日志，
4.8 的故障因此无从查证。`run-singbox.ps1` 改为在 `check` **之前**先把旧 `run.log` 移到
`F:\vps\local\logs\run-<上次最后写入时间>.log`，保留最新 30 份，空日志不轮转，移动记录写进 `console.log`。
已在临时目录演练（33 份旧日志 → 保留 30，命名、空文件跳过均正确）；15:12 重启时实际生效，
生成 `logs\run-20261008-151209.log`。

### 4.10 SSH 走 CF 线路（2026-10-08）

源站 IP 被墙后，FinalShell 直连 `<VPS_IP>:22` 超时（日志 `dial tcp <VPS_IP>:22: i/o timeout`）；
原有规则 `ip_cidr <VPS_IP>/32 → direct` 也让它绕不开。在那条规则**之前**插入：

```json
{ "ip_cidr": ["<VPS_IP>/32"], "port": [22],
  "action": "route", "outbound": "proxy-ws", "override_address": "127.0.0.1" }
```

- 连接经 CF 线路到达 VPS 后，由服务端 sing-box 连 **`127.0.0.1:22`**（目标改写），不依赖 VPS 能否回连自己的公网 IP。
- FinalShell 配置**不用改**，照样连 `<VPS_IP>:22`（TUN 接管；纯代理模式下给 FinalShell 设 SOCKS5 `127.0.0.1:2080` 也走同一规则）。
- 只加在本机 `config-tun.json` / `config.json`（备份 `*.pre-ssh`）；**便携客户端不加**，别人不该能连到 sshd。
- 实测：读 SSH banner `SSH-2.0-OpenSSH_9.6p1 Ubuntu` 约 1.1 秒。**代理刚重启后第一次可能失败**（隧道还在建立），再连一次即可。
- 局限：依赖服务端 sing-box 正常。sing-box 配置改坏时 SSH 也一起断——独立管理通道见 `CF-TUNNEL-SSH.md`。
- **换 IP 后**这条规则里的 IP 要跟着改。

### 4.11 `ssh.example.com` 直连（2026-10-08）

Cloudflare Tunnel 管理通道（`CF-TUNNEL-SSH.md`）打通后，本机 `cloudflared access tcp` 连 `ssh.example.com`
原本被当作境外域名送进 CF 线路，绕了两圈 CF（本机 → CF → VPS → CF → 隧道 → VPS），而且依赖 sing-box。
加两条规则（`config-tun.json` / `config.json`，备份 `*.pre-sshdirect`）：

```json
"dns":   { "rules": [ { "domain": ["ssh.example.com"], "server": "dns-local" }, … ] }
"route": { "rules": [ sniff, hijack-dns, { "domain": ["ssh.example.com"], "outbound": "direct" }, … ] }
```

- DNS 规则放在 fake-ip 兜底之前：拿真实 CF IP，不依赖 fake-ip 映射。
- 实测：解析为真实 CF 地址；连接全部走 `direct`；SSH banner 4.7–12.9s → **2.1–2.4s**，完整登录 9.4–17.1s → **7.4–11.4s**。
- 这条管理通道从此不依赖 sing-box：sing-box 正常时它走直连，sing-box 停了 TUN 消失也是直连。
- ⚠️ 当时在本机用 `Start-Process` 开着的那个 `cloudflared access tcp`（PID 25688）后来**退出了**：
  它是从 Claude 的工具会话里启动的，会话回收子进程时一起被结束（同 4.2「子进程被回收」）。
  本机需要应急通道时手动运行下面这条命令，或者用便携客户端的「SSH 应急通道」（4.12，不用点「启动」）：
  `& 'D:\Tools\cloudflared\cloudflared.exe' access tcp --hostname ssh.example.com --url 127.0.0.1:2222`

### 4.12 便携客户端：优选 IP、直连网址、SSH 应急通道（2026-10-08）

`F:\vps\portable\` 的 Windows 版（`SGProxy\`）和 mac 版（`SGProxy-mac\`，打包为 `SGProxy-mac.zip`）。
改动前备份：`portable\_backup-20261008-pre-cf\`（加 CF 线路前）、`portable\_backup-20261008-pre-cfip-ssh\`（本次前），都在发布目录之外。

| 功能 | 做法 |
| --- | --- |
| 优选 IP | 四份模板由 `patch-client-config.py` 重新生成，结构同 7.9（`proxy-cf` urltest：东京 IP ×2 + 域名兜底） |
| 直连网址 | 模板的 DNS 规则（→ `dns-local`）和路由规则（→ `direct`）各有 `domain_suffix: ["ssh.example.com", "sgproxy-direct.invalid"]`；启动时把用户列表展开到占位符前。Windows：`config\direct.txt`，PowerShell 字符串替换；mac：列表在 `~/Library/Application Support/SGProxy/direct`，启动前同步到 `ctl/direct`，root 后台组件用 sed 展开 |
| SSH 应急通道 | 打包 cloudflared 2026.10.0（Windows `core\cloudflared.exe`；mac `Resources/core/cloudflared`，arm64，SHA256 均与 GitHub 一致），界面开关运行 `access tcp --hostname ssh.example.com --url 127.0.0.1:2222`；与代理是否运行无关 |

- **为什么不用 sing-box 开 2222**：那条路要经过服务端 sing-box，代理挂了它也挂；Tunnel 两端都不经 sing-box。
  且 Access 只放行主人邮箱，别人拿到便携客户端也进不了 sshd。
- 输入解析：完整网址 / `*.` 前缀 / 端口 / `user@` 都会剥掉，只留主机名；拒绝 IP、`localhost`、非法字符。
  Windows 支持中文域名（转 punycode）；mac 不支持（没有现成的 punycode 工具）。
- mac 后台组件是 root、`ctl/` 是用户可写：只读普通文件（拒绝符号链接），每行只认 `a-z0-9.-`，引号/斜杠/大写等一律丢弃。
- 两个启动器原本对所有 `listen_port` 做替换——只要模板里只有代理一个监听口就没问题，**以后加别的监听口要先改这里**。
- 测试：PowerShell 5.1 解析无错；解析函数 14 种输入；直连展开后两种模式 `check` 通过；SSH 通道在 2223 上两次读到 banner（2.7 s），2222 被占用时正确报错。
  mac：`bash -n`、`norm_host` 14 种输入（含注入）、helper 展开含恶意行的列表后 `check` 通过；**未在真机运行**。
- mac `VERSION` 升到 1.2（`SGProxy-mac 1.2 sing-box-1.14.2 06909e199b972045`），已装过的 Mac 打开时会提示更新后台组件。

**补充（同日稍晚）：与本机 `sing-box-local` 功能对齐 + 扫描优选 IP**（改前备份 `portable\_backup-20261008-pre-scan\`）

| 项 | 做法 |
| --- | --- |
| SSH 走 CF 线路 | 四份模板加入 4.10 那条规则（`<VPS_IP>:22` → `proxy-cf`，改写成 `127.0.0.1`）。用便携版时 FinalShell 照常连 `<VPS_IP>:22`。此前不加是怕别人能连到 sshd 登录界面；用户决定加上，**因此关 SSH 密码登录更要紧**（CF-TUNNEL-SSH.md 第 7 步） |
| 日志按会话保留 | 改为保留最近 10 次（Windows `data\logs\`，mac `run/logs/`）。顺带修了一个原有 bug：两版都是先跑 `sing-box check` 再把 `run.log` 改名为 `.old`，而 `check` 一启动就清空 `run.log`，所以「上次的日志」其实从没保住过；现在轮转放在 `check` 之前 |
| 扫描优选 IP | Windows：后台 Job 里用 .NET 并发连 ~350 个抽样 IP（每段最多 40 个），前 20 个各做 3 次 TCP+TLS（SNI `ws.example.com`）+ `/cdn-cgi/trace` 读 PoP，按「TCP+TLS 中位数」排序；自动找物理网卡绑定，绕开本机任何 TUN。mac：`scan-probe.sh` 用系统 `curl`，`xargs -P 48` 并发，前 12 个再测两次取平均。**只在代理停止时允许扫描**（否则测的是经代理的延迟）。结果列出与默认入口（按域名）的对比，用户确认才采用 |
| 采用后 | Windows `config\preferred.txt`；mac `~/Library/Application Support/SGProxy/preferred` → 启动前同步到 `ctl/preferred`。启动时替换模板里的两个默认 IP（先换成占位符再换成值，避免两个 IP 顺序互换时串位）；严格校验 IPv4（每段 ≤255，mac 后台组件只取每行第一个字段、拒绝符号链接）；「恢复默认」删掉结果文件 |

- 实测（便携版 TUN 开着、绑物理网卡）：Windows 49 s，抽样 350、有响应 99，第一名东京 `172.64.229.32`（TCP 36 + TLS 46 ms）；mac 流程在 Git Bash 里 24 s，抽样 350、可用 64，第一名同为 `.32`（51 + 61 ms）。
  同一时段新加坡段 `172.64.144.229` 的 TLS 只要 85 ms——下午测时被拖到 0.3–1.4 s，**线路状况随时间变**，这正是让用户自己扫的理由。
- 测试时「默认入口（按域名）」测不出：便携版 TUN 开着，系统 DNS 返回 fake-ip，绑物理网卡连不上。正式使用只在代理停止时扫描，不受影响。
- 便携版界面（Windows）：主按钮行加「扫描优选 IP」「恢复默认」；节点标签在采用了扫描结果时显示所用 IP。mac：菜单项「优选 IP」。
- mac `VERSION` 升到 1.3（`SGProxy-mac 1.3 sing-box-1.14.2 948db9e990f06c94`），zip 已重打（48.9 MB）。**未在真机运行**。

**Windows 便携版真机验证（18:30–18:40，用户在本机以管理员身份运行便携版，`sing-box-local` 当时没在跑）**：

| 项 | 结果 |
| --- | --- |
| SSH 走 CF 线路 | 加规则前 `<VPS_IP>:22` 被重置（`kex_exchange_identification: Connection reset`）；重启便携版后 banner 0.73–0.74 s |
| 日志保留 | `data\logs\run-20261008-183246.log`、`…183422.log` 依次生成 |
| 扫描（界面里点） | 抽样 350、107 个有响应；**默认入口（按域名）AMS TCP 201 + TLS 210 ms**；第一 `172.64.229.94` NRT 41 + 51 ms，第二 `172.64.229.32` NRT 56 + 95 ms，其后都是 LAX（~145 + 155 ms）。最快两个恰好就是模板默认值；用户选了「是」，`config\preferred.txt` 写入同样两个 IP |
| 采用后 | 运行配置入口 `.94 / .32 / 域名`；36 个连接走 `proxy-ws-nrt1`（另两个各 3 次是 urltest 探测）；Google 0.36 s、GitHub 1.6 s、百度 79 ms |
| 节点标签 | 采用扫描结果后原文案 + IP 需 727 px，标签只有 600 px，被**静默截断**（显示到 `172.64.22`）。改为有扫描结果时换短文案（543 px）、`AutoEllipsis` + 悬停提示全文、标签随窗口伸缩；重开后用户确认显示完整 |

- 测得「按域名」那一行要求代理停止（DNS 拿真实地址）；之前开着 TUN 测时这一行为空，属预期。
- 选「是」与默认相同时效果一样，区别只在：以后客户端更新默认 IP，已有 `preferred.txt` 的用户仍用自己的扫描结果，点「恢复默认」才跟随。

---

## 五、故障：浏览器无法联网

**症状**：TUN 跑得好好的，命令行/Python 测试全部正常，但**浏览器打不开网页**，
而且日志里**完全看不到浏览器的流量**。

**根因**：`GUI.for.SingBox` 运行时给系统设了 WinINET 代理 `127.0.0.1:20122`，
**但它退出时没清理**。Chrome 默认读系统代理，于是把所有请求发给这个**没人监听的端口**：

```
HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings
  ProxyEnable = 1
  ProxyServer = 127.0.0.1:20122     ← 无进程监听，连接被积极拒绝
```

**为什么命令行测试发现不了**：我用的 `ProxyHandler({})` / curl 显式指定不走代理，
**绕过了这个坏设置**；浏览器老实听系统的。

**修复**（`fix-proxy.ps1`）：

1. `ProxyEnable = 0`，删除 `ProxyServer`
2. 用 `wininet.dll` 的 `InternetSetOption` 发 `SETTINGS_CHANGED` + `REFRESH`，
   让**已打开的浏览器无需重启**就重读设置

修复后日志里立刻出现浏览器的真实请求（`api.anthropic.com`），确认恢复。

**结论**：走 TUN 时系统代理必须关闭 —— TUN 在网卡层接管全部流量，
系统代理是多余的一层，指向死端口就会让浏览器彻底断网。

---

## 六、故障：IP 被墙

### 6.1 判定方法

用**双侧对照**：本机视角 + 外部多节点视角（check-host.net）。

#### 第一轮：`<OLD_VPS_IP>`

```
本机   : 443 TCP 可连，但 TLS 握手被 RST（三次全失败）
外部   : 5 国节点（塞浦路斯/德国/匈牙利/葡萄牙/乌克兰）全部连通，156~258ms
对照   : cloudflare.com / microsoft.com / apple.com 同样被 RST
```

症状：**TCP 能连、数据即被重置**。

> **更正**：这一轮的对照组（cloudflare/microsoft/apple）**同样被 RST**，说明当时是本机侧的问题
> （很可能 TUN 正在切换），这组数据**区分不出**是不是该 IP 被封，不能作为证据。
> 能支撑"14 被封"的是后来的直连对照：`新 IP:443 OK TLSv1.3` / `旧 IP:443 RESET`（见 9.3）。
> 外部节点能连只说明服务器在线，不说明大陆可达性。

#### 第二轮：`<VPS_IP>`（用户换的新 IP）

```
本机   : 22/443 全部 TCP 超时，ICMP 无回应
外部   : 7/8 节点连通（德/伊朗/哈/土/乌/美/越），165~275ms
对照   : cloudflare.com 正常，github.com 超时
```

症状恶化：从 `RESET` 变成 **`Timeout`（黑洞丢包）**，说明是 IP 级封锁。

### 6.2 结论

两个 IP 都被墙。**问题不在服务器**（服务一直 active、配置未变），
而在**中国大陆到该 IP 的链路**。

两个 IP 在**同一个 /24**（`同一 /24 网段`），小厂 VPS 整段被拉黑很常见。换 IP 时要明确要求
**不同网段**；只能给同段就该考虑换商家，否则大概率再被封。

外部探测证据可直接用于向客服申诉（见会话中的客服话术草稿）。

---

## 七、CDN 双路架构

### 7.1 目标

CDN 方案把**源站 IP 从公网视野隐藏**：客户端只连 Cloudflare 的共享边缘 IP，
CF 从自己的网络回源。源站 IP 再被封也不影响使用。

**关键优势**：CF 回源是**从 CF 的网络发起**的，不需要从大陆访问源站 IP，
所以**源站已被封的情况下也能立即跑起来**。

### 7.2 域名与 Cloudflare 配置

| 项目 | 值 |
| --- | --- |
| 域名 | `example.com`（阿里云注册） |
| NS | `<ns1>.ns.cloudflare.com` / `<ns2>.ns.cloudflare.com` |
| 边缘证书 | Universal SSL，SAN = `*.example.com, example.com`（自动覆盖 `node` 子域） |
| `node` 记录 | A → `<VPS_IP>`，🟠 Proxied（**实际未被使用**，见 9.6；别改成灰云，会暴露源站 IP） |
| `ws` 记录 | A → `<VPS_IP>`，🟠 Proxied |
| Origin Rule | Hostname = `ws.example.com` → **Destination Port 改写为 8443** |
| SSL/TLS 模式 | **Full** |
| DNSSEC | 未启用（外部验证：权威区无 DNSKEY，注册局无 DS） |

**为什么需要 Origin Rule**：CF 的回源端口默认 443，而 443 被 Reality 占用。
Reality 按 SNI 处理，会把 CF 的普通 HTTP 探测**转发给 `dl.google.com`**
（表现为返回 Google 的 301/404）—— 这正是我一度误判"服务端故障"的原因。

**为什么不能用 `SSL/TLS → Origin Server` 端口设置**：那是**整个 zone 一份**的，
不能按 hostname 区分，用了会连带影响 Reality。必须用 Origin Rules。

### 7.3 服务端新增 WS 入站

```json
{
  "type": "vless",
  "tag": "vless-ws-in",
  "listen": "0.0.0.0",
  "listen_port": 8443,
  "users": [{ "name": "ws", "uuid": "<UUID>" }],
  "transport": { "type": "ws", "path": "/ws" },
  "tls": {
    "enabled": true,
    "server_name": "node.example.com",
    "certificate_path": "/etc/ssl/singbox-ws/cert.pem",
    "key_path": "/etc/ssl/singbox-ws/key.pem"
  }
}
```

- 证书**自签**（10 年），配合 CF 的 `Full` 模式。原 CN=`node.example.com`，**10-08 已换成 CN=`localhost`**（7.10）
  —— 加密回源但 CF 不校验证书，无需 Let's Encrypt / Origin Certificate 流程
- **复用与 Reality 相同的 UUID**，客户端不用改 UUID
- 端口变更（2053 → 8443）由 `server-ws-8443.sh` 完成

服务端自测结果：`ws probe http_code=101` —— **WebSocket 升级成功**（最理想）。

### 7.4 客户端双路 + selector

```
proxy (selector) → [proxy-ws, proxy-reality]   default = proxy-ws
   ├─ proxy-ws      : ws.example.com:443  WS /ws  SNI=ws.example.com（校验 CF 证书）
   └─ proxy-reality : <VPS_IP>:443     Reality
```

- `proxy` 这个 tag **保留给 selector**，让原有的 DNS `detour: "proxy"` 继续有效
- Reality 出站重命名为 `proxy-reality`，`server` 是**裸 IP**（Reality 不能穿过 CF）
- `proxy-ws` 的 TLS：`server_name: ws.example.com`，**不设 `insecure`**，校验 CF 边缘的 Universal SSL 证书。
  **2026-10-08 已改正**（原先是 `node.example.com` + `insecure: true`，理由写反了，见 9.5）。
  改动覆盖 `config-tun.json` / `config.json` / `client-split.json` 和生成脚本，旧版备份为 `*.pre-sni`。
  验证：改前在 TUN 之外 A/B 对照，新写法 5/5 返回 204、无证书错误、延迟与旧写法相同；
  重启后经 TUN 与经 2080 出口均为 `<VPS_IP>`，境外 204/200/200，国内 84–88ms。

生成脚本：`patch-client-config.py`（幂等）。

### 7.5 端到端验收（CF 路）

```
出口 IP（经 TUN 全局）  : <VPS_IP>
出口 IP（经 2080 代理） : <VPS_IP>
国内 baidu/taobao/qq    : 200 / 200 / 200
境外 google/github/yt/x : 204 / 200 / 200 / 200
WebSocket 升级          : HTTP/1.1 101 Switching Protocols（三次全 101）
```

### 7.6 性能实测：CF 路可用但慢

20 次采样：

```
TLS 握手到 CF 边缘     :  最小 2058ms  中位 2730ms  最大 6703ms  成功 20/20
国内直连同样操作       :  202~247ms
```

**逐段定位瓶颈**：

| 环节 | 耗时 | 判断 |
| --- | --- | --- |
| TCP 连接 CF 边缘 | 2~26ms | 正常 |
| **TLS 握手 CF 边缘** | **~2.7s** | ← 瓶颈 |
| CF 边缘内部（`cfEdge`） | 15ms | 很快 |
| CF → 源站（`cfOrigin`） | 140ms | 很快 |
| CF 边缘 POP | 当时记为 `HKG`；**10-08 下午从本机网卡直测为 `AMS`（阿姆斯特丹）**，见 7.9 | — |

**CF 服务端侧毫无问题**，慢在**中国大陆 → CF 边缘**这段（TLS 握手被限速/高丢包）。按域名默认落在阿姆斯特丹（7.9）。

**HTTP/3（QUIC）也走不通**：UDP/443 到 CF 边缘**全部超时**
（对照：国内 UDP/53 13ms 正常），说明 UDP 出境被阻断。

**结论**：CF 路是**能用的兜底**（20/20 稳定），但每建连接 2-3 秒，
网页首屏明显卡顿，**不适合当主力**。

### 7.7 SSL/TLS 模式辨析

| 模式 | 含义 | 是否选用 |
| --- | --- | --- |
| Flexible | 明文回源 | 不推荐 |
| **Full** | 加密回源但不校验证书 | ✅ **选用**（匹配自签证书） |
| Full (strict) | 校验证书 | ❌ 会因自签证书报 526 |

### 7.8 多路复用（multiplex）—— ✅ 2026-10-08 已启用

**目的**：CF 路每建一个连接要 2-3 秒 TLS 握手（7.6）。开 multiplex 后客户端维持少量隧道，
请求作为流跑在隧道里，握手成本按隧道付一次，而不是每个请求付一次。

**顺序不能反：先服务端，后客户端。** 本地实测（1.14.2，脚本里的 Python 原样抽出来跑）：

| | 普通客户端 | mux 客户端 |
| --- | --- | --- |
| 服务端未开 multiplex | 204 ×3 | **000 ×3（断）** |
| 服务端已开 multiplex | 204 ×3 | 204 ×3 |

服务端开了照样接受普通客户端，所以先部署服务端是零风险；反过来先改客户端，CF 路立刻断
（本机流量全走这条路，连带断网）。

| 侧 | 配置 |
| --- | --- |
| 服务端 `vless-ws-in` | `"multiplex": {"enabled": true}` |
| 客户端 `proxy-ws` | `"multiplex": {"enabled": true, "protocol": "h2mux", "max_connections": 4, "min_streams": 4}` |

客户端参数含义：已有隧道里的流达到 4 个才开新隧道，最多 4 条。不只开 1 条，是因为大陆→CF 边缘丢包高，
单条 TCP 上所有流会被队头阻塞拖住。WS 路没有 vision flow，与 multiplex 不冲突（Reality 路不开）。

`server-ws-mux.sh`：备份 → 加 multiplex → check → 重启（失败自动还原）→ 在服务端起普通 / mux
两个临时客户端各测 3 次 `generate_204`，任一失败也自动还原。看到 `RESULT_OK` 后再改客户端。

**部署记录**：服务端经 paste.rs + `curl -so` 下载（SHA256 一致）执行，`RESULT_OK`；paste 已删除。
客户端由 `patch-client-config.py` 加入 `WS_MUX`，覆盖 `config-tun.json` / `config.json` / `client-split.json`，
旧版备份 `*.pre-mux`；`server-config-backup.json` 同步（旧版 `.pre-mux`）。

**实测（真实 CF 路径，TUN 之外的独立实例，8 个境外站）**：

| 场景 | 不开 mux | mux 4×4 | mux 8×2 |
| --- | --- | --- | --- |
| 依次访问（每次新连接） | 59.1s | **20.6s** | 36.3s |
| 同时访问，3 轮 | 9.6 / 8.7 / 12.8s | 13.0 / 11.4 / 8.8s | 12.3 / 6.9 / 26.6s |

- **依次访问快约 3 倍**，差距远超波动：每个新连接省掉 2-3 秒外层握手。日常浏览大多是这种情形。
- **同时访问三者无显著差别**：波动（6.9~26.6s）远大于配置间差距。8 个页面共 1.44 MB，
  受 **VPS 出口 5 Mbps 限速**下限 2.4s；实测 7~27s，大头是大陆→CF 边缘线路本身。
  第一次单次测得"mux 慢 4 秒"属于波动，不是 mux 的代价。
- 据此选 **4×4**。上线后经 TUN 复测依次访问 20.6s，与独立实例一致；国内 80~95ms 不受影响。

> 重启后日志里的 `missing fakeip record` 是重启前拿到 fake-ip 的程序还在用旧地址（映射表随重启丢失），
> 与 mux 无关，过一会儿自然消失。

### 7.9 优选 IP：CF 线路改走东京节点（2026-10-08）

**发现**：从本机网卡（绕开 TUN）直测，按域名连 CF 落在 **AMS（阿姆斯特丹）**，TCP 往返 195–285 ms；
服务器侧 cloudflared 连在 SIN。也就是每个请求都「本地 → 阿姆斯特丹 → CF 骨干 → 新加坡源站」绕大半个地球。
CF 用 Anycast，进哪个节点由运营商选路决定；免费版流量不会落大陆节点（大陆网络仅企业版 + ICP），
电信常把它送去美西或欧洲。**会随时间、运营商变化**——7.6 当时记为 HKG，可能是视角不对（经 VPS 测会得到 VPS 侧节点），也可能当时确实如此。

**扫描**（脚本在会话临时目录，思路：CF 官方 IPv4 段随机抽样 → 绑定 WLAN 测 TCP → 低延迟者以 SNI `ws.example.com`
做 TLS + `GET /cdn-cgi/trace` 读 `colo`）：

| 节点 | 代表 IP 段 | TCP 往返 | TLS 握手 | 结论 |
| --- | --- | --- | --- | --- |
| **NRT 东京** | `172.64.228.x`–`229.x` | 46–123 ms | **55–133 ms** | ✅ TLS≈TCP，线路干净，选用 |
| LAX 洛杉矶 | `172.64.230.x`–`231.x`、`104.16–19.x` 等 | ~145–210 ms | ~150–210 ms | 可用但远 |
| FRA 法兰克福 | `104.24.x`、`172.67.x` 等 | ~165–185 ms | ~175–240 ms | 可用但远 |
| SIN 新加坡 | `172.64.144.0/20` | 63–158 ms | **280–1400 ms** | ❌ TCP 快、TLS 被严重拖慢 |
| —— | `108.162.198.x`、`162.159.x`、`198.41.192.x`、`172.64.52–53.x` 等 | 44–73 ms | 正常 | ❌ 返回 `error code: 1034`（边缘 IP 不给免费版 zone 用） |

**端到端**（独立 sing-box 实例、开 mux、每轮重启实例，4 轮中位数）：

| 入口 | 首次连接 | 单个请求 | 依次 8 站 | 同时 8 站 | 失败 |
| --- | --- | --- | --- | --- | --- |
| 域名（AMS） | 2.91 s | 0.98 s | 15.1 s | 7.0 s | 0 |
| `172.64.229.94`（NRT） | **0.78 s** | **0.25 s** | **5.3 s** | **3.2 s** | 0 |
| `172.64.229.32`（NRT） | 1.05 s | 0.28 s | 5.6 s | 3.7 s | 0 |

**接入**（`patch-client-config.py` 的 `WS_PREFERRED`，生成到三份客户端配置，备份 `*.pre-cfip`）：

```
proxy (selector, default proxy-cf) → [proxy-cf, proxy-ws, proxy-reality]
proxy-cf (urltest, 3m, tolerance 100ms) → [proxy-ws-nrt1, proxy-ws-nrt2, proxy-ws]
proxy-ws-nrt1/2 : server = 优选 IP，TLS server_name 与 WS Host 头都是 ws.example.com
proxy-ws        : server = ws.example.com（兜底：优选 IP 全失效时自动退回）
```

- 拨 IP 必须设 WS `Host` 头，否则 Host 变成 IP，CF 无法路由（403）。证书照常校验。
- SSH 规则（4.10）的出站由 `proxy-ws` 改为 `proxy-cf`。
- 上线后经 TUN：61 个连接走 `proxy-ws-nrt1`（另两个出站各 3 次是 urltest 探测）；依次 8 站 10.2 / 6.6 s
  （7.8 开 mux 后为 20.6 s，未开 mux 59 s）；`<VPS_IP>:22` banner 1.1 s → 0.79 s；国内不受影响。
- **哪天变慢就重扫**：节点分配随运营商、时段变化。urltest 只能在给定候选里择优，选不出新 IP。
- 便携客户端（`portable\`）未改：用户的运营商可能不同，东京段未必对他们最快（urltest 会自动退回域名，加上也无害，需要时再定）。
  （后来已加上，见 4.12。）

### 7.10 8443 只放行 Cloudflare + 证书换中性名字（2026-10-08）

**问题**：8443 对全网开放，直连（不带 SNI 也行）就会拿到证书 `CN = node.example.com`。Censys/Shodan 和 GFW 的主动扫描
会据此把 `example.com` 和被墙的 `<VPS_IP>` 关联起来——最坏情况是按 SNI 封 `ws.example.com`，CF 兜底线路也断，换 IP 也救不回。
改前 check-host：8443 从日本/荷兰/俄罗斯/土耳其/美国/越南 6 国全部可连。

**做法**（`server-harden-8443.sh` 分三阶段，每段用 `systemd-run` 脱离 SSH 会话执行——操作者的 SSH 本身走 sing-box，重启会断）：

| 阶段 | 内容 | 保险 |
| --- | --- | --- |
| `cert` | 自签证书换成 `CN=localhost`（同路径 `/etc/ssl/singbox-ws/`），重启 sing-box | 备份 `*.pem.bak.20261008172358`；check/重启/自测（普通 + mux 临时客户端各 3×204）失败就换回旧证书 |
| `firewall` | `cf8443-firewall.sh update`：从 `api.cloudflare.com/client/v4/ips` 取段（校验 ≥10 段 IPv4），写 `/etc/cf8443/v{4,6}.txt`，原子加载 nftables 表 `inet cf8443` | **15 分钟后自动撤销**（`systemd-run --on-active=15min … remove`），确认无误才取消 |
| `confirm` | 取消自动撤销；`cf8443-firewall.service`（开机 apply）enable；`cf8443-update.timer`（每周刷新 CF 段）enable | —— |

规则（独立的表，其它端口、其它规则一概不碰；`cf8443-firewall.sh remove` 即完全还原）：

```
iif lo tcp dport 8443 accept               # 本机自测（127.0.0.1 / 本机连自己的公网 IP）
ip  saddr @cf4 tcp dport 8443 accept       # Cloudflare 15 段 IPv4
ip6 saddr @cf6 tcp dport 8443 accept       # Cloudflare 7 段 IPv6
tcp dport 8443 counter drop
```

**验证**：
- 证书：`before: CN = node.example.com` → `after: CN = localhost`；服务端自测 6/6 × 204。
- 经 CF（本机全新实例，域名 / `.94` / `.32` 三种入口）全部 204/200；正在用的 TUN 正常；日常 SSH banner 0.74 s。
- 外部 check-host：**8443 全部超时**（瑞士、印尼、伊朗等），**443 照常**（巴西、西班牙、新加坡、美国等 6 国）；drop 计数器 12 包。
- 持久化：`cf8443-firewall.service` enabled/active，`cf8443-update.timer` enabled（下次 10-12），自动撤销 timer inactive。
- 中途 `.94` 一次 13 s 失败，复测 3/3 正常、直测显示东京段晚间有丢包——与本次改动无关（证书只影响 CF→源站段）。

**退路**：规则写错会把 CF 挡在外面（CF 线路和日常 SSH 一起断），但 Cloudflare Tunnel 应急通道是出站连接，不受影响，
登上去 `cf8443-firewall.sh remove` 即可；再不行 VNC 控制台。

**注意**：以后若改 vless-ws-in 的端口，`cf8443-firewall.sh` 里的 `PORT=8443` 要一起改；`server-add-ws.sh` 新生成的证书也已改为 `CN=localhost`。

---

## 八、传输通道的坑

排查中踩了几类坑。8.1、8.2 当初归为"链路损坏内容"，**2026-10-08 复盘已查明不是线路噪声**，
而是剥离 `\r` 的命令丢了反斜杠（见 8.2）。

### 8.1 stdin 管道丢字符

```powershell
Get-Content script.sh | ssh-vps.cmd 'bash -s'   # 当时观察到"丢字符"
```

实测现象：`grep` → `gep`、`/usr/local/bin` → `/us/local/bin`。

**复盘**：两个案例都是**行中间少了字母 `r`**，与 8.2 同属"`\r` 丢了反斜杠"一类。
`s/r$//` 只删行尾，解释不了这两个；本地复现中 `tr -d 'r'`（即 `tr -d '\r'` 丢反斜杠）
能同时得到 `gep` 和 `/us`。具体是哪条命令、哪一层，**未定位**（见 8.2 末尾）。

**规避**：用 scp 传文件，**不要**用管道喂脚本（保留）。

### 8.2 `bbr` 被改写成 `bb`：sed 里的 `\r` 丢了反斜杠

**现象**：脚本执行后写出的 `/etc/sysctl.d/99-singbox-tuning.conf` 里 `bbr` 变成 `bb`，重复 5 次全部如此。
**后果**：BBR 静默失效（`sysctl` 报错被 `>/dev/null` 吞掉，一直没发现）。

当时的结论是"heredoc 内容被恒定改写"，并定下"禁止用 heredoc"的规矩。**这个结论是错的。**

**机制（已在服务端控制台实测复现）**：剥离 CR 的 `sed 's/\r$//'` 若反斜杠被吞，模式变成 `s/r$//`，
删的是**行尾字母 `r`**：

```
实验 3: sed 's/r$//' /tmp/t1.txt
输入:   net.ipv4.tcp_congestion_control = bbr
输出:   net.ipv4.tcp_congestion_control = bb      ← 精确复现
```

**heredoc 是清白的**：

```
实验 2: cat > /tmp/t2.txt <<'EOF'
        net.ipv4.tcp_congestion_control = bbr
        EOF
        sed -i "s/\r$//" /tmp/t2.txt
输出:   net.ipv4.tcp_congestion_control = bbr     ← 完好
```

**规矩修正**：

| 之前的规矩 | 修正后 |
| --- | --- |
| 禁止用 heredoc | ❌ 撤销，heredoc 可以用 |
| — | ✅ **新增**：sed / tr 的模式里**别写 `\r` 字面量**（见下） |
| 传文件用 scp，别用管道 | ✅ 保留 |
| 关键文件写完做校验 | ✅ 保留，且两边用同一种算法（见下） |

```bash
CR=$'\015'                          # 不写 \r 字面量
sed -i "s/${CR}\$//" file
# 或
tr -d "$CR" < file > tmp && mv tmp file
```

注意 `tr -d '\r'` 同样含 `\r` 字面量，反斜杠一丢就变成 `tr -d 'r'`（正是 8.1 的现象），也要换成 `"$CR"`。
`$'\015'` 本身也有反斜杠，丢了会变成字面量 `015`：CR 剥不掉，最多误删行尾恰好是 `015` 的内容，
远比误删字母 `r` 少见，也更容易察觉。最稳妥的是写完照样做校验（下文）。

**哪一层吞了反斜杠：仍未定位。** 已实测排除：

| 层 | 测试 | 结果 |
| --- | --- | --- |
| PowerShell 双引号 → cmd | `cmd /c probe "sed -i "s/\r$//" f"` | `\r` 完好 |
| PowerShell 单引号 → cmd | `cmd /c probe 'sed -i "s/\r$//" f'` | `\r` 完好 |
| `.cmd` 文件内部字面量 | 探针脚本内嵌该行 | `\r` 完好 |
| 远端 bash + heredoc | 实验 1 / 2 | 完好 |

剩余嫌疑：agent 工具调用的参数传递，或当时 `bash -s` 的 stdin 路径。SSH 可达时用两条路对比即可定位：

```bash
# L1 参数直传（不经 shell/cmd/PowerShell）
ssh root@host "printf '%s' 's/\r$//' | od -An -c"
# L2 经包装脚本 + bash -s
echo "printf '%s' 's/\r$//' | od -An -c" | ./ssh-vps.cmd 'bash -s'
```

**关于"磁盘上的脚本内容正确"这条证据**：它来自 `push-file.ps1`，比的是本地**去掉 CR 后**的哈希
与远端**原始字节**哈希。两者相等证明远端 = 本地去 CR 后的内容，对 bash 脚本来说正是想要的状态，
**这条证据成立**；远端若带 CR，原始哈希必然不等，会判失败而不是误判通过。真正的缺陷在反方向：
本地文件带 CR 时**永远校验不过**（假阴性），且没检查 ssh 退出码。

**2026-10-08 已修**：两边都对**原始字节**算 SHA256（scp 原样复制字节，相等即同一个文件；
不用远端 `tr -d '\r'`，免得又碰上 `\r` 字面量丢反斜杠）；本地文件含 CR 直接拒绝（exit 2，`-AllowCR` 可放行）；
检查 scp 和 ssh 的退出码。

**对现在的影响**：华纳云控制台直接进 bash，不经 cmd / PowerShell / 包装脚本这一串，天然不受影响
（实验 1–3 就是在控制台跑的）。`server-reality-camo.sh` 经 paste.rs + `curl -so` 下载，SHA256 与本地一致，执行正确。

### 8.3 出站间歇性阻断

非白名单站点的表现是**周期性**的：

```
TCP connect 443     : OK
TLS handshake       : ConnectionReset      ← 数据即被重置
HTTP GET :80        : ConnectionReset
```

且**大文件传输完好**（32MB zip SHA256 双向一致），说明不是普遍性损坏，
而是针对特定站点的主动干扰。

**规避**：靠 Cloudflare 通道，或等恢复后重试。

### 8.4 paste 服务的 ToS 封禁

我反复用自动化方式 POST 上传脚本到 `dpaste.com`，触发了它的反滥用：

```
Your IP address 2a06:98c0:3600::103 has been blocked for violating the
dpaste.com Terms of Service. IP will be unblocked after not connecting for 3 days.
```

（那个 IPv6 是 Cloudflare 的地址，说明是经 CF 链路出去的）

**教训**：不要自动化反复 POST 到 paste 服务。已改用 `paste.rs` 等替代。

### 8.5 当前可用的传输方式

| 方式 | 状态 |
| --- | --- |
| SSH 到源站 | ❌ 两个 IP 均被墙，完全不可达 |
| scp（沙箱内） | ⚠️ 需提权，且目标 IP 被墙时不可用 |
| 华纳云控制台 | ✅ 唯一可用的服务端入口 |
| 控制台粘贴长度 | ⚠️ 约 80 字符上限（VNC 限制） |
| paste 服务 + `curl -so` 下载 | ✅ 先 `sha256sum` 对上再 `bash`，比 `curl \| bash` 多一道完整性校验 |

> ⚠️ paste 服务的内容**拿到 URL 即公开**。只能传**不含密钥**的东西；用完 `DELETE https://paste.rs/<短码>` 删掉。

---

## 九、我犯的错误与更正

记录在此以免重复踩坑。

### 9.1 误判 Low 完整性标签为故障

**错误说法**：`F:\vps` 被标了 Low 完整性标签，所以是故障，应该"恢复 Medium"。

**更正**：Low 标签是 **DSH Windows 沙箱的既定设计**。`grantWrite` 在**同一个
`SetNamedSecurityInfoW` 调用**里做三件事：加 capability ACE、拒绝 Everyone 的
`FILE_DELETE_CHILD`、把目录标为 Low。原因是受限子进程令牌被降为 Low 完整性，
内核会拒绝它对**任何未标 Low 的对象**做写操作。

权威依据（读过源码与文档）：

| 位置 | 要点 |
| --- | --- |
| `sandbox-windows-acl/src/acl.ts` 顶部注释 | 一次调用完成三处编辑 |
| `sandbox-windows-acl/README.md:128` | 工作区 ACE/拒绝项/标签**按设计常驻、绝不撤销** |
| `diagnose-windows-sandbox-acl/SKILL.md:19` | 标签与拒绝项**保持不动** |
| `sandbox-windows-acl/README.md:175` | 诊断**刻意保留完整性标签** |

**所以不要去"恢复 Medium"**：DSH 下次授权会立刻打回 Low，且手工摘标签会削弱删除围栏。

### 9.2 误判服务端"出问题"

**错误说法**：本地访问 443 返回 Google 的 404，推断"服务端可能出问题了"。

**更正**：这是 **Reality 的正常伪装行为**。Reality 对**未通过认证的探测**
会转发给真实 SNI 目标，让它像一个真网站。所以返回 Google 的 301/404
恰恰说明**伪装在正常工作**。

正确做法是先看 `systemctl is-active` / `ss -lnt`（后来通过控制台确认服务健康）。

### 9.3 误判 TUN 未就绪

早期几次测试中"两个节点都 RESET"，是切换过程中的**瞬时状态**，最终直连对照为
`新 IP:443 OK TLSv1.3` / `旧 IP:443 RESET`。不该把瞬时状态当成结论。

### 9.4 沙箱 ACL 修复的教训

**过程**：

1. 沙箱报 `SetNamedSecurityInfoW failed (Win32 5): grantWrite(F:\vps)`
2. 用随包诊断脚本得到 `PRECONDITION`（`WRITE_DAC` 可用、`WRITE_OWNER` 不可用）
3. 按技能指引执行 `-GrantFullControl` 修复（首次因 `-AllowRoot` 取值不当被拒，改 `F:\` 后成功）
4. **验证受限操作 → 仍然失败**
5. 按技能规则**逐字节还原** ACL（`RESTORED F:\vps`，与备份一致）
6. 复查判定变为 `NOT_THIS_CLASS`（写权限齐全、无包 SID），`nextAction: stop`

**已排除的原因**：

```
AppContainer 包 SID（S-1-15-2-*）   未发现        ← 不是别的工具盖了戳
工作区规模                           43 文件 / 350 MB  ← 不是全树传播超时
非受限调用者 WRITE_DAC               可用（所有者）
```

失败的是 `SetNamedSecurityInfoW` 返回 **Win32 5**。该调用**包含标签编辑**，
而在带强制标签的对象上重写含标签的描述符需要 `SeRelabelPrivilege`（管理员特权），
非受限调用者也没有。

**用户选择方案 C**：保持现状，继续用提权命令。**未做任何 ACL 改动。**

排障凭证保留在 `%USERPROFILE%\dsh-acl-reports\`（3 个报告 + 1 组备份 4 个文件）。

### 9.5 `insecure: true` 的理由写反了

**错误说法**：`server_name` 必须是源站证书 CN；`insecure: true` 后客户端→CF 这段仍有 CF 证书保护。

**更正**：经 CF 代理时，客户端的 TLS **在 CF 边缘终止**，源站证书只有 CF 回源时才看到（Full 模式下也不校验），
所以源站证书 CN 与客户端无关。`insecure: true` 关掉的正是对 **CF 边缘证书**的校验，这段因此**失去**防中间人保护，
而 UUID 是唯一的认证凭据。现在能用，是因为 sing-box 的 WS `Host` 头取自 `server`（`ws.example.com`），
Origin Rule 照样命中；但 SNI 与 Host 不一致属于同 zone 的 domain fronting，CF 以后可能收紧。
正确写法：`server_name: ws.example.com`，去掉 `insecure`。**2026-10-08 客户端已改正并验证**（见 7.4）。

### 9.6 "Reality 经 `node.example.com`" 走不通

**错误说法**：路线 A 是 Reality → `node.example.com:443` → 源站。

**更正**：`node` 是 🟠 Proxied，流量进 CF、由 CF 终止 TLS，Reality 不可能穿过 CF。
客户端 `proxy-reality` 实际连的是**裸 IP**，所以使用没受影响，只是文档描述错了。`node` 记录目前没在用：
可以删；留着就别改灰云（会直接把域名和源站 IP 绑在一起公开）。

### 9.7 第一轮"被墙"证据无效

见 6.1 的更正：对照组同时失败时，测试没有区分能力，不能下结论。

### 9.8 老脚本的"还原"是空话

`server-add-ws.sh` / `server-ws-8443.sh` 在 `check` 失败时打印 `config invalid, restoring`，
**但并没有拷回备份**，直接退出，留下一份坏配置（服务还在用旧配置跑，下次重启才炸）。
**2026-10-08 已修**：两个老脚本都加了与 `server-reality-camo.sh` 相同的 `restore()`，
python 补丁失败、`check` 失败、重启失败、重启后不 active 四处都会拷回备份并重启。
同时改正了 `server-ws-8443.sh` 头部注释：原先写"no Origin Rules needed"，实际正是靠 Origin Rule 把 `ws` 回源到 8443
（zone 级的 Origin Server 端口设置不能用，会连带 Reality）。

### 9.9 曾把含私钥的配置传到公开 paste

11.3 原先给的取配置命令是把整个 `config.json`（含私钥）POST 到 paste.rs，8.4 也反复上传过脚本。
**私钥应视为可能已泄露**，下次换 IP 时一并轮换 keypair / UUID / shortId。取配置改用脱敏版本（见 11.3）。

### 9.10 把 heredoc 当成了嫌疑犯

**错误说法**：heredoc 内容被链路恒定改写，脚本里禁止用 heredoc。

**更正**：真正的原因是 `sed 's/\r$//'` 丢了反斜杠变成 `s/r$//`，删掉了行尾的 `r`；heredoc 写入完全正常
（控制台实验 2、3，见 8.2）。"禁用 heredoc"已撤销，换成范围小得多的"模式里别写 `\r` 字面量"。

---

## 十、文件清单

### 10.1 远端（`<VPS_IP>`）

| 路径 | 内容 |
| --- | --- |
| `/usr/local/bin/sing-box` | 1.14.2 二进制 |
| `/etc/sing-box/config.json` | 三个入站的配置（0600） |
| `/etc/sing-box/config.json.bak.*` | 每次改配置的备份 |
| `/etc/ssl/singbox-ws/cert.pem` `/key.pem` | WS 自签证书 |
| `/etc/systemd/system/sing-box.service` | systemd unit |
| `/etc/sing-box/rules/geosite-cn.srs` `/geoip-cn.srs` | 禁回国用的本地规则集（重跑 `server-reality-camo.sh` 刷新） |
| `/usr/local/bin/cloudflared` + systemd `cloudflared` | Cloudflare Tunnel 连接器（SSH 应急通道，`CF-TUNNEL-SSH.md`） |
| `/root/.ssh/authorized_keys` | 两把：本机 Windows `admin@DESKTOP-XXXXXXX`（RSA，`SHA256:…`）、Mac `mac`（ED25519，`SHA256:…`）；改前备份 `.bak.*` |
| `/etc/ssh/sshd_config.d/01-no-password.conf` | 关密码 + 键盘交互登录（10-08）。`01-` 才能压过 `50-cloud-init.conf` 里的 `PasswordAuthentication yes` |
| `/usr/local/sbin/cf8443-firewall.sh`、`/etc/cf8443/v{4,6}.txt`、systemd `cf8443-firewall.service` / `cf8443-update.timer` | 8443 只放行 Cloudflare（nftables 表 `inet cf8443`，7.10）；部署日志 `/root/cf8443-deploy.log` |
| `/etc/ssl/singbox-ws/cert.pem`（`CN=localhost`）、`*.pem.bak.20261008172358` | WS 入站自签证书；旧证书（CN=node.example.com）的备份 |
| `/root/.local/share/claude/versions/2.1.294`、`/root/.local/bin/claude` | Claude Code（原生安装器，10-08 装；自动更新开着）。原先「装失败」实为 `~/.local/bin` 不在 PATH，已在 `/root/.bashrc` 末尾补上（备份 `.bashrc.bak.*`）；已登录，凭证在 `/root/.claude/.credentials.json` |
| `/etc/sysctl.d/99-singbox-tuning.conf` | BBR/fq 调优 |
| `/swapfile`（2 GiB，0600）+ `/etc/fstab` 一行、`/etc/sysctl.d/99-swap.conf`（`vm.swappiness=10`） | 交换文件（10-10），防内存突增 OOM 掉 sing-box；fstab 改前备份 `.bak.*` |
| `/etc/modules-load.d/singbox-bbr.conf` | BBR 模块开机加载 |

### 10.2 本机 `F:\vps\`

| 文件 | 用途 |
| --- | --- |
| `ssh-vps.cmd` | 免密 SSH 包装（含 `scp` 子命令） |
| `ssh_remote.py` | paramiko 连接器（`--install-key` / `--interactive`） |
| `ssh_login.py` | 早期 sshpass 替代实现 |
| `push-file.ps1` | **scp + SHA256 比对（两边原始字节）+ 自动重传**，拒绝含 CR 的文件，检查退出码 |
| `.ssh_known_hosts` | 工作区内的 known_hosts（系统那份不可写） |

### 10.3 本机 `F:\vps\local\`

| 文件 | 用途 |
| --- | --- |
| `core/sing-box-1.14.2-windows-amd64/` | Windows core |
| `config-tun.json` | **当前使用**（TUN 全局 + 双路 + selector） |
| `config.json` | 免管理员的纯代理模式 |
| `run-singbox.ps1` | 计划任务调用的启动脚本 |
| `elevated-setup.ps1` | 提权安装脚本（注册计划任务） |
| `fix-proxy.ps1` | 清除残留系统代理 + 通知 WinINET |
| `verify-browser.py` | 浏览器路径验证 |
| `verify-backup.py` | 服务端备份校验 |
| `restart-ws.ps1` | 重启代理 |
| `run.log` / `console.log` | 运行日志（`run.log` 为本次会话；`console.log` 为启动器记录，累加） |
| `logs\run-*.log` | 历次会话的 `run.log`，按结束时间命名，保留 30 份（4.9） |
| `*.pre-ws` | 加 WS 之前的配置备份 |
| `*.pre-sni` / `*.pre-mux` / `*.pre-fakeip` | 改 `proxy-ws` TLS（7.4）、开 multiplex（7.8）、加 `store_fakeip`（4.7）之前的备份 |
| `*.pre-ipv6fix` / `*.pre-ipfix` | 另一个助手改 `dns-dial` 前的备份（4.8） |
| `*.pre-ssh` | 加 SSH 走 CF 规则之前的备份（4.10） |
| `*.pre-sshdirect` | 加 `ssh.example.com` 直连规则之前的备份（4.11） |
| `*.pre-cfip` | 加优选 IP + urltest 之前的备份（7.9；`singbox\client-split.json` 同） |
| `cache.db` | sing-box 缓存（规则集、fake-ip 映射，4.7） |

### 10.4 本机 `F:\vps\singbox\`

| 文件 | 用途 |
| --- | --- |
| `README.md` | 部署文档（含 1.14 迁移坑、DNS 污染排查） |
| `CDN-SETUP.md` | CDN 双路架构文档 |
| `SANDBOX-ACL-STATUS.md` | 沙箱 ACL 现状与方案 C 决定 |
| `OPERATIONS.md` | **本文档** |
| `server-config-backup.json` | **服务端配置备份（含唯一私钥，9 字段已校验）**，已同步 3.6 的改动 |
| `server-config-backup.json.pre-camo` | 3.6 改动之前的备份 |
| `server-config-backup.json.pre-mux` | 7.8 multiplex 之前的备份 |
| `server-reality-camo.sh` | REALITY 配置加分项：禁回国 + 80/UDP 443 转发（可重跑，无密钥） |
| `server-ws-mux.sh` | `vless-ws-in` 开 multiplex，并用普通 / mux 两种临时客户端自检（可重跑，无密钥） |
| `server-harden-8443.sh` / `cf8443-firewall.sh` | 8443 加固：换中性证书 + 只放行 Cloudflare（分阶段、带自动撤销，7.10） |
| `client-split.json` | GUI 用客户端配置 |
| `patch-client-config.py` | 幂等的双路 patch 脚本 |
| `install.sh` | 服务端安装/升级（含 Reality 配置，**含私钥**） |
| `server-add-ws.sh` | 服务端新增 WS 入站 |
| `server-ws-8443.sh` | 服务端端口迁移 2053 → 8443 |
| `verify.sh` / `verify-final.sh` / `integrity.sh` | 各类验证脚本 |

---

## 十一、速查表

### 11.1 凭据

| 字段 | 值 |
| --- | --- |
| 节点地址 | `<VPS_IP>`（**已被墙**） |
| CF 入口 | `ws.example.com:443`（稳路）；`node.example.com` 未使用（Reality 只能连裸 IP，见 9.6） |
| 端口 | Reality `443` / WS `8443` |
| UUID | `<UUID>` |
| Flow | `xtls-rprx-vision` |
| SNI | `dl.google.com` |
| PublicKey | `<REALITY_PUBLIC_KEY>` |
| shortId | `<SHORT_ID>` |
| PrivateKey | 见 `server-config-backup.json`（视为可能已泄露，见 9.9） |

### 11.2 分享链接（Reality，IP 需可用）

```
vless://<UUID>@<VPS_IP>:443?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=dl.google.com&fp=chrome&pbk=<REALITY_PUBLIC_KEY>&sid=<SHORT_ID>#SG-Reality
```

### 11.3 常用命令

**本机（普通 PowerShell 窗口，无需沙箱）**

```powershell
schtasks /Run  /TN "sing-box-local"    # 启动代理
schtasks /End  /TN "sing-box-local"    # 停止代理（恢复直连）
Get-Process sing-box                   # 查看进程
Get-NetAdapter | Where-Object Name -match singbox   # 查看 TUN
netstat -ano | Select-String ':2080\s+.*LISTENING'
& 'F:\vps\local\core\sing-box-1.14.2-windows-amd64\sing-box.exe' check -c 'F:\vps\local\config-tun.json'
```

**远端（SSH 可达时）**

```bash
systemctl status sing-box
systemctl restart sing-box
journalctl -u sing-box -f
sing-box check -c /etc/sing-box/config.json
ss -lnt
```

**远端（SSH 不可达时，用华纳云控制台）**

```bash
# 取配置：先去掉私钥再上传（原先直接传整个 config.json，会泄露私钥，见 9.9）
jq 'del(..|.private_key?)' /etc/sing-box/config.json > /tmp/c.json
curl -s --data-binary @/tmp/c.json https://paste.rs
# 用完删除：curl -X DELETE https://paste.rs/<短码>
```

**部署脚本**（见 3.6）：`curl -so c.sh <URL>` → `sha256sum c.sh` 对上 → `bash c.sh`。

### 11.4 当前状态（截至本文档编写）

| 项目 | 状态 |
| --- | --- |
| 服务端 sing-box | ✅ active + enabled，443 / 8443 / 2080 监听 |
| CF 回源链路 | ✅ WebSocket 升级返回 101 |
| 本机代理 | ✅ 运行中，TUN + 2080 |
| 出口 IP | `<VPS_IP>`（经 CF） |
| 国内直连 | ✅ 39~89ms |
| 境外经 CF | ✅ 可用，2476~3724ms |
| Reality 直连 | ❌ IP 被墙，不可用 |
| 禁回国 + 80/UDP 443 转发 | ✅ 2026-10-08 部署（3.6） |
| CF 路 multiplex | ✅ 2026-10-08 启用（7.8），依次访问 59s → 21s |
| CF 优选 IP | ✅ 2026-10-08 东京 `172.64.229.94/.32` + urltest（7.9），依次访问 21s → 6.6–10s |
| fake-ip 跨重启保留 | ✅ 2026-10-08 `store_fakeip`（4.7） |
| SSH 应急通道 | ✅ Cloudflare Tunnel `ssh.example.com` → `127.0.0.1:2222`（`CF-TUNNEL-SSH.md`；便携客户端内置开关，4.12） |
| 8443 防护 | ✅ 只放行 Cloudflare + 证书 CN=localhost（7.10）；外部直连超时 |
| SSH 认证 | ✅ 仅密钥（10-08 关掉密码登录前：24 h 内 12,727 次、累计约 12.7 万次密码猜测，全部失败；历史 7 次密码登录成功均为用户本人） |
| 便携客户端 | ✅ 与 `sing-box-local` 功能对齐（SSH 走 CF、日志保留）+ 直连网址 + SSH 应急通道 + 扫描优选 IP（4.12）；Windows 版真机验证通过，mac 版未真机验证 |
| VPS 出口带宽 | 5 Mbps 限速（同时访问的硬下限） |
| 私钥备份 | ✅ 已落盘并校验（已同步 3.6 改动） |

### 11.5 下一步

1. **换新 IP 恢复 Reality 快路**（195ms vs CF 的 2700ms，快 14 倍）—— 最高优先级。
   **要求不同 /24 网段**（6.2）
2. 换 IP 时**轮换 keypair / UUID / shortId**（9.9）。私钥只留服务端，只把公钥、UUID、shortId 带回客户端
3. 换 IP 后需改：CF 的 `ws` 记录（`node` 未使用，可删）→ 新 IP；客户端 `proxy-reality` 的 `server`
4. **停用 `<OLD_VPS_IP>` / `<VPS_IP>`** —— 均已确认被墙
5. ~~客户端 `proxy-ws`：`server_name` 改 `ws.example.com`、去掉 `insecure`~~ ✅ 2026-10-08 已改（7.4）
6. CF 路提速：~~multiplex~~ ✅（7.8）、~~优选 IP~~ ✅（7.9，东京节点）。变慢时重扫优选 IP；
   Argo Smart Routing（付费）收益已不大。同时访问受 VPS 5 Mbps 出口限速约束
7. ~~防火墙只放行 CF IP 段访问 8443~~ ✅ 2026-10-08（7.10）；证书 CN 也已换成中性的 `localhost`
8. ~~关 SSH 密码登录~~ ✅ 2026-10-08 19:4x 已关（`/etc/ssh/sshd_config.d/01-no-password.conf`，见 CF-TUNNEL-SSH.md 第 7 步）。
   **改 root 密码**仍待用户自己在服务器上 `passwd`（密码曾明文泄露；VNC 控制台仍用它）

### 11.6 已知限制

| 限制 | 说明 |
| --- | --- |
| CF 路延迟高 | 按域名默认落 AMS（往返约 250 ms），QUIC 被阻断；已用优选 IP 缓解（7.9） |
| 无 SSH 到源站 | 两个 IP 被墙，只能走华纳云控制台 |
| 控制台粘贴限制 | 约 80 字符，长脚本须经 paste 服务 |
| 工作区沙箱不可用 | `F:\vps` ACL 授权失败，所有命令需提权（方案 C） |
| dpaste 被封 3 天 | 因自动化反复 POST 触发 ToS |
