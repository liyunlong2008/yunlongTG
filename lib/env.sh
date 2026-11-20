#!/usr/bin/env bash
# lib/env.sh — 云龙TG 常量（发布配置终版，design.md 第 9 节）
# 命中红线：写死的三个地址供运行时使用，不要改。

# 品牌名
BRAND="云龙TG"

# 仓库与安装源
REPO_URL="https://github.com/liyunlong2008/yunlongTG"
RAW_URL="https://raw.githubusercontent.com/liyunlong2008/yunlongTG/main"
TPROXY_REPO_URL="https://github.com/telegramdesktop/tproxy-server"

# 官方源码与脚本自更新落位
TPROXY_SRC_DIR="/usr/local/src/tproxy-server"
TG_SRC_DIR="/usr/local/src/tg-script"
TG_SHARE_DIR="/usr/local/share/tg"
TG_PREV_DIR="/usr/local/share/tg.prev"
TG_BIN="/usr/local/bin/tg"
TG_LIB_DIR="/usr/local/share/tg/lib"

# 我们自有状态（可用环境变量覆盖，便于测试）
TG_ETC_DIR="${TG_ETC_DIR:-/etc/tg}"
NODE_JSON="${NODE_JSON:-/etc/tg/node.json}"
TG_CADDY_DIR="${TG_CADDY_DIR:-/etc/tg/caddy}"
VERSION_FILE="${VERSION_FILE:-/usr/local/share/tg/VERSION}"

# 官方路径（只读，红线：不写 /etc/tproxy-server、/etc/mtproxy 以外的官方文件）
TPROXY_CONFIG="/etc/tproxy-server/config.json"
TPROXY_PROFILES="/etc/tproxy-server/profiles.json"
MPROXY_ENV="/etc/mtproxy/mtproxy.env"
CADDYFILE="/etc/caddy/Caddyfile"
CADDY_SERVICE="/etc/systemd/system/caddy.service"

# 端口策略：443 空闲用 443；被占用时由用户输入端口，脚本不预设默认值
DEFAULT_PORT=443
