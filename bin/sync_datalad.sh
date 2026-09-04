#!/bin/bash
# Push the local container store to the datalad server via rsync.
# --ignore-existing means it only adds files that aren't already on the
# receiver -- it never overwrites or deletes anything there.
#
# config/datalad.env (gitignored) holds the destination; see
# config/datalad.env.example. config/paths.env (also gitignored, but
# mandatory) holds CONTAINER_DIR, the tree being mirrored.
#
# Prints the relative path of every file actually transferred, one per
# line (via --out-format), so callers can report e.g. which .sif images
# went out without having to dig through a log file.
#
# Usage: sync_datalad.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PATHS_ENV="$REPO_DIR/config/paths.env"
if [ ! -f "$PATHS_ENV" ]; then
    echo "sync_datalad.sh: $PATHS_ENV not found. Copy config/paths.env.example to config/paths.env and edit it for your setup (see README Quick Setup)." >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$PATHS_ENV"
: "${CONTAINER_DIR:?CONTAINER_DIR not set in $PATHS_ENV}"

ENV_FILE="$REPO_DIR/config/datalad.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "sync_datalad.sh: $ENV_FILE not found, skipping sync (see config/datalad.env.example)." >&2
    exit 3
fi

# shellcheck disable=SC1090
source "$ENV_FILE"
: "${DATALAD_USER:?DATALAD_USER not set in $ENV_FILE}"
: "${DATALAD_HOST:?DATALAD_HOST not set in $ENV_FILE}"
: "${DATALAD_PATH:?DATALAD_PATH not set in $ENV_FILE}"

# Trailing slash is required: it tells rsync to copy CONTAINER_DIR's
# *contents* into DATALAD_PATH, not create a nested CONTAINER_DIR/ on the
# receiver. Strip any trailing slash the config value might already have,
# then add exactly one, so it's correct either way it's written.
rsync -a --ignore-existing --exclude="docker_tmp" --out-format='%n' \
    "${CONTAINER_DIR%/}/" "${DATALAD_USER}@${DATALAD_HOST}:${DATALAD_PATH}"
