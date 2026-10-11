#!/bin/bash
# server-a-status.sh: tells Server B, every 5 minutes, whether it is safe to restart the
# watchtower there (server-a-status.timer, installed by install-scripts.sh). Runs as root (LND is
# asked through docker), sends as the backup user, through Server B's backup gate (put-status).
#
# It sends only these lines, data that Server B reads and checks, never runs:
#   server-a-status 1
#   lnd=<LND's state: SERVER_ACTIVE when it runs, else what lncli state says, or down>
#   htlcs=<payments in flight, over all channels>
#   pending_channels=<channels being opened or closed>
# Server B's serverb-update restarts bitcoind or the watchtower only while this is fresh (less
# than 10 minutes old, by Server B's own clock) and says SERVER_ACTIVE, 0 and 0.

set -uo pipefail
umask 077
if ! SCRIPT_DIR=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")"); then
    echo "Could not determine this script's folder" >&2
    exit 1
fi
CONFIG_FILE="$SCRIPT_DIR/config"
(( EUID == 0 )) || { echo "Run it as root" >&2; exit 1; }
for f in "$SCRIPT_DIR/server-a-status.sh" "$CONFIG_FILE"; do
    path=$(realpath -m -- "$f")
    while :; do
        if [[ ! -e "$path" || "$(stat -c %u -- "$path")" != 0 ]] || (( 8#$(stat -c %a -- "$path") & 8#022 )); then
            echo "$f or a folder above it can be changed by users other than root: not run" >&2
            exit 1
        fi
        [[ "$path" == / ]] && break
        path=$(dirname -- "$path")
    done
done
# shellcheck disable=SC1090
source "$CONFIG_FILE" || exit 1
# Not set up for Server B yet: nothing to tell
[[ -n "${REMOTE_SERVER:-}" && -n "${SERVER_B_USER:-}" && -n "${SERVER_A_USER:-}" && -n "${KEY_PATH:-}" ]] || exit 0

lncli() {
    timeout 30 docker exec "${LND_CONTAINER_NAME:-btcpayserver_lnd_bitcoin}" lncli \
        --macaroonpath=/data/readonly.macaroon "$@" 2>/dev/null
}
state=$(timeout 30 docker exec "${LND_CONTAINER_NAME:-btcpayserver_lnd_bitcoin}" lncli state 2>/dev/null |
        python3 -I -c 'import json, sys; print(json.load(sys.stdin).get("state", ""))' 2>/dev/null) || state=""
[[ "$state" =~ ^[A-Z_]{1,40}$ ]] || state=down
htlcs=-1 pending=-1
if [[ "$state" == SERVER_ACTIVE ]]; then
    htlcs=$(lncli listchannels | python3 -I -c '
import json, sys
print(sum(len(c.get("pending_htlcs", [])) for c in json.load(sys.stdin).get("channels", [])))' 2>/dev/null) || htlcs=-1
    pending=$(lncli pendingchannels | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
print(sum(len(d.get(k, [])) for k in ("pending_open_channels", "pending_closing_channels",
                                     "pending_force_closing_channels", "waiting_close_channels")))' 2>/dev/null) || pending=-1
fi
[[ "$htlcs" =~ ^-?[0-9]+$ ]] || htlcs=-1
[[ "$pending" =~ ^-?[0-9]+$ ]] || pending=-1

status=$(printf 'server-a-status 1\nlnd=%s\nhtlcs=%s\npending_channels=%s\n' "$state" "$htlcs" "$pending")
error=$(printf '%s\n' "$status" | runuser -u "$SERVER_A_USER" -- ssh -o BatchMode=yes -o ConnectTimeout=15 \
            -i "$KEY_PATH" -p "${REMOTE_SSH_PORT:-22}" "$SERVER_B_USER@$REMOTE_SERVER" put-status 2>&1 >/dev/null)
rc=$?
# A refusal or an unreachable Server B is said once an hour, not every 5 minutes
NOTE=/run/server-a-status.error
if (( rc != 0 )); then
    if [[ ! -f "$NOTE" || "$(cat "$NOTE")" != "$error" || -n "$(find "$NOTE" -mmin +60 2>/dev/null)" ]]; then
        printf '%s' "$error" > "$NOTE"
        echo "Could not send the status to Server B: ${error//[[:cntrl:]]/?}" >&2
    fi
    exit 1
fi
rm -f "$NOTE"
