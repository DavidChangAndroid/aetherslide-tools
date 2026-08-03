#!/usr/bin/env bash
# collect_site_config.sh v1.13 — 唯讀採集客戶站台環境資訊,輸出 Markdown 供貼入 site config 站頁。
#
# 常態用法(零參數):
#   bash collect.sh
# 報告直接印在螢幕上,**不落地檔案**;起訖標記走 stderr,自己從螢幕框起來複製。


set -u
SELF="${BASH_SOURCE[0]:-}"
# 第 9 段印指令時要用檔名(使用者貼進客戶機器時常改名成 collect.sh)
SCRIPT_NAME="$(basename -- "$SELF" 2>/dev/null)"
[ -n "$SCRIPT_NAME" ] || SCRIPT_NAME="collect.sh"
DEPLOY_DIR=""
PEER=""
AIL_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    # 舊文件的指令貼進來不能報錯,所以留成 no-op;印一行提示讓人知道不必再打。
    --with-sudo)
      printf '[collect_site_config] --with-sudo 自 v1.13 起已內建為預設,本旗標忽略。\n' >&2; shift ;;
    --no-remote)
      printf '[collect_site_config] --no-remote 自 v1.13 起已是預設行為(不自動連 peer),本旗標忽略。\n' >&2; shift ;;
    --ai-landing-dir)
      AIL_DIR="${2:-}"
      [ -n "$AIL_DIR" ] || { echo "--ai-landing-dir 需要目錄" >&2; exit 2; }
      shift 2 ;;
    --peer)
      PEER="${2:-}"
      [ -n "$PEER" ] || { echo "--peer 需要 [user@]host" >&2; exit 2; }
      shift 2 ;;
    -h|--help)
      printf '%s v1.13 — 唯讀採集客戶站台環境資訊,輸出 Markdown 供貼入 site config 站頁。\n\n' "$SCRIPT_NAME"
      printf '  bash %s [部署目錄]              預設 ~/website。報告印在螢幕上,不落地檔案\n' "$SCRIPT_NAME"
      printf '  bash %s --peer [user@]host      只印「把腳本丟到那台跑」的指令就結束,不採本機\n' "$SCRIPT_NAME"
      printf '  bash %s --ai-landing-dir 目錄   AI Landing 自動偵測不到時指定\n\n' "$SCRIPT_NAME"
      printf '  --with-sudo / --no-remote       v1.13 起無作用(留著讓舊文件的指令不報錯)\n\n'
      printf '會問一次 sudo 密碼(Enter 或 10 秒不輸入 = 跳過)。用法細節、設計理由、變更歷程:見「採集腳本說明」。\n'
      exit 0 ;;
    # 不認識的旗標一律報錯:舊版會被下面的 *) 當成「部署目錄」吃掉,打錯字不報錯。
    --*)
      printf '不認識的參數:%s\n參數表請看:bash %s -h\n' "$1" "$SCRIPT_NAME" >&2; exit 2 ;;
    # 明確給了就一定要存在:不然報告照跑、只是第 2/5/8 段空掉,像「這站沒東西」而不是參數打錯。
    # 不給時不檢查(GPU / 儲存主機本來就沒有 ~/website)。
    *)
      if [ ! -d "$1" ]; then
        printf '參數「%s」不是一個存在的目錄。\n' "$1" >&2
        case "$1" in
          *@*|[0-9]*.[0-9]*.[0-9]*.[0-9]*)
            printf '看起來像主機位址 —— 要採另一台請加 --peer:\n    bash %s --peer %s\n' "$SCRIPT_NAME" "$1" >&2 ;;
          *)
            printf '位置參數是 aetherSlide 的部署目錄(預設 ~/website);參數表看:bash %s -h\n' "$SCRIPT_NAME" >&2 ;;
        esac
        exit 2
      fi
      DEPLOY_DIR="$1"; shift ;;
  esac
done
[ -n "$DEPLOY_DIR" ] || DEPLOY_DIR="$HOME/website"

# --peer 是「產生指令」模式,不採本機就結束 —— 本機資訊直接跑無參數版本就有,
# 順便採一遍只是佔螢幕。輸出刻意只有四行(兩行註解 + ls + 那條指令)。
if [ -n "$PEER" ]; then
  printf '# 先確認這台有哪把金鑰(每站不一樣)\n'
  printf 'ls -1 ~/.ssh/id_*\n\n'
  printf '# 把 K= 換成上面查到的,整行貼上;-t 不能拿掉(沒有 pty 那台問不到 sudo 密碼)\n'
  printf 'K=~/.ssh/id_rsa; P=%s; ssh -i $K $P '\''cat > /tmp/c.sh'\'' < %s && ssh -i $K -t $P '\''bash /tmp/c.sh; rm -f /tmp/c.sh'\''\n' \
    "$PEER" "$SCRIPT_NAME"
  exit 0
fi

have() { command -v "$1" >/dev/null 2>&1; }
# ── sudo(v1.13 內建為預設)──────
# 提示在任何報告輸出之前問完(報告不落地,晚問會被往上洗掉),且一律走 stderr。
SUDO_OK=0      # 1=可用
SUDO_MODE=""   # n=走 sudo -n(timestamp 有效) / S=每次餵密碼 / ""=不可用
SUDO_PW=""     # 只有 SUDO_MODE=S 才會留值
SUDO_NOTE=""   # 給報告用的一句話:這次到底拿不拿得到 root、為什麼
sudo_init() {
  if ! have sudo; then SUDO_NOTE="本機沒有 sudo 指令"; return; fi
  if sudo -n true 2>/dev/null; then
    SUDO_OK=1; SUDO_MODE="n"; SUDO_NOTE="有免密 sudo(沒有問密碼)"; return
  fi
  # sudo 訊息受 locale 影響,中英文關鍵字都比對;比對不到保守當作「不准」,不白問。
  _why="$(sudo -n true 2>&1)"
  if ! printf '%s' "$_why" | grep -qiE 'password|密[碼码]'; then
    SUDO_NOTE="這個帳號不被允許 sudo($(printf '%s' "$_why" | head -1 | cut -c1-60)),需要 root 的欄位一律略過"
    return
  fi
  # ②③ 不能互動就不要問
  if [ ! -t 2 ] || [ -z "$SELF" ] || [ ! -r "$SELF" ]; then
    SUDO_NOTE="沒有免密 sudo,且無法互動輸入密碼(沒有 tty,或腳本是從 stdin 餵入)—— 需要 root 的欄位略過。要抓就把腳本落地到該機再跑:bash $SCRIPT_NAME"
    return
  fi
  printf '\n[collect_site_config] 需要 sudo 才讀得到:硬體序號 / 保固、RAID 陣列狀態、SMART 硬碟健康、LVM。\n' >&2
  printf '[collect_site_config] 全部是唯讀查詢,不改任何設定、不寫任何檔案。\n' >&2
  printf '[collect_site_config] 直接按 Enter(或 10 秒不輸入)= 跳過,其餘採集完全不受影響;密碼錯誤可再試兩次。\n' >&2
  _try=1
  while [ "$_try" -le 3 ]; do
    printf '[collect_site_config] sudo 密碼(第 %d/3 次,Enter 跳過): ' "$_try" >&2
    if ! IFS= read -r -s -t 10 _pw < /dev/tty 2>/dev/null; then
      printf '\n[collect_site_config] 逾時或輸入結束 —— 略過需要 root 的欄位。\n' >&2
      SUDO_NOTE="沒有免密 sudo,使用者未提供密碼(逾時或按 Ctrl-D)—— 需要 root 的欄位略過"
      return
    fi
    printf '\n' >&2
    if [ -z "$_pw" ]; then
      printf '[collect_site_config] 跳過需要 root 的欄位。\n' >&2
      SUDO_NOTE="沒有免密 sudo,使用者選擇跳過(未輸入密碼)—— 需要 root 的欄位略過"
      return
    fi
    if printf '%s\n' "$_pw" | sudo -S -p '' -v 2>/dev/null; then
      SUDO_OK=1
      # timestamp 到底有沒有生效?生效就把密碼丟掉,不生效才留著(見①)
      if sudo -n true 2>/dev/null; then
        SUDO_MODE="n"
        SUDO_NOTE="互動輸入密碼一次(sudo timestamp 有效,腳本未保留密碼)"
      else
        SUDO_MODE="S"; SUDO_PW="$_pw"
        SUDO_NOTE="互動輸入密碼一次;**本站 sudo 不快取 timestamp(timestamp_timeout=0)**,腳本執行期間全程持有密碼以免反覆詢問"
      fi
      unset _pw
      printf '[collect_site_config] sudo 可用,開始採集。\n' >&2
      return
    fi
    printf '[collect_site_config] 密碼錯誤。\n' >&2
    _try=$((_try + 1))
  done
  unset _pw
  SUDO_NOTE="沒有免密 sudo,密碼連續錯三次 —— 需要 root 的欄位略過"
  printf '[collect_site_config] 三次都不對,略過需要 root 的欄位。\n' >&2
}
sudo_ready() { [ "$SUDO_OK" = "1" ]; }
# 唯讀查詢統一入口。刻意不吞 stderr(SMART 段要靠 stderr 判斷「量不到」的原因)。
sq() {
  case "$SUDO_MODE" in
    n) sudo -n "$@" ;;
    S) printf '%s\n' "$SUDO_PW" | sudo -S -p '' "$@" ;;
    *) return 1 ;;
  esac
}
sec()  { printf '\n<!--SEC:%s-->\n## %s\n\n' "$1" "$2"; }
kv()   { printf -- '- **%s**: %s\n' "$1" "$2"; }
note() { printf -- '- _(略過:%s)_\n' "$1"; }
# 只取單一鍵的值,不 source 整個 env 檔
envval() {
  [ -f "$1" ] || return 0
  grep -E "^[[:space:]]*$2=" "$1" 2>/dev/null | tail -1 |
    sed -E "s/^[[:space:]]*$2=//" | tr -d "\"'" | tr -d '\r'
}
# values.yaml 逐鍵取值。$2 要含縮排錨點:同一個鍵名可能在不同層出現。
yamlval() {
  [ -f "$1" ] || return 0
  grep -E "$2" "$1" 2>/dev/null | head -1 |
    sed -E 's/^[^:]*:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^&[A-Za-z0-9_]+[[:space:]]*//' |
    tr -d "\"'" | tr -d '\r'
}

# sudo 一定要在任何 stdout 輸出之前問完(見 sudo_init 的註解)
sudo_init

# ── 0. 節點識別 ──────
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
  # 純 AI Landing 主機本來就沒有 configs.env,不能印成「aetherSlide 壞了」
  NODE_SELF="非 aetherSlide 主機"
fi

# ── AI Landing(AI 推論主機)偵測 ──────
# 「有 aetherSlide」與「有 AI Landing」是兩個獨立問題(GPU 常分開裝),各自判。
HAS_AS=0
{ [ -f "$DEPLOY_DIR/configs.env" ] || [ -f "$DEPLOY_DIR/.env" ]; } && HAS_AS=1
if [ -z "$AIL_DIR" ]; then
  for _d in "$HOME/ai-landing" "$HOME/AI-Landing" /opt/ai-landing /opt/AI-Landing; do
    [ -f "$_d/values.yaml" ] && { AIL_DIR="$_d"; break; }
  done
fi
# k8s 指令:microk8s 優先,退回原生 kubectl。判準是「真的問得到 namespace」而非 command -v。
KCTL=""
if have microk8s && microk8s kubectl get ns >/dev/null 2>&1; then KCTL="microk8s kubectl"
elif have kubectl && kubectl get ns >/dev/null 2>&1; then KCTL="kubectl"; fi
kctl() { [ -n "$KCTL" ] && $KCTL "$@" 2>/dev/null; }
HELM=""
if have microk8s && microk8s helm version >/dev/null 2>&1; then HELM="microk8s helm"
elif have helm; then HELM="helm"; fi

# AI_LANDING_URL 提早算:AI Landing 段在「對接」段之前,不提早算會讀不到、定位不了推論主機。
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

# 報告不落地靠螢幕複製,所以要起訖標記;走 stderr 才不會混進 stdout。
printf '\n===== 以下開始複製(到「以上結束複製」為止)=====\n\n' >&2

printf '<!--COLLECTOR:v1.14-->\n'
printf '# site config 採集結果 — %s(%s)\n' "$(hostname 2>/dev/null || echo unknown)" "$NODE_SELF"
printf '> 唯讀採集。敏感值(帳密/私鑰)本腳本刻意不抓。\n'
printf '> 採集權限:%s\n' "${SUDO_NOTE:-未判定}"
printf '>\n'
printf '> **貼到哪**(段落順序已與站頁一致,由上而下對著貼):\n'
printf '>\n'
printf '> | 本檔區段 | 站頁區塊 |\n'
printf '> |---|---|\n'
printf '> | 0 節點識別 | 不直接貼,用來確認架構與本機是哪一台 |\n'
printf '> | 1–6 | `AUTO:M-machine` 的同名小節 |\n'
printf '> | 7 GPU node / AI Landing | `AUTO:M-machine` 末段「GPU node」 |\n'
printf '> | 8 對接與整合設定 | `AUTO:M-config` 的「對接(整合)」 |\n'
printf '> | 9 另一個節點 | 不直接貼:只是提醒對方節點是誰,那台自己跑一次的輸出才併進各表的 Node 2 欄 |\n'

sec node.identity "0. 節點識別"
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

# ── 1. 節點與網路 ──────
sec net "1. 節點與網路"
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
# 兩層:① 留「有實體裝置或有 IPv4」的(不必知道名字就擋掉 veth / cali*;DOWN 的實體卡留著);
# ② 再擋有 IP 但屬容器 / 虛擬化橋接的。結果存起來給下面「介面明細」重用。
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
printf '<!--SEC:net.interfaces-->\n### 網路介面(已濾掉容器與虛擬網卡)\n```\n'
if have ip; then
  for _n in $IFLIST; do ip -brief addr show "$_n" 2>/dev/null; done
fi
printf '```\n'
# 只撈累積型欄位,不撈即時流量。speed / MTU 讀 sysfs(ethtool 要 CAP_NET_ADMIN),
# 型號用 lspci 補 —— 只有驅動名看不出是 1G 還是 25G 卡。
printf '<!--SEC:net.iface_detail-->\n### 介面明細(speed / MTU / 驅動 / 型號)\n'
printf -- '> `br0` / `bond0` 這類虛擬介面的 speed 是聚合出來的虛擬值(實測 demo 機 `br0` 報 10000Mb/s,\n'
printf -- '> 底下的實體卡其實只跑 1000Mb/s)。**要看實體那一列,不要看 bridge 那一列。**\n'
printf '```\n'
VIRTNIC_SEEN=0
EMULATED_NIC_SEEN=0
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
  # 虛擬網卡的 speed 是 hypervisor 給的固定值,與實體上限無關 → 加 * 標記(用驅動名判斷就夠)。
  # 用星號而不是「(虛擬值)」:中文佔兩格會破壞 printf 的欄位對齊。
  case "$_drv" in
    vmxnet3|virtio_net|e1000|e1000e|hv_netvsc|xen-netfront)
      VIRTNIC_SEEN=1
      [ "$_sp" = '-' ] || _sp="${_sp}*"
      case "$_drv" in e1000|e1000e) EMULATED_NIC_SEEN=1 ;; esac ;;
  esac
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
# v1.11:星號的說明只在真的有虛擬網卡時才印,實體機不用看這段。
if [ "$VIRTNIC_SEEN" = "1" ]; then
  printf -- '> `*` = **虛擬網卡驅動回報的值,不是實體上限**。vmxnet3 / virtio 幾乎一律報 10000Mb/s,\n'
  printf -- '> 與底下實體網卡是 1G 還是 25G 無關。真正的上限在 hypervisor:實體 uplink、vSwitch 的\n'
  printf -- '> teaming(**guest 看不到 host 這層的鏈路聚合**)、以及 port group 有沒有設 traffic shaping\n'
  printf -- '> (可以直接限速,guest 完全無感)。**這三件事只能向客戶的虛擬化管理者要。**\n'
  printf -- '> VM 上這張表真正有效的是 **MTU** 與下面的**累積錯誤**,speed 與型號只能拿來看「用的是哪種虛擬網卡」。\n'
fi
if [ "$EMULATED_NIC_SEEN" = "1" ]; then
  printf -- '> ⚠ 偵測到 **e1000 / e1000e** —— 那是**模擬**的 Intel 千兆卡,不是半虛擬化網卡\n'
  printf -- '> (vmxnet3 / virtio_net)。吞吐與 CPU 開銷都明顯較差,通常是建 VM 時範本沒改或沒裝 VMware Tools。\n'
fi
# MTU 1500 vs 9000 對 NFS 大檔差很多。DOWN 的實體網卡不濾掉:「有 10G 埠沒接線」是擴充頻寬最便宜的路。
printf '<!--SEC:net.iface_errors-->\n### 介面累積錯誤 / 丟包(自開機累積,非時點值)\n'
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
  printf '<!--SEC:net.bonding-->\n### bonding\n```\n'
  for _b in /proc/net/bonding/*; do
    printf '[%s]\n' "$(basename "$_b")"
    grep -E 'Bonding Mode|Slave Interface|MII Status|Speed|Aggregator ID' "$_b" 2>/dev/null
  done
  printf '```\n'
else
  printf -- '- **bonding**: 無(沒有 `/proc/net/bonding`,單卡)\n'
fi
if [ -s /proc/net/vlan/config ]; then
  printf '<!--SEC:net.vlan-->\n### VLAN\n```\n'; cat /proc/net/vlan/config 2>/dev/null; printf '```\n'
else
  printf -- '- **VLAN**: 無(guest 看不到 VLAN 標籤時這裡也會是「無」,交換器側要另外問)\n'
fi
printf '<!--SEC:net.dns-->\n### DNS\n```\n'
grep -E '^nameserver' /etc/resolv.conf 2>/dev/null || note "讀不到 resolv.conf"
printf '```\n'
# v1.2 起不列 listen port:抓到的幾乎都是 NFS/RPC 動態高位 port,是雜訊。對外 port 以防火牆為準。

# ── 2. 憑證 ──
sec cert "2. 憑證(SSL)"
CERT="$DEPLOY_DIR/data/ssl/cert.pem"
# 「檔案不存在」與「存在但讀不到」要講不同的話:cert 常是 0600 root:root,`[ -f ]` 過得了但
# openssl 讀不到 —— 舊版兩種都印「找不到」,權限問題會偽裝成「這站沒有憑證」。
CERT_READ=""   # direct=一般權限可讀 / sudo=要 root / 空=讀不到
if [ -f "$CERT" ] && have openssl; then
  if openssl x509 -in "$CERT" -noout -subject >/dev/null 2>&1; then
    CERT_READ="direct"
  elif sudo_ready && sq openssl x509 -in "$CERT" -noout -subject >/dev/null 2>&1; then
    CERT_READ="sudo"
  fi
fi
cert_x509() {
  if [ "$CERT_READ" = "sudo" ]; then sq openssl x509 -in "$CERT" -noout "$@" 2>/dev/null
  else openssl x509 -in "$CERT" -noout "$@" 2>/dev/null; fi
}
if [ -n "$CERT_READ" ]; then
  kv "憑證檔" "$CERT$([ "$CERT_READ" = "sudo" ] && printf '(檔案權限只有 root 可讀,用 sudo 讀取)')"
  kv "Subject" "$(cert_x509 -subject | sed 's/^subject=//')"
  kv "SAN" "$(cert_x509 -ext subjectAltName | grep -v 'X509v3' | tr -s ' ')"
  kv "到期" "$(cert_x509 -enddate | sed 's/^notAfter=//')"
elif [ -f "$CERT" ] && have openssl; then
  # 檔案在、openssl 也在,但讀不到 —— 這是權限,不是「沒有憑證」
  kv "憑證檔" "$CERT(**檔案存在但讀不到**)"
  printf -- '- _`openssl x509` 讀取失敗,幾乎一定是檔案權限(cert/key 常設成 `0600 root:root`)。**這不代表這站沒有憑證。**_\n'
  printf -- '- _本次 sudo 狀態:%s。要補這幾格就在該機用 root 執行(唯讀):_\n' "${SUDO_NOTE:-未判定}"
  printf '```\nsudo openssl x509 -in %s -noout -subject -ext subjectAltName -enddate\n```\n' "$CERT"
elif [ -f "$CERT" ]; then
  note "有 $CERT 但本機沒有 openssl 指令,憑證細節抓不到"
elif printf '%s' "$(envval "$DEPLOY_DIR/configs.env" MODULES)" | grep -q caddy ||
     { have docker && docker ps --format '{{.Names}}' 2>/dev/null | grep -q caddy; }; then
  # 啟用 caddy 的站台憑證由 caddy 自己申請與續約,不會放在 data/ssl
  kv "憑證管理方式" "caddy(ACME 自動申請 / 續約),不在 $DEPLOY_DIR/data/ssl"
  note "憑證細節要進 caddy 容器或看 caddy 資料目錄,本腳本不進容器"
else
  note "$CERT 不存在(檔案真的沒有,不是權限問題),也沒偵測到 caddy —— 非標準路徑請用部署目錄參數指定,或問客戶憑證放哪"
fi

# ── 3. 硬體 ──────
sec hw "3. 硬體"
if have lscpu; then
  kv "CPU 型號" "$(lscpu 2>/dev/null | grep -E 'Model name' | sed 's/.*: *//')"
  kv "CPU 核心(邏輯)" "$(nproc 2>/dev/null)"
else note "無 lscpu"; fi
if have free; then kv "RAM" "$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')"; fi
if have nvidia-smi; then
  kv "GPU driver / CUDA" "driver $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1) / $(nvidia-smi 2>/dev/null | sed -n 's/.*CUDA Version: *\([0-9.]*\).*/\1/p' | head -1)"
fi
printf '<!--SEC:hw.gpu-->\n### GPU\n```\n'
if have nvidia-smi; then
  nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader 2>/dev/null || nvidia-smi -L 2>/dev/null
else note "無 nvidia-smi"; fi
printf '```\n'
# 序號 / 保固靠 dmidecode(需 root)。序號是查保固的唯一線索,拿到權限就抓。
if ! have dmidecode; then
  printf -- '_序號 / 保固 / 供應商:本機沒有 `dmidecode` 指令,要看機器標籤或 BMC_\n'
elif sudo_ready; then
  SERIAL="$(sq dmidecode -s system-serial-number 2>/dev/null | grep -v '^#' | head -1)"
  PRODUCT="$(sq dmidecode -s system-product-name 2>/dev/null | grep -v '^#' | head -1)"
  VENDOR="$(sq dmidecode -s system-manufacturer 2>/dev/null | grep -v '^#' | head -1)"
  if [ -n "$SERIAL$PRODUCT$VENDOR" ]; then
    kv "廠牌 / 型號" "${VENDOR:-未知} / ${PRODUCT:-未知}"
    kv "系統序號" "${SERIAL:-未知}"
  else
    note "有 sudo 也有 dmidecode,但問不到序號(VM 常常如此:虛擬機沒有實體 DMI 資料)"
  fi
else
  printf -- '_序號 / 保固 / 供應商需另查(需 root:%s)_\n' "${SUDO_NOTE:-未判定}"
fi

# ── 4. OS / Docker / 儲存 ──────
sec os "4. OS / Docker / 儲存"
kv "OS" "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
kv "Kernel" "$(uname -r 2>/dev/null)"
VIRT=""
if have systemd-detect-virt; then VIRT="$(systemd-detect-virt 2>/dev/null)"; kv "虛擬化" "$VIRT"; fi
# **VMware / Hyper-V 不透過 steal time 暴露 CPU 競爭**,guest 恆為 0 ——
# 印一個看似正常的 0 比不印還糟,所以這兩家直接標「量不到」。
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
# 控制器偵測要提早在這裡算:「實體碟總覽」需要它判斷顆數可不可信。
HWCTL=""
have lspci && HWCTL="$(lspci 2>/dev/null | grep -iE 'RAID bus controller|Serial Attached SCSI controller|Mass storage controller|SATA controller|Non-Volatile memory controller')"
HW_CTL_RAID=0
printf '%s\n' "$HWCTL" | grep -qi 'RAID bus controller' && HW_CTL_RAID=1
IMSM_SEEN=0   # 下面 md 段偵測到 Intel RST 時設 1;硬體 RAID 段要用(md 段在它前面)
# 先回答「這台幾顆碟」。用 -P(key="value")而不是欄位對齊:MODEL 常含空白(PERC H730P Mini),
# 欄位切割會把它切成兩欄、序號跟著跑位。
printf '<!--SEC:hw.disks-->\n### 實體碟總覽\n'
DISKROWS=""
# 這兩個旗標會傳到下面的「硬體 RAID」段用:碟的型號本身就是「這台的碟是誰做出來的」的線索。
HW_RAID_HINT=0    # 型號看起來是 RAID 控制器做出來的 virtual disk
HW_VDISK_HINT=0   # 型號看起來是 hypervisor 給的虛擬碟
VDRAID=""         # 命中前者的裝置名(空白分隔)
VDVIRT=""         # 命中後者的裝置名
if have lsblk; then
  # VENDOR 一起抓:只看 MODEL 不夠 —— MegaRAID 的 VD 型號是 MRROMB,字面看不出跟 RAID 有關,
  # 但 VENDOR 會是 AVAGO / LSI / DELL。VENDOR 不進表,只用來判斷是不是 virtual disk。
  DISKRAW="$(lsblk -dn -P -e 7,11 -o NAME,SIZE,ROTA,TRAN,TYPE,VENDOR,MODEL,SERIAL 2>/dev/null | awk '
    function g(s, k,   r) {
      r = ""
      if (match(s, k "=\"[^\"]*\"")) { r = substr(s, RSTART, RLENGTH); sub(k "=\"", "", r); sub(/"$/, "", r) }
      return r
    }
    {
      # -d 也會列出 md / dm 這類組合裝置(TYPE=raid1 / lvm),那不是實體碟,不算進顆數
      if (g($0, "TYPE") != "disk") next
      name = g($0, "NAME"); size = g($0, "SIZE"); rota = g($0, "ROTA")
      tran = g($0, "TRAN"); vend = g($0, "VENDOR"); model = g($0, "MODEL"); ser = g($0, "SERIAL")
      kind = (rota == "1" ? "HDD" : (rota == "0" ? "SSD/NVMe" : "?"))
      if (kind == "HDD") hdd++; else if (kind == "SSD/NVMe") ssd++; else unk++
      n++
      # 廠牌+型號一起比對,並收集命中的裝置名 —— 警語要能指名是哪幾列。
      vm = vend " " model
      if (vm ~ /(PERC|MegaRAID|MRROMB|MR9|LSI|AVAGO|Broadcom|ServeRAID|Smart Array|Adaptec|LOGICAL VOLUME)/) vdr = vdr " " name
      if (vm ~ /(VMware|Virtual disk|Virtual HD|QEMU HARDDISK|VBOX|Msft)/) vdv = vdv " " name
      printf "%-12s %-8s %-9s %-6s %-30s %s\n", name, size, kind, \
             (tran == "" ? "-" : tran), (model == "" ? "-" : model), (ser == "" ? "-" : ser)
    }
    END {
      printf "@@COUNT %d %d %d %d\n", n, hdd+0, ssd+0, unk+0
      printf "@@VDRAID%s\n", vdr
      printf "@@VDVIRT%s\n", vdv
    }
  ')"
  DCOUNT="$(printf '%s\n' "$DISKRAW" | sed -n 's/^@@COUNT //p')"
  VDRAID="$(printf '%s\n' "$DISKRAW" | sed -n 's/^@@VDRAID *//p')"
  VDVIRT="$(printf '%s\n' "$DISKRAW" | sed -n 's/^@@VDVIRT *//p')"
  DISKROWS="$(printf '%s\n' "$DISKRAW" | grep -v '^@@')"
  kv "OS 看得到的碟" "$(printf '%s' "$DCOUNT" | awk '{print $1" 顆(HDD "$2" / SSD-NVMe "$3" / 未知 "$4")"}')"
  if [ -n "$DISKROWS" ]; then
    printf '```\n'
    # 表頭用 ASCII:中文佔兩格但 printf %-Ns 按字元數算,中文表頭會與資料列對不齊。
    printf '%-12s %-8s %-9s %-6s %-30s %s\n' NAME SIZE HDD/SSD BUS MODEL SERIAL
    printf '%s\n' "$DISKROWS"
    printf '```\n'
  fi
  # 硬體 RAID 站台的 OS 只看到 virtual disk,底下幾十顆碟 lsblk 看不到 —— 不標這個顆數是錯的。
  # 分「控制器做的」與「hypervisor 做的」兩種:要問的人不同(BMC / 廠商 CLI vs 虛擬化管理者)。
  [ -n "$VDRAID" ] && HW_RAID_HINT=1
  [ -n "$VDVIRT" ] && HW_VDISK_HINT=1
  # 型號比對抓不完虛擬碟(EBS / PersistentDisk / QEMU… 列不完),所以主判準改用
  # systemd-detect-virt:只要這台是 VM,上面的碟就一定不是實體碟。
  { [ -n "$VIRT" ] && [ "$VIRT" != "none" ]; } && HW_VDISK_HINT=1
  if [ -n "$VDRAID" ]; then
    printf -- '- **注意:上面的顆數不等於實體硬碟數**。`%s` 的廠牌 / 型號是 RAID 控制器做出來的 **virtual disk**(一列可能是一整櫃碟),**底下真正幾顆碟、哪一顆壞了 `lsblk` 一律看不到** —— 看下面「硬體 RAID(控制器)」段,或走 BMC。\n' "$VDRAID"
  elif [ "$HW_CTL_RAID" = "1" ]; then
    # 型號沒露餡但機器上確實有 RAID 卡:講可能性,不要講成事實
    printf -- '- **注意:這台有 RAID 控制器**(見下方「硬體 RAID(控制器)」)。若其中某一列其實是控制器做出來的 virtual disk,**上面的顆數就不是實體硬碟數** —— 拿廠商 CLI 的 VD 容量對照上表就知道是哪一列。\n'
  fi
  if [ "$HW_VDISK_HINT" = "1" ]; then
    # 指名道姓優先(型號有露餡就列裝置名),否則就說「上面所有的碟」
    _vdwho="$([ -n "$VDVIRT" ] && printf '`%s`' "$VDVIRT" || printf '上面所有的碟')"
    case "$VIRT" in
      amazon|gce|azure|oracle|alibaba)
        # 雲端跟地端 hypervisor 要問的人不同,而且雲端**沒有 BMC 可看**,不能照抄同一句話
        printf -- '- **注意:這是雲端 VM(`%s`),%s 不是實體碟**,是雲端的網路 block storage(EBS / PD 這類)。顆數等於掛了幾個 volume,**跟底層有幾顆實體碟無關**;容量與 IOPS 由 volume 規格決定,要看雲端 console。**實體碟是雲端業者的,沒有 BMC 可查,SMART 也沒有意義。**\n' "$VIRT" "$_vdwho" ;;
      *)
        printf -- '- **注意:%s 是 hypervisor(`%s`)給的虛擬碟**,顆數與容量都是 guest 視角。底下實際是幾顆碟、有沒有做 RAID、放在哪個 datastore / LUN,**guest 完全看不到,也不在這台的 BMC 上** —— 只能問客戶的虛擬化管理者。\n' "$_vdwho" "${VIRT:-未知}" ;;
    esac
  fi
  printf -- '- _SERIAL 空白 = udev 沒提供(virtual disk、部分 RAID 後端與 VM 常見),不是抓失敗_\n'
else
  note "無 lsblk,碟數與型號要人工查"
fi
printf '<!--SEC:storage.blockdev-->\n### 區塊裝置 / 分割\n```\n'
# -e 7 濾掉 loop 裝置(snap 裝的 microk8s 實測 29 個 squashfs,會淹掉磁碟結構)。
# 結尾 `| cat`:lsblk 依終端機寬度會截斷最後一欄,stdout 是 pipe 時才不截斷。
if have lsblk; then lsblk -e 7 -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null | cat; else note "無 lsblk"; fi
printf '```\n<!--SEC:storage.mount-->\n### 磁碟使用 / mount\n```\n'
if have df; then df -hT 2>/dev/null | grep -vE 'tmpfs|overlay|squashfs'; fi
printf '```\n'
# `df` 有但 `lsblk` 沒有的碟:裝置已不在 /sys/block(拔掉 / 掉出控制器 / 熱插拔沒重掛)但掛載還在。
# **這種碟不算在「實體碟總覽」的顆數裡**,不標的話那個顆數會被當成完整清單。
if have lsblk && [ -r /proc/mounts ]; then
  LSBLK_ALL="$(lsblk -alno NAME 2>/dev/null | tr -d ' ' | sort -u)"
  GHOSTDEV=""
  for _md in $(awk '$1 ~ /^\/dev\// {print $1}' /proc/mounts 2>/dev/null | sort -u); do
    _b="${_md#/dev/}"
    # 只比對得了「單純的裝置名」;以下三類在 lsblk 是另一個名字,比對會產生假警報(假的
    # 「碟掉了」比不報還糟):① dm/mapper;② 帶 `/` 的路徑(by-uuid symlink);③ /dev/root。
    case "$_b" in */*|dm-*|root) continue ;; esac
    printf '%s\n' "$LSBLK_ALL" | grep -qx "$_b" || GHOSTDEV="$GHOSTDEV $_b"
  done
  # 前導空白要砍:GHOSTDEV 是用空白累加的,直接塞進反引號會印成 `` ` sde6` ``(實測 ukt 就這樣)
  GHOSTDEV="${GHOSTDEV# }"
  if [ -n "$GHOSTDEV" ]; then
    printf -- '- **注意:有掛載中的裝置不在 `lsblk` 清單裡** —— `%s`。代表裝置已經不在 `/sys/block`(碟被拔掉、從控制器上掉了、或熱插拔後沒重掛),但掛載還在,所以 `df` 照樣有數字。**這種碟不算在上面的顆數裡,而且上面的容量數字未必還可信。** 照實記錄、不要自己判斷用途(站頁模板 C4 收這一類)。\n' "$GHOSTDEV"
  fi
fi
# NFS 掛載參數:df 說「掛了誰、用多少」,這裡說「怎麼掛的」。rsize/wsize 與 vers 決定大檔吞吐,
# hard vs soft 決定 NFS 卡住時是無限等待還是回錯。來源主機不重複列(上面 df 有)。
printf '<!--SEC:storage.nfs_opts-->\n### NFS 掛載參數\n'
# 只認 client 掛載:fstype 精確比對 nfs / nfs4(`^nfs` 會把 server 側的 /proc/fs/nfsd 也算進來)。
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
# 一律印結論:舊版沒有 md 就整段不印,讀者分不出「沒有軟 RAID」與「腳本沒查」。
# 而且只貼 mdstat 原文不夠:degraded 在 `[U_]` 那兩個字元,會被滑過去。
printf '<!--SEC:hw.raid_md-->\n### 軟體 RAID(md)\n'
if [ ! -r /proc/mdstat ]; then
  printf -- '- 讀不到 `/proc/mdstat`(kernel 沒有 md 模組)\n'
elif ! grep -q '^md' /proc/mdstat 2>/dev/null; then
  printf -- '- **無 active md array** —— 這台沒有 Linux 軟體 RAID。碟若有做 RAID,是在控制器層或 hypervisor 做的(見下方「硬體 RAID(控制器)」)\n'
else
  MDSTAT="$(cat /proc/mdstat 2>/dev/null)"
  MDBAD=""
  # 狀態列 [UU] 全 U = 成員都在線;出現 _ 就是缺成員
  printf '%s\n' "$MDSTAT" | grep -qE '\[[U_]*_[U_]*\]' && MDBAD="degraded(狀態列出現 \`_\`,有成員不在線)"
  printf '%s\n' "$MDSTAT" | grep -q '(F)' && MDBAD="${MDBAD:+$MDBAD;}有成員被標記 faulty \`(F)\`"
  printf '%s\n' "$MDSTAT" | grep -qE 'recovery|resync|reshape' && MDBAD="${MDBAD:+$MDBAD;}正在重建 / 同步中"
  if [ -n "$MDBAD" ]; then
    kv "md 陣列健康" "**異常 — $MDBAD**"
  else
    kv "md 陣列健康" "成員全部在線(狀態列無 \`_\`)。**這不代表碟是健康的** —— 硬碟壽命看下方 SMART"
  fi
  printf '```\n%s\n```\n' "$MDSTAT"
  # Intel RST(主機板 fakeRAID)的 mdstat 會有一行 `inactive … super external:imsm` ——
  # 那是 metadata container,**顯示 inactive 是正常的**,不解釋會被當成故障。
  if printf '%s\n' "$MDSTAT" | grep -q 'external:imsm'; then
    IMSM_SEEN=1
    printf -- '- _`external:imsm` = **Intel RST(主機板 fakeRAID)**,不是 Linux 原生 md 也不是硬體 RAID 卡:陣列由主機板 BIOS 定義、由 kernel 的 md 驅動實際運作。其中 `inactive … (S)` 那一行是 **metadata container,顯示 inactive 是正常的**,真正的陣列是它上面那個 `active` 的 md。要換碟或看細節走 BIOS 的 Intel RST 設定畫面_\n'
  fi
  if have mdadm && sudo_ready; then
    for _md in /dev/md*; do
      [ -b "$_md" ] || continue
      _det="$(sq mdadm --detail "$_md" 2>/dev/null |
              grep -E 'Raid Level|Array Size|Raid Devices|Total Devices|State :|Active Devices|Working Devices|Failed Devices|Spare Devices|Rebuild Status|Consistency Policy')"
      [ -n "$_det" ] && printf -- '- **%s**(`mdadm --detail`)\n```\n%s\n```\n' "$_md" "$_det"
    done
  elif ! have mdadm; then
    note "有 md array 但沒有 mdadm 指令,成員碟明細抓不到"
  else
    printf -- '- _RAID level / 幾顆 / 哪一顆掉 / 重建進度要 `mdadm --detail`(需 root:%s)_\n' "${SUDO_NOTE:-未判定}"
  fi
fi
# LVM:vgs/lvs 非 root 會把警告丟 stderr、stdout 留空,看起來像「沒有 LVM」→ 要分辨沒權限。
# lvs 加 segtype:LVM 自己也能做 RAID,預設欄位看不出 linear 與 raid1 的差別。
if have vgs; then
  LVM_OUT="$(vgs 2>/dev/null; lvs -o +segtype 2>/dev/null)"
  if [ -z "$LVM_OUT" ] && sudo_ready; then
    LVM_OUT="$(sq vgs 2>/dev/null; sq lvs -o +segtype 2>/dev/null)"
  fi
  printf '<!--SEC:storage.lvm-->\n### LVM\n'
  if [ -n "$LVM_OUT" ]; then
    printf '```\n%s\n```\n' "$LVM_OUT"
  elif lsblk -o FSTYPE 2>/dev/null | grep -q LVM2_member; then
    note "偵測到 LVM2_member 分割,但 vgs/lvs 需要 root 才讀得到($SUDO_NOTE)"
  else
    printf -- '- 無 LVM\n'
  fi
fi
# ZFS / btrfs:軟體 RAID 的另外兩種,只查 mdstat 會漏掉整片陣列。沿用 LVM 那套權限判斷。
printf '<!--SEC:storage.zfs-->\n### ZFS\n'
if ! have zpool; then
  printf -- '- 無 ZFS(沒有 `zpool` 指令)\n'
else
  ZP="$(zpool list 2>/dev/null)"
  { [ -z "$ZP" ] && sudo_ready; } && ZP="$(sq zpool list 2>/dev/null)"
  if [ -z "$ZP" ]; then
    printf -- '- 裝了 ZFS 但沒有 pool(或 `zpool` 需要 root:%s)\n' "${SUDO_NOTE:-未判定}"
  else
    printf '```\n%s\n```\n' "$ZP"
    # `zpool status -x` 是一行式健康判定(全好只印 all pools are healthy),比整份 status 適合紀錄。
    ZS="$(zpool status -x 2>/dev/null)"
    { [ -z "$ZS" ] && sudo_ready; } && ZS="$(sq zpool status -x 2>/dev/null)"
    [ -n "$ZS" ] && printf -- '- **pool 健康**(`zpool status -x`)\n```\n%s\n```\n' "$ZS"
  fi
fi
# btrfs 只在真的有 btrfs 檔案系統時才查,避免在每台機器上多印一段無關的「無」
if lsblk -o FSTYPE 2>/dev/null | grep -q btrfs; then
  printf '<!--SEC:storage.btrfs-->\n### btrfs(偵測到 btrfs 檔案系統)\n'
  if ! have btrfs; then
    note "有 btrfs 分割但沒有 btrfs 指令,RAID profile 抓不到"
  else
    BT="$(btrfs filesystem show 2>/dev/null)"
    { [ -z "$BT" ] && sudo_ready; } && BT="$(sq btrfs filesystem show 2>/dev/null)"
    if [ -n "$BT" ]; then
      printf '```\n%s\n```\n' "$BT"
      printf -- '- _RAID profile(single / raid1 / raid10)要 `btrfs filesystem df <掛載點>` 逐個掛載點看,本腳本不逐點掃_\n'
    else
      note "btrfs filesystem show 需要 root($SUDO_NOTE)"
    fi
  fi
fi
# 硬體 RAID 分兩層:① 控制器型號(lspci,非 root 可讀);② 陣列狀態(只有廠商 CLI 問得到,需 root)。
# 兩層都拿不到時要明講量不到,不能讓「md 成員全部在線」被讀成「陣列沒問題」。
printf '<!--SEC:hw.raid_ctrl-->\n### 硬體 RAID(控制器)\n'
# HWCTL / HW_CTL_RAID 在「實體碟總覽」之前就算好了(見那裡的註解),這裡只負責印
if ! have lspci; then
  note "無 lspci,控制器型號要人工查(BMC 或機器標籤)"
elif [ -n "$HWCTL" ]; then
  printf '```\n%s\n```\n' "$HWCTL"
  printf -- '- _`RAID bus controller` = 硬體 RAID 卡或主機板 RAID 模式;`Serial Attached SCSI controller` 多半是純 HBA(不做 RAID,RAID 在 OS 層);`SATA controller` / `Non-Volatile memory controller` = 主機板內建,碟是直連_\n'
  # 只有「控制器層 + 主機板 fakeRAID」真的並存時才印這句,否則會指向不存在的東西。
  [ "$IMSM_SEEN" = "1" ] && [ "$HW_CTL_RAID" = "1" ] &&
    printf -- '- _這台兩種並存:系統碟走主機板 RAID(見上方 md 段的 `external:imsm`),資料碟走 RAID 卡_\n'
else
  printf -- '- `lspci` 看不到儲存控制器(VM 的虛擬碟常是這樣)\n'
fi
# 廠商 CLI:這類工具幾乎都不在 PATH(裝在 /opt 底下),所以 PATH 與 /opt 常見路徑都要找
RCLI=""
for _c in storcli64 storcli perccli64 perccli ssacli hpssacli hpacucli arcconf sas3ircu sas2ircu tw_cli MegaCli64 MegaCli megacli; do
  if have "$_c"; then RCLI="$_c"; break; fi
  for _p in /opt/MegaRAID/storcli /opt/MegaRAID/perccli /opt/MegaRAID/MegaCli /opt/MegaRAID/CmdTool2 \
            /opt/lsi/storcli /opt/dell/srvadmin/bin /usr/local/sbin /usr/local/bin /opt/hp/hpssacli/bin; do
    [ -x "$_p/$_c" ] && { RCLI="$_p/$_c"; break; }
  done
  [ -n "$RCLI" ] && break
done
if [ -z "$RCLI" ]; then
  # **沒有陣列就不要說量不到**(無中生有的缺口比漏報還糟)。三句話:有卡沒 CLI → BMC;
  # 虛擬碟 → 問虛擬化管理者;兩者皆無 → 沒有控制器層的陣列要查。
  if [ "$HW_RAID_HINT" = "1" ] || [ "$HW_CTL_RAID" = "1" ]; then
    printf -- '- **有 RAID 控制器但沒有廠商 CLI**(找過 storcli / perccli / MegaCli / ssacli / arcconf / sas3ircu / tw_cli,PATH 與 /opt 常見路徑都沒有)\n'
    printf -- '- **所以陣列健康、有沒有 degraded、是哪一顆壞、底下幾顆碟,這台量不到** —— 這些都在控制器層,`lsblk` / `mdstat` / `df` 一律看不到。要走 **BMC(iDRAC / iLO / IPMI web)**,或請客戶裝廠商 CLI 後重跑。\n'
  elif [ "$HW_VDISK_HINT" = "1" ]; then
    printf -- '- 沒有廠商 CLI,**這台也不需要** —— 碟是 hypervisor 給的虛擬碟,底層 RAID 在客戶的虛擬化平台 / 儲存設備上,要問虛擬化管理者(見上方「實體碟總覽」的註記)\n'
  else
    printf -- '- **未偵測到 RAID 控制器**(碟是主機板 SATA / NVMe 直連),也沒有廠商 CLI —— **沒有控制器層的陣列要查**。這台的 RAID 若存在只會在 OS 層(見上方 md / ZFS / LVM 三段),碟本身的健康看下方 SMART。\n'
  fi
else
  kv "廠商 CLI" "\`$RCLI\`"
  # 一律只用 show / display / info / GETCONFIG 這類「讀」的子指令,不下 set / start / rebuild。
  case "$(basename "$RCLI")" in
    storcli*|perccli*)  RCLI_CMD="$RCLI /c0 show" ;;             # 一頁含 controller + VD + PD 狀態
    MegaCli*|megacli)   RCLI_CMD="$RCLI -LDInfo -Lall -aALL" ;;  # PD 明細另有 -PDList,太長不自動跑
    ssacli|hpssacli|hpacucli) RCLI_CMD="$RCLI ctrl all show config" ;;
    arcconf)            RCLI_CMD="$RCLI GETCONFIG 1 LD" ;;
    sas3ircu|sas2ircu)  RCLI_CMD="$RCLI 0 DISPLAY" ;;
    tw_cli)             RCLI_CMD="$RCLI info" ;;
    *)                  RCLI_CMD="" ;;
  esac
  if [ -z "$RCLI_CMD" ]; then
    note "認得這支 CLI 但沒有對應的唯讀查詢指令,請人工執行"
  elif sudo_ready; then
    # shellcheck disable=SC2086
    RCLI_OUT="$(sq $RCLI_CMD 2>/dev/null)"
    if [ -n "$RCLI_OUT" ]; then
      printf -- '- 唯讀查詢:`%s`\n' "$RCLI_CMD"
      # `storcli /c0 show` 約 175 行、最有價值的 PD LIST 在後段(舊版 head -150 正好切掉)。
      # 先解析摘要(對應站頁模板 C2:陣列 / level / 成員碟 / 狀態)再貼原文;只解析 storcli / perccli。
      case "$(basename "$RCLI")" in
        storcli*|perccli*)
          printf '%s\n' "$RCLI_OUT" | awk '
            /^Product Name/     { sub(/^[^=]*= */, ""); prod = $0 }
            /^FW Package Build/ { sub(/^[^=]*= */, ""); fw = $0 }
            /^Virtual Drives/   { sub(/^[^=]*= */, ""); nvd = $0 }
            /^Physical Drives/  { sub(/^[^=]*= */, ""); npd = $0 }
            # VD LIST 資料列:`0/0   RAID6 Optl  RW  Yes  RWTD  -  ON  229.188 TB`
            /^[0-9]+\/[0-9]+[ \t]/ {
              vd = vd sprintf("%s %s **%s** %s %s;  ", $1, $2, $3, $9, $10)
              if ($3 != "Optl") badvd = badvd " " $1 "(" $3 ")"
            }
            # PD LIST 資料列:`8:0  55 Onln  0 16.370 TB SAS HDD N N 512B ST18000NM004J U -`
            /^[0-9]+:[0-9]+[ \t]/ {
              pn++; st[$3]++
              if (model == "") { model = $12; psz = $5 " " $6; intf = $7 " " $8 }
              # Onln=在陣列中、GHS/DHS=熱備、UGood=未配置但健康;其餘(Failed/Offln/UBad/Msng/Rbld)都要點名
              if ($3 != "Onln" && $3 != "GHS" && $3 != "DHS" && $3 != "UGood") badpd = badpd " " $1 "(" $3 ")"
            }
            END {
              if (prod != "") printf "- **控制器**: %s(FW %s)\n", prod, fw
              if (vd != "") { sub(/;  $/, "", vd); printf "- **陣列(VD)**: %s 個 —— %s\n", nvd, vd }
              if (pn > 0) {
                s = ""
                for (k in st) s = s sprintf("%s %d / ", k, st[k])
                sub(/ \/ $/, "", s)
                printf "- **控制器後面的實體碟**: **%s 顆**(%s)—— %s %s %s\n", (npd == "" ? pn : npd), s, model, psz, intf
                # 表頭顆數與表列行數不一致 = 輸出被截或版面不同,要讓人知道別採信其中一個
                if (npd != "" && npd + 0 != pn)
                  printf "- _表頭寫 %s 顆但表列只有 %d 行,不一致 —— 請人工執行上面那條指令確認_\n", npd, pn
              }
              if (badvd != "" || badpd != "")
                printf "- **異常:%s%s** —— 這是要立刻處理的\n", (badvd == "" ? "" : " VD" badvd), (badpd == "" ? "" : " PD" badpd)
              else if (vd != "" || pn > 0)
                printf "- **異常**: 無(所有 VD 為 Optl,所有 PD 為 Onln 或熱備)\n"
            }
          '
          printf -- '- _`OS 看得到的碟` 那格是 virtual disk 數,**這裡的顆數才是實體硬碟數**_\n' ;;
      esac
      # 原文照貼,但砍掉 legend 區塊(`DG=Disk Group Index|Arr=...` 這類說明佔了快 40 行)
      RCLI_BODY="$(printf '%s\n' "$RCLI_OUT" |
        grep -vE '^[A-Za-z][A-Za-z0-9 ]*=.*\|' | grep -v '^Check Consistency$' |
        grep -v 'Generating detailed summary' | cat -s)"
      printf '```\n%s\n```\n' "$(printf '%s\n' "$RCLI_BODY" | head -200)"
      # 有截斷就要說(不然讀者會以為這就是全部)
      [ "$(printf '%s\n' "$RCLI_BODY" | wc -l | tr -d ' ')" -gt 200 ] &&
        printf -- '- _(原文過長,只留前 200 行;完整內容請在站台自行執行上面那條指令。已砍掉 legend 說明區塊)_\n'
      printf -- '- _State 對照:VD `Optl`=正常 / `Dgrd`=缺碟 / `Pdgd`=部分降級;PD `Onln`=在陣列中 / `GHS`=全域熱備 / `UGood`=未配置 / `Failed`·`Offln`·`Msng`=要換 / `Rbld`=重建中_\n'
    else
      note "$RCLI 執行不到內容(可能不是這張卡的工具、或這台沒有 RAID 控制器)"
    fi
  else
    # sudo 已內建,「沒查到」只剩一個原因 —— 這次拿不到 root,把原因直接印出來。
    printf -- '- _**有 CLI 但這次拿不到 root,所以陣列狀態沒查**。原因:%s。請在該機人工執行(唯讀):_\n' "${SUDO_NOTE:-未判定}"
    printf '```\nsudo %s\n```\n' "$RCLI_CMD"
  fi
fi
# SMART 刻意只取整體判定:通電時數 / 重配置磁區 / 壽命% 屬監控指標,每顆碟一份也會淹掉報告。
printf '<!--SEC:hw.smart-->\n### 硬碟健康(SMART,只取整體判定)\n'
# VM 上這段不適用:虛擬碟沒有實體 SMART。而且**雲端沒有 BMC**,不能照抄「走 BMC」那句。
IS_VM=0
{ [ -n "$VIRT" ] && [ "$VIRT" != "none" ]; } && IS_VM=1
if [ "$IS_VM" = "1" ]; then
  case "$VIRT" in
    amazon|gce|azure|oracle|alibaba)
      printf -- '- **不適用**:這是雲端 VM(`%s`),碟是雲端的網路 block storage,**沒有實體碟的 SMART 可讀,也沒有 BMC**。底層硬碟由雲端業者負責,壞碟由他們換,我們看不到也不必看。\n' "$VIRT" ;;
    *)
      printf -- '- **不適用**:這是虛擬機(`%s`),碟是 hypervisor 給的虛擬碟,**guest 讀不到實體碟的 SMART**(即使裝了 smartmontools,讀到的也不是實體碟的健康)。實體碟健康要在 hypervisor / 儲存設備那一側看,要問客戶的虛擬化管理者。\n' "$VIRT" ;;
  esac
elif ! have smartctl; then
  printf -- '- 無 `smartctl`(smartmontools 未安裝),**硬碟健康這台量不到**;要看就走 BMC 或請客戶裝 smartmontools\n'
  # 碟在 RAID 控制器後面時,smartctl 本來也要靠 -d megaraid,N 才問得到,所以廠商 CLI 是更直接的路
  [ "$HW_RAID_HINT" = "1" ] || [ "$HW_CTL_RAID" = "1" ] &&
    printf -- '- _這台的碟在 RAID 控制器後面,即使裝了 smartmontools 也要走 `-d megaraid,N`;**用上面的廠商 CLI 看 PD 狀態更直接**_\n'
elif ! sudo_ready; then
  printf -- '- 有 `smartctl`,但 SMART 需要 root,**這次拿不到所以略過**。原因:%s\n' "${SUDO_NOTE:-未判定}"
  printf -- '- _若原因是「腳本從 stdin 餵入」(`bash -s < 腳本` / `curl | bash`),那種跑法不會問密碼(sudo 會跟腳本搶同一條 stdin)—— 把腳本落地到該機再跑就會問:`bash %s`_\n' "$SCRIPT_NAME"
else
  # 裝置清單優先用 --scan-open:控制器後面的碟要 `-d megaraid,N` 才問得到,手寫 /dev/sdX 問不到。
  SMDEV="$(sq smartctl --scan-open 2>/dev/null | sed 's/#.*//; s/[[:space:]]*$//' | grep -v '^$')"
  SMSRC="smartctl --scan-open"
  if [ -z "$SMDEV" ]; then
    SMDEV="$(printf '%s\n' "$DISKROWS" | awk 'NF{print "/dev/"$1}')"
    SMSRC="lsblk 實體碟清單(--scan-open 沒掃到)"
  fi
  if [ -z "$SMDEV" ]; then
    note "找不到可查詢的碟"
  else
    printf '```\n'
    printf '%-34s %s\n' DEVICE HEALTH   # 表頭用 ASCII,理由同「實體碟總覽」那張表
    printf '%s\n' "$SMDEV" | while IFS= read -r _d; do
      [ -n "$_d" ] || continue
      # $_d 可能是「/dev/bus/0 -d megaraid,8」多字串,刻意不加引號讓它斷字
      # shellcheck disable=SC2086
      _out="$(sq smartctl -H $_d 2>&1)"
      _res="$(printf '%s\n' "$_out" | grep -iE 'overall-health|SMART Health Status' | sed -E 's/.*: *//' | head -1)"
      if [ -z "$_res" ]; then
        _res="量不到($(printf '%s\n' "$_out" | grep -iE 'unable|unknown|failed|permission|not supported|Open failed' | head -1 | cut -c1-56))"
      fi
      printf '%-34s %s\n' "$_d" "$_res"
    done
    printf '```\n'
    kv "裝置清單來源" "$SMSRC"
    printf -- '- PASSED / OK = 這顆碟自評沒事;**FAILED = 立刻安排換碟**。「量不到」多半是碟在 RAID 控制器後面而 `--scan-open` 沒列出來 —— 走 BMC 或上面的廠商 CLI。\n'
    printf -- '- _通電時數 / 重配置磁區 / NVMe 壽命%% 本腳本刻意不抓(屬監控指標,不是環境紀錄)_\n'
  fi
fi
# 反過來:「這台把資料分享給誰」。samba 不屬於 aetherSlide(compose 沒有 SMB server),
# 有的話一定是站台自建或客戶 IT 推的 —— 只列分享名與 path,不判斷用途,密碼類鍵不抓。
printf '<!--SEC:share.samba-->\n### 本機分享出去的目錄(samba)\n'
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
# 同一類的另一半:這台當 NFS server 分享出去的目錄。
# `exportfs -s` 要 root,所以讀設定檔:/etc/exports 加 /etc/exports.d/*.exports。
printf '<!--SEC:share.nfs_export-->\n### 本機分享出去的目錄(NFS export)\n'
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

# ── 5. 執行中的 aetherSlide ──────
# 整節用 HAS_AS 包起來:AI 推論主機常沒有 aetherSlide,照印空欄位會像「裝了但全掛了」。
sec app "5. 執行中的 aetherSlide"
if [ "$HAS_AS" = "0" ]; then
  note "本機沒有 aetherSlide 部署($DEPLOY_DIR 找不到 configs.env / .env),本節略過"
  note "部署在別的路徑的話用第一個參數指定:bash collect_site_config.sh /path/to/website"
else
  kv "部署目錄" "$DEPLOY_DIR"
  # .env 的 TAG 是「設定要跑哪版」,實際 image tag 是「現在真的在跑哪版」;不一致 = 改了沒重建。
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
  printf '<!--SEC:app.config_files-->\n### 設定檔存在狀況\n'
  for f in configs.env prefs.env .env configs.yaml tier_configs.yaml model-config; do
    if [ -e "$DEPLOY_DIR/$f" ]; then kv "$f" "存在"; else kv "$f" "(無)"; fi
  done
  [ -d "$DEPLOY_DIR/secrets" ] && kv "secrets/" "存在(目錄)"
  # 站台有幾十個容器,不健康的會混在清單裡看不到,所以先單獨拉出來當警示
  if have docker; then
    BAD="$(docker ps --format '{{.Names}}\t{{.Status}}' 2>/dev/null |
      grep -iE 'restarting|unhealthy|health: starting|created|paused')"
    printf '<!--SEC:app.containers_unhealthy-->\n### 狀態不正常的 container(先看這個)\n'
    if [ -n "$BAD" ]; then
      printf '```\n%s\n```\n' "$BAD"
      printf -- '- _重啟中 / unhealthy 代表這個服務現在是壞的,交接時要問清楚原因_\n'
    else
      printf -- '- 無狀態異常的 container\n'
    fi
  fi
  printf '<!--SEC:app.containers_running-->\n### 執行中 container(名稱 / image / 狀態 / 對外 port)\n```\n'
  if have docker; then
    docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || note "docker ps 失敗(權限?)"
  else note "無 docker"; fi
  printf '```\n'
  # 只列最近 15 個。Exited (0) 多半是 init / volume 準備之類的一次性容器,屬正常
  if have docker; then
    STOPPED="$(docker ps -a --filter 'status=exited' --filter 'status=dead' \
      --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null | head -15)"
    printf '<!--SEC:app.containers_stopped-->\n### 已停止的 container(Exited 0 多半是一次性初始化,非 0 才要追)\n'
    if [ -n "$STOPPED" ]; then printf '```\n%s\n```\n' "$STOPPED"; else printf -- '- 無\n'; fi
  fi
fi

# ── 6. 時間與排程 ──────
sec sched "6. 時間與排程"
if have timedatectl; then
  kv "時區 / NTP" "$(timedatectl 2>/dev/null | tr -s ' ' | grep -E 'Time zone|NTP' | paste -sd '; ' -)"
else
  kv "時間 / 時區" "$(date 2>/dev/null)"
fi
printf '<!--SEC:sched.crontab-->\n### 使用者 crontab\n```\n'
crontab -l 2>/dev/null || printf '(無 crontab 或讀不到)\n'
printf '```\n'
if have systemctl; then
  # 白名單含 smb/nmb/winbind/nfs-server(不屬 aetherSlide 但常在分享它的資料)與
  # smartd/mdmonitor/zed/multipathd(「碟壞了有沒有人被通知」跟「碟好不好」是兩件事)。
  UNITS="$(systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null \
    | grep -iE 'docker|compose|aetherslide|website|microk8s|kubelet|containerd|smbd|nmbd|winbind|nfs-server|smartd|mdmonitor|zed|multipathd' | awk '{print $1}')"
  printf '<!--SEC:sched.services-->\n### 相關 systemd service\n'
  if [ -n "$UNITS" ]; then printf '```\n%s\n```\n' "$UNITS"; else printf -- '- 無(可能是人工 `bin/dc up` 起的)\n'; fi
  # 濾掉每台 Ubuntu 都有的 OS 預設 timer,只留這台自己加的
  TIMERS="$(systemctl list-timers --all --no-pager --no-legend 2>/dev/null \
    | grep -vE 'fwupd|man-db|logrotate|motd-news|dpkg-db-backup|systemd-tmpfiles|update-notifier|fstrim|sysstat|apt-daily|e2scrub|snapd|ua-timer|ubuntu-advantage|anacron|plocate|mlocate|apport')"
  printf '<!--SEC:sched.timers-->\n### systemd timer(已濾掉 OS 預設,只留這台自己加的)\n'
  if [ -n "$TIMERS" ]; then printf '```\n%s\n```\n' "$TIMERS"; else printf -- '- 無\n'; fi
fi

# ── 7. GPU node / AI Landing(AI 推論主機)──────
# microk8s + helm,不是 docker compose,所以整段是另一套指令。不自動 SSH 過去。
sec ai "7. GPU node / AI Landing(AI 推論)"
if [ "$HAS_AIL" = "0" ]; then
  note "本機沒有 AI Landing(找不到部署目錄的 values.yaml,也沒有 $AIL_NS namespace)"
  if [ -n "${AIL_URL:-}" ]; then
    # 只比對 host 部分;URL 可能帶 port 或走 FQDN
    AIL_HOST="$(printf '%s' "$AIL_URL" | sed -E 's#^[a-zA-Z]+://##; s#[:/].*$##')"
    if has_ip "$AIL_HOST"; then
      kv "AI_LANDING_URL 指向" "$AIL_URL(是本機 IP,但本機偵測不到 AI Landing → 需人工確認)"
    else
      kv "AI_LANDING_URL 指向" "$AIL_URL(**不是本機**,AI 推論在另一台)"
      printf -- '- _請到那台主機再跑一次本腳本(那台要另外貼一份),把它的第 1–7 段貼進站頁 M-machine 的「GPU node」段:_\n'
      printf '```\nbash collect.sh\n```\n'
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
  # helm appVersion(CI build 會變成 0.0.0-<sha>)、Chart.yaml、image tag 三者常不同,只抓一個會誤導。
  printf '<!--SEC:ai.versions-->\n### 版本(三個來源,不一致是常態,要一起看)\n'
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
    printf '<!--SEC:ai.core_images-->\n### 核心服務 image(實際在跑的版本)\n```\n%s\n```\n' "$IMGS"
  fi

  # ── values.yaml:逐鍵取值,密碼類鍵一律不查(同 configs.env 的原則)──
  if [ -f "$AIL_DIR/values.yaml" ]; then
    printf '<!--SEC:ai.values-->\n### values.yaml(非密鍵;adminPassword / SECRET_KEY / *_PASS 刻意不抓)\n'
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
  # 8500 是 svc/ingress 的 externalIPs,由 kube-proxy iptables 轉;主機上沒有 listening socket。
  if [ -n "$KCTL" ]; then
    printf '<!--SEC:ai.endpoint-->\n### 對外端點(externalIPs 沒有 listening socket,ss 抓不到,只能問 k8s)\n'
    ING_SVC="$(kctl get svc -A --no-headers -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.type,EXTIP:.spec.externalIPs[*],PORT:.spec.ports[*].port' | awk '$4!="<none>"')"
    if [ -n "$ING_SVC" ]; then printf '```\n%s\n```\n' "$ING_SVC"; else note "沒有帶 externalIPs 的 service"; fi
    NP_SVC="$(kctl get svc -A --no-headers -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.type,NODEPORT:.spec.ports[*].nodePort' | awk '$3=="NodePort"')"
    printf '<!--SEC:ai.endpoint.nodeport-->\n#### NodePort service\n'
    if [ -n "$NP_SVC" ]; then printf '```\n%s\n```\n' "$NP_SVC"; else printf -- '- 無\n'; fi
    ING="$(kctl get ingress -A --no-headers)"
    printf '<!--SEC:ai.endpoint.ingress-->\n#### Ingress\n'
    if [ -n "$ING" ]; then printf '```\n%s\n```\n' "$ING"; else printf -- '- 無\n'; fi
  fi

  # ── 叢集節點與 GPU 配置 ──
  if [ -n "$KCTL" ]; then
    printf '<!--SEC:ai.nodes-->\n### 叢集節點\n```\n'
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
    printf '<!--SEC:ai.timeslicing-->\n#### time-slicing configmap\n'
    if [ -n "$TS" ]; then printf '```\n%s\n```\n' "$TS"; else printf -- '- 無(未設定 time-slicing)\n'; fi
  fi

  # ── pod 狀態 ──
  # 推論 job 留下的 pod 可達上千個(實測 1369)→ 依 ownerReferences 拆:Job 只給統計,其餘逐一列。
  if [ -n "$KCTL" ]; then
    PODS="$(kctl get pods -n "$AIL_NS" --no-headers -o 'custom-columns=OWNER:.metadata.ownerReferences[*].kind,NAME:.metadata.name,PHASE:.status.phase,REASON:.status.reason,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount')"
    CORE="$(printf '%s\n' "$PODS" | awk '$1!="Job"')"
    printf '<!--SEC:ai.pods-->\n### 核心 pod(已排除推論 job 的 pod)\n'
    if [ -n "$CORE" ]; then printf '```\n%s\n```\n' "$CORE"; else note "查不到 pod"; fi
    BADP="$(printf '%s\n' "$CORE" | awk '$3!="Running" && $3!="Succeeded" || $5 ~ /false/')"
    printf '<!--SEC:ai.pods_unhealthy-->\n#### 狀態不正常的核心 pod(先看這個)\n'
    if [ -n "$BADP" ]; then
      printf '```\n%s\n```\n' "$BADP"
      printf -- '- _交接時要問清楚原因_\n'
    else
      printf -- '- 無\n'
    fi
    printf '<!--SEC:ai.jobs_stats-->\n#### 推論 job 統計(受 BACKEND_JOB_TTL_DAYS_AFTER_FINISHED 限制,只看得到保留期內的)\n'
    JOB_N="$(kctl get jobs -n "$AIL_NS" --no-headers | wc -l | tr -d ' ')"
    kv "job 總數" "${JOB_N:-0}"
    printf '```\n%s\n```\n' "$(printf '%s\n' "$PODS" | awk '$1=="Job"{print $3" "$4}' | sort | uniq -c | sort -rn)"
    # 模板「AI model 版本」那格唯一的來源。會混進 prometheus / grafana 等基礎設施 image,
    # 所以先只留 /ai-app/;一個都沒命中就退回列全部並註明。
    ALL_IMG="$(kctl get pods -n "$AIL_NS" --no-headers -o 'custom-columns=IMG:.spec.containers[*].image' |
      tr ',' '\n' | sed 's/^ *//' | grep -v '^$')"
    APP_IMG="$(printf '%s\n' "$ALL_IMG" | grep '/ai-app/' | sort | uniq -c | sort -rn)"
    printf '<!--SEC:ai.app_images-->\n#### 保留期內跑過的 AI app image(次數 / image)\n'
    if [ -n "$APP_IMG" ]; then
      printf '```\n%s\n```\n' "$APP_IMG"
    else
      printf -- '- _沒有 `/ai-app/` 路徑的 image,改列全部(含基礎設施 image,需自行分辨)_\n'
      printf '```\n%s\n```\n' "$(printf '%s\n' "$ALL_IMG" | sort | uniq -c | sort -rn)"
    fi
    printf -- '_這是「跑過」不是「裝了哪些」;沒被呼叫過的 app 不會出現_\n'
    printf '<!--SEC:ai.pvc-->\n### PVC\n```\n'
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

# ── 8. 對接與整合設定(從 configs.env 讀,不含任何密碼類鍵)──────
# 屬 M-config 層,貼到站頁的「對接(整合)」。
sec integ "8. 對接與整合設定(→ 貼到 M-config 的「對接(整合)」)"
# DICOM / HL7 等鍵沒用到也有預設值:模組沒列在 MODULES 裡就代表服務沒起、設定不生效。
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
  # AI 推論去向。註解掉時走程式預設(舊版預設是已廢棄的 FQDN),「沒這行」不等於「沒有 AI 推論」。
  kv "AI_LANDING_URL(AI 推論端點)" "${AIL_URL:-(未設定 / 被註解 → 走程式預設值,需查該版預設)}"
  printf -- '_掃描機型號 / PACS-LIS-HIS 對接對象 / 對方 IP 與 port 仍需人工填(設定檔看不出來)_\n'
else
  note "讀不到 $DEPLOY_DIR/configs.env"
fi

# ── 9. 另一個節點(dual)──────
# 只提醒「有另一台、是哪一台」:不自動連過去,跑法也不印在報告裡(要指令就用 --peer)。
if [ "$ARCH" = "dual" ]; then
  sec peer "9. 另一個節點"
  if [ -n "$PEER_IP" ]; then
    kv "對方節點" "$PEER_IP$([ -n "$NODE_SELF" ] && printf '(本機是 %s)' "$NODE_SELF")"
    printf -- '- 那一台要自己再跑一次;要指令就跑 `bash %s --peer <帳號>@%s`(只印指令,不會採本機)\n' \
      "$SCRIPT_NAME" "$PEER_IP"
  else
    if [ -n "$NODE_1_IP$NODE_2_IP" ]; then
      note "**本機不是 dual 的任一節點**(IP 不在 NODE_1_IP=${NODE_1_IP:-未填} / NODE_2_IP=${NODE_2_IP:-未填} 上)—— 這台多半是 witness / ES 或其他角色機,dual 那兩台要各自跑一次"
    else
      note "dual 架構但 .env 沒填 NODE_1_IP / NODE_2_IP,推不出這站的兩個節點是誰 —— 要人工確認"
    fi
  fi
fi

printf '\n---\n_採集完成。對接對方是誰、聯絡窗口等需人工填寫的欄位不在此輸出(屬站頁 H 層)。_\n'
printf '\n===== 以上結束複製 =====\n' >&2

exit 0
