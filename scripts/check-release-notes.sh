#!/bin/bash
# 检查某个版本的更新说明是否符合固定格式（应用内的“查看更新说明”按这个格式取内容）
# 用法：scripts/check-release-notes.sh 0.3.0
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?用法：scripts/check-release-notes.sh <版本号，例如 0.3.0>}"
MINOR="$(echo "$VERSION" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')"
FILE="$ROOT/changes/v$MINOR/release-notes-$VERSION.md"
fail=0
err() { echo "不符合格式：$1" >&2; fail=1; }

[ -f "$FILE" ] || { echo "没有找到 $FILE" >&2; exit 1; }

# 三个一级段落必须都有，而且按“中文、English、安装”的顺序
zh="$(grep -n '^## 中文$' "$FILE" | head -n1 | cut -d: -f1 || true)"
en="$(grep -n '^## English$' "$FILE" | head -n1 | cut -d: -f1 || true)"
ins="$(grep -n '^## 安装 / Install$' "$FILE" | head -n1 | cut -d: -f1 || true)"
[ -n "$zh" ] || err "缺少“## 中文”"
[ -n "$en" ] || err "缺少“## English”"
[ -n "$ins" ] || err "缺少“## 安装 / Install”"
if [ -n "$zh" ] && [ -n "$en" ] && [ -n "$ins" ]; then
  { [ "$zh" -lt "$en" ] && [ "$en" -lt "$ins" ]; } || err "段落顺序应为：中文、English、安装 / Install"
  # 中文段和英文段的小标题数量、条目数量要一致，避免只更新了一种语言
  zh_h="$(sed -n "${zh},${en}p" "$FILE" | grep -c '^### ' || true)"
  en_h="$(sed -n "${en},${ins}p" "$FILE" | grep -c '^### ' || true)"
  zh_b="$(sed -n "${zh},${en}p" "$FILE" | grep -c '^- ' || true)"
  en_b="$(sed -n "${en},${ins}p" "$FILE" | grep -c '^- ' || true)"
  [ "$zh_h" -gt 0 ] || err "中文段没有任何“### ”小标题"
  [ "$zh_h" = "$en_h" ] || err "中文段有 $zh_h 个小标题，英文段有 $en_h 个"
  [ "$zh_b" = "$en_b" ] || err "中文段有 $zh_b 条，英文段有 $en_b 条"
fi

# 只允许简单格式：不能有图片、表格、HTML、一级标题
grep -n '!\[' "$FILE" >/dev/null && err "不能有图片"
grep -n '^|' "$FILE" >/dev/null && err "不能有表格"
grep -n '<[a-zA-Z/][^>]*>' "$FILE" | grep -v '<发布脚本输出的值>' >/dev/null && err "不能有 HTML 标签"
grep -n '^# ' "$FILE" >/dev/null && err "不能有一级标题（标题由 GitHub 的发布标题提供）"
grep -n '<发布脚本输出的值>' "$FILE" >/dev/null && err "SHA-256 还没有填"

[ "$fail" = 0 ] && echo "格式正确：$FILE"
exit "$fail"
