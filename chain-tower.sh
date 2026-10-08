#!/bin/bash
set -euo pipefail

# Server A's side of the watchtower on Server B:
#   prune         Prune BTCPay's blockchain with one of BTCPay's opt-save-storage presets
#   copy          Copy BTCPay's pruned blockchain to Server B (into ~SERVER_B_USER/chain-incoming,
#                 which serverb-bitcoind-setup.sh makes; serverb-import-chain.sh takes it over)
#   tower-add     Turn on BTCPay's LND watchtower client and add the tower in config
#                 (WATCHTOWER_PUBKEY@WATCHTOWER_IP:WATCHTOWER_PORT)
#   tower-status  The watchtower client's towers and its statistics
# Run it as root in a terminal: sudo ./chain-tower.sh <command>  (lnd-manager: /chain ..., /tower ...)
#
# Everything that stops BTCPay asks you to type STOP BTCPAY first. prune, copy and tower-add run
# inside a tmux session named lnd-chain, so a dropped SSH connection doesn't stop them: reconnect
# and run the same command again, or sudo tmux -S /run/lnd-wallet-tmux/sock attach -t lnd-chain.
# --no-tmux skips that (tests); --pause waits for Enter at the end (the dashboard uses it).

# === CONFIG ===
if ! SCRIPT_DIR=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")"); then
    echo "❌ Could not determine this script's folder"
    exit 1
fi
CONFIG_FILE="$SCRIPT_DIR/config"
[[ -f "$CONFIG_FILE" ]] || { echo "❌ Configuration file not found at $CONFIG_FILE"; exit 1; }
# Root runs this file and reads config: both must be root's, with every folder on the way, and
# writable only by root (install-scripts.sh installs them that way)
root_owned_chain() {
    local path
    for path in "$@"; do
        path=$(realpath -m -- "$path")
        while :; do
            [[ -e "$path" && "$(stat -c %u -- "$path")" == 0 ]] || return 1
            (( (8#$(stat -c %a -- "$path") & 8#022) == 0 )) || return 1
            [[ "$path" == / ]] && break
            path=$(dirname -- "$path")
        done
    done
}
if [[ $EUID -ne 0 ]]; then
    echo "❌ Run it as root: sudo $0 $*" >&2
    exit 1
fi
if ! root_owned_chain "$SCRIPT_DIR/chain-tower.sh" "$CONFIG_FILE" "$SCRIPT_DIR/i18n.sh"; then
    echo "❌ $SCRIPT_DIR/chain-tower.sh or its config can be changed by users other than root, so root won't run it." >&2
    echo "   Install the scripts root-owned (sudo ./install-scripts.sh in your working folder) and run the installed copy." >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE" || { echo "❌ Failed to load $CONFIG_FILE"; exit 1; }
# shellcheck disable=SC1091
source "$SCRIPT_DIR/i18n.sh" || { echo "❌ Failed to load $SCRIPT_DIR/i18n.sh"; exit 1; }
i18n_load

usage() {
    sed -n '/^# Server A.s side/,/^# --no-tmux/p' "$SCRIPT_DIR/chain-tower.sh" | sed 's/^# \{0,1\}//'
}
COMMAND=""
USE_TMUX=true
PAUSE_AT_END=false
ARGS=("$@")
for arg in "$@"; do
    case "$arg" in
        prune | copy | tower-add | tower-status) COMMAND="$arg" ;;
        --no-tmux) USE_TMUX=false ;;
        --pause) PAUSE_AT_END=true ;;
        -h | --help) usage; exit 0 ;;
        *) say "❌ Unknown option: %s" "$arg" >&2; usage >&2; exit 2 ;;
    esac
done
[[ -n "$COMMAND" ]] || { usage >&2; exit 2; }
if [[ "$COMMAND" != tower-status && ! -t 0 ]]; then
    say "❌ chain-tower.sh needs a terminal for its confirmations." >&2
    exit 1
fi

log_message() {
    local message="${1//[[:cntrl:]]/?}"
    local timestamped="[$(date '+%Y-%m-%d %H:%M:%S')] $message"
    echo "$timestamped"
    echo "$timestamped" >> "$LIGHTNING_BACKUP_LOG_FILE" 2>/dev/null || true
    echo "$message" | systemd-cat -t btcpay-chain-tower 2>/dev/null || true
}
die() {
    log_message "❌ $*"
    exit 1
}
confirm_phrase() {
    local answer
    read -rp "$2" answer || answer=""
    [[ "$answer" == "$1" ]]
}
show_lines() {
    LC_ALL=C tr -d '\000-\010\013-\037\177' | sed 's/^/    /'
}

# === TMUX (as lnd-wallet.sh: root's own socket, only root can attach) ===
TMUX_SESSION="lnd-chain"
TMUX_SOCKET_DIR="/run/lnd-wallet-tmux"
TMUX_SOCKET="$TMUX_SOCKET_DIR/sock"
RESULT_FILE="/run/lnd-chain.result"
IN_OUR_TMUX="${LND_CHAIN_IN_TMUX:-}"
inside_multiplexer() {
    local pid=$$ comm
    while (( pid > 1 )); do
        comm=$(cat "/proc/$pid/comm" 2>/dev/null) || return 1
        case "$comm" in
            tmux* | screen* | SCREEN*) return 0 ;;
        esac
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || return 1
        [[ -n "$pid" ]] || return 1
    done
    return 1
}
if [[ "$COMMAND" != tower-status ]] && $USE_TMUX && [[ -z "$IN_OUR_TMUX" ]] && ! inside_multiplexer &&
   command -v tmux >/dev/null; then
    mkdir -p "$TMUX_SOCKET_DIR"
    chmod 700 "$TMUX_SOCKET_DIR"
    if tmux -S "$TMUX_SOCKET" has-session -t "=$TMUX_SESSION" 2>/dev/null; then
        say "ℹ️ A chain/tower operation is already running in tmux session '%s'. Attaching to it..." "$TMUX_SESSION"
        tmux -S "$TMUX_SOCKET" attach-session -t "=$TMUX_SESSION" || true
        say "ℹ️ That was the earlier operation; this one (%s) was not started." "$COMMAND"
        exit 4
    fi
    rm -f "$RESULT_FILE"
    if tmux -S "$TMUX_SOCKET" new-session -s "$TMUX_SESSION" \
            env LND_CHAIN_IN_TMUX=1 "$SCRIPT_DIR/chain-tower.sh" "${ARGS[@]}"; then
        if [[ -f "$RESULT_FILE" ]]; then
            code=$(<"$RESULT_FILE")
            rm -f "$RESULT_FILE"
            [[ "$code" =~ ^[0-9]+$ ]] || code=1
            exit "$code"
        fi
        say "ℹ️ It is still running in tmux. Back to it: run the same command again."
        exit 3
    fi
    say "⚠️ tmux could not start a session. Continuing without it: don't let the SSH connection drop."
fi
finish() {
    local code="$1"
    if [[ -n "$IN_OUR_TMUX" ]]; then
        echo "$code" > "$RESULT_FILE"
        echo
        read -rp "$(T "Finished (exit code %s). Press Enter to close this tmux session. " "$code")" _ || true
    elif $PAUSE_AT_END; then
        echo
        read -rp "$(T "Finished (exit code %s). Press Enter to go back. " "$code")" _ || true
    fi
}
trap 'finish $?' EXIT

exec 9> /run/lnd-chain.lock
flock -n 9 || die "$(T "Another chain-tower.sh is running. Let it finish first.")"
# lnd-wallet.sh's lock too: prune, copy and tower-add stop and start BTCPay, which in the middle
# of a wallet change would let BTCPay's LND make a wallet of its own
exec 8> /run/lnd-wallet.lock
flock -n 8 || die "$(T "lnd-wallet.sh is running. Let it finish first.")"

# === BTCPay ===
BTCPAY_ENV=/etc/profile.d/btcpay-env.sh
[[ -f "$BTCPAY_ENV" && -x "$DOCKER_ROOT/btcpay-setup.sh" ]] || die "$(T "BTCPay isn't installed the usual way (%s, %s)" "$BTCPAY_ENV" "$DOCKER_ROOT")"
current_fragments() {
    # shellcheck disable=SC1090
    (source "$BTCPAY_ENV" >/dev/null 2>&1; printf '%s' "${BTCPAYGEN_ADDITIONAL_FRAGMENTS:-}")
}
# Runs btcpay-setup.sh -i with BTCPay's own settings and the fragments in $1 (";"-separated), the
# way BTCPay's docs do. It regenerates docker-compose and restarts what changed.
apply_fragments() {
    local code
    log_message "$(T "⚙️ btcpay-setup.sh with BTCPAYGEN_ADDITIONAL_FRAGMENTS=\"%s\" (BTCPay restarts)..." "$1")"
    # Its exit code is checked below; pipefail and set -e would otherwise end the script silently
    code=0
    (umask 022 && cd "$DOCKER_ROOT" && bash -c '
        source "$1" >/dev/null 2>&1
        export BTCPAYGEN_ADDITIONAL_FRAGMENTS="$2"
        . ./btcpay-setup.sh -i' _ "$BTCPAY_ENV" "$1") 2>&1 | show_lines | tail -n 25 || code=${PIPESTATUS[0]}
    (( code == 0 )) || die "$(T "btcpay-setup.sh failed (exit code %s); see the lines above. Check BTCPay: %s/btcpay-up.sh" "$code" "$DOCKER_ROOT")"
    [[ "$(current_fragments)" == "$1" ]] || die "$(T "btcpay-setup.sh didn't take the new fragments; see the lines above")"
    log_message "$(T "✅ BTCPay runs with: %s" "$1")"
}
# The fragment list with every name matching $2 (a glob) removed, and $3 added (if not empty)
change_fragments() {
    local list="$1" drop="$2" add="$3" out=() f
    IFS=';' read -r -a parts <<< "$list"
    for f in "${parts[@]}"; do
        [[ -z "$f" ]] && continue
        # shellcheck disable=SC2053
        [[ -n "$drop" && "$f" == $drop ]] && continue
        [[ "$f" == "$add" ]] && continue
        out+=("$f")
    done
    [[ -n "$add" ]] && out+=("$add")
    (IFS=';'; printf '%s' "${out[*]}")
}
confirm_btcpay_stop() {
    echo
    say "⚠️  BTCPay will be stopped: the store can't take payments and Lightning is offline for %s." "$1"
    confirm_phrase "STOP BTCPAY" "$(T "Type 'STOP BTCPAY' to stop it: ")" ||
        die "$(T "Aborted: BTCPay was not stopped and nothing was changed.")"
}
btcpay_lncli() {
    docker exec "$LND_CONTAINER_NAME" lncli --macaroonpath=/data/admin.macaroon "$@"
}
wait_for_lnd() {
    local i
    for i in $(seq 1 60); do
        btcpay_lncli getinfo >/dev/null 2>&1 && return 0
        sleep 5
    done
    return 1
}
chain_prune_mb() {
    grep -hE '^prune=[0-9]+' "$BITCOIND_DIR/bitcoin.conf" 2>/dev/null | tail -n 1 | cut -d= -f2
}

# === prune ===
cmd_prune() {
    local now prune choice preset new
    now=$(current_fragments)
    prune=$(chain_prune_mb || true)
    say "BTCPay's blockchain: %s of blocks, prune=%s" "$(du -sh "$BITCOIND_DIR/blocks" 2>/dev/null | cut -f1)" "${prune:-off}"
    say "Fragments now: %s" "${now:-none}"
    echo
    say "BTCPay's pruning presets keep this much of the blockchain:"
    say "  1) opt-save-storage       ~100 GB"
    say "  2) opt-save-storage-s     ~50 GB"
    say "  3) opt-save-storage-xs    ~25 GB   recommended: keeps about 3 months of blocks"
    say "  4) opt-save-storage-xxs   ~5 GB    BTCPay warns that Lightning can have trouble with this little"
    say "Pruning deletes old blocks: BTCPay can then no longer rescan for transactions older than what it"
    say "keeps (for example when importing an old wallet). Do it only if you have no old transactions to"
    say "find. Lightning needs blocks back to its oldest channel's opening."
    while true; do
        read -rp "$(T "Choose 1-4 (Enter for 3, q to stop): ")" choice || exit 1
        case "${choice:-3}" in
            1) preset=opt-save-storage ;;
            2) preset=opt-save-storage-s ;;
            3) preset=opt-save-storage-xs ;;
            4) preset=opt-save-storage-xxs ;;
            q) die "$(T "Stopped: nothing was changed.")" ;;
            *) continue ;;
        esac
        break
    done
    new=$(change_fragments "$now" 'opt-save-storage*' "$preset")
    [[ "$new" != "$now" ]] || { log_message "$(T "ℹ️ BTCPay already uses %s" "$preset")"; return 0; }
    confirm_btcpay_stop "$(T "a few minutes, while btcpay-setup.sh applies %s" "$preset")"
    apply_fragments "$new"
    log_message "$(T "✅ BTCPay's blockchain is pruned to %s; bitcoind deletes old blocks as it starts." "$preset")"
}

# === copy ===
cmd_copy() {
    local remote="$SERVER_B_USER@$REMOTE_SERVER" size prune rsh rsync_cmd gid
    [[ -n "${SERVER_B_USER:-}" && -n "${REMOTE_SERVER:-}" ]] || die "$(T "SERVER_B_USER or REMOTE_SERVER is empty in config. Run setup first.")"
    [[ -d "$BITCOIND_DIR/blocks" && -d "$BITCOIND_DIR/chainstate" ]] || die "$(T "No blockchain in %s (BITCOIND_DIR in config)" "$BITCOIND_DIR")"
    # rsync talks to Server B, so it doesn't run as root: it runs as the backup user with one
    # extra right, reading any file (CAP_DAC_READ_SEARCH, for Docker's volume). ssh, which it
    # starts, gets that right taken away again: it runs as the plain backup user, with its key
    # and known_hosts.
    local ssh_arr=("${SSH_COMMAND_ARR[@]}")
    unset 'ssh_arr[${#ssh_arr[@]}-1]'
    gid=$(id -g "$SERVER_A_USER") || die "$(T "There is no user %s (SERVER_A_USER in config)" "$SERVER_A_USER")"
    rsh=$(printf '%q ' setpriv --inh-caps=-all --ambient-caps=-all -- "${ssh_arr[@]}" -o BatchMode=yes)
    [[ "$(sudo -u "$SERVER_A_USER" "${ssh_arr[@]}" -n -o BatchMode=yes "$remote" ping 2>/dev/null)" == ok ]] ||
        die "$(T "Server B's backup gate doesn't answer. Run setup first (lnd-manager: /setup).")"
    prune=$(chain_prune_mb || true)
    size=$(du -sb "$BITCOIND_DIR/blocks" "$BITCOIND_DIR/chainstate" | awk '{ s += $1 } END { printf "%.1f", s / 1e9 }')
    say "BTCPay's blockchain: %s GB (prune=%s), to %s:~/chain-incoming" "$size" "${prune:-off}" "$remote"
    if [[ -z "$prune" ]]; then
        say "⚠️  It isn't pruned: all of it would be copied (hundreds of GB). Prune it first: /chain prune."
        confirm_phrase "COPY ALL" "$(T "Type 'COPY ALL' to copy it unpruned anyway: ")" || die "$(T "Stopped: nothing was copied.")"
    fi
    echo
    say "Two passes, so BTCPay is down only for the second:"
    say "  1. while BTCPay runs: almost everything (%s GB). This can take hours; BTCPay keeps working." "$size"
    say "     If the connection drops, run /chain copy again: it goes on where it stopped."
    say "  2. BTCPay stopped (you type STOP BTCPAY): only what changed meanwhile, usually minutes."
    say "     Then BTCPay starts again."
    say "Server B's gate takes it only into ~%s/chain-incoming (serverb-bitcoind-setup.sh makes it)." "$SERVER_B_USER"
    say "Afterwards, on Server B: sudo bash serverb-import-chain.sh"
    confirm_phrase yes "$(T "Start the copy? Type yes: ")" || die "$(T "Stopped: nothing was copied.")"
    rsync_cmd=(setpriv --reuid="$SERVER_A_USER" --regid="$gid" --init-groups
               --inh-caps=+dac_read_search --ambient-caps=+dac_read_search --
               rsync -rt --delete --partial --info=progress2 --human-readable
               '--include=/blocks/***' '--include=/chainstate/***' '--exclude=*' -e "$rsh"
               "$BITCOIND_DIR/" "$remote:")
    log_message "$(T "📤 Pass 1 of 2: copying while BTCPay runs...")"
    # The live files change during this pass; pass 2 makes the copy consistent. Only that
    # (23: some files not copied, 24: files vanished) is a reason to go on and stop BTCPay
    local code=0
    "${rsync_cmd[@]}" || code=$?
    case $code in
        0) ;;
        23 | 24) log_message "$(T "⚠️ Pass 1 ended with code %s (files changing while BTCPay runs, expected). Going on to pass 2, which copies the rest." "$code")" ;;
        *) die "$(T "Pass 1 failed (rsync exit code %s), so BTCPay was not stopped. Fix what the lines above say, then run /chain copy again." "$code")" ;;
    esac
    confirm_btcpay_stop "$(T "a few minutes, while the rest of the blockchain is copied")"
    # Whatever happens from here, BTCPay is started again
    trap 'code=$?; log_message "$(T "🚀 Starting BTCPay again...")"; (umask 022 && "$DOCKER_ROOT/btcpay-up.sh" >/dev/null 2>&1) || log_message "$(T "❌ btcpay-up.sh failed: run %s/btcpay-up.sh by hand" "$DOCKER_ROOT")"; finish $code' EXIT
    log_message "$(T "🛑 Stopping BTCPay (btcpay-down.sh)...")"
    (umask 022 && "$DOCKER_ROOT/btcpay-down.sh" >/dev/null 2>&1) || die "$(T "btcpay-down.sh failed")"
    log_message "$(T "📤 Pass 2 of 2: copying the rest with BTCPay stopped...")"
    "${rsync_cmd[@]}" || die "$(T "Pass 2 failed. BTCPay is started again; run /chain copy again later.")"
    log_message "$(T "✅ Blockchain copied to Server B. Next, on Server B: sudo bash serverb-import-chain.sh")"
}

# === tower-add ===
cmd_tower_add() {
    local uri now new
    [[ "${WATCHTOWER_PUBKEY:-}" =~ ^0[23][0-9a-f]{64}$ ]] || die "$(T "WATCHTOWER_PUBKEY in config isn't a public key (66 hex characters)")"
    [[ "${WATCHTOWER_IP:-}" =~ ^[A-Za-z0-9.:-]+$ && "${WATCHTOWER_IP}" != your-watchtower-ip ]] || die "$(T "WATCHTOWER_IP in config isn't set")"
    [[ "${WATCHTOWER_PORT:-}" =~ ^[0-9]{1,5}$ ]] || die "$(T "WATCHTOWER_PORT in config isn't a port")"
    uri="$WATCHTOWER_PUBKEY@$WATCHTOWER_IP:$WATCHTOWER_PORT"
    now=$(current_fragments)
    if [[ ";$now;" != *";opt-lnd-wtclient;"* ]]; then
        say "BTCPay's LND has its watchtower client off. BTCPay's opt-lnd-wtclient fragment turns it on"
        say "(wtclient.active=1); btcpay-setup.sh applies it and restarts LND."
        confirm_btcpay_stop "$(T "a few minutes, while btcpay-setup.sh turns on the watchtower client")"
        new=$(change_fragments "$now" "" opt-lnd-wtclient)
        apply_fragments "$new"
    fi
    log_message "$(T "⏳ Waiting for LND...")"
    wait_for_lnd || die "$(T "LND doesn't answer (docker logs %s)" "$LND_CONTAINER_NAME")"
    # The watchtower client answers only once LND is synced to the chain
    if ! btcpay_lncli getinfo 2>/dev/null | jq -e '.synced_to_chain == true' >/dev/null; then
        log_message "$(T "⏳ LND is still catching up with the chain; the watchtower client waits for that (up to 10 minutes here)...")"
    fi
    log_message "$(T "➕ Adding the watchtower %s..." "$uri")"
    timeout 600 docker exec "$LND_CONTAINER_NAME" lncli --macaroonpath=/data/admin.macaroon wtclient add "$uri" 2>&1 | show_lines
    case ${PIPESTATUS[0]} in
        0) ;;
        124) die "$(T "LND's watchtower client didn't answer within 10 minutes (LND not synced to the chain yet?). The client is on; run /tower add again later.")" ;;
        *) die "$(T "lncli wtclient add failed")" ;;
    esac
    log_message "$(T "✅ The watchtower is added. LND sends it encrypted channel updates from now on.")"
    cmd_tower_status
}

# === tower-status ===
cmd_tower_status() {
    local out
    if ! out=$(timeout 60 docker exec "$LND_CONTAINER_NAME" lncli --macaroonpath=/data/admin.macaroon wtclient towers 2>&1); then
        say "The watchtower client isn't on, LND isn't running, or LND is still catching up with the chain:"
        show_lines <<< "${out:-(no answer within a minute)}"
        return 1
    fi
    say "Towers:"
    show_lines <<< "$out"
    say "Statistics:"
    timeout 60 docker exec "$LND_CONTAINER_NAME" lncli --macaroonpath=/data/admin.macaroon wtclient stats 2>&1 | show_lines
}

case "$COMMAND" in
    prune) cmd_prune ;;
    copy) cmd_copy ;;
    tower-add) cmd_tower_add ;;
    tower-status) cmd_tower_status ;;
esac
