#!/usr/bin/env bash
#
# publish.sh — 把 Obsidian 正本庫裡某個小工具的「最新版號」檔案發佈到 GitHub Releases。
#
# 用法:
#   ./publish.sh set_configs
#
# 行為:
#   1. 到正本庫對應資料夾,找出版號最大的檔案(例:set_configsV2.3.sh)
#   2. 以固定檔名複製進 repo(set_configs/set_configs.sh)→ commit & push
#   3. 建立固定版 release  : tag = <tool>-v<版號>(已存在則覆蓋上傳 asset)
#   4. 重建移動標籤 release: tag = <tool>-latest(永遠指向最新版)
#
# 正本庫是唯一編輯來源;這支腳本只做「發佈 + 版本」。
set -euo pipefail

REPO="DavidChangAndroid/aetherslide-tools"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_ROOT="/Users/davidchang/Library/Mobile Documents/iCloud~md~obsidian/Documents/iCloud_Obsidian/雲象科技/08_工具與設定/小工具"

# 工具設定:repo 子目錄名 → 正本庫資料夾名 / 檔名前綴
# 新增工具時在這裡加一行即可。
vault_dir_for() {
  case "$1" in
    set_configs)      echo "aetherSlideAutoConfig" ;;
    install_recorder) echo "專案錄影" ;;
    chrome_debug)     echo "Chrome_debug" ;;
    *) echo "" ;;
  esac
}
file_prefix_for() {
  case "$1" in
    set_configs)      echo "set_configs" ;;
    install_recorder) echo "install_recorder" ;;
    chrome_debug)     echo "chrome_debug" ;;
    *) echo "" ;;
  esac
}

tool="${1:-}"
if [[ -z "$tool" ]]; then
  echo "用法: $0 <tool>  (例: $0 set_configs)" >&2
  exit 1
fi

vdir="$(vault_dir_for "$tool")"
prefix="$(file_prefix_for "$tool")"
if [[ -z "$vdir" || -z "$prefix" ]]; then
  echo "✗ 未知的工具: $tool(請先在 publish.sh 的 vault_dir_for/file_prefix_for 加設定)" >&2
  exit 1
fi

src_dir="$VAULT_ROOT/$vdir"
[[ -d "$src_dir" ]] || { echo "✗ 找不到正本庫資料夾: $src_dir" >&2; exit 1; }

# 找版號最大的檔案:<prefix>V<版號>.sh
latest_file="$(ls "$src_dir/${prefix}V"*.sh 2>/dev/null | sort -V | tail -1 || true)"
[[ -n "$latest_file" ]] || { echo "✗ 在 $src_dir 找不到 ${prefix}V*.sh" >&2; exit 1; }

version="$(basename "$latest_file" | sed -E "s/^${prefix}V([0-9.]+)\.sh$/\1/")"
echo "→ 工具: $tool"
echo "→ 最新版本檔: $(basename "$latest_file")  (v$version)"

# 複製進 repo(固定檔名)
dest="$REPO_ROOT/$tool/$tool.sh"
mkdir -p "$(dirname "$dest")"
cp "$latest_file" "$dest"
chmod +x "$dest"

# commit & push(無變更則略過)
cd "$REPO_ROOT"
git add "$tool/$tool.sh"
if git diff --cached --quiet; then
  echo "→ 內容無變更,略過 commit"
else
  git commit -m "publish ${tool} v${version}" -q
  git push -q
  echo "→ 已 commit & push"
fi

# 固定版 release
vtag="${tool}-v${version}"
if gh release view "$vtag" -R "$REPO" >/dev/null 2>&1; then
  echo "→ release $vtag 已存在,覆蓋上傳 asset"
  gh release upload "$vtag" "$dest" --clobber -R "$REPO"
else
  gh release create "$vtag" "$dest" -R "$REPO" \
    --title "${tool} v${version}" \
    --notes "正本庫: 08_工具與設定/小工具/${vdir}/$(basename "$latest_file")"
  echo "→ 已建立固定版 release: $vtag"
fi

# 移動標籤 release(永遠指向最新)
ltag="${tool}-latest"
gh release delete "$ltag" -R "$REPO" --yes --cleanup-tag >/dev/null 2>&1 || true
gh release create "$ltag" "$dest" -R "$REPO" \
  --title "${tool} (latest = v${version})" \
  --notes "永遠指向最新版。目前 = v${version}。"
echo "→ 已更新移動標籤 release: $ltag"

echo ""
echo "✓ 完成。下載指令:"
echo "  最新版 : gh release download ${ltag} -R ${REPO} -p '${tool}.sh' -O ${tool}.sh"
echo "  指定版 : gh release download ${vtag} -R ${REPO} -p '${tool}.sh' -O ${tool}.sh"
