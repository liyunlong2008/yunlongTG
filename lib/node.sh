#!/usr/bin/env bash
# lib/node.sh — 节点登记文件读写（/etc/tg/node.json，0600 root）
# 我们唯一自有状态；官方配置只读不写。

# 初始化（不存在则建空壳）
node_init() {
  mkdir -p "$TG_ETC_DIR" "$TG_CADDY_DIR"
  chmod 700 "$TG_ETC_DIR"
  if [ ! -s "$NODE_JSON" ]; then
    echo '{}' > "$NODE_JSON"
    chmod 600 "$NODE_JSON"
  fi
}

# 保存节点（增量合并，键见 design.md 第 4 节）
node_save() {
  # $@: key=value
  node_init
  local pairs='{}'
  local kv
  for kv in "$@"; do
    local key="${kv%%=*}" val="${kv#*=}"
    pairs=$(jq -c --arg k "$key" --arg v "$val" '. + {($k): $v}' <<< "$pairs")
  done
  local tmp
  tmp=$(mktemp)
  jq --argjson p "$pairs" '. * $p' "$NODE_JSON" > "$tmp" && mv "$tmp" "$NODE_JSON" && chmod 600 "$NODE_JSON"
}

# 删除节点登记（del 用）
node_clear() {
  rm -f "$NODE_JSON"
}

node_get() { json_get ".$1"; }

node_exists_check() {
  node_exists || error_exit "本机尚未安装节点" "先执行 tg add"
}
