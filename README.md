# aetherslide-tools

AetherSlide 內部小工具的**發佈與版本管理**。私有 repo,僅供公司內部使用。

> 編輯來源(正本庫)在 Obsidian:`雲象科技/08_工具與設定/小工具/`。
> 本 repo 只負責「發佈 + 版本」,請勿在這裡直接改腳本邏輯。

## 安裝(在目標機器上)

公開 repo,直接用 curl / wget,免登入。

```bash
# 安裝最新版
curl -fsSL https://github.com/DavidChangAndroid/aetherslide-tools/releases/download/set_configs-latest/set_configs.sh -o set_configs.sh
bash set_configs.sh

# 安裝指定版本(把 set_configs-v2.3 換成要的版號)
curl -fsSL https://github.com/DavidChangAndroid/aetherslide-tools/releases/download/set_configs-v2.3/set_configs.sh -o set_configs.sh
```

> wget 版:`wget -qO set_configs.sh https://github.com/DavidChangAndroid/aetherslide-tools/releases/download/set_configs-latest/set_configs.sh`

## 發版(在開發機上)

在 Obsidian 正本庫編輯好新版本檔(檔名帶版號,如 `set_configsV2.4.sh`)後:

```bash
./publish.sh set_configs
```

腳本會自動抓版號最大的檔案 → 複製進 repo → commit/push → 建立 `set_configs-v<版號>`(固定版)與更新 `set_configs-latest`(移動標籤)。

## 版本標籤規則

- `<工具>-v<版號>`:固定版,永久保留,可重現安裝。
- `<工具>-latest`:移動標籤,永遠指向最新版。

## 已登錄的工具

| repo 子目錄 | 正本庫資料夾 | 工具 |
|---|---|---|
| `set_configs` | `aetherSlideAutoConfig` | 互動式填 .env 資源上限 |
| `install_recorder` | `專案錄影` | terminal 錄製 + diff 擷取 |
| `chrome_debug` | `Chrome_debug` | 抓 Chrome bug report |

新增工具:在 `publish.sh` 的 `vault_dir_for` / `file_prefix_for` 各加一行對應。
