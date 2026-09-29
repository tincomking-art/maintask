# sgm4 邮件（Gmail）收发排障与修复

配置模板：[`mail-policy.yaml`](./mail-policy.yaml)（Mihomo / Clash Meta / Clash Verge Rev）。

## 常见原因（按概率排序）

| # | 现象 | 原因 | 处理 |
|---|------|------|------|
| 1 | 能收不能发，发信超时 | 当前节点封了 SMTP 端口 465/587/25（机场普遍这样做） | 用单独的 `📧 邮件` 策略组，只挑放行 SMTP 的节点 |
| 2 | 收发都超时，但浏览器能打开 Gmail | 邮件客户端没走代理：开的是「系统代理」，而 Outlook / Foxmail / 部分客户端的 IMAP/SMTP 不读系统代理 | 开启 **TUN 模式**（服务模式），让所有进程流量进 Clash |
| 3 | TUN 已开还是走了别的组 | 规则顺序：前面的 `GEOSITE,google` 等规则先命中 | 邮件规则放到 `rules:` 最前面 |
| 4 | 连得上但一直提示密码错误 | Gmail 已不再接受普通密码登录 IMAP/SMTP | 客户端里用「Google 登录（OAuth）」添加账号，或开两步验证后生成 **应用专用密码** |
| 5 | 偶尔能用，经常断 | 策略组是 url-test / fallback，节点自动切换打断邮件长连接 | 邮件组用 `select` 固定节点 |

## 1. 先确认问题出在哪一段

在 sgm4 上执行（Windows 10+ 自带 `curl.exe`，PowerShell 里请写 `curl.exe`；
`7890` 换成你的 mixed-port）：

```bash
# 收信 IMAP 993：成功会看到 "* OK Gmail IMAPv4rev1 ready"
curl -v --connect-timeout 10 -x socks5h://127.0.0.1:7890 imaps://imap.gmail.com/

# 发信 SMTPS 465：成功会看到 "220 smtp.gmail.com ESMTP"
curl -v --connect-timeout 10 -x socks5h://127.0.0.1:7890 smtps://smtp.gmail.com:465

# 发信 587 STARTTLS
curl -v --connect-timeout 10 -x socks5h://127.0.0.1:7890 --ssl-reqd smtp://smtp.gmail.com:587
```

输出最后出现 `Login denied` / `530 Authentication Required` 一类的报错是**正常的**（没带账号密码），
只要看到上面的欢迎语，说明网络这一段是通的。

判断：

- 三条都能看到欢迎语 → 网络没问题，问题在客户端没走代理（原因 2）或账号认证（原因 4）。
- 993 通、465/587 超时 → 节点封了 SMTP（原因 1），在 Clash 面板里把 `📧 邮件` 组切到别的节点逐个重试，
  找到能通的节点后固定下来，并把它的关键字写进 `filter`。
- 全部超时 → 当前节点本身不通或规则把流量送去了 DIRECT，看 Clash「连接」面板中这几个连接命中的规则和策略。

## 2. 合并配置

1. 打开 sgm4 上 Clash 正在使用的配置（Clash Verge Rev：订阅 → 右键 →「编辑文件」，
   或者在「全局扩展配置 / Merge」里写，订阅更新后不会被覆盖）。
2. 把 `mail-policy.yaml` 中的 `sniffer`、`proxy-groups`、`rules` 三段合进去：
   - `proxy-groups`：追加 `📧 邮件` 组。
   - `rules`：邮件规则插到**最前面**（Merge 里用 `prepend-rules:`，`proxy-groups` 用 `prepend-proxy-groups:`）。
3. 按实际节点名称修改 `filter`（只留放行 SMTP 的节点）。
4. 重载配置，开启 TUN 模式，重跑第 1 步验证。

## 3. 客户端侧

- Gmail 网页 → 设置 → 查看所有设置 → 「转发和 POP/IMAP」确认 IMAP 已启用。
- 服务器参数：IMAP `imap.gmail.com:993 SSL`；SMTP `smtp.gmail.com:465 SSL` 或 `:587 STARTTLS`。
- 认证：优先客户端内置的 Google 登录；不支持 OAuth 的客户端（如老版本 Foxmail）
  需要 Google 账号开两步验证，然后在 <https://myaccount.google.com/apppasswords> 生成应用专用密码代替登录密码。
