#!/usr/bin/env bash
# lib/site.sh — 伪装站生成器（design.md 第 8 节）
# 每机不同：随机骨架 + 随机标题/段落/配色。输出交给官方 --site-dir 装进 /srv/tproxy-site。
# 模板属于代码（进仓库），生成产物不进仓库。

SITE_TPL_DIR="${SITE_TPL_DIR:-/usr/local/share/tg/site-templates}"

# 从数组随机取一个元素
_rand_pick() { local -a arr=("$@"); echo "${arr[RANDOM % ${#arr[@]}]}"; }

# 随机配色：输出 CSS 变量段
_site_palette() {
  local accents=("#2c7be5" "#00b8a9" "#e63946" "#6c5ce7" "#f4a261" "#2a9d8f" "#d62828" "#457b9d")
  local bg=("#ffffff" "#f8f9fa" "#fdfcfb" "#f7f6f2")
  local ink=("#212529" "#343a40" "#2b2d42" "#1d3557")
  local a; a=$(_rand_pick "${accents[@]}")
  local b; b=$(_rand_pick "${bg[@]}")
  local c; c=$(_rand_pick "${ink[@]}")
  printf '  --accent: %s;\n  --bg: %s;\n  --ink: %s;\n' "$a" "$b" "$c"
}

# 随机拼装正文段落（几十段中性文案随机组合，个人博客/工具站/文档站三种骨架共用池）
_site_paragraphs() {
  local -a pool=(
    "这里记录一些日常使用的小工具和笔记。"
    "内容会不定期更新，欢迎常来看看。"
    "大部分文章偏技术向，偶尔写点生活记录。"
    "如果你在找某个工具的用法，可以先看看归档。"
    "本站托管在一台小服务器上，页面保持轻量。"
    "所有内容均为个人整理，转载请注明出处。"
    "有问题可以通过页面底部的联系方式联系我。"
    "最近在整理旧文档，部分页面还在补充中。"
    "习惯把配置和脚本留在仓库里，方便随时回溯。"
    "更新日志按月归档，往期内容在页面最下方。"
    "写这份笔记是为了下次少踩坑。"
    "这个站没有统计脚本，也没有广告。"
    "页面加载应该很快，如果慢说明网络有问题。"
    "建议收藏常用的那几篇，搜索功能暂时没有。"
    "部分内容来自社区讨论，已经注明来源。"
    "一些命令行技巧，复制即用。"
    "以下是近期整理的几篇内容。"
    "页面在手机端也能正常阅读。"
  )
  local n=$(( RANDOM % 3 + 3 ))  # 3-5 段
  local i p
  for ((i = 0; i < n; i++)); do p=$(_rand_pick "${pool[@]}"); echo "    <p>$p</p>"; done
}

# 随机标题/副标题
_site_title() {
  local -a names=("陈记手记" "慢速实验室" "白板与咖啡" "拾光小站" "日常备忘" "南风札记" "工具与生活" "松木笔记")
  local -a subs=("一些随手记的东西" "把复杂的事写简单" "记录、整理、回顾" "个人笔记本" "慢慢更新中")
  echo "$(_rand_pick "${names[@]}")|$(_rand_pick "${subs[@]}")"
}

# 生成一套伪装站到 $1（输出目录）
# 文件：index.html 404.html style.css favicon.svg
site_generate() {
  local out="$1"
  [ -n "$out" ] || error_exit "site_generate 缺少输出目录参数" "检查脚本调用"
  mkdir -p "$out"
  local meta title sub
  meta=$(_site_title)
  title="${meta%%|*}"; sub="${meta#*|}"

  cat > "$out/style.css" <<CSS
:root {
$( _site_palette | sed 's/^/  /' )
}
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
  font-family: -apple-system, "Segoe UI", Roboto, "Helvetica Neue", sans-serif;
  background: var(--bg); color: var(--ink); line-height: 1.7;
  max-width: 720px; margin: 0 auto; padding: 48px 20px;
}
header { margin-bottom: 40px; }
h1 { color: var(--accent); font-size: 1.8em; }
.tagline { color: #888; margin-top: 6px; }
main section { margin-bottom: 32px; }
h2 { font-size: 1.2em; margin-bottom: 12px; }
a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; }
footer { margin-top: 60px; color: #999; font-size: 0.9em; border-top: 1px solid #eee; padding-top: 20px; }
CSS

  local nav_items nav=""
  nav_items=("首页" "归档" "关于")
  local ni
  for ni in "${nav_items[@]}"; do nav="$nav<a href=\"./\">$ni</a> "; done

  local idx_body
  idx_body=$(site_paragraphs_html)
  cat > "$out/index.html" <<HTML
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<link rel="stylesheet" href="style.css">
<link rel="icon" href="favicon.svg" type="image/svg+xml">
</head>
<body>
<header>
  <h1>$title</h1>
  <div class="tagline">$sub</div>
</header>
<nav style="margin-bottom:32px">$nav</nav>
<main>
$idx_body
</main>
<footer>
  &copy; $(date +%Y) $title &middot; 由一台小服务器驱动
</footer>
</body>
</html>
HTML

  cat > "$out/404.html" <<HTML
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>页面不存在</title>
<link rel="stylesheet" href="style.css">
</head>
<body>
<main>
  <h2>404</h2>
  <p>这个页面不存在或已被移除。</p>
  <p><a href="/">回到首页</a></p>
</main>
</body>
</html>
HTML

  local r g b
  r=$(( RANDOM % 200 + 30 )); g=$(( RANDOM % 200 + 30 )); b=$(( RANDOM % 200 + 30 ))
  cat > "$out/favicon.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">
<rect width="32" height="32" rx="6" fill="rgb($r,$g,$b)"/>
<text x="16" y="22" font-size="16" text-anchor="middle" fill="#fff" font-family="sans-serif">${title:0:1}</text>
</svg>
SVG

  chmod -R 755 "$out"
}

# index.html 的正文段落块（几节小标题+段落）
site_paragraphs_html() {
  local -a heads=("近期更新" "一些说明" "常用工具" "笔记归档" "随手记录")
  local n=$(( RANDOM % 3 + 2 ))  # 2-4 节
  local i h
  for ((i = 0; i < n; i++)); do
    h=$(_rand_pick "${heads[@]}")
    echo "  <section>"
    echo "    <h2>$h</h2>"
    _site_paragraphs
    echo "  </section>"
  done
}
