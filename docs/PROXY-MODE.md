# 代理模式说明

> 面向日常使用：你现在的代理是什么形态、流量怎么走、怎么切换、怎么排查。
> 历史排查过程见 `OPERATIONS.md`，CDN 架构细节见 `CDN-SETUP.md`。

---

## 一、一句话概括

**TUN 全局透明代理 + 智能分流 + 双路冗余。**

系统所有流量自动被接管，国内网站直连、境外网站走节点；
节点有两条路（Cloudflare 中转 / Reality 直连），一条断了可以切另一条。

**你不需要在浏览器或任何软件里配置代理** —— 流量在网卡层就被接管了。

---

## 二、流量怎么走

```
你的程序（浏览器 / 微信 / apt / docker ...）
        │  不感知代理，正常发起连接
        ▼
┌───────────────────────────────────────────┐
│  singbox-tun 虚拟网卡（172.19.0.1/30）      │  ← auto_route，接管全部流量
└───────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────┐
│  sing-box 路由决策                          │
│                                            │
│  国内域名/IP  ──► direct  直接出去（快）     │
│  境外域名/IP  ──► proxy   走节点             │
└───────────────────────────────────────────┘
        │
        ├─── direct ──────────► 本地网络直接访问
        │
        └─── proxy（selector 二选一）
                 ├─ proxy-ws      ──► Cloudflare ──► VPS    （稳）
                 └─ proxy-reality ──► VPS 直连              （快）
```

---

## 三、两个入口

配置里有两个入站（inbound），**同时生效**：

| 入口 | 地址 | 说明 |
| --- | --- | --- |
| `tun` | 虚拟网卡，无端口 | **主力**。全部系统流量自动分流 |
| `mixed` | `127.0.0.1:2080` | **备用**。HTTP + SOCKS5 同端口 |

**什么时候用 2080**：

- 某个程序你**不想让它走分流规则**，想强制走代理
- 做测试、临时指定
- 某个程序对 TUN 兼容不好

用法：

```bash
# HTTP 代理
http://127.0.0.1:2080

# SOCKS5（推荐用 hostname 模式）
socks5://127.0.0.1:2080
```

> 只绑 `127.0.0.1`，**外部访问不到**，这是刻意的。

---

## 四、分流规则（按顺序，首个命中生效）

```
1. sniff              解析真实域名（TLS SNI / HTTP Host）
2. DNS 查询           hijack-dns，交给 sing-box 统一处理（防污染）
3. 节点 IP /32        direct   ← 防止"代理自己的流量"又绕回 TUN，形成死循环
4. 私有 IP            direct   ← 局域网、172.16/12、192.168/16 等
5. geosite-cn 域名    direct   ← 国内网站
6. geoip-cn   IP      direct   ← 兜底：域名没命中但 IP 在国内
────────────────────────────────
   final               proxy    ← 其余全部走节点
```

**规则集来自 GitHub 现成数据**（MetaCubeX 官方 `.srs`），每 3 天自动更新，不用手工维护：

| 规则集 | 内容 | 大小 |
| --- | --- | --- |
| `geosite-cn` | 国内域名（`cn.srs`） | 446 KB |
| `geoip-cn` | 国内 IP 段（`cn.srs`） | 36 KB |

> ⚠️ 注意别用 `geolocation-cn.srs`（仅 27 KB 的精选子集）。
> 实测用它 `qq.com`/`taobao.com`/`jd.com` 会被误判走代理。

---

## 五、DNS 怎么处理（防污染的关键）

```
① 国内域名（geosite-cn） → 本地 DNS  → 拿真实 IP → 走 direct
② 其余域名的 A/AAAA 查询 → fake-ip   → 返回 198.18.x.x 合成地址
③ 无法归类的             → DoH 1.1.1.1，经 proxy 出站（防污染）
```

**fake-ip 是这里最关键的设计**：

```
系统以为 google.com 是 198.18.0.x
   → 连接发到 198.18.0.x，进入 TUN
   → sing-box 反查这个合成 IP 对应哪个域名
   → 用域名（而不是 IP）做分流判断
   → 走 proxy 出去，由出口侧去解析真实 IP
```

**为什么必须这样**：本机 DNS 是 `<运营商 DNS>`（本地运营商）。
实测它把 `www.google.com` 解析成 `104.244.42.197`（**Twitter 网段，典型污染**）。
如果不用 fake-ip，sing-box 只会看到一个被投毒的 IP，**域名分流彻底失效**，
境外站点全部打不开（表现为 TLS EOF）。

用了 fake-ip 后，系统永远拿不到可被污染的答案：

```
google -> 198.18.0.6      ← 合成，防污染
baidu  -> 180.101.49.44   ← 真实，直连
```

---

## 六、双路：selector 切换

`proxy` 是个 **selector**，在两个出站之间二选一：

```json
{
  "type": "selector",
  "tag": "proxy",
  "outbounds": ["proxy-ws", "proxy-reality"],
  "default": "proxy-ws"
}
```

| 出站 | 路径 | 延迟 | 何时用 |
| --- | --- | --- | --- |
| `proxy-ws` | `ws.example.com:443` → Cloudflare → VPS | **慢**（2-3 秒/连接） | **当前默认**。源站 IP 被封时的唯一可用路径 |
| `proxy-reality` | `<VPS_IP>:443` 直连 | **快**（~195ms） | IP 未被封时首选 |

**为什么慢的反而当默认**：`<VPS_IP>` **已经被墙**（TCP 黑洞），
Reality 直连完全不通。所以只能先用 CF 那条。

**换 IP 后怎么切回快路**：改 `config-tun.json` 里 selector 的 `default`：

```json
"default": "proxy-reality"
```

然后重启任务。或者直接在 GUI 里点 selector 切换。

---

## 七、日常操作

**用普通 PowerShell 窗口**（DSH 沙箱里这些命令会被拒）：

```powershell
schtasks /Run  /TN "sing-box-local"    # 启动代理
schtasks /End  /TN "sing-box-local"    # 停止代理（临时恢复直连）
```

**查看状态**

```powershell
Get-Process sing-box                                        # 进程在不在
Get-NetAdapter | Where-Object Name -match singbox           # TUN 网卡
netstat -ano | Select-String ':2080\s+.*LISTENING'          # 2080 端口
Get-Content F:\vps\local\run.log -Tail 20                   # 日志
```

**校验配置**

```powershell
& 'F:\vps\local\core\sing-box-1.14.2-windows-amd64\sing-box.exe' check -c 'F:\vps\local\config-tun.json'
```

---

## 八、配置与文件

| 文件 | 作用 |
| --- | --- |
| `F:\vps\local\config-tun.json` | **当前使用**：TUN 全局 + 双路 |
| `F:\vps\local\config.json` | 备用：仅 2080 代理，**不需要管理员** |
| `F:\vps\local\run-singbox.ps1` | 启动脚本（计划任务调用），`$cfg` 决定用哪份配置 |
| `F:\vps\local\core\` | sing-box 1.14.2 for Windows |
| `F:\vps\local\run.log` | 运行日志 |
| `F:\vps\local\*.pre-ws` | 加 CF 之前的配置备份 |

**计划任务**：`sing-box-local`，登录时自动启动，`RunLevel Highest`（TUN 需要管理员）。

> **进程会退出吗**：会。网络抖动或源站不可达时 `sing-box run` 可能退出，
> 启动脚本**没有加自动重启**（刻意如此 —— 否则你手动退出后它会自己弹回来）。
> 发现代理失效时先 `schtasks /Run` 拉起来。

---

## 九、节点信息（服务端）

| 项目 | 值 |
| --- | --- |
| VPS | `<VPS_IP>`（**已被墙**） |
| CF 入口（WS） | `ws.example.com:443`，路径 `/ws` |
| Reality 入口 | `node.example.com` → 回源 `:443` |
| WS 回源端口 | `8443`（CF Origin Rule 改写） |
| UUID | `<UUID>` |
| Flow | `xtls-rprx-vision`（仅 Reality 用） |
| Reality SNI | `dl.google.com` |
| PublicKey | `<REALITY_PUBLIC_KEY>` |
| shortId | `<SHORT_ID>` |

**服务端也有一份配置**（`/etc/sing-box/config.json`），含三个入站：

```
vless-reality-in   0.0.0.0:443     直连入口
vless-ws-in        0.0.0.0:8443    CF 回源入口
mixed-in           127.0.0.1:2080  服务器自用回环代理（与你本机的 2080 无关）
```

私钥备份：`F:\vps\singbox\server-config-backup.json`（**唯一，勿丢**）。

---

## 十、性能预期

实测（当前 CF 路）：

```
国内直连        39 ~ 89 ms
境外经 CF       2476 ~ 3724 ms      中位约 2.7 秒（建连）
```

**CF 路慢主要慢在"中国 → CF 边缘"这一段**的 TLS 握手，
而 CF 服务端侧很快（`cfEdge=15ms`、`cfOrigin=140ms`）。HTTP/3 也试过，
UDP/443 出境被阻断，走不通。

> 更正（2026-10-08）：这里原先写的是"CF 香港边缘"。从本机网卡直测，按域名连 CF 实际落在
> **AMS（阿姆斯特丹）**，往返约 250 ms。现已改用东京节点的优选 IP（往返 50–90 ms），
> 单个请求 0.98 s → 0.25 s，详见 OPERATIONS.md 7.9。

**换成 Reality 直连后可降到 ~195ms**，快约 14 倍。

---

## 十一、常见问题

**Q：浏览器打不开境外网站**
先 `schtasks /Query /TN "sing-box-local"` 看是不是进程退了。
另外确认**系统代理是关闭的**（`ProxyEnable = 0`）—— 走 TUN 时系统代理必须关，
否则指向死端口会让浏览器彻底断网（这个坑踩过一次）。

**Q：国内网站也变慢了**
不该发生（国内走 direct）。检查是否有程序自己设了系统代理。

**Q：2080 连不上**
代理进程没运行。`schtasks /Run /TN "sing-box-local"`。

**Q：想临时完全恢复直连**
`schtasks /End /TN "sing-box-local"`，TUN 网卡会消失，路由自动回到 WLAN。

**Q：怎么知道流量走了哪条路**
看日志里的出站标签：`outbound/vless[proxy-ws]` 是 CF，
`outbound/vless[proxy-reality]` 是直连，`outbound/direct[direct]` 是直连出去。

---

## 十二、已知限制

| 限制 | 说明 |
| --- | --- |
| CF 路延迟高 | 按域名默认落 AMS（阿姆斯特丹，往返约 250 ms），QUIC 被阻断；已用东京优选 IP 缓解（OPERATIONS.md 7.9） |
| Reality 路当前不可用 | `<VPS_IP>` 被墙，需换 IP |
| SSH 到源站要绕路 | 源站 IP 被墙不能直连。日常：本机代理把 `<VPS_IP>:22` 经 CF 线路转到 VPS 的 `127.0.0.1:22`（OPERATIONS.md 4.10）；sing-box 坏了：Cloudflare Tunnel 应急通道 `127.0.0.1:2222`（CF-TUNNEL-SSH.md）；都不行时用华纳云控制台 |
| 工作区沙箱不可用 | `F:\vps` 的 ACL 授权失败，相关命令需提权（方案 C） |
| 双路需手动切换 | 没做自动故障转移（可用 urltest 实现，但会让每次请求都探测、增加延迟） |
