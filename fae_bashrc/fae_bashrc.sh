#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fae_bashrc installer (v0.5)
#
#     bash fae_bashrc.sh          # backs up, migrates customizations, installs
#
# fae_bashrc OWNS ~/.bashrc: it is replaced wholesale so every FAE machine runs
# one identical shell environment. v0.5 adds the missing half of that deal — the
# FAE's OWN customizations (aliases, PATH, conda/nvm init) move to
# ~/.bashrc.local, which the installed bashrc sources on every interactive
# login and which upgrades never overwrite.
#
# This installer migrates a pre-existing ~/.bashrc into ~/.bashrc.local by
# default, commenting out only the lines that would silently break command/edit
# capture (and reporting each one).
# =============================================================================

target_file="${HOME}/.bashrc"
user_rc="${HOME}/.bashrc.local"
timestamp="$(date +%Y%m%d%H%M%S)"

# Names whose capture wrappers an alias would silently shadow. bash resolves
# alias -> keyword -> function, and alias expansion happens at parse time, so a
# same-named alias wins no matter what order things are defined in. Keep this
# list in sync with _FAE_PROTECTED_NAMES in the embedded bashrc below.
protected_re='vi|vim|nano|crontab|su|sudo|ssh|docker|ssh-copy-id'

# --- Is $1 a bashrc that this tool installed? --------------------------------
# v0.5+ carries an explicit marker line. v0.4/v0.41 predate the marker, so fall
# back to a function name only our bashrc can contain.
_is_fae_bashrc() {
  [[ -f "$1" ]] || return 1
  if grep -q '^# fae_bashrc-managed ' "$1" 2>/dev/null; then return 0; fi
  if grep -q '_fae_log_cmd' "$1" 2>/dev/null; then return 0; fi
  return 1
}

# -----------------------------------------------------------------------------
# 1. Pick the migration source
#
# On a machine that ALREADY runs v0.4/v0.41, the current ~/.bashrc is ours —
# migrating from it would copy fae's own wrappers into ~/.bashrc.local and then
# source them recursively. The FAE's real content is in the OLDEST backup
# (.bak.<ts>, so lexicographic order == chronological order).
# -----------------------------------------------------------------------------
migrate_from=""
migrate_note=""
if [[ ! -s "${target_file}" ]]; then
  migrate_note="no existing ~/.bashrc"
elif ! _is_fae_bashrc "${target_file}"; then
  migrate_from="${target_file}"
  migrate_note="current ~/.bashrc"
else
  oldest="$(ls -1 "${target_file}".bak.* 2>/dev/null | sort | head -1 || true)"
  if [[ -n "${oldest}" && -s "${oldest}" ]] && ! _is_fae_bashrc "${oldest}"; then
    migrate_from="${oldest}"
    migrate_note="oldest backup ${oldest##*/} (current ~/.bashrc is already fae-managed)"
  else
    migrate_note="current ~/.bashrc is already fae-managed and no original backup was found — not guessing"
  fi
fi

# -----------------------------------------------------------------------------
# 2. Copy the source verbatim, commenting out only the dangerous lines
#
# Verbatim + selective disable, NOT a whitelist: a whitelist of `alias` /
# `export PATH` lines would drop functions, `source` lines and conda/nvm init
# blocks. PS1 is deliberately NOT disabled — the bashrc loads ~/.bashrc.local
# after setting PS1, so a custom prompt is meant to win.
# -----------------------------------------------------------------------------
migrate_body=""
disabled_report=()
if [[ -n "${migrate_from}" ]]; then
  lineno=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    reason=""
    trimmed="${line#"${line%%[![:space:]]*}"}"
    if [[ -n "${trimmed}" && "${trimmed}" != '#'* ]]; then
      if [[ "${trimmed}" =~ ^(export[[:space:]]+)?(HISTCONTROL|HISTSIZE|HISTFILESIZE|HISTTIMEFORMAT|HISTFILE)= ]]; then
        reason="history settings are pinned by fae_bashrc for audit completeness"
      elif [[ "${trimmed}" =~ ^(export[[:space:]]+)?PROMPT_COMMAND= ]]; then
        reason="PROMPT_COMMAND is owned by fae_bashrc (command capture)"
      elif [[ "${trimmed}" =~ ^trap[[:space:]] && "${trimmed}" == *EXIT* ]]; then
        reason="an EXIT trap would replace fae_bashrc's session finalize"
      elif [[ "${trimmed}" =~ ^alias[[:space:]]+(${protected_re})= ]]; then
        reason="this alias would silently shadow a capture wrapper"
      elif [[ "${trimmed}" =~ (^|[[:space:]])(\.|source)[[:space:]] ]] \
        && [[ "${trimmed}" =~ \.bashrc(\.local)?([[:space:]]|$) ]]; then
        reason="sourcing ~/.bashrc(.local) from here would recurse"
      fi
    fi
    if [[ -n "${reason}" ]]; then
      migrate_body+="# [fae v0.5 disabled] ${reason}"$'\n'"# ${line}"$'\n'
      disabled_report+=("line ${lineno}: ${reason}")
    else
      migrate_body+="${line}"$'\n'
    fi
  done < "${migrate_from}"
fi

# -----------------------------------------------------------------------------
# 3. Write ~/.bashrc.local — never over an existing one
#
# An existing ~/.bashrc.local means either a second install, or an old ~/.bashrc
# that already sourced it. Either way the file is the FAE's; write beside it and
# let them merge.
# -----------------------------------------------------------------------------
user_rc_written=""
if [[ -n "${migrate_from}" ]]; then
  if [[ -e "${user_rc}" ]]; then
    user_rc_written="${user_rc}.migrated.${timestamp}"
  else
    user_rc_written="${user_rc}"
  fi
  {
    echo "# ~/.bashrc.local — your own shell customizations (aliases, PATH, conda/nvm)."
    echo "#"
    echo "# Migrated from ${migrate_from}"
    echo "# by fae_bashrc v0.5 on $(date '+%F %T')."
    echo "#"
    echo "# fae_bashrc sources this file on every interactive login and NEVER rewrites"
    echo "# it again — it is yours. Upgrading fae_bashrc will not touch it."
    echo "#"
    echo "# Lines marked '[fae v0.5 disabled]' were commented out because they would"
    echo "# break command/edit capture. Re-enabling them is at your own risk: the"
    echo "# bashrc re-pins history settings and restores capture wrappers after"
    echo "# sourcing this file anyway, so most of them simply cannot take effect."
    echo ""
    printf '%s' "${migrate_body}"
  } > "${user_rc_written}"
fi

# -----------------------------------------------------------------------------
# 4. Back up and install
# -----------------------------------------------------------------------------
if [[ -f "${target_file}" ]]; then
  backup_file="${target_file}.bak.${timestamp}"
  cp "${target_file}" "${backup_file}"
  echo "Backed up ${target_file} to ${backup_file}"
fi

cat > "${target_file}" <<'FAE_BASHRC_EOF'
#!/usr/bin/env bash
# fae_bashrc-managed v0.5
# =============================================================================
# fae_bashrc  (v0.5) — the standardized FAE ~/.bashrc, input-only capture
#
# FAE on-site shell environment for hospital production machines. The installer
# backs up the current ~/.bashrc and installs this file in its place, so every
# FAE machine runs one identical, unified shell environment.
#
#     bash fae_bashrc.sh          # backs up, migrates customizations, installs
#
# v0.4 replaced v0.2/v0.3's whole-screen `script` recording with an INPUT-ONLY
# capture model. The risk was that recording the whole pty wrote patient PHI
# (names, MRNs, DOBs printed on screen) into the logs. v0.4 records only what
# the FAE *did*, never what the screen *showed*:
#   - commands.log : every command the FAE ran, timestamped (input side)
#   - edits.log    : before/diff/after for vi/vim/nano edits + `crontab -e`,
#                    produced by reading the FILE, not the screen
# Command OUTPUT (query results, `cat` of a patient file, errors) is still shown
# on the FAE's screen as normal — it is simply never written to disk.
#
# There is NO recording of output, stderr, or full-screen program state, and NO
# redaction engine. Residual PHI is limited to identifiers the FAE types into a
# command themselves (e.g. `grep <MRN>`) — small, and accepted as risk. See the
# README "隱私定位" section; an MRN is a direct identifier, not "non-PII".
#
# v0.5 adds user customizations WITHOUT giving up "one file, every machine":
# this file owns ~/.bashrc, and the FAE's own aliases/PATH/conda init live in
# ~/.bashrc.local, sourced on every interactive login. Because a user alias
# would silently shadow a capture wrapper (bash resolves alias before function,
# regardless of definition order), the load is followed by a hardening pass that
# un-aliases the protected names, restores overridden wrappers, and re-pins the
# history settings — announcing each conflict instead of failing quietly.
#
# v0.5 also fixes a v0.4/v0.41 capture bug found while testing it: on a machine
# whose audit history file was still empty, the FIRST command of the FIRST
# session was swallowed by _fae_log_cmd's baseline. See that function.
#
# Design rationale & decisions:
#   context/99-latest-v0.4-input-only-擷取模型-spec.md   (capture model)
#   context/99-latest-v0.5-使用者自訂-bashrc-local-spec.md (this version)
#
# Capture seams (reuse the proven v0.3 machinery, just change the OUTPUT sink):
#   - Commands: a PROMPT_COMMAND hook appends the last history entry to
#     commands.log after every command. The global audit history ([12]) is
#     unchanged.
#   - Edits: the vi/vim/nano wrappers ([IR-*]) append straight to edits.log
#     instead of echoing to a `script` recording.
#   - Boundary crossing (ssh/su/sudo/docker): inject a bootstrap that sets the
#     same two logs up on the far side, then collect them back to the
#     originating machine's session dir. The injected payload carries the
#     CAPTURE only — never the user's ~/.bashrc.local.
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
#   $FAE_HOME/logs/     per-session commands.log / edits.log + manifest
#   $FAE_HOME/backups/  pre-edit file backups
#   $FAE_HOME/history/  the audit history file (see [12] below)
# ~/.bashrc.local is the deliberate exception: it is the FAE's own file, not
# tool-owned state, so it stays where a FAE would look for it.
: "${FAE_HOME:=$HOME/.fae}"                 # single root for all tool-owned state
: "${FAE_LOG_DIR:=$FAE_HOME/logs}"          # session logs + manifest live here
: "${FAE_BACKUP_DIR:=$FAE_HOME/backups}"    # pre-edit file backups
: "${FAE_HIST_DIR:=$FAE_HOME/history}"      # audit history file lives here
: "${FAE_RETENTION_DAYS:=365}"              # rotate: delete session dirs older than this
: "${FAE_CAPTURE:=1}"                       # 1 = capture commands+edits (0 = plain shell)
: "${FAE_LOG_WARN_MB:=500}"                 # warn (don't cut) if a session exceeds this
# Snapshot list (GAP1): files commonly changed via shell redirection (which the
# vi wrappers can't see). We `cat` their FINAL content at finalize. This is the
# final file CONTENT, not screen output, and is low-PHI system config.
: "${FAE_SNAPSHOT_FILES:=/etc/fstab /etc/exports /etc/hosts /etc/netplan/*.yaml}"

# =============================================================================
# [12] History hardening  (unchanged from v0.3 — global audit trail)
# =============================================================================
HISTSIZE=-1                    # unlimited in-memory history
HISTFILESIZE=-1               # unlimited on-disk history
HISTTIMEFORMAT="%F %T "        # timestamp every entry (audit)
HISTCONTROL=                   # record EVERYTHING: keep dups & space-prefixed cmds
shopt -s histappend 2>/dev/null

# =============================================================================
# Remote/privileged/container injection payload
#
# base64-encoded and pushed across interactive boundaries (ssh, su/sudo,
# docker exec -it) so the FAR side also records commands + vi edits into a
# session dir. The caller MUST export FAE_SESSION_DIR before sourcing this:
#   - ssh / docker : a fresh dir under the far side's /tmp (collected back on exit)
#   - su / sudo    : the SAME local session dir (root can write it; no collection)
# Output lands in that dir's commands.log / edits.log — never on any screen.
# The user's ~/.bashrc.local is NOT carried across: ssh lands on a machine with
# its own, and su/sudo land in root's HOME.
# =============================================================================
read -r -d '' _FAE_REMOTE_PAYLOAD << 'REMOTE_EOF'
# --- fae_bashrc injected bootstrap (input-only capture) ---
: "${FAE_SESSION_DIR:=/tmp/.fae_sess_$$}"
mkdir -p "$FAE_SESSION_DIR" 2>/dev/null
# Pre-create the logs as whoever starts this shell, so a later su/sudo shell
# only ever appends (root bypasses perms; ownership stays with this user).
: >> "$FAE_SESSION_DIR/commands.log" 2>/dev/null; : >> "$FAE_SESSION_DIR/edits.log" 2>/dev/null
export FAE_SESSION_DIR

# Stable, timestamped, unbounded history so command extraction is reliable.
HISTSIZE=-1; HISTFILESIZE=-1; HISTCONTROL=; export HISTSIZE HISTFILESIZE HISTCONTROL

# --- command logger: append the last command (timestamped) to commands.log ---
_fae_log_cmd() {
    [[ -n "$FAE_SESSION_DIR" && -d "$FAE_SESSION_DIR" ]] || return 0
    local num cmd
    read -r num cmd <<< "$(HISTTIMEFORMAT='' builtin history 1 2>/dev/null)"
    # First fire in THIS shell only records a baseline (skips any pre-existing
    # history entry) so injected ssh/su/docker shells never log a stale command.
    # An EMPTY history counts as a baseline of 0 — it must be seeded HERE, before
    # the empty-num guard below. Otherwise, on a machine whose audit history file
    # is still empty, the first prompt returns early WITHOUT seeding and the
    # baseline lands on the session's first real command, swallowing it (v0.4/v0.41
    # behaviour, fixed in v0.5).
    if [[ -z "$_fae_seeded" ]]; then _fae_seeded=1; _fae_last_histn="${num:-0}"; return 0; fi
    [[ -z "$num" ]] && return 0
    [[ "$num" == "$_fae_last_histn" ]] && return 0   # bare Enter → no new command
    _fae_last_histn="$num"
    { printf '%s  %s\n' "$(date '+%F %T' 2>/dev/null)" "$cmd" >> "$FAE_SESSION_DIR/commands.log"; } 2>/dev/null
}
# _fae_seeded/_fae_last_histn are intentionally NOT exported: each shell (incl.
# injected ones) must re-baseline on its own first prompt.
case "$PROMPT_COMMAND" in
    *_fae_log_cmd*) : ;;
    "")  PROMPT_COMMAND="_fae_log_cmd" ;;
    *)   PROMPT_COMMAND="_fae_log_cmd; ${PROMPT_COMMAND}" ;;
esac
export PROMPT_COMMAND

# --- file-edit tracker: before/diff/after into edits.log (reads the file) ---
_fae_redit() {
    local cmd="$1"; shift
    local file=""
    for a in "$@"; do [[ "$a" != -* ]] && file="$a"; done
    if [[ -z "$file" || -z "$FAE_SESSION_DIR" ]]; then command "$cmd" "$@"; return; fi

    local abs dir edits="$FAE_SESSION_DIR/edits.log"
    dir="$(cd "$(dirname "$file")" 2>/dev/null && pwd)"; [[ -z "$dir" ]] && dir="$(pwd)"
    abs="${dir}/$(basename "$file")"

    if [[ -f "$abs" ]]; then
        local bak="/tmp/.fae_bak_${$}_$(date +%s%N 2>/dev/null || date +%s)"
        cp -p "$abs" "$bak" 2>/dev/null
        command "$cmd" "$@"; local rc=$?
        {
            echo "=== [IR-BEFORE] $(date '+%F %T') file=$abs ==="; cat "$bak"; echo "=== [IR-BEFORE-END] ==="
            echo "=== [IR-DIFF] file=$abs ==="; diff -u "$bak" "$abs" 2>/dev/null || true; echo "=== [IR-END] ==="
            if ! cmp -s "$bak" "$abs" 2>/dev/null; then
                echo "=== [IR-AFTER] file=$abs ==="; cat "$abs"; echo "=== [IR-AFTER-END] ==="
            fi
        } >> "$edits" 2>/dev/null
        rm -f "$bak"; return $rc
    else
        command "$cmd" "$@"; local rc=$?
        if [[ -f "$abs" ]]; then
            { echo "=== [IR-NEW] $(date '+%F %T') file=$abs ==="; cat "$abs"; echo "=== [IR-END] ==="; } >> "$edits" 2>/dev/null
        fi
        return $rc
    fi
}
vi()   { _fae_redit vi   "$@"; }
vim()  { _fae_redit vim  "$@"; }
nano() { _fae_redit nano "$@"; }

# --- crontab -e before/after diff into edits.log ---
crontab() {
    if [[ "$1" == "-e" && -n "$FAE_SESSION_DIR" ]]; then
        local before after edits="$FAE_SESSION_DIR/edits.log"
        before="$(command crontab -l 2>/dev/null)"
        command crontab "$@"; local rc=$?
        after="$(command crontab -l 2>/dev/null)"
        {
            echo "=== [IR-CRON-BEFORE] $(date '+%F %T') ==="; printf '%s\n' "$before"; echo "=== [IR-CRON-BEFORE-END] ==="
            echo "=== [IR-CRON-DIFF] ==="; diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") 2>/dev/null || true; echo "=== [IR-END] ==="
            echo "=== [IR-CRON-AFTER] ==="; printf '%s\n' "$after"; echo "=== [IR-CRON-AFTER-END] ==="
        } >> "$edits" 2>/dev/null
        return $rc
    fi
    command crontab "$@"
}

# --- su / sudo re-injection: carry capture into the privileged shell (same dir) ---
su() {
    local has_c=false a; for a in "$@"; do [[ "$a" == "-c" ]] && has_c=true; done
    if $has_c || [[ ! -f /tmp/.fae_init ]]; then command su "$@"; return; fi
    command su "$@" -c "export FAE_SESSION_DIR='$FAE_SESSION_DIR'; source /tmp/.fae_init 2>/dev/null; exec bash"
}
sudo() {
    case "$1" in
        su) shift
            if [[ -f /tmp/.fae_init ]]; then command sudo su "$@" -c "export FAE_SESSION_DIR='$FAE_SESSION_DIR'; source /tmp/.fae_init 2>/dev/null; exec bash"
            else command sudo su "$@"; fi; return ;;
        -s) if [[ -f /tmp/.fae_init ]]; then command sudo bash -c "export FAE_SESSION_DIR='$FAE_SESSION_DIR'; source /tmp/.fae_init 2>/dev/null; exec bash"
            else command sudo "$@"; fi; return ;;
        -i) if [[ -f /tmp/.fae_init ]]; then command sudo bash -lc "export FAE_SESSION_DIR='$FAE_SESSION_DIR'; source /tmp/.fae_init 2>/dev/null; exec bash -l"
            else command sudo "$@"; fi; return ;;
        vi|vim|nano) local editor="$1"; shift
            command sudo bash -c "export FAE_SESSION_DIR='$FAE_SESSION_DIR'; source /tmp/.fae_init 2>/dev/null; _fae_redit $editor $*"; return ;;
        -E) case "$2" in
                vi|vim|nano) command sudo -E bash -c "export FAE_SESSION_DIR='$FAE_SESSION_DIR'; source /tmp/.fae_init 2>/dev/null; _fae_redit $2 ${*:3}"; return ;;
            esac ;;
    esac
    command sudo "$@"
}

export -f _fae_log_cmd _fae_redit vi vim nano crontab su sudo 2>/dev/null

# --- pack helper: the ssh host side calls this after the shell exits ---
_fae_pack() { tar -C "$FAE_SESSION_DIR" -cf - . 2>/dev/null | base64 2>/dev/null | tr -d '\n'; }
export -f _fae_pack 2>/dev/null
REMOTE_EOF
_FAE_PAYLOAD_B64="$(printf '%s' "$_FAE_REMOTE_PAYLOAD" | base64 | tr -d '\n')"
export _FAE_PAYLOAD_B64

# =============================================================================
# Local capture: command logger + vi/vim/nano wrappers
# (these run in the FAE's own login shell; edits.log/commands.log live under
#  FAE_SESSION_DIR, set up in the interactive-setup block below)
# =============================================================================
_fae_log_cmd() {
    [[ -n "$FAE_SESSION_DIR" && -d "$FAE_SESSION_DIR" ]] || return 0
    local num cmd
    read -r num cmd <<< "$(HISTTIMEFORMAT='' builtin history 1 2>/dev/null)"
    # Seed the baseline even on an empty history — see the twin in the injected
    # payload above for why the order of these two lines matters.
    if [[ -z "$_fae_seeded" ]]; then _fae_seeded=1; _fae_last_histn="${num:-0}"; return 0; fi
    [[ -z "$num" ]] && return 0
    [[ "$num" == "$_fae_last_histn" ]] && return 0
    _fae_last_histn="$num"
    { printf '%s  %s\n' "$(date '+%F %T' 2>/dev/null)" "$cmd" >> "$FAE_SESSION_DIR/commands.log"; } 2>/dev/null
}

# Backup -> edit -> before/diff/after, appended to edits.log. Local backups go
# under FAE_BACKUP_DIR (one root); the remote twin (_fae_redit) uses /tmp.
_fae_edit() {
    local cmd="$1"; shift
    local file=""
    for a in "$@"; do [[ "$a" != -* ]] && file="$a"; done
    if [[ -z "$file" || -z "$FAE_SESSION_DIR" ]]; then command "$cmd" "$@"; return; fi

    local abs dir edits="$FAE_SESSION_DIR/edits.log"
    dir="$(cd "$(dirname "$file")" 2>/dev/null && pwd)"; [[ -z "$dir" ]] && dir="$(pwd)"
    abs="${dir}/$(basename "$file")"

    if [[ -f "$abs" ]]; then
        mkdir -p "$FAE_BACKUP_DIR" 2>/dev/null
        local safe="${abs//\//%}"
        local bak="${FAE_BACKUP_DIR}/${safe}.$(date +%Y%m%d_%H%M%S).bak"
        cp -p "$abs" "$bak" 2>/dev/null
        command "$cmd" "$@"; local rc=$?
        {
            echo "=== [IR-BEFORE] $(date '+%F %T') file=$abs ==="; cat "$bak"; echo "=== [IR-BEFORE-END] ==="
            echo "=== [IR-DIFF] file=$abs ==="; diff -u "$bak" "$abs" 2>/dev/null || true; echo "=== [IR-END] ==="
            if ! cmp -s "$bak" "$abs" 2>/dev/null; then
                echo "=== [IR-AFTER] file=$abs ==="; cat "$abs"; echo "=== [IR-AFTER-END] ==="
            fi
        } >> "$edits" 2>/dev/null
        return $rc
    else
        command "$cmd" "$@"; local rc=$?
        if [[ -f "$abs" ]]; then
            { echo "=== [IR-NEW] $(date '+%F %T') file=$abs ==="; cat "$abs"; echo "=== [IR-END] ==="; } >> "$edits" 2>/dev/null
        fi
        return $rc
    fi
}
vi()   { _fae_edit vi   "$@"; }
vim()  { _fae_edit vim  "$@"; }
nano() { _fae_edit nano "$@"; }

# --- crontab -e wrapper (local) ---
crontab() {
    if [[ "$1" == "-e" && -n "$FAE_SESSION_DIR" ]]; then
        local before after edits="$FAE_SESSION_DIR/edits.log"
        before="$(command crontab -l 2>/dev/null)"
        command crontab "$@"; local rc=$?
        after="$(command crontab -l 2>/dev/null)"
        {
            echo "=== [IR-CRON-BEFORE] $(date '+%F %T') ==="; printf '%s\n' "$before"; echo "=== [IR-CRON-BEFORE-END] ==="
            echo "=== [IR-CRON-DIFF] ==="; diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") 2>/dev/null || true; echo "=== [IR-END] ==="
            echo "=== [IR-CRON-AFTER] ==="; printf '%s\n' "$after"; echo "=== [IR-CRON-AFTER-END] ==="
        } >> "$edits" 2>/dev/null
        return $rc
    fi
    command crontab "$@"
}

# --- su / sudo intercept (local): carry capture into privileged shells ---
su() {
    local has_c=false a; for a in "$@"; do [[ "$a" == "-c" ]] && has_c=true; done
    if $has_c || [[ ! -f /tmp/.fae_init ]]; then command su "$@"; return; fi
    command su "$@" -c "export FAE_SESSION_DIR='$FAE_SESSION_DIR'; source /tmp/.fae_init 2>/dev/null; exec bash"
}
sudo() {
    case "$1" in
        su) shift
            if [[ -f /tmp/.fae_init ]]; then command sudo su "$@" -c "export FAE_SESSION_DIR='$FAE_SESSION_DIR'; source /tmp/.fae_init 2>/dev/null; exec bash"
            else command sudo su "$@"; fi; return ;;
        -s) if [[ -f /tmp/.fae_init ]]; then command sudo bash -c "export FAE_SESSION_DIR='$FAE_SESSION_DIR'; source /tmp/.fae_init 2>/dev/null; exec bash"
            else command sudo "$@"; fi; return ;;
        -i) if [[ -f /tmp/.fae_init ]]; then command sudo bash -lc "export FAE_SESSION_DIR='$FAE_SESSION_DIR'; source /tmp/.fae_init 2>/dev/null; exec bash -l"
            else command sudo "$@"; fi; return ;;
        vi|vim|nano) local editor="$1"; shift
            command sudo bash -c "export FAE_SESSION_DIR='$FAE_SESSION_DIR'; source /tmp/.fae_init 2>/dev/null; _fae_redit $editor $*"; return ;;
        -E) case "$2" in
                vi|vim|nano) command sudo -E bash -c "export FAE_SESSION_DIR='$FAE_SESSION_DIR'; source /tmp/.fae_init 2>/dev/null; _fae_redit $2 ${*:3}"; return ;;
            esac ;;
    esac
    command sudo "$@"
}

# --- Intercept ssh: inject payload on interactive connections, collect on exit ---
ssh() {
    local args=("$@") host_found=false has_remote_cmd=false remote_host="" i=0

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
                host_found=true; remote_host="$arg"; ((i++)); continue ;;
        esac
    done

    if $has_remote_cmd; then
        command ssh "$@"; return                             # non-interactive -> no inject
    fi

    # Interactive: set up a remote session dir, run the shell, then pack it back.
    local rtag; rtag="$(date +%Y%m%d_%H%M%S)_$$"
    local rsess="/tmp/.fae_sess_${rtag}"
    local ctl="/tmp/.fae_ctl_$$"
    local host_safe="${remote_host//[^A-Za-z0-9._-]/_}"
    local dest="$FAE_SESSION_DIR/ssh_${host_safe}_${rtag}"
    mkdir -p "$dest" 2>/dev/null

    # Remote command: seed /tmp/.fae_init, run the login shell, pack on exit.
    # NOTE: we do NOT `exec` bash so that `_fae_pack` runs after the user logs out.
    local rcmd="echo '${_FAE_PAYLOAD_B64}' | base64 -d > /tmp/.fae_init && chmod 600 /tmp/.fae_init"
    rcmd="$rcmd && export FAE_SESSION_DIR='$rsess' && source /tmp/.fae_init; bash -l; _fae_pack > /tmp/.fae_pack.b64 2>/dev/null"

    command ssh -t \
        -o ControlMaster=auto -o ControlPath="$ctl" -o ControlPersist=15 \
        "$@" "$rcmd"

    # Collect the remote logs back. Prefer the multiplexed master (no re-auth);
    # fall back to a fresh connection (which may prompt for a password).
    local fetch="cat /tmp/.fae_pack.b64 2>/dev/null; rm -f /tmp/.fae_pack.b64 /tmp/.fae_init 2>/dev/null; rm -rf '$rsess' 2>/dev/null"
    if command ssh -o ControlPath="$ctl" -O check "$@" 2>/dev/null; then
        command ssh -o ControlPath="$ctl" "$@" "$fetch" | base64 -d 2>/dev/null | tar -C "$dest" -xf - 2>/dev/null
        command ssh -o ControlPath="$ctl" -O exit "$@" 2>/dev/null
    else
        echo "[fae] 正在把遠端操作紀錄撈回本機 session（多工重用不可用，可能需再輸入一次密碼）…" >&2
        command ssh "$@" "$fetch" | base64 -d 2>/dev/null | tar -C "$dest" -xf - 2>/dev/null
    fi
    # If nothing was collected, drop the empty dir so it doesn't clutter.
    rmdir "$dest" 2>/dev/null || true
}
ssh-copy-id() { command ssh-copy-id "$@"; }

# --- Intercept docker: inject into interactive `exec -it ... bash|sh`; Django REPL ---
# One-shot `docker exec c <cmd>` (incl. `dj admin <cmd>` and `... shell -c`) is a
# single outer command already captured in commands.log — pass it straight
# through. Only interactive shells and the bare `dj admin shell` REPL need the
# in-container bootstrap + docker-cp collection.
docker() {
    local argv=("$@") base=0
    [[ "${argv[0]}" == "compose" ]] && base=1        # cover `docker compose exec` / bin/dc
    if [[ "${argv[$base]}" != "exec" ]]; then command docker "$@"; return; fi

    # Parse the exec: interactivity, container ref, in-container command.
    local interactive=false container="" j=$((base+1)) n=${#argv[@]}
    local pre=("${argv[@]:0:$((base+1))}")           # e.g. (exec) or (compose exec)
    local flags=() cmdwords=()
    while (( j < n )); do
        local a="${argv[$j]}"
        case "$a" in
            -i|-t|-it|-ti|--interactive|--tty) [[ "$a" == *t* || "$a" == "--tty" ]] && interactive=true
                                               flags+=("$a"); ((j++)) ;;
            -e|-u|-w|--env|--user|--workdir)   flags+=("$a" "${argv[$((j+1))]}"); ((j+=2)) ;;
            -*)                                flags+=("$a"); ((j++)) ;;
            *)                                 container="$a"; ((j++)); break ;;
        esac
    done
    while (( j < n )); do cmdwords+=("${argv[$j]}"); ((j++)); done

    # Only interactive execs are candidates; everything else is a one-shot.
    if ! $interactive; then command docker "$@"; return; fi

    local ncw=${#cmdwords[@]}
    local last="${cmdwords[$((ncw-1))]:-}"
    local first="${cmdwords[0]:-}"
    local has_c=false w; for w in "${cmdwords[@]}"; do [[ "$w" == "-c" ]] && has_c=true; done

    local rtag; rtag="$(date +%Y%m%d_%H%M%S)_$$"

    # (A) Bare interactive shell: docker exec -it c bash|sh  -> full bootstrap.
    if [[ $ncw -le 2 && ( "$first" == "bash" || "$first" == "sh" ) ]]; then
        local dest="$FAE_SESSION_DIR/docker_${container//[^A-Za-z0-9._-]/_}_${rtag}"
        mkdir -p "$dest" 2>/dev/null
        local csess="/tmp/.fae_sess"
        local rcmd="echo '${_FAE_PAYLOAD_B64}' | base64 -d > /tmp/.fae_init && export FAE_SESSION_DIR='$csess' && source /tmp/.fae_init; exec bash"
        command docker "${pre[@]}" "${flags[@]}" "$container" bash -c "$rcmd"
        _fae_docker_collect "$base" "$container" "$csess/." "$dest"
        rmdir "$dest" 2>/dev/null || true
        return
    fi

    # (B) Django interactive REPL: `... admin shell` with no -c -> IPython history.
    #     Spike (2026-07-23, demo1) confirmed dj admin shell -> IPython, and with
    #     a tty IPYTHONDIR captures each input line into history.sqlite.
    if ! $has_c && [[ "$last" == "shell" ]]; then
        local dest="$FAE_SESSION_DIR/djshell_${container//[^A-Za-z0-9._-]/_}_${rtag}"
        mkdir -p "$dest" 2>/dev/null
        command docker "${pre[@]}" "${flags[@]}" \
            -e IPYTHONDIR=/tmp/.fae_ipy -e PYTHONSTARTUP=/tmp/.fae_py \
            "$container" "${cmdwords[@]}"
        _fae_docker_collect "$base" "$container" "/tmp/.fae_ipy/profile_default/history.sqlite" "$dest"
        rmdir "$dest" 2>/dev/null || true
        return
    fi

    # (C) Other interactive exec (e.g. mysql, python one-off): pass through.
    command docker "$@"
}

# Copy $src (a path inside $container) out to local $dest. Uses `docker cp` for a
# plain container, `docker compose cp` when the exec was `docker compose exec`.
_fae_docker_collect() {
    local base="$1" container="$2" src="$3" dest="$4"
    if [[ "$base" == 1 ]]; then
        command docker compose cp "${container}:${src}" "$dest/" 2>/dev/null
    else
        command docker cp "${container}:${src}" "$dest/" 2>/dev/null
    fi
}

# =============================================================================
# User customizations (~/.bashrc.local) + capture hardening
#
# This file owns ~/.bashrc, so the FAE's own aliases/PATH/conda init go in
# ~/.bashrc.local. The installer migrates a pre-existing ~/.bashrc there once;
# after that the file belongs to the FAE and this tool never rewrites it (it is
# not backed up and not rotated either).
#
# Hardening exists because bash resolves names alias -> keyword -> function and
# expands aliases at PARSE time: `alias vi='vim -u NONE'` beats the vi() capture
# wrapper no matter which is defined first, and the failure is SILENT (edits.log
# just stays empty). Defining the wrappers later does not help — the only fix is
# to unalias. Same story for a same-named function, which replaces the wrapper
# outright, so we snapshot the wrappers before sourcing and restore them after.
#
# Who wins what, by design:
#   PS1             user  (loaded after PS1 is set — a custom prompt is fine)
#   PROMPT_COMMAND  both  (the block at the bottom prepends _fae_log_cmd)
#   HIST* / HISTFILE  fae (audit completeness)
#   trap EXIT       fae   (the session trap is installed after this point)
#   protected names fae   (aliases dropped, wrappers restored, both announced)
# =============================================================================
_FAE_PROTECTED_NAMES='vi vim nano crontab su sudo ssh docker ssh-copy-id'
_fae_userrc_note=""      # held until the session dir exists, then written to manifest

# Snapshot the capture wrappers so an override can be restored after sourcing.
# Plain variables via printf -v (not an associative array) to stay compatible.
_fae_snapshot_wrappers() {
    local n v
    for n in $_FAE_PROTECTED_NAMES; do
        v="_fae_fnsnap_${n//[^A-Za-z0-9]/_}"
        printf -v "$v" '%s' "$(declare -f "$n" 2>/dev/null)"
    done
}

# Syntax-check, then source. A broken user file must not take the login down:
# login is normally silent, so a raw pile of bash errors would be hard to trace.
_fae_source_guarded() {
    local f="$1" lines fp selfsrc
    [[ -f "$f" ]] || return 0
    if ! bash -n "$f" 2>/dev/null; then
        printf 'fae: %s has a syntax error — not loaded (fix it, or run: bash -n %s)\n' "$f" "$f" >&2
        _fae_userrc_note="${_fae_userrc_note}${_fae_userrc_note:+; }SKIPPED ${f##*/} (syntax error)"
        return 0
    fi
    # A file that sources ~/.bashrc(.local) recurses until bash dies (SIGSEGV).
    # No variable guard can stop it — the `.` builtin re-reads the file directly,
    # bypassing this loader entirely — so the only defence is to refuse. The
    # installer comments such lines out on migration; this catches a hand-edited
    # file. An unloaded customization file beats an unusable login shell.
    selfsrc="$(sed 's/#.*//' "$f" 2>/dev/null | grep -nE '(^|[[:space:]])(\.|source)[[:space:]]+[^;&|]*\.bashrc(\.local)?([[:space:]]|$)' 2>/dev/null | head -1)"
    if [[ -n "$selfsrc" ]]; then
        printf 'fae: %s sources ~/.bashrc(.local) at line %s — not loaded (it would recurse until the shell dies). Delete that line.\n' "$f" "${selfsrc%%:*}" >&2
        _fae_userrc_note="${_fae_userrc_note}${_fae_userrc_note:+; }SKIPPED ${f##*/} (self-source at line ${selfsrc%%:*})"
        return 0
    fi
    source "$f"
    lines="$(wc -l < "$f" 2>/dev/null | tr -d ' ')"
    fp="$( { sha256sum "$f" 2>/dev/null || shasum -a 256 "$f" 2>/dev/null; } | cut -c1-8 )"
    _fae_userrc_note="${_fae_userrc_note}${_fae_userrc_note:+; }loaded ${f##*/} (${lines:-0} lines, sha256 ${fp:-unknown})"
}

# _FAE_USER_RC_LOADED is deliberately NOT exported: every interactive shell
# should load the customizations, but a user file that sources ~/.bashrc back
# must not re-enter this loader within one shell. (A file that sources ITSELF
# bypasses this guard entirely — see the self-source check in
# _fae_source_guarded, which is the defence for that case.)
_fae_load_user_rc() {
    [[ -z "$_FAE_USER_RC_LOADED" ]] || return 0
    _FAE_USER_RC_LOADED=1
    _fae_source_guarded "$HOME/.bashrc.local"
    # Reserved interface for future multi-source customization (personal +
    # per-site). Undocumented on purpose: v0.5 ships one file.
    if [[ -d "$FAE_HOME/bashrc.d" ]]; then
        local d
        for d in "$FAE_HOME"/bashrc.d/*.sh; do
            [[ -f "$d" ]] && _fae_source_guarded "$d"
        done
    fi
}

# Undo anything the user file did that would silently disable capture. Only
# reached when FAE_CAPTURE=1 — with capture off there is nothing to protect.
_fae_harden_capture() {
    local n v snap conflicts="" repinned=""

    for n in $_FAE_PROTECTED_NAMES; do
        if alias "$n" >/dev/null 2>&1; then
            unalias "$n" 2>/dev/null
            printf 'fae: dropped your alias for `%s` — it would silently break capture\n' "$n" >&2
            conflicts="${conflicts}${conflicts:+, }alias:$n"
        fi
        v="_fae_fnsnap_${n//[^A-Za-z0-9]/_}"; snap="${!v}"
        if [[ -n "$snap" && "$(declare -f "$n" 2>/dev/null)" != "$snap" ]]; then
            eval "$snap"
            printf 'fae: restored the `%s` capture wrapper (your override was dropped)\n' "$n" >&2
            conflicts="${conflicts}${conflicts:+, }func:$n"
        fi
    done

    # History settings are the audit trail — fae owns them unconditionally.
    [[ "$HISTFILE" == "$FAE_HIST_DIR/bash_history" ]] || { HISTFILE="$FAE_HIST_DIR/bash_history"; repinned="${repinned}${repinned:+, }HISTFILE"; }
    [[ "$HISTSIZE" == -1 ]]                           || { HISTSIZE=-1;                          repinned="${repinned}${repinned:+, }HISTSIZE"; }
    [[ "$HISTFILESIZE" == -1 ]]                       || { HISTFILESIZE=-1;                      repinned="${repinned}${repinned:+, }HISTFILESIZE"; }
    [[ -z "$HISTCONTROL" ]]                           || { HISTCONTROL=;                         repinned="${repinned}${repinned:+, }HISTCONTROL"; }
    [[ "$HISTTIMEFORMAT" == "%F %T " ]]               || { HISTTIMEFORMAT="%F %T ";              repinned="${repinned}${repinned:+, }HISTTIMEFORMAT"; }
    if [[ -n "$repinned" ]]; then
        printf 'fae: re-pinned history settings owned by fae_bashrc: %s\n' "$repinned" >&2
        conflicts="${conflicts}${conflicts:+; }repinned: $repinned"
    fi

    [[ -z "$conflicts" ]] || _fae_userrc_note="${_fae_userrc_note}${_fae_userrc_note:+; }${conflicts}"
}

# =============================================================================
# Log-lifecycle engine
#
#   $FAE_LOG_DIR/session_<ts>_<tty>/
#     commands.log   every command run this session, timestamped (input side)
#     edits.log      before/diff/after for vi/crontab edits (read from files)
#     ssh_*/ docker_*/ djshell_*/   logs collected back from boundary hops
#     snapshot/      final content of redirect-prone files (GAP1)
#     .open          in-progress marker; contains the owning shell PID
# Finalize = snapshot, size warn, clean this shell's /tmp bits, drop .open, note
# manifest. commands.log/edits.log append live, so they're crash-safe already.
# Idempotent: a session with no .open is treated as already finalized.
# =============================================================================
_FAE_MANIFEST="${FAE_LOG_DIR}/manifest.log"

# $1=ACTION  $2=session-name  $3=note
_fae_manifest() {
    mkdir -p "$FAE_LOG_DIR" 2>/dev/null
    printf '%s  %-8s  %-40s  %s\n' "$(date '+%F %T')" "$1" "$2" "$3" >> "$_FAE_MANIFEST"
}

# GAP1: capture the FINAL content of redirect-prone files the vi layer misses.
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
    if command crontab -l >"$snap/crontab.txt" 2>/dev/null; then n=$((n + 1)); else rm -f "$snap/crontab.txt"; fi
    [[ "$n" -gt 0 ]] || rmdir "$snap" 2>/dev/null
    return 0
}

_fae_finalize_session() {
    local dir="$1"
    [[ -d "$dir" ]] || return 0
    [[ -f "$dir/.open" ]] || return 0          # no .open == already finalized (idempotent)

    # 1. Snapshot redirect-prone files (GAP1).
    _fae_snapshot "$dir"

    # 2. Size warning (GAP2) — warn, never cut. (Input-only logs are tiny; this
    #    mainly guards against a runaway collected hop.)
    local mb; mb=$(du -m "$dir" 2>/dev/null | tail -1 | awk '{print $1}')
    if [[ -n "$mb" && "$mb" -ge "$FAE_LOG_WARN_MB" ]]; then
        _fae_manifest WARN "$(basename "$dir")" "session size ${mb}MB >= ${FAE_LOG_WARN_MB}MB"
    fi

    # 3. Clean this shell's own /tmp bits (leave /tmp/.fae_init: other live
    #    sessions on this host may still need it; it's rewritten each login).
    rm -f "/tmp/.fae_pack.b64" "/tmp/.fae_ctl_${$}" "/tmp/.fae_bak_${$}"* 2>/dev/null

    local cc ec
    cc=$(wc -l < "$dir/commands.log" 2>/dev/null | tr -d ' '); : "${cc:=0}"
    ec=$(grep -c '^=== \[IR-DIFF\]\|^=== \[IR-NEW\]\|^=== \[IR-CRON-DIFF\]' "$dir/edits.log" 2>/dev/null || echo 0)

    rm -f "$dir/.open"
    _fae_manifest FINALIZE "$(basename "$dir")" "commands ${cc}, edits ${ec}"
}

# Finalize sessions a previous login left open, unless their shell is alive.
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
# Interactive setup: dirs, history, prompt, user customizations, housekeeping,
# session start
# (reached only in interactive shells — see the early return at the top)
# =============================================================================
mkdir -p "$FAE_LOG_DIR" "$FAE_BACKUP_DIR" "$FAE_HIST_DIR" 2>/dev/null

# [12] Relocate the audit history file under FAE_HOME (one root). bash keeps a
# single HISTFILE, so the old ~/.bash_history is simply left untouched.
HISTFILE="$FAE_HIST_DIR/bash_history"

# [1] Prompt — plain \u@\h:\w (already names user + machine). Silent login.
PS1="\u@\h:\w\\$ "

# Load the FAE's own customizations HERE — after PS1 (a custom prompt wins) and
# before the FAE_CAPTURE early return (customizations load with capture off
# too). Silent when there is nothing to load or nothing conflicts.
[[ "$FAE_CAPTURE" == 1 ]] && _fae_snapshot_wrappers
_fae_load_user_rc
[[ "$FAE_CAPTURE" == 1 ]] && _fae_harden_capture

# Skip all capture when disabled — behaves like a plain, silent bashrc.
if [[ "$FAE_CAPTURE" != 1 ]]; then
    case "$PROMPT_COMMAND" in *"history -a"*) : ;; "") PROMPT_COMMAND="history -a" ;; *) PROMPT_COMMAND="history -a; ${PROMPT_COMMAND}" ;; esac
    return
fi

# Make the generic injection payload available on disk for su/sudo/ssh/docker.
printf '%s' "$_FAE_PAYLOAD_B64" | base64 -d > /tmp/.fae_init 2>/dev/null && chmod 600 /tmp/.fae_init 2>/dev/null

# Login housekeeping — finalize orphaned sessions + rotate. Run once per login
# (the exported guard makes nested `bash` shells skip it).
if [[ -z "$_FAE_HOUSEKEPT" ]]; then
    export _FAE_HOUSEKEPT=1
    _fae_housekeeping
fi

# Session dir. The OWNING login shell creates it and owns finalize; nested
# `bash` shells inherit FAE_SESSION_DIR and log into the SAME dir but neither
# re-create it nor finalize it (guarded by _FAE_SESSION_ACTIVE / owner PID).
if [[ -z "$_FAE_SESSION_ACTIVE" ]]; then
    _fae_ts="$(date +%Y%m%d_%H%M%S)"
    _fae_tty="$(tty 2>/dev/null | sed 's|.*/||; s|[^A-Za-z0-9]|_|g')"; : "${_fae_tty:=pid$$}"
    export FAE_SESSION_DIR="$FAE_LOG_DIR/session_${_fae_ts}_${_fae_tty}"
    export _FAE_SESSION_ACTIVE=1
    export _FAE_OWNER_PID=$$
    mkdir -p "$FAE_SESSION_DIR"
    # Pre-create logs as the login user so a later su/sudo shell only appends
    # (root bypasses perms; ownership stays with the user → no perm-denied spam).
    : >> "$FAE_SESSION_DIR/commands.log" 2>/dev/null; : >> "$FAE_SESSION_DIR/edits.log" 2>/dev/null
    echo $$ > "$FAE_SESSION_DIR/.open"          # owning PID: alive == session live
    _fae_manifest OPEN "$(basename "$FAE_SESSION_DIR")" "session started (pid $$)"
    # This machine is NOT the stock environment if a user file was loaded — an
    # auditor (or the AI reading these logs) has to be able to see that. Written
    # here, not at load time, because the session dir did not exist yet. No
    # customizations == no USERRC line at all.
    [[ -z "$_fae_userrc_note" ]] || _fae_manifest USERRC "$(basename "$FAE_SESSION_DIR")" "$_fae_userrc_note"
    # Clean logout: finalize best-effort. Crash/disconnect: next login's
    # _fae_finalize_orphans picks it up (both paths are idempotent).
    trap '[[ "$$" == "$_FAE_OWNER_PID" ]] && _fae_finalize_session "$FAE_SESSION_DIR"' EXIT
fi

# [12] Command capture + immediate history append. _fae_log_cmd self-baselines
# on its first fire (see its definition), so the pre-existing last history entry
# is never re-logged — no explicit seeding needed here.
case "$PROMPT_COMMAND" in
    *_fae_log_cmd*) : ;;
    "")  PROMPT_COMMAND="history -a; _fae_log_cmd" ;;
    *)   PROMPT_COMMAND="history -a; _fae_log_cmd; ${PROMPT_COMMAND}" ;;
esac
FAE_BASHRC_EOF

echo "Installed embedded FAE bashrc to ${target_file}"

# -----------------------------------------------------------------------------
# 5. Report what happened to the customizations
# -----------------------------------------------------------------------------
if [[ -n "${user_rc_written}" ]]; then
  echo "Migrated your shell customizations from ${migrate_note}"
  echo "  -> ${user_rc_written}"
  if [[ "${user_rc_written}" != "${user_rc}" ]]; then
    echo "  NOTE: ${user_rc} already exists and was NOT modified."
    echo "        Review ${user_rc_written} and merge by hand what you want to keep."
  fi
  if [[ ${#disabled_report[@]} -gt 0 ]]; then
    echo "  Commented out ${#disabled_report[@]} line(s) that would break command/edit capture:"
    for r in "${disabled_report[@]}"; do echo "    - ${r}"; done
    echo "  They are marked '# [fae v0.5 disabled]' in the file if you want to review them."
  fi
else
  echo "No shell customizations migrated (${migrate_note})."
fi
echo "From now on your own aliases/PATH belong in ${user_rc} — upgrades never overwrite it."
