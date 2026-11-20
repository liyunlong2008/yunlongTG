#!/usr/bin/env bash
# lib/uninstall-core.sh — tg del / tg uninstall 编排（design.md 第 6 节）
# 无官方卸载器：自写。卸载前二次确认；按模式还原或摘除 Caddy site block。

core_del() {
  node_exists_check
  warn "即将删除节点，所有服务停止，配置清除"
  confirm "确认删除？" || { info "已取消"; return 0; }

  local shared backup
  shared=$(node_get caddy_shared)
  backup=$(node_get caddyfile_backup)

  # 1. 停服务
  info "正在停止服务..."
  local svc
  for svc in tproxy-server mtproxy tproxy-firewall refresh-mtproxy-config.timer caddy; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^$svc\."; then
      systemctl disable --now "$svc" >/dev/null 2>&1 || true
    fi
  done

  # 2. Caddy 处理：按模式还原或摘除
  if [ "$shared" = "true" ]; then
    # C 模式：还原我们的 before-tg 备份（如果还原后能 validate），否则只摘 site block
    if [ -n "$backup" ] && [ -f "$backup" ]; then
      info "正在还原原 Caddyfile..."
      cp -a "$backup" "$CADDYFILE"
      if caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then
        systemctl reload caddy
      else
        warn "还原后 validate 未过，请手工检查 $CADDYFILE"
      fi
    else
      caddy_detach_fragment
      systemctl reload caddy 2>/dev/null || true
    fi
  else
    # A/B 模式：Caddy 是我们装的，直接摘除
    caddy_detach_fragment
    if systemctl list-unit-files 2>/dev/null | grep -q '^caddy\.service'; then
      systemctl disable --now caddy >/dev/null 2>&1 || true
    fi
  fi

  # 3. 删官方单元与二进制
  info "正在删除官方组件..."
  rm -f /etc/systemd/system/tproxy-server.service \
        /etc/systemd/system/mtproxy.service \
        /etc/systemd/system/tproxy-firewall.service \
        /etc/systemd/system/refresh-mtproxy-config.timer \
        /etc/systemd/system/refresh-mtproxy-config.service 2>/dev/null || true
  systemctl daemon-reload
  rm -f /usr/local/bin/tproxy-server /usr/local/bin/caddy 2>/dev/null || true
  rm -rf /etc/tproxy-server /etc/mtproxy /srv/tproxy-site 2>/dev/null || true

  # 4. nftables 官方规则清除（如有）
  if command -v nft >/dev/null 2>&1 && [ -f /etc/nftables.conf ]; then
    # 只删我们/官方加的 2398/8888 drop 规则，其他不动
    nft delete rule inet filter input tcp dport 2398 drop 2>/dev/null || true
    nft delete rule inet filter input tcp dport 8888 drop 2>/dev/null || true
  fi

  # 5. 清登记（保留脚本本体）
  node_clear
  rm -rf "$TG_CADDY_DIR"

  success "节点已删除"
  info "卸载脚本本体用 tg uninstall"
}

core_uninstall() {
  # 空态行为与 del/info 一致：无登记即视为未安装
  if ! node_exists; then
    error_exit "本机未安装，无需卸载" "安装用一键安装命令，查看帮助用 tg help"
  fi
  warn "即将卸载 ${BRAND} 脚本（不影响已装节点）"
  confirm "确认卸载？" || { info "已取消"; return 0; }

  # 若还有节点，提示先 del
  warn "检测到仍有节点登记"
  if confirm "同时删除节点？"; then
    core_del
  else
    info "保留节点，仅卸载脚本"
  fi

  info "正在卸载脚本..."
  rm -rf "$TG_SHARE_DIR" "$TG_PREV_DIR" "$VERSION_FILE" "$TG_SRC_DIR" "$TG_ETC_DIR" 2>/dev/null || true
  rm -f "$TG_BIN" 2>/dev/null || true

  success "卸载完成"
}
