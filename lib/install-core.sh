#!/usr/bin/env bash
# lib/install-core.sh — tg add 编排（design.md 第 5 节模式 A/B/C）
# 原则：官方 install.sh 原样跑，我们不重造；我们的增量 = 检测 + 伪装站 + Caddyfile 接管 + 登记。
# CADDY_* 变量由 core_install 主流程与 node_save 消费，shellcheck 单文件分析查不到
# shellcheck disable=SC2034

# 拉官方源码（add/update 都要）
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
}

# 记录当前 relay 版本（git short sha）
core_relay_version() {
  git -C "$TPROXY_SRC_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown"
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

# 跑官方 install.sh（全 flag 非交互）
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
# 模式 A：443 空闲、无 caddy —— 官方原样全跑
# ============================================================
core_install_mode_a() {
  local host="$1" email="$2" secret="$3" sitedir="$4"
  # 官方自己装 Caddy 占 443，我们只跑 + 登记
  core_run_official_install "$host" "$email" "$secret" "$sitedir"
  CADDY_BACKUP=""
  CADDY_SHARED="false"
}

# ============================================================
# 模式 B：443 被其他 TLS 服务占用、本机无 caddy
# 官方照跑（它装的 Caddy 此刻无冲突）→ 跑完接管 Caddyfile 重写为用户指定端口
# 太白金星拍板：官方 install.sh 的 Caddyfile 占 443 会被既有 TLS 服务卡住，
# caddy restart 可能失败导致官方脚本中止 —— 这一步视为预期，容忍继续。
# ============================================================
core_install_mode_b() {
  local host="$1" email="$2" secret="$3" sitedir="$4" port="$5"
  info "模式 B：官方安装器会在 443 被占时启动失败，属预期，继续接管..."
  bash "$TPROXY_SRC_DIR/install.sh" \
    --hostname "$host" \
    --email "$email" \
    --secret "$secret" \
    --site-dir "$sitedir" \
    --static-routes exact \
    > /tmp/tg-official-install.log 2>&1
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "官方脚本退出码 $rc（443 被占导致），核心组件应已装好，继续..."
    grep -E 'config.json|profiles.json|systemd' /tmp/tg-official-install.log >/dev/null \
      || error_exit "官方安装异常，核心组件疑似未装好" "查看日志: cat /tmp/tg-official-install.log，确认后重试"
  fi
  # 核心就位的硬校验
  [ -f "$TPROXY_CONFIG" ] || error_exit "官方配置缺失" "查看日志: cat /tmp/tg-official-install.log，修复后重试"

  # 接管 Caddyfile：重写为用户指定端口的 site block
  local backup
  backup=$(caddy_backup)
  caddy_render_site "$host" "$port" "$(core_official_get '.base_path // ""')"
  cp "$TG_CADDY_DIR/site.conf" "$CADDYFILE"
  caddy_apply
  systemctl restart caddy 2>/dev/null || true
  # 等核心 ready（官方逻辑同款）
  core_wait_ready 20 || error_exit "tproxy 未就绪" "查看日志: journalctl -u tproxy-server -n 50"
  CADDY_BACKUP="$backup"
  CADDY_SHARED="false"
  CADDY_PORT_OVERRIDDEN="true"
}

# ============================================================
# 模式 C：本机已有 caddy —— 官方跑完立即恢复其 before-tproxy 备份，
# 再追加我们的 site block（共用 caddy）
# 太白金星拍板批准此编排；失败必须原样还原并大声报错。
# ============================================================
core_install_mode_c() {
  local host="$1" email="$2" secret="$3" sitedir="$4" port="$5"
  local pre_backup
  # 我们先自己备份一份（官方也会备份，双保险）
  pre_backup=$(caddy_backup)

  core_run_official_install "$host" "$email" "$secret" "$sitedir"

  # 官方跑完，恢复官方的 before-tproxy 备份（恢复原 Caddyfile）
  local official_backup
  official_backup=$(find /etc/caddy -maxdepth 1 -name 'Caddyfile.before-tproxy.*' -type f 2>/dev/null | sort -r | head -1)
  if [ -n "$official_backup" ]; then
    cp -a "$official_backup" "$CADDYFILE"
    info "已恢复原 Caddyfile（官方 before-tproxy 备份）"
  else
    warn "官方未生成 before-tproxy 备份，保留当前 Caddyfile"
  fi

  # 追加我们的 site block
  caddy_render_site "$host" "$port" "$(core_official_get '.base_path // ""')"
  caddy_attach_fragment
  if ! caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then
    caddy_restore_backup "$pre_backup"
    error_exit "Caddy 配置校验失败，已还原原 Caddyfile" "查看详情: caddy validate --config $CADDYFILE，修复后重试 tg add"
  fi
  caddy_apply
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

  # 生成伪装站
  info "正在生成伪装站..."
  local sitedir
  sitedir=$(core_build_site)

  # 分模式安装
  CADDY_BACKUP=""; CADDY_SHARED="false"; CADDY_PORT_OVERRIDDEN="false"
  case "$DETECT_MODE" in
    A) core_install_mode_a "$host" "$email" "$secret" "$sitedir" ;;
    B) core_install_mode_b "$host" "$email" "$secret" "$sitedir" "$port" ;;
    C) core_install_mode_c "$host" "$email" "$secret" "$sitedir" "$port" ;;
  esac

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
    "relay_version=master@$(core_relay_version)"

  rm -rf "$sitedir"

  echo ""
  success "安装完成"
  info "使用 tg url 查看节点链接"
  info "使用 tg qr 查看二维码"
  info "使用 tg status 查看服务状态"
}
