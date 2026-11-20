#!/usr/bin/env bash
# install.sh — 云龙TG 一键引导（design.md 第 9 节）
# 只做引导，不装代理。代理由 tg add 装。
# 用法: bash <(curl -sL https://raw.githubusercontent.com/liyunlong2008/yunlongTG/main/install.sh)

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; PLAIN='\033[0m'
info() { echo -e "${BLUE}信息${PLAIN}: $1"; }
success() { echo -e "${GREEN}成功${PLAIN}: $1"; }
error_exit() { echo -e "${RED}错误${PLAIN}: $1" >&2; [ -n "$2" ] && echo -e "请执行: $2" >&2; exit 1; }

REPO_URL="https://github.com/liyunlong2008/yunlongTG"
TARBALL_URL="https://github.com/liyunlong2008/yunlongTG/archive/refs/heads/main.tar.gz"
TG_BIN="/usr/local/bin/tg"
TG_SHARE_DIR="/usr/local/share/tg"

echo ""
echo "==================== 云龙TG ===================="
echo ""

# 1. 系统检测
[ "$(id -u)" -eq 0 ] || error_exit "请用 root 用户运行" "sudo -i 后重新执行安装命令"
[ "$(uname -m)" = "x86_64" ] || error_exit "不支持的架构: $(uname -m)" "仅支持 x86_64"
if [ -r /etc/os-release ]; then
  . /etc/os-release
  case "$ID" in
    ubuntu) [ "${VERSION_ID%%.*}" -ge 22 ] || error_exit "Ubuntu 版本过低（$VERSION_ID）" "请使用 Ubuntu 22.04 及以上" ;;
    debian) [ "${VERSION_ID%%.*}" -ge 12 ] || error_exit "Debian 版本过低（$VERSION_ID）" "请使用 Debian 12 及以上" ;;
    *) error_exit "不支持的系统: $ID" "仅支持 Ubuntu 22+ / Debian 12+" ;;
  esac
else
  error_exit "无法读取 /etc/os-release" "确认是 Ubuntu 或 Debian 系统"
fi
info "系统检测通过: $PRETTY_NAME x86_64"

# 2. 已装 tg → 提示直接用
if [ -x "$TG_BIN" ]; then
  info "检测到已安装 tg 命令"
  info "请使用 tg 命令进行管理"
  exit 0
fi

# 3. 拉整包解压落位
info "正在下载 ${REPO_URL#https://} main 分支..."
tmp=$(mktemp -d)
curl -fsSL --max-time 60 "$TARBALL_URL" | tar -xz -C "$tmp" --strip-components=1 \
  || error_exit "下载失败" "检查网络后重试安装命令"

mkdir -p "$TG_SHARE_DIR/lib"
cp -a "$tmp/lib/." "$TG_SHARE_DIR/lib/"
cp -a "$tmp/tg.sh" "$TG_BIN"
chmod +x "$TG_BIN"
# 版本号取整包里的 VERSION 文件（发版时写入）；整包缺 VERSION 则写当前发布版
if [ -f "$tmp/VERSION" ]; then
  cp -a "$tmp/VERSION" "$TG_SHARE_DIR/VERSION"
else
  echo "v1.0.0" > "$TG_SHARE_DIR/VERSION"
fi

rm -rf "$tmp"
success "安装完成，请使用 tg 命令进行管理"
echo ""
info "下一步: 执行 tg add 添加节点"
info "示例: tg add --hostname tg.example.com --email you@example.com"
