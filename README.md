# 云龙TG

[English](README_EN.md) | [简体中文](README.md)

Telegram WEB 代理一键管理脚本。

基于官方 [tproxy-server](https://github.com/telegramdesktop/tproxy-server)，不 fork、不改官方代码。一行命令装好，一行命令拿到 `t.me/webproxy` 链接，在 Telegram 里打开链接，点连接即可添加代理。

## 一键安装

```bash
bash <(curl -sL https://raw.githubusercontent.com/liyunlong2008/yunlongTG/main/install.sh)
```

安装完成后，请使用 `tg` 命令进行管理。

## 添加节点

```bash
tg add --hostname tg.example.com --email you@example.com
```

- 域名先解析到服务器 IP，A 记录不对装不了
- 邮箱用于申请 HTTPS 证书
- WEB 代理类型固定使用 443 端口，安装前需确保 443 空闲

## 功能

- 一键添加节点，自动生成每台机器不同的伪装站
- 自动检测端口占用，443 被占用时明确报错并提示释放，不支持换端口
- 节点链接 + 终端二维码，手机扫码直达（链接无路径后缀，`server` 仅域名）
- 改密码、改域名，一条命令
- 更新走 GitHub release，失败自动回退
- 卸载干净，不留垃圾

## 命令说明

| 命令 | 说明 |
|---|---|
| `tg` | 打开菜单 |
| `tg add` | 添加节点 |
| `tg info` | 查看节点信息 |
| `tg url` | 显示节点链接 |
| `tg qr` | 显示二维码，`tg qr /root/qr.png` 存成图片 |
| `tg change secret` | 改密码，旧链接全部作废 |
| `tg change hostname tg2.example.com` | 改域名 |
| `tg status` | 查看服务状态 |
| `tg start` | 启动服务 |
| `tg stop` | 停止服务 |
| `tg restart` | 重启服务 |
| `tg log` | 查看日志，`tg log mtproxy -f` 切换组件跟踪 |
| `tg update` | 更新 relay 与脚本 |
| `tg del` | 删除节点 |
| `tg uninstall` | 卸载脚本 |

## 与其他服务共存

同一台 VPS 可以和平共存：

- 443 需空闲；被占用时云龙TG 报错并提示先释放，不影响原有服务
- 不碰已有服务的任何配置，卸载云龙TG 后原有服务原样可用
- 本机已有 Caddy 时自动共用，不会重装冲突

## 更新

```bash
tg update
```

- relay 更新走官方 update-relay.sh，自带失败回滚
- 脚本更新走 GitHub release，失败自动还原上一版本

## 常见问题

**域名解析不正确怎么办？**

检查 A 记录是否指向本机公网 IP，改对后重新执行 `tg add`。

**80 端口被占用？**

证书申请需要 80 端口，先释放再装。


**装完链接打不开？**

先看状态：`tg status`。再开浏览器无痕窗口重试，本地缓存可能过期。

**忘记链接？**

`tg url` 随时取，`tg qr` 出二维码。

**怎么彻底删除？**

`tg del` 删节点，`tg uninstall` 删脚本本体。

## 手动清理

`tg` 命令本身坏了、跑不起来时，手动卸载。按顺序执行：

```bash
# 停服务
systemctl disable --now tproxy-server mtproxy caddy 2>/dev/null

# 删配置和程序
rm -rf /etc/tproxy-server /etc/mtproxy /opt/MTProxy /usr/local/src/tproxy-server
rm -f /etc/systemd/system/tproxy-server.service /etc/systemd/system/mtproxy.service
rm -f /etc/systemd/system/refresh-mtproxy-config.service /etc/systemd/system/refresh-mtproxy-config.timer
systemctl daemon-reload

# 删 Caddy 里的节点配置（装之前有别的站点就手动挑着删）
nano /etc/caddy/Caddyfile
systemctl restart caddy 2>/dev/null

# 删脚本本体
rm -f /usr/local/bin/tg
rm -rf /usr/local/share/tg
```

删完重装：重新跑一键安装命令即可。

## 说明

- 仅支持 Ubuntu 22+ / Debian 12+，x86_64
- 仅做 WEB 代理（`t.me/webproxy` 链接），不含 MTProto 分享链接
- 一台 VPS 一个节点，多节点请多台机器
