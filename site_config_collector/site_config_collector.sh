#!/usr/bin/env bash
# collect_site_config.sh — 唯讀採集客戶站台環境資訊,輸出 Markdown 供貼入 Obsidian
# site config 模板(標「腳本」的欄位)。
#
# 安全性:全程唯讀,不安裝、不修改、不需 sudo。可直接在正式機執行。
#   (--with-sudo 例外:多跑一個 `sudo -n dmidecode` 抓硬體序號,仍是唯讀查詢;
#    用 -n 不會問密碼,沒權限就自動略過。)
# 用法:
#   在站台上執行:  bash collect_site_config.sh [部署目錄] [--peer [user@]host] [--no-remote] [--with-sudo]
#   部署目錄預設 ~/website(aetherSlide)。
#   例:bash collect_site_config.sh ~/website > site_$(hostname).md
#
# dual node:自動判定本機是 node-1 還是 node-2(比對 .env 的 NODE_1_IP/NODE_2_IP),
#   並嘗試 SSH 到另一台跑同一份腳本,一次收齊兩台。SSH 用 BatchMode(不會問密碼),
#   不通就跳過並提示到另一台手動執行。--peer 手動指定對方(自動判定失敗或帳號不同時用),
#   --no-remote 只採本機。首次連線會寫入 ~/.ssh/known_hosts(唯讀例外,僅此一項)。
#
# 缺少的指令(nvidia-smi/docker/ss 等)會自動略過並註記,不會中斷。

set -u
SELF="${BASH_SOURCE[0]:-}"
DEPLOY_DIR=""
DEPLOY_DIR_EXPLICIT=0
PEER=""
DO_REMOTE=1
CHILD=0   # 內部用:被另一個節點透過 SSH 叫起來的那一次
WITH_SUDO=0
while [ $# -gt 0 ]; do
  case "$1" in
    --with-sudo) WITH_SUDO=1; shift ;;
    --peer)
      PEER="${2:-}"
      [ -n "$PEER" ] || { echo "--peer 需要 [user@]host" >&2; exit 2; }
      shift 2 ;;
    --no-remote) DO_REMOTE=0; shift ;;
    --remote-child) CHILD=1; DO_REMOTE=0; shift ;;
    -h|--help)
      sed -n '2,13p' "${SELF:-$0}" 2>/dev/null | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) DEPLOY_DIR="$1"; DEPLOY_DIR_EXPLICIT=1; shift ;;
  esac
done
[ -n "$DEPLOY_DIR" ] || DEPLOY_DIR="$HOME/website"

have() { command -v "$1" >/dev/null 2>&1; }
sec()  { printf '\n## %s\n\n' "$1"; }
kv()   { printf -- '- **%s**: %s\n' "$1" "$2"; }
note() { printf -- '- _(略過:%s)_\n' "$1"; }
# 只取單一鍵的值,不 source 整個 env 檔
envval() {
  [ -f "$1" ] || return 0
  grep -E "^[[:space:]]*$2=" "$1" 2>/dev/null | tail -1 |
    sed -E "s/^[[:space:]]*$2=//" | tr -d "\"'" | tr -d '\r'
}

# ── 0. 節點識別 ──────────────────────────────
# ARCHITECTURE 在 configs.env;NODE_1_IP/NODE_2_IP/VIRTUAL_IP/ES_HOST 在 .env
ARCH="$(envval "$DEPLOY_DIR/configs.env" ARCHITECTURE)"
NODE_1_IP="$(envval "$DEPLOY_DIR/.env" NODE_1_IP)"
NODE_2_IP="$(envval "$DEPLOY_DIR/.env" NODE_2_IP)"
VIRTUAL_IP="$(envval "$DEPLOY_DIR/.env" VIRTUAL_IP)"
ES_HOST="$(envval "$DEPLOY_DIR/.env" ES_HOST)"
MY_IPS="$(ip -brief addr 2>/dev/null | awk '{for(i=3;i<=NF;i++) print $i}' | cut -d/ -f1)"
has_ip() { [ -n "${1:-}" ] && printf '%s\n' "$MY_IPS" | grep -qx "$1"; }

NODE_SELF=""
PEER_IP=""
if [ "$ARCH" = "dual" ]; then
  if has_ip "$NODE_1_IP";   then NODE_SELF="node-1"; PEER_IP="$NODE_2_IP"
  elif has_ip "$NODE_2_IP"; then NODE_SELF="node-2"; PEER_IP="$NODE_1_IP"
  else NODE_SELF="dual/未知節點"; fi
elif [ -n "$ARCH" ]; then
  NODE_SELF="$ARCH"
else
  NODE_SELF="未知(讀不到 $DEPLOY_DIR/configs.env)"
fi

printf '# site config 採集結果 — %s(%s)\n' "$(hostname 2>/dev/null || echo unknown)" "$NODE_SELF"
printf '> 唯讀採集。請把各段貼進 Obsidian 模板對應欄位;敏感值(帳密/私鑰)本腳本刻意不抓。\n'

sec "0. 節點識別"
kv "hostname" "$(hostname 2>/dev/null || echo unknown)"
kv "架構 ARCHITECTURE" "${ARCH:-未知}"
kv "本機節點" "$NODE_SELF"
if [ "$ARCH" = "dual" ]; then
  kv "NODE_1_IP" "${NODE_1_IP:-(空)}"
  kv "NODE_2_IP" "${NODE_2_IP:-(空)}"
  kv "VIRTUAL_IP(VIP)" "${VIRTUAL_IP:-(空)}"
  kv "ES_HOST" "${ES_HOST:-(空)}"
  if has_ip "$VIRTUAL_IP"; then
    kv "VIP 目前綁在本機" "是(本機為 keepalived master)"
  else
    kv "VIP 目前綁在本機" "否"
  fi
  [ "$NODE_SELF" = "dual/未知節點" ] &&
    printf -- '- _NODE_1_IP/NODE_2_IP 都不在本機介面上,可能是 .env 未填或走 NAT;請人工確認_\n'
fi

# ── 1. 對外與網路 ──────────────────────────────
sec "1. 對外與網路"
# 自動判斷最可能的對外路徑:預設路由的介面就是主要對外網卡,不列整張路由表
if have ip; then
  DEF_LINE="$(ip route show default 2>/dev/null | head -1)"
  DEF_GW="$(echo "$DEF_LINE" | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')"
  DEF_IF="$(echo "$DEF_LINE" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')"
  DEF_IP="$(ip -brief addr show "$DEF_IF" 2>/dev/null | awk '{print $3}')"
  kv "主要對外介面(預設路由)" "${DEF_IF:-未知}"
  kv "主要 IP" "${DEF_IP:-未知}"
  kv "預設 gateway" "${DEF_GW:-未知}"
else
  note "無 ip 指令"
fi
# 濾掉 docker 生出來的虛擬網卡(veth*、br-<id>、docker0、vnet*),
# 有跑 aetherSlide 的站台會有幾十個 veth,會把真正的實體網卡淹掉。
printf '### 所有介面(已濾掉 docker 虛擬網卡)\n```\n'
if have ip; then
  ip -brief addr 2>/dev/null | grep -vE '^(veth|br-[0-9a-f]{6,}|docker[0-9]|vnet)'
fi
printf '```\n### DNS\n```\n'
grep -E '^nameserver' /etc/resolv.conf 2>/dev/null || note "讀不到 resolv.conf"
printf '```\n'
# v1.2 起不再列 listen port:實測抓到的幾乎都是 NFS/RPC 動態高位 port 與跳板服務,
# 對交接沒幫助,反而要人去分辨雜訊。對外開放哪些 port 以防火牆規則為準,人工填。

# ── SSL 憑證 ──
sec "SSL 憑證"
CERT="$DEPLOY_DIR/data/ssl/cert.pem"
if [ -f "$CERT" ] && have openssl; then
  kv "憑證檔" "$CERT"
  kv "Subject" "$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null | sed 's/^subject=//')"
  kv "SAN" "$(openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null | grep -v 'X509v3' | tr -s ' ')"
  kv "到期" "$(openssl x509 -in "$CERT" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
elif printf '%s' "$(envval "$DEPLOY_DIR/configs.env" MODULES)" | grep -q caddy ||
     { have docker && docker ps --format '{{.Names}}' 2>/dev/null | grep -q caddy; }; then
  # 啟用 caddy 的站台憑證由 caddy 自己申請與續約,不會放在 data/ssl
  kv "憑證管理方式" "caddy(ACME 自動申請 / 續約),不在 $DEPLOY_DIR/data/ssl"
  note "憑證細節要進 caddy 容器或看 caddy 資料目錄,本腳本不進容器"
else
  note "找不到 $CERT 或無 openssl(非標準路徑請自行指定)"
fi

# ── 2. 硬體 ──────────────────────────────
sec "2. 硬體"
if have lscpu; then
  kv "CPU 型號" "$(lscpu 2>/dev/null | grep -E 'Model name' | sed 's/.*: *//')"
  kv "CPU 核心(邏輯)" "$(nproc 2>/dev/null)"
else note "無 lscpu"; fi
if have free; then kv "RAM" "$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')"; fi
if have nvidia-smi; then
  kv "GPU driver / CUDA" "driver $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1) / $(nvidia-smi 2>/dev/null | sed -n 's/.*CUDA Version: *\([0-9.]*\).*/\1/p' | head -1)"
fi
printf '### GPU\n```\n'
if have nvidia-smi; then
  nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader 2>/dev/null || nvidia-smi -L 2>/dev/null
else note "無 nvidia-smi"; fi
printf '```\n'
# 序號/保固要靠 dmidecode(需 sudo),預設不跑;--with-sudo 才試,且用 sudo -n 不問密碼
if [ "$WITH_SUDO" = "1" ] && have dmidecode; then
  SERIAL="$(sudo -n dmidecode -s system-serial-number 2>/dev/null | grep -v '^#' | head -1)"
  PRODUCT="$(sudo -n dmidecode -s system-product-name 2>/dev/null | grep -v '^#' | head -1)"
  VENDOR="$(sudo -n dmidecode -s system-manufacturer 2>/dev/null | grep -v '^#' | head -1)"
  if [ -n "$SERIAL$PRODUCT$VENDOR" ]; then
    kv "廠牌 / 型號" "${VENDOR:-未知} / ${PRODUCT:-未知}"
    kv "系統序號" "${SERIAL:-未知}"
  else
    note "--with-sudo 但沒有免密 sudo 權限,序號仍需人工查"
  fi
else
  printf -- '_序號 / 保固 / 供應商需另查(需 sudo;有免密 sudo 時可加 `--with-sudo` 讓腳本抓)_\n'
fi

# ── 3. OS / 虛擬化 / 邏輯結構 ──────────────────────────────
sec "3. OS / 虛擬化 / 邏輯結構"
kv "OS" "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
kv "Kernel" "$(uname -r 2>/dev/null)"
if have systemd-detect-virt; then kv "虛擬化" "$(systemd-detect-virt 2>/dev/null)"; fi
if have docker; then kv "Docker" "$(docker --version 2>/dev/null)"; else note "無 docker"; fi
printf '### 區塊裝置 / 分割\n```\n'
if have lsblk; then lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null; else note "無 lsblk"; fi
printf '```\n### 磁碟使用 / mount\n```\n'
if have df; then df -hT 2>/dev/null | grep -vE 'tmpfs|overlay'; fi
printf '```\n'
if [ -f /proc/mdstat ] && grep -q '^md' /proc/mdstat 2>/dev/null; then
  printf '### RAID(mdstat)\n```\n'; cat /proc/mdstat 2>/dev/null; printf '```\n'
fi
# LVM:vgs/lvs 非 root 會把警告丟到 stderr、stdout 留空,看起來像「這台沒有 LVM」。
# 所以要分辨「真的沒有」與「沒權限」,--with-sudo 時再試一次。
if have vgs; then
  LVM_OUT="$(vgs 2>/dev/null; lvs 2>/dev/null)"
  if [ -z "$LVM_OUT" ] && [ "$WITH_SUDO" = "1" ]; then
    LVM_OUT="$(sudo -n vgs 2>/dev/null; sudo -n lvs 2>/dev/null)"
  fi
  printf '### LVM\n'
  if [ -n "$LVM_OUT" ]; then
    printf '```\n%s\n```\n' "$LVM_OUT"
  elif lsblk -o FSTYPE 2>/dev/null | grep -q LVM2_member; then
    note "偵測到 LVM2_member 分割,但 vgs/lvs 需要 root 才讀得到(可加 --with-sudo,或人工確認)"
  else
    printf -- '- 無 LVM\n'
  fi
fi

# ── 4. aetherSlide / AI app 部署 ──────────────────────────────
sec "4. aetherSlide / AI app 部署"
kv "部署目錄" "$DEPLOY_DIR"
# 版本:.env 的 TAG 是「設定要跑哪版」,實際跑的 image tag 是「現在真的在跑哪版」。
# 兩者不一致 = 改了 TAG 但沒重建。hotfix / 客製版仍要人工補註記。
kv "aetherSlide 版本 TAG(設定值)" "$(envval "$DEPLOY_DIR/.env" TAG)"
if have docker; then
  # 只看自家 registry 的 image;redis 等第三方 image 的 tag 不是 aetherSlide 版本
  RUNNING_TAG="$(docker ps --format '{{.Image}}' 2>/dev/null | grep -i aetherai |
    sed -n 's/.*:\([^:]*\)$/\1/p' | sort -u | paste -sd ', ' -)"
  if [ -z "$RUNNING_TAG" ] && docker ps -q 2>/dev/null | grep -q .; then
    RUNNING_TAG="$(docker ps --format '{{.Image}}' 2>/dev/null | sed -n 's/.*:\([^:]*\)$/\1/p' | sort -u | paste -sd ', ' -)(非自家 registry,請確認)"
  fi
  kv "實際執行中的 image tag" "${RUNNING_TAG:-(無執行中 container)}"
fi
kv "SITE_NAME(站台代號)" "$(envval "$DEPLOY_DIR/configs.env" SITE_NAME)"
kv "MODULES(啟用的功能模組)" "$(envval "$DEPLOY_DIR/configs.env" MODULES)"
kv "WEB_NETWORK_LOCATION(對外網址)" "$(envval "$DEPLOY_DIR/configs.env" WEB_NETWORK_LOCATION)"
if [ -d "$DEPLOY_DIR" ]; then
  printf '### 設定檔存在狀況\n'
  for f in configs.env prefs.env .env configs.yaml tier_configs.yaml model-config; do
    if [ -e "$DEPLOY_DIR/$f" ]; then kv "$f" "存在"; else kv "$f" "(無)"; fi
  done
  [ -d "$DEPLOY_DIR/secrets" ] && kv "secrets/" "存在(目錄)"
else
  note "部署目錄不存在:$DEPLOY_DIR"
fi
# 站台有幾十個容器,不健康的會混在清單裡看不到,所以先單獨拉出來當警示
if have docker; then
  BAD="$(docker ps --format '{{.Names}}\t{{.Status}}' 2>/dev/null |
    grep -iE 'restarting|unhealthy|health: starting|created|paused')"
  printf '### 狀態不正常的 container(先看這個)\n'
  if [ -n "$BAD" ]; then
    printf '```\n%s\n```\n' "$BAD"
    printf -- '- _重啟中 / unhealthy 代表這個服務現在是壞的,交接時要問清楚原因_\n'
  else
    printf -- '- 無狀態異常的 container\n'
  fi
fi
printf '### 執行中 container(名稱 / image / 狀態 / 對外 port)\n```\n'
if have docker; then
  docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || note "docker ps 失敗(權限?)"
else note "無 docker"; fi
printf '```\n'
# 只列最近 15 個。Exited (0) 多半是 init / volume 準備之類的一次性容器,屬正常
if have docker; then
  STOPPED="$(docker ps -a --filter 'status=exited' --filter 'status=dead' \
    --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null | head -15)"
  printf '### 已停止的 container(Exited 0 多半是一次性初始化,非 0 才要追)\n'
  if [ -n "$STOPPED" ]; then printf '```\n%s\n```\n' "$STOPPED"; else printf -- '- 無\n'; fi
fi

# ── 5. 對接與整合設定(從 configs.env 讀,不含任何密碼類鍵)─────────────
sec "5. 對接與整合設定"
if [ -f "$DEPLOY_DIR/configs.env" ]; then
  kv "DICOM AE Title" "$(envval "$DEPLOY_DIR/configs.env" WEB_DICOM_SCP__AE_TITLE)"
  kv "DICOM SCP 使用者" "$(envval "$DEPLOY_DIR/configs.env" WEB_BACKEND__DICOM_SCP_USER)"
  kv "HL7v2 訊息編碼" "$(envval "$DEPLOY_DIR/configs.env" WEB_HL7V2_SERVER__MESSAGE_CODEC)"
  kv "LDAP 整合" "$(envval "$DEPLOY_DIR/configs.env" WEB_BACKEND__LDAP_INTEGRATION)(1=開)"
  kv "LDAP server" "$(envval "$DEPLOY_DIR/configs.env" WEB_BACKEND__LDAP_SERVER_URL)"
  kv "LDAP bind domain" "$(envval "$DEPLOY_DIR/configs.env" WEB_BACKEND__LDAP_BIND_DOMAIN)"
  kv "aetherAI LDAP 登入" "$(envval "$DEPLOY_DIR/configs.env" WEB_BACKEND__ENABLE_AETHERAI_LDAP_LOGIN)(1=開)"
  kv "自動匯入 AUTO_IMPORT" "$(envval "$DEPLOY_DIR/configs.env" AUTO_IMPORT_ENABLED)(1=開),路徑 $(envval "$DEPLOY_DIR/configs.env" AUTO_IMPORT_PATH)"
  kv "分層儲存 GIGASTORE_ENABLE_TIERING" "$(envval "$DEPLOY_DIR/configs.env" GIGASTORE_ENABLE_TIERING)(1=開)"
  kv "匯出路徑" "$(envval "$DEPLOY_DIR/configs.env" WEB_BACKEND__EXPORT_PATH)"
  kv "NDPI 匯入時轉 DICOM" "$(envval "$DEPLOY_DIR/configs.env" WEB_BACKEND__CONVERT_NDPI_TO_DICOM_ON_IMPORT)(1=開)"
  printf -- '_掃描機型號 / PACS-LIS-HIS 對接對象 / 對方 IP 與 port 仍需人工填(設定檔看不出來)_\n'
else
  note "讀不到 $DEPLOY_DIR/configs.env"
fi

# ── 6. 維運排程與時間 ──────────────────────────────
sec "6. 維運排程與時間"
if have timedatectl; then
  kv "時區 / NTP" "$(timedatectl 2>/dev/null | tr -s ' ' | grep -E 'Time zone|NTP' | paste -sd '; ' -)"
else
  kv "時間 / 時區" "$(date 2>/dev/null)"
fi
printf '### 使用者 crontab\n```\n'
crontab -l 2>/dev/null || printf '(無 crontab 或讀不到)\n'
printf '```\n'
if have systemctl; then
  UNITS="$(systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null \
    | grep -iE 'docker|compose|aetherslide|website' | awk '{print $1}')"
  printf '### 相關 systemd service\n'
  if [ -n "$UNITS" ]; then printf '```\n%s\n```\n' "$UNITS"; else printf -- '- 無(可能是人工 `bin/dc up` 起的)\n'; fi
  # 濾掉每台 Ubuntu 都有的 OS 預設 timer,只留這台自己加的
  TIMERS="$(systemctl list-timers --all --no-pager --no-legend 2>/dev/null \
    | grep -vE 'fwupd|man-db|logrotate|motd-news|dpkg-db-backup|systemd-tmpfiles|update-notifier|fstrim|sysstat|apt-daily|e2scrub|snapd|ua-timer|ubuntu-advantage|anacron|plocate|mlocate|apport')"
  printf '### systemd timer(已濾掉 OS 預設,只留這台自己加的)\n'
  if [ -n "$TIMERS" ]; then printf '```\n%s\n```\n' "$TIMERS"; else printf -- '- 無\n'; fi
fi

# ── 7. 另一個節點(dual;SSH 一次收齊兩台)──────────────────────────────
# 遠端跑的是同一份腳本(從 stdin 餵過去,不落地),並帶 --no-remote 避免互相遞迴。
PEER_TARGET="$PEER"
[ -n "$PEER_TARGET" ] || { [ "$ARCH" = "dual" ] && PEER_TARGET="$PEER_IP"; }

if [ "$DO_REMOTE" = "1" ] && [ -n "$PEER_TARGET" ]; then
  sec "7. 另一個節點(遠端採集:$PEER_TARGET)"
  REMOTE_ARGS="--remote-child"
  [ "$DEPLOY_DIR_EXPLICIT" = "1" ] && REMOTE_ARGS="$REMOTE_ARGS '$DEPLOY_DIR'"
  if [ -z "$SELF" ] || [ ! -r "$SELF" ]; then
    note "讀不到腳本自身檔案(可能是 pipe 執行),無法送到遠端;請在 $PEER_TARGET 上自行執行本腳本"
  elif ! have ssh; then
    note "本機無 ssh"
  elif ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
        "$PEER_TARGET" "bash -s -- $REMOTE_ARGS" < "$SELF" 2>/tmp/.sc_ssh_err; then
    :
  else
    printf -- '- _SSH 到 %s 失敗(BatchMode:不會問密碼)。原因:_\n' "$PEER_TARGET"
    printf '```\n%s\n```\n' "$(cat /tmp/.sc_ssh_err 2>/dev/null)"
    printf -- '- _請改用 `--peer user@host` 指定正確帳號,或到另一台執行:_\n'
    printf '```\nbash collect_site_config.sh %s--no-remote\n```\n' \
      "$([ "$DEPLOY_DIR_EXPLICIT" = "1" ] && printf '%s ' "$DEPLOY_DIR")"
  fi
  rm -f /tmp/.sc_ssh_err 2>/dev/null
elif [ "$ARCH" = "dual" ] && [ "$CHILD" = "0" ]; then
  sec "7. 另一個節點"
  if [ "$DO_REMOTE" = "0" ]; then
    note "--no-remote:只採本機,另一台請自行執行"
  else
    note "dual 架構但推不出對方 IP(.env 的 NODE_1_IP/NODE_2_IP 未填?),請用 --peer [user@]host 指定"
  fi
fi

[ "$CHILD" = "0" ] &&
  printf '\n---\n_採集完成。硬體序號/保固、對接整合、聯絡窗口等需人工填寫的欄位不在此輸出。_\n'
exit 0
