#!/usr/bin/env bash
# lib/uninstall-core.sh — tg del / tg uninstall 编排（design.md 第 6 节）
# 无官方卸载器：自写。卸载前二次确认；按模式还原或摘除 Caddy site block。

# 半套残留判定：无登记但部署产物还在（add 中断/装坏版后常见状态）
core_has_deploy_remnants() {
  [ -f "$TPROXY_CONFIG" ] || [ -f "$MPROXY_ENV" ] \
    || [ -x "$CORE_BIN" ] || systemctl list-unit-files 2>/dev/null | grep -q '^tproxy-server\.service'
}

# 清半套残留：停服务 → 删单元/二进制/配置 → 摘我们的 Caddy 片段
# 不动 node.json（本就没有）；脚本本体不动（uninstall 收尾段负责）
core_cleanup_remnants() {
  info "正在停止残留服务..."
  local svc
  for svc in tproxy-server mtproxy tproxy-firewall refresh-mtproxy-config.timer caddy; do
    systemctl disable --now "$svc" >/dev/null 2>&1 || true
  done
  info "正在删除残留组件..."
  rm -f "$SYSTEMD_UNIT_DIR/tproxy-server.service" \
        "$SYSTEMD_UNIT_DIR/mtproxy.service" \
        "$SYSTEMD_UNIT_DIR/tproxy-firewall.service" \
        "$SYSTEMD_UNIT_DIR/refresh-mtproxy-config.timer" \
        "$SYSTEMD_UNIT_DIR/refresh-mtproxy-config.service" \
        "$SYSTEMD_UNIT_DIR/caddy.service.d/tproxy.conf" 2>/dev/null || true
  systemctl daemon-reload
  rm -f "$CORE_BIN" 2>/dev/null || true
  rm -rf "$(dirname "$TPROXY_CONFIG")" "$(dirname "$MPROXY_ENV")" "$MPROXY_HOME" "$TPROXY_SITE_ROOT" 2>/dev/null || true
  # Caddyfile 处理：无登记就没有 before-tg 备份记录，只摘我们的片段
  if [ -f "$CADDYFILE" ] && grep -qF "import $TG_CADDY_DIR/*.conf" "$CADDYFILE"; then
    caddy_detach_fragment
  fi
  rm -rf "$TG_CADDY_DIR"
  # 清我们的 Caddyfile 备份与官方接管副本（残留场景无登记，备份无还原用途）
  rm -f "${CADDY_BACKUP_PREFIX}".* 2>/dev/null || true
  rm -f "$(dirname "$CADDYFILE")/Caddyfile.tproxy" "$(dirname "$CADDYFILE")"/Caddyfile.before-tproxy.* 2>/dev/null || true
}

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
    # C 模式：还原我们的 before-tg 备份（仅当它是干净的用户原始配置）
    # 备份若含 tg 痕迹（旧 site block/import 行），说明是上一轮 tg 旧物，整份恢复会带回旧端口 block
    if [ -n "$backup" ] && [ -f "$backup" ] && ! caddy_file_has_tg_marks "$backup"; then
      info "正在还原原 Caddyfile..."
      cp -a "$backup" "$CADDYFILE"
      if caddy_validate; then
        systemctl reload caddy
      else
        warn "还原后 validate 未过，请手工检查 $CADDYFILE"
      fi
    else
      # 无干净备份或备份已含 tg 痕迹：只摘我们的 site block，不整份恢复
      caddy_detach_fragment
      caddy_validate >/dev/null 2>&1 && systemctl reload caddy 2>/dev/null || true
    fi
  else
    # A/B 模式：Caddy 是我们装的，直接摘除
    caddy_detach_fragment
    if systemctl list-unit-files 2>/dev/null | grep -q '^caddy\.service'; then
      systemctl disable --now caddy >/dev/null 2>&1 || true
    fi
  fi

  # 3. 删官方单元与二进制（caddy 二进制保留：重装复用；/opt/MTProxy 连预置产物一并清：
  #    重装时流水线会重新下载预置产物，保留反而藏旧版本）
  info "正在删除官方组件..."
  rm -f /etc/systemd/system/tproxy-server.service \
        /etc/systemd/system/mtproxy.service \
        /etc/systemd/system/tproxy-firewall.service \
        /etc/systemd/system/refresh-mtproxy-config.timer \
        /etc/systemd/system/refresh-mtproxy-config.service 2>/dev/null || true
  systemctl daemon-reload
  rm -f /usr/local/bin/tproxy-server 2>/dev/null || true
  rm -rf /etc/tproxy-server /etc/mtproxy "$MPROXY_HOME" /srv/tproxy-site 2>/dev/null || true
  # 清我们的 Caddyfile 备份（有正常用途的场景已在上一步还原/摘除完）
  rm -f "${CADDY_BACKUP_PREFIX}".* 2>/dev/null || true

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
  # 半套残留（部署中断：组件在、无登记）也要能清干净
  if ! node_exists; then
    if ! core_has_deploy_remnants; then
      error_exit "本机未安装，无需卸载" "安装用一键安装命令，查看帮助用 tg help"
    fi
    warn "检测到部署残留（无节点登记）"
    confirm "确认清理残留？" || { info "已取消"; return 0; }
    core_cleanup_remnants
    success "残留清理完成"
    return 0
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
