#!/bin/bash
# Push the local container store to the datalad server via rsync.
# --ignore-existing means it only adds files that aren't already on the
# receiver -- it never overwrites or deletes anything there.
#
# config/datalad.env (gitignored) holds the destination; see
# config/datalad.env.example.
#
# Prints the relative path of every file actually transferred, one per
# line (via --out-format), so callers can report e.g. which .sif images
# went out without having to dig through a log file.
#
# Usage: sync_datalad.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
SRC_DIR="${SRC_DIR:-/data/local/container/}"

rsync -a --ignore-existing --exclude="docker_tmp" --out-format='%n' \
    "$SRC_DIR" "${DATALAD_USER}@${DATALAD_HOST}:${DATALAD_PATH}"
