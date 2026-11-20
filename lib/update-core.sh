#!/usr/bin/env bash
# lib/update-core.sh — tg update 编排（design.md 第 7 节）
# 二进制回退完全信任官方 update-relay.sh，我们只做：拉源码 + 调官方脚本 + 脚本自更新。

core_update() {
  node_exists_check
  info "正在检查更新..."

  # 1. 记录当前版本
  local cur_version
  cur_version=$(node_get relay_version)

  # 2. 拉官方源码
  core_fetch_tproxy
  local new_version
  new_version="master@$(core_relay_version)"
  info "当前版本: $cur_version"
  info "最新版本: $new_version"

  # 3. 调官方 update-relay.sh（自带 test→build→备份→替换→healthz，失败自动回滚）
  if [ -f "$TPROXY_SRC_DIR/deploy/update-relay.sh" ]; then
    info "正在更新 relay..."
    if bash "$TPROXY_SRC_DIR/deploy/update-relay.sh" 2>&1 | tee /tmp/tg-official-update.log; then
      node_save "relay_version=$new_version"
      success "relay 更新完成: $new_version"
    else
      # 官方脚本已自动回滚二进制，我们不叠加操作，如实报告
      error_exit "官方更新脚本失败（二进制已自动回滚）" "查看日志: cat /tmp/tg-official-update.log 或 journalctl -u tproxy-server -n 50"
    fi
  else
    warn "官方 update-relay.sh 不存在，跳过 relay 更新"
  fi

  # 4. tg 脚本自身自更新
  core_self_update
}

# tg 脚本自更新：下载最新 release tag 覆盖 /usr/local/share/tg/，保留 .prev 回退
core_self_update() {
  info "正在检查脚本更新..."
  local latest local_ver
  latest=$(curl -fsS --max-time 10 "https://api.github.com/repos/liyunlong2008/yunlongTG/releases/latest" | jq -r '.tag_name // empty' 2>/dev/null)
  local_ver=$(tg_version)
  if [ -z "$latest" ]; then
    warn "获取最新版本失败，跳过脚本更新"
    return 0
  fi
  if [ "$latest" = "v$local_ver" ]; then
    success "脚本已是最新版本: $local_ver"
    return 0
  fi
  info "发现新版本脚本: $latest（当前 $local_ver）"

  # 保留上一版本目录
  rm -rf "$TG_PREV_DIR"
  cp -a "$TG_SHARE_DIR" "$TG_PREV_DIR"

  local tmp; tmp=$(mktemp -d)
  if ! curl -fsSL --max-time 60 "$REPO_URL/archive/refs/tags/$latest.tar.gz" | tar -xz -C "$tmp" --strip-components=1 2>/dev/null; then
    rm -rf "$tmp"
    warn "下载 $latest 失败，还原上一版本"
    rm -rf "$TG_SHARE_DIR"
    mv "$TG_PREV_DIR" "$TG_SHARE_DIR"
    error_exit "脚本更新失败" "手动下载: $REPO_URL/releases"
  fi

  # 覆盖安装（lib + 入口）
  mkdir -p "$TG_LIB_DIR"
  cp -a "$tmp/lib/." "$TG_LIB_DIR/" 2>/dev/null || true
  cp -a "$tmp/tg.sh" "$TG_BIN"
  chmod +x "$TG_BIN"
  echo "${latest#v}" > "$VERSION_FILE"

  rm -rf "$tmp"
  success "脚本更新完成: $latest"
  info "如需回退: rm -rf $TG_SHARE_DIR && mv $TG_PREV_DIR $TG_SHARE_DIR"
}

# 版本号写入（安装时）
core_write_version() {
  echo "${TG_VERSION:-dev}" > "$VERSION_FILE"
}
