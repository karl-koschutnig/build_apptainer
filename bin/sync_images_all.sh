#!/bin/bash
# Consolidate every built .sif (DSI Studio + every config/apps.conf app)
# into one flat, browsable directory via hardlinks, so nobody has to know
# which per-app subfolder under /data/local/container a given image lives
# in. Hardlinks only ever ADD a new name for an existing inode - they never
# move, rename, or touch the original file, so no project's pinned image
# path (e.g. dsistuido's <project_root>/code/dsistudio/dsi_studio_image.json)
# is ever affected by this, and nothing here can cause an in-progress
# analysis to silently switch versions mid-project.
#
# Symlinks (e.g. *_latest.sif, dsi_studio_latest.sif) are skipped on
# purpose - this directory is for picking a *specific* pinned build, not
# a moving "latest" target.
set -euo pipefail

CONTAINER_DIR="${CONTAINER_DIR:-/data/local/container}"
DSISTUDIO_IMAGES_DIR="${DSISTUDIO_IMAGES_DIR:-/data/local/software/apptainer_images}"
DSISTUDIO_SIF_DIR="${DSISTUDIO_SIF_DIR:-$DSISTUDIO_IMAGES_DIR/dsi_studio}"
ALL_DIR="${ALL_DIR:-$DSISTUDIO_IMAGES_DIR/all}"

mkdir -p "$ALL_DIR"

linked=0
for src in "$CONTAINER_DIR"/*/*.sif "$DSISTUDIO_SIF_DIR"/*.sif; do
    [ -e "$src" ] || continue                                # unmatched glob
    [ -L "$src" ] && continue                                # skip *_latest.sif symlinks
    case "$(basename "$src")" in
        *_building.sif) continue ;;                          # build in progress
    esac

    dest="$ALL_DIR/$(basename "$src")"
    [ -e "$dest" ] && continue                                # already linked (or name collision)

    ln "$src" "$dest"
    echo "$dest"
    linked=$((linked + 1))
done

echo "Linked $linked new image(s) into $ALL_DIR" >&2
