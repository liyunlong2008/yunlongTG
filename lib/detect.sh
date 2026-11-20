#!/usr/bin/env bash
# lib/detect.sh — 系统/域名/端口/Caddy 端口冲突检测（design.md 第 5 节）
# 所有函数单独可测；任一检测失败由调用方终止并给可操作提示。
# DETECT_* 变量由调用方消费，shellcheck 单文件分析查不到
# shellcheck disable=SC2034

# 系统检测：Ubuntu 22+ / Debian 12+，x86_64，root
detect_system() {
  require_root
  [ -r /etc/os-release ] || error_exit "无法读取 /etc/os-release" "确认是 Ubuntu 或 Debian 系统"
  . /etc/os-release
  case "$ID" in
    ubuntu)
      [ "${VERSION_ID%%.*}" -ge 22 ] || error_exit "Ubuntu 版本过低（$VERSION_ID）" "请使用 Ubuntu 22.04 及以上"
      ;;
    debian)
      [ "${VERSION_ID%%.*}" -ge 12 ] || error_exit "Debian 版本过低（$VERSION_ID）" "请使用 Debian 12 及以上"
      ;;
    *) error_exit "不支持的系统: $ID" "仅支持 Ubuntu 22+ / Debian 12+" ;;
  esac
  [ "$(uname -m)" = "x86_64" ] || error_exit "不支持的架构: $(uname -m)" "官方 MTProxy 仅支持 x86_64"
}

# 依赖检测：curl/git/jq/qrencode
detect_deps() { require_cmds curl git jq qrencode; }

# 域名解析检测：dig +short 必须 = 本机公网 IPv4
# 用法: detect_dns <hostname> [显式IP]
detect_dns() {
  local hostname="$1" ip="${2:-}" resolved
  command -v dig >/dev/null 2>&1 || apt-get install -y dnsutils >/dev/null 2>&1 || error_exit "安装 dnsutils 失败" "手动执行 apt-get install -y dnsutils"
  resolved=$(dig +short "$hostname" A 2>/dev/null | grep -E '^[0-9.]+$' | tail -1)
  [ -n "$resolved" ] || error_exit "域名 $hostname 无解析记录" "先到域名服务商添加 A 记录指向本机 IP"
  if [ -z "$ip" ]; then
    ip=$(public_ip) || error_exit "获取本机公网 IP 失败" "用 tg add --ip <公网IP> 显式传入"
    [ -n "$ip" ] || error_exit "获取本机公网 IP 失败" "用 tg add --ip <公网IP> 显式传入"
  fi
  [ "$resolved" = "$ip" ] || error_exit "域名解析不正确，请检查 A 记录" "$hostname 当前解析到 $resolved，本机 IP 是 $ip，改对 A 记录后重试"
  info "域名解析正确: $hostname -> $resolved"
}

# 检测 443 占用者。输出写入全局变量：
#   DETECT_443 occupier: "free" | "caddy" | "other"(变量 DETECT_443_PID)
#   DETECT_HAS_CADDY: "yes" | "no"（本机是否已有 caddy，含仅二进制未跑的场景）
detect_ports() {
  DETECT_HAS_CADDY="no"
  if systemctl list-unit-files 2>/dev/null | grep -q '^caddy\.service'; then DETECT_HAS_CADDY="yes"; fi
  if command -v caddy >/dev/null 2>&1; then DETECT_HAS_CADDY="yes"; fi

  local listener
  listener=$(ss -tlnp 'sport = :443' 2>/dev/null | tail -n +2)
  if [ -z "$listener" ]; then
    DETECT_443="free"
    # 443 空闲但本机有 caddy：仍算模式 C（共用 caddy，它只是没在跑或没占 443）
    if [ "$DETECT_HAS_CADDY" = "yes" ]; then
      info "检测到本机已有 Caddy"
    fi
    return 0
  fi
  if echo "$listener" | grep -q 'caddy'; then
    DETECT_443="caddy"
    return 0
  fi
  DETECT_443="other"
  DETECT_443_PID=$(echo "$listener" | grep -oP 'pid=\K[0-9]+' | head -1)
  DETECT_443_NAME=$(echo "$listener" | grep -oP '"\K[^"]+' | head -1)
  # shellcheck disable=SC2034  # 两个变量供调用方/提示使用
  :
  return 0
}

# 模式判定：输出 DETECT_MODE（A/B/C）
decide_mode() {
  detect_ports
  case "$DETECT_443" in
    free)
      if [ "$DETECT_HAS_CADDY" = "yes" ]; then
        DETECT_MODE="C"   # 本机已有 caddy（未占 443）：共用，443 仍可用
      else
        DETECT_MODE="A"
      fi
      ;;
    caddy)  DETECT_MODE="C" ;;
    other)  DETECT_MODE="B" ;;
  esac
}

# 模式 B 前置：80 必须空闲（ACME 回落 HTTP-01），目标端口必须空闲
detect_mode_b_ports() {
  local want_port="${1:?目标端口不能为空}"
  local l80 lport
  l80=$(ss -tlnp 'sport = :80' 2>/dev/null | tail -n +2)
  [ -z "$l80" ] || error_exit "80 端口被占用" "Caddy 需要走 80 做 HTTP-01 签证书，先释放 80，或改用 DNS 验证（需联系作者）"
  lport=$(ss -tlnp "sport = :$want_port" 2>/dev/null | tail -n +2)
  [ -z "$lport" ] || error_exit "$want_port 端口被占用" "换一个端口: tg add --port <端口>"
}

# 重入检测：官方配置已存在 → 拒绝 add
detect_reinstall() {
  [ -f "$TPROXY_CONFIG" ] && error_exit "本机已安装 tproxy" "查看状态用 tg status，改配置用 tg change，重装先 tg del"
}

# 汇总打印（add 前给用户看一眼）
detect_summary() {
  info "正在检测系统环境..."
  detect_system
  detect_deps
  info "系统检测通过: $(. /etc/os-release && echo "$PRETTY_NAME") x86_64"
}
