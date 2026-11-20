# YunlongTG

[English](README_EN.md) | [简体中文](README.md)

One-click management script for a Telegram WEB proxy.

Built on the official [tproxy-server](https://github.com/telegramdesktop/tproxy-server). No fork, no patches to the official code. One command to install, one command to get your `t.me/webproxy` link — open it in a browser and go.

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
- If port 443 is taken by another service, the script asks you for a port to use. Client links carry the port number, and the existing service stays untouched.

## Features

- One command to add a node, with a decoy site generated uniquely per machine
- Automatic port detection: free 443 gets used, taken 443 prompts you for a port, no hardcoded default
- Node link plus a terminal QR code — scan with your phone and go
- Change port, secret, or hostname with a single command
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
| `tg change port 9443` | Change the port |
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

- When port 443 is taken by another service, YunlongTG asks you for a port plus a dedicated subdomain
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

**The port I want is taken?**

Pick another one: `tg add --port 9443`.

**The link does not open after install?**

Check status first: `tg status`. Then retry in an incognito window — your browser cache may be stale.

**Lost the link?**

`tg url` prints it any time, `tg qr` gives you a QR code.

**How do I remove everything?**

`tg del` removes the node, `tg uninstall` removes the script.

## Notes

- Ubuntu 22+ / Debian 12+ on x86_64 only
- WEB proxy only (`t.me/webproxy` links), no MTProto share links
- One node per VPS; use one machine per node
