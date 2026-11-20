#!/usr/bin/env bash
# lib/install-core.sh — tg add 编排（design.md 第 5 节模式 A/B/C + 第 7.2 节流水线路径）
# 核心=流水线预构建二进制（下载+sha256 强校验），部署段=分步复用官方 deploy/ 原文件，
# 官方 install.sh 的 go test/go build 段被跳过（VPS 不再需要 Go）。
# CADDY_* 变量由 core_install 主流程与 node_save 消费，shellcheck 单文件分析查不到
# shellcheck disable=SC2034

# ============================================================
# core release 查询与下载（流水线路径）
# ============================================================

# 拉官方源码树（部署段要用官方 deploy/ 原文件：install-mtproxy.sh、
# ensure-token-key.sh、systemd 单元、Caddyfile、firewall.nft 等）。
# 流水线路径下不再跑 go test/go build，VPS 无需 Go。
core_fetch_tproxy() {
  if [ -d "$TPROXY_SRC_DIR/.git" ]; then
    git -C "$TPROXY_SRC_DIR" fetch --all --prune >/dev/null 2>&1
    git -C "$TPROXY_SRC_DIR" reset --hard origin/master >/dev/null 2>&1
  else
    mkdir -p "$(dirname "$TPROXY_SRC_DIR")"
    rm -rf "$TPROXY_SRC_DIR"
    git clone --depth 1 "$TPROXY_REPO_URL" "$TPROXY_SRC_DIR" >/dev/null 2>&1 \
      || error_exit "克隆官方仓库失败" "检查网络后重试: git clone $TPROXY_REPO_URL $TPROXY_SRC_DIR"
  fi
  [ -f "$TPROXY_SRC_DIR/deploy/install-mtproxy.sh" ] \
    || error_exit "官方源码树不完整（缺 deploy/）" "删除 $TPROXY_SRC_DIR 后重试 tg add"
}

# 取最新 core-* release 信息：echo "tag|tproxy_url|mtproxy_url|sha256_url"
core_latest_release() {
  local json tag
  json=$(curl -fsS --max-time 15 "$CORE_RELEASE_API" 2>/dev/null) \
    || error_exit "取不到 core release 列表" "检查网络后重试: curl $CORE_RELEASE_API"
  # 列表按 created_at 倒序；取第一个 core- 前缀且不是 draft 的
  tag=$(echo "$json" | jq -r '[.[] | select(.tag_name | startswith("core-")) | select(.draft == false)][0].tag_name // empty') \
    || error_exit "解析 core release 失败" "稍后重试 tg add；持续失败联系维护者"
  [ -n "$tag" ] || error_exit "尚无 core release 产物" "流水线未产出或被清空，稍后重试 tg add"
  local base
  base="https://github.com/liyunlong2008/yunlongTG/releases/download/$tag"
  echo "$tag|$base/tproxy-server|$base/mtproto-proxy|$base/core.sha256"
}

# 下载 core 产物到临时目录并强校验 sha256；输出临时目录路径（stdout）
# 目录内: tproxy-server mtproto-proxy core.sha256
core_fetch_binaries() {
  local rel dir
  rel=$(core_latest_release)
  local tag
  tag="${rel%%|*}"
  # 分支提示打 stderr（本函数返回值走 stdout，日志不得混入，Bug #5）
  if [ -n "$tag" ]; then
    info "拉取核心产物: $tag" >&2
  else
    info "无已登记版本，直接拉取最新核心产物" >&2
  fi
  dir=$(mktemp -d)
  local tproxy_url mtproxy_url sha_url
  IFS='|' read -r _ tproxy_url mtproxy_url sha_url <<< "$rel"
  curl -fsSL --max-time 300 --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --output "$dir/tproxy-server" "$tproxy_url" \
    || { rm -rf "$dir"; error_exit "下载 tproxy-server 失败" "检查网络后重试 tg add"; }
  curl -fsSL --max-time 300 --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --output "$dir/mtproto-proxy" "$mtproxy_url" \
    || { rm -rf "$dir"; error_exit "下载 mtproto-proxy 失败" "检查网络后重试 tg add"; }
  curl -fsSL --max-time 60 --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --output "$dir/core.sha256" "$sha_url" \
    || { rm -rf "$dir"; error_exit "下载 sha256 清单失败" "检查网络后重试 tg add"; }
  # 强校验：清单逐字节核对，不匹配即终止（供应链闭环，design.md 7.4）
  if ! (cd "$dir" && sha256sum -c core.sha256 --status); then
    rm -rf "$dir"
    error_exit "sha256 校验不通过，已丢弃下载产物" "可能是产物损坏或被篡改，重试 tg add；持续失败联系维护者"
  fi
  echo "$dir"
}

# 生成伪装站到临时目录，输出目录路径（stdout）
core_build_site() {
  local tmp
  tmp=$(mktemp -d)
  site_generate "$tmp"
  # 官方要求 --site-dir 必须有 index.html
  [ -f "$tmp/index.html" ] || error_exit "伪装站生成异常（缺 index.html）" "重试 tg add"
  echo "$tmp"
}

# 跑官方 install.sh（全 flag 非交互）——流水线路径下已废弃不再调用，保留备查（回退源码编译模式用）
# $1=hostname $2=email $3=secret $4=site_dir
core_run_official_install() {
  local host="$1" email="$2" secret="$3" sitedir="$4"
  info "正在安装官方 tproxy（首次编译约几分钟）..."
  bash "$TPROXY_SRC_DIR/install.sh" \
    --hostname "$host" \
    --email "$email" \
    --secret "$secret" \
    --site-dir "$sitedir" \
    --static-routes exact \
    2>&1 | tee /tmp/tg-official-install.log
  local rc=${PIPESTATUS[0]}
  [ "$rc" -eq 0 ] || error_exit "官方安装脚本失败（退出码 $rc）" "查看日志: cat /tmp/tg-official-install.log，修复后重试 tg add"
}

# 从官方 config.json 读字段（只读）
core_official_get() { jq -r "$1" "$TPROXY_CONFIG" 2>/dev/null; }

# ============================================================
# 分步复刻官方 deploy/ 段落（design.md 7.2/7.3：调官方原文件，无自造逻辑）
# 顺序对照官方 install.sh 第 3-16 段。
# ============================================================

# 段 3：apt 依赖（官方 install.sh 125 行）
core_apt_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends ca-certificates curl nftables >/dev/null 2>&1 \
    || error_exit "安装基础依赖失败" "手动执行: apt-get install -y ca-certificates curl nftables"
}

# 段 4：Caddy 安装（官方 install.sh 127-145 行，逐行复刻官方逻辑）
core_install_caddy() {
  local caddy_version=2.11.4
  local caddy_checksum=8220d1f013b6f27510247b2360c9e0ca9f018feebd82515f07635318b34ff9777ccc8fd0b6e6f2486ce3a33fe389fbb7db12d05baa474f4587509fb4f5ebf1c9
  local archive directory
  archive=$(mktemp /tmp/caddy-linux-amd64.XXXXXX.tar.gz)
  directory=$(mktemp -d /tmp/caddy-linux-amd64.XXXXXX)
  curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --output "$archive" "https://github.com/caddyserver/caddy/releases/download/v${caddy_version}/caddy_${caddy_version}_linux_amd64.tar.gz" \
    || { rm -f "$archive"; rm -rf "$directory"; error_exit "下载 Caddy 失败" "检查网络后重试 tg add"; }
  local got
  got=$(sha512sum "$archive" | awk '{print $1}')
  if [ "$got" != "$caddy_checksum" ]; then
    rm -f "$archive"; rm -rf "$directory"
    error_exit "Caddy sha512 校验不通过" "重试 tg add；持续失败联系维护者"
  fi
  tar -C "$directory" -xzf "$archive"
  install -m 0755 "$directory/caddy" /usr/local/bin/caddy
  rm -f "$archive"
  rm -rf "$directory"
  if ! id caddy >/dev/null 2>&1; then
    useradd --system --home /var/lib/caddy --shell /usr/sbin/nologin caddy
  fi
  install -d -o root -g caddy -m 0750 "$(dirname "$CADDYFILE")"
  install -d -o caddy -g caddy -m 0750 /var/lib/caddy
}

# 段 5：MTProxy 部署 = 官方 install-mtproxy.sh 原样跑
# 流水线产物预置 "$MPROXY_HOME/objs/bin/mtproto-proxy + .tproxy-commit → 官方自动跳过编译段
core_install_mtproxy() {
  local bindir="$1"
  if ! id mtproxy >/dev/null 2>&1; then
    useradd --system --home /nonexistent --shell /usr/sbin/nologin mtproxy
  fi
  # 预置预编译产物（官方 install-mtproxy.sh 24-26 行检测匹配即跳过编译）
  if [ ! -x "$MPROXY_HOME/objs/bin/mtproto-proxy" ] \
    || [ ! -f "$MPROXY_HOME/.tproxy-commit" ] \
    || ! grep -Fxq 'f36d8af769ffaeac36978d38c2c0f6d1104c2137' "$MPROXY_HOME/.tproxy-commit"; then
    install -d -o mtproxy -g mtproxy -m 0755 "$MPROXY_HOME/objs/bin"
    install -o root -g root -m 0755 "$bindir/mtproto-proxy" "$MPROXY_HOME/objs/bin/mtproto-proxy"
    printf '%s\n' 'f36d8af769ffaeac36978d38c2c0f6d1104c2137' > "$MPROXY_HOME/.tproxy-commit"
    chown root:root "$MPROXY_HOME/.tproxy-commit"
  fi
  # 官方脚本原样跑：normalize 权限 + 代理秘钥/配置下载段必须让它执行（官方逻辑）
  bash "$TPROXY_SRC_DIR/deploy/install-mtproxy.sh"
}

# 段 6：tproxy 用户（官方 install.sh 149-151 行）
core_user_tproxy() {
  if ! id tproxy >/dev/null 2>&1; then
    useradd --system --home /nonexistent --shell /usr/sbin/nologin tproxy
  fi
}

# 段 7（流水线替换）：二进制落位（官方 install.sh 182-184 行的 install 段）
core_install_relay_binary() {
  local bindir="$1"
  install -o root -g root -m 0755 "$bindir/tproxy-server" "$CORE_BIN"
}

# 段 2（base_path）：官方生成逻辑（install.sh 61 行）
core_gen_base_path() {
  head -c 10 /dev/urandom | base32 | tr 'A-Z' 'a-z' | tr -d '\n'
}

# 段 9：config.json + profiles.json（官方 install.sh 204-222 行，字段与权限逐行一致）
core_write_config() {
  local host="$1" base_path="$2" secret="$3" public_source="$4"
  install -d -o root -g tproxy -m 0750 "$(dirname "$TPROXY_CONFIG")"
  bash "$TPROXY_SRC_DIR/deploy/ensure-token-key.sh"
  cat > "$TPROXY_CONFIG" <<EOF
{
  "public_hostname": "$host",
  "base_path": "$base_path",
  "listen": "127.0.0.1:8080",
  "admin_listen": "127.0.0.1:8081",
$public_source
  "static_routes": "exact",
  "profiles_file": "/run/credentials/tproxy-server.service/profiles.json"
}
EOF
  cat > "$TPROXY_PROFILES" <<EOF
{"profiles":[{"name":"default","secret":"$secret","backend":"127.0.0.1:2398"}]}
EOF
  chown root:tproxy "$TPROXY_CONFIG" "$TPROXY_PROFILES"
  chmod 0640 "$TPROXY_CONFIG"
  chmod 0400 "$TPROXY_PROFILES"
}

# 段 10：mtproxy.env（官方 install.sh 224-274 行，NAT 探测逐行复刻）
# $2=hostname：add 链路 node.json 尚未写出，探测回落必须显式传，不得读登记
core_write_mtproxy_env() {
  local secret="$1" host="${2:-}"
  local backend_secret="$secret"
  if [ "${backend_secret#dd}" != "$backend_secret" ] && [ ${#backend_secret} -eq 34 ]; then
    backend_secret="${backend_secret:2}"
  fi
  # NAT 探测：官方注释语义——1:1 NAT 下 MTProxy 与 middle-end 各算各的地址会话必断
  local mtproxy_nat_args=""
  local local_address public_address candidate
  local_address="$(ip -4 route get 149.154.175.50 2>/dev/null |
    sed -n 's/.*[[:space:]]src[[:space:]]\+\([0-9.]\+\).*/\1/p' | head -n 1)"
  public_address=""
  for probe in https://api.ipify.org https://ifconfig.co/ip https://icanhazip.com; do
    candidate="$(curl -fsSL --ipv4 --max-time 15 "$probe" 2>/dev/null | tr -d '[:space:]')" || continue
    if echo "$candidate" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
      public_address="$candidate"
      break
    fi
  done
  if [ -z "$public_address" ]; then
    if [ -n "$host" ]; then
      public_address="$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1 {print $1}')"
    else
      public_address="$(getent ahostsv4 "$(node_get hostname 2>/dev/null || true)" 2>/dev/null | awk 'NR==1 {print $1}')"
    fi
  fi
  if [ -n "$local_address" ] && [ -n "$public_address" ] && [ "$local_address" != "$public_address" ]; then
    mtproxy_nat_args="--nat-info $local_address:$public_address"
    info "本机在 NAT 后（$local_address -> $public_address），已带 NAT 参数"
  fi
  install -d -o root -g mtproxy -m 0750 "$(dirname "$MPROXY_ENV")"
  cat > "$MPROXY_ENV" <<EOF
MTPROXY_SECRET=$backend_secret
MTPROXY_WORKERS=1
MTPROXY_MAX_CONNECTIONS=4096
MTPROXY_NAT_ARGS=$mtproxy_nat_args
EOF
  chown root:mtproxy "$MPROXY_ENV"
  chmod 0640 "$MPROXY_ENV"
}

# 段 11：Caddyfile + caddy.service 官方覆盖（备份语义照官方 before-tproxy.<时间戳>）
core_install_caddy_config() {
  local host="$1" email="$2"
  install -m 0644 "$TPROXY_SRC_DIR/deploy/Caddyfile" "$(dirname "$CADDYFILE")/Caddyfile.tproxy"
  if [ -e "$CADDYFILE" ] && ! cmp -s "$CADDYFILE" "$TPROXY_SRC_DIR/deploy/Caddyfile"; then
    cp -a "$CADDYFILE" "$(dirname "$CADDYFILE")/Caddyfile.before-tproxy.$(date +%Y%m%d%H%M%S)"
  fi
  install -m 0644 "$TPROXY_SRC_DIR/deploy/Caddyfile" "$CADDYFILE"
  if [ -e "$CADDY_SERVICE" ] && ! cmp -s "$CADDY_SERVICE" "$TPROXY_SRC_DIR/deploy/caddy.service"; then
    cp -a "$CADDY_SERVICE" "$(dirname "$CADDY_SERVICE")/caddy.service.before-tproxy.$(date +%Y%m%d%H%M%S)"
  fi
  install -m 0644 "$TPROXY_SRC_DIR/deploy/caddy.service" "$CADDY_SERVICE"
  install -d -m 0755 "$SYSTEMD_UNIT_DIR/caddy.service.d"
  cat > "$SYSTEMD_UNIT_DIR/caddy.service.d"/tproxy.conf <<EOF
[Service]
Environment=TPROXY_HOSTNAME=$host
Environment=TPROXY_SITE_ROOT="$TPROXY_SITE_ROOT"
Environment=ACME_EMAIL=$email
EOF
}

# 段 12：systemd 单元（官方 install.sh 293-299 行）
core_install_units() {
  install -m 0644 "$TPROXY_SRC_DIR/deploy/tproxy-server.service" "$SYSTEMD_UNIT_DIR/tproxy-server.service"
  install -m 0644 "$TPROXY_SRC_DIR/deploy/mtproxy.service" "$SYSTEMD_UNIT_DIR/mtproxy.service"
  install -m 0644 "$TPROXY_SRC_DIR/deploy/tproxy-firewall.service" "$SYSTEMD_UNIT_DIR/tproxy-firewall.service"
  install -m 0644 "$TPROXY_SRC_DIR/deploy/refresh-mtproxy-config.service" "$SYSTEMD_UNIT_DIR/refresh-mtproxy-config.service"
  install -m 0644 "$TPROXY_SRC_DIR/deploy/refresh-mtproxy-config.timer" "$SYSTEMD_UNIT_DIR/refresh-mtproxy-config.timer"
  install -m 0644 "$TPROXY_SRC_DIR/deploy/firewall.nft" /etc/tproxy-server/firewall.nft
  install -m 0755 "$TPROXY_SRC_DIR/deploy/refresh-mtproxy-config.sh" /usr/local/sbin/refresh-mtproxy-config
}

# 段 13-15：配置校验 + 启动（官方 install.sh 301-312 行）
core_start_services() {
  local host="$1" email="$2"
  "$CORE_BIN" -config "$TPROXY_CONFIG" -profiles-file "$TPROXY_PROFILES" -check \
    || error_exit "核心配置校验未通过" "查看: $CORE_BIN -config $TPROXY_CONFIG -check，修复后重试 tg add"
  TPROXY_HOSTNAME="$host" TPROXY_SITE_ROOT="$TPROXY_SITE_ROOT" ACME_EMAIL="$email" \
    /usr/local/bin/caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1 \
    || error_exit "Caddy 配置校验未通过" "查看: caddy validate --config $CADDYFILE，修复后重试 tg add"
  systemctl daemon-reload
  systemctl enable --now tproxy-firewall.service >/dev/null 2>&1 || true
  systemctl enable --now mtproxy.service >/dev/null 2>&1 || true
  systemctl restart mtproxy.service || true
  systemctl enable --now tproxy-server.service >/dev/null 2>&1 || true
  systemctl enable --now refresh-mtproxy-config.timer >/dev/null 2>&1 || true
  systemctl enable --now caddy.service >/dev/null 2>&1 || true
  systemctl restart caddy.service || true
}

# ============================================================
# 模式 A：443 空闲、无 caddy —— 官方部署段原样分步跑
# ============================================================
core_install_mode_a() {
  local host="$1" email="$2" secret="$3" sitedir="$4" bindir="$5"
  # 官方自己装 Caddy 占 443
  core_apt_deps
  core_install_caddy
  core_install_mtproxy "$bindir"
  core_user_tproxy
  core_install_relay_binary "$bindir"
  # 伪装站落位（官方 install.sh 186-196 行逻辑）
  install -d -o root -g root -m 0755 "$TPROXY_SITE_ROOT"
  if [ ! -e "$TPROXY_SITE_ROOT/index.html" ]; then
    cp -a "$sitedir/." "$TPROXY_SITE_ROOT/"
    chown -R root:root "$TPROXY_SITE_ROOT"
  fi
  local public_source='  "public_dir": "'"$TPROXY_SITE_ROOT"'",'
  core_write_config "$host" "$(core_gen_base_path)" "$secret" "$public_source"
  core_write_mtproxy_env "$secret" "$host"
  core_install_caddy_config "$host" "$email"
  core_install_units
  core_start_services "$host" "$email"
  core_wait_ready 20 || error_exit "tproxy 未就绪" "查看日志: journalctl -u tproxy-server -n 50"
  CADDY_BACKUP=""
  CADDY_SHARED="false"
}

# ============================================================
# 模式 B：443 被其他 TLS 服务占用、本机无 caddy
# 太白金星拍板：官方逻辑下 Caddyfile 占 443 会启动失败，视为预期：
# 部署段跑完核心就位硬校验 → 重写 Caddyfile 为用户指定端口 → validate → restart → healthz
# ============================================================
core_install_mode_b() {
  local host="$1" email="$2" secret="$3" sitedir="$4" port="$5" bindir="$6"
  info "443 端口被占用，安装后自动改用端口 $port"
  core_apt_deps
  core_install_caddy
  core_install_mtproxy "$bindir"
  core_user_tproxy
  core_install_relay_binary "$bindir"
  install -d -o root -g root -m 0755 "$TPROXY_SITE_ROOT"
  if [ ! -e "$TPROXY_SITE_ROOT/index.html" ]; then
    cp -a "$sitedir/." "$TPROXY_SITE_ROOT/"
    chown -R root:root "$TPROXY_SITE_ROOT"
  fi
  local public_source='  "public_dir": "'"$TPROXY_SITE_ROOT"'",'
  core_write_config "$host" "$(core_gen_base_path)" "$secret" "$public_source"
  core_write_mtproxy_env "$secret" "$host"
  core_install_caddy_config "$host" "$email"
  core_install_units
  # 此刻 caddy restart 会因 443 冲突失败（官方语义），跳过整体启动段
  "$CORE_BIN" -config "$TPROXY_CONFIG" -profiles-file "$TPROXY_PROFILES" -check \
    || error_exit "核心配置校验未通过" "查看: $CORE_BIN -config $TPROXY_CONFIG -check，修复后重试 tg add"
  systemctl daemon-reload
  systemctl enable --now tproxy-firewall.service >/dev/null 2>&1 || true
  systemctl enable --now mtproxy.service >/dev/null 2>&1 || true
  systemctl restart mtproxy.service || true
  systemctl enable --now tproxy-server.service >/dev/null 2>&1 || true
  systemctl enable --now refresh-mtproxy-config.timer >/dev/null 2>&1 || true
  # 核心就位硬校验
  [ -f "$TPROXY_CONFIG" ] || error_exit "官方配置缺失" "查看日志后重试"

  # 接管 Caddyfile：重写为用户指定端口的 site block
  local backup
  backup=$(caddy_backup)
  caddy_render_site "$host" "$port" "$(core_official_get '.base_path // ""')" "$email"
  cp "$TG_CADDY_DIR/site.conf" "$CADDYFILE"
  caddy_apply
  core_wait_ready 20 || error_exit "tproxy 未就绪" "查看日志: journalctl -u tproxy-server -n 50"
  CADDY_BACKUP="$backup"
  CADDY_SHARED="false"
  CADDY_PORT_OVERRIDDEN="true"
}

# ============================================================
# 模式 C：本机已有 caddy —— 部署段跑完立即恢复 before-tproxy 备份，
# 再追加我们的 site block（共用 caddy）
# 太白金星拍板批准此编排；失败必须原样还原并大声报错。
# ============================================================
core_install_mode_c() {
  local host="$1" email="$2" secret="$3" sitedir="$4" port="$5" bindir="$6"
  local pre_backup
  pre_backup=$(caddy_backup)

  core_apt_deps
  core_install_mtproxy "$bindir"
  core_user_tproxy
  core_install_relay_binary "$bindir"
  install -d -o root -g root -m 0755 "$TPROXY_SITE_ROOT"
  if [ ! -e "$TPROXY_SITE_ROOT/index.html" ]; then
    cp -a "$sitedir/." "$TPROXY_SITE_ROOT/"
    chown -R root:root "$TPROXY_SITE_ROOT"
  fi
  local public_source='  "public_dir": "'"$TPROXY_SITE_ROOT"'",'
  core_write_config "$host" "$(core_gen_base_path)" "$secret" "$public_source"
  core_write_mtproxy_env "$secret" "$host"
  core_install_caddy_config "$host" "$email"
  core_install_units

  # 官方部署段跑完，恢复官方的 before-tproxy 备份（恢复原 Caddyfile）
  local official_backup
  official_backup=$(find "$(dirname "$CADDYFILE")" -maxdepth 1 -name 'Caddyfile.before-tproxy.*' -type f 2>/dev/null | sort -r | head -1)
  if [ -n "$official_backup" ]; then
    cp -a "$official_backup" "$CADDYFILE"
    info "已恢复原 Caddyfile（安装前备份）"
  else
    warn "无安装前备份，保留当前 Caddyfile"
  fi

  # 追加我们的 site block
  caddy_render_site "$host" "$port" "$(core_official_get '.base_path // ""')" "$email"
  caddy_attach_fragment
  if ! caddy_validate; then
    caddy_restore_backup "$pre_backup"
    error_exit "Caddy 配置校验失败，已还原原 Caddyfile" "查看详情: caddy validate --config $CADDYFILE，修复后重试 tg add"
  fi
  caddy_apply
  systemctl daemon-reload
  systemctl enable --now tproxy-firewall.service >/dev/null 2>&1 || true
  systemctl enable --now mtproxy.service >/dev/null 2>&1 || true
  systemctl restart mtproxy.service || true
  systemctl enable --now tproxy-server.service >/dev/null 2>&1 || true
  systemctl enable --now refresh-mtproxy-config.timer >/dev/null 2>&1 || true
  core_wait_ready 20 || {
    caddy_restore_backup "$pre_backup"
    systemctl reload caddy 2>/dev/null || true
    error_exit "tproxy 未就绪，已还原原 Caddyfile" "查看日志: journalctl -u tproxy-server -n 50"
  }
  CADDY_BACKUP="$pre_backup"
  CADDY_SHARED="true"
}

# 等官方 admin 端口 ready（同官方逻辑）
core_wait_ready() {
  local timeout="${1:-20}" i
  for ((i = 0; i < timeout; i++)); do
    curl -fsS --max-time 2 http://127.0.0.1:8081/readyz >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# ============================================================
# tg add 主入口
# ============================================================
core_add() {
  local host="" email="" secret="" port="" explicit_ip=""
  local args=("$@")
  local i
  for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[$i]}" in
      --hostname) host="${args[$((i + 1))]}" ; i=$((i + 1)) ;;
      --email) email="${args[$((i + 1))]}" ; i=$((i + 1)) ;;
      --secret) secret="${args[$((i + 1))]}" ; i=$((i + 1)) ;;
      --port) port="${args[$((i + 1))]}" ; i=$((i + 1)) ;;
      --ip) explicit_ip="${args[$((i + 1))]}" ; i=$((i + 1)) ;;
      *) error_exit "未知参数: ${args[$i]}" "查看用法: tg add --help" ;;
    esac
  done

  detect_summary
  detect_reinstall

  # 参数补齐
  [ -n "$host" ] || error_exit "缺少 --hostname" "用法: tg add --hostname tg.example.com --email you@example.com"
  [ -n "$email" ] || error_exit "缺少 --email" "ACME 签证书需要邮箱，用法: tg add --email you@example.com"
  [ -n "$secret" ] || secret=$(gen_hex)
  [ ${#secret} -ge 32 ] || error_exit "secret 必须 32 位 hex" "去掉 --secret 让脚本自动生成"

  detect_dns "$host" "$explicit_ip"
  decide_mode

  case "$DETECT_MODE" in
    A) info "模式 A：443 空闲，全新安装" ;;
    B)
      # 443 被占用：必须由用户指定端口，不预设默认值
      if [ -z "$port" ]; then
        info "443 端口被占用（占用者: $DETECT_443_NAME）"
        while [ -z "$port" ]; do
          read -rp "请输入 WEB 代理使用的端口: " port
          [ -n "$port" ] || info "端口不能为空，请输入"
        done
      fi
      detect_mode_b_ports "$port"
      info "模式 B：443 被占用（$DETECT_443_NAME），改用端口 $port"
      ;;
    C)
      [ -n "$port" ] || port=$DEFAULT_PORT
      info "模式 C：共用本机 Caddy，端口 $port"
      ;;
  esac

  # 拉官方源码树（部署段复用官方 deploy/ 原文件，Bug #4 根修）
  core_fetch_tproxy

  # 生成伪装站
  info "正在生成伪装站..."
  local sitedir
  sitedir=$(core_build_site)

  # 拉取流水线 core 产物（下载 + sha256 强校验，不通过即终止）
  local bindir core_tag
  bindir=$(core_fetch_binaries)
  core_tag=$(core_latest_release | cut -d'|' -f1)

  # 分模式安装
  CADDY_BACKUP=""; CADDY_SHARED="false"; CADDY_PORT_OVERRIDDEN="false"
  case "$DETECT_MODE" in
    A) core_install_mode_a "$host" "$email" "$secret" "$sitedir" "$bindir" ;;
    B) core_install_mode_b "$host" "$email" "$secret" "$sitedir" "$port" "$bindir" ;;
    C) core_install_mode_c "$host" "$email" "$secret" "$sitedir" "$port" "$bindir" ;;
  esac
  rm -rf "$bindir"

  # 官方跑完，从 config.json 读回实际 base_path（官方自动生成的随机 slug）
  local base_path
  base_path=$(core_official_get '.base_path // ""')

  # 登记
  node_save \
    "hostname=$host" \
    "base_path=$base_path" \
    "port=$port" \
    "secret=$secret" \
    "email=$email" \
    "mode=$DETECT_MODE" \
    "caddy_shared=$CADDY_SHARED" \
    "caddyfile_backup=$CADDY_BACKUP" \
    "site_type=generated-static" \
    "installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "relay_version=$core_tag"

  rm -rf "$sitedir"

  echo ""
  success "安装完成"
  info "使用 tg url 查看节点链接"
  info "使用 tg qr 查看二维码"
  info "使用 tg status 查看服务状态"
}
