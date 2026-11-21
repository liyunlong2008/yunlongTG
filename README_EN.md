# YunlongTG

[English](README_EN.md) | [简体中文](README.md)

One-click management script for a Telegram WEB proxy.

Built on the official [tproxy-server](https://github.com/telegramdesktop/tproxy-server). No fork, no patches to the official code. One command to install, one command to get your `t.me/webproxy` link — open the link in Telegram and tap Connect to add the proxy.

## Install

```bash
bash <(curl -sL https://raw.githubusercontent.com/liyunlong2008/yunlongTG/main/install.sh)
```

After installation, use the `tg` command to manage everything.

## Add a node

```bash
tg add --hostname tg.example.com --email you@example.com
```

- Point the domain to your server first. A wrong A record blocks installation.
- The email is used to issue the HTTPS certificate.
- WEB proxy type fixes HTTPS and port 443; free port 443 before install

## Features

- One command to add a node, with a decoy site generated uniquely per machine
- Automatic port detection: taken 443 fails with a clear message, no port switching
- Node link plus a terminal QR code — scan with your phone and go (no path suffix; `server` is the bare hostname)
- Change secret or hostname with a single command
- Updates shipped via GitHub releases, with automatic rollback on failure
- Clean uninstall, nothing left behind

## Commands

| Command | Description |
|---|---|
| `tg` | Open the menu |
| `tg add` | Add a node |
| `tg info` | Show node information |
| `tg url` | Show the node link |
| `tg qr` | Show a QR code; `tg qr /root/qr.png` saves it as an image |
| `tg change secret` | Change the secret; all old links become invalid |
| `tg change hostname tg2.example.com` | Change the hostname |
| `tg status` | Show service status |
| `tg start` | Start services |
| `tg stop` | Stop services |
| `tg restart` | Restart services |
| `tg log` | View logs; `tg log mtproxy -f` follows a component |
| `tg update` | Update the relay and the script |
| `tg del` | Remove the node |
| `tg uninstall` | Remove the script |

## Coexistence with other services

Multiple services can live on the same VPS in peace:

- Port 443 must be free; if taken, YunlongTG fails with a message and leaves the existing service untouched
- It never touches the existing service's configuration. Uninstall YunlongTG and the original service works exactly as before
- If the machine already runs Caddy, it is shared automatically, no reinstall conflict

## Update

```bash
tg update
```

- The relay is updated with the official update-relay.sh, which rolls back on failure
- The script itself is updated from GitHub releases, restoring the previous version if a download fails

## FAQ

**DNS resolution is wrong.**

Check that the A record points to your server's public IP, then run `tg add` again.

**Port 80 is taken?**

Certificate issuance needs port 80. Free it first, then install.


**The link does not open after install?**

Check status first: `tg status`. Then retry in an incognito window — your browser cache may be stale.

**Lost the link?**

`tg url` prints it any time, `tg qr` gives you a QR code.

**How do I remove everything?**

`tg del` removes the node, `tg uninstall` removes the script.

## Manual cleanup

If the `tg` command itself is broken, uninstall by hand. Run in order:

```bash
# Stop services
systemctl disable --now tproxy-server mtproxy caddy 2>/dev/null

# Remove config and binaries
rm -rf /etc/tproxy-server /etc/mtproxy /opt/MTProxy /usr/local/src/tproxy-server
rm -f /etc/systemd/system/tproxy-server.service /etc/systemd/system/mtproxy.service
rm -f /etc/systemd/system/refresh-mtproxy-config.service /etc/systemd/system/refresh-mtproxy-config.timer
systemctl daemon-reload

# Remove the node config from Caddy (keep other sites if you had them)
nano /etc/caddy/Caddyfile
systemctl restart caddy 2>/dev/null

# Remove the script itself
rm -f /usr/local/bin/tg
rm -rf /usr/local/share/tg
```

To reinstall, run the one-click install command again.

## Notes

- Ubuntu 22+ / Debian 12+ on x86_64 only
- WEB proxy only (`t.me/webproxy` links), no MTProto share links
- One node per VPS; use one machine per node
