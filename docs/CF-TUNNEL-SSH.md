# Cloudflare Tunnel：独立的 SSH 管理通道

记录时间：2026-10-08。在 DeepSeek 给的方案基础上调整了顺序和几处细节（见文末「与原方案的差别」）。

## ✅ 当前状态（2026-10-08 15:50 已全部打通）

| 项 | 实际值 |
| --- | --- |
| Zero Trust | 免费版，team `<team-name>` |
| Access 应用 | `vps-ssh` → `ssh.example.com`，策略 `only-me`（Allow，Emails = `<你的邮箱>`），会话 24h |
| 隧道 | `vps-ssh`，ID `<TUNNEL_ID>`，4 条连接在线 |
| 路由 | `ssh.example.com` → `ssh://localhost:22`，其余 `http_status:404` |
| 服务器 | `/usr/local/bin/cloudflared` 2026.10.0，systemd `cloudflared` active + enabled |
| 本机 | `D:\Tools\cloudflared\cloudflared.exe` 2026.10.0（SHA256 与 GitHub 一致），凭证在 `%USERPROFILE%\.cloudflared\` |
| 本机代理 | `ssh.example.com` DNS 走 `dns-local`、路由走 `direct`（OPERATIONS.md 4.11），不经 sing-box |

验证：未登录访问 `https://ssh.example.com` → 302 到 Access 登录页；经隧道读到 `SSH-2.0-OpenSSH_9.6p1 Ubuntu`，
密钥登录成功，sshd 看到的来源为 `127.0.0.1`；经隧道取得的主机密钥与直连 `<VPS_IP>` 时记录的**一致**。

速度（直连 CF 之后）：SSH banner 2.1–2.4s，完整登录 7.4–11.4s；交互延迟不受影响。
慢在 SSH 握手的几次往返都要过「本地 → CF 阿姆斯特丹（AMS，往返约 250 ms）→ CF 新加坡 → 隧道」，路由规则解决不了。
（服务器侧 cloudflared 连在 sin02/14/21；本机直连 `ssh.example.com` 落 AMS。分到哪个节点由运营商选路决定，会随时间变化。）
**日常用 4.10 的 `<VPS_IP>:22`，sing-box 坏了才用这条。**

**用法**：需要时启动本地转发，SSH 客户端（WindTerm / FinalShell / `ssh -p 2222 root@127.0.0.1`）连 `127.0.0.1:2222`
（用户 `root`，认证同原连接）。更省事的是用便携客户端里的「SSH 应急通道」开关（OPERATIONS.md 4.12），
它自带 cloudflared，不用点「启动」代理也能开。手动开转发：

```powershell
& 'D:\Tools\cloudflared\cloudflared.exe' access tcp --hostname ssh.example.com --url 127.0.0.1:2222
```

凭证过期（24h）后再连会弹浏览器：输邮箱、填邮件验证码。登录后跳到 "Welcome! … enable the Access App Launcher"
页面是正常的（只是没开应用列表页），凭证已经写入本机，可以直接关掉。

下面是当时的操作清单，保留备查。实际执行时：隧道 `vps-ssh` 和服务器上的 cloudflared 二进制已由另一个助手提前建好/装好，
只补做了门禁、注册服务、路由和本机部分；Token 由用户在 FinalShell 里以「行首加空格」方式粘贴执行（root 的
`HISTCONTROL=ignorespace`，未进历史，已核实）。

## 为什么还要这条通道

OPERATIONS.md 4.10 已经让 FinalShell 经 sing-box 的 CF 线路连上 SSH，但那条路**依赖服务端 sing-box 正常**。
一旦把服务端 sing-box 配置改坏，代理和 SSH 会一起断——而那正是最需要 SSH 的时候。

Cloudflare Tunnel 由服务器上的 `cloudflared` **主动向外**连到 Cloudflare，与 sing-box 无关，
也不受源站 IP 被墙、换 IP 影响。

```
FinalShell ── 127.0.0.1:2222 ── 本机 cloudflared access tcp
          ── ssh.example.com:443（CF 边缘）── Cloudflare Access（邮箱验证）
          ── 隧道 ── 服务器 cloudflared ── 127.0.0.1:22（sshd）
```

## 分工

| 步骤 | 在哪做 | 谁做 |
| --- | --- | --- |
| 1–2、5 | Cloudflare 后台 | 你 |
| 3–4 | 服务器（**用 FinalShell**，走 4.10 的通道） | 你 |
| 6 | 本机 | Claude |

---

## 第 1 步：建隧道，拿 Token（CF 后台）

1. 打开 Zero Trust。第一次进会让你选套餐：选 **Free**，起一个 team name（随便填）。
   **可能要求绑定支付方式**（免费版不扣费），有的账号会卡在这一步。
2. **Networks → Tunnels**（新版界面可能叫 Connectors，找不到就搜 "Tunnel"）→ **Create a tunnel**。
3. 类型选 **Cloudflared**，名字填 `vps-ssh`，保存。
4. 运行环境选 **Debian**、**64-bit**。页面会给出一条形如
   `sudo cloudflared service install eyJhIjoi……` 的命令：**只复制 `eyJ` 开头的那一长串 Token**。
5. 下一页会让你填 Public Hostname（路由）——**先别填**，直接离开这个页面。
   隧道已经建好，路由放到第 5 步、等门禁建好之后再加。

## 第 2 步：先建门禁（CF 后台）——必须在加 Public Hostname 之前

> 原方案把这一步放在最后。那样第 5 步一保存，`ssh.example.com` 就对全世界开放，
> 任何人装个 cloudflared 都能敲到你的 sshd，直到门禁建好为止。sshd 目前还开着密码登录，
> root 密码又曾明文写在文档里，所以**门禁先行**。

**Access → Applications → Add an application → Self-hosted**：

| 字段 | 填写 |
| --- | --- |
| Application name | `vps-ssh` |
| Session Duration | `24 hours` |
| Public hostname / Domain | Subdomain `ssh`，Domain `example.com` |

策略：

| 字段 | 填写 |
| --- | --- |
| Policy name | `only-me` |
| Action | **Allow** |
| Include | **Emails** → 你自己的邮箱 |

保存。此时 `ssh.example.com` 还没有路由，门禁先站岗。

## 第 3 步：服务器装 cloudflared（FinalShell）

FinalShell 照常连 `<VPS_IP>:22`（4.10），粘贴没有长度限制，下面的命令可以直接贴。

```bash
cd /usr/local/bin
U=https://github.com/cloudflare/cloudflared/releases/latest/download
curl -fsSLo cloudflared "$U/cloudflared-linux-amd64"
chmod +x cloudflared && cloudflared --version
```

期望打印 `cloudflared version 202x.x.x`。下载失败（GitHub 偶尔被干扰）就重试一两次。

装成系统服务。用 `read -rs` 读 Token，**不进 shell 历史、不回显**：

```bash
read -rs TOK        # 回车后粘贴 Token，再回车（屏幕上不显示）
echo "${#TOK}"      # 打印长度，和 CF 后台那串的长度对一下
cloudflared service install "$TOK"; unset TOK
systemctl is-active cloudflared; systemctl is-enabled cloudflared
```

期望：`active`、`enabled`。失败看 `journalctl -u cloudflared -n 50`。

> Token 会写进 cloudflared 的 systemd 服务定义里，这是它的正常工作方式；只有 root 能读。

## 第 4 步：确认隧道在线（CF 后台）

回到 Tunnels 列表，`vps-ssh` 应显示 **HEALTHY**、1 个 connector。

## 第 5 步：加 Public Hostname（CF 后台）

进 `vps-ssh` → **Public Hostname**（或 Routes）→ **Add a public hostname**：

| 字段 | 填写 |
| --- | --- |
| Subdomain | `ssh` |
| Domain | `example.com` |
| Path | 留空 |
| Service Type | **SSH** |
| URL | `localhost:22` |

保存。CF 会自动建 DNS 记录（CNAME 到 `<隧道ID>.cfargotunnel.com`），不用手动加。
因为第 2 步的门禁已经在，这一刻起它就是受保护的。

**做完告诉 Claude，进入第 6 步。**

## 第 6 步：本机（Claude 来做）

1. 装 cloudflared（`winget install --id Cloudflare.cloudflared`，或官方 GitHub Releases 的 `cloudflared-windows-amd64.exe`）。
2. 跑本地转发：

   ```powershell
   cloudflared access tcp --hostname ssh.example.com --url 127.0.0.1:2222
   ```

   第一次连接会弹浏览器做 Cloudflare Access 的邮箱验证码验证，之后 24 小时内不再要求。
3. FinalShell **新建一个**连接（保留原来那个）：主机 `127.0.0.1`，端口 `2222`，用户 `root`。
4. 实测：读到 SSH banner、能登录。

关于开机自启：可以做成计划任务，但 Access 登录过期时需要弹浏览器重新验证，
后台任务弹不出来，就会表现成「突然连不上」。**建议需要时手动开一个窗口跑**；
要做成后台任务也行，知道有这个现象就好。

## 第 7 步（建议）：关掉 SSH 密码登录

> ✅ **2026-10-08 19:4x 已完成**。先登记并实测了两把钥匙：本机 Windows（RSA，WindTerm 改为只用公钥后 19:40 登录成功）、
> Mac（ED25519，19:28 / 19:30 登录成功）。关后：`sshd -T` 回读两项均为 `no`；新连接用钥匙成功，只用密码被拒
> （`Permission denied (publickey)`）。关之前 24 h 内有 12,727 次密码猜测（累计约 12.7 万次），全部失败；
> 历史上 7 次密码登录成功均为用户本人（09-28 来自用户家宽 IP，10-08 经 `127.0.0.1` 即代理/隧道）。

两条通道都通了以后再做。**前提：你用的 SSH 客户端（WindTerm / FinalShell 等）都是密钥登录**——
还在用密码的先改成密钥，否则关了密码登录就进不去了
（华纳云 VNC 控制台不受影响，那是本地终端登录，不经过 sshd）。

**先决条件**：每台要登录的电脑都已在 `/root/.ssh/authorized_keys` 里登记了自己的公钥，并且**实际用密钥登录成功过**。
截至 2026-10-08 只登记了一把（本机 `admin@DESKTOP-XXXXXXX`，RSA 3072）。别的电脑先 `ssh-keygen -t ed25519 -C "<名字>"`，
把 `.pub` 那一行加进 `authorized_keys`、测通，再做下面这步。每台电脑各用一把钥匙，不要拷私钥。

```bash
printf '%s\n' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' > /etc/ssh/sshd_config.d/01-no-password.conf
sshd -t && systemctl reload-or-restart ssh
sshd -T | grep -E '^(passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication) '
```

- **两项都要关**：`KbdInteractiveAuthentication`（键盘交互认证）经 PAM 同样能输密码登录，
  只关 `PasswordAuthentication` 等于没关。实测服务器上两项原先都是 `yes`。
- 文件名用 `01-` 开头：sshd 对同一选项**取最先读到的值**，云镜像常带 `50-cloud-init.conf`
  写着 `PasswordAuthentication yes`，起名 `90-` 会被它压住、改了等于没改。
- `reload-or-restart`：Ubuntu 24.04 的 ssh 是按需（socket）启动的，服务没在运行时单纯 `reload` 会报错。
  重启 sshd 不会断开已有会话。
- 最后一行应输出 `passwordauthentication no`、`kbdinteractiveauthentication no`、`pubkeyauthentication yes`。
  改完**别关当前会话**，另开一个连接确认还能用密钥登录。
- 关掉后华纳云 VNC 控制台仍可用密码登录（本地终端登录不经 sshd），是最后的保底。

---

## 排错

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 隧道显示 Down / Inactive | cloudflared 没跑起来 | `journalctl -u cloudflared -n 50` |
| `service install` 报 Token 无效 | Token 复制不全 | 对一下第 3 步打印的长度，重新 `read -rs` |
| 连 `127.0.0.1:2222` 立刻断开 | 本地转发没开 / Access 没验证 | 确认那个窗口在跑；浏览器打开 `https://ssh.example.com` 先验证一次 |
| 找不到 hostname | 第 5 步没保存成功 | 回第 5 步 |
| 连上但认证失败 | SSH 本身的密钥/密码问题 | 与隧道无关 |

## 本机开着代理时的路径

本机代理在跑时，`ssh.example.com` 不是国内域名，会走 sing-box 的 CF 线路：
本机 → CF → VPS → CF 边缘 → 隧道 → VPS。绕了一圈但能用。代理关掉时直连 CF 边缘，同样能用。

## 与原方案的差别

| 原方案 | 调整 | 原因 |
| --- | --- | --- |
| 门禁（Access）放在最后 | 移到加 Public Hostname **之前** | 避免 sshd 裸露在公网的窗口期 |
| VNC 控制台分段粘贴 Token | 用 FinalShell + `read -rs` | 4.10 已打通 SSH；分段手敲易错，且留在历史里 |
| 方法 B：Token 再转 base64 | 删掉 | Token 本身就是 base64 字符，再转一次只会更长 |
| `curl … https://github.com/…/cloudflared-linux-amd64` 一行 | 拆成 `U=` 变量 + 短命令 | 原命令超过控制台约 80 字符的粘贴上限（用 FinalShell 时无所谓，留作备用） |
| 计划任务开机自启 | 改为建议手动开 | Access 过期需要浏览器重新验证，后台任务弹不出来 |
| 无 | 加第 7 步关密码登录 | 两条通道都有密钥保护后，密码登录只剩风险 |
