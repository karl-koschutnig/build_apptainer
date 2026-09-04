#!/bin/bash
# Send a push notification via ntfy.sh (https://ntfy.sh/docs/) -- no account,
# password, or SMTP auth needed. The topic name acts as a shared secret:
# anyone who knows it can publish to it or subscribe and read messages, so
# config/ntfy.env (which holds it) is gitignored and must stay private.
#
# Usage: notify_ntfy.sh "<title>" <<< "<message>"

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_DIR/config/ntfy.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "notify_ntfy.sh: $ENV_FILE not found, skipping notification (see config/ntfy.env.example)." >&2
    exit 3
fi

# shellcheck disable=SC1090
source "$ENV_FILE"
: "${NTFY_TOPIC:?NTFY_TOPIC not set in $ENV_FILE}"
NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"

title="$1"
message=$(cat)

curl -s --show-error \
     -H "Title: $title" \
     -H "Priority: default" \
     -d "$message" \
     "${NTFY_SERVER%/}/${NTFY_TOPIC}" > /dev/null
