#!/usr/bin/env bash
# collect_site_config.sh v1.17 — 唯讀採集客戶站台環境資訊,輸出 Markdown 供貼入 site config 站頁。
# 2026-08-07 起**報告輸出全部英文**(國外 FAE 也要用);shell 註解仍保持中文(給維護者看)。
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
      printf '[collect_site_config] --with-sudo has been the default since v1.13; this flag is ignored.\n' >&2; shift ;;
    --no-remote)
      printf '[collect_site_config] --no-remote has been the default since v1.13 (peer is never contacted automatically); this flag is ignored.\n' >&2; shift ;;
    --ai-landing-dir)
      AIL_DIR="${2:-}"
      [ -n "$AIL_DIR" ] || { echo "--ai-landing-dir requires a directory" >&2; exit 2; }
      shift 2 ;;
    --peer)
      PEER="${2:-}"
      [ -n "$PEER" ] || { echo "--peer requires [user@]host" >&2; exit 2; }
      shift 2 ;;
    -h|--help)
      printf '%s v1.17 — read-only capture of a customer site environment; prints Markdown to paste into the site config page.\n\n' "$SCRIPT_NAME"
      printf '  bash %s [deploy-dir]            defaults to ~/website. The report is printed to the screen, no file is written\n' "$SCRIPT_NAME"
      printf '  bash %s --peer [user@]host      only prints the command to run this script on that host, then exits; does not capture this host\n' "$SCRIPT_NAME"
      printf '  bash %s --ai-landing-dir DIR    set this when AI Landing is not auto-detected\n\n' "$SCRIPT_NAME"
      printf '  --with-sudo / --no-remote       no-ops since v1.13 (kept so commands in older docs do not error)\n\n'
      printf 'You are asked for the sudo password once (Enter, or no input for 10s = skip). Usage details, design rationale and change history: see the collector notes doc.\n'
      exit 0 ;;
    # 不認識的旗標一律報錯:舊版會被下面的 *) 當成「部署目錄」吃掉,打錯字不報錯。
    --*)
      printf 'Unknown argument: %s\nFor the argument list run: bash %s -h\n' "$1" "$SCRIPT_NAME" >&2; exit 2 ;;
    # 明確給了就一定要存在:不然報告照跑、只是第 2/5/8 段空掉,像「這站沒東西」而不是參數打錯。
    # 不給時不檢查(GPU / 儲存主機本來就沒有 ~/website)。
    *)
      if [ ! -d "$1" ]; then
        printf 'Argument "%s" is not an existing directory.\n' "$1" >&2
        case "$1" in
          *@*|[0-9]*.[0-9]*.[0-9]*.[0-9]*)
            printf 'That looks like a host address — to capture another host use --peer:\n    bash %s --peer %s\n' "$SCRIPT_NAME" "$1" >&2 ;;
          *)
            printf 'The positional argument is the aetherSlide deploy directory (default ~/website); for the argument list run: bash %s -h\n' "$SCRIPT_NAME" >&2 ;;
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
  printf '# First check which key this host has (it differs per site)\n'
  printf 'ls -1 ~/.ssh/id_*\n\n'
  printf '# Replace K= with what you found above and paste the whole line; do not drop -t (a host without a pty cannot be asked for the sudo password)\n'
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
  if ! have sudo; then SUDO_NOTE="no sudo command on this host"; return; fi
  if sudo -n true 2>/dev/null; then
    SUDO_OK=1; SUDO_MODE="n"; SUDO_NOTE="passwordless sudo (no password was asked)"; return
  fi
  # sudo 訊息受 locale 影響,中英文關鍵字都比對;比對不到保守當作「不准」,不白問。
  _why="$(sudo -n true 2>&1)"
  if ! printf '%s' "$_why" | grep -qiE 'password|密[碼码]'; then
    SUDO_NOTE="this account is not allowed to sudo ($(printf '%s' "$_why" | head -1 | cut -c1-60)); every field that needs root is skipped"
    return
  fi
  # ②③ 不能互動就不要問
  if [ ! -t 2 ] || [ -z "$SELF" ] || [ ! -r "$SELF" ]; then
    SUDO_NOTE="no passwordless sudo and no way to type one interactively (no tty, or the script was fed via stdin) -- fields that need root are skipped. To capture them, put the script on that host and run it there: bash $SCRIPT_NAME"
    return
  fi
  printf '\n[collect_site_config] sudo is needed to read: hardware serial / warranty, RAID array state, SMART disk health, LVM.\n' >&2
  printf '[collect_site_config] Everything is a read-only query: no setting is changed, no file is written.\n' >&2
  printf '[collect_site_config] Press Enter (or give no input for 10s) to skip; the rest of the capture is unaffected. A wrong password can be retried twice.\n' >&2
  _try=1
  while [ "$_try" -le 3 ]; do
    printf '[collect_site_config] sudo password (attempt %d/3, Enter to skip): ' "$_try" >&2
    if ! IFS= read -r -s -t 10 _pw < /dev/tty 2>/dev/null; then
      printf '\n[collect_site_config] Timed out or input closed -- skipping fields that need root.\n' >&2
      SUDO_NOTE="no passwordless sudo; the user did not supply a password (timeout or Ctrl-D) -- fields that need root are skipped"
      return
    fi
    printf '\n' >&2
    if [ -z "$_pw" ]; then
      printf '[collect_site_config] Skipping fields that need root.\n' >&2
      SUDO_NOTE="no passwordless sudo; the user chose to skip (no password entered) -- fields that need root are skipped"
      return
    fi
    if printf '%s\n' "$_pw" | sudo -S -p '' -v 2>/dev/null; then
      SUDO_OK=1
      # timestamp 到底有沒有生效?生效就把密碼丟掉,不生效才留著(見①)
      if sudo -n true 2>/dev/null; then
        SUDO_MODE="n"
        SUDO_NOTE="password typed once interactively (sudo timestamp is valid; the script kept no password)"
      else
        SUDO_MODE="S"; SUDO_PW="$_pw"
        SUDO_NOTE="password typed once interactively; **this site does not cache the sudo timestamp (timestamp_timeout=0)**, so the script holds the password for the whole run to avoid asking repeatedly"
      fi
      unset _pw
    printf '[collect_site_config] sudo is available; starting capture.\n' >&2
      return
    fi
    printf '[collect_site_config] Wrong password.\n' >&2
    _try=$((_try + 1))
  done
  unset _pw
  SUDO_NOTE="no passwordless sudo; password was wrong three times in a row -- fields that need root are skipped"
  printf '[collect_site_config] Three wrong attempts; skipping fields that need root.\n' >&2
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
note() { printf -- '- _(skipped: %s)_\n' "$1"; }
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
  else NODE_SELF="dual/unknown node"; fi
elif [ -n "$ARCH" ]; then
  NODE_SELF="$ARCH"
elif [ -f "$DEPLOY_DIR/configs.env" ]; then
  NODE_SELF="unknown (no ARCHITECTURE in configs.env)"
else
  # 純 AI Landing 主機本來就沒有 configs.env,不能印成「aetherSlide 壞了」
  NODE_SELF="not an aetherSlide host"
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

if [ "$HAS_AS" = "1" ] && [ "$HAS_AIL" = "1" ]; then ROLE="aetherSlide + AI Landing (same host)"
elif [ "$HAS_AIL" = "1" ];                        then ROLE="AI Landing (no aetherSlide on this host)"
elif [ "$HAS_AS" = "1" ];                         then ROLE="aetherSlide (no AI Landing on this host)"
else                                                   ROLE="neither was detected"
fi

# 報告不落地靠螢幕複製,所以要起訖標記;走 stderr 才不會混進 stdout。
printf '\n===== COPY FROM HERE (down to "END OF COPY") =====\n\n' >&2

printf '<!--COLLECTOR:v1.17-->\n'
printf '# site config capture — %s(%s)\n' "$(hostname 2>/dev/null || echo unknown)" "$NODE_SELF"
printf '> Read-only capture. Sensitive values (credentials / private keys) are deliberately not collected.\n'
printf '> Privilege: %s\n' "${SUDO_NOTE:-not determined}"
# 採集時間是目標機自己的時鐘與時區(第 6 段有時區/NTP,對得起來就知道這個時間可不可信)。
printf '> Captured at: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo unknown)"
printf '>\n'
printf '> **Where to paste this** (the section order already matches the site page; paste top to bottom):\n'
printf '>\n'
printf '> | Section in this report | Block on the site page |\n'
printf '> |---|---|\n'
printf '> | 0 Node identity | Not pasted directly; use it to confirm the architecture and which host this is |\n'
printf '> | 1-6 | The same-named subsection under `AUTO:M-machine` |\n'
printf '> | 7 GPU node / AI Landing | The "GPU node" part at the end of `AUTO:M-machine` |\n'
printf '> | 8 Integrations | The "Integrations" part of `AUTO:M-config` |\n'
printf '> | 9 The other node | Not pasted directly: it only tells you who the peer node is. Run this script on that host too; its output is what fills the Node 2 column of each table |\n'

sec node.identity "0. Node identity"
kv "hostname" "$(hostname 2>/dev/null || echo unknown)"
kv "Host role" "$ROLE"
kv "ARCHITECTURE" "${ARCH:-unknown}"
kv "This node" "$NODE_SELF"
if [ "$ARCH" = "dual" ]; then
  kv "NODE_1_IP" "${NODE_1_IP:-(empty)}"
  kv "NODE_2_IP" "${NODE_2_IP:-(empty)}"
  kv "VIRTUAL_IP (VIP)" "${VIRTUAL_IP:-(empty)}"
  kv "ES_HOST" "${ES_HOST:-(empty)}"
  if has_ip "$VIRTUAL_IP"; then
    kv "VIP currently bound to this host" "yes (this host is the keepalived master)"
  else
    kv "VIP currently bound to this host" "no"
  fi
  [ "$NODE_SELF" = "dual/unknown node" ] &&
    printf -- '- _Neither NODE_1_IP nor NODE_2_IP is on an interface of this host. The .env may be unset, or it is behind NAT; confirm by hand_\n'
fi

# ── 1. 節點與網路 ──────
sec net "1. Node and network"
# 自動判斷最可能的對外路徑:預設路由的介面就是主要對外網卡,不列整張路由表
if have ip; then
  DEF_LINE="$(ip route show default 2>/dev/null | head -1)"
  DEF_GW="$(echo "$DEF_LINE" | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')"
  DEF_IF="$(echo "$DEF_LINE" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')"
  DEF_IP="$(ip -brief addr show "$DEF_IF" 2>/dev/null | awk '{print $3}')"
  kv "Primary outbound interface (default route)" "${DEF_IF:-unknown}"
  kv "Primary IP" "${DEF_IP:-unknown}"
  kv "Default gateway" "${DEF_GW:-unknown}"
else
  note "no ip command"
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
printf '<!--SEC:net.interfaces-->\n### Network interfaces (container and virtual NICs filtered out)\n```\n'
if have ip; then
  for _n in $IFLIST; do ip -brief addr show "$_n" 2>/dev/null; done
fi
printf '```\n'
# 只撈累積型欄位,不撈即時流量。speed / MTU 讀 sysfs(ethtool 要 CAP_NET_ADMIN),
# 型號用 lspci 補 —— 只有驅動名看不出是 1G 還是 25G 卡。
printf '<!--SEC:net.iface_detail-->\n### Interface detail (speed / MTU / driver / model)\n'
printf -- '> The speed on virtual interfaces such as `br0` / `bond0` is an aggregated, virtual figure (on a real demo host `br0`\n'
printf -- '> reported 10000Mb/s while the physical NIC underneath ran at 1000Mb/s). **Read the physical row, not the bridge row.**\n'
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
  printf -- '> `*` = **a value reported by a virtual NIC driver, not a physical ceiling**. vmxnet3 / virtio almost always report\n'
  printf -- '> 10000Mb/s regardless of whether the physical NIC underneath is 1G or 25G. The real ceiling is in the hypervisor: the\n'
  printf -- '> physical uplink, vSwitch teaming (**a guest cannot see link aggregation at the host layer**), and whether the port\n'
  printf -- '> group has traffic shaping (which can cap throughput with the guest none the wiser). **All three can only be obtained\n'
  printf -- '> from the customer virtualization admin.** On a VM the only meaningful parts of this table are **MTU** and the\n'
  printf -- '> **cumulative errors** below; speed and model are only good for telling which kind of virtual NIC is in use.\n'
fi
if [ "$EMULATED_NIC_SEEN" = "1" ]; then
  printf -- '> ⚠ **e1000 / e1000e** detected — that is an **emulated** Intel gigabit NIC, not a paravirtual one\n'
  printf -- '> (vmxnet3 / virtio_net). Throughput and CPU overhead are both clearly worse; usually the VM template was not changed or VMware Tools is not installed.\n'
fi
# MTU 1500 vs 9000 對 NFS 大檔差很多。DOWN 的實體網卡不濾掉:「有 10G 埠沒接線」是擴充頻寬最便宜的路。
printf '<!--SEC:net.iface_errors-->\n### Cumulative interface errors / drops (since boot, not a point-in-time value)\n'
printf -- '> **`rx_drop` normally has a non-zero count on bridges and physical NICs** (packets not addressed to this host are\n'
printf -- '> counted too) — a real demo host showed 3 million on `br0`. **What matters is `rx_err` / `tx_err`; those mean the link or the card has a problem.**\n'
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
if [ -n "$IFERR" ]; then printf '```\n%s```\n' "$IFERR"; else printf -- '- rx/tx errors and dropped are 0 on every interface\n'; fi
# bonding / VLAN:有沒有做鏈路聚合直接決定頻寬上限是一張卡還是兩張卡
if [ -d /proc/net/bonding ] && ls /proc/net/bonding/* >/dev/null 2>&1; then
  printf '<!--SEC:net.bonding-->\n### bonding\n```\n'
  for _b in /proc/net/bonding/*; do
    printf '[%s]\n' "$(basename "$_b")"
    grep -E 'Bonding Mode|Slave Interface|MII Status|Speed|Aggregator ID' "$_b" 2>/dev/null
  done
  printf '```\n'
else
  printf -- '- **bonding**: none (no `/proc/net/bonding`, single NIC)\n'
fi
if [ -s /proc/net/vlan/config ]; then
  printf '<!--SEC:net.vlan-->\n### VLAN\n```\n'; cat /proc/net/vlan/config 2>/dev/null; printf '```\n'
else
  printf -- '- **VLAN**: none (this also reads "none" when the guest cannot see VLAN tags; ask about the switch side separately)\n'
fi
printf '<!--SEC:net.dns-->\n### DNS\n```\n'
grep -E '^nameserver' /etc/resolv.conf 2>/dev/null || note "cannot read resolv.conf"
printf '```\n'
# v1.2 起不列 listen port:抓到的幾乎都是 NFS/RPC 動態高位 port,是雜訊。對外 port 以防火牆為準。

# ── 2. 憑證 ──
sec cert "2. Certificate (SSL)"
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
  kv "Certificate file" "$CERT$([ "$CERT_READ" = "sudo" ] && printf '(file is root-readable only; read via sudo)')"
  kv "Subject" "$(cert_x509 -subject | sed 's/^subject=//')"
  kv "SAN" "$(cert_x509 -ext subjectAltName | grep -v 'X509v3' | tr -s ' ')"
  kv "Expires" "$(cert_x509 -enddate | sed 's/^notAfter=//')"
elif [ -f "$CERT" ] && have openssl; then
  # 檔案在、openssl 也在,但讀不到 —— 這是權限,不是「沒有憑證」
  kv "Certificate file" "$CERT(**file exists but cannot be read**)"
  printf -- '- _`openssl x509` failed to read it, which is almost always file permissions (cert/key are commonly `0600 root:root`). **This does not mean the site has no certificate.**_\n'
  printf -- '- _sudo state for this run: %s. To fill these fields, run as root on that host (read-only):_\n' "${SUDO_NOTE:-not determined}"
  printf '```\nsudo openssl x509 -in %s -noout -subject -ext subjectAltName -enddate\n```\n' "$CERT"
elif [ -f "$CERT" ]; then
  note "$CERT exists but this host has no openssl command, so certificate detail cannot be read"
elif printf '%s' "$(envval "$DEPLOY_DIR/configs.env" MODULES)" | grep -q caddy ||
     { have docker && docker ps --format '{{.Names}}' 2>/dev/null | grep -q caddy; }; then
  # 啟用 caddy 的站台憑證由 caddy 自己申請與續約,不會放在 data/ssl
  kv "Certificate management" "caddy (ACME issues / renews automatically), not under $DEPLOY_DIR/data/ssl"
  note "certificate detail would require entering the caddy container or reading its data dir; this script does not enter containers"
else
  note "$CERT does not exist (the file is genuinely absent, not a permission problem) and no caddy was detected -- for a non-standard path pass the deploy directory argument, or ask the customer where the certificate lives"
fi

# ── 3. 硬體 ──────
sec hw "3. Hardware"
if have lscpu; then
  kv "CPU model" "$(lscpu 2>/dev/null | grep -E 'Model name' | sed 's/.*: *//')"
  kv "CPU cores (logical)" "$(nproc 2>/dev/null)"
else note "no lscpu"; fi
if have free; then kv "RAM" "$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')"; fi
if have nvidia-smi; then
  kv "GPU driver / CUDA" "driver $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1) / $(nvidia-smi 2>/dev/null | sed -n 's/.*CUDA Version: *\([0-9.]*\).*/\1/p' | head -1)"
fi
printf '<!--SEC:hw.gpu-->\n### GPU\n```\n'
if have nvidia-smi; then
  nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader 2>/dev/null || nvidia-smi -L 2>/dev/null
else note "no nvidia-smi"; fi
printf '```\n'
# 序號 / 保固靠 dmidecode(需 root)。序號是查保固的唯一線索,拿到權限就抓。
if ! have dmidecode; then
  printf -- '_Serial / warranty / supplier: this host has no `dmidecode` command; read the machine label or the BMC_\n'
elif sudo_ready; then
  SERIAL="$(sq dmidecode -s system-serial-number 2>/dev/null | grep -v '^#' | head -1)"
  PRODUCT="$(sq dmidecode -s system-product-name 2>/dev/null | grep -v '^#' | head -1)"
  VENDOR="$(sq dmidecode -s system-manufacturer 2>/dev/null | grep -v '^#' | head -1)"
  if [ -n "$SERIAL$PRODUCT$VENDOR" ]; then
    kv "Vendor / model" "${VENDOR:-unknown} / ${PRODUCT:-unknown}"
    kv "System serial" "${SERIAL:-unknown}"
  else
    note "sudo and dmidecode are both available but no serial was returned (common on VMs: a virtual machine has no physical DMI data)"
  fi
else
  printf -- '_Serial / warranty / supplier need to be looked up separately (needs root: %s)_\n' "${SUDO_NOTE:-not determined}"
fi

# ── 4. OS / Docker / 儲存 ──────
sec os "4. OS / Docker / storage"
kv "OS" "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
kv "Kernel" "$(uname -r 2>/dev/null)"
VIRT=""
if have systemd-detect-virt; then VIRT="$(systemd-detect-virt 2>/dev/null)"; kv "Virtualization" "$VIRT"; fi
# **VMware / Hyper-V 不透過 steal time 暴露 CPU 競爭**,guest 恆為 0 ——
# 印一個看似正常的 0 比不印還糟,所以這兩家直接標「量不到」。
if [ -n "$VIRT" ] && [ "$VIRT" != "none" ] && [ -r /proc/stat ]; then
  case "$VIRT" in
    vmware)
      kv "CPU steal" "**not measurable (VMware)** -- VMware does not report CPU contention through steal time, so a guest always reads close to 0. To tell whether it is oversubscribed, look at **CPU Ready (%RDY)** and Co-Stop on the vSphere side. **The script cannot obtain this; ask the customer virtualization admin**" ;;
    microsoft)
      kv "CPU steal" "**not measurable (Hyper-V)** -- same as VMware; look at CPU wait time per dispatch on the hypervisor side" ;;
    *)
      # kvm / xen / 各家雲的 VM 都有 steal,這裡才有意義
      kv "CPU steal (cumulative since boot)" "$(awk '/^cpu /{t=0; for(i=2;i<=NF;i++) t+=$i; printf "%.2f%%", ($9/t)*100}' /proc/stat 2>/dev/null)($VIRT)" ;;
  esac
fi
if have docker; then kv "Docker" "$(docker --version 2>/dev/null)"; else note "no docker"; fi
# 控制器偵測要提早在這裡算:「實體碟總覽」需要它判斷顆數可不可信。
HWCTL=""
have lspci && HWCTL="$(lspci 2>/dev/null | grep -iE 'RAID bus controller|Serial Attached SCSI controller|Mass storage controller|SATA controller|Non-Volatile memory controller')"
HW_CTL_RAID=0
printf '%s\n' "$HWCTL" | grep -qi 'RAID bus controller' && HW_CTL_RAID=1
# **沒有 lspci ≠ 沒有控制器**(pciutils 不是每台都裝)。少了這個旗標,下面「硬體 RAID」段會把
# 「查不了」印成「這台沒有 RAID 控制器」—— 是被當成事實抄進站頁的假否定,比空白更糟。
HW_CTL_UNKNOWN=0
have lspci || HW_CTL_UNKNOWN=1
IMSM_SEEN=0   # 下面 md 段偵測到 Intel RST 時設 1;硬體 RAID 段要用(md 段在它前面)
# 先回答「這台幾顆碟」。用 -P(key="value")而不是欄位對齊:MODEL 常含空白(PERC H730P Mini),
# 欄位切割會把它切成兩欄、序號跟著跑位。
printf '<!--SEC:hw.disks-->\n### Physical disk overview\n'
DISKROWS=""
# 這兩個旗標會傳到下面的「硬體 RAID」段用:碟的型號本身就是「這台的碟是誰做出來的」的線索。
HW_RAID_HINT=0    # 型號看起來是 RAID 控制器做出來的 virtual disk
HW_VDISK_HINT=0   # 型號看起來是 hypervisor 給的虛擬碟
VDRAID=""         # 命中前者的裝置名(空白分隔)
VDVIRT=""         # 命中後者的裝置名
if have lsblk; then
  # VENDOR 一起抓:只看 MODEL 不夠 —— MegaRAID 的 VD 型號是 MRROMB,字面看不出跟 RAID 有關,
  # 但 VENDOR 會是 AVAGO / LSI / DELL。VENDOR 不進表,只用來判斷是不是 virtual disk。
  # 比對前一律 toupper:同一個東西各家大小寫不同(HP 是 `LOGICAL VOLUME`、LSI IR 是 `Logical Volume`),
  # 舊版逐字比對會漏掉後者。清單裡的 `DELLBOSS` 是 Dell BOSS 開機鏡像卡的 VD 型號(`DELLBOSS VD`)——
  # 它在 lspci 只是一張 `SATA controller`,不加這個字串整張卡會完全隱形。
  # **刻意不加單獨的 `DELL`**:Dell 認證的直連碟 VENDOR 也可能是 DELL,會把實體碟誤標成 virtual disk。
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
      vm = toupper(vend " " model)
      if (vm ~ /(PERC|MEGARAID|MRROMB|MR9|LSI|AVAGO|BROADCOM|SERVERAID|SMART ARRAY|ADAPTEC|LOGICAL VOLUME|LOGICALDRV|VIRTUAL DRIVE|DELLBOSS|ARECA|ARC-1|3WARE|MARVELL)/) vdr = vdr " " name
      if (vm ~ /(VMWARE|VIRTUAL DISK|VIRTUAL HD|QEMU HARDDISK|VBOX|MSFT)/) vdv = vdv " " name
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
  kv "Disks visible to the OS" "$(printf '%s' "$DCOUNT" | awk '{print $1" total (HDD "$2" / SSD-NVMe "$3" / unknown "$4")"}')"
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
    printf -- '- **Note: the count above is not the number of physical disks.** The vendor / model of `%s` is a **virtual disk** presented by the RAID controller (one row can be a whole shelf of disks). **How many disks are actually behind it, and which one failed, is never visible to `lsblk`** -- see the "Hardware RAID (controller)" section below, or go through the BMC.\n' "$VDRAID"
  elif [ "$HW_CTL_RAID" = "1" ]; then
    # 型號沒露餡但機器上確實有 RAID 卡:講可能性,不要講成事實
    printf -- '- **Note: this host has a RAID controller** (see "Hardware RAID (controller)" below). If one of the rows above is in fact a virtual disk presented by the controller, **the count above is not the number of physical disks** -- compare the VD capacity from the vendor CLI against the table above to see which row it is.\n'
  fi
  if [ "$HW_VDISK_HINT" = "1" ]; then
    # 指名道姓優先(型號有露餡就列裝置名),否則就說「上面所有的碟」
    _vdwho="$([ -n "$VDVIRT" ] && printf '`%s`' "$VDVIRT" || printf 'every disk above')"
    case "$VIRT" in
      amazon|gce|azure|oracle|alibaba)
        # 雲端跟地端 hypervisor 要問的人不同,而且雲端**沒有 BMC 可看**,不能照抄同一句話
        printf -- '- **Note: this is a cloud VM (`%s`) and %s are not physical disks**, they are cloud network block storage (EBS / PD and the like). The count equals how many volumes are attached and **has nothing to do with how many physical disks are underneath**; capacity and IOPS come from the volume spec, so look at the cloud console. **The physical disks belong to the cloud provider: there is no BMC to query and SMART is meaningless.**\n' "$VIRT" "$_vdwho" ;;
      *)
        printf -- '- **Note: %s are virtual disks presented by the hypervisor (`%s`)**, so both the count and the capacity are the guest view. How many disks are actually underneath, whether they are in a RAID, and which datastore / LUN they sit on is **entirely invisible to the guest and not on this host BMC either** -- only the customer virtualization admin can answer that.\n' "$_vdwho" "${VIRT:-unknown}" ;;
    esac
  fi
  printf -- '- _An empty SERIAL means udev did not provide one (common for virtual disks, some RAID backends and VMs). It is not a failed read_\n'
else
  note "no lsblk; disk count and models have to be looked up by hand"
fi
printf '<!--SEC:storage.blockdev-->\n### Block devices / partitions\n```\n'
# -e 7 濾掉 loop 裝置(snap 裝的 microk8s 實測 29 個 squashfs,會淹掉磁碟結構)。
# 結尾 `| cat`:lsblk 依終端機寬度會截斷最後一欄,stdout 是 pipe 時才不截斷。
if have lsblk; then lsblk -e 7 -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null | cat; else note "no lsblk"; fi
printf '```\n<!--SEC:storage.mount-->\n### Disk usage / mounts\n```\n'
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
    printf -- '- **Note: a mounted device is missing from the `lsblk` list** -- `%s`. That means the device is no longer in `/sys/block` (the disk was pulled, dropped off the controller, or was not remounted after a hot-swap) while the mount is still there, so `df` still reports numbers. **Such a disk is not counted above, and the capacity figures above may no longer be reliable.** Record it as-is and do not infer its purpose (block C4 of the site page template collects this).\n' "$GHOSTDEV"
  fi
fi
# NFS 掛載參數:df 說「掛了誰、用多少」,這裡說「怎麼掛的」。rsize/wsize 與 vers 決定大檔吞吐,
# hard vs soft 決定 NFS 卡住時是無限等待還是回錯。來源主機不重複列(上面 df 有)。
printf '<!--SEC:storage.nfs_opts-->\n### NFS mount options\n'
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
  printf -- '- No NFS mounts (data is on local disks)\n'
fi
# 一律印結論:舊版沒有 md 就整段不印,讀者分不出「沒有軟 RAID」與「腳本沒查」。
# 而且只貼 mdstat 原文不夠:degraded 在 `[U_]` 那兩個字元,會被滑過去。
printf '<!--SEC:hw.raid_md-->\n### Software RAID (md)\n'
if [ ! -r /proc/mdstat ]; then
  printf -- '- Cannot read `/proc/mdstat` (no md module in the kernel)\n'
elif ! grep -q '^md' /proc/mdstat 2>/dev/null; then
  printf -- '- **No active md array** -- this host has no Linux software RAID. If the disks are in a RAID it was done at the controller layer or by the hypervisor (see "Hardware RAID (controller)" below)\n'
else
  MDSTAT="$(cat /proc/mdstat 2>/dev/null)"
  MDBAD=""
  # 狀態列 [UU] 全 U = 成員都在線;出現 _ 就是缺成員
  printf '%s\n' "$MDSTAT" | grep -qE '\[[U_]*_[U_]*\]' && MDBAD="degraded (a \`_\` appears in the status line, a member is offline)"
  printf '%s\n' "$MDSTAT" | grep -q '(F)' && MDBAD="${MDBAD:+$MDBAD;}a member is flagged faulty \`(F)\`"
  printf '%s\n' "$MDSTAT" | grep -qE 'recovery|resync|reshape' && MDBAD="${MDBAD:+$MDBAD;}rebuild / resync in progress"
  if [ -n "$MDBAD" ]; then
    kv "md array health" "**abnormal -- $MDBAD**"
  else
    kv "md array health" "all members online (no \`_\` in the status line). **This does not mean the disks are healthy** -- for disk life see SMART below"
  fi
  printf '```\n%s\n```\n' "$MDSTAT"
  # Intel RST(主機板 fakeRAID)的 mdstat 會有一行 `inactive … super external:imsm` ——
  # 那是 metadata container,**顯示 inactive 是正常的**,不解釋會被當成故障。
  if printf '%s\n' "$MDSTAT" | grep -q 'external:imsm'; then
    IMSM_SEEN=1
    printf -- '- _`external:imsm` = **Intel RST (motherboard fakeRAID)**, neither native Linux md nor a hardware RAID card: the array is defined by the board BIOS and driven by the kernel md driver. The `inactive ... (S)` line is the **metadata container, and showing inactive is normal** -- the real array is the `active` md above it. To replace a disk or see detail, go through the Intel RST screen in BIOS_\n'
  fi
  if have mdadm && sudo_ready; then
    for _md in /dev/md*; do
      [ -b "$_md" ] || continue
      _det="$(sq mdadm --detail "$_md" 2>/dev/null |
              grep -E 'Raid Level|Array Size|Raid Devices|Total Devices|State :|Active Devices|Working Devices|Failed Devices|Spare Devices|Rebuild Status|Consistency Policy')"
      [ -n "$_det" ] && printf -- '- **%s**(`mdadm --detail`)\n```\n%s\n```\n' "$_md" "$_det"
    done
  elif ! have mdadm; then
    note "an md array exists but there is no mdadm command, so member-disk detail cannot be read"
  else
    printf -- '- _RAID level, member count, which disk dropped and rebuild progress need `mdadm --detail` (needs root: %s)_\n' "${SUDO_NOTE:-not determined}"
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
    note "LVM2_member partitions detected, but vgs/lvs need root to read ($SUDO_NOTE)"
  else
    printf -- '- No LVM\n'
  fi
fi
# ZFS / btrfs:軟體 RAID 的另外兩種,只查 mdstat 會漏掉整片陣列。沿用 LVM 那套權限判斷。
printf '<!--SEC:storage.zfs-->\n### ZFS\n'
if ! have zpool; then
  printf -- '- No ZFS (no `zpool` command)\n'
else
  ZP="$(zpool list 2>/dev/null)"
  { [ -z "$ZP" ] && sudo_ready; } && ZP="$(sq zpool list 2>/dev/null)"
  if [ -z "$ZP" ]; then
    printf -- '- ZFS is installed but there is no pool (or `zpool` needs root: %s)\n' "${SUDO_NOTE:-not determined}"
  else
    printf '```\n%s\n```\n' "$ZP"
    # `zpool status -x` 是一行式健康判定(全好只印 all pools are healthy),比整份 status 適合紀錄。
    ZS="$(zpool status -x 2>/dev/null)"
    { [ -z "$ZS" ] && sudo_ready; } && ZS="$(sq zpool status -x 2>/dev/null)"
    [ -n "$ZS" ] && printf -- '- **pool health** (`zpool status -x`)\n```\n%s\n```\n' "$ZS"
  fi
fi
# btrfs 只在真的有 btrfs 檔案系統時才查,避免在每台機器上多印一段無關的「無」
if lsblk -o FSTYPE 2>/dev/null | grep -q btrfs; then
  printf '<!--SEC:storage.btrfs-->\n### btrfs (a btrfs filesystem was detected)\n'
  if ! have btrfs; then
    note "btrfs partitions exist but there is no btrfs command, so the RAID profile cannot be read"
  else
    BT="$(btrfs filesystem show 2>/dev/null)"
    { [ -z "$BT" ] && sudo_ready; } && BT="$(sq btrfs filesystem show 2>/dev/null)"
    if [ -n "$BT" ]; then
      printf '```\n%s\n```\n' "$BT"
      printf -- '- _The RAID profile (single / raid1 / raid10) needs `btrfs filesystem df <mountpoint>` per mountpoint; this script does not walk every mountpoint_\n'
    else
      note "btrfs filesystem show needs root ($SUDO_NOTE)"
    fi
  fi
fi
# 硬體 RAID 分兩層:① 控制器型號(lspci,非 root 可讀);② 陣列狀態(只有廠商 CLI 問得到,需 root)。
# 兩層都拿不到時要明講量不到,不能讓「md 成員全部在線」被讀成「陣列沒問題」。
# 而且**實務上第二層多半拿不到**(客戶站沒裝廠商 CLI、或這次沒有 root),所以「量不到」不能說完就算——
# 要把站頁 C2 需要的欄位逐條列出來,讓人有東西可以去 BMC 抄。
bmc_raid_todo() {
  printf -- '- **Copy these from the BMC (iDRAC / iLO / IPMI web) or by running the vendor CLI by hand** -- site page block C2 needs them and **none of them can be reached from the OS**:\n'
  printf -- '  1. Controller model + firmware version\n'
  printf -- '  2. How many virtual drives (VD), and the RAID level + state of each\n'
  printf -- '  3. **How many physical disks sit behind the controller** -- this is the real disk count; the `Disks visible to the OS` row above is not\n'
  printf -- '  4. Hot spares: how many, and global or dedicated\n'
  printf -- '  5. Every disk that is not Online -- failed / rebuilding / foreign / **predictive failure** -- with its enclosure:slot number\n'
  printf -- '  6. BBU / CacheVault state, and the write cache policy of each VD (WriteBack vs WriteThrough)\n'
}
printf '<!--SEC:hw.raid_ctrl-->\n### Hardware RAID (controller)\n'
# HWCTL / HW_CTL_RAID 在「實體碟總覽」之前就算好了(見那裡的註解),這裡只負責印
if ! have lspci; then
  # 不用 note():那個格式是「(skipped: …)」,語氣像可有可無的一格,而這裡是「查不了」——
  # 後面那句「無法判定」才是結論,這行只負責講清楚少了什麼工具。
  printf -- '- **No `lspci` (pciutils is not installed)**, so the controller model cannot be read on this host -- it has to come from the BMC or the machine label\n'
elif [ -n "$HWCTL" ]; then
  printf '```\n%s\n```\n' "$HWCTL"
  printf -- '- _`RAID bus controller` = a hardware RAID card, or the motherboard in RAID mode; `Serial Attached SCSI controller` is usually a plain HBA (no RAID, RAID is done in the OS); `SATA controller` / `Non-Volatile memory controller` = on-board, disks are attached directly_\n'
  # 只有「控制器層 + 主機板 fakeRAID」真的並存時才印這句,否則會指向不存在的東西。
  [ "$IMSM_SEEN" = "1" ] && [ "$HW_CTL_RAID" = "1" ] &&
    printf -- '- _This host has both: the system disks go through motherboard RAID (see `external:imsm` in the md section above) and the data disks through a RAID card_\n'
else
  printf -- '- `lspci` shows no storage controller (common for the virtual disks of a VM)\n'
fi
# 廠商 CLI:這類工具幾乎都不在 PATH(裝在 /opt 底下),所以 PATH 與 /opt 常見路徑都要找
RCLI=""
# mvcli(Dell BOSS / Marvell 主機板 RAID)與 cli64(Areca)放最後:主流卡先命中,免得一台同時有兩支時選錯。
for _c in storcli64 storcli perccli64 perccli ssacli hpssacli hpacucli arcconf sas3ircu sas2ircu tw_cli MegaCli64 MegaCli megacli mvcli cli64; do
  if have "$_c"; then RCLI="$_c"; break; fi
  for _p in /opt/MegaRAID/storcli /opt/MegaRAID/perccli /opt/MegaRAID/MegaCli /opt/MegaRAID/CmdTool2 \
            /opt/lsi/storcli /opt/dell/srvadmin/bin /usr/local/sbin /usr/local/bin /opt/hp/hpssacli/bin \
            /usr/StorMan /opt/areca /opt/marvell; do
    [ -x "$_p/$_c" ] && { RCLI="$_p/$_c"; break; }
  done
  [ -n "$RCLI" ] && break
done
if [ -z "$RCLI" ]; then
  # **沒有陣列就不要說量不到**(無中生有的缺口比漏報還糟),但反過來也不能把「查不了」講成「沒有」。
  # 四句話:有卡沒 CLI → BMC;虛擬碟 → 問虛擬化管理者;連 lspci 都沒有 → 明講無法判定;
  # lspci 跑過且真的沒看到 → 沒有控制器層的陣列要查。
  if [ "$HW_RAID_HINT" = "1" ] || [ "$HW_CTL_RAID" = "1" ]; then
    printf -- '- **There is a RAID controller but no vendor CLI** (looked for storcli / perccli / MegaCli / ssacli / arcconf / sas3ircu / tw_cli / mvcli / cli64 in PATH and the usual /opt paths, none found)\n'
    printf -- '- **So array health, whether anything is degraded, which disk failed and how many disks are underneath cannot be measured on this host** -- all of that lives in the controller layer and is never visible to `lsblk` / `mdstat` / `df`. Go through the **BMC (iDRAC / iLO / IPMI web)**, or ask the customer to install the vendor CLI and run this again.\n'
    bmc_raid_todo
  elif [ "$HW_VDISK_HINT" = "1" ]; then
    printf -- '- No vendor CLI, and **this host does not need one** -- the disks are virtual disks from the hypervisor, so any underlying RAID is on the customer virtualization platform / storage appliance. Ask the virtualization admin (see the note under "Physical disk overview" above)\n'
  elif [ "$HW_CTL_UNKNOWN" = "1" ]; then
    printf -- '- **Whether this host has a RAID controller could not be determined**: there is no `lspci` (pciutils not installed), no vendor CLI, and none of the disk models above identify themselves as a virtual disk. **Do not read this as "no RAID"** -- a controller-layer array is invisible to `lsblk` / `mdstat` / `df` either way, so this is an unknown, not a negative.\n'
    bmc_raid_todo
  else
    printf -- '- **No RAID controller detected** (`lspci` ran and shows no RAID / SAS controller; the disks are attached directly to on-board SATA / NVMe) and no vendor CLI -- **there is no controller-layer array to look up**. If this host has RAID at all it is in the OS layer (see the md / ZFS / LVM sections above); for the health of the disks themselves see SMART below.\n'
    printf -- '- _One case this cannot rule out: a **boot mirror on a small add-in card** (Dell BOSS, some Marvell / on-board SATA RAID) shows up as a plain `SATA controller` and its CLI (`mvcli`) is rarely installed. If this machine has one, its state has to come from the BMC_\n'
  fi
else
  kv "Vendor CLI" "\`$RCLI\`"
  # 一律只用 show / display / info / GETCONFIG 這類「讀」的子指令,不下 set / start / rebuild。
  # RCLI_PD_CMD:這支 CLI 的預設查詢**不含實體碟狀態**時填「還要另外跑什麼」——
  # 「哪顆碟壞了」是這一段存在的理由,沒查到就要明寫,不能只貼一份看不出來的 LD 輸出。
  RCLI_PD_CMD=""
  case "$(basename "$RCLI")" in
    storcli*|perccli*)  RCLI_CMD="$RCLI /c0 show" ;;             # 一頁含 controller + VD + PD 狀態
    MegaCli*|megacli)   RCLI_CMD="$RCLI -LDInfo -Lall -aALL"; RCLI_PD_CMD="$RCLI -PDList -aALL" ;;
    ssacli|hpssacli|hpacucli) RCLI_CMD="$RCLI ctrl all show config" ;;   # config 已含 physicaldrive 狀態
    arcconf)            RCLI_CMD="$RCLI GETCONFIG 1 LD"; RCLI_PD_CMD="$RCLI GETCONFIG 1 PD" ;;
    sas3ircu|sas2ircu)  RCLI_CMD="$RCLI 0 DISPLAY" ;;            # DISPLAY 已含 physical device 清單
    tw_cli)             RCLI_CMD="$RCLI info"; RCLI_PD_CMD="$RCLI info c0" ;;
    mvcli)              RCLI_CMD="$RCLI info -o vd"; RCLI_PD_CMD="$RCLI info -o pd" ;;
    cli64)              RCLI_CMD="$RCLI vsf info"; RCLI_PD_CMD="$RCLI disk info" ;;
    *)                  RCLI_CMD="" ;;
  esac
  if [ -z "$RCLI_CMD" ]; then
    note "this CLI is recognised but there is no matching read-only query command for it; run it by hand"
  elif sudo_ready; then
    # shellcheck disable=SC2086
    RCLI_OUT="$(sq $RCLI_CMD 2>/dev/null)"
    if [ -n "$RCLI_OUT" ]; then
      printf -- '- Read-only query: `%s`\n' "$RCLI_CMD"
      # `storcli /c0 show` 約 175 行、最有價值的 PD LIST 在後段(舊版 head -150 正好切掉)。
      # 先解析摘要(對應站頁模板 C2:陣列 / level / 成員碟 / 狀態)再貼原文;只解析 storcli / perccli。
      case "$(basename "$RCLI")" in
        storcli*|perccli*)
          printf '%s\n' "$RCLI_OUT" | awk -v cli="$(basename "$RCLI")" '
            /^Product Name/     { sub(/^[^=]*= */, ""); prod = $0 }
            /^FW Package Build/ { sub(/^[^=]*= */, ""); fw = $0 }
            /^Virtual Drives/   { sub(/^[^=]*= */, ""); nvd = $0 }
            /^Physical Drives/  { sub(/^[^=]*= */, ""); npd = $0 }
            # VD LIST 資料列:`0/0   RAID6 Optl  RW  Yes  RWTD  -  ON  229.188 TB`
            /^[0-9]+\/[0-9]+[ \t]/ {
              vd = vd sprintf("%s %s **%s** cache %s %s %s;  ", $1, $2, $3, $6, $9, $10)
              if ($3 != "Optl") badvd = badvd " " $1 "(" $3 ")"
              # Cache 欄含 WT = 寫入快取是 WriteThrough。可能是刻意設定,也可能是 BBU 掛了自動掉回來——
              # 這一頁看不到 BBU,所以只陳述事實與「這頁看不到什麼」,不判斷對錯。
              if (index($6, "WT") > 0) wt = wt " " $1
            }
            # PD LIST 資料列:`8:0  55 Onln  0 16.370 TB SAS HDD N N 512B ST18000NM004J U -`
            /^[0-9]+:[0-9]+[ \t]/ {
              pn++; st[$3]++
              if (model == "") { model = $12; psz = $5 " " $6; intf = $7 " " $8 }
              # Onln=在陣列中、GHS/DHS=熱備、UGood=未配置但健康;其餘(Failed/Offln/UBad/Msng/Rbld)都要點名
              if ($3 != "Onln" && $3 != "GHS" && $3 != "DHS" && $3 != "UGood") badpd = badpd " " $1 "(" $3 ")"
            }
            END {
              if (prod != "") printf "- **Controller**: %s (FW %s)\n", prod, fw
              if (vd != "") { sub(/;  $/, "", vd); printf "- **Arrays (VD)**: %s -- %s\n", nvd, vd }
              if (pn > 0) {
                s = ""
                for (k in st) s = s sprintf("%s %d / ", k, st[k])
                sub(/ \/ $/, "", s)
                printf "- **Physical disks behind the controller**: **%s** (%s) -- %s %s %s\n", (npd == "" ? pn : npd), s, model, psz, intf
                # 表頭顆數與表列行數不一致 = 輸出被截或版面不同,要讓人知道別採信其中一個
                if (npd != "" && npd + 0 != pn)
                  printf "- _The header says %s disks but the table only has %d rows, which is inconsistent -- run the command above by hand to confirm_\n", npd, pn
              }
              if (wt != "")
                printf "- _Write cache is **WriteThrough** on VD%s (`WT` in the cache column). That can be by design, or what a dead BBU / CacheVault falls back to -- **BBU state is not on this page**: `%s /c0/bbu show`_\n", wt, cli
              if (badvd != "" || badpd != "")
                printf "- **Abnormal:%s%s** -- this needs attention immediately\n", (badvd == "" ? "" : " VD" badvd), (badpd == "" ? "" : " PD" badpd)
              else if (vd != "" || pn > 0) {
                # 「異常:無」比這頁的資料撐得起的結論強:media error / predictive failure / BBU 都不在這頁,
                # 一顆即將壞掉的碟狀態仍是 Onln。要把界線講清楚,不然這行會被當成完整健檢結果。
                printf "- **Abnormal**: none **in what this query reports** (every VD is Optl, every PD is Onln or a hot spare)\n"
                printf "- _Not a full health verdict: this page has **no per-disk media / predictive-failure counters and no BBU state**. For those run `%s /c0/eall/sall show all` and `%s /c0/bbu show`_\n", cli, cli
              }
            }
          '
          printf -- '- _The `Disks visible to the OS` row is a count of virtual disks; **the count here is the number of physical disks**_\n' ;;
        *)
          # 沒有解析器就只剩原文,而且好幾支 CLI 的預設查詢根本不含 PD —— 缺口要明寫,不能靜默。
          printf -- '- _No parsed summary for this CLI (only storcli / perccli output is parsed), so the raw output below is all there is -- **read the VD state and the disk count out of it by hand**_\n'
          if [ -n "$RCLI_PD_CMD" ]; then
            printf -- '- **The query above does not include physical-disk state**: how many disks are behind the controller, and whether one of them failed, is **not** in the output below. Run this as well (read-only): `sudo %s`\n' "$RCLI_PD_CMD"
          fi ;;
      esac
      # 原文照貼,但砍掉 legend 區塊(`DG=Disk Group Index|Arr=...` 這類說明佔了快 40 行)
      RCLI_BODY="$(printf '%s\n' "$RCLI_OUT" |
        grep -vE '^[A-Za-z][A-Za-z0-9 ]*=.*\|' | grep -v '^Check Consistency$' |
        grep -v 'Generating detailed summary' | cat -s)"
      printf '```\n%s\n```\n' "$(printf '%s\n' "$RCLI_BODY" | head -200)"
      # 有截斷就要說(不然讀者會以為這就是全部)
      [ "$(printf '%s\n' "$RCLI_BODY" | wc -l | tr -d ' ')" -gt 200 ] &&
        printf -- '- _(Output was long, only the first 200 lines are kept; run the command above on the site for the full text. The legend block has been cut)_\n'
      printf -- '- _State reference: VD `Optl`=healthy / `Dgrd`=missing a disk / `Pdgd`=partially degraded; PD `Onln`=in the array / `GHS`=global hot spare / `UGood`=unconfigured / `Failed`,`Offln`,`Msng`=replace / `Rbld`=rebuilding_\n'
    else
      note "$RCLI returned nothing (it may be the wrong tool for this card, or this host has no RAID controller)"
      # 有卡卻問不出東西 = 真的缺一段,不是「這台沒有」。
      { [ "$HW_RAID_HINT" = "1" ] || [ "$HW_CTL_RAID" = "1" ]; } && bmc_raid_todo
    fi
  else
    # sudo 已內建,「沒查到」只剩一個原因 —— 這次拿不到 root,把原因直接印出來。
    printf -- '- _**A CLI exists but root was not available this run, so array state was not queried.** Reason: %s. Run this by hand on that host (read-only):_\n' "${SUDO_NOTE:-not determined}"
    printf '```\nsudo %s\n```\n' "$RCLI_CMD"
    if [ -n "$RCLI_PD_CMD" ]; then
      printf -- '- _That query does not include physical-disk state, so also run:_ `sudo %s`\n' "$RCLI_PD_CMD"
    fi
    # 這是實務上最常走到的分支(客戶站多半拿不到 root),所以要留下可人工補齊的欄位清單,
    # 而不是讓站頁 C2 空著。
    bmc_raid_todo
  fi
fi
# SMART 刻意只取整體判定:通電時數 / 重配置磁區 / 壽命% 屬監控指標,每顆碟一份也會淹掉報告。
printf '<!--SEC:hw.smart-->\n### Disk health (SMART, overall verdict only)\n'
# VM 上這段不適用:虛擬碟沒有實體 SMART。而且**雲端沒有 BMC**,不能照抄「走 BMC」那句。
IS_VM=0
{ [ -n "$VIRT" ] && [ "$VIRT" != "none" ]; } && IS_VM=1
if [ "$IS_VM" = "1" ]; then
  case "$VIRT" in
    amazon|gce|azure|oracle|alibaba)
      printf -- '- **Not applicable**: this is a cloud VM (`%s`) and the disks are cloud network block storage, so **there is no physical-disk SMART to read and no BMC**. The underlying disks are the cloud provider responsibility; they replace failed disks, and we can neither see nor need to see it.\n' "$VIRT" ;;
    *)
      printf -- '- **Not applicable**: this is a virtual machine (`%s`) and the disks are virtual disks from the hypervisor, so **a guest cannot read the SMART of a physical disk** (even with smartmontools installed, what it reads is not the health of a physical disk). Physical disk health has to be read on the hypervisor / storage appliance side; ask the customer virtualization admin.\n' "$VIRT" ;;
  esac
elif ! have smartctl; then
  printf -- '- No `smartctl` (smartmontools is not installed), so **disk health cannot be measured on this host**; to see it, go through the BMC or ask the customer to install smartmontools\n'
  # 碟在 RAID 控制器後面時,smartctl 本來也要靠 -d megaraid,N 才問得到,所以廠商 CLI 是更直接的路
  [ "$HW_RAID_HINT" = "1" ] || [ "$HW_CTL_RAID" = "1" ] &&
    printf -- '- _The disks on this host sit behind a RAID controller, so even with smartmontools installed it needs `-d megaraid,N`. **Reading PD state from the vendor CLI above is more direct**_\n'
elif ! sudo_ready; then
  printf -- '- `smartctl` exists, but SMART needs root and **that was not available this run, so it is skipped**. Reason: %s\n' "${SUDO_NOTE:-not determined}"
  printf -- '- _If the reason is "the script was fed via stdin" (`bash -s < script` / `curl | bash`), that way of running never asks for a password (sudo competes with the script for the same stdin). Put the script on the host and run it there and it will ask: `bash %s`_\n' "$SCRIPT_NAME"
else
  # 裝置清單優先用 --scan-open:控制器後面的碟要 `-d megaraid,N` 才問得到,手寫 /dev/sdX 問不到。
  SMDEV="$(sq smartctl --scan-open 2>/dev/null | sed 's/#.*//; s/[[:space:]]*$//' | grep -v '^$')"
  SMSRC="smartctl --scan-open"
  if [ -z "$SMDEV" ]; then
    SMDEV="$(printf '%s\n' "$DISKROWS" | awk 'NF{print "/dev/"$1}')"
    SMSRC="physical disk list from lsblk (--scan-open found nothing)"
  fi
  if [ -z "$SMDEV" ]; then
    note "no queryable disk found"
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
        _res="not measurable ($(printf '%s\n' "$_out" | grep -iE 'unable|unknown|failed|permission|not supported|Open failed' | head -1 | cut -c1-56))"
      fi
      printf '%-34s %s\n' "$_d" "$_res"
    done
    printf '```\n'
    kv "Device list source" "$SMSRC"
    printf -- '- PASSED / OK = the disk reports itself fine; **FAILED = arrange a replacement immediately**. "not measurable" usually means the disk is behind a RAID controller and `--scan-open` did not list it -- go through the BMC or the vendor CLI above.\n'
    printf -- '- _Power-on hours / reallocated sectors / NVMe life%% are deliberately not collected (those are monitoring metrics, not an environment record)_\n'
  fi
fi
# 反過來:「這台把資料分享給誰」。samba 不屬於 aetherSlide(compose 沒有 SMB server),
# 有的話一定是站台自建或客戶 IT 推的 —— 只列分享名與 path,不判斷用途,密碼類鍵不抓。
printf '<!--SEC:share.samba-->\n### Directories this host shares out (samba)\n'
SMBCONF=/etc/samba/smb.conf
if [ ! -f "$SMBCONF" ]; then
  printf -- '- No `%s` (samba is not installed here, or sharing is done another way)\n' "$SMBCONF"
elif [ ! -r "$SMBCONF" ]; then
  note "$SMBCONF exists but cannot be read (needs root)"
else
  SMBSHARES="$(awk '
    function flush() {
      if (name != "" && tolower(name) != "global")
        printf "%-24s %s\n", name, (path == "" ? "(no path set)" : path)
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
    printf -- '- The full share definitions (`valid users` / `hosts allow` / read-only or not) are in `%s`; read them by hand when needed\n' "$SMBCONF"
  else
    printf -- '- `%s` exists but has no share section other than `[global]`\n' "$SMBCONF"
  fi
fi
# 同一類的另一半:這台當 NFS server 分享出去的目錄。
# `exportfs -s` 要 root,所以讀設定檔:/etc/exports 加 /etc/exports.d/*.exports。
printf '<!--SEC:share.nfs_export-->\n### Directories this host shares out (NFS export)\n'
EXPFILES=""
[ -f /etc/exports ] && EXPFILES="/etc/exports"
for _e in /etc/exports.d/*.exports; do [ -f "$_e" ] && EXPFILES="$EXPFILES $_e"; done
if [ -z "$EXPFILES" ]; then
  printf -- '- No `/etc/exports` (this host is not an NFS server)\n'
else
  EXPLINES=""
  for _e in $EXPFILES; do
    if [ -r "$_e" ]; then
      _l="$(grep -vE '^[[:space:]]*(#|$)' "$_e" 2>/dev/null)"
      [ -n "$_l" ] && EXPLINES="$EXPLINES$_l
"
    else
      note "$_e exists but cannot be read (needs root)"
    fi
  done
  if [ -n "$EXPLINES" ]; then
    printf '```\n%s```\n' "$EXPLINES"
    printf -- '- Source file: `%s`. The line format is `path client(options)`; authorization details such as `rw` / `no_root_squash` are listed as-is, not interpreted\n' "$EXPFILES"
    # 有 nfsd 在跑但 exports 是空的 = 裝了沒用,跟「沒裝」是兩件事
  else
    printf -- '- `%s` exists but has no valid export line (comments or blank lines only)\n' "$EXPFILES"
  fi
fi
if [ -d /proc/fs/nfsd ]; then
  printf -- '- **This host has `/proc/fs/nfsd`** (`nfs-kernel-server` is installed); whether it actually serves anything depends on the export list above\n'
fi

# ── 5. 執行中的 aetherSlide ──────
# 整節用 HAS_AS 包起來:AI 推論主機常沒有 aetherSlide,照印空欄位會像「裝了但全掛了」。
sec app "5. Running aetherSlide"
if [ "$HAS_AS" = "0" ]; then
  note "no aetherSlide deployment on this host (no configs.env / .env under $DEPLOY_DIR); this section is skipped"
  note "if it is deployed elsewhere, pass the path as the first argument: bash collect_site_config.sh /path/to/website"
else
  kv "Deploy directory" "$DEPLOY_DIR"
  # .env 的 TAG 是「設定要跑哪版」,實際 image tag 是「現在真的在跑哪版」;不一致 = 改了沒重建。
  kv "aetherSlide version TAG (configured)" "$(envval "$DEPLOY_DIR/.env" TAG)"
  if have docker; then
    # 只看自家 registry 的 image;redis 等第三方 image 的 tag 不是 aetherSlide 版本
    RUNNING_TAG="$(docker ps --format '{{.Image}}' 2>/dev/null | grep -i aetherai |
      sed -n 's/.*:\([^:]*\)$/\1/p' | sort -u | paste -sd ', ' -)"
    if [ -z "$RUNNING_TAG" ] && docker ps -q 2>/dev/null | grep -q .; then
      RUNNING_TAG="$(docker ps --format '{{.Image}}' 2>/dev/null | sed -n 's/.*:\([^:]*\)$/\1/p' | sort -u | paste -sd ', ' -)(not our registry, please confirm)"
    fi
    kv "image tag actually running" "${RUNNING_TAG:-(no running container)}"
  fi
  kv "SITE_NAME" "$(envval "$DEPLOY_DIR/configs.env" SITE_NAME)"
  kv "MODULES (enabled feature modules)" "$(envval "$DEPLOY_DIR/configs.env" MODULES)"
  kv "WEB_NETWORK_LOCATION (public URL)" "$(envval "$DEPLOY_DIR/configs.env" WEB_NETWORK_LOCATION)"
  printf '<!--SEC:app.config_files-->\n### Config files present\n'
  for f in configs.env prefs.env .env configs.yaml tier_configs.yaml model-config; do
    if [ -e "$DEPLOY_DIR/$f" ]; then kv "$f" "present"; else kv "$f" "(absent)"; fi
  done
  [ -d "$DEPLOY_DIR/secrets" ] && kv "secrets/" "present (directory)"
  # 站台有幾十個容器,不健康的會混在清單裡看不到,所以先單獨拉出來當警示
  if have docker; then
    BAD="$(docker ps --format '{{.Names}}\t{{.Status}}' 2>/dev/null |
      grep -iE 'restarting|unhealthy|health: starting|created|paused')"
    printf '<!--SEC:app.containers_unhealthy-->\n### Containers in an abnormal state (read this first)\n'
    if [ -n "$BAD" ]; then
      printf '```\n%s\n```\n' "$BAD"
      printf -- '- _Restarting / unhealthy means this service is broken right now; ask why during handover_\n'
    else
      printf -- '- No container in an abnormal state\n'
    fi
  fi
  printf '<!--SEC:app.containers_running-->\n### Running containers (name / image / status / published ports)\n```\n'
  if have docker; then
    docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || note "docker ps failed (permissions?)"
  else note "no docker"; fi
  printf '```\n'
  # 只列最近 15 個。Exited (0) 多半是 init / volume 準備之類的一次性容器,屬正常
  if have docker; then
    STOPPED="$(docker ps -a --filter 'status=exited' --filter 'status=dead' \
      --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null | head -15)"
    printf '<!--SEC:app.containers_stopped-->\n### Stopped containers (Exited 0 is usually a one-shot init; only non-zero needs following up)\n'
    if [ -n "$STOPPED" ]; then printf '```\n%s\n```\n' "$STOPPED"; else printf -- '- None\n'; fi
  fi
fi

# ── 6. 時間與排程 ──────
sec sched "6. Time and scheduling"
if have timedatectl; then
  kv "Timezone / NTP" "$(timedatectl 2>/dev/null | tr -s ' ' | grep -E 'Time zone|NTP' | paste -sd '; ' -)"
else
  kv "Time / timezone" "$(date 2>/dev/null)"
fi
printf '<!--SEC:sched.crontab-->\n### User crontab\n```\n'
crontab -l 2>/dev/null || printf '(no crontab, or it cannot be read)\n'
printf '```\n'
if have systemctl; then
  # 白名單含 smb/nmb/winbind/nfs-server(不屬 aetherSlide 但常在分享它的資料)與
  # smartd/mdmonitor/zed/multipathd(「碟壞了有沒有人被通知」跟「碟好不好」是兩件事)。
  UNITS="$(systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null \
    | grep -iE 'docker|compose|aetherslide|website|microk8s|kubelet|containerd|smbd|nmbd|winbind|nfs-server|smartd|mdmonitor|zed|multipathd' | awk '{print $1}')"
  printf '<!--SEC:sched.services-->\n### Related systemd services\n'
  if [ -n "$UNITS" ]; then printf '```\n%s\n```\n' "$UNITS"; else printf -- '- None (it may have been started by hand with `bin/dc up`)\n'; fi
  # 濾掉每台 Ubuntu 都有的 OS 預設 timer,只留這台自己加的
  TIMERS="$(systemctl list-timers --all --no-pager --no-legend 2>/dev/null \
    | grep -vE 'fwupd|man-db|logrotate|motd-news|dpkg-db-backup|systemd-tmpfiles|update-notifier|fstrim|sysstat|apt-daily|e2scrub|snapd|ua-timer|ubuntu-advantage|anacron|plocate|mlocate|apport')"
  printf '<!--SEC:sched.timers-->\n### systemd timers (OS defaults filtered out; only what this host added)\n'
  if [ -n "$TIMERS" ]; then printf '```\n%s\n```\n' "$TIMERS"; else printf -- '- None\n'; fi
fi

# ── 7. GPU node / AI Landing(AI 推論主機)──────
# microk8s + helm,不是 docker compose,所以整段是另一套指令。不自動 SSH 過去。
sec ai "7. GPU node / AI Landing (AI inference)"
if [ "$HAS_AIL" = "0" ]; then
  note "no AI Landing on this host (no values.yaml in a deploy directory and no $AIL_NS namespace)"
  if [ -n "${AIL_URL:-}" ]; then
    # 只比對 host 部分;URL 可能帶 port 或走 FQDN
    AIL_HOST="$(printf '%s' "$AIL_URL" | sed -E 's#^[a-zA-Z]+://##; s#[:/].*$##')"
    if has_ip "$AIL_HOST"; then
      kv "AI_LANDING_URL points to" "$AIL_URL (an IP of this host, but no AI Landing was detected here -> confirm by hand)"
    else
      kv "AI_LANDING_URL points to" "$AIL_URL (**not this host**, inference runs elsewhere)"
      printf -- '- _Run this script on that host as well (it needs its own paste), and put its sections 1-7 into the "GPU node" part of M-machine on the site page:_\n'
      printf '```\nbash collect.sh\n```\n'
      printf -- '- _For an FQDN the real IP is decided by customer DNS/NAT; confirm by hand which host it resolves to_\n'
    fi
  else
    note "this host has no aetherSlide AI_LANDING_URL to go by either, so the inference host cannot be located"
  fi
else
  kv "Deploy directory" "${AIL_DIR:-(not found; the namespace exists but the directory is not in the default path -- pass --ai-landing-dir)}"
  kv "namespace" "$AIL_NS"
  if [ -z "$KCTL" ]; then
    note "a deploy directory exists but kubectl / microk8s kubectl cannot reach the cluster (permissions? cluster down?); only config file contents are listed below"
  else
    kv "k8s command" "$KCTL"
    have microk8s && kv "MicroK8s version" "$(microk8s version 2>/dev/null | head -1)"
  fi

  # ── 版本:三個來源要並列 ──
  # helm appVersion(CI build 會變成 0.0.0-<sha>)、Chart.yaml、image tag 三者常不同,只抓一個會誤導。
  printf '<!--SEC:ai.versions-->\n### Versions (three sources; they commonly disagree, read them together)\n'
  kv "Chart.yaml appVersion (deploy dir)" "$(yamlval "$AIL_DIR/charts/ai-landing/Chart.yaml" '^appVersion:')"
  if [ -n "$HELM" ]; then
    HELM_OUT="$($HELM list -A 2>/dev/null)"
    if [ -n "$HELM_OUT" ]; then
      printf '```\n%s\n```\n' "$HELM_OUT"
    else
      note "helm list found no release (permissions?)"
    fi
  else
    note "no helm"
  fi
  IMGS="$(kctl get deploy -n "$AIL_NS" -o 'custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[*].image' --no-headers)"
  if [ -n "$IMGS" ]; then
    printf '<!--SEC:ai.core_images-->\n### Core service images (versions actually running)\n```\n%s\n```\n' "$IMGS"
  fi

  # ── values.yaml:逐鍵取值,密碼類鍵一律不查(同 configs.env 的原則)──
  if [ -f "$AIL_DIR/values.yaml" ]; then
    printf '<!--SEC:ai.values-->\n### values.yaml (non-secret keys; adminPassword / SECRET_KEY / *_PASS are deliberately not collected)\n'
    kv "external_ip" "$(yamlval "$AIL_DIR/values.yaml" '^external_ip:')"
    kv "port" "$(yamlval "$AIL_DIR/values.yaml" '^port:')"
    kv "image registry" "$(yamlval "$AIL_DIR/values.yaml" '^[[:space:]]+host:')/$(yamlval "$AIL_DIR/values.yaml" '^[[:space:]]+repository:')"
    kv "backend image_tag" "$(yamlval "$AIL_DIR/values.yaml" '^[[:space:]]+image_tag:')"
    kv "DJANGO_ALLOWED_HOSTS" "$(yamlval "$AIL_DIR/values.yaml" 'DJANGO_ALLOWED_HOSTS:')"
    kv "DJANGO_DEBUG" "$(yamlval "$AIL_DIR/values.yaml" 'DJANGO_DEBUG:')"
    kv "BACKEND_URL_PREFIX" "$(yamlval "$AIL_DIR/values.yaml" 'BACKEND_URL_PREFIX:')"
    kv "BACKEND_JOB_TTL_DAYS_AFTER_FINISHED" "$(yamlval "$AIL_DIR/values.yaml" 'BACKEND_JOB_TTL_DAYS_AFTER_FINISHED:') (job retention in days -- it decides how far back the statistics below can see)"
    kv "UWSGI_PROCESS_NUMBER" "$(yamlval "$AIL_DIR/values.yaml" 'UWSGI_PROCESS_NUMBER:')"
    kv "backend logs storage_class" "$(yamlval "$AIL_DIR/values.yaml" '^[[:space:]]+storage_class:')"
    kv "database volumeSize" "$(yamlval "$AIL_DIR/values.yaml" '^[[:space:]]+volumeSize:')"
  else
    note "cannot find $AIL_DIR/values.yaml"
  fi

  # ── 對外端點 ──
  # 8500 是 svc/ingress 的 externalIPs,由 kube-proxy iptables 轉;主機上沒有 listening socket。
  if [ -n "$KCTL" ]; then
    printf '<!--SEC:ai.endpoint-->\n### Public endpoint (externalIPs have no listening socket, so ss cannot see them -- only k8s can answer)\n'
    ING_SVC="$(kctl get svc -A --no-headers -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.type,EXTIP:.spec.externalIPs[*],PORT:.spec.ports[*].port' | awk '$4!="<none>"')"
    if [ -n "$ING_SVC" ]; then printf '```\n%s\n```\n' "$ING_SVC"; else note "no service carries externalIPs"; fi
    NP_SVC="$(kctl get svc -A --no-headers -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.type,NODEPORT:.spec.ports[*].nodePort' | awk '$3=="NodePort"')"
    printf '<!--SEC:ai.endpoint.nodeport-->\n#### NodePort service\n'
    if [ -n "$NP_SVC" ]; then printf '```\n%s\n```\n' "$NP_SVC"; else printf -- '- None\n'; fi
    ING="$(kctl get ingress -A --no-headers)"
    printf '<!--SEC:ai.endpoint.ingress-->\n#### Ingress\n'
    if [ -n "$ING" ]; then printf '```\n%s\n```\n' "$ING"; else printf -- '- None\n'; fi
  fi

  # ── 叢集節點與 GPU 配置 ──
  if [ -n "$KCTL" ]; then
    printf '<!--SEC:ai.nodes-->\n### Cluster nodes\n```\n'
    kctl get nodes --no-headers -o 'custom-columns=NAME:.metadata.name,ROLES:.metadata.labels.node-role,VER:.status.nodeInfo.kubeletVersion,IP:.status.addresses[0].address,GPU:.status.capacity.nvidia\.com/gpu,RUNTIME:.status.nodeInfo.containerRuntimeVersion'
    printf '```\n'
    NODE_N="$(kctl get nodes --no-headers | wc -l | tr -d ' ')"
    kv "Node count" "${NODE_N:-unknown} (1 = single node, >1 means workers were added)"
    # 實體 GPU 數 vs k8s 看到的 GPU 數:不一致就是 time-slicing 在切
    PHYS_GPU="$(nvidia-smi -L 2>/dev/null | grep -c GPU)"
    K8S_GPU="$(kctl get nodes -o 'custom-columns=G:.status.capacity.nvidia\.com/gpu' --no-headers | awk '$1 ~ /^[0-9]+$/ {s+=$1} END{print s+0}')"
    kv "Physical GPUs (nvidia-smi)" "${PHYS_GPU:-0}"
    kv "GPUs allocatable in k8s (capacity)" "${K8S_GPU:-0} (greater than the physical count = time-slicing is on)"
    TS="$(kctl get cm -A --no-headers | grep -i time-slicing)"
    printf '<!--SEC:ai.timeslicing-->\n#### time-slicing configmap\n'
    if [ -n "$TS" ]; then printf '```\n%s\n```\n' "$TS"; else printf -- '- None (time-slicing not configured)\n'; fi
  fi

  # ── pod 狀態 ──
  # 推論 job 留下的 pod 可達上千個(實測 1369)→ 依 ownerReferences 拆:Job 只給統計,其餘逐一列。
  if [ -n "$KCTL" ]; then
    PODS="$(kctl get pods -n "$AIL_NS" --no-headers -o 'custom-columns=OWNER:.metadata.ownerReferences[*].kind,NAME:.metadata.name,PHASE:.status.phase,REASON:.status.reason,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount')"
    CORE="$(printf '%s\n' "$PODS" | awk '$1!="Job"')"
    printf '<!--SEC:ai.pods-->\n### Core pods (inference job pods excluded)\n'
    if [ -n "$CORE" ]; then printf '```\n%s\n```\n' "$CORE"; else note "no pod found"; fi
    BADP="$(printf '%s\n' "$CORE" | awk '$3!="Running" && $3!="Succeeded" || $5 ~ /false/')"
    printf '<!--SEC:ai.pods_unhealthy-->\n#### Core pods in an abnormal state (read this first)\n'
    if [ -n "$BADP" ]; then
      printf '```\n%s\n```\n' "$BADP"
      printf -- '- _Ask why during handover_\n'
    else
      printf -- '- None\n'
    fi
    printf '<!--SEC:ai.jobs_stats-->\n#### Inference job statistics (bounded by BACKEND_JOB_TTL_DAYS_AFTER_FINISHED -- only jobs inside the retention window are visible)\n'
    JOB_N="$(kctl get jobs -n "$AIL_NS" --no-headers | wc -l | tr -d ' ')"
    kv "Total jobs" "${JOB_N:-0}"
    printf '```\n%s\n```\n' "$(printf '%s\n' "$PODS" | awk '$1=="Job"{print $3" "$4}' | sort | uniq -c | sort -rn)"
    # 模板「AI model 版本」那格唯一的來源。會混進 prometheus / grafana 等基礎設施 image,
    # 所以先只留 /ai-app/;一個都沒命中就退回列全部並註明。
    ALL_IMG="$(kctl get pods -n "$AIL_NS" --no-headers -o 'custom-columns=IMG:.spec.containers[*].image' |
      tr ',' '\n' | sed 's/^ *//' | grep -v '^$')"
    APP_IMG="$(printf '%s\n' "$ALL_IMG" | grep '/ai-app/' | sort | uniq -c | sort -rn)"
    printf '<!--SEC:ai.app_images-->\n#### AI app images run inside the retention window (count / image)\n'
    if [ -n "$APP_IMG" ]; then
      printf '```\n%s\n```\n' "$APP_IMG"
    else
      printf -- '- _No image has an `/ai-app/` path, so all images are listed instead (infrastructure images included -- tell them apart yourself)_\n'
      printf '```\n%s\n```\n' "$(printf '%s\n' "$ALL_IMG" | sort | uniq -c | sort -rn)"
    fi
    printf -- '_This is "was run", not "is installed"; an app that was never called does not appear_\n'
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
    kv "aetherSlide CA certificate file" "$CA (contains $(grep -c 'BEGIN CERTIFICATE' "$CA" 2>/dev/null) certificate(s); several are concatenated when multiple sites share one inference host)"
  else
    note "cannot find ca-cert.internal.pem (used by k8s_init.sh for registration); registered certificates live in the cluster, so a missing file does not mean nothing was registered"
  fi
  printf -- '_Which aetherSlide sites connect to this host, who bought the GPU and holds its warranty, and who updates the models cannot be seen from configuration -- fill those in by hand_\n'
fi

# ── 8. 對接與整合設定(從 configs.env 讀,不含任何密碼類鍵)──────
# 屬 M-config 層,貼到站頁的「對接(整合)」。
sec integ "8. Integrations (-> paste into the Integrations part of M-config)"
# DICOM / HL7 等鍵沒用到也有預設值:模組沒列在 MODULES 裡就代表服務沒起、設定不生效。
MODULES_VAL="$(envval "$DEPLOY_DIR/configs.env" MODULES | tr -d ' ')"
mod_off() {   # 模組不在 MODULES 裡就回傳提示字串
  if printf '%s' ",$MODULES_VAL," | grep -q ",$1,"; then printf ''
  else printf '(module %s is not enabled, so this setting has no effect)' "$1"; fi
}
if [ -f "$DEPLOY_DIR/configs.env" ]; then
  kv "Enabled MODULES" "${MODULES_VAL:-(empty)}"
  kv "DICOM AE Title" "$(envval "$DEPLOY_DIR/configs.env" WEB_DICOM_SCP__AE_TITLE)$(mod_off dicom)"
  kv "DICOM SCP user" "$(envval "$DEPLOY_DIR/configs.env" WEB_BACKEND__DICOM_SCP_USER)$(mod_off dicom)"
  kv "HL7v2 message codec" "$(envval "$DEPLOY_DIR/configs.env" WEB_HL7V2_SERVER__MESSAGE_CODEC)$(mod_off hl7v2)"
  kv "LDAP integration" "$(envval "$DEPLOY_DIR/configs.env" WEB_BACKEND__LDAP_INTEGRATION)(1=on)"
  kv "LDAP server" "$(envval "$DEPLOY_DIR/configs.env" WEB_BACKEND__LDAP_SERVER_URL)"
  kv "LDAP bind domain" "$(envval "$DEPLOY_DIR/configs.env" WEB_BACKEND__LDAP_BIND_DOMAIN)"
  kv "aetherAI LDAP login" "$(envval "$DEPLOY_DIR/configs.env" WEB_BACKEND__ENABLE_AETHERAI_LDAP_LOGIN)(1=on)"
  kv "AUTO_IMPORT" "$(envval "$DEPLOY_DIR/configs.env" AUTO_IMPORT_ENABLED)(1=on), path $(envval "$DEPLOY_DIR/configs.env" AUTO_IMPORT_PATH)$(mod_off auto-import)"
  kv "Tiered storage GIGASTORE_ENABLE_TIERING" "$(envval "$DEPLOY_DIR/configs.env" GIGASTORE_ENABLE_TIERING)(1=on)"
  kv "Export path" "$(envval "$DEPLOY_DIR/configs.env" WEB_BACKEND__EXPORT_PATH)"
  kv "Convert NDPI to DICOM on import" "$(envval "$DEPLOY_DIR/configs.env" WEB_BACKEND__CONVERT_NDPI_TO_DICOM_ON_IMPORT)(1=on)"
  # AI 推論去向。註解掉時走程式預設(舊版預設是已廢棄的 FQDN),「沒這行」不等於「沒有 AI 推論」。
  kv "AI_LANDING_URL (inference endpoint)" "${AIL_URL:-(not set / commented out -> the program default applies; look up the default for that version)}"
  printf -- '_Scanner models, the PACS / LIS / HIS counterparts and their IP and port still have to be filled in by hand (configuration does not show them)_\n'
else
  note "cannot read $DEPLOY_DIR/configs.env"
fi

# ── 9. 另一個節點(dual)──────
# 只提醒「有另一台、是哪一台」:不自動連過去,跑法也不印在報告裡(要指令就用 --peer)。
if [ "$ARCH" = "dual" ]; then
  sec peer "9. The other node"
  if [ -n "$PEER_IP" ]; then
    kv "Peer node" "$PEER_IP$([ -n "$NODE_SELF" ] && printf '(this host is %s)' "$NODE_SELF")"
    printf -- '- That host has to be captured separately; for the command run `bash %s --peer <user>@%s` (it only prints the command, it does not capture this host)\n' \
      "$SCRIPT_NAME" "$PEER_IP"
  else
    if [ -n "$NODE_1_IP$NODE_2_IP" ]; then
      note "**this host is neither node of the dual pair** (its IPs are not on NODE_1_IP=${NODE_1_IP:-unset} / NODE_2_IP=${NODE_2_IP:-unset}) -- it is most likely a witness / ES or another role host; the two dual nodes each need their own run"
    else
      note "dual architecture, but .env has no NODE_1_IP / NODE_2_IP, so the two nodes of this site cannot be derived -- confirm by hand"
    fi
  fi
fi

printf '\n---\n_Capture complete. Fields that need a human (who the integration counterpart is, contact windows, and so on) are not in this output; they belong to the H layer of the site page._\n'
printf '\n===== END OF COPY =====\n' >&2

exit 0
