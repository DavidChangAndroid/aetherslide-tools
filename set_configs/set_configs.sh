#!/bin/bash

# Interactive helper to fill hardware-dependent resource limits in .env and
# the gigastore disk limit in configs/gigastore/tier_configs.yaml, based on the
# detected machine and three headroom percentages (CPU / RAM / DISK).
#
# Run this once after each installation instead of hand-editing every limit.
# Service limits stay independent "ceilings" (they may overlap / oversubscribe);
# this only caps each one relative to this machine's size.

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

# Defaults for the three knobs (percent).
DEFAULT_CPU_PCT=80
DEFAULT_RAM_PCT=80
DEFAULT_DISK_PCT=95

declare -A ENV_UPDATES
declare -A CONFIGS_UPDATES
CONFIGS_COMMENT_OUT=()

main() {
    fix_default_data_paths
    ensure_docker_group
    check_disk_encryption
    check_storage_mounts
    configure_site_settings
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

    # vol001 under STORAGE_PATH must always exist.
    local storage_raw storage_p vol001_path
    storage_raw=$(resolve_path_raw STORAGE_PATH)
    if [[ -n $storage_raw ]]; then
        if [[ $storage_raw == ./* || $storage_raw == . ]]; then
            storage_p="$website_path/${storage_raw#./}"
        else
            storage_p="$storage_raw"
        fi
        vol001_path="$storage_p/vol001"

        if [[ ! -d $vol001_path ]]; then
            sudo mkdir -p "$vol001_path" && echo "[INFO] Created: $vol001_path"
        fi
        echo
    fi
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
    local cur_matomo
    cur_matomo=$(getenv WEB__MATOMO_BACKEND_LOCATION configs.env || true)
    echo "  WEB__MATOMO_BACKEND_LOCATION = $cur_matomo"
    echo "  (external monitoring server — if unreachable, NGINX will hang on startup)"
    local ans
    read -rp "  Does this server have external internet access? [Y/n]: " ans
    if [[ -z $ans || $ans =~ ^[Yy]$ ]]; then
        echo "  -> Keeping WEB__MATOMO_BACKEND_LOCATION unchanged."
    else
        CONFIGS_COMMENT_OUT+=(WEB__MATOMO_BACKEND_LOCATION)
        echo "  -> Will comment out WEB__MATOMO_BACKEND_LOCATION."
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

compute_values() {
    local cpu_full=$((CORES * CPU_PCT / 100))
    local cpu_half=$((CORES * CPU_PCT / 200))
    local mem_full=$((RAM_GB * RAM_PCT / 100))
    local mem_half=$((RAM_GB * RAM_PCT / 200))
    ((cpu_full < 1)) && cpu_full=1
    ((cpu_half < 1)) && cpu_half=1
    ((mem_full < 1)) && mem_full=1
    ((mem_half < 1)) && mem_half=1

    # Bucket A: flagship, full cap
    ENV_UPDATES[UWSGI_CPUS_LIMIT]=$cpu_full
    ENV_UPDATES[IMAGE_SERVER_CPUS_LIMIT]=$cpu_full
    ENV_UPDATES[UWSGI_MEM_LIMIT]=${mem_full}g
    ENV_UPDATES[IMAGE_SERVER_MEM_LIMIT]=${mem_full}g
    ENV_UPDATES[IMAGE_ANALYSIS_WORKER_MEM_LIMIT]=${mem_full}g
    ENV_UPDATES[HL7V2_SERVER_MEM_LIMIT]=${mem_full}g

    # Bucket B: major, half cap
    ENV_UPDATES[DATABASE_CPUS_LIMIT]=$cpu_half
    ENV_UPDATES[WORKER_CPUS_LIMIT]=$cpu_half
    ENV_UPDATES[HL7V2_SERVER_CPUS_LIMIT]=$cpu_half
    ENV_UPDATES[IMAGE_SERVER_WORKER_CPUS_LIMIT]=$cpu_half
    ENV_UPDATES[CADDY_CPUS_LIMIT]=$cpu_half
    ENV_UPDATES[DATABASE_MEM_LIMIT]=${mem_half}g
    ENV_UPDATES[IMAGE_SERVER_WORKER_MEM_LIMIT]=${mem_half}g

    # process / concurrency, aligned to each service's bucket
    ENV_UPDATES[UWSGI_PROCESS_NUMBER]=$cpu_full
    ENV_UPDATES[IMAGE_SERVER_PROCESS_NUMBER]=$cpu_full
    ENV_UPDATES[WEB_WORKER_CONCURRENCY]=$cpu_half
    ENV_UPDATES[WEB_IMAGE_SERVER_WORKER_CONCURRENCY]=$cpu_half
}

show_plan() {
    echo "[INFO] Planned changes ($ENV_FILE):"
    printf "       %-40s %-12s -> %-12s\n" "VARIABLE" "CURRENT" "NEW"
    # Data path fixes (./data/* -> /data/*), recorded earlier as planned changes.
    local pk
    for pk in STORAGE_PATH BACKUP_PATH UPLOAD_PATH EXPORT_PATH EXPORT_EXTERNAL_PATH DATASET_EXPORT_PATH; do
        [[ -n ${ENV_UPDATES[$pk]:-} ]] || continue
        printf "       %-40s %-12s -> %-12s\n" "$pk" "$(current_env "$pk")" "${ENV_UPDATES[$pk]}"
    done
    # stable, grouped ordering
    local keys=(
        UWSGI_CPUS_LIMIT IMAGE_SERVER_CPUS_LIMIT
        UWSGI_MEM_LIMIT IMAGE_SERVER_MEM_LIMIT IMAGE_ANALYSIS_WORKER_MEM_LIMIT HL7V2_SERVER_MEM_LIMIT
        DATABASE_CPUS_LIMIT WORKER_CPUS_LIMIT HL7V2_SERVER_CPUS_LIMIT IMAGE_SERVER_WORKER_CPUS_LIMIT CADDY_CPUS_LIMIT
        DATABASE_MEM_LIMIT IMAGE_SERVER_WORKER_MEM_LIMIT
        UWSGI_PROCESS_NUMBER IMAGE_SERVER_PROCESS_NUMBER WEB_WORKER_CONCURRENCY WEB_IMAGE_SERVER_WORKER_CONCURRENCY
    )
    local k cur new
    for k in "${keys[@]}"; do
        cur=$(current_env "$k")
        new=${ENV_UPDATES[$k]}
        local flag=""
        [[ $cur == "$new" ]] && flag="(unchanged)"
        printf "       %-40s %-12s -> %-12s %s\n" "$k" "$cur" "$new" "$flag"
    done

    echo
    echo "[INFO] Planned changes ($CONFIGS_FILE):"
    printf "       %-45s %-32s -> %s\n" "VARIABLE" "CURRENT" "NEW"
    local ckeys=(WEB_NETWORK_LOCATION WEB_BACKEND__ALLOWED_HOSTS AI_LANDING_URL WEB_BACKEND__SITE_LICENSE_LIMIT SMTP_HOST SMTP_PORT EMAIL_RECEIVER)
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
    read -rp "Apply changes? Consider running ./bin/backup_config_files.sh first. [Y/n]: " ans
    if [[ -n $ans && ! $ans =~ ^[Yy]$ ]]; then
        echo "[INFO] Cancelled, no changes written."
        exit 0
    fi

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

    # gigastore disk limit
    if grep -qE "max_percent:" "$TIER_FILE"; then
        sed -i -E "s|(max_percent:[[:space:]]*)[0-9]+|\1$DISK_PCT|" "$TIER_FILE"
    else
        echo "[WARN] max_percent not found in $TIER_FILE, skipping." >&2
    fi

    echo "[INFO] Done. Review $ENV_FILE, $CONFIGS_FILE and $TIER_FILE before starting services."
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