#!/usr/bin/env bash
# collect_site_config.sh — 唯讀採集客戶站台環境資訊,輸出 Markdown 供貼入 Obsidian
# site config 模板(標「腳本」的欄位)。
#
# 安全性:全程唯讀,不安裝、不修改、不需 sudo。可直接在正式機執行。
# 用法:
#   在站台上執行:  bash collect_site_config.sh [部署目錄] [--peer [user@]host] [--no-remote]
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
while [ $# -gt 0 ]; do
  case "$1" in
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
printf '### 所有介面(參考,多網卡時用)\n```\n'
if have ip; then ip -brief addr 2>/dev/null; fi
printf '```\n### DNS\n```\n'
grep -E '^nameserver' /etc/resolv.conf 2>/dev/null || note "讀不到 resolv.conf"
printf '```\n'
# aetherSlide 是標準 HTTPS(80/443),不列完整 listen 清單;只挑「標準以外、綁在 0.0.0.0/:: 的對外 port」當例外提醒
sec "非標準對外 port(例外提醒)"
if have ss; then
  EXTRA="$(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -E '^(0\.0\.0\.0|\[::\]|\*):' | sed -E 's/.*:([0-9]+)$/\1/' | sort -un | grep -vE '^(22|80|443)$')"
  if [ -n "$EXTRA" ]; then printf '```\n%s\n```\n' "$EXTRA"; else printf -- '- 無(僅標準 22/80/443)\n'; fi
else
  note "無 ss"
fi

# ── SSL 憑證 ──
sec "SSL 憑證"
CERT="$DEPLOY_DIR/data/ssl/cert.pem"
if [ -f "$CERT" ] && have openssl; then
  kv "憑證檔" "$CERT"
  kv "Subject" "$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null | sed 's/^subject=//')"
  kv "SAN" "$(openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null | grep -v 'X509v3' | tr -s ' ')"
  kv "到期" "$(openssl x509 -in "$CERT" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
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
printf '### GPU\n```\n'
if have nvidia-smi; then
  nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader 2>/dev/null || nvidia-smi -L 2>/dev/null
else note "無 nvidia-smi"; fi
printf '```\n'
printf '_序號/保固/供應商需另查(dmidecode 需 sudo,本腳本不執行)_\n'

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
if have vgs; then
  printf '### LVM\n```\n'; vgs 2>/dev/null; lvs 2>/dev/null; printf '```\n'
fi

# ── 4. aetherSlide / AI app 部署 ──────────────────────────────
sec "4. aetherSlide / AI app 部署"
kv "部署目錄" "$DEPLOY_DIR"
if [ -d "$DEPLOY_DIR" ]; then
  printf '### 設定檔存在狀況\n'
  for f in configs.env prefs.env .env configs.yaml tier_configs.yaml model-config; do
    if [ -e "$DEPLOY_DIR/$f" ]; then kv "$f" "存在"; else kv "$f" "(無)"; fi
  done
  [ -d "$DEPLOY_DIR/secrets" ] && kv "secrets/" "存在(目錄)"
else
  note "部署目錄不存在:$DEPLOY_DIR"
fi
printf '### 執行中 container(名稱 / image / 狀態)\n```\n'
if have docker; then
  docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null || note "docker ps 失敗(權限?)"
else note "無 docker"; fi
printf '```\n'


# ── 5. 另一個節點(dual;SSH 一次收齊兩台)──────────────────────────────
# 遠端跑的是同一份腳本(從 stdin 餵過去,不落地),並帶 --no-remote 避免互相遞迴。
PEER_TARGET="$PEER"
[ -n "$PEER_TARGET" ] || { [ "$ARCH" = "dual" ] && PEER_TARGET="$PEER_IP"; }

if [ "$DO_REMOTE" = "1" ] && [ -n "$PEER_TARGET" ]; then
  sec "5. 另一個節點(遠端採集:$PEER_TARGET)"
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
  sec "5. 另一個節點"
  if [ "$DO_REMOTE" = "0" ]; then
    note "--no-remote:只採本機,另一台請自行執行"
  else
    note "dual 架構但推不出對方 IP(.env 的 NODE_1_IP/NODE_2_IP 未填?),請用 --peer [user@]host 指定"
  fi
fi

[ "$CHILD" = "0" ] &&
  printf '\n---\n_採集完成。硬體序號/保固、對接整合、聯絡窗口等需人工填寫的欄位不在此輸出。_\n'
exit 0
