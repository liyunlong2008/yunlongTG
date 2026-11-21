#!/usr/bin/env bash
# lib/env.sh
# shellcheck shell=bash
# 云龙TG 常量（发布配置终版，design.md 第 9 节）
# 命中红线：写死的三个地址供运行时使用，不要改。
# 以下常量由 tg.sh 统一 source 后跨模块消费，shellcheck 单文件分析查不到消费方
# shellcheck disable=SC2034

# 品牌名
BRAND="云龙TG"

# 仓库与安装源
REPO_URL="https://github.com/liyunlong2008/yunlongTG"
RAW_URL="https://raw.githubusercontent.com/liyunlong2008/yunlongTG/main"
TPROXY_REPO_URL="https://github.com/telegramdesktop/tproxy-server"
# core release 列表接口（design.md 7.2）：按 tag 前缀 core- 过滤取最新
CORE_RELEASE_API="${CORE_RELEASE_API:-https://api.github.com/repos/liyunlong2008/yunlongTG/releases}"

# 官方源码与脚本自更新落位（安装根 TG_SHARE_DIR 由 tg.sh 按落位导出，勿在此写死）
TPROXY_SRC_DIR="${TPROXY_SRC_DIR:-/usr/local/src/tproxy-server}"
TG_SRC_DIR="${TG_SRC_DIR:-/usr/local/src/tg-script}"
TG_PREV_DIR="${TG_PREV_DIR:-$TG_SHARE_DIR.prev}"
TG_BIN="${TG_BIN:-/usr/local/bin/tg}"

# 我们自有状态（可用环境变量覆盖，便于测试）
TG_ETC_DIR="${TG_ETC_DIR:-/etc/tg}"
NODE_JSON="${NODE_JSON:-/etc/tg/node.json}"
TG_CADDY_DIR="${TG_CADDY_DIR:-/etc/tg/caddy}"
# 安装根：tg.sh 按落位写死 LIB_DIR=/usr/local/share/tg/lib 并导出 TG_SHARE_DIR 供此处对齐
# 注意：tg.sh 在 source 本文件前已 export TG_SHARE_DIR，这里不覆盖已注入的值
VERSION_FILE="${VERSION_FILE:-$TG_SHARE_DIR/VERSION}"

# 官方路径（默认值即官方文档化路径；${VAR:-default} 可注入便于测试）
TPROXY_CONFIG="${TPROXY_CONFIG:-/etc/tproxy-server/config.json}"
TPROXY_PROFILES="${TPROXY_PROFILES:-/etc/tproxy-server/profiles.json}"
MPROXY_ENV="${MPROXY_ENV:-/etc/mtproxy/mtproxy.env}"
# MTProxy 预置产物根目录（流水线预编译落位；官方 install-mtproxy.sh 编译目标亦在此）
MPROXY_HOME="${MPROXY_HOME:-/opt/MTProxy}"
CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
CADDY_SERVICE="${CADDY_SERVICE:-/etc/systemd/system/caddy.service}"
# Caddyfile 备份前缀（del/uninstall 清备份用；与其余常量同风格可注入）
CADDY_BACKUP_PREFIX="${CADDY_BACKUP_PREFIX:-$(dirname "$CADDYFILE")/Caddyfile.before-tg}"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"

# 端口策略：WEB 代理类型固定 HTTPS + 443（协议规定），不支持修改端口
DEFAULT_PORT=443

# core 二进制下载校验落位（流水线路径，design.md 7.1/7.2）
CORE_BIN="${CORE_BIN:-/usr/local/bin/tproxy-server}"
CADDY_BIN="${CADDY_BIN:-/usr/local/bin/caddy}"
CORE_LOCK="${CORE_LOCK:-/run/lock/tproxy-server-update.lock}"
# 伪装站官方落位（官方 install.sh 186 行路径，官方默认 /srv/tproxy-site）
TPROXY_SITE_ROOT="${TPROXY_SITE_ROOT:-/srv/tproxy-site}"
