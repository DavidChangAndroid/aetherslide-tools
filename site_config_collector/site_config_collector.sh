#!/usr/bin/env bash
# collect_site_config.sh v1.10 — 唯讀採集客戶站台環境資訊,輸出 Markdown 供貼入 Obsidian
# site config 站頁(標「腳本」的欄位)。
#
# v1.10 相對 v1.9(ukt 實跑後的修正,只動 CPU steal 一處):
#   **VMware / Hyper-V 的 guest 量不到 CPU steal**。v1.9 在 ukt 兩台 vmware VM 上印 0.00%,
#   看起來像「hypervisor 沒超賣」,其實是那兩家 hypervisor 根本不透過 steal time 機制回報
#   CPU 競爭 —— 印一個看似正常的 0 比不印還糟。現在依 systemd-detect-virt 分流:
#   vmware / microsoft 直接標「量不到」並指到 vSphere 的 CPU Ready(%RDY);
#   kvm / xen / 雲端 VM 才照舊算 /proc/stat 的累積佔比。
#   ⚠ 版號 V1.10 > V1.9 —— `ls` 的字典序會排錯,但 publish.sh 用的是 `sort -V`(版本排序),
#     選版正確;說明文件的「目前最新」欄以人工標示為準。
#
# v1.9 相對 v1.8:補網路與儲存的「容量與健康」欄位,用途是評估**未來把 AI agent
#   接進 aetherSlide** 時,現有環境撐不撐得住(agent 若要讀影像,每片是 GB 級,
#   而 dual 站的資料全在 NFS 上 —— 同一張網卡收一次、送一次,是雙重計費)。
#   ① 第 1 段:介面明細(link speed / MTU / 驅動與型號 / 累積錯誤與丟包),
#      DOWN 的實體網卡也照列 —— 「有 10G 埠沒接線」是擴充頻寬最便宜的一條路。
#   ② 第 1 段:bonding / VLAN。
#   ③ 第 4 段:虛擬機的 CPU steal(自開機累積佔比,判斷 host 有沒有超賣)。
#   ④ 第 4 段:NFS 掛載的關鍵參數(vers / proto / rsize / wsize / hard-soft / timeo)。
#   ⑤ 第 4 段:NFS export(/etc/exports)—— 補齊 v1.8「這台把資料分享出去」只做了 samba
#      的另一半。實測 demo 機有 /proc/fs/nfsd 才發現這個缺口。
#   **刻意不採時點值**:即時流量水位、NFS RTT 這類上下班差很多的數字不進來
#   (要看那些請當場跑 sar / nfsiostat)。這裡只放「開機以來就固定,或累積型」的欄位。
#   ⚠ VM 的 link speed 是 guest 視角:vmxnet3 不管底下實體是什麼常常都報 10000Mb/s,
#     真正的上限在 ESXi host 的 uplink 與同 host 其他 VM 的競爭,腳本問不到,要問客戶。
#
# v1.8 相對 v1.7:補「這台把資料分享出去」這一類 —— 站台自建、不屬於 aetherSlide、
#   但正在服務 aetherSlide 資料的服務。起因是 ukt node-1 有客戶客製的 samba 分享
#   /data/export 給 Windows 取檔,v1.7 兩處都漏掉它:
#   ① 第 6 段 systemd 白名單只含 docker/compose/aetherslide/website/microk8s 等,
#      smbd 被濾掉 → 白名單加 smb/nmb/winbind/nfs-server。
#   ② v1.2 起不再列 listen port(當時嫌 NFS/RPC 動態高位 port 雜訊多),445 跟著消失
#      → 不恢復 port 掃描,改在第 4 段直接讀 /etc/samba/smb.conf 列出分享名與 path。
#
# v1.7 相對 v1.6 只改輸出的「順序與段名」,採集邏輯完全沒動:
#   段落順序改成與站頁一致(M-machine 各節 → GPU node → M-config 的對接),
#   段名改成站頁的小節名,貼的時候一段對一節,不用再自己找位置。
#   「對接與整合設定」從第 5 段移到第 8 段 —— 它讀的是 configs.env,屬 M-config 層,
#   不是機器現況,夾在機器段中間會讓人把它貼錯區塊。
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
#   分開時請「兩台各跑一次」;GPU 那台的輸出貼進站頁 M-machine 的「GPU node」段
#   (那台的 1–7 段都要,不是只有第 7 段:OS / 磁碟 / NFS / container 都在前面幾段)。
#   本腳本不會自動 SSH 到
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
      sed -n '2,66p' "${SELF:-$0}" 2>/dev/null | sed 's/^# \{0,1\}//'
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

# v1.7:AI_LANDING_URL 提早在這裡算。原本寫在「對接與整合設定」那段裡,
# 那段移到 AI Landing 之後,不提早算的話 AI Landing 段會讀不到、定位不了推論主機。
AIL_URL="$(envval "$DEPLOY_DIR/configs.env" AI_LANDING_URL)"
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
printf '> 唯讀採集。敏感值(帳密/私鑰)本腳本刻意不抓。\n'
printf '>\n'
printf '> **貼到哪**(段落順序已與站頁一致,由上而下對著貼):\n'
printf '>\n'
printf '> | 本檔區段 | 站頁區塊 |\n'
printf '> |---|---|\n'
printf '> | 0 節點識別 | 不直接貼,用來確認架構與本機是哪一台 |\n'
printf '> | 1–6 | `AUTO:M-machine` 的同名小節 |\n'
printf '> | 7 GPU node / AI Landing | `AUTO:M-machine` 末段「GPU node」 |\n'
printf '> | 8 對接與整合設定 | `AUTO:M-config` 的「對接(整合)」 |\n'
printf '> | 9 另一個節點 | 併進 M-machine 各表的 Node 2 欄 |\n'

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

# ── 1. 節點與網路 ──────────────────────────────
sec "1. 節點與網路"
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
# v1.9:同一份過濾結果先存起來,下面「介面明細」重用,不重跑一次過濾。
IFLIST=""
for _if in /sys/class/net/*; do
  _n="$(basename "$_if")"
  [ "$_n" = "lo" ] && continue
  case "$_n" in
    docker*|cni*|flannel*|kube-ipvs*|virbr*|mpqemubr*|lxdbr*|lxcbr*|podman*) continue ;;
  esac
  printf '%s' "$_n" | grep -qE '^br-[0-9a-f]{6,}$' && continue   # docker 自建 bridge
  if [ -e "$_if/device" ] ||
     { have ip && ip -4 -brief addr show "$_n" 2>/dev/null | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; }; then
    IFLIST="$IFLIST $_n"
  fi
done
printf '### 網路介面(已濾掉容器與虛擬網卡)\n```\n'
if have ip; then
  for _n in $IFLIST; do ip -brief addr show "$_n" 2>/dev/null; done
fi
printf '```\n'
# v1.9:介面明細。撈的是「開機以來就固定 or 累積型」的欄位,不撈即時流量
# (那種上下班差很多,採集當下的值沒有代表性)。用途:評估未來 AI agent 接進來時
# 頻寬夠不夠 —— dual 站資料全在 NFS,影像進到 image-server 走一次網路、
# 送給瀏覽器再走一次,同一張卡雙重計費。
# speed / MTU 都讀 sysfs 不用 ethtool:ethtool 讀 speed 要 CAP_NET_ADMIN,sysfs 不用。
# 型號用 lspci 補,只有驅動名(vmxnet3 / i40e)看不出是 1G 還是 25G 卡。
printf '### 介面明細(speed / MTU / 驅動 / 型號)\n'
printf -- '> `br0` / `bond0` 這類虛擬介面的 speed 是聚合出來的虛擬值(實測 demo 機 `br0` 報 10000Mb/s,\n'
printf -- '> 底下的實體卡其實只跑 1000Mb/s)。**要看實體那一列,不要看 bridge 那一列。**\n'
printf '```\n'
# 標題用英文:中文字在等寬字型佔兩格,printf 的 %-Ns 按字元數算會錯位
printf '%-14s %-6s %-10s %-6s %-12s %s\n' iface state speed MTU driver model
for _n in $IFLIST; do
  _state="$(cat "/sys/class/net/$_n/operstate" 2>/dev/null || echo '?')"
  _mtu="$(cat "/sys/class/net/$_n/mtu" 2>/dev/null || echo '-')"
  # DOWN 或虛擬介面讀 speed 會失敗或回 -1,這不是錯誤,照實標「-」
  _sp="$(cat "/sys/class/net/$_n/speed" 2>/dev/null)"
  case "$_sp" in ''|-1|*[!0-9-]*) _sp='-' ;; *) _sp="${_sp}Mb/s" ;; esac
  _drv="$(basename "$(readlink -f "/sys/class/net/$_n/device/driver" 2>/dev/null)" 2>/dev/null)"
  [ -n "$_drv" ] && [ "$_drv" != "." ] || _drv='-'
  _model='-'
  if have lspci; then
    _pci="$(basename "$(readlink -f "/sys/class/net/$_n/device" 2>/dev/null)" 2>/dev/null)"
    case "$_pci" in
      # lspci 的類別前綴("Ethernet controller: " / "Network controller: ")砍掉,只留廠牌型號
      *:*:*.*) _model="$(lspci -s "$_pci" 2>/dev/null | sed 's/^[^ ]* //; s/^[A-Za-z ]*controller: //' | head -1)" ;;
    esac
    [ -n "$_model" ] || _model='-'
  fi
  printf '%-14s %-6s %-10s %-6s %-12s %s\n' "$_n" "$_state" "$_sp" "$_mtu" "$_drv" "$_model"
done
printf '```\n'
# MTU 1500 vs 9000(jumbo frame)對 NFS 大檔讀取差很多,所以上面那張表要連 MTU 一起看。
# DOWN 的實體網卡不濾掉:「有第二張 10G/25G 埠沒接線」是擴充頻寬最便宜的一條路
# (ukt 的 GPU node 就有 6 張 DOWN 的實體網卡)。
printf '### 介面累積錯誤 / 丟包(自開機累積,非時點值)\n'
printf -- '> **`rx_drop` 在 bridge 與實體卡上常態就有數字**(收到不是給本機的封包也算),\n'
printf -- '> 實測 demo 機 `br0` 有 300 萬筆。**要看的是 `rx_err`/`tx_err`,那才代表線路或卡有問題。**\n'
IFERR=""
for _n in $IFLIST; do
  _s="/sys/class/net/$_n/statistics"
  _re="$(cat "$_s/rx_errors" 2>/dev/null || echo 0)"; _te="$(cat "$_s/tx_errors" 2>/dev/null || echo 0)"
  _rd="$(cat "$_s/rx_dropped" 2>/dev/null || echo 0)"; _td="$(cat "$_s/tx_dropped" 2>/dev/null || echo 0)"
  if [ "$_re$_te$_rd$_td" != "0000" ]; then
    IFERR="$IFERR$(printf '%-14s rx_err=%-8s tx_err=%-8s rx_drop=%-10s tx_drop=%s' "$_n" "$_re" "$_te" "$_rd" "$_td")
"
  fi
done
if [ -n "$IFERR" ]; then printf '```\n%s```\n' "$IFERR"; else printf -- '- 全部介面的 rx/tx errors 與 dropped 都是 0\n'; fi
# bonding / VLAN:有沒有做鏈路聚合直接決定頻寬上限是一張卡還是兩張卡
if [ -d /proc/net/bonding ] && ls /proc/net/bonding/* >/dev/null 2>&1; then
  printf '### bonding\n```\n'
  for _b in /proc/net/bonding/*; do
    printf '[%s]\n' "$(basename "$_b")"
    grep -E 'Bonding Mode|Slave Interface|MII Status|Speed|Aggregator ID' "$_b" 2>/dev/null
  done
  printf '```\n'
else
  printf -- '- **bonding**: 無(沒有 `/proc/net/bonding`,單卡)\n'
fi
if [ -s /proc/net/vlan/config ]; then
  printf '### VLAN\n```\n'; cat /proc/net/vlan/config 2>/dev/null; printf '```\n'
else
  printf -- '- **VLAN**: 無(guest 看不到 VLAN 標籤時這裡也會是「無」,交換器側要另外問)\n'
fi
printf '### DNS\n```\n'
grep -E '^nameserver' /etc/resolv.conf 2>/dev/null || note "讀不到 resolv.conf"
printf '```\n'
# v1.2 起不再列 listen port:實測抓到的幾乎都是 NFS/RPC 動態高位 port 與跳板服務,
# 對交接沒幫助,反而要人去分辨雜訊。對外開放哪些 port 以防火牆規則為準,人工填。

# ── 2. 憑證 ──
sec "2. 憑證(SSL)"
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

# ── 3. 硬體 ──────────────────────────────
sec "3. 硬體"
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

# ── 4. OS / Docker / 儲存 ──────────────────────────────
sec "4. OS / Docker / 儲存"
kv "OS" "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
kv "Kernel" "$(uname -r 2>/dev/null)"
VIRT=""
if have systemd-detect-virt; then VIRT="$(systemd-detect-virt 2>/dev/null)"; kv "虛擬化" "$VIRT"; fi
# CPU steal —— 只在 VM 上有意義(實體機恆為 0)。用 /proc/stat 的累積值算佔比,
# 不用 `vmstat 1 2` 的一秒取樣:那是時點值,上下班差很多。這裡是自開機以來的平均,
# 持續偏高代表 hypervisor 上被別的 VM 卡住 —— 加 vCPU 也救不了,要找客戶的虛擬化管理者。
#
# v1.10:**但這只在會回報 steal time 的 hypervisor 上成立**。VMware / Hyper-V 不透過
# steal time 機制暴露 CPU 競爭,guest 的 /proc/stat steal 幾乎恆為 0 —— v1.9 在 ukt 兩台
# vmware VM 上就印出 0.00%,看起來像「沒被超賣」,其實是「量不到」。**印一個看似正常的 0
# 比不印還糟**,所以這類 hypervisor 直接標明量不到,並指到該去看哪個指標。
if [ -n "$VIRT" ] && [ "$VIRT" != "none" ] && [ -r /proc/stat ]; then
  case "$VIRT" in
    vmware)
      kv "CPU steal" "**量不到(VMware)** —— VMware 不透過 steal time 回報 CPU 競爭,guest 讀到的一律接近 0。要判斷有沒有被超賣,看 vSphere 側的 **CPU Ready(%RDY)** 與 Co-Stop,**腳本問不到,要向客戶的虛擬化管理者要**" ;;
    microsoft)
      kv "CPU steal" "**量不到(Hyper-V)** —— 同 VMware,要看 hypervisor 側的 CPU wait time per dispatch" ;;
    *)
      # kvm / xen / 各家雲的 VM 都有 steal,這裡才有意義
      kv "CPU steal(自開機累積)" "$(awk '/^cpu /{t=0; for(i=2;i<=NF;i++) t+=$i; printf "%.2f%%", ($9/t)*100}' /proc/stat 2>/dev/null)($VIRT)" ;;
  esac
fi
if have docker; then kv "Docker" "$(docker --version 2>/dev/null)"; else note "無 docker"; fi
printf '### 區塊裝置 / 分割\n```\n'
# v1.6:-e 7 濾掉 loop 裝置(major 7)。microk8s 是 snap 裝的,AI Landing 主機上
# 實測有 29 個 squashfs loop,把真正的磁碟結構整個淹掉 —— 跟 veth 洪水同一類問題。
if have lsblk; then lsblk -e 7 -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null; else note "無 lsblk"; fi
printf '```\n### 磁碟使用 / mount\n```\n'
if have df; then df -hT 2>/dev/null | grep -vE 'tmpfs|overlay|squashfs'; fi
printf '```\n'
# v1.9:NFS 掛載的關鍵參數。上面的 df 只說「掛了誰、用了多少」,這裡說「怎麼掛的」。
# 對 AI agent 這種要讀整片 WSI(GB 級)的用法,rsize/wsize 與 vers 直接決定吞吐;
# hard vs soft 決定 NFS 卡住時是無限等待還是回錯(影響服務怎麼壞)。
# 來源主機不重複列(上面 df 有),只列掛載點與參數,表才不會爆寬。
printf '### NFS 掛載參數\n'
# 只認 client 掛載:fstype 精確比對 nfs / nfs4。`$3 ~ /^nfs/` 會把 /proc/fs/nfsd
# (NFS **server** 的控制用 filesystem)也算進來,實測 demo 機就中了這一槍。
NFSTBL="$(awk '$3 == "nfs" || $3 == "nfs4" {
    opts = $4
    v = "-"; pr = "-"; rs = "-"; ws = "-"; hs = "-"; to = "-"; rt = "-"; ac = "-"
    n = split(opts, a, ",")
    for (i = 1; i <= n; i++) {
      split(a[i], kv, "=")
      if (kv[1] == "vers" || kv[1] == "nfsvers") v = kv[2]
      else if (kv[1] == "proto") pr = kv[2]
      else if (kv[1] == "rsize") rs = kv[2]
      else if (kv[1] == "wsize") ws = kv[2]
      else if (kv[1] == "timeo") to = kv[2]
      else if (kv[1] == "retrans") rt = kv[2]
      else if (kv[1] == "actimeo") ac = kv[2]
      else if (a[i] == "hard" || a[i] == "soft") hs = a[i]
    }
    printf "%-26s %-5s %-5s %-9s %-9s %-5s %-6s %-8s %s\n", $2, v, pr, rs, ws, hs, to, rt, ac
  }' /proc/mounts 2>/dev/null)"
if [ -n "$NFSTBL" ]; then
  printf '```\n'
  printf '%-26s %-5s %-5s %-9s %-9s %-5s %-6s %-8s %s\n' mountpoint vers proto rsize wsize hard timeo retrans actimeo
  printf '%s\n' "$NFSTBL"
  printf '```\n'
else
  printf -- '- 無 NFS 掛載(資料在本機碟)\n'
fi
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
# v1.8:上面的 mount 是「這台掛了誰的資料」,這裡是反過來「這台把資料分享給誰」。
# samba 不屬於 aetherSlide 部署(compose 裡沒有 SMB server),有的話一定是站台自建或
# 客戶 IT 推的,所以只讀設定檔列出分享名與 path,不判斷用途。密碼類鍵不抓。
printf '### 本機分享出去的目錄(samba)\n'
SMBCONF=/etc/samba/smb.conf
if [ ! -f "$SMBCONF" ]; then
  printf -- '- 無 `%s`(本機沒裝 samba,或用其他方式分享)\n' "$SMBCONF"
elif [ ! -r "$SMBCONF" ]; then
  note "$SMBCONF 存在但讀不到(需要 root)"
else
  SMBSHARES="$(awk '
    function flush() {
      if (name != "" && tolower(name) != "global")
        printf "%-24s %s\n", name, (path == "" ? "(未設 path)" : path)
    }
    /^[ \t]*[;#]/ { next }
    /^[ \t]*\[/ {
      flush(); name = $0
      sub(/^[ \t]*\[/, "", name); sub(/\][ \t]*$/, "", name)
      path = ""; next
    }
    /^[ \t]*[Pp][Aa][Tt][Hh][ \t]*=/ {
      path = $0; sub(/^[ \t]*[Pp][Aa][Tt][Hh][ \t]*=[ \t]*/, "", path)
    }
    END { flush() }
  ' "$SMBCONF" 2>/dev/null)"
  if [ -n "$SMBSHARES" ]; then
    printf '```\n%s\n```\n' "$SMBSHARES"
    printf -- '- 分享定義的完整內容(`valid users` / `hosts allow` / 唯讀與否)在 `%s`,需要時人工看\n' "$SMBCONF"
  else
    printf -- '- `%s` 存在但沒有 `[global]` 以外的分享區段\n' "$SMBCONF"
  fi
fi
# v1.9:同一類的另一半 —— 這台當 NFS server 分享出去的目錄。實測 demo 機有 /proc/fs/nfsd
# (= 裝了 nfs-kernel-server)才發現 v1.8 只做了 samba 這一半。
# `exportfs -s` 要 root,所以讀設定檔:/etc/exports 加 /etc/exports.d/*.exports。
printf '### 本機分享出去的目錄(NFS export)\n'
EXPFILES=""
[ -f /etc/exports ] && EXPFILES="/etc/exports"
for _e in /etc/exports.d/*.exports; do [ -f "$_e" ] && EXPFILES="$EXPFILES $_e"; done
if [ -z "$EXPFILES" ]; then
  printf -- '- 無 `/etc/exports`(本機不是 NFS server)\n'
else
  EXPLINES=""
  for _e in $EXPFILES; do
    if [ -r "$_e" ]; then
      _l="$(grep -vE '^[[:space:]]*(#|$)' "$_e" 2>/dev/null)"
      [ -n "$_l" ] && EXPLINES="$EXPLINES$_l
"
    else
      note "$_e 存在但讀不到(需要 root)"
    fi
  done
  if [ -n "$EXPLINES" ]; then
    printf '```\n%s```\n' "$EXPLINES"
    printf -- '- 來源檔:`%s`。行格式是 `路徑 client(選項)`;`rw` / `no_root_squash` 這類授權細節照實列出,不解讀\n' "$EXPFILES"
    # 有 nfsd 在跑但 exports 是空的 = 裝了沒用,跟「沒裝」是兩件事
  else
    printf -- '- `%s` 存在但沒有有效的 export 行(只有註解或空行)\n' "$EXPFILES"
  fi
fi
if [ -d /proc/fs/nfsd ]; then
  printf -- '- **本機有 `/proc/fs/nfsd`**(裝了 `nfs-kernel-server`);它是否真的在服務要看上面的 export 清單\n'
fi

# ── 5. 執行中的 aetherSlide ──────────────────────────────
# v1.6:整節用 HAS_AS 包起來。AI 推論主機常常沒有 aetherSlide(GPU 分開裝),
# 舊版會照樣印出十幾個空欄位與「無執行中 container」,看起來像「裝了但全掛了」。
sec "5. 執行中的 aetherSlide"
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

# ── 6. 時間與排程 ──────────────────────────────
sec "6. 時間與排程"
if have timedatectl; then
  kv "時區 / NTP" "$(timedatectl 2>/dev/null | tr -s ' ' | grep -E 'Time zone|NTP' | paste -sd '; ' -)"
else
  kv "時間 / 時區" "$(date 2>/dev/null)"
fi
printf '### 使用者 crontab\n```\n'
crontab -l 2>/dev/null || printf '(無 crontab 或讀不到)\n'
printf '```\n'
if have systemctl; then
  # v1.8:白名單加 smb/nmb/winbind/nfs-server —— 這類不屬於 aetherSlide,但常常正在
  # 把 aetherSlide 的資料分享出去(ukt node-1 的 samba 就是這樣被漏掉的)。
  UNITS="$(systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null \
    | grep -iE 'docker|compose|aetherslide|website|microk8s|kubelet|containerd|smbd|nmbd|winbind|nfs-server' | awk '{print $1}')"
  printf '### 相關 systemd service\n'
  if [ -n "$UNITS" ]; then printf '```\n%s\n```\n' "$UNITS"; else printf -- '- 無(可能是人工 `bin/dc up` 起的)\n'; fi
  # 濾掉每台 Ubuntu 都有的 OS 預設 timer,只留這台自己加的
  TIMERS="$(systemctl list-timers --all --no-pager --no-legend 2>/dev/null \
    | grep -vE 'fwupd|man-db|logrotate|motd-news|dpkg-db-backup|systemd-tmpfiles|update-notifier|fstrim|sysstat|apt-daily|e2scrub|snapd|ua-timer|ubuntu-advantage|anacron|plocate|mlocate|apport')"
  printf '### systemd timer(已濾掉 OS 預設,只留這台自己加的)\n'
  if [ -n "$TIMERS" ]; then printf '```\n%s\n```\n' "$TIMERS"; else printf -- '- 無\n'; fi
fi

# ── 7. GPU node / AI Landing(AI 推論主機)──────────────────────────────
# v1.6 新增。AI Landing 是 microk8s + helm,不是 docker compose,所以整段是另一套指令。
# 跟 dual node 不同,這裡「不」自動 SSH 過去:dual 兩台是同一套部署、同一批人裝的,
# 節點間免密 SSH 還有機會;aetherSlide 與 GPU 主機常屬不同網段甚至不同單位,
# 自動連只會生一堆失敗訊息,不如明講「到那台再跑一次」。
sec "7. GPU node / AI Landing(AI 推論)"
if [ "$HAS_AIL" = "0" ]; then
  note "本機沒有 AI Landing(找不到部署目錄的 values.yaml,也沒有 $AIL_NS namespace)"
  if [ -n "${AIL_URL:-}" ]; then
    # 只比對 host 部分;URL 可能帶 port 或走 FQDN
    AIL_HOST="$(printf '%s' "$AIL_URL" | sed -E 's#^[a-zA-Z]+://##; s#[:/].*$##')"
    if has_ip "$AIL_HOST"; then
      kv "AI_LANDING_URL 指向" "$AIL_URL(是本機 IP,但本機偵測不到 AI Landing → 需人工確認)"
    else
      kv "AI_LANDING_URL 指向" "$AIL_URL(**不是本機**,AI 推論在另一台)"
      printf -- '- _請到那台主機再跑一次本腳本,把它的第 1–7 段貼進站頁 M-machine 的「GPU node」段:_\n'
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

# ── 8. 對接與整合設定(從 configs.env 讀,不含任何密碼類鍵)─────────────
# 這段屬 M-config 層(設定檔說了什麼),不是機器現況 —— 貼到站頁的「對接(整合)」。
sec "8. 對接與整合設定(→ 貼到 M-config 的「對接(整合)」)"
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
  # AI 推論的去向。註解掉時走程式預設(舊版預設是已廢棄的 http://dgx.aetherai.com),
  # 所以「configs.env 沒這行」不等於「沒有 AI 推論」,要標出來而不是留空。
  # (AIL_URL 在檔案上方就算好了,見 v1.7 註記)
  kv "AI_LANDING_URL(AI 推論端點)" "${AIL_URL:-(未設定 / 被註解 → 走程式預設值,需查該版預設)}"
  printf -- '_掃描機型號 / PACS-LIS-HIS 對接對象 / 對方 IP 與 port 仍需人工填(設定檔看不出來)_\n'
else
  note "讀不到 $DEPLOY_DIR/configs.env"
fi

# ── 9. 另一個節點(dual;SSH 一次收齊兩台)──────────────────────────────
# 遠端跑的是同一份腳本(從 stdin 餵過去,不落地),並帶 --no-remote 避免互相遞迴。
PEER_TARGET="$PEER"
[ -n "$PEER_TARGET" ] || { [ "$ARCH" = "dual" ] && PEER_TARGET="$PEER_IP"; }

if [ "$DO_REMOTE" = "1" ] && [ -n "$PEER_TARGET" ]; then
  sec "9. 另一個節點(遠端採集:$PEER_TARGET)"
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
  sec "9. 另一個節點"
  if [ "$DO_REMOTE" = "0" ]; then
    note "--no-remote:只採本機,另一台請自行執行"
  else
    note "dual 架構但推不出對方 IP(.env 的 NODE_1_IP/NODE_2_IP 未填?),請用 --peer [user@]host 指定"
  fi
fi

[ "$CHILD" = "0" ] &&
  printf '\n---\n_採集完成。硬體序號/保固、對接對方是誰、聯絡窗口等需人工填寫的欄位不在此輸出(屬站頁 H 層)。_\n'
exit 0
