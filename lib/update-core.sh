#!/usr/bin/env bash
# lib/update-core.sh — tg update 编排（design.md 第 7.2 节流水线路径）
# relay 更新=下载流水线 core 产物 + 照官方 update-relay.sh 回退语义自写编排
# （官方脚本硬编码从本地源码 go build，不支持预编译候选，已核实源码）。
# MTProxy 为 pinned 二进制，update 不动它（官方 pinned commit 变更时由流水线重出）。

core_update() {
  node_exists_check
  info "正在检查更新..."

  # 1. 版本比对
  local cur_version
  cur_version=$(node_get relay_version)

  local rel tag
  rel=$(core_latest_release)
  tag="${rel%%|*}"
  info "当前版本: $cur_version"
  info "最新版本: $tag"
  if [ "$tag" = "$cur_version" ]; then
    success "核心已是最新版本: $tag"
    core_self_update
    return 0
  fi

  # 2. 下载 + 强校验
  local bindir
  bindir=$(core_fetch_binaries)

  # 3. 照官方 update-relay.sh 语义自写编排
  core_relay_swap "$bindir/tproxy-server" "$tag"
  rm -rf "$bindir"

  # 4. tg 脚本自身自更新
  core_self_update
}

# relay 二进制原子替换（照官方 update-relay.sh 回退语义逐行对照）：
# flock 防并发 → 前置检查 → was_ready → token-migration → ensure-token-key
# → 候选 -check → 备份 → 替换 → 只 restart tproxy-server.service
# → healthz → readyz（此前就绪才等）→ 失败回滚 previous
core_relay_swap() {
  local candidate_path="$1" tag="$2"
  local installed="$CORE_BIN" next="$CORE_BIN.next" previous="$CORE_BIN.previous"
  local config="$TPROXY_CONFIG" profiles="$TPROXY_PROFILES" service="tproxy-server.service"
  local health="http://127.0.0.1:8081/healthz" ready="http://127.0.0.1:8081/readyz"

  # 前置检查（官方 update-relay.sh 22-33 行）
  local f
  for f in "$installed" "$config" "$profiles"; do
    [ -f "$f" ] || error_exit "缺少已部署文件: $f" "先执行 tg add 安装节点"
  done
  local c
  for c in curl flock install systemctl; do
    command -v "$c" >/dev/null 2>&1 || error_exit "缺少命令: $c" "手动安装后重试: apt-get install -y $c"
  done

  # flock 防并发（官方 34-38 行）
  exec 9>"$CORE_LOCK"
  if ! flock -n 9; then
    error_exit "另一个核心更新正在进行" "稍后重试 tg update"
  fi

  local was_ready=""
  if curl -fsS --max-time 2 --output /dev/null "$ready" 2>/dev/null; then
    was_ready=1
  fi

  core_wait_health() {
    local url="$1" i
    for ((i = 0; i < 20; i++)); do
      if curl -fsS --max-time 2 --output /dev/null "$url" 2>/dev/null; then
        return 0
      fi
      sleep 1
    done
    return 1
  }

  core_swap_rollback() {
    warn "新核心未通过验证，回滚上一版本"
    install -o root -g root -m 0755 "$previous" "$next"
    mv -f "$next" "$installed"
    if systemctl restart "$service" && core_wait_health "$health"; then
      success "已回滚上一版本并恢复健康"
    else
      error_exit "回滚失败，需要人工介入" "查看: journalctl -u $service -n 100 --no-pager"
    fi
  }

  # token-migration（官方 98-113 行）：无 token.key 时写 drain dropin，已存在且不同则拒绝
  if [ ! -e /etc/tproxy-server/token.key ]; then
    local migration_dir="$SYSTEMD_UNIT_DIR/tproxy-server.service.d"
    local migration_dropin="$migration_dir/token-migration.conf"
    install -d -m 0755 "$migration_dir"
    local migration_tmp
    migration_tmp=$(mktemp)
    cat > "$migration_tmp" <<'EOF'
[Service]
Environment=TPROXY_LEGACY_TOKEN_DRAIN=1
EOF
    if [ -L "$migration_dropin" ] || { [ -e "$migration_dropin" ] && ! cmp -s "$migration_tmp" "$migration_dropin"; }; then
      rm -f "$migration_tmp"
      error_exit "已存在不同的 token-migration 配置" "按官方 HARDENING.md 显式配置 legacy draining 后重试"
    fi
    install -o root -g root -m 0644 "$migration_tmp" "$migration_dropin"
    rm -f "$migration_tmp"
    systemctl daemon-reload
    info "已启用旧版令牌过渡（首次升级到签名令牌）"
  fi
  bash "$TPROXY_SRC_DIR/deploy/ensure-token-key.sh" \
    || error_exit "token key 部署失败" "查看 /etc/tproxy-server/ 权限后重试"

  # 候选配置校验（官方 115 行）
  "$candidate_path" -config "$config" -profiles-file "$profiles" -check \
    || error_exit "新核心与本机配置不匹配" "查看 core release 说明或回退到旧版 tg update"

  # 备份 → 替换（官方 117-122 行）
  info "正在替换核心..."
  install -o root -g root -m 0755 "$installed" "$previous"
  install -o root -g root -m 0755 "$candidate_path" "$next"
  mv -f "$next" "$installed"

  # 只 restart tproxy-server.service（官方 124-132 行）
  info "正在重启核心..."
  if ! systemctl restart "$service" || ! core_wait_health "$health"; then
    core_swap_rollback
    error_exit "核心更新失败（已自动回滚）" "查看日志: journalctl -u $service -n 50"
  fi
  if [ -n "$was_ready" ] && ! core_wait_health "$ready"; then
    core_swap_rollback
    error_exit "核心更新失败（已自动回滚）" "查看日志: journalctl -u $service -n 50"
  fi

  node_save "relay_version=$tag"
  success "核心更新完成: $tag"
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
  if [ "$latest" = "$local_ver" ]; then
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
  echo "$latest" > "$VERSION_FILE"

  rm -rf "$tmp"
  success "脚本更新完成: $latest"
  info "如需回退: rm -rf $TG_SHARE_DIR && mv $TG_PREV_DIR $TG_SHARE_DIR"
}

# 版本号写入（安装时）
core_write_version() {
  echo "${TG_VERSION:-v1.0.0}" > "$VERSION_FILE"
}
