#!/usr/bin/env bash
# tg.sh — 云龙TG 主入口：菜单 + 子命令分发
# 轻命令（info/url/qr/status/start/stop/restart/log）在此直接实现；
# 重编排（add/update/del/change）在 lib/*-core.sh。

set -e

# lib 寻址：按设计书落位写死（/usr/local/bin/tg + /usr/local/share/tg/lib）。
# 本地源码树运行（未安装）时回退到脚本旁边的 lib/。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="/usr/local/share/tg/lib"
[ -d "$LIB_DIR" ] || LIB_DIR="$SCRIPT_DIR/lib"
# 安装根随 LIB_DIR 对齐（VERSION 文件与 lib 同级）
export TG_SHARE_DIR="${LIB_DIR%/lib}"

# shellcheck source=lib/env.sh
. "$LIB_DIR/env.sh"
# shellcheck source=lib/util.sh
. "$LIB_DIR/util.sh"
# shellcheck source=lib/detect.sh
. "$LIB_DIR/detect.sh"
# shellcheck source=lib/node.sh
. "$LIB_DIR/node.sh"
# shellcheck source=lib/site.sh
. "$LIB_DIR/site.sh"
# shellcheck source=lib/caddy.sh
. "$LIB_DIR/caddy.sh"
# shellcheck source=lib/install-core.sh
. "$LIB_DIR/install-core.sh"
# shellcheck source=lib/update-core.sh
. "$LIB_DIR/update-core.sh"
# shellcheck source=lib/uninstall-core.sh
. "$LIB_DIR/uninstall-core.sh"

# ============================================================
# tg info
# ============================================================
cmd_info() {
  node_exists_check
  echo "节点信息："
  echo "  域名      $(node_get hostname)"
  echo "  端口      $(node_get port)"
  echo "  模式      $(node_get mode)"
  echo "  邮箱      $(node_get email)"
  echo "  安装时间  $(node_get installed_at)"
  echo "  relay 版本 $(node_get relay_version)"
  echo ""
  echo "服务状态："
  local svc
  for svc in caddy tproxy-server mtproxy; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^$svc\.service"; then
      printf '  %-14s %s\n' "$svc" "$(systemctl is-active "$svc" 2>/dev/null || echo inactive)"
    fi
  done
  if svc_active tproxy-server; then
    if curl -fsS --max-time 2 http://127.0.0.1:8081/readyz >/dev/null 2>&1; then
      echo "  readyz      正常"
    else
      echo "  readyz      异常"
    fi
  fi
}

# ============================================================
# tg url — 按 design.md 1.6 拼链接
# ============================================================
cmd_url() {
  node_exists_check
  local host secret
  host=$(node_get hostname)
  secret=$(node_get secret)

  # 根路径部署（官方 ANDROID.md）：server 仅域名；secret 为明文 32 位 hex
  echo "https://t.me/webproxy?server=$host&secret=$secret"
}

# ============================================================
# tg qr
# ============================================================
cmd_qr() {
  node_exists_check
  command -v qrencode >/dev/null 2>&1 || require_cmds qrencode
  local url png=""
  url=$(cmd_url_stdout)
  # 可选 PNG：tg qr /path/to/out.png
  if [ -n "${1:-}" ]; then
    png="$1"
    if qrencode -o "$png" -s 8 "$url"; then
      success "二维码已保存: $png"
    else
      error_exit "二维码写入失败: $png" "检查路径是否可写，重试 tg qr"
    fi
  else
    qrencode -t ANSIUTF8I "$url"
    echo ""
    info "链接: $url"
  fi
}
cmd_url_stdout() { cmd_url >/dev/null; cmd_url; }

# ============================================================
# tg status
# ============================================================
cmd_status() {
  node_exists_check
  local svc all_ok=0
  for svc in caddy tproxy-server mtproxy; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^$svc\.service"; then
      local st
      st=$(systemctl is-active "$svc" 2>/dev/null || echo inactive)
      if [ "$st" = "active" ]; then
        printf '%-14s %s\n' "$svc" "运行中"
      else
        printf '%-14s %s\n' "$svc" "$st"
        all_ok=1
      fi
    fi
  done
  if svc_active tproxy-server; then
    if curl -fsS --max-time 2 http://127.0.0.1:8081/readyz >/dev/null 2>&1; then
      echo "readyz        正常"
    else
      echo "readyz        异常"
      all_ok=1
    fi
  fi
  [ "$all_ok" -eq 0 ] && success "全部服务正常" || warn "部分服务异常，查看日志用 tg log"
}

# ============================================================
# tg start/stop/restart — 按模式决定是否带 caddy
# ============================================================
_cmd_service() {
  local action="$1"
  node_exists_check
  # 三种模式都装了 caddy（shared=true 表示共享既有 caddy），始终纳入服务清单
  local services=("tproxy-server" "mtproxy" "caddy")

  local svc
  for svc in "${services[@]}"; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^$svc\.service"; then
      info "$svc $action..."
      systemctl "$action" "$svc" || warn "$svc $action 失败，查看日志: journalctl -u $svc -n 50"
    fi
  done
  success "已执行 $action"
}

cmd_start()   { _cmd_service start; }
cmd_stop()    { _cmd_service stop; }
cmd_restart() { _cmd_service restart; }

# ============================================================
# tg log [tproxy|mtproxy|caddy] [-f]
# ============================================================
cmd_log() {
  node_exists_check
  local unit="tproxy-server" follow=""
  case "${1:-}" in
    tproxy|"") unit="tproxy-server" ;;
    mtproxy) unit="mtproxy" ;;
    caddy) unit="caddy" ;;
    *) error_exit "未知日志源: $1" "可用: tg log [tproxy|mtproxy|caddy]" ;;
  esac
  if [ "${2:-}" = "-f" ]; then
    follow="-f"
  fi
  journalctl -u "$unit" $follow -n 100 --no-pager
}

# ============================================================
# tg change — 端口/密码/域名
# ============================================================
cmd_change() {
  node_exists_check
  local sub="${1:-}"
  shift || true
  case "$sub" in
    port)   core_change_port "$@" ;;
    secret) core_change_secret ;;
    hostname) core_change_hostname "$@" ;;
    *) error_exit "未知子命令: tg change $sub" "可用: tg change secret|hostname（端口固定 443 不支持修改）" ;;
  esac
}

# 改端口：WEB 代理类型固定 HTTPS + 443，端口不可改（保留命令以给出明确指引）
core_change_port() {
  error_exit "WEB 代理固定使用 443 端口，不支持修改端口" \
    "如需更换入口请重新部署：tg del 后用一键安装命令重装"
}

# 改密码：新 32 hex → 改 profiles.json secret 字段 + mtproxy.env → restart
core_change_secret() {
  local new
  new=$(gen_hex)
  info "正在生成新密码..."
  # 官方文档化路径（design.md 6：profiles.json secret 字段 + mtproxy.env）
  # 真实结构 {"profiles":[{"secret":...}]}（Bug #9：顶层 .secret 是错位）
  local cur
  cur=$(jq -r '.profiles[0].secret // empty' "$TPROXY_PROFILES" 2>/dev/null)
  [ -n "$cur" ] || error_exit "读不到 profiles.json 的 secret 字段" "检查 $TPROXY_PROFILES 是否存在"
  local tmp; tmp=$(mktemp)
  if jq --arg s "$new" '.profiles[0].secret = $s' "$TPROXY_PROFILES" > "$tmp"; then
    mv "$tmp" "$TPROXY_PROFILES"
  else
    rm -f "$tmp"; error_exit "写 profiles.json 失败" "检查文件权限"
  fi
  chmod 400 "$TPROXY_PROFILES"
  # mtproxy.env 键名为官方 MTPROXY_SECRET=（Bug #9：旧代码 grep '^SECRET=' 错位）
  if grep -q '^MTPROXY_SECRET=' "$MPROXY_ENV" 2>/dev/null; then
    sed -i "s/^MTPROXY_SECRET=.*/MTPROXY_SECRET=$new/" "$MPROXY_ENV"
  fi
  systemctl restart tproxy-server mtproxy
  node_save "secret=$new"
  success "密码已更换"
  warn "旧链接全部作废，请重新分发: tg url"
}

# 改域名：DNS 检测 → config.json public_hostname + site block + caddy.service.d → validate → restart
core_change_hostname() {
  local newhost="$1"
  [ -n "$newhost" ] || error_exit "缺少新域名" "用法: tg change hostname tg2.example.com"
  detect_dns "$newhost"

  local port oldhost backup
  port=$(node_get port)
  oldhost=$(node_get hostname)
  backup=$(caddy_backup)

  # config.json 只改 public_hostname 字段（design.md 6 允许的字段级改动）
  local tmp; tmp=$(mktemp)
  if jq --arg h "$newhost" '.public_hostname = $h' "$TPROXY_CONFIG" > "$tmp"; then
    mv "$tmp" "$TPROXY_CONFIG"
  else
    rm -f "$tmp"; error_exit "写 config.json 失败" "检查文件权限"
  fi

  caddy_render_site "$newhost" "$port"
  caddy_write_env_hostname "$newhost"
  if [ "$(node_get caddy_shared)" = "true" ]; then
    caddy_attach_fragment
  else
    cp "$TG_CADDY_DIR/site.conf" "$CADDYFILE"
  fi
  if ! caddy_validate; then
    caddy_restore_backup "$backup"
    jq --arg h "$oldhost" '.public_hostname = $h' "$TPROXY_CONFIG" > "$tmp" && mv "$tmp" "$TPROXY_CONFIG"
    error_exit "域名修改失败，已还原" "查看详情: caddy validate --config $CADDYFILE"
  fi
  # apply 失败同样全量还原（Caddyfile + config.json，不留半改状态）
  if ! caddy_apply; then
    caddy_restore_backup "$backup"
    jq --arg h "$oldhost" '.public_hostname = $h' "$TPROXY_CONFIG" > "$tmp" && mv "$tmp" "$TPROXY_CONFIG"
    error_exit "域名修改失败（caddy 生效失败），已还原" "查看日志: journalctl -u caddy -n 50，修复后重试 tg change hostname $newhost"
  fi
  # 域名落进 config.json public_hostname，tproxy 需重启生效
  systemctl restart tproxy-server || error_exit "tproxy-server 重启失败" "查看日志: journalctl -u tproxy-server -n 50"
  node_save "hostname=$newhost"
  success "域名已改为 $newhost"
  info "节点链接已变化，重新分发用 tg url"
}

# ============================================================
# tg add / update / del 分发
# ============================================================
cmd_add()     { core_add "$@"; }
cmd_update()  { core_update "$@"; }
cmd_del()     { core_del; }
cmd_uninstall() { core_uninstall; }

# ============================================================
# 帮助
# ============================================================
cmd_help() {
  echo "用法: tg <命令>"
  echo ""
  echo "命令："
  echo "  add               添加节点"
  echo "  info              查看节点信息"
  echo "  url               显示节点链接"
  echo "  qr                显示二维码（tg qr <file.png> 可存图）"
  echo "  change            修改密码/域名（tg change secret|hostname）"
  echo "  status            服务状态"
  echo "  start             启动服务"
  echo "  stop              停止服务"
  echo "  restart           重启服务"
  echo "  log               查看日志（tg log [tproxy|mtproxy|caddy] [-f]）"
  echo "  update            更新 relay 与脚本"
  echo "  del               删除节点"
  echo "  uninstall         卸载本脚本（不影响节点）"
  echo ""
  echo "更多说明: man tg 或阅读 README"
}

# ============================================================
# 菜单（经典数字选单风格）
# ============================================================
show_menu() {
  echo "==================== ${BRAND} ===================="
  echo ""
  if node_exists; then
    echo " 1. 添加节点          tg add"
    echo " 2. 查看节点信息      tg info"
    echo " 3. 显示节点链接      tg url"
    echo " 4. 显示二维码        tg qr"
    echo " 5. 端口说明          WEB 代理固定 443"
    echo " 6. 修改密码          tg change secret"
    echo " 7. 修改域名          tg change hostname"
    echo " 8. 查看服务状态      tg status"
    echo " 9. 启动服务          tg start"
    echo " 10. 停止服务         tg stop"
    echo " 11. 重启服务         tg restart"
    echo " 12. 查看日志         tg log"
    echo " 13. 更新             tg update"
    echo " 14. 删除节点         tg del"
    echo " 15. 卸载脚本         tg uninstall"
    echo " 0. 退出"
  else
    echo " 1. 添加节点          tg add"
    echo " 2. 查看脚本说明      tg help"
    echo " 0. 退出"
  fi
  echo ""
}

menu_loop() {
  while true; do
    show_menu
    local choice
    read -rp "请选择: " choice
    case "$choice" in
      1)
        if node_exists; then
          warn "已有节点"
          if confirm "强制重新添加？先删除现有节点"; then
            cmd_del
            cmd_add
          else
            info "已取消"
          fi
        else
          cmd_add
        fi
        ;;
      2) cmd_info ;;
      3) cmd_url ;;
      4) cmd_qr ;;
      5) info "WEB 代理固定使用 443 端口，不支持修改端口" ;;
      6) if confirm "确认更换密码？旧链接全部作废"; then cmd_change secret; else info "已取消"; fi ;;
      7) read -rp "新域名: " h; cmd_change hostname "$h" ;;
      8) cmd_status ;;
      9) cmd_start ;;
      10) cmd_stop ;;
      11) cmd_restart ;;
      12) cmd_log tproxy -f ;;
      13) cmd_update ;;
      14) if confirm "确认删除节点？"; then cmd_del; else info "已取消"; fi ;;
      15) if confirm "确认卸载脚本？（不影响已装节点）"; then cmd_uninstall; else info "已取消"; fi ;;
      0) exit 0 ;;
      *) warn "无效选择" ;;
    esac
    echo ""
    read -rp "按回车返回菜单..." _
  done
}

# ============================================================
# 分发
# ============================================================
main() {
  local cmd="${1:-}"
  [ -n "$cmd" ] || { menu_loop; return; }
  shift || true
  case "$cmd" in
    add)        cmd_add "$@" ;;
    info)       cmd_info ;;
    url)        cmd_url ;;
    qr)         cmd_qr "$@" ;;
    change)     cmd_change "$@" ;;
    status)     cmd_status ;;
    start)      cmd_start ;;
    stop)       cmd_stop ;;
    restart)    cmd_restart ;;
    log)        cmd_log "$@" ;;
    update)     cmd_update "$@" ;;
    del)        cmd_del ;;
    uninstall)  cmd_uninstall ;;
    help|-h|--help) cmd_help ;;
    version|--version|-v) echo "${BRAND} $(tg_version)" ;;    *) error_exit "未知命令: $cmd" "查看全部命令: tg help" ;;
  esac
}

main "$@"
