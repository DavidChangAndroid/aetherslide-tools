#!/usr/bin/env bash
# collect_site_config.sh — 唯讀採集客戶站台環境資訊,輸出 Markdown 供貼入 Obsidian
# site config 模板(標「腳本」的欄位)。
#
# 安全性:全程唯讀,不安裝、不修改、不需 sudo。可直接在正式機執行。
#   (--with-sudo 例外:多跑一個 `sudo -n dmidecode` 抓硬體序號,仍是唯讀查詢;
#    用 -n 不會問密碼,沒權限就自動略過。)
# 用法:
#   在站台上執行:  bash collect_site_config.sh [部署目錄] [--peer [user@]host] [--no-remote] [--with-sudo]
#                                              [--ai-landing-dir 目錄]
#   部署目錄預設 ~/website(aetherSlide)。
#   例:bash collect_site_config.sh ~/website > site_$(hostname).md
#
# AI Landing(AI 推論主機):自動偵測本機有沒有 AI Landing(部署目錄 + microk8s 的
#   ai-landing namespace),有就多出一段完整採集。GPU 常跟 aetherSlide 分開裝,
#   分開時請「兩台各跑一次」,輸出各貼進同一份 site config —— 本腳本不會自動 SSH 到
#   AI Landing 主機(兩台常屬不同網段/不同單位,免密 SSH 通常不存在)。
#   沒偵測到就只印 aetherSlide 的 AI_LANDING_URL 並判斷它指的是不是本機。
#   --ai-landing-dir 手動指定(自動偵測不到時用)。
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
AIL_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --with-sudo) WITH_SUDO=1; shift ;;
    --ai-landing-dir)
      AIL_DIR="${2:-}"
      [ -n "$AIL_DIR" ] || { echo "--ai-landing-dir 需要目錄" >&2; exit 2; }
      shift 2 ;;
    --peer)
      PEER="${2:-}"
      [ -n "$PEER" ] || { echo "--peer 需要 [user@]host" >&2; exit 2; }
      shift 2 ;;
    --no-remote) DO_REMOTE=0; shift ;;
    --remote-child) CHILD=1; DO_REMOTE=0; shift ;;
    -h|--help)
      sed -n '2,26p' "${SELF:-$0}" 2>/dev/null | sed 's/^# \{0,1\}//'
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
# values.yaml 同樣逐鍵取值(不整檔倒出,密碼類鍵不會被查)。$2 是含縮排錨點的 grep 規則,
# 因為同一個鍵名可能在不同層出現(例如 top-level 的 port 與 grafana service 的 port)。
yamlval() {
  [ -f "$1" ] || return 0
  grep -E "$2" "$1" 2>/dev/null | head -1 |
    sed -E 's/^[^:]*:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^&[A-Za-z0-9_]+[[:space:]]*//' |
    tr -d "\"'" | tr -d '\r'
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
elif [ -f "$DEPLOY_DIR/configs.env" ]; then
  NODE_SELF="未知(configs.env 沒有 ARCHITECTURE)"
else
  # v1.6:純 AI Landing 主機本來就沒有 configs.env,舊版會在標題印「讀不到 configs.env」,
  # 看起來像 aetherSlide 壞了,其實是這台根本沒裝
  NODE_SELF="非 aetherSlide 主機"
fi

# ── AI Landing(AI 推論主機)偵測 ──────────────
# GPU 常跟 aetherSlide 分開裝,所以「本機有沒有 aetherSlide」與「本機有沒有 AI Landing」
# 是兩個獨立的問題,要各自判,不能假設同一台。
HAS_AS=0
{ [ -f "$DEPLOY_DIR/configs.env" ] || [ -f "$DEPLOY_DIR/.env" ]; } && HAS_AS=1
if [ -z "$AIL_DIR" ]; then
  for _d in "$HOME/ai-landing" "$HOME/AI-Landing" /opt/ai-landing /opt/AI-Landing; do
    [ -f "$_d/values.yaml" ] && { AIL_DIR="$_d"; break; }
  done
fi
# k8s 指令:microk8s 優先(AI Landing 的官方裝法),退回原生 kubectl。
# 判準用「真的問得到 namespace」而不是 command -v —— 指令在但沒權限或叢集沒起,
# 後面每一條查詢都會空手而回,不如一開始就分清楚。
KCTL=""
if have microk8s && microk8s kubectl get ns >/dev/null 2>&1; then KCTL="microk8s kubectl"
elif have kubectl && kubectl get ns >/dev/null 2>&1; then KCTL="kubectl"; fi
kctl() { [ -n "$KCTL" ] && $KCTL "$@" 2>/dev/null; }
HELM=""
if have microk8s && microk8s helm version >/dev/null 2>&1; then HELM="microk8s helm"
elif have helm; then HELM="helm"; fi

AIL_NS="$(yamlval "$AIL_DIR/values.yaml" '^[[:space:]]+namespace:')"
[ -n "$AIL_NS" ] || AIL_NS="ai-landing"
HAS_AIL_NS=0
[ -n "$KCTL" ] && $KCTL get ns "$AIL_NS" >/dev/null 2>&1 && HAS_AIL_NS=1
HAS_AIL=0
{ [ -n "$AIL_DIR" ] || [ "$HAS_AIL_NS" = "1" ]; } && HAS_AIL=1

if [ "$HAS_AS" = "1" ] && [ "$HAS_AIL" = "1" ]; then ROLE="aetherSlide + AI Landing(同機)"
elif [ "$HAS_AIL" = "1" ];                        then ROLE="AI Landing(本機沒有 aetherSlide)"
elif [ "$HAS_AS" = "1" ];                         then ROLE="aetherSlide(本機沒有 AI Landing)"
else                                                   ROLE="兩者都沒偵測到"
fi

printf '# site config 採集結果 — %s(%s)\n' "$(hostname 2>/dev/null || echo unknown)" "$NODE_SELF"
printf '> 唯讀採集。請把各段貼進 Obsidian 模板對應欄位;敏感值(帳密/私鑰)本腳本刻意不抓。\n'

sec "0. 節點識別"
kv "hostname" "$(hostname 2>/dev/null || echo unknown)"
kv "本機角色" "$ROLE"
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
# 介面過濾(v1.4):純黑名單擋不住沒列到的名字(k8s 的 cali*、kernel 的 ip_vti0…),
# 純白名單又會誤殺 br0 / bond0 / vlan 這些沒有實體裝置的主介面。所以用兩層:
#   第一層(正向):留下「有實體裝置」或「有 IPv4」的 —— veth pair、cali*、ip_vti0
#                  兩者皆非,不必知道名字就會被擋掉;DOWN 但存在的實體網卡會留著
#                  (「有第二張網卡沒接線」是交接時要知道的事)。
#   第二層(反向):再擋掉「有 IP 但屬於容器 / 虛擬化橋接」的那一小類。
printf '### 網路介面(已濾掉容器與虛擬網卡)\n```\n'
if have ip; then
  for _if in /sys/class/net/*; do
    _n="$(basename "$_if")"
    [ "$_n" = "lo" ] && continue
    case "$_n" in
      docker*|cni*|flannel*|kube-ipvs*|virbr*|mpqemubr*|lxdbr*|lxcbr*|podman*) continue ;;
    esac
    printf '%s' "$_n" | grep -qE '^br-[0-9a-f]{6,}$' && continue   # docker 自建 bridge
    if [ -e "$_if/device" ] ||
       ip -4 -brief addr show "$_n" 2>/dev/null | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
      ip -brief addr show "$_n" 2>/dev/null
    fi
  done
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
# v1.6:-e 7 濾掉 loop 裝置(major 7)。microk8s 是 snap 裝的,AI Landing 主機上
# 實測有 29 個 squashfs loop,把真正的磁碟結構整個淹掉 —— 跟 veth 洪水同一類問題。
if have lsblk; then lsblk -e 7 -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null; else note "無 lsblk"; fi
printf '```\n### 磁碟使用 / mount\n```\n'
if have df; then df -hT 2>/dev/null | grep -vE 'tmpfs|overlay|squashfs'; fi
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

# ── 4. aetherSlide 部署 ──────────────────────────────
# v1.6:整節用 HAS_AS 包起來。AI 推論主機常常沒有 aetherSlide(GPU 分開裝),
# 舊版會照樣印出十幾個空欄位與「無執行中 container」,看起來像「裝了但全掛了」。
sec "4. aetherSlide / AI app 部署"
if [ "$HAS_AS" = "0" ]; then
  note "本機沒有 aetherSlide 部署($DEPLOY_DIR 找不到 configs.env / .env),本節略過"
  note "部署在別的路徑的話用第一個參數指定:bash collect_site_config.sh /path/to/website"
else
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
  printf '### 設定檔存在狀況\n'
  for f in configs.env prefs.env .env configs.yaml tier_configs.yaml model-config; do
    if [ -e "$DEPLOY_DIR/$f" ]; then kv "$f" "存在"; else kv "$f" "(無)"; fi
  done
  [ -d "$DEPLOY_DIR/secrets" ] && kv "secrets/" "存在(目錄)"
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
fi

# ── 5. 對接與整合設定(從 configs.env 讀,不含任何密碼類鍵)─────────────
sec "5. 對接與整合設定"
# v1.5:configs.env 裡的 DICOM / HL7 等鍵就算沒用到也會有預設值,
# 模組沒列在 MODULES 裡就代表那個服務根本沒起、設定不生效 —— 不註明會讓人以為有對接。
MODULES_VAL="$(envval "$DEPLOY_DIR/configs.env" MODULES | tr -d ' ')"
mod_off() {   # 模組不在 MODULES 裡就回傳提示字串
  if printf '%s' ",$MODULES_VAL," | grep -q ",$1,"; then printf ''
  else printf '(%s 模組未啟用,此設定不生效)' "$1"; fi
}
if [ -f "$DEPLOY_DIR/configs.env" ]; then
  kv "啟用的模組 MODULES" "${MODULES_VAL:-(空)}"
  kv "DICOM AE Title" "$(envval "$DEPLOY_DIR/configs.env" WEB_DICOM_SCP__AE_TITLE)$(mod_off dicom)"
  kv "DICOM SCP 使用者" "$(envval "$DEPLOY_DIR/configs.env" WEB_BACKEND__DICOM_SCP_USER)$(mod_off dicom)"
  kv "HL7v2 訊息編碼" "$(envval "$DEPLOY_DIR/configs.env" WEB_HL7V2_SERVER__MESSAGE_CODEC)$(mod_off hl7v2)"
  kv "LDAP 整合" "$(envval "$DEPLOY_DIR/configs.env" WEB_BACKEND__LDAP_INTEGRATION)(1=開)"
  kv "LDAP server" "$(envval "$DEPLOY_DIR/configs.env" WEB_BACKEND__LDAP_SERVER_URL)"
  kv "LDAP bind domain" "$(envval "$DEPLOY_DIR/configs.env" WEB_BACKEND__LDAP_BIND_DOMAIN)"
  kv "aetherAI LDAP 登入" "$(envval "$DEPLOY_DIR/configs.env" WEB_BACKEND__ENABLE_AETHERAI_LDAP_LOGIN)(1=開)"
  kv "自動匯入 AUTO_IMPORT" "$(envval "$DEPLOY_DIR/configs.env" AUTO_IMPORT_ENABLED)(1=開),路徑 $(envval "$DEPLOY_DIR/configs.env" AUTO_IMPORT_PATH)$(mod_off auto-import)"
  kv "分層儲存 GIGASTORE_ENABLE_TIERING" "$(envval "$DEPLOY_DIR/configs.env" GIGASTORE_ENABLE_TIERING)(1=開)"
  kv "匯出路徑" "$(envval "$DEPLOY_DIR/configs.env" WEB_BACKEND__EXPORT_PATH)"
  kv "NDPI 匯入時轉 DICOM" "$(envval "$DEPLOY_DIR/configs.env" WEB_BACKEND__CONVERT_NDPI_TO_DICOM_ON_IMPORT)(1=開)"
  # v1.6:AI 推論的去向。註解掉時走程式預設(http://dgx.aetherai.com),
  # 所以「configs.env 沒這行」不等於「沒有 AI 推論」,要標出來而不是留空。
  AIL_URL="$(envval "$DEPLOY_DIR/configs.env" AI_LANDING_URL)"
  kv "AI_LANDING_URL(AI 推論端點)" "${AIL_URL:-(未設定 / 被註解 → 走程式預設值,需查該版預設)}"
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
    | grep -iE 'docker|compose|aetherslide|website|microk8s|kubelet|containerd' | awk '{print $1}')"
  printf '### 相關 systemd service\n'
  if [ -n "$UNITS" ]; then printf '```\n%s\n```\n' "$UNITS"; else printf -- '- 無(可能是人工 `bin/dc up` 起的)\n'; fi
  # 濾掉每台 Ubuntu 都有的 OS 預設 timer,只留這台自己加的
  TIMERS="$(systemctl list-timers --all --no-pager --no-legend 2>/dev/null \
    | grep -vE 'fwupd|man-db|logrotate|motd-news|dpkg-db-backup|systemd-tmpfiles|update-notifier|fstrim|sysstat|apt-daily|e2scrub|snapd|ua-timer|ubuntu-advantage|anacron|plocate|mlocate|apport')"
  printf '### systemd timer(已濾掉 OS 預設,只留這台自己加的)\n'
  if [ -n "$TIMERS" ]; then printf '```\n%s\n```\n' "$TIMERS"; else printf -- '- 無\n'; fi
fi

# ── 7. AI Landing(AI 推論主機)──────────────────────────────
# v1.6 新增。AI Landing 是 microk8s + helm,不是 docker compose,所以整段是另一套指令。
# 跟 dual node 不同,這裡「不」自動 SSH 過去:dual 兩台是同一套部署、同一批人裝的,
# 節點間免密 SSH 還有機會;aetherSlide 與 GPU 主機常屬不同網段甚至不同單位,
# 自動連只會生一堆失敗訊息,不如明講「到那台再跑一次」。
sec "7. AI Landing(AI 推論)"
if [ "$HAS_AIL" = "0" ]; then
  note "本機沒有 AI Landing(找不到部署目錄的 values.yaml,也沒有 $AIL_NS namespace)"
  if [ -n "${AIL_URL:-}" ]; then
    # 只比對 host 部分;URL 可能帶 port 或走 FQDN
    AIL_HOST="$(printf '%s' "$AIL_URL" | sed -E 's#^[a-zA-Z]+://##; s#[:/].*$##')"
    if has_ip "$AIL_HOST"; then
      kv "AI_LANDING_URL 指向" "$AIL_URL(是本機 IP,但本機偵測不到 AI Landing → 需人工確認)"
    else
      kv "AI_LANDING_URL 指向" "$AIL_URL(**不是本機**,AI 推論在另一台)"
      printf -- '- _請到那台主機再跑一次本腳本,把第 7 節貼進同一份 site config:_\n'
      printf '```\nbash collect_site_config.sh --no-remote\n```\n'
      printf -- '- _FQDN 的話實際 IP 由客戶 DNS/NAT 決定,要人工確認解析到哪台_\n'
    fi
  else
    note "本機也沒有 aetherSlide 的 AI_LANDING_URL 可參考,無法定位推論主機"
  fi
else
  kv "部署目錄" "${AIL_DIR:-(找不到;namespace 存在但目錄不在預設路徑,可用 --ai-landing-dir 指定)}"
  kv "namespace" "$AIL_NS"
  if [ -z "$KCTL" ]; then
    note "有部署目錄但 kubectl / microk8s kubectl 問不到叢集(權限?叢集沒起?),以下只列設定檔內容"
  else
    kv "k8s 指令" "$KCTL"
    have microk8s && kv "MicroK8s 版本" "$(microk8s version 2>/dev/null | head -1)"
  fi

  # ── 版本:三個來源要並列 ──
  # 實測 gpu-a4000:helm 顯示 0.0.0-<sha>、Chart.yaml 寫 1.1.18、image tag 是 git sha。
  # CI build 的部署 appVersion 會變成 0.0.0-<sha>,只抓一個會誤導。
  printf '### 版本(三個來源,不一致是常態,要一起看)\n'
  kv "Chart.yaml appVersion(部署目錄)" "$(yamlval "$AIL_DIR/charts/ai-landing/Chart.yaml" '^appVersion:')"
  if [ -n "$HELM" ]; then
    HELM_OUT="$($HELM list -A 2>/dev/null)"
    if [ -n "$HELM_OUT" ]; then
      printf '```\n%s\n```\n' "$HELM_OUT"
    else
      note "helm list 查不到 release(權限?)"
    fi
  else
    note "無 helm"
  fi
  IMGS="$(kctl get deploy -n "$AIL_NS" -o 'custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[*].image' --no-headers)"
  if [ -n "$IMGS" ]; then
    printf '### 核心服務 image(實際在跑的版本)\n```\n%s\n```\n' "$IMGS"
  fi

  # ── values.yaml:逐鍵取值,密碼類鍵一律不查(同 configs.env 的原則)──
  if [ -f "$AIL_DIR/values.yaml" ]; then
    printf '### values.yaml(非密鍵;adminPassword / SECRET_KEY / *_PASS 刻意不抓)\n'
    kv "external_ip" "$(yamlval "$AIL_DIR/values.yaml" '^external_ip:')"
    kv "port" "$(yamlval "$AIL_DIR/values.yaml" '^port:')"
    kv "image registry" "$(yamlval "$AIL_DIR/values.yaml" '^[[:space:]]+host:')/$(yamlval "$AIL_DIR/values.yaml" '^[[:space:]]+repository:')"
    kv "backend image_tag" "$(yamlval "$AIL_DIR/values.yaml" '^[[:space:]]+image_tag:')"
    kv "DJANGO_ALLOWED_HOSTS" "$(yamlval "$AIL_DIR/values.yaml" 'DJANGO_ALLOWED_HOSTS:')"
    kv "DJANGO_DEBUG" "$(yamlval "$AIL_DIR/values.yaml" 'DJANGO_DEBUG:')"
    kv "BACKEND_URL_PREFIX" "$(yamlval "$AIL_DIR/values.yaml" 'BACKEND_URL_PREFIX:')"
    kv "BACKEND_JOB_TTL_DAYS_AFTER_FINISHED" "$(yamlval "$AIL_DIR/values.yaml" 'BACKEND_JOB_TTL_DAYS_AFTER_FINISHED:')(job 保留天數,決定下面的統計看得到多久)"
    kv "UWSGI_PROCESS_NUMBER" "$(yamlval "$AIL_DIR/values.yaml" 'UWSGI_PROCESS_NUMBER:')"
    kv "backend logs storage_class" "$(yamlval "$AIL_DIR/values.yaml" '^[[:space:]]+storage_class:')"
    kv "database volumeSize" "$(yamlval "$AIL_DIR/values.yaml" '^[[:space:]]+volumeSize:')"
  else
    note "找不到 $AIL_DIR/values.yaml"
  fi

  # ── 對外端點 ──
  # 實測:8500 是 svc/ingress 的 externalIPs,由 kube-proxy 的 iptables 轉,
  # 主機上「沒有」listening socket,ss -ltnp 抓不到 —— 只能問 k8s。
  if [ -n "$KCTL" ]; then
    printf '### 對外端點(externalIPs 沒有 listening socket,ss 抓不到,只能問 k8s)\n'
    ING_SVC="$(kctl get svc -A --no-headers -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.type,EXTIP:.spec.externalIPs[*],PORT:.spec.ports[*].port' | awk '$4!="<none>"')"
    if [ -n "$ING_SVC" ]; then printf '```\n%s\n```\n' "$ING_SVC"; else note "沒有帶 externalIPs 的 service"; fi
    NP_SVC="$(kctl get svc -A --no-headers -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.type,NODEPORT:.spec.ports[*].nodePort' | awk '$3=="NodePort"')"
    printf '#### NodePort service\n'
    if [ -n "$NP_SVC" ]; then printf '```\n%s\n```\n' "$NP_SVC"; else printf -- '- 無\n'; fi
    ING="$(kctl get ingress -A --no-headers)"
    printf '#### Ingress\n'
    if [ -n "$ING" ]; then printf '```\n%s\n```\n' "$ING"; else printf -- '- 無\n'; fi
  fi

  # ── 叢集節點與 GPU 配置 ──
  if [ -n "$KCTL" ]; then
    printf '### 叢集節點\n```\n'
    kctl get nodes --no-headers -o 'custom-columns=NAME:.metadata.name,ROLES:.metadata.labels.node-role,VER:.status.nodeInfo.kubeletVersion,IP:.status.addresses[0].address,GPU:.status.capacity.nvidia\.com/gpu,RUNTIME:.status.nodeInfo.containerRuntimeVersion'
    printf '```\n'
    NODE_N="$(kctl get nodes --no-headers | wc -l | tr -d ' ')"
    kv "節點數" "${NODE_N:-未知}(1 = 單節點,>1 表示有加 worker)"
    # 實體 GPU 數 vs k8s 看到的 GPU 數:不一致就是 time-slicing 在切
    PHYS_GPU="$(nvidia-smi -L 2>/dev/null | grep -c GPU)"
    K8S_GPU="$(kctl get nodes -o 'custom-columns=G:.status.capacity.nvidia\.com/gpu' --no-headers | awk '$1 ~ /^[0-9]+$/ {s+=$1} END{print s+0}')"
    kv "實體 GPU 數(nvidia-smi)" "${PHYS_GPU:-0}"
    kv "k8s 可配置 GPU 數(capacity)" "${K8S_GPU:-0}(大於實體數 = time-slicing 有開)"
    TS="$(kctl get cm -A --no-headers | grep -i time-slicing)"
    printf '#### time-slicing configmap\n'
    if [ -n "$TS" ]; then printf '```\n%s\n```\n' "$TS"; else printf -- '- 無(未設定 time-slicing)\n'; fi
  fi

  # ── pod 狀態 ──
  # 實測 gpu-a4000:這個 namespace 有 1369 個 pod,其中 1359 個是推論 job 留下的。
  # 無腦 `get pods` 會吐 1369 行把報告淹掉,所以依 ownerReferences 拆兩半:
  # Job 擁有的只給統計,其餘(Deployment/StatefulSet/DaemonSet)才逐一列。
  if [ -n "$KCTL" ]; then
    PODS="$(kctl get pods -n "$AIL_NS" --no-headers -o 'custom-columns=OWNER:.metadata.ownerReferences[*].kind,NAME:.metadata.name,PHASE:.status.phase,REASON:.status.reason,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount')"
    CORE="$(printf '%s\n' "$PODS" | awk '$1!="Job"')"
    printf '### 核心 pod(已排除推論 job 的 pod)\n'
    if [ -n "$CORE" ]; then printf '```\n%s\n```\n' "$CORE"; else note "查不到 pod"; fi
    BADP="$(printf '%s\n' "$CORE" | awk '$3!="Running" && $3!="Succeeded" || $5 ~ /false/')"
    printf '#### 狀態不正常的核心 pod(先看這個)\n'
    if [ -n "$BADP" ]; then
      printf '```\n%s\n```\n' "$BADP"
      printf -- '- _交接時要問清楚原因_\n'
    else
      printf -- '- 無\n'
    fi
    printf '#### 推論 job 統計(受 BACKEND_JOB_TTL_DAYS_AFTER_FINISHED 限制,只看得到保留期內的)\n'
    JOB_N="$(kctl get jobs -n "$AIL_NS" --no-headers | wc -l | tr -d ' ')"
    kv "job 總數" "${JOB_N:-0}"
    printf '```\n%s\n```\n' "$(printf '%s\n' "$PODS" | awk '$1=="Job"{print $3" "$4}' | sort | uniq -c | sort -rn)"
    # 這是模板「AI model 版本」那格唯一抓得到的來源:跑過哪些 AI app 與版本。
    # 實測會混進 prometheus / grafana / postgres 等基礎設施 image,所以先只留 /ai-app/;
    # 客製 registry 路徑可能不長這樣,一個都沒命中就退回列全部並註明(同 v1.3 image tag 的做法)。
    ALL_IMG="$(kctl get pods -n "$AIL_NS" --no-headers -o 'custom-columns=IMG:.spec.containers[*].image' |
      tr ',' '\n' | sed 's/^ *//' | grep -v '^$')"
    APP_IMG="$(printf '%s\n' "$ALL_IMG" | grep '/ai-app/' | sort | uniq -c | sort -rn)"
    printf '#### 保留期內跑過的 AI app image(次數 / image)\n'
    if [ -n "$APP_IMG" ]; then
      printf '```\n%s\n```\n' "$APP_IMG"
    else
      printf -- '- _沒有 `/ai-app/` 路徑的 image,改列全部(含基礎設施 image,需自行分辨)_\n'
      printf '```\n%s\n```\n' "$(printf '%s\n' "$ALL_IMG" | sort | uniq -c | sort -rn)"
    fi
    printf -- '_這是「跑過」不是「裝了哪些」;沒被呼叫過的 app 不會出現_\n'
    printf '### PVC\n```\n'
    kctl get pvc -n "$AIL_NS" --no-headers
    printf '```\n'
  fi

  # ── aetherSlide 憑證註冊(兩邊的信任鏈)──
  CA=""
  for _c in "$AIL_DIR/ca-cert.internal.pem" "$AIL_DIR/bin/ca-cert.internal.pem"; do
    [ -f "$_c" ] && { CA="$_c"; break; }
  done
  if [ -n "$CA" ]; then
    kv "aetherSlide CA 憑證檔" "$CA(內含 $(grep -c 'BEGIN CERTIFICATE' "$CA" 2>/dev/null) 張;多站共用同一套推論時會串接多張)"
  else
    note "找不到 ca-cert.internal.pem(k8s_init.sh 註冊用);已註冊的憑證在叢集內,檔案不在不代表沒註冊"
  fi
  printf -- '_哪些 aetherSlide 站台連這台、GPU 由誰採購保固、模型更新誰做,設定看不出來,要人工填_\n'
fi

# ── 8. 另一個節點(dual;SSH 一次收齊兩台)──────────────────────────────
# 遠端跑的是同一份腳本(從 stdin 餵過去,不落地),並帶 --no-remote 避免互相遞迴。
PEER_TARGET="$PEER"
[ -n "$PEER_TARGET" ] || { [ "$ARCH" = "dual" ] && PEER_TARGET="$PEER_IP"; }

if [ "$DO_REMOTE" = "1" ] && [ -n "$PEER_TARGET" ]; then
  sec "8. 另一個節點(遠端採集:$PEER_TARGET)"
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
  sec "8. 另一個節點"
  if [ "$DO_REMOTE" = "0" ]; then
    note "--no-remote:只採本機,另一台請自行執行"
  else
    note "dual 架構但推不出對方 IP(.env 的 NODE_1_IP/NODE_2_IP 未填?),請用 --peer [user@]host 指定"
  fi
fi

[ "$CHILD" = "0" ] &&
  printf '\n---\n_採集完成。硬體序號/保固、對接整合、聯絡窗口等需人工填寫的欄位不在此輸出。_\n'
exit 0
