# CDN 双路架构（Cloudflare + Reality）

记录时间：2026-10-08

## 为什么要做这个

`<OLD_VPS_IP>` 和 `<VPS_IP>` **连续两个 IP 被墙**（TCP 黑洞，ICMP 无回应，
而 check-host.net 从 7 国探测均正常）。裸 Reality 直连的问题不是配置错误，
而是**源站 IP 一旦被拉黑，客户端就完全失联**。

CDN 方案把源站 IP 从公网视野里彻底隐藏：客户端只连 Cloudflare 的共享边缘 IP，
CF 从自己的网络回源到 VPS。**源站 IP 再被封也不影响使用。**

## 最终架构

```
客户端
  │
  ├─ 路线 A（快，IP 未封时用）
  │     VLESS + Reality  →  <VPS_IP>:443（裸 IP 直连，不经 CF）
  │                              (vless-reality-in)
  │
  └─ 路线 B（稳，IP 被封时用）
        VLESS + WebSocket + TLS  →  ws.example.com:443
              → Cloudflare 边缘（按域名落 AMS；优选 IP 落 NRT）→ 回源 <VPS_IP>:8443
                                            (vless-ws-in)
```

> Reality 不能经过 CF：🟠 Proxied 记录的流量由 CF 终止 TLS，Reality 握手到不了源站。
> 所以路线 A 只能连裸 IP，`node.example.com` 这条记录实际没在用（早先版本把路线 A 画成经 `node`，是错的）。

两条路**并存**，客户端用 sing-box 的 `selector` 切换：

```json
{
  "type": "selector",
  "tag": "proxy",
  "outbounds": ["proxy-ws", "proxy-reality"],
  "default": "proxy-ws"
}
```

`default` 按当前哪个可用改即可，或直接在 GUI 里点 selector 切换。

## Cloudflare 侧配置

| 项目 | 值 |
| --- | --- |
| 域名 | `example.com`（阿里云注册，NS 改到 CF） |
| NS | `<ns1>.ns.cloudflare.com` / `<ns2>.ns.cloudflare.com` |
| 边缘证书 | Universal SSL，SAN = `*.example.com, example.com` |
| DNS `node` | A → `<VPS_IP>`，🟠 Proxied（未使用，可删；留着别改灰云，会暴露源站 IP） |
| DNS `ws` | A → `<VPS_IP>`，🟠 Proxied |
| Origin Rule | Hostname = `ws.example.com` → Destination Port 改写为 `8443` |
| SSL/TLS 模式 | **Full**（加密回源但不校验证书，匹配自签证书） |
| DNSSEC | 未启用（无需操作） |

**关键点**：CF 的回源端口默认是 443，而 443 被 Reality 占用（Reality 按 SNI
处理，会把 CF 的探测流量转发给 `dl.google.com`，表现为返回 Google 的 301/404）。
所以 WS 必须换端口，用 **Origin Rule** 单独把 `ws` 子域的回源端口改写到 8443。

> 注意：CF 的 `SSL/TLS → Origin Server` 端口设置是**整个 zone 一份**的，
> 不能按 hostname 区分，所以不能用它 —— 用了会连带影响 Reality。必须用 Origin Rules。

## 服务端配置

`vless-ws-in` 入站（追加在原有 Reality 入站之后，不修改原有部分）：

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

- 证书是**自签**的（10 年），配合 CF 的 `Full` 模式。原 CN=`node.example.com`，2026-10-08 换成 CN=`localhost`（不再暴露域名）
- 复用与 Reality 相同的 UUID，客户端不用改 UUID
- 自签证书生成、配置备份、回滚逻辑都在 `server-add-ws.sh` / `server-ws-8443.sh` 里

## 客户端配置

`proxy-ws` 出站（`patch-client-config.py` 生成）：

```json
{
  "type": "vless",
  "tag": "proxy-ws",
  "server": "ws.example.com",
  "server_port": 443,
  "uuid": "<UUID>",
  "domain_resolver": "dns-dial",
  "transport": { "type": "ws", "path": "/ws" },
  "tls": {
    "enabled": true,
    "server_name": "ws.example.com"
  },
  "multiplex": {
    "enabled": true,
    "protocol": "h2mux",
    "max_connections": 4,
    "min_streams": 4
  }
}
```

- `domain_resolver: dns-dial`：节点域名用专用解析器（UDP `223.5.5.5`）解析，不依赖系统 DNS，属于加固（OPERATIONS.md 4.8）。
- `multiplex`（2026-10-08 启用）：复用最多 4 条隧道，每条满 4 个流才开新的。服务端 `vless-ws-in`
  需同时开 `"multiplex": {"enabled": true}`，**必须服务端先开**，否则 mux 客户端连不上。

- `server_name` 是 **CF 代理的主机名** `ws.example.com`，**不设 `insecure`**：客户端校验 CF 边缘的
  Universal SSL 证书（覆盖 `*.example.com`）。SNI 与 WS 的 `Host` 头一致。
- 客户端的 TLS 在 CF 边缘终止，看不到源站的自签证书；源站证书只有 CF 回源时才看（Full 模式下不校验）。
  所以服务端 `vless-ws-in` 的自签证书和 `server_name: node.example.com` 不用动。

> **2026-10-08 改正**：原先是 `server_name: node.example.com` + `insecure: true`，理由写的是"必须是源站证书 CN，
> 客户端→CF 仍有 CF 证书保护"——两点都错：源站证书与客户端无关，`insecure` 关掉的恰恰是对 CF 证书的校验，
> 而且 SNI（`node`）与 Host（`ws`）不一致属于 domain fronting。改前在 TUN 之外 A/B 对照：新写法 5/5 返回 204、
> 无证书错误、延迟相同；重启后境外/国内全部正常。旧配置备份为 `*.pre-sni`。

## ⚠️ 实测性能：CF 路可用但慢

`<VPS_IP>` 被墙后实测（20 次采样）：

```
TLS 握手到 CF 边缘     :  最小 2058ms  中位 2730ms  最大 6703ms  成功 20/20
国内直连对照           :  202~247ms
```

**瓶颈定位（逐段测量）**：

| 环节 | 耗时 | 判断 |
| --- | --- | --- |
| TCP 连接 CF 边缘 | 2~26ms | 正常 |
| **TLS 握手 CF 边缘** | **~2.7s** | ← 瓶颈 |
| CF 边缘内部 (`cfEdge`) | 15ms | 很快 |
| CF → 源站 (`cfOrigin`) | 140ms | 很快 |
| CF 边缘 POP | 当时记为 `HKG`；10-08 下午直测为 `AMS`（阿姆斯特丹） | — |

**CF 服务端侧毫无问题**，慢在中国大陆 → CF 边缘这段链路（TLS 握手被限速/高丢包）。已用优选 IP 改到东京节点，见下文「优选 IP」。

**HTTP/3（QUIC）也走不通**：UDP/443 到 CF 边缘全部超时
（对照：国内 UDP/53 13ms 正常），说明 UDP 出境被阻断。

**结论**：CF 路是**能用的兜底**（20/20 稳定，网站都能打开），
但每建连接 2-3 秒，网页首屏明显卡顿，**不适合当主力**。
主力仍应是 Reality 直连（195ms，快 14 倍）。

## 优选 IP（2026-10-08）

按域名连 CF，本地运营商落在 **AMS（阿姆斯特丹）**，TCP 往返约 250 ms。扫了 CF 官方 IPv4 段后发现
`172.64.228.x`–`229.x` 落在 **NRT（东京）**，往返 46–123 ms、TLS 握手不被拖慢；新加坡段
`172.64.144.0/20` 虽然更近，但 TLS 握手要 0.3–1.4 s，不选。

客户端现在是：`proxy`（selector）默认 → `proxy-cf`（urltest，每 3 分钟择优）→
`proxy-ws-nrt1`（`172.64.229.94`）/ `proxy-ws-nrt2`（`172.64.229.32`）/ `proxy-ws`（域名兜底）。
拨 IP 时 TLS `server_name` 和 WS `Host` 头都设为 `ws.example.com`（不设 Host 会 403）。

实测（4 轮中位数）：单个请求 0.98 s → **0.25 s**，依次 8 站 15.1 s → **5.3 s**，同时 8 站 7.0 s → **3.2 s**。
节点分配会随运营商和时间变化，变慢就重扫。详见 OPERATIONS.md 7.9。

便携客户端（Windows / mac）内置了「扫描优选 IP」：代理停止时点一下，在用户自己的网络上抽样 ~350 个 CF IP，
列出最快的几个和按域名入口的对比，确认后替换默认的两个东京 IP（OPERATIONS.md 4.12）。
10-08 18:35 用它在本机复测：按域名 AMS 201 + 210 ms，东京 `.94` 41 + 51 ms、`.32` 56 + 95 ms，结论不变。

## 下一步建议

1. **再换一个 IP**（最高优先级）—— 恢复 Reality 快路，CF 保留作兜底。
   两个被封的 IP 同在 `同一 /24 网段`，**要求换不同 /24 网段**
2. 换 IP 后只需改两处：CF 的 `ws` 记录 → 新 IP；客户端 `proxy-reality` 的 `server`
3. **不要再用 `<OLD_VPS_IP>` / `<VPS_IP>`** —— 均已确认被墙
4. CF 路提速，先试免费的：
   - ~~**multiplex**~~ ✅ **2026-10-08 已启用**（服务端 `server-ws-mux.sh` + 客户端 h2mux 4×4）。
     实测 8 个境外站依次访问 **59.1s → 20.6s**；同时访问无显著差别（受 VPS 5 Mbps 出口限速与线路波动主导）。
     详见 OPERATIONS.md 7.8
   - ~~**优选 IP**~~ ✅ **2026-10-08 已做**（东京节点 + urltest，见上文「优选 IP」）
   - 都不够再评估 Argo Smart Routing（付费）
5. ~~**防火墙只放行 CF IP 段访问 8443**~~ ✅ 2026-10-08：nftables 表 `inet cf8443`，外部直连 8443 超时，经 CF 正常；
   证书 CN 也换成了 `localhost`。详见 OPERATIONS.md 7.10
6. ~~客户端 `proxy-ws` 改正 `server_name` / `insecure`~~ ✅ 2026-10-08 已改（见上文"客户端配置"）
7. CF 控制台里删掉没在用的 `node` 记录（可选；留着也行，只要别改成灰云）

> CF 免费版的服务条款不鼓励大流量代理，当兜底用问题不大，别长期当主力跑大流量。

## 私钥备份

`server-config-backup.json` 是服务端完整配置的备份，**含唯一私钥**（文档不再明文记录私钥）。

已逐项校验与线上一致（9 个字段全对）；2026-10-08 已同步 `server-reality-camo.sh` 的改动，
改动前的版本另存为 `server-config-backup.json.pre-camo`。**实例重建前先确认这份备份在。**

> ⚠️ 早先曾把含私钥的整份配置传到公开 paste 服务，**私钥应视为可能已泄露**。
> 下次换 IP 时一并轮换 keypair / UUID / shortId；私钥只留服务端，只把公钥、UUID、shortId 带回客户端。

## 传输通道的坑（重要）

这台机器到外网的传输极不稳定，排查中踩了不少：

| 问题 | 表现 | 规避方式 |
| --- | --- | --- |
| stdin 管道丢字符 | `grep` → `gep` | 用 scp 传文件，不要管道喂脚本 |
| `bbr` → `bb` | 剥 CR 的 `sed 's/\r$//'` 丢了反斜杠，变成删行尾 `r`（已复现；**不是 heredoc 的锅**） | 模式里别写 `\r` 字面量，用 `CR=$'\015'` 变量；heredoc 照常可用 |
| dpaste 反复自动上传 | 被判定违反 ToS，**封禁 3 天** | 别用自动化反复 POST；换 paste.rs 等 |
| 出站间歇性阻断 | 非白名单站点 TCP 通、TLS 被 RST | 靠 Cloudflare 通道，或等恢复 |
| SSH 到源站 | 两个 IP 均被墙，完全不可达 | 用商家控制台 / CF 通道 |

> 三个案例（`grep→gep`、`/usr→/us`、`bbr→bb`）**都是少了字母 `r`**，不是线路噪声，而是剥离 `\r` 的命令丢了反斜杠。
> `bbr→bb` 已在控制台复现（`s/r$//`）；另外两个是行中间的 `r`，更像 `tr -d 'r'`。
> 哪一层吞的反斜杠还没定位，详见 OPERATIONS.md 8.1 / 8.2。控制台直接进 bash，不受影响。

**服务端改动现在只能通过华纳云控制台**（SSH 已不可达）。
控制台有粘贴长度限制（约 80 字符），所以部署方式是：把**不含密钥**的脚本传到 paste 服务，控制台里：

```bash
curl -so c.sh <短URL>
sha256sum c.sh      # 与本地对上才执行
bash c.sh
```

用完 `curl -X DELETE <短URL>` 删掉 paste。

## REALITY 配置加分项（2026-10-08）

`server-reality-camo.sh` 已部署：禁回国流量（本地 geosite-cn / geoip-cn 规则集）+ TCP/80、UDP/443
转发到握手目标 `dl.google.com`。服务端自检全部通过（80 转发 302 与真站一致、国内域名/IP 被拦、境外 204）。
不影响本文的两条路线。详见 OPERATIONS.md 3.6。
