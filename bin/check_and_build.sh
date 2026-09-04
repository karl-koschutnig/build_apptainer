#!/bin/bash
# Daily Apptainer auto-build for tracked BIDS apps.
#
# For each app in config/apps.conf: fetch Docker Hub tags, keep only the
# ones matching that app's tag_regex ("full releases" -- excludes latest/
# unstable/rc/experimental/etc by construction), and build the newest one
# with vendor/build_apptainer.sh if it isn't already built.
#
# Usage: check_and_build.sh [--dry-run]

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$REPO_DIR/config/apps.conf"
BUILD_SCRIPT="$REPO_DIR/vendor/build_apptainer.sh"
LOG_DIR="$REPO_DIR/logs"
LOG_FILE="$LOG_DIR/build.log"
LOCK_FILE="$LOG_DIR/.lock"
STATE_DIR="$REPO_DIR/state"
STATE_FILE="$STATE_DIR/versions.json"

PATHS_ENV="$REPO_DIR/config/paths.env"
if [ ! -f "$PATHS_ENV" ]; then
    echo "check_and_build.sh: $PATHS_ENV not found. Copy config/paths.env.example to config/paths.env and edit it for your setup (see README Quick Setup)." >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$PATHS_ENV"
: "${TMP_BASE:?TMP_BASE not set in $PATHS_ENV}"
: "${DISK_CHECK_PATH:?DISK_CHECK_PATH not set in $PATHS_ENV}"
: "${MIN_FREE_GB:?MIN_FREE_GB not set in $PATHS_ENV}"
: "${DSISTUDIO_BUILD_SCRIPT:?DSISTUDIO_BUILD_SCRIPT not set in $PATHS_ENV}"
: "${DSISTUDIO_IMAGES_DIR:?DSISTUDIO_IMAGES_DIR not set in $PATHS_ENV}"

# DSI Studio is a special case, not a config/apps.conf row: it has no Docker
# Hub repo with usable version tags, its GPU/CUDA build only exists as a
# GitHub release asset, and per-project analyses pin to specific
# dsi_studio_hou-<date>.sif paths under DSISTUDIO_SIF_DIR (see
# dsi_studio_pipeline.py's _resolve_apptainer_image()) -- so unlike every
# other app here, its output dir/naming can't be moved under CONTAINER_DIR
# and files there must never be overwritten, only added to.
DSISTUDIO_SIF_DIR="$DSISTUDIO_IMAGES_DIR/dsi_studio"
DSISTUDIO_REPO="frankyeh/DSI-Studio"
DSISTUDIO_ASSET_NAME="dsi_studio_ubuntu2204.zip"

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

mkdir -p "$LOG_DIR" "$STATE_DIR"

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "SKIP: another run is already in progress (lock held on $LOCK_FILE)."
    exit 0
fi

log "=== check_and_build.sh starting (dry_run=$DRY_RUN) ==="

avail_gb=$(df --output=avail -B1G "$DISK_CHECK_PATH" 2>/dev/null | tail -1 | tr -d ' ')
if [ -z "$avail_gb" ]; then
    log "ERROR: could not determine free space on $DISK_CHECK_PATH, aborting."
    exit 1
fi
if [ "$avail_gb" -lt "$MIN_FREE_GB" ]; then
    log "ERROR: only ${avail_gb}G free on $DISK_CHECK_PATH (need >= ${MIN_FREE_GB}G), aborting run."
    exit 1
fi
log "Disk check OK: ${avail_gb}G free on $DISK_CHECK_PATH."

mkdir -p "$TMP_BASE"

for cmd in curl jq apptainer; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "ERROR: required command '$cmd' not found on PATH, aborting."
        exit 1
    fi
done

fetch_tags() {
    local docker_repo="$1"
    local page=1
    local tags=()
    local response next page_tags

    while true; do
        response=$(curl -s -m 30 "https://registry.hub.docker.com/v2/repositories/${docker_repo}/tags?page=${page}&page_size=100")
        page_tags=$(printf '%s' "$response" | jq -r '.results[]?.name')
        if [ -n "$page_tags" ]; then
            while IFS= read -r t; do tags+=("$t"); done <<< "$page_tags"
        fi
        next=$(printf '%s' "$response" | jq -r '.next // "null"')
        if [ "$next" == "null" ]; then
            break
        fi
        page=$((page + 1))
    done

    printf '%s\n' "${tags[@]}"
}

# Highest full-release tag already on disk for an app, regardless of which
# separator (_/-) its .sif filename happens to use. Empty if none found.
find_installed_version() {
    local output_dir="$1" image_name="$2" tag_regex="$3"
    local f base tag installed=()

    shopt -s nullglob
    for f in "$output_dir"/"${image_name}"[-_]*.sif; do
        base=$(basename "$f")
        tag="${base#${image_name}?}"
        tag="${tag%.sif}"
        if [[ "$tag" =~ $tag_regex ]]; then
            installed+=("$tag")
        fi
    done
    shopt -u nullglob

    if [ ${#installed[@]} -eq 0 ]; then
        return 0
    fi
    printf '%s\n' "${installed[@]}" | sort -V | tail -1
}

# DSI Studio's release tags don't reliably ship the Linux CUDA asset (the
# newest release as of 2026-08 is Windows-only) -- it lives under an older
# tag that gets refreshed via `gh release upload --clobber` instead of a
# fresh tag. Walk releases newest-first and use whichever currently has it.
# Prints "<browser_download_url>\t<asset_updated_at>", empty if none found.
resolve_dsistudio_asset() {
    local releases_json
    releases_json=$(curl -s -m 30 "https://api.github.com/repos/${DSISTUDIO_REPO}/releases?per_page=20")
    printf '%s' "$releases_json" | jq -r --arg name "$DSISTUDIO_ASSET_NAME" '
        [.[] | select(.assets[]?.name == $name)][0] as $r
        | if $r == null then empty
          else ($r.assets[] | select(.name == $name) | .browser_download_url) + "\t" +
               ($r.assets[] | select(.name == $name) | .updated_at)
          end'
}

# Highest dsi_studio_hou-<date>.sif on disk, empty if none found.
find_installed_dsistudio() {
    shopt -s nullglob
    local f=("$DSISTUDIO_SIF_DIR"/dsi_studio_hou-*.sif)
    shopt -u nullglob
    [ ${#f[@]} -eq 0 ] && return 0
    printf '%s\n' "${f[@]}" | sort -V | tail -1
}

state_tmp=$(mktemp -p "$STATE_DIR")
trap 'rm -f "$state_tmp"' EXIT

record_state() {
    local name="$1" docker_repo="$2" latest_available="$3" installed="$4" installed_sif="$5" status="$6"
    jq -n \
        --arg name "$name" \
        --arg docker_repo "$docker_repo" \
        --arg latest_available "$latest_available" \
        --arg installed "$installed" \
        --arg installed_sif "$installed_sif" \
        --arg status "$status" \
        --arg checked_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        '{name:$name, docker_repo:$docker_repo, latest_available:$latest_available,
          installed:$installed, installed_sif:$installed_sif, status:$status,
          last_checked:$checked_at}' >> "$state_tmp"
}

write_state_file() {
    if [ -s "$state_tmp" ]; then
        jq -s 'map({(.name): (. | del(.name))}) | add' "$state_tmp" > "$STATE_FILE"
    fi
}

overall_status=0
apps_processed=0
built_summary=()

# DSI Studio special case (see the DSISTUDIO_* comment near the top): checks
# GitHub releases instead of Docker Hub tags, and reuses/never overwrites the
# existing dsi_studio_hou-<date>.sif convention that per-project pins depend
# on, but otherwise plugs into the same log/state/notify/sync machinery as
# every config/apps.conf entry.
process_dsistudio() {
    local name="dsistudio" source_label="github:${DSISTUDIO_REPO}"
    apps_processed=$((apps_processed + 1))
    log "--- $name ($source_label) ---"

    if [ ! -x "$DSISTUDIO_BUILD_SCRIPT" ]; then
        log "ERROR [$name]: build script not found or not executable: $DSISTUDIO_BUILD_SCRIPT, skipping."
        record_state "$name" "$source_label" "" "" "" "fetch_error"
        overall_status=1
        return
    fi

    local installed_sif installed_version=""
    installed_sif=$(find_installed_dsistudio)
    if [ -n "$installed_sif" ]; then
        installed_version=$(basename "$installed_sif" .sif)
        installed_version="${installed_version#dsi_studio_}"
    fi

    local resolved asset_url asset_updated
    resolved=$(resolve_dsistudio_asset)
    if [ -z "$resolved" ]; then
        log "ERROR [$name]: no recent GitHub release ships $DSISTUDIO_ASSET_NAME, skipping."
        record_state "$name" "$source_label" "" "$installed_version" "$installed_sif" "fetch_error"
        overall_status=1
        return
    fi
    IFS=$'\t' read -r asset_url asset_updated <<< "$resolved"

    # asset_updated is a proxy for the embedded build date, used only to
    # decide whether a rebuild looks necessary without downloading first --
    # the actual filename always comes from the binary's own --version
    # output post-build (see build_image.sh), which may land on a
    # neighboring date.
    local latest_tag="hou-${asset_updated%%T*}"
    local expected_sif="$DSISTUDIO_SIF_DIR/dsi_studio_${latest_tag}.sif"

    if [ -f "$expected_sif" ]; then
        log "OK [$name]: up to date at $latest_tag ($expected_sif already exists)."
        record_state "$name" "$source_label" "$latest_tag" "$latest_tag" "$expected_sif" "up_to_date"
        return
    fi

    log "NEW [$name]: newest available build looks like $latest_tag, not yet built (expected $expected_sif)."

    if [ "$DRY_RUN" = true ]; then
        log "DRY-RUN [$name]: would run: DSI_ASSET_URL=$asset_url $DSISTUDIO_BUILD_SCRIPT"
        record_state "$name" "$source_label" "$latest_tag" "$installed_version" "$installed_sif" "update_available"
        return
    fi

    local wrapper_log="$LOG_DIR/wrapper_${name}_${latest_tag}.log"
    log "BUILD [$name]: starting build -> $DSISTUDIO_SIF_DIR (wrapper output: $wrapper_log)"
    if DSI_ASSET_URL="$asset_url" DSI_APPTAINER_IMAGES_DIR="$DSISTUDIO_SIF_DIR" "$DSISTUDIO_BUILD_SCRIPT" >"$wrapper_log" 2>&1; then
        local built_sif built_version
        built_sif=$(find_installed_dsistudio)
        built_version=$(basename "$built_sif" .sif)
        built_version="${built_version#dsi_studio_}"
        log "BUILD [$name]: succeeded ($built_sif)."
        rm -f "$wrapper_log"
        record_state "$name" "$source_label" "$built_version" "$built_version" "$built_sif" "built"
        built_summary+=("$name  $source_label  -> $built_sif")
    else
        log "BUILD [$name]: FAILED (exit $?). See $wrapper_log for details."
        record_state "$name" "$source_label" "$latest_tag" "$installed_version" "$installed_sif" "build_failed"
        overall_status=1
    fi
}

while IFS='|' read -r name docker_repo tag_regex output_dir; do
    name=$(echo "$name" | xargs)
    docker_repo=$(echo "$docker_repo" | xargs)
    tag_regex=$(echo "$tag_regex" | xargs)
    output_dir=$(echo "$output_dir" | xargs)

    [ -z "$name" ] && continue
    [[ "$name" == \#* ]] && continue

    apps_processed=$((apps_processed + 1))
    log "--- $name ($docker_repo) ---"
    image_name="${docker_repo##*/}"

    all_tags=$(fetch_tags "$docker_repo")
    if [ -z "$all_tags" ]; then
        log "ERROR [$name]: no tags returned for $docker_repo, skipping."
        installed_version=$(find_installed_version "$output_dir" "$image_name" "$tag_regex")
        record_state "$name" "$docker_repo" "" "$installed_version" "" "fetch_error"
        overall_status=1
        continue
    fi

    full_release_tags=$(printf '%s\n' "$all_tags" | grep -E "$tag_regex" || true)
    if [ -z "$full_release_tags" ]; then
        log "WARN [$name]: no tags matched regex '$tag_regex', skipping."
        installed_version=$(find_installed_version "$output_dir" "$image_name" "$tag_regex")
        record_state "$name" "$docker_repo" "" "$installed_version" "" "no_tags_matched"
        continue
    fi

    latest_tag=$(printf '%s\n' "$full_release_tags" | sort -V | tail -1)
    # New builds land as <image>_<tag>.sif (build_apptainer.sh's own
    # convention), but some pre-existing local builds use <image>-<tag>.sif
    # (e.g. freesurfer-8.2.0.sif) -- match either separator.
    expected_sif="${output_dir}/${image_name}_${latest_tag}.sif"
    shopt -s nullglob
    existing_sifs=("$output_dir"/"${image_name}"[-_]"${latest_tag}".sif)
    shopt -u nullglob

    if [ ${#existing_sifs[@]} -gt 0 ]; then
        log "OK [$name]: up to date at $latest_tag (${existing_sifs[0]} already exists)."
        record_state "$name" "$docker_repo" "$latest_tag" "$latest_tag" "${existing_sifs[0]}" "up_to_date"
        continue
    fi

    installed_version=$(find_installed_version "$output_dir" "$image_name" "$tag_regex")
    installed_sif=""
    if [ -n "$installed_version" ]; then
        shopt -s nullglob
        prev_sifs=("$output_dir"/"${image_name}"[-_]"${installed_version}".sif)
        shopt -u nullglob
        [ ${#prev_sifs[@]} -gt 0 ] && installed_sif="${prev_sifs[0]}"
    fi

    log "NEW [$name]: latest full release is $latest_tag, not yet built (expected $expected_sif)."

    if [ "$DRY_RUN" = true ]; then
        log "DRY-RUN [$name]: would run: $BUILD_SCRIPT -o $output_dir -t $TMP_BASE --docker-repo $docker_repo --docker-tag $latest_tag"
        record_state "$name" "$docker_repo" "$latest_tag" "$installed_version" "$installed_sif" "update_available"
        continue
    fi

    mkdir -p "$output_dir"
    # build_apptainer.sh's own stdout is mostly a banner + a spinner that
    # never emits newlines (fine on a TTY, unreadable noise once appended to
    # a plain log file) -- capture it separately rather than in build.log.
    wrapper_log="$LOG_DIR/wrapper_${name}_${latest_tag}.log"
    log "BUILD [$name]: starting build of ${docker_repo}:${latest_tag} -> $output_dir (wrapper output: $wrapper_log)"
    if "$BUILD_SCRIPT" -o "$output_dir" -t "$TMP_BASE" --docker-repo "$docker_repo" --docker-tag "$latest_tag" >"$wrapper_log" 2>&1; then
        log "BUILD [$name]: succeeded ($expected_sif)."
        rm -f "$wrapper_log"
        record_state "$name" "$docker_repo" "$latest_tag" "$latest_tag" "$expected_sif" "built"
        built_summary+=("$name  ${docker_repo}:${latest_tag}  -> $expected_sif")
    else
        log "BUILD [$name]: FAILED (exit $?). See $wrapper_log and ${expected_sif%.sif}.log for details."
        record_state "$name" "$docker_repo" "$latest_tag" "$installed_version" "$installed_sif" "build_failed"
        overall_status=1
    fi
done < <(grep -vE '^\s*(#|$)' "$CONFIG_FILE")

process_dsistudio

write_state_file

if $DRY_RUN; then
    log "SYNC-ALL: skipped (dry-run)."
elif images_all_output=$("$REPO_DIR/bin/sync_images_all.sh" 2>&1); then
    linked_count=$(grep -c '\.sif$' <<< "$images_all_output" || true)
    log "SYNC-ALL: consolidated image directory refreshed ($linked_count new hardlink(s))."
else
    log "SYNC-ALL: WARN failed to refresh consolidated image directory: $images_all_output"
fi

if [ ${#built_summary[@]} -gt 0 ]; then
    sync_output=$("$REPO_DIR/bin/sync_datalad.sh" 2>&1)
    sync_status=$?
    synced_sifs=()
    case "$sync_status" in
        0)
            while IFS= read -r line; do
                [[ "$line" == *.sif ]] && synced_sifs+=("$(basename "$line")")
            done <<< "$sync_output"
            log "SYNC: pushed ${#synced_sifs[@]} sif file(s) to datalad server."
            ;;
        3) log "SYNC: not configured yet (config/datalad.env missing), skipping sync." ;;
        *) log "SYNC: WARN failed to push to datalad server (exit $sync_status): $sync_output"; overall_status=1 ;;
    esac

    subject="bids_apptainer_autobuild: ${#built_summary[@]} new container(s) built"
    notify_body=$(printf 'New Apptainer image(s) built on %s:\n\n%s\n' "$(hostname)" "$(printf '%s\n' "${built_summary[@]}")")
    if [ "$sync_status" -eq 0 ]; then
        if [ ${#synced_sifs[@]} -gt 0 ]; then
            notify_body+=$(printf '\nSynced to datalad server:\n%s\n' "$(printf '%s\n' "${synced_sifs[@]}")")
        else
            notify_body+=$'\nAlready in sync with datalad server (nothing new to transfer).\n'
        fi
    elif [ "$sync_status" -ne 3 ]; then
        notify_body+=$'\nWARNING: datalad server sync FAILED, new image(s) only on this host.\n'
    fi
    notify_output=$("$REPO_DIR/bin/notify_ntfy.sh" "$subject" <<< "$notify_body" 2>&1)
    notify_status=$?
    case "$notify_status" in
        0) log "NOTIFY: ntfy notification sent for ${#built_summary[@]} new build(s)." ;;
        3) log "NOTIFY: not configured yet (config/ntfy.env missing), skipping notification." ;;
        *) log "NOTIFY: WARN failed to send notification (exit $notify_status): $notify_output" ;;
    esac
fi

log "=== check_and_build.sh finished: $apps_processed app(s) processed, exit status $overall_status ==="
exit "$overall_status"
