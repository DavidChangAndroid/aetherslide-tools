#!/usr/bin/env bash
# =============================================================================
# fae_bashrc  (v0.2)  — the standardized FAE ~/.bashrc, now with recording
#
# FAE on-site shell environment for hospital production machines. This file IS
# the machine's ~/.bashrc: deploy by REPLACING ~/.bashrc with it, so every FAE
# machine runs one identical, unified shell environment.
#
#     cp fae_bashrc ~/.bashrc     # (back up the old one first if it matters)
#
# v0.2 wires up terminal recording (merged from 專案錄影/install_recorder v5)
# on top of v0.1's operator features + crash-proof log-lifecycle engine:
#   [1]  Environment banner + colour-coded prompt (prod=red; override-able)
#   [4]  vi/vim/nano edit tracking (backup -> [IR-BEFORE]/[IR-DIFF]/[IR-AFTER])
#   [12] History hardening (unlimited, timestamped, written immediately)
#   REC  `script` recording auto-started at login, finalized as housekeeping,
#        with ssh/su/sudo wrappers injected across hops so vi edits stay tracked.
#
# Design rationale & decisions: context/02-v0.2-錄影整併設計.md
#
# Capture model (consumer is an AI that reads the logs to draft SOPs, so the
# bar is "is the content on disk", not "is it structured"):
#   - Layer 1 (raw `script`): records the WHOLE screen -> nothing is missed.
#   - Layer 2 ([IR-*] wrappers): clean before/after/diff for named-file edits,
#     carried across ssh/su/sudo by payload injection.
#   - Snapshot (GAP1-B): redirect writes (`>> /etc/fstab`) bypass Layer 2 and
#     often aren't `cat`-ed, so their final state never hits the screen either.
#     At finalize we `cat` a small list of commonly-redirected system files.
#
# Compat: bash >= 4.3, Linux production hosts. Comments in English.
# =============================================================================

# Non-interactive shells (scp, rsync, git-over-ssh, `ssh host cmd`) must see a
# silent, side-effect-free .bashrc — bail out before anything below runs.
case $- in *i*) ;; *) return ;; esac

# -----------------------------------------------------------------------------
# Configuration  (identical on every machine; edit only if one truly differs)
# -----------------------------------------------------------------------------
# Everything this tool writes lives under ONE root (FAE_HOME) so it never
# scatters dot-dirs across $HOME:
#   $FAE_HOME/logs/     session recordings + manifest
#   $FAE_HOME/backups/  pre-edit file backups
#   $FAE_HOME/history/  the audit history file (see [12] below)
: "${FAE_ENV:=prod}"                        # prod | demo | dev -> banner/prompt colour
: "${FAE_HOME:=$HOME/.fae}"                 # single root for all tool-owned state
: "${FAE_LOG_DIR:=$FAE_HOME/logs}"          # session recordings + manifest live here
: "${FAE_BACKUP_DIR:=$FAE_HOME/backups}"    # pre-edit file backups
: "${FAE_HIST_DIR:=$FAE_HOME/history}"      # audit history file lives here
: "${FAE_RETENTION_DAYS:=365}"              # rotate: delete session dirs older than this
: "${FAE_RECORDING:=1}"                     # 1 = auto-record the terminal at login
: "${FAE_LOG_WARN_MB:=500}"                 # warn (don't cut) if a session exceeds this
# Snapshot list (GAP1-B): files commonly changed via shell redirection (which
# the vi wrappers can't see). We `cat` their FINAL content at finalize. This is
# an INCLUDE list of "also capture these", NOT an exclusion list — everything
# is still recorded raw. Deployment configs (configs.env/.env) are edited with
# vi and already covered by Layer 2, so they're intentionally not listed here.
: "${FAE_SNAPSHOT_FILES:=/etc/fstab /etc/exports /etc/hosts /etc/netplan/*.yaml}"

# =============================================================================
# [12] History hardening
# =============================================================================
HISTSIZE=-1                    # unlimited in-memory history
HISTFILESIZE=-1               # unlimited on-disk history
HISTTIMEFORMAT="%F %T "        # timestamp every entry (audit)
HISTCONTROL=                   # record EVERYTHING: keep dups & space-prefixed cmds
shopt -s histappend 2>/dev/null

# =============================================================================
# Remote injection payload
#
# base64-encoded and pushed to remote hosts on interactive SSH, and sourced
# into su/sudo shells, so vi/vim/nano edits stay tracked across hops. Output
# lands in the local `script` recording as [IR-*] blocks. Kept close to the
# proven install_recorder v5 logic; identifiers aligned to the fae_* namespace.
# =============================================================================
read -r -d '' _FAE_REMOTE_PAYLOAD << 'REMOTE_EOF'
# --- fae_bashrc remote vi/vim/nano edit tracker ---
_fae_redit() {
    local cmd="$1"; shift
    local file=""
    for a in "$@"; do [[ "$a" != -* ]] && file="$a"; done
    if [[ -z "$file" ]]; then command "$cmd" "$@"; return; fi

    local abs dir
    dir="$(cd "$(dirname "$file")" 2>/dev/null && pwd)"; [[ -z "$dir" ]] && dir="$(pwd)"
    abs="${dir}/$(basename "$file")"

    if [[ -f "$abs" ]]; then
        local bak="/tmp/.fae_bak_${$}_$(date +%s%N 2>/dev/null || date +%s)"
        cp -p "$abs" "$bak"
        echo ""; echo "=== [IR-BEFORE] file=$abs ==="; cat "$abs"; echo "=== [IR-BEFORE-END] ==="
        command "$cmd" "$@"; local rc=$?
        echo ""; echo "=== [IR-DIFF] file=$abs ==="; diff -u "$bak" "$abs" 2>/dev/null || true; echo "=== [IR-END] ==="
        if ! cmp -s "$bak" "$abs"; then
            echo "=== [IR-AFTER] file=$abs ==="; cat "$abs"; echo "=== [IR-AFTER-END] ==="
        fi
        rm -f "$bak"; return $rc
    else
        command "$cmd" "$@"; local rc=$?
        if [[ -f "$abs" ]]; then
            echo ""; echo "=== [IR-NEW] file=$abs ==="; cat "$abs"; echo "=== [IR-END] ==="
        fi
        return $rc
    fi
}
vi()   { _fae_redit vi   "$@"; }
vim()  { _fae_redit vim  "$@"; }
nano() { _fae_redit nano "$@"; }
export -f _fae_redit vi vim nano 2>/dev/null

# --- su intercept: carry wrappers into the target user's shell ---
su() {
    local has_c=false; for arg in "$@"; do [[ "$arg" == "-c" ]] && has_c=true; done
    if $has_c; then command su "$@"
    elif [[ -f /tmp/.fae_init ]]; then command su "$@" -c "source /tmp/.fae_init 2>/dev/null; exec bash"
    else command su "$@"; fi
}
export -f su 2>/dev/null

# --- sudo intercept: handle 'sudo su', 'sudo -s/-i', and 'sudo vi' ---
sudo() {
    case "$1" in
        su) shift
            if [[ -f /tmp/.fae_init ]]; then command sudo su "$@" -c "source /tmp/.fae_init 2>/dev/null; exec bash"
            else command sudo su "$@"; fi; return ;;
        -s) if [[ -f /tmp/.fae_init ]]; then command sudo bash -c "source /tmp/.fae_init 2>/dev/null; exec bash"
            else command sudo "$@"; fi; return ;;
        -i) if [[ -f /tmp/.fae_init ]]; then command sudo bash -lc "source /tmp/.fae_init 2>/dev/null; exec bash -l"
            else command sudo "$@"; fi; return ;;
        vi|vim|nano) local editor="$1"; shift
            command sudo bash -c "source /tmp/.fae_init 2>/dev/null; _fae_redit $editor $*"; return ;;
        -E) case "$2" in
                vi|vim|nano) command sudo -E bash -c "source /tmp/.fae_init 2>/dev/null; _fae_redit $2 ${*:3}"; return ;;
            esac ;;
    esac
    command sudo "$@"
}
export -f sudo 2>/dev/null
echo "[fae] vi/vim/nano edit tracking enabled"
REMOTE_EOF
_FAE_PAYLOAD_B64="$(printf '%s' "$_FAE_REMOTE_PAYLOAD" | base64 | tr -d '\n')"
export _FAE_PAYLOAD_B64

# =============================================================================
# [4] Local vi/vim/nano wrappers  (edits on the recording machine itself)
#
# Backup -> edit -> diff, emitting [IR-*] blocks into the recording. Supersedes
# v0.1's backup-only _fae_edit. Backups go under FAE_BACKUP_DIR (one root).
# =============================================================================
_fae_edit() {
    local cmd="$1"; shift
    local file=""
    for a in "$@"; do [[ "$a" != -* ]] && file="$a"; done
    if [[ -z "$file" ]]; then command "$cmd" "$@"; return; fi

    local abs dir
    dir="$(cd "$(dirname "$file")" 2>/dev/null && pwd)"; [[ -z "$dir" ]] && dir="$(pwd)"
    abs="${dir}/$(basename "$file")"

    if [[ -f "$abs" ]]; then
        mkdir -p "$FAE_BACKUP_DIR" 2>/dev/null
        local safe="${abs//\//%}"
        local bak="${FAE_BACKUP_DIR}/${safe}.$(date +%Y%m%d_%H%M%S).bak"
        cp -p "$abs" "$bak" 2>/dev/null
        echo ""; echo "=== [IR-BEFORE] file=$abs ==="; cat "$abs"; echo "=== [IR-BEFORE-END] ==="
        command "$cmd" "$@"; local rc=$?
        echo ""; echo "=== [IR-DIFF] file=$abs ==="; diff -u "$bak" "$abs" 2>/dev/null || true; echo "=== [IR-END] ==="
        if ! cmp -s "$bak" "$abs" 2>/dev/null; then
            echo "=== [IR-AFTER] file=$abs ==="; cat "$abs"; echo "=== [IR-AFTER-END] ==="
        fi
        return $rc
    else
        command "$cmd" "$@"; local rc=$?
        if [[ -f "$abs" ]]; then
            echo ""; echo "=== [IR-NEW] file=$abs ==="; cat "$abs"; echo "=== [IR-END] ==="
        fi
        return $rc
    fi
}
vi()   { _fae_edit vi   "$@"; }
vim()  { _fae_edit vim  "$@"; }
nano() { _fae_edit nano "$@"; }

# --- Intercept ssh: inject payload on interactive connections only ---
ssh() {
    local args=("$@") host_found=false has_remote_cmd=false i=0

    # ssh-copy-id / sftp / scp may invoke ssh internally — never inject for them.
    local caller_cmd; caller_cmd="$(ps -o comm= -p $PPID 2>/dev/null)"
    if [[ "$caller_cmd" == *"ssh-copy-id"* || "$caller_cmd" == *"sftp"* || "$caller_cmd" == *"scp"* ]]; then
        command ssh "$@"; return
    fi

    while [[ $i -lt ${#args[@]} ]]; do
        local arg="${args[$i]}"
        case "$arg" in
            -[bcDeFIiJLlmOopQRSWw]) ((i+=2)); continue ;;   # flags taking an argument
            -*)                     ((i++)); continue ;;    # boolean flags
            *)  if $host_found; then has_remote_cmd=true; break; fi
                host_found=true; ((i++)); continue ;;
        esac
    done

    if $has_remote_cmd; then
        command ssh "$@"                                    # non-interactive -> no inject
    else
        command ssh -t "$@" \
            "echo '${_FAE_PAYLOAD_B64}' | base64 -d > /tmp/.fae_init && chmod 644 /tmp/.fae_init && source /tmp/.fae_init; exec bash -l"
    fi
}
ssh-copy-id() { command ssh-copy-id "$@"; }

# =============================================================================
# Log-lifecycle engine
#
#   $FAE_LOG_DIR/session_<ts>_<tty>/
#     rec_<tty>.log   raw `script` recording
#     .open           recording-in-progress marker; contains the outer shell PID
# Finalize = strip ANSI, extract [IR-*], snapshot redirect-prone files, warn on
# size, gzip, clean /tmp, drop .open, note in manifest. Idempotent, crash-safe.
# =============================================================================
_FAE_MANIFEST="${FAE_LOG_DIR}/manifest.log"

# $1=ACTION  $2=session-name  $3=note
_fae_manifest() {
    mkdir -p "$FAE_LOG_DIR" 2>/dev/null
    printf '%s  %-8s  %-40s  %s\n' "$(date '+%F %T')" "$1" "$2" "$3" >> "$_FAE_MANIFEST"
}

# GAP1-B: capture the FINAL content of redirect-prone files the vi layer misses.
_fae_snapshot() {
    local dir="$1" snap="$1/snapshot" f content
    mkdir -p "$snap" 2>/dev/null
    local n=0
    for f in $FAE_SNAPSHOT_FILES; do            # unquoted: allow globs (netplan/*.yaml)
        [[ -e "$f" ]] || continue
        local safe="${f//\//%}"
        if content="$(cat "$f" 2>/dev/null)" || content="$(sudo -n cat "$f" 2>/dev/null)"; then
            printf '%s\n' "$content" > "$snap/${safe}.txt"; n=$((n + 1))
        else
            printf '[unreadable without interactive sudo]\n' > "$snap/${safe}.txt"
        fi
    done
    if crontab -l >"$snap/crontab.txt" 2>/dev/null; then n=$((n + 1)); else rm -f "$snap/crontab.txt"; fi
    [[ "$n" -gt 0 ]] || rmdir "$snap" 2>/dev/null
    return 0
}

_fae_finalize_session() {
    local dir="$1"
    [[ -d "$dir" ]] || return 0

    # 1+2. Merge raw logs and strip ANSI (Linux sed).
    local merged="${dir}/merged.log" f
    if compgen -G "$dir"/rec_*.log >/dev/null 2>&1; then
        cat "$dir"/rec_*.log > "$merged" 2>/dev/null
        LC_ALL=C sed -i $'s/\x1b\[[0-9;]*[a-zA-Z]//g'   "$merged" 2>/dev/null
        LC_ALL=C sed -i $'s/\x1b\][^\x07]*\x07//g'      "$merged" 2>/dev/null
        LC_ALL=C sed -i $'s/\x1b\[[?][0-9;]*[a-zA-Z]//g' "$merged" 2>/dev/null
        LC_ALL=C sed -i $'s/\x1b(B//g'                  "$merged" 2>/dev/null
        LC_ALL=C sed -i $'s/\x1b[=>]//g'                "$merged" 2>/dev/null
        LC_ALL=C sed -i $'s/\r//g'                      "$merged" 2>/dev/null
    fi

    # 3. Extract [IR-*] edit blocks.
    local edits="${dir}/edits.log" ec=0
    if [[ -f "$merged" ]]; then
        awk '/^=== \[IR-(DIFF|NEW|BEFORE|AFTER)\]/{f=1} f{print} /^=== \[IR-(END|BEFORE-END|AFTER-END)\]/{f=0}' \
            "$merged" > "$edits" 2>/dev/null
        ec=$(grep -c '^=== \[IR-DIFF\]\|^=== \[IR-NEW\]' "$edits" 2>/dev/null || echo 0)
    fi

    # 4. Snapshot redirect-prone files (GAP1-B).
    _fae_snapshot "$dir"

    # 5. Size warning (GAP2) — warn, never cut.
    local mb; mb=$(du -m "$dir" 2>/dev/null | tail -1 | awk '{print $1}')
    if [[ -n "$mb" && "$mb" -ge "$FAE_LOG_WARN_MB" ]]; then
        _fae_manifest WARN "$(basename "$dir")" "session size ${mb}MB >= ${FAE_LOG_WARN_MB}MB"
    fi

    # 6. gzip raw + merged (keep edits.log plaintext for quick reading).
    local n=0
    for f in "$dir"/rec_*.log "$merged"; do
        [[ -e "$f" ]] || continue
        gzip -f "$f" 2>/dev/null && n=$((n + 1))
    done

    # 7. Clean this shell's own /tmp injection artifacts.
    rm -f /tmp/.fae_init "/tmp/.fae_bak_${$}"* 2>/dev/null

    rm -f "$dir/.open"
    _fae_manifest FINALIZE "$(basename "$dir")" "gzipped ${n}, edits ${ec}"
}

# Finalize sessions a previous login left open, unless their recorder is alive.
_fae_finalize_orphans() {
    local dir pid
    for dir in "$FAE_LOG_DIR"/session_*/; do
        [[ -d "$dir" ]] || continue
        [[ -f "$dir/.open" ]] || continue
        pid="$(cat "$dir/.open" 2>/dev/null)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then continue; fi   # still live
        _fae_finalize_session "$dir"
    done
}

_fae_rotate() {
    [[ -n "$FAE_LOG_DIR" && "$FAE_LOG_DIR" != "/" && -d "$FAE_LOG_DIR" ]] || return 0
    local dir
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        _fae_manifest ROTATE "$(basename "$dir")" "deleted, age>${FAE_RETENTION_DAYS}d (retention policy)"
        rm -rf "$dir"
    done < <(find "$FAE_LOG_DIR" -maxdepth 1 -type d -name 'session_*' -mtime "+${FAE_RETENTION_DAYS}" 2>/dev/null)
}

_fae_housekeeping() { _fae_finalize_orphans; _fae_rotate; }

# =============================================================================
# Interactive setup: dirs, history, prompt, housekeeping, recording, banner
# (reached only in interactive shells — see the early return at the top)
# =============================================================================
mkdir -p "$FAE_LOG_DIR" "$FAE_BACKUP_DIR" "$FAE_HIST_DIR" 2>/dev/null

# [12] Relocate the audit history file under FAE_HOME (one root). bash keeps a
# single HISTFILE, so the old ~/.bash_history is simply left untouched.
HISTFILE="$FAE_HIST_DIR/bash_history"

# [1] Environment banner + colour-coded prompt
case "$FAE_ENV" in
    prod) _fae_bg=$'\033[1;97;41m'; _fae_fg=$'\033[1;31m'; _fae_tag=' PROD · 正式機 ' ;;
    demo) _fae_bg=$'\033[1;30;42m'; _fae_fg=$'\033[1;32m'; _fae_tag=' DEMO · 測試機 ' ;;
    *)    _fae_bg=$'\033[1;30;43m'; _fae_fg=$'\033[1;33m'; _fae_tag=" ${FAE_ENV} " ;;
esac
_fae_reset=$'\033[0m'
PS1="\[${_fae_fg}\][${FAE_ENV}]\[${_fae_reset}\] \u@\h:\w\\$ "

# [12] Append each command to the history file immediately (survives abrupt exit).
case "$PROMPT_COMMAND" in
    *"history -a"*) : ;;
    "")  PROMPT_COMMAND="history -a" ;;
    *)   PROMPT_COMMAND="history -a; ${PROMPT_COMMAND}" ;;
esac

# Login housekeeping — run once per login, in the OUTER shell before recording
# starts (so it isn't captured into the recording). Inherited flag makes the
# inner recorded shell skip it.
if [[ -z "$_FAE_HOUSEKEPT" ]]; then
    export _FAE_HOUSEKEPT=1
    _fae_housekeeping
fi

# --- Recording bootstrap ---------------------------------------------------
# Only the OUTER interactive login shell starts `script`. `script` spawns a new
# bash that re-reads this file; the exported guard makes that inner shell skip
# this block (otherwise: infinite re-exec = fork bomb). The inner shell falls
# through to load wrappers + print the banner.
if [[ "$FAE_RECORDING" == 1 && -z "$_FAE_REC_ACTIVE" ]]; then
    if command -v script >/dev/null 2>&1; then
        _fae_ts="$(date +%Y%m%d_%H%M%S)"
        _fae_tty="$(tty 2>/dev/null | sed 's|.*/||; s|[^A-Za-z0-9]|_|g')"; : "${_fae_tty:=pid$$}"
        _fae_sess="$FAE_LOG_DIR/session_${_fae_ts}_${_fae_tty}"
        mkdir -p "$_fae_sess"
        echo $$ > "$_fae_sess/.open"        # outer PID: alive while we block on `script`
        export _FAE_REC_ACTIVE=1
        export _FAE_REC_SESSION="$_fae_sess" # visible to the inner shell's banner
        _fae_manifest OPEN "$(basename "$_fae_sess")" "recording started (pid $$)"

        script -q -a "$_fae_sess/rec_${_fae_tty}.log"   # blocks; inner shell is the recorded one

        # Reached only on a clean logout (inner shell exited): finalize now.
        _fae_finalize_session "$_fae_sess"
        exit
    else
        printf '  \033[2m(recording skipped: `script` not found)\033[0m\n'
    fi
fi

# Banner — printed by the inner (recorded) shell; hostname is the machine's
# identity (no per-site label).
printf '\n%s%s%s  %s\n' "$_fae_bg" "$_fae_tag" "$_fae_reset" "$(hostname)"
printf '  user=%s   data=%s\n' "$(whoami)" "$FAE_HOME"
if [[ "$FAE_RECORDING" == 1 && -n "$_FAE_REC_ACTIVE" ]]; then
    printf '  \033[2m(recording -> %s)\033[0m\n' "$_FAE_REC_SESSION"
elif [[ "$FAE_RECORDING" != 1 ]]; then
    printf '  \033[2m(terminal recording disabled: FAE_RECORDING=%s)\033[0m\n' "$FAE_RECORDING"
fi
printf '\n'
