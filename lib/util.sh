#!/usr/bin/env bash
# lib/util.sh — 颜色/日志/确认/工具函数
# 文案规范（design.md 第 10 节）：短句、动词开头、一句一行、0 emoji、报错给下一步动作。

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

info() { echo -e "${BLUE}信息${PLAIN}: $1"; }
success() { echo -e "${GREEN}成功${PLAIN}: $1"; }
warn() { echo -e "${YELLOW}注意${PLAIN}: $1"; }
error() { echo -e "${RED}错误${PLAIN}: $1" >&2; }
# 报错必须给下一步动作：error_exit "原因" "下一步动作"
error_exit() {
  error "$1"
  [ -n "$2" ] && echo -e "${YELLOW}请执行${PLAIN}: $2" >&2
  exit 1
}

# root 检查
require_root() {
  [ "$(id -u)" -eq 0 ] || error_exit "请用 root 用户运行" "sudo -i 后再执行本命令"
}

# 是/否确认，默认否（避免重复确认的啰嗦写法）
confirm() {
  local prompt="$1"
  read -rp "$prompt (y/N): " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

# 依赖检查：缺则 apt 装，装不上报错
require_cmds() {
  local missing=()
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  [ ${#missing[@]} -eq 0 ] && return 0
  info "缺少依赖: ${missing[*]}，正在安装..."
  apt-get update -y >/dev/null 2>&1 || error_exit "apt-get update 失败" "检查网络后重试"
  for cmd in "${missing[@]}"; do
    # qrencode 的包名同名；其余按命令名装
    apt-get install -y "$cmd" >/dev/null 2>&1 || error_exit "安装 $cmd 失败" "手动执行 apt-get install -y $cmd 后重试"
  done
}

# 生成 32 位 hex 随机串
gen_hex() {
  # 16 字节 = 32 hex
  head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# JSON 字段读写（jq）
json_get() { jq -r "$1" "$NODE_JSON" 2>/dev/null; }
json_set() {
  local updates="$1" tmp
  tmp=$(mktemp)
  jq "$updates" "$NODE_JSON" > "$tmp" && mv "$tmp" "$NODE_JSON" && chmod 600 "$NODE_JSON"
}

# 节点是否已登记
node_exists() { [ -s "$NODE_JSON" ] && jq -e '.hostname' "$NODE_JSON" >/dev/null 2>&1; }

# systemctl 服务状态：active 返回 0
svc_active() { systemctl is-active --quiet "$1"; }

# 计算公网 IPv4（官方同款 ipify）
public_ip() { curl -4 -s --max-time 8 https://api.ipify.org; }

# 版本号读取
tg_version() { cat "$VERSION_FILE" 2>/dev/null || echo "dev"; }
