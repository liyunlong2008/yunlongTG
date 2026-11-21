#!/usr/bin/env bash
# lib/caddy.sh — Caddyfile 模板渲染 + site block 增改删（design.md 第 5/6 节）
# 红线：动 /etc/caddy/Caddyfile 必须先备份且可回滚；官方文件只读（Caddyfile 是被官方 install.sh
# 整体覆盖的对象，我们只在官方跑完后接管）。

CADDY_BACKUP_PREFIX="${CADDY_BACKUP_PREFIX:-$(dirname "${CADDYFILE:-/etc/caddy/Caddyfile}")/Caddyfile.before-tg}"

# 备份当前 Caddyfile，返回备份路径（stdout）
caddy_backup() {
  [ -f "$CADDYFILE" ] || { echo ""; return 0; }
  local ts backup
  ts=$(date +%Y%m%d%H%M%S)
  backup="${CADDY_BACKUP_PREFIX}.${ts}"
  cp -a "$CADDYFILE" "$backup"
  echo "$backup"
}

# 备份是否含 tg 自己生成的痕迹（旧 site block / import 行）。
# 多次 del/add 后备份链越攒越多，最新一份可能是上一轮 tg 时代的旧配置，
# 盲恢复会把旧端口 site block 带回主 Caddyfile（Bug #10）。
caddy_file_has_tg_marks() {
  local f="$1"
  [ -f "$f" ] || return 1
  if grep -qF "import $TG_CADDY_DIR/*.conf" "$f"; then return 0; fi
  if grep -qF "# 由 ${BRAND} 管理" "$f"; then return 0; fi
  # 根路径模式：不再有 /<base> 前缀路由，痕迹识别靠管理注释 + import 行 + 兜底转发组合
  if grep -qF "# 由 ${BRAND} 管理" "$f" && grep -qF 'reverse_proxy 127.0.0.1:8080' "$f"; then return 0; fi
  return 1
}

# 从 before-tproxy 备份里挑最新的一份「不含 tg 痕迹」的原始快照。
# 输出路径到 stdout；无干净备份则输出空（调用方保留当前 Caddyfile）。
caddy_pick_clean_backup() {
  local dir b
  dir=$(dirname "$CADDYFILE")
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    if ! caddy_file_has_tg_marks "$b"; then
      printf '%s\n' "$b"
      return 0
    fi
  done < <(find "$dir" -maxdepth 1 -name 'Caddyfile.before-tproxy.*' -type f 2>/dev/null | sort -r)
  return 0
}

# 清掉含 tg 痕迹的旧备份（含 before-tproxy 与 before-tg 两类），避免备份链越攒越多
caddy_purge_tainted_backups() {
  local dir b prefix
  dir=$(dirname "$CADDYFILE")
  prefix="${CADDY_BACKUP_PREFIX##*/}"
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    if caddy_file_has_tg_marks "$b"; then
      rm -f "$b"
    fi
  done < <(find "$dir" -maxdepth 1 \( -name 'Caddyfile.before-tproxy.*' -o -name "$prefix.*" \) -type f 2>/dev/null)
  return 0
}

# del 收尾：清空两个前缀的全部备份（此时配置已还原/摘除，备份无保留价值）
# before-tg.*（我们的）+ before-tproxy.*（官方安装段产生的），杜绝备份链增长
caddy_purge_all_backups() {
  local dir prefix
  dir=$(dirname "$CADDYFILE")
  prefix="${CADDY_BACKUP_PREFIX##*/}"
  rm -f "$dir/$prefix".* "$dir"/Caddyfile.before-tproxy.* "$dir/Caddyfile.tproxy" 2>/dev/null || true
  return 0
}

# 从备份恢复 Caddyfile（仅接受不含 tg 痕迹的干净备份）
caddy_restore_backup() {
  local backup="$1"
  if [ -z "$backup" ] || [ ! -f "$backup" ]; then
    error_exit "备份文件不存在: $backup" "检查 $CADDY_BACKUP_PREFIX.* 是否存在"
  fi
  if caddy_file_has_tg_marks "$backup"; then
    error_exit "备份含旧配置痕迹，拒绝恢复: $backup" "保留当前 Caddyfile，检查 $CADDY_BACKUP_PREFIX.* 后手工处理"
  fi
  cp -a "$backup" "$CADDYFILE"
}

# 我们的 site block 片段落位目录
caddy_fragment_dir() { mkdir -p "$TG_CADDY_DIR"; chmod 755 "$TG_CADDY_DIR"; }

# 渲染 site block 到 $TG_CADDY_DIR/site.conf（根路径部署：无 base_path 前缀路由）
# $1=hostname $2=port $3=email（可选）：add 链路 node.json 尚未写出，必须显式传；
#   省略时读登记（change 等装后路径），仍无则 admin@$host 兜底
caddy_render_site() {
  local host="$1" port="$2"
  local acme_email="${3:-}"
  if [ -z "$acme_email" ]; then
    acme_email=$(node_get email 2>/dev/null || true)
  fi
  [ -n "$acme_email" ] || acme_email="admin@$host"
  caddy_fragment_dir
  local site_addr
  if [ "$port" = "443" ]; then
    site_addr="$host"
  else
    site_addr="$host:$port"
  fi
  cat > "$TG_CADDY_DIR/site.conf" <<EOF
# 由 ${BRAND} 管理，勿手工编辑；tg change 域名会重写本文件
$site_addr {
	tls "$acme_email"
	encode zstd gzip

	# 根路径部署：所有请求直接转发给 relay，由它分流
	# （servePublic：/ → 伪装站首页 200；带 capability → 桥接页）
	handle {
		reverse_proxy 127.0.0.1:8080
	}
}
EOF
  chmod 644 "$TG_CADDY_DIR/site.conf"
}

# 把片段接进主 Caddyfile（幂等：没有 import 行才加）
caddy_attach_fragment() {
  local import_line="import $TG_CADDY_DIR/*.conf"
  if grep -qF "$import_line" "$CADDYFILE"; then return 0; fi
  printf '\n%s\n' "$import_line" >> "$CADDYFILE"
}

# 从主 Caddyfile 摘掉 import 行（del 用）
caddy_detach_fragment() {
  local import_line="import $TG_CADDY_DIR/*.conf"
  if grep -qF "$import_line" "$CADDYFILE"; then
    local tmp; tmp=$(mktemp)
    if grep -vF "$import_line" "$CADDYFILE" > "$tmp"; then
      mv "$tmp" "$CADDYFILE"
    else
      rm -f "$tmp"
      error_exit "摘除节点配置失败" "手动检查 $CADDYFILE 中的 import 行"
    fi
  fi
  rm -f "$TG_CADDY_DIR/site.conf"
}

# validate + reload（失败不自动还原，由调用方决定，避免重复还原逻辑）
# validate 统一走 caddy 服务的 drop-in 环境（与 reload 同环境，Bug #6 次修）：
# Caddyfile 官方模板含 {$ACME_EMAIL}/{$TPROXY_HOSTNAME} 占位符，裸 validate 会假失败
caddy_validate() {
  # drop-in 取值：systemctl show 读运行时环境；读不到则用我们 drop-in 的等价默认
  local env_tproxy_host env_site_root env_acme_email
  env_tproxy_host=$(systemctl show -p Environment caddy.service 2>/dev/null \
    | tr ' ' '\n' | sed -n 's/^TPROXY_HOSTNAME=//p' | head -1)
  env_site_root=$(systemctl show -p Environment caddy.service 2>/dev/null \
    | tr ' ' '\n' | sed -n 's/^TPROXY_SITE_ROOT=//p' | head -1 | tr -d '"')
  env_acme_email=$(systemctl show -p Environment caddy.service 2>/dev/null \
    | tr ' ' '\n' | sed -n 's/^ACME_EMAIL=//p' | head -1)
  env_tproxy_host="${env_tproxy_host:-$(node_get hostname 2>/dev/null || true)}"
  env_site_root="${env_site_root:-${TPROXY_SITE_ROOT:-/srv/tproxy-site}}"
  env_acme_email="${env_acme_email:-$(node_get email 2>/dev/null || true)}"
  TPROXY_HOSTNAME="$env_tproxy_host" TPROXY_SITE_ROOT="$env_site_root" ACME_EMAIL="$env_acme_email" \
    caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1
}

caddy_apply() {
  caddy_validate || error_exit "Caddy 配置校验失败" "查看详情: caddy validate --config $CADDYFILE，修复后执行 systemctl reload caddy"
  if systemctl is-active --quiet caddy.service; then
    # 跑着：官方 caddy unit 无 ExecReload，reload 会 rc=3 —— 用 restart（毫秒级，代理通道可容忍）
    systemctl restart caddy || error_exit "caddy 重启失败" "查看日志: journalctl -u caddy -n 50"
  else
    # 首次安装（流水线路径我们自己装 Caddy，服务未跑过）：reload/restart rc=3 场景，走 start
    systemctl start caddy || error_exit "caddy 启动失败" "查看日志: journalctl -u caddy -n 50"
    systemctl is-active --quiet caddy.service \
      || error_exit "caddy 启动后仍未运行" "查看日志: journalctl -u caddy -n 50，修复后执行 systemctl start caddy"
  fi
}

# caddy.service.d 环境变量（改域名用：官方把 hostname 写在 service 覆盖里）
# 官方 install.sh 写的覆盖文件我们只读；新增我们的 drop-in 并不清除官方配置
caddy_env_dir() { mkdir -p /etc/systemd/system/caddy.service.d; }

caddy_write_env_hostname() {
  local host="$1"
  caddy_env_dir
  cat > /etc/systemd/system/caddy.service.d/tg-hostname.conf <<EOF
# 由 ${BRAND} 管理
[Service]
Environment=TPROXY_HOSTNAME=$host
EOF
  systemctl daemon-reload
}
