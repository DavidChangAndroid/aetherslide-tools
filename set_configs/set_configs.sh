#!/bin/bash

# Interactive helper to fill hardware-dependent resource limits in .env and
# the gigastore disk limit in configs/gigastore/tier_configs.yaml, based on the
# detected machine and three headroom percentages (CPU / RAM / DISK).
#
# Run this once after each installation instead of hand-editing every limit.
# Service limits stay independent "ceilings" (they may overlap / oversubscribe);
# this only caps each one relative to this machine's size.
#
# V2.6: fixes a crash bug in the "no external internet access" branch of
#   configure_site_settings(): commenting out WEB__MATOMO_BACKEND_LOCATION made the
#   nginx container's Settings() (nginx/settings.py, a required str with no default)
#   raise a pydantic ValidationError and crash-loop — confirmed on a real install
#   (2026-08-13). Fix: point it at the IP literal 127.0.0.1:1 instead of commenting
#   it out. nginx/web.conf.jinja renders this into a static `upstream { server X }`
#   block that nginx resolves via system DNS at config-parse time; an IP literal
#   needs no DNS, so nginx always starts regardless of internet access, and the
#   tracking upstream just gets connection-refused per request (harmless).
#
# V2.5: replaces V2.4's A/B/C bucket model with ONE unified formula per service:
#     value = max( scale_from(.env.example), tph_floor )
#   - .env.example (sized for 64C/128G) is the scaling BASE for normal machines.
#   - the "tph" (部北) profile is a per-service FLOOR calibrated for 4C/8G, so hot
#     services (uwsgi/image-server/websocket) keep enough process count + headroom
#     even when pure scaling would starve them. This encodes real per-service
#     tuning that a flat scale/floor cannot.
#   - CPU/process scale by cores (/64), MEM scales by RAM (/128); k = pct/100.
#   - Below the 4C/8G minimum: print an English warning and scale the tph floor
#     DOWN by the machine/4C8G ratio (no pct applied), best-effort only.
#   Two hand-maintained tables (EX = example base, FL = tph floor) live in
#   load_reference_tables(); update them when the upstream sample / tph profile
#   changes.
#
# V2.7 (multi-version; targets 202605.x .. 202609.1+; collapses the set_full_mod fork):
#   * Resource sizing is now VERSION-ADAPTIVE. The managed key set + example base
#     values (EX) + kind are DISCOVERED at runtime from the deployed .env.example
#     (verified: EX == .env.example). New services are auto-managed, renamed ones
#     followed, removed ones dropped; the write phase already skips keys absent from
#     the target .env, so an unmatched key just falls back to its default.
#   * FL (per-service floor) is a snapshot of the LIVE tph .env — the values that
#     actually run stably in production (the old hand-guessed floors were too low and
#     caused start-up failures). It carries both the current tph key names and the
#     202609 renamed/new keys mapped to the nearest tph service, so the same floor
#     applies under either naming. Refresh load_fl_snapshot() when tph is re-tuned.
#   * NEW step configure_module_switches(): ask Y/N (or read env override MOD_AIHUB /
#     MOD_EDUCATION / MOD_STUDY / MOD_QC / MOD_REGI = 1|0) for the five front-end
#     modules and write them to prefs.env; all five are always offered and the key is
#     appended if the deployed prefs.env lacks it. Replaces set_full_mod_configV1.0.sh.
#   * Falls back to a built-in 202609.1 base table if .env.example can't be read.

if [ -z "${BASH_VERSION:-}" ]; then
    echo "Error: this script must be run with bash, not sh."
    echo "Usage: bash bin/set_resource_limits.sh"
    exit 1
fi

set -euo pipefail

dirpath=$(realpath "$0" | xargs dirname)
website_path=$(dirname "$dirpath")

source "$dirpath/lib/env_utils.sh"

ENV_FILE="$website_path/.env"
CONFIGS_FILE="$website_path/configs.env"
TIER_FILE="$website_path/configs/gigastore/tier_configs.yaml"
PREFS_FILE="$website_path/prefs.env"

# Defaults for the three knobs (percent).
DEFAULT_CPU_PCT=80
DEFAULT_RAM_PCT=80
DEFAULT_DISK_PCT=95

declare -A ENV_UPDATES
declare -A CONFIGS_UPDATES
declare -A PREFS_UPDATES
CONFIGS_COMMENT_OUT=()

# Reference tables + regime flag, filled by discover_ref_keys() / compute_values().
declare -A EX FL KIND FL_SNAP EX_BUILTIN
REF_KEYS=()
REF_KEYS_CPU=()
REF_KEYS_MEM=()
REF_KEYS_NUM=()
BELOW_MIN=0

main() {
    fix_default_data_paths
    ensure_docker_group
    check_disk_encryption
    check_storage_mounts
    configure_site_settings
    configure_module_switches
    detect_hardware
    show_disk_usage
    prompt_percentages
    compute_values
    show_plan
    confirm_and_apply
    run_populate_working_dir
}

# resolve_path_raw <key> -> raw path value, preferring a planned (not-yet-written)
# fix recorded in ENV_UPDATES. Lets pre-confirm checks see the /data/* target even
# though the actual .env write is deferred to confirm_and_apply.
resolve_path_raw() {
    local key=$1
    if [[ -n ${ENV_UPDATES[$key]:-} ]]; then
        echo "${ENV_UPDATES[$key]}"
    else
        getenv "$key" .env || true
    fi
}

fix_default_data_paths() {
    # All data path keys except TLS_PATH (which is intentionally local).
    local path_keys=(STORAGE_PATH BACKUP_PATH UPLOAD_PATH EXPORT_PATH EXPORT_EXTERNAL_PATH DATASET_EXPORT_PATH)
    local fixed=0

    for key in "${path_keys[@]}"; do
        local raw
        raw=$(getenv "$key" .env || true)
        [[ -z $raw ]] && continue

        if [[ $raw == ./data/* ]]; then
            # ./data/foo  ->  /data/foo  (recorded as planned; written at confirm_and_apply)
            local new_path="/${raw#./}"
            ENV_UPDATES[$key]="$new_path"
            printf "  [PLANNED] %-28s  %s  ->  %s\n" "$key" "$raw" "$new_path"
            fixed=1
        fi
    done

    if ((fixed)); then
        echo
        echo "[INFO] Data paths will be updated from ./data/* to /data/* after you confirm."
        echo "       These directories must be mount points for external storage (SMB/NFS)."
        echo "       Mount your storage server at /data before starting services."
        echo
    fi
}

ensure_docker_group() {
    local install_user
    install_user=$(id -un)

    if id -nG "$install_user" | grep -qw docker; then
        echo "[INFO] $install_user is already in the docker group (ok)"
    else
        echo "[INFO] Adding $install_user to the docker group..."
        sudo usermod -aG docker "$install_user" \
            && echo "[INFO] Done. Re-login or run 'newgrp docker' for the change to take effect." \
            || echo "[WARN] sudo usermod failed — check sudo permissions." >&2
    fi
    echo
}

check_disk_encryption() {
    # WHY THIS CHECKS THE DOCKER VOLUME DISK, NOT /data/* :
    # Elasticsearch encrypts its OWN data directory with fscrypt, from inside the
    # container. See the image source monitoring/elasticsearch/encrypt_es_data.sh:
    #     fscrypt encrypt /bitnami/elasticsearch/data \
    #         --key=/bitnami/elasticsearch/secrets/es_data_secret.key --source=raw_key
    # and entrypoint.sh, which "fscrypt unlock" that dir on startup and exits 1 (=>
    # container restart loop) if it cannot. That directory IS the named volume
    # "es_data" (docker-compose.stateful.yaml: "es_data:/bitnami/elasticsearch"),
    # which has NO device binding, so it lives under Docker's data-root
    # (default /var/lib/docker/volumes) — NOT under /data/*.
    #
    # For ES's in-container fscrypt to work, the filesystem backing Docker's
    # data-root must have the ext4 "encrypt" feature. The /data/* app paths
    # (STORAGE_PATH/BACKUP_PATH/...) are plain bind mounts that nothing
    # fscrypt-encrypts, so they are intentionally NOT checked here.
    echo "[INFO] Checking disk encryption for the Elasticsearch data volume..."

    # Where Docker stores named volumes (es_data lives here).
    local docker_root
    docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)
    [[ -z $docker_root ]] && docker_root=/var/lib/docker
    local vol_dir="$docker_root/volumes"
    [[ -d $vol_dir ]] || vol_dir="$docker_root"

    # Resolve the backing device + filesystem type.
    local dev fstype
    dev=$(df --output=source "$vol_dir" 2>/dev/null | tail -n1)
    fstype=$(df --output=fstype "$vol_dir" 2>/dev/null | tail -n1)
    if [[ -z $dev ]]; then
        echo "  [SKIP] Could not resolve the device behind $vol_dir; skipping check."
        echo
        return
    fi

    # fscrypt needs a local ext-family block device. Network / overlay / fuse
    # filesystems cannot be checked with tune2fs (and network FS bring their own
    # at-rest encryption), so the local encrypt-feature check does not apply.
    case "$fstype" in
        nfs|nfs4|cifs|smbfs|smb3|fuse.*|overlay|overlay2|zfs|btrfs)
            printf "  [SKIP] %s on %s (%s) — fscrypt encrypt-feature check N/A for this FS.\n" "$vol_dir" "$dev" "$fstype"
            echo
            return
            ;;
    esac

    local enc_status
    enc_status=$(sudo tune2fs -l "$dev" 2>/dev/null \
        | grep '^Filesystem features' | grep -o 'encrypt' || true)

    if [[ $enc_status == "encrypt" ]]; then
        printf "  [OK]   %s (Docker volume disk, %s) — encrypt feature enabled\n" "$dev" "$fstype"
        echo
        return
    fi

    printf "  [ERROR] %s (Docker volume disk for es_data, %s) — ext4 'encrypt' feature NOT enabled\n" "$dev" "$fstype"
    echo
    echo "          Elasticsearch fscrypt-encrypts its data on this disk ($vol_dir) and"
    echo "          will restart-loop (exit 1 on 'fscrypt unlock') without the encrypt feature."
    local ans
    read -rp "          Enable the ext4 encrypt feature on $dev now? [Y/n]: " ans
    if [[ -z $ans || $ans =~ ^[Yy]$ ]]; then
        sudo "$dirpath/enable_encryption_on_ext4_fs.sh" "$dev" \
            || { echo "[ERROR] Encryption setup failed for $dev. Aborting."; exit 1; }
        # Verify encryption was actually enabled.
        enc_status=$(sudo tune2fs -l "$dev" 2>/dev/null \
            | grep '^Filesystem features' | grep -o 'encrypt' || true)
        if [[ $enc_status != "encrypt" ]]; then
            echo "[ERROR] Encryption still not enabled on $dev after setup. Aborting."
            exit 1
        fi
        echo "[INFO] Encryption confirmed on $dev."
    else
        echo "[ERROR] Encryption is mandatory for Elasticsearch. Aborting setup."
        exit 1
    fi
    echo
}

check_storage_mounts() {
    # Data paths that must be mounted on external storage (SMB/NFS).
    # TLS_PATH is intentionally local and excluded.
    local path_keys=(STORAGE_PATH BACKUP_PATH UPLOAD_PATH EXPORT_PATH EXPORT_EXTERNAL_PATH DATASET_EXPORT_PATH)

    echo "[INFO] Storage path check:"
    for key in "${path_keys[@]}"; do
        local raw p
        raw=$(resolve_path_raw "$key")
        [[ -z $raw ]] && continue

        if [[ $raw == ./* || $raw == . ]]; then
            p="$website_path/${raw#./}"
        else
            p="$raw"
        fi

        # Find the nearest existing ancestor to get a mount point.
        local rp="$p"
        while [[ ! -e $rp && $rp != / ]]; do rp=$(dirname "$rp"); done
        local mount dev
        mount=$(df --output=target "$rp" 2>/dev/null | tail -n1)
        dev=$(df --output=source "$rp" 2>/dev/null | tail -n1)

        printf "  [OK]   %-24s = %-30s  (mounted: %s on %s)\n" "$key" "$raw" "$mount" "$dev"
    done
    echo

    echo "[INFO] Confirm that all external storage (SMB/NFS) is mounted before continuing."
    local ans
    read -rp "All storage mounts verified? [Y/n]: " ans
    [[ -z $ans || $ans =~ ^[Yy]$ ]] || { echo "[INFO] Cancelled."; exit 0; }
    echo

    # Resolve all 6 data paths.
    local resolved_paths=()
    for key in "${path_keys[@]}"; do
        local raw p
        raw=$(resolve_path_raw "$key")
        [[ -z $raw ]] && continue
        if [[ $raw == ./* || $raw == . ]]; then
            p="$website_path/${raw#./}"
        else
            p="$raw"
        fi
        resolved_paths+=("$p")
    done

    # Check for missing optional data directories and offer to create them.
    local missing=()
    for p in "${resolved_paths[@]}"; do
        [[ ! -d $p ]] && missing+=("$p")
    done

    if ((${#missing[@]} > 0)); then
        echo "[INFO] The following data directories do not exist:"
        for p in "${missing[@]}"; do
            echo "       $p"
        done
        echo
        local ans
        read -rp "Create them now with mkdir -p? [Y/n]: " ans
        if [[ -z $ans || $ans =~ ^[Yy]$ ]]; then
            for p in "${missing[@]}"; do
                mkdir -p "$p" && echo "[INFO] Created: $p"
            done
        else
            echo "[WARN] Directories not created. Services may fail to start."
        fi
        echo
    else
        echo "[INFO] All data directories already exist."
        echo
    fi

    # ── RD SOP: required storage sub-volumes and the 'share' mount ───────────
    # Source: https://docs.google.com/document/d/1E_s7Wl_Ap2tjIOZYXK0Ro7H-5COdt6ikxzLWLzCcPd0/edit
    # Per the RD install SOP these must exist before services start:
    #   storage/vol001..vol003, upload/gw001..gw003, and a top-level 'share'
    #   (which has no .env key of its own). Sub-volumes are created under the
    #   resolved STORAGE_PATH / UPLOAD_PATH; 'share' sits alongside storage
    #   (e.g. STORAGE_PATH=/data/storage -> /data/share). sudo, because /data is
    #   typically a freshly-mounted root-owned external volume.
    local storage_raw upload_raw storage_p upload_p d
    storage_raw=$(resolve_path_raw STORAGE_PATH)
    upload_raw=$(resolve_path_raw UPLOAD_PATH)

    if [[ -n $storage_raw ]]; then
        if [[ $storage_raw == ./* || $storage_raw == . ]]; then
            storage_p="$website_path/${storage_raw#./}"
        else
            storage_p="$storage_raw"
        fi
        for d in vol001 vol002 vol003; do
            [[ -d "$storage_p/$d" ]] || { sudo mkdir -p "$storage_p/$d" && echo "[INFO] Created: $storage_p/$d"; }
        done
        if [[ ! -d "$(dirname "$storage_p")/share" ]]; then
            sudo mkdir -p "$(dirname "$storage_p")/share" && echo "[INFO] Created: $(dirname "$storage_p")/share"
        fi
    fi

    if [[ -n $upload_raw ]]; then
        if [[ $upload_raw == ./* || $upload_raw == . ]]; then
            upload_p="$website_path/${upload_raw#./}"
        else
            upload_p="$upload_raw"
        fi
        for d in gw001 gw002 gw003; do
            [[ -d "$upload_p/$d" ]] || { sudo mkdir -p "$upload_p/$d" && echo "[INFO] Created: $upload_p/$d"; }
        done
    fi
    echo
}

detect_hardware() {
    CORES=$(nproc)
    RAM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)

    echo "[INFO] Detected hardware:"
    echo "       CPU cores : $CORES"
    echo "       Total RAM : ${RAM_GB} GB"
    echo
}

show_disk_usage() {
    echo "[INFO] Disk usage for data paths (watch for anything near 100% on /):"
    local seen=""
    for key in STORAGE_PATH BACKUP_PATH UPLOAD_PATH EXPORT_PATH; do
        local p
        p=$(resolve_path_raw "$key")
        [[ -z $p ]] && continue
        # Walk up to the nearest existing ancestor so df has something to report.
        while [[ ! -e $p && $p != / ]]; do p=$(dirname "$p"); done
        local dev
        dev=$(df --output=source "$p" 2>/dev/null | tail -n1)
        [[ -z $dev || $seen == *"|$dev|"* ]] && continue
        seen="$seen|$dev|"
        df -h "$p" | tail -n1 | awk -v k="$key" '{printf "       %-14s %-22s %5s used (%s on %s)\n", k, $6, $5, $4" free", $1}'
    done
    echo
}

prompt_percentages() {
    CPU_PCT=$(ask_pct "CPU ceiling %" "$DEFAULT_CPU_PCT")
    RAM_PCT=$(ask_pct "RAM ceiling %" "$DEFAULT_RAM_PCT")
    DISK_PCT=$(ask_pct "Disk usage limit % (gigastore max_percent)" "$DEFAULT_DISK_PCT")
    echo
}

# ask_str <prompt> <default> -> echoes the user's input or default
ask_str() {
    local prompt=$1 default=$2 ans
    read -rp "$prompt [$default]: " ans
    echo "${ans:-$default}"
}

# ask_pct <prompt> <default> -> echoes an integer 1..100
ask_pct() {
    local prompt=$1 default=$2 ans
    while true; do
        read -rp "$prompt [$default]: " ans
        ans=${ans:-$default}
        if [[ $ans =~ ^[0-9]+$ ]] && ((ans >= 1 && ans <= 100)); then
            echo "$ans"
            return
        fi
        echo "  Please enter an integer between 1 and 100." >&2
    done
}

configure_site_settings() {
    echo "[INFO] Site settings (configs.env):"
    echo

    # --- WEB_NETWORK_LOCATION (single canonical host:port) ---
    # Only the internal IP is auto-detected (used as the default). The canonical address
    # may be a FQDN / public IP — type it manually; we never auto-detect external addresses.
    local detected_ip
    detected_ip=$(ip route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || true)
    [[ -z $detected_ip ]] && detected_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    [[ -z $detected_ip ]] && detected_ip="127.0.0.1"
    local cur_netloc cur_allowed
    cur_netloc=$(getenv WEB_NETWORK_LOCATION configs.env || true)
    cur_allowed=$(getenv WEB_BACKEND__ALLOWED_HOSTS configs.env || true)
    echo "  Current WEB_NETWORK_LOCATION : $cur_netloc"
    echo "  Detected internal IP         : $detected_ip  (default)"
    echo "  WEB_NETWORK_LOCATION is the canonical address (TLS cert + SERVER_URL + redirects)."
    echo "  Default is the internal IP; type your FQDN / public IP for the production address."
    local netloc
    netloc=$(ask_str "  WEB_NETWORK_LOCATION (host:port)" "${detected_ip}:443")
    CONFIGS_UPDATES[WEB_NETWORK_LOCATION]="$netloc"
    local site_host="${netloc%%:*}"   # strip :port
    # Warn if the canonical host is a hostname (FQDN): nginx 301-redirects '/' to it and
    # SERVER_URL uses it, so it must resolve via DNS or IP-based access will break.
    if [[ -n $site_host ]] && ! [[ $site_host =~ ^[0-9.]+$ ]]; then
        echo "  [WARN] '$site_host' is a hostname. nginx 301-redirects / to it and SERVER_URL uses it."
        echo "         DNS must resolve it (or add it to your test client's /etc/hosts);"
        echo "         otherwise access via IP will 301-redirect to an unresolvable name."
    fi
    echo

    # --- WEB_BACKEND__ALLOWED_HOSTS (list of accepted hosts) ---
    # Seed with the detected internal IP + the WEB_NETWORK_LOCATION host; add the rest
    # manually (public IP, FQDN, ...). No auto-detection of external addresses.
    echo "  Build the ALLOWED_HOSTS list (hosts Django will accept). Add public IP / FQDN manually."
    local extra_hosts
    while true; do
        extra_hosts=("$detected_ip" "$site_host")
        local add
        while true; do
            echo "  Current list: ${extra_hosts[*]}"
            read -rp "  Add another host/IP/FQDN (blank to finish): " add
            [[ -z $add ]] && break
            extra_hosts+=("$add")
        done
        echo "  Final ALLOWED_HOSTS additions: ${extra_hosts[*]}"
        local ok
        read -rp "  Confirm this list? [Y/n] (n = start the list over): " ok
        [[ -z $ok || $ok =~ ^[Yy]$ ]] && break
        echo
    done

    # Merge into existing ALLOWED_HOSTS, de-duplicated, preserving existing internal entries.
    local merged="$cur_allowed" h
    for h in "${extra_hosts[@]}"; do
        [[ -z $h ]] && continue
        if [[ ",$merged," != *",$h,"* ]]; then
            merged="${merged:+$merged,}$h"
        fi
    done
    CONFIGS_UPDATES[WEB_BACKEND__ALLOWED_HOSTS]="$merged"
    echo "  -> WEB_BACKEND__ALLOWED_HOSTS = $merged"
    echo

    # --- WEB__MATOMO_BACKEND_LOCATION ---
    # nginx/settings.py declares this a REQUIRED str (no default) — commenting it out
    # makes the nginx container's Settings() raise a pydantic ValidationError and
    # crash-loop on every start, it does not just "hang". Confirmed the hard way on a
    # real install (2026-08-13): commenting this out broke nginx immediately.
    #
    # nginx/web.conf.jinja renders it into a static `upstream { server X }` block,
    # which nginx resolves via system DNS at config-parse time (not the in-container
    # `resolver` directive, which only applies to variables). A hostname that fails to
    # resolve (no DNS / no internet) makes nginx fail to start with "host not found in
    # upstream" — THIS is what the "no external internet access" question is actually
    # guarding against. So on "no internet", point it at a loopback IP literal instead
    # of commenting it out: an IP literal never needs DNS, so nginx always starts; the
    # tracking upstream just gets connection-refused per request (harmless).
    local cur_matomo
    cur_matomo=$(getenv WEB__MATOMO_BACKEND_LOCATION configs.env || true)
    echo "  WEB__MATOMO_BACKEND_LOCATION = $cur_matomo"
    echo "  (external monitoring server — settings.py requires this field; it cannot be blank/commented out)"
    local ans
    read -rp "  Does this server have external internet access? [Y/n]: " ans
    if [[ -z $ans || $ans =~ ^[Yy]$ ]]; then
        echo "  -> Keeping WEB__MATOMO_BACKEND_LOCATION unchanged."
    else
        CONFIGS_UPDATES[WEB__MATOMO_BACKEND_LOCATION]="127.0.0.1:1"
        echo "  -> No internet: pointing WEB__MATOMO_BACKEND_LOCATION at 127.0.0.1:1 (IP literal, no DNS needed, keeps nginx startable)."
    fi
    echo

    # --- AI_LANDING_URL ---
    local cur_ai
    cur_ai=$(getenv AI_LANDING_URL configs.env || true)
    # If currently commented out, recover the value so we can show it as default.
    if [[ -z $cur_ai ]]; then
        cur_ai=$(grep "^#AI_LANDING_URL=" "$CONFIGS_FILE" | cut -d= -f2- || true)
    fi
    echo "  AI_LANDING_URL = $cur_ai"
    echo "  (GPU node endpoint for AI inference)"
    local ans
    read -rp "  Does this site have an AI Landing server? [Y/n]: " ans
    if [[ -z $ans || $ans =~ ^[Yy]$ ]]; then
        local ai_url
        while true; do
            ai_url=$(ask_str "  AI_LANDING_URL" "${cur_ai:-}")
            [[ $ai_url =~ ^https?:// ]] && break
            echo "  [ERROR] Must start with http:// or https://" >&2
        done
        CONFIGS_UPDATES[AI_LANDING_URL]="$ai_url"
        echo "  -> AI_LANDING_URL set to $ai_url"
    else
        CONFIGS_COMMENT_OUT+=(AI_LANDING_URL)
        echo "  -> Will comment out AI_LANDING_URL."
    fi
    echo

    # --- WEB_BACKEND__SITE_LICENSE_LIMIT ---
    local cur_license
    cur_license=$(getenv WEB_BACKEND__SITE_LICENSE_LIMIT configs.env || true)
    local license_limit
    license_limit=$(ask_str "  WEB_BACKEND__SITE_LICENSE_LIMIT" "${cur_license:-5}")
    CONFIGS_UPDATES[WEB_BACKEND__SITE_LICENSE_LIMIT]="$license_limit"
    echo

    # --- SMTP ---
    echo "  SMTP / alert email settings:"
    local cur_smtp_host cur_smtp_port cur_email_receiver
    cur_smtp_host=$(getenv SMTP_HOST configs.env || true)
    cur_smtp_port=$(getenv SMTP_PORT configs.env || true)
    cur_email_receiver=$(getenv EMAIL_RECEIVER configs.env || true)
    local smtp_host smtp_port email_receiver
    smtp_host=$(ask_str "  SMTP_HOST" "${cur_smtp_host:-}")
    smtp_port=$(ask_str "  SMTP_PORT" "${cur_smtp_port:-25}")
    email_receiver=$(ask_str "  EMAIL_RECEIVER" "${cur_email_receiver:-}")
    CONFIGS_UPDATES[SMTP_HOST]="$smtp_host"
    CONFIGS_UPDATES[SMTP_PORT]="$smtp_port"
    CONFIGS_UPDATES[EMAIL_RECEIVER]="$email_receiver"
    echo
}

# module_choice <env_value> <label> -> echoes 1 or 0
#   Non-empty <env_value> is used non-interactively (1/Y/y/yes -> 1, else 0);
#   otherwise prompt, defaulting to No.
module_choice() {
    local envval=$1 label=$2 ans
    if [[ -n $envval ]]; then
        case "$envval" in
            1|Y|y|yes|YES) echo 1 ;;
            *)             echo 0 ;;
        esac
        return
    fi
    read -rp "  Enable $label? [y/N]: " ans
    [[ $ans =~ ^[Yy]$ ]] && echo 1 || echo 0
}

# configure_module_switches: ask (or read from env) whether to enable each of the
# five optional front-end modules, staged into PREFS_UPDATES for prefs.env. All five
# are always offered; the key is appended if prefs.env lacks it (see set_or_append_env).
# 202609.1: these are UI-only toggles (no backend module / no MODULES= entry).
configure_module_switches() {
    echo "[INFO] Optional front-end modules (prefs.env). Default = No."
    echo "       Non-interactive override via env: MOD_AIHUB / MOD_EDUCATION / MOD_STUDY / MOD_QC / MOD_REGI (1|0)."
    echo
    local v
    v=$(module_choice "${MOD_AIHUB:-}"     "AI Hub (AI App page)");    PREFS_UPDATES[PREF__CAN_USE_AI_APP_PAGE]=$v;       echo "  -> AI Hub          = $v"
    v=$(module_choice "${MOD_EDUCATION:-}" "Education");               PREFS_UPDATES[PREF__CAN_USE_EDUCATION]=$v;         echo "  -> Education       = $v"
    v=$(module_choice "${MOD_STUDY:-}"     "Study Tool (Worklist)");   PREFS_UPDATES[PREF__CAN_USE_STUDY_TOOL]=$v;        echo "  -> Study Tool      = $v"
    v=$(module_choice "${MOD_QC:-}"        "Quality Control");         PREFS_UPDATES[PREF__CAN_USE_QUALITY_CONTROL]=$v;   echo "  -> Quality Control = $v"
    v=$(module_choice "${MOD_REGI:-}"      "Registration Tool");       PREFS_UPDATES[PREF__CAN_USE_REGISTRATION_TOOL]=$v; echo "  -> Registration    = $v"
    echo
}

# rdiv <num> <den> -> integer round(num/den)
rdiv() {
    echo $(( ( $1 + $2 / 2 ) / $2 ))
}


# load_fl_snapshot -> FL floors: a snapshot of the LIVE tph .env resource limits
# (the values that actually run stably in production; the previous hand-guessed
# floors were too low and caused start-up failures). Refresh whenever tph is
# re-tuned. Carries BOTH the current tph key names AND the 202609 renamed/new keys,
# each mapped to the nearest tph service, so the same floor applies under either
# naming:  IMAGE_ANALYSIS_SERVER_* <- IMAGE_ANALYSIS_WORKER_* (tph);
#          CLINICAL_FILE_IMPORT_*  <- AUTOIMPORT (tph).
# (mem values are integers in GB; the "g" suffix is added at write time.)
load_fl_snapshot() {
    FL_SNAP=(
        [UWSGI_CPUS_LIMIT]=4 [IMAGE_SERVER_CPUS_LIMIT]=6 [NGINX_CPUS_LIMIT]=1
        [WEBSOCKET_CPUS_LIMIT]=1 [DATABASE_CPUS_LIMIT]=4 [WORKER_CPUS_LIMIT]=1
        [WORKER_SERIAL_CPUS_LIMIT]=1 [HL7V2_SERVER_CPUS_LIMIT]=1 [IMAGE_SERVER_WORKER_CPUS_LIMIT]=1
        [IMAGE_ANALYSIS_WORKER_CPUS_LIMIT]=2 [IMAGE_ANALYSIS_SERVER_CPUS_LIMIT]=2 [CLINICAL_FILE_IMPORT_CPUS_LIMIT]=1
        [IMAGE_SERVER_HIGH_PRIORITY_WORKER_CPUS_LIMIT]=3 [IMAGE_SERVER_BACKGROUND_WORKER_CPUS_LIMIT]=3
        [MRXS_SERVER_CPUS_LIMIT]=4 [DICOM_SCP_CPUS_LIMIT]=2 [AUTOIMPORT_CPUS_LIMIT]=1
        [RABBITMQ_CPUS_LIMIT]=4 [REDIS_CPUS_LIMIT]=4 [CADDY_CPUS_LIMIT]=1
        [CRONTAB_WORKER_CPUS_LIMIT]=1 [SELF_CHECK_CPUS_LIMIT]=1
        [UWSGI_MEM_LIMIT]=4 [IMAGE_SERVER_MEM_LIMIT]=8 [IMAGE_ANALYSIS_WORKER_MEM_LIMIT]=2
        [IMAGE_ANALYSIS_SERVER_MEM_LIMIT]=2 [CLINICAL_FILE_IMPORT_MEM_LIMIT]=1 [HL7V2_SERVER_MEM_LIMIT]=5
        [DATABASE_MEM_LIMIT]=4 [IMAGE_SERVER_WORKER_MEM_LIMIT]=1 [WORKER_MEM_LIMIT]=10
        [WORKER_SERIAL_MEM_LIMIT]=10 [WEBSOCKET_MEM_LIMIT]=1 [AUTOIMPORT_MEM_LIMIT]=1
        [REDIS_MEM_LIMIT]=10 [MRXS_SERVER_MEM_LIMIT]=8 [IMAGE_SERVER_HIGH_PRIORITY_WORKER_MEM_LIMIT]=6
        [IMAGE_SERVER_BACKGROUND_WORKER_MEM_LIMIT]=6 [NGINX_MEM_LIMIT]=1 [CADDY_MEM_LIMIT]=2
        [RABBITMQ_MEM_LIMIT]=2 [DICOM_SCP_MEM_LIMIT]=4 [CRONTAB_WORKER_MEM_LIMIT]=2 [SELF_CHECK_MEM_LIMIT]=2
        [UWSGI_PROCESS_NUMBER]=4 [IMAGE_SERVER_PROCESS_NUMBER]=6 [WEBSOCKET_PROCESS_NUMBER]=2
        [MRXS_SERVER_PROCESS_NUMBER]=8 [WEB_WORKER_CONCURRENCY]=1 [WEB_IMAGE_SERVER_WORKER_CONCURRENCY]=1
        [IMAGE_ANALYSIS_WORKER_CONCURRENCY]=4 [IMAGE_ANALYSIS_SERVER_PROCESS_NUMBER]=2
        [WEB_IMAGE_SERVER_BACKGROUND_WORKER_CONCURRENCY]=4 [GIGASTORE_WORKER_CONCURRENCY]=1
    )
}

# load_builtin_ex_table -> fallback EX (example base), a snapshot of 202609.1
# .env.example. Used ONLY when the deployed .env.example cannot be read.
load_builtin_ex_table() {
    EX_BUILTIN=(
        [UWSGI_CPUS_LIMIT]=22 [IMAGE_SERVER_CPUS_LIMIT]=16 [NGINX_CPUS_LIMIT]=4 [WEBSOCKET_CPUS_LIMIT]=4
        [DATABASE_CPUS_LIMIT]=8 [WORKER_CPUS_LIMIT]=8 [WORKER_SERIAL_CPUS_LIMIT]=1 [HL7V2_SERVER_CPUS_LIMIT]=8
        [IMAGE_SERVER_WORKER_CPUS_LIMIT]=8 [IMAGE_ANALYSIS_SERVER_CPUS_LIMIT]=4 [CLINICAL_FILE_IMPORT_CPUS_LIMIT]=4
        [IMAGE_SERVER_HIGH_PRIORITY_WORKER_CPUS_LIMIT]=8 [IMAGE_SERVER_BACKGROUND_WORKER_CPUS_LIMIT]=8
        [MRXS_SERVER_CPUS_LIMIT]=4 [DICOM_SCP_CPUS_LIMIT]=2 [AUTOIMPORT_CPUS_LIMIT]=4 [RABBITMQ_CPUS_LIMIT]=4
        [REDIS_CPUS_LIMIT]=4 [CADDY_CPUS_LIMIT]=4 [CRONTAB_WORKER_CPUS_LIMIT]=1 [SELF_CHECK_CPUS_LIMIT]=1
        [UWSGI_MEM_LIMIT]=60 [IMAGE_SERVER_MEM_LIMIT]=32 [IMAGE_ANALYSIS_SERVER_MEM_LIMIT]=32 [CLINICAL_FILE_IMPORT_MEM_LIMIT]=8
        [HL7V2_SERVER_MEM_LIMIT]=60 [DATABASE_MEM_LIMIT]=32 [IMAGE_SERVER_WORKER_MEM_LIMIT]=32 [WORKER_MEM_LIMIT]=10
        [WORKER_SERIAL_MEM_LIMIT]=10 [WEBSOCKET_MEM_LIMIT]=6 [AUTOIMPORT_MEM_LIMIT]=8 [REDIS_MEM_LIMIT]=10
        [MRXS_SERVER_MEM_LIMIT]=8 [IMAGE_SERVER_HIGH_PRIORITY_WORKER_MEM_LIMIT]=32 [IMAGE_SERVER_BACKGROUND_WORKER_MEM_LIMIT]=32
        [NGINX_MEM_LIMIT]=2 [CADDY_MEM_LIMIT]=2 [RABBITMQ_MEM_LIMIT]=2 [DICOM_SCP_MEM_LIMIT]=4
        [CRONTAB_WORKER_MEM_LIMIT]=2 [SELF_CHECK_MEM_LIMIT]=2
        [UWSGI_PROCESS_NUMBER]=20 [IMAGE_SERVER_PROCESS_NUMBER]=20 [WEBSOCKET_PROCESS_NUMBER]=4 [MRXS_SERVER_PROCESS_NUMBER]=8
        [IMAGE_ANALYSIS_SERVER_PROCESS_NUMBER]=2 [WEB_WORKER_CONCURRENCY]=8 [WEB_IMAGE_SERVER_WORKER_CONCURRENCY]=4
        [WEB_IMAGE_SERVER_BACKGROUND_WORKER_CONCURRENCY]=4 [GIGASTORE_WORKER_CONCURRENCY]=2
    )
}

# kind_of <KEY> -> cpu|mem|num|"" (by suffix)
kind_of() {
    case "$1" in
        *_CPUS_LIMIT)                    echo cpu ;;
        *_MEM_LIMIT)                     echo mem ;;
        *_PROCESS_NUMBER|*_CONCURRENCY)  echo num ;;
        *)                               echo "" ;;
    esac
}

# num_prefix <val> -> leading integer ("10g" -> 10, "32" -> 32)
num_prefix() { local v=$1; v=${v%%[!0-9]*}; echo "${v:-0}"; }

# discover_ref_keys -> fill EX / KIND / FL / REF_KEYS (+ per-kind ordered lists) by
# scanning the DEPLOYED .env.example, so the managed key set + base values track the
# installed version. Falls back to the built-in 202609.1 table if unreadable.
discover_ref_keys() {
    local example="$website_path/.env.example"
    local line key val kind
    if [[ -r $example ]]; then
        echo "[INFO] Sizing base: $example (managed keys derived from the deployed version)."
        while IFS= read -r line; do
            [[ $line =~ ^[A-Z0-9_]+= ]] || continue
            key=${line%%=*}
            kind=$(kind_of "$key")
            [[ -n $kind ]] || continue
            val=$(num_prefix "${line#*=}")
            EX[$key]=$val; KIND[$key]=$kind; REF_KEYS+=("$key")
            case "$kind" in
                cpu) REF_KEYS_CPU+=("$key") ;;
                mem) REF_KEYS_MEM+=("$key") ;;
                num) REF_KEYS_NUM+=("$key") ;;
            esac
        done < "$example"
    fi
    if ((${#REF_KEYS[@]} == 0)); then
        echo "[WARN] $example not readable — using the built-in 202609.1 base table." >&2
        load_builtin_ex_table
        for key in "${!EX_BUILTIN[@]}"; do
            EX[$key]=${EX_BUILTIN[$key]}; KIND[$key]=$(kind_of "$key"); REF_KEYS+=("$key")
        done
        local sk
        for sk in $(printf '%s
' "${REF_KEYS[@]}" | sort); do
            case "$(kind_of "$sk")" in
                cpu) REF_KEYS_CPU+=("$sk") ;;
                mem) REF_KEYS_MEM+=("$sk") ;;
                num) REF_KEYS_NUM+=("$sk") ;;
            esac
        done
    fi
    # FL floor from the tph snapshot; a key with no tph analog gets a 1 insurance floor.
    for key in "${REF_KEYS[@]}"; do
        FL[$key]=${FL_SNAP[$key]:-1}
    done
}

compute_values() {
    # Unified per-service sizing (see file header):
    #   value = max( round(example_base * machine_ratio * k), tph_floor )
    # with machine_ratio = CORES/64 (cpu, process) or RAM_GB/128 (mem), k = pct/100.
    # Below the 4C/8G minimum, the tph floor becomes the base and is scaled DOWN by
    # the machine/4C8G ratio (no k), after an English warning.
    local BASE_CORES=64 BASE_RAM_GB=128 MIN_CORES=4 MIN_RAM_GB=8

    load_fl_snapshot
    discover_ref_keys

    BELOW_MIN=0
    if (( CORES < MIN_CORES || RAM_GB < MIN_RAM_GB )); then
        BELOW_MIN=1
        cat >&2 <<EOF

WARNING: Detected hardware (${CORES} cores / ${RAM_GB} GB RAM) is below the
recommended minimum of ${MIN_CORES} cores / ${MIN_RAM_GB} GB. aetherSlide will
very likely hit out-of-memory conditions and be unstable on this machine.
The reference minimum (tph) profile will be scaled down to fit, but this setup
is NOT recommended for production. Proceed at your own risk.

EOF
    fi

    local k base_ex base_fl kind val
    for k in "${REF_KEYS[@]}"; do
        base_ex=${EX[$k]}
        base_fl=${FL[$k]}
        kind=${KIND[$k]}

        if (( BELOW_MIN )); then
            # tph floor is the base; scale down by machine / 4C8G ratio, no pct.
            if [[ $kind == mem ]]; then
                val=$(rdiv $(( base_fl * RAM_GB )) "$MIN_RAM_GB")
            else
                val=$(rdiv $(( base_fl * CORES )) "$MIN_CORES")
            fi
            (( val < 1 )) && val=1
        else
            # scale from .env.example, then never drop below the tph floor.
            if [[ $kind == mem ]]; then
                val=$(rdiv $(( base_ex * RAM_GB * RAM_PCT )) $(( BASE_RAM_GB * 100 )))
            else
                val=$(rdiv $(( base_ex * CORES * CPU_PCT )) $(( BASE_CORES * 100 )))
            fi
            (( val < base_fl )) && val=$base_fl
        fi

        # A CPU limit can never exceed the physical core count.
        [[ $kind == cpu ]] && (( val > CORES )) && val=$CORES

        if [[ $kind == mem ]]; then
            ENV_UPDATES[$k]="${val}g"
        else
            ENV_UPDATES[$k]=$val
        fi
    done
}

show_plan() {
    echo "[INFO] Planned changes ($ENV_FILE):"
    if (( BELOW_MIN )); then
        echo "       (basis: tph minimum profile scaled down to ${CORES}C/${RAM_GB}G — BELOW the recommended 4C/8G minimum)"
    else
        echo "       (basis: .env.example scaled to ${CORES}C/${RAM_GB}G @ CPU ${CPU_PCT}% / RAM ${RAM_PCT}%, floored at the tph minimum)"
    fi
    printf "       %-48s %-12s -> %-12s\n" "VARIABLE" "CURRENT" "NEW"
    # Data path fixes (./data/* -> /data/*), recorded earlier as planned changes.
    local pk
    for pk in STORAGE_PATH BACKUP_PATH UPLOAD_PATH EXPORT_PATH EXPORT_EXTERNAL_PATH DATASET_EXPORT_PATH; do
        [[ -n ${ENV_UPDATES[$pk]:-} ]] || continue
        printf "       %-48s %-12s -> %-12s\n" "$pk" "$(current_env "$pk")" "${ENV_UPDATES[$pk]}"
    done
    # dynamic ordering: CPU limits, then MEM, then process/concurrency (discovery order)
    local k cur new flag
    for k in "${REF_KEYS_CPU[@]}" "${REF_KEYS_MEM[@]}" "${REF_KEYS_NUM[@]}"; do
        cur=$(current_env "$k")
        new=${ENV_UPDATES[$k]}
        flag=""
        [[ $cur == "$new" ]] && flag="(unchanged)"
        printf "       %-48s %-12s -> %-12s %s
" "$k" "$cur" "$new" "$flag"
    done

    echo
    echo "[INFO] Planned changes ($CONFIGS_FILE):"
    printf "       %-45s %-32s -> %s\n" "VARIABLE" "CURRENT" "NEW"
    local ckeys=(WEB_NETWORK_LOCATION WEB_BACKEND__ALLOWED_HOSTS WEB__MATOMO_BACKEND_LOCATION AI_LANDING_URL WEB_BACKEND__SITE_LICENSE_LIMIT SMTP_HOST SMTP_PORT EMAIL_RECEIVER)
    local ck ccur cnew cflag
    for ck in "${ckeys[@]}"; do
        ccur=$(getenv "$ck" configs.env || true)
        cnew=${CONFIGS_UPDATES[$ck]:-}
        cflag=""
        [[ $ccur == "$cnew" ]] && cflag="(unchanged)"
        printf "       %-45s %-32s -> %-32s %s\n" "$ck" "$ccur" "$cnew" "$cflag"
    done
    for ck in "${CONFIGS_COMMENT_OUT[@]}"; do
        ccur=$(getenv "$ck" configs.env || true)
        printf "       %-45s %-32s -> %s\n" "$ck" "$ccur" "(commented out)"
    done
    echo
    echo "[INFO] Planned changes ($PREFS_FILE):"
    printf "       %-45s %-12s -> %-12s\n" "VARIABLE" "CURRENT" "NEW"
    local pkk pcur pnew pflag
    for pkk in PREF__CAN_USE_AI_APP_PAGE PREF__CAN_USE_EDUCATION PREF__CAN_USE_STUDY_TOOL PREF__CAN_USE_QUALITY_CONTROL PREF__CAN_USE_REGISTRATION_TOOL; do
        pcur=$(getenv "$pkk" prefs.env 2>/dev/null || true)
        pnew=${PREFS_UPDATES[$pkk]}
        pflag=""
        [[ $pcur == "$pnew" ]] && pflag="(unchanged)"
        [[ -z $pcur ]] && pflag="(will append)"
        printf "       %-45s %-12s -> %-12s %s\n" "$pkk" "$pcur" "$pnew" "$pflag"
    done
    echo
    echo "[INFO] Planned changes ($TIER_FILE):"
    local cur_disk
    cur_disk=$(grep -E "max_percent:" "$TIER_FILE" | grep -oE "[0-9]+" | head -n1)
    printf "       %-40s %-12s -> %-12s\n" "max_percent" "$cur_disk" "$DISK_PCT"
    echo
}

# current_env <key> -> echoes the current raw value from .env (empty if absent)
current_env() {
    grep -m1 "^$1=" "$ENV_FILE" | cut -d= -f2- || true
}

confirm_and_apply() {
    local ans
    read -rp "Apply changes? (target files are backed up first) [Y/n]: " ans
    if [[ -n $ans && ! $ans =~ ^[Yy]$ ]]; then
        echo "[INFO] Cancelled, no changes written."
        exit 0
    fi

    # Back up every file we are about to modify, timestamped, before writing.
    local ts f
    ts=$(date +%Y%m%d%H%M%S)
    for f in "$ENV_FILE" "$CONFIGS_FILE" "$PREFS_FILE" "$TIER_FILE"; do
        [[ -f $f ]] && cp -p "$f" "$f.bak.$ts" && echo "[INFO] Backed up: $f -> $f.bak.$ts"
    done

    local key
    for key in "${!ENV_UPDATES[@]}"; do
        update_env "$key" "${ENV_UPDATES[$key]}" "$ENV_FILE"
    done

    # configs.env: value updates
    for key in "${!CONFIGS_UPDATES[@]}"; do
        update_env "$key" "${CONFIGS_UPDATES[$key]}" "$CONFIGS_FILE"
    done
    # configs.env: comment-outs
    for key in "${CONFIGS_COMMENT_OUT[@]}"; do
        comment_out_env "$key" "$CONFIGS_FILE"
    done

    # prefs.env: front-end module switches (append the key if it is missing)
    for key in "${!PREFS_UPDATES[@]}"; do
        set_or_append_env "$key" "${PREFS_UPDATES[$key]}" "$PREFS_FILE"
    done

    # gigastore disk limit
    if grep -qE "max_percent:" "$TIER_FILE"; then
        sed -i -E "s|(max_percent:[[:space:]]*)[0-9]+|\1$DISK_PCT|" "$TIER_FILE"
    else
        echo "[WARN] max_percent not found in $TIER_FILE, skipping." >&2
    fi

    echo "[INFO] Done. Review $ENV_FILE, $CONFIGS_FILE, $PREFS_FILE and $TIER_FILE before starting services."
}

# comment_out_env <key> <file>
comment_out_env() {
    local key=$1 file=$2
    if grep -q "^$key=" "$file"; then
        sed -i "s|^$key=|#$key=|" "$file"
    else
        echo "[WARN] $key not found or already commented in $file, skipping." >&2
    fi
}

run_populate_working_dir() {
    # If WEB_NETWORK_LOCATION host changed, remove the site cert so 2_populate_working_dir.sh
    # regenerates it for the new host (the script skips generation when cert.pem already exists).
    local tls_raw new_host tls_abs cert_file ca_file
    tls_raw=$(getenv TLS_PATH .env || true)
    new_host="${CONFIGS_UPDATES[WEB_NETWORK_LOCATION]%%:*}"
    if [[ -n $tls_raw && -n $new_host ]]; then
        if [[ $tls_raw == /* ]]; then tls_abs=$tls_raw; else tls_abs="$website_path/${tls_raw#./}"; fi
        cert_file="$tls_abs/cert.pem"
        ca_file="$tls_abs/ca-cert.internal.pem"
        if [[ -f $cert_file ]]; then
            # SAFETY: only ever delete a cert we can POSITIVELY prove was self-signed by our own
            # internal CA. Anything else — externally provided (MIS-issued), or internal CA absent,
            # or verify inconclusive — is treated as "do not touch". An external cert/key must
            # never be deleted. So deletion requires (a) the internal CA file exists AND
            # (b) openssl verify confirms cert.pem chains to it.
            local is_internal=0
            if [[ -f $ca_file ]] && openssl verify -CAfile "$ca_file" "$cert_file" >/dev/null 2>&1; then
                is_internal=1
            fi
            if ((is_internal)); then
                if ! openssl x509 -in "$cert_file" -noout -text 2>/dev/null | grep -qF "$new_host"; then
                    echo "[INFO] Internal self-signed cert host mismatch — removing cert.pem / key.pem for regeneration."
                    rm -f "$tls_abs/cert.pem" "$tls_abs/key.pem" "$tls_abs/req.pem"
                fi
            else
                # Externally-provided (e.g. MIS) or not provably internal → keep it, never delete.
                echo "[INFO] $cert_file is not a self-signed internal-CA cert — leaving cert.pem/key.pem untouched."
                echo "       (External/MIS cert preserved.) Ensure WEB_NETWORK_LOCATION host ($new_host) matches its CN/SAN."
            fi
        fi
    fi

    echo "[INFO] Running 2_populate_working_dir.sh (TLS + secrets setup)..."
    # Must run from website_path so relative paths in .env (e.g. TLS_PATH=./data/ssl)
    # resolve correctly. Using a subshell keeps the parent's CWD unchanged.
    (cd "$website_path" && bash "$dirpath/2_populate_working_dir.sh")
    echo

    local su_pass_file="$website_path/secrets/WEB_BACKEND__SU_PASSWORD"
    if [[ -f "$su_pass_file" ]]; then
        local su_pass
        su_pass=$(cat "$su_pass_file")
        echo "[INFO] default login = superuser, password=$su_pass"
    else
        echo "[WARN] $su_pass_file not found — superuser password unavailable." >&2
    fi
}

# set_or_append_env <key> <value> <file> -> update if present (or commented),
# otherwise append. Used for the module switches so a version whose prefs.env lacks
# the key still gets it set.
set_or_append_env() {
    local key=$1 val=$2 file=$3
    if grep -q "^$key=" "$file"; then
        sed -i "s|^$key=.*|$key=$val|" "$file"
    elif grep -q "^#$key=" "$file"; then
        sed -i "s|^#$key=.*|$key=$val|" "$file"
    else
        printf '%s=%s\n' "$key" "$val" >> "$file"
        echo "[INFO] $key was absent in $(basename "$file") — appended." >&2
    fi
}

# update_env <key> <value> <file>
update_env() {
    local key=$1 val=$2 file=$3
    if grep -q "^$key=" "$file"; then
        sed -i "s|^$key=.*|$key=$val|" "$file"
    elif grep -q "^#$key=" "$file"; then
        # Key was commented out (e.g. previous "No" answer) — un-comment and set new value.
        sed -i "s|^#$key=.*|$key=$val|" "$file"
    else
        echo "[WARN] $key not found in $file, skipping." >&2
    fi
}

main
