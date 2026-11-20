#!/usr/bin/env bash
# lib/caddy.sh — Caddyfile 模板渲染 + site block 增改删（design.md 第 5/6 节）
# 红线：动 /etc/caddy/Caddyfile 必须先备份且可回滚；官方文件只读（Caddyfile 是被官方 install.sh
# 整体覆盖的对象，我们只在官方跑完后接管）。

CADDY_BACKUP_PREFIX="/etc/caddy/Caddyfile.before-tg"

# 备份当前 Caddyfile，返回备份路径（stdout）
caddy_backup() {
  [ -f "$CADDYFILE" ] || { echo ""; return 0; }
  local ts backup
  ts=$(date +%Y%m%d%H%M%S)
  backup="${CADDY_BACKUP_PREFIX}.${ts}"
  cp -a "$CADDYFILE" "$backup"
  echo "$backup"
}

# 从备份恢复 Caddyfile（模式 C 失败回滚用）
caddy_restore_backup() {
  local backup="$1"
  if [ -z "$backup" ] || [ ! -f "$backup" ]; then
    error_exit "备份文件不存在: $backup" "检查 $CADDY_BACKUP_PREFIX.* 是否存在"
  fi
  cp -a "$backup" "$CADDYFILE"
}

# 我们的 site block 片段落位目录
caddy_fragment_dir() { mkdir -p "$TG_CADDY_DIR"; chmod 755 "$TG_CADDY_DIR"; }

# 渲染 site block 到 $TG_CADDY_DIR/site.conf
# $1=hostname $2=port $3=base_path（来自 config.json，只读）
caddy_render_site() {
  local host="$1" port="$2" base="$3"
  caddy_fragment_dir
  local site_addr
  if [ "$port" = "443" ]; then
    site_addr="$host"
  else
    site_addr="$host:$port"
  fi
  cat > "$TG_CADDY_DIR/site.conf" <<EOF
# 由 ${BRAND} 管理，勿手工编辑；tg change 端口/域名会重写本文件
$site_addr {
	tls "$TG_ACME_EMAIL"
	encode zstd gzip

	handle_path /$base/* {
		reverse_proxy 127.0.0.1:8080
	}
	handle_path /$base {
		reverse_proxy 127.0.0.1:8080
	}

	handle {
		redir https://{host}{uri} 302
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
    grep -vF "$import_line" "$CADDYFILE" > "$tmp" && mv "$tmp" "$CADDYFILE"
  fi
  rm -f "$TG_CADDY_DIR/site.conf"
}

# validate + reload（失败不自动还原，由调用方决定，避免重复还原逻辑）
caddy_apply() {
  caddy validate --config "$CADDYFILE" >/dev/null 2>&1 || error_exit "Caddy 配置校验失败" "查看详情: caddy validate --config $CADDYFILE，修复后执行 systemctl reload caddy"
  systemctl reload caddy || error_exit "caddy reload 失败" "查看日志: journalctl -u caddy -n 50"
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
