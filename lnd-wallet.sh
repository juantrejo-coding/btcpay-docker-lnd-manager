#!/bin/bash
set -euo pipefail

# Replaces or restores BTCPay's LND wallet:
#   1) new            New wallet
#   2) restore        Restore the wallet (on-chain funds) from its seed
#   3) channels       Restore the wallet and the channels (seed + channel.backup)
#   4) channels-only  Restore the channels into the running wallet (channel.backup only)
#   5) undo           Undo: put a safety backup back
# Run it as root in a terminal: sudo ./lnd-wallet.sh [option]   (no option: it shows the menu)
#
# It runs itself inside a tmux session named lnd-wallet, so a dropped SSH connection doesn't
# stop it halfway: reconnect and run the script again (it goes back to the session), or
# sudo tmux -S /run/lnd-wallet-tmux/sock attach -t lnd-wallet.
# --no-tmux skips that, for automated tests. --pause waits for Enter at the end (the dashboard
# uses it, so the last messages can be read before it redraws).
#
# Recovery only uses the seed and channel.backup. Old channel state (channel.db) is never put back,
# except by option 5, which puts back a whole volume exactly as it was.
# Every option first saves the current LND volume as an encrypted safety backup in pre-recovery/ on
# the attached volume and on Server B, where no rotation deletes it.
# The wallet is created in a temporary lnd-init container while BTCPay is down, so BTCPay can't
# make its own wallet in the meantime, and walletunlock.json is written before BTCPay starts again:
# BTCPay unlocks LND with the password in it.

# === CONFIG ===
# config sits in the same folder as this script. Without it every path would be empty,
# so stop rather than let later steps act on the wrong files.
if ! SCRIPT_DIR=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")"); then
    echo "❌ Could not determine this script's folder"
    exit 1
fi
CONFIG_FILE="$SCRIPT_DIR/config"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Configuration file not found at $CONFIG_FILE (keep config next to the scripts)"
    exit 1
fi
# Root runs this file and reads config: both must be root's, with every folder on the way, and
# writable only by root. Otherwise an ordinary user could change what root runs. The scripts are
# installed that way by install-scripts.sh, into BACKUP_INSTALL_DIR.
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
# Checked before config is read: sourcing it is running it
if [[ $EUID -eq 0 ]] && ! root_owned_chain "$SCRIPT_DIR/lnd-wallet.sh" "$CONFIG_FILE" "$SCRIPT_DIR/i18n.sh"; then
    echo "❌ $SCRIPT_DIR/lnd-wallet.sh or its config can be changed by users other than root, so root won't run it." >&2
    echo "   Install the scripts root-owned (sudo ./install-scripts.sh in your working folder), then run" >&2
    echo "   the installed copy: sudo lnd-wallet [new|restore|channels|channels-only|undo]" >&2
    exit 1
fi
if ! source "$CONFIG_FILE"; then
    echo "❌ Failed to load $CONFIG_FILE"
    exit 1
fi
# shellcheck disable=SC1091
if ! source "$SCRIPT_DIR/i18n.sh"; then
    echo "❌ Failed to load $SCRIPT_DIR/i18n.sh"
    exit 1
fi
i18n_load

# The backup installer next to this script: the root-owned copy, whatever an older config's
# RSYNC_FOLDER_MIRROR_SCRIPT says
INSTALLER="$SCRIPT_DIR/rsync_gpg_backup.sh"

# === OPTIONS ===
usage() {
    sed -n '/^# Replaces or restores/,/^# --no-tmux/p' "$SCRIPT_DIR/lnd-wallet.sh" | sed 's/^# \{0,1\}//'
}
CHOICE=""
USE_TMUX=true
PAUSE_AT_END=false
ARGS=("$@")
for arg in "$@"; do
    case "$arg" in
        new) CHOICE=1 ;;
        restore) CHOICE=2 ;;
        channels) CHOICE=3 ;;
        channels-only) CHOICE=4 ;;
        undo) CHOICE=5 ;;
        --no-tmux) USE_TMUX=false ;;
        --pause) PAUSE_AT_END=true ;;
        -h | --help) usage; exit 0 ;;
        *) say "❌ Unknown option: %s" "$arg" >&2; usage >&2; exit 2 ;;
    esac
done

# It deletes and recreates the LND wallet only after typed confirmations, so without a terminal
# it can't go ahead. Stop before installing or starting anything.
if [[ ! -t 0 ]]; then
    say "❌ lnd-wallet.sh needs a terminal for its confirmation. Run it in a terminal." >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    say "❌ Run lnd-wallet.sh as root: sudo %s %s" "$0" "${ARGS[*]}" >&2
    exit 1
fi

# === TMUX ===
# A dropped SSH connection would end the script halfway through a wallet change, so it runs inside
# a tmux session that survives the connection. Only root can attach to it (the session belongs to
# root's tmux server, whose socket only root can open), and it opens no network port.
TMUX_SESSION="lnd-wallet"
# Its own socket in a folder only root can write to: in /tmp, another user could pre-create
# tmux's folder and stop the session from starting
TMUX_SOCKET_DIR="/run/lnd-wallet-tmux"
TMUX_SOCKET="$TMUX_SOCKET_DIR/sock"
# The exit code of the run inside tmux, for the run that started it (tmux doesn't pass it on)
RESULT_FILE="/run/lnd-wallet.result"
IN_OUR_TMUX="${LND_WALLET_IN_TMUX:-}"

# True when a parent process is tmux or screen. sudo removes $TMUX and $STY, so the parents are
# checked instead, which also avoids starting a tmux inside the user's own tmux or screen.
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

if $USE_TMUX && [[ -z "$IN_OUR_TMUX" ]] && ! inside_multiplexer; then
    if ! command -v tmux >/dev/null; then
        say "📦 'tmux' not found, installing (it keeps the script running if SSH drops)..."
        apt-get update >/dev/null && apt-get install -y tmux >/dev/null ||
            say "⚠️ Could not install tmux. Continuing without it: don't let the SSH connection drop."
    fi
    if command -v tmux >/dev/null; then
        mkdir -p "$TMUX_SOCKET_DIR"
        chmod 700 "$TMUX_SOCKET_DIR"
        # One already there (still running, or finished and waiting for Enter): go back to it, but
        # never report this request as done, since it wasn't started
        if tmux -S "$TMUX_SOCKET" has-session -t "=$TMUX_SESSION" 2>/dev/null; then
            say "ℹ️ A wallet operation is already running in tmux session '%s'. Attaching to it..." "$TMUX_SESSION"
            tmux -S "$TMUX_SOCKET" attach-session -t "=$TMUX_SESSION" || true
            say "ℹ️ That was the earlier wallet operation. This one (%s) was not started:" "${ARGS[*]:-the menu}"
            say "   run it again once the earlier one has finished."
            exit 4
        fi
        rm -f "$RESULT_FILE"
        # tmux returns when the session ends, or when you detach from it
        if tmux -S "$TMUX_SOCKET" new-session -s "$TMUX_SESSION" \
                env LND_WALLET_IN_TMUX=1 "$SCRIPT_DIR/lnd-wallet.sh" "${ARGS[@]}"; then
            if [[ -f "$RESULT_FILE" ]]; then
                code=$(<"$RESULT_FILE")
                rm -f "$RESULT_FILE"
                [[ "$code" =~ ^[0-9]+$ ]] || code=1
                exit "$code"
            fi
            say "ℹ️ The wallet operation is still running in tmux. Back to it: run this script again."
            exit 3
        fi
        say "⚠️ tmux could not start a session. Continuing without it: don't let the SSH connection drop."
    fi
fi

# Inside the tmux session this script started: leave the result for the run outside, and keep the
# screen open until Enter so the last messages can be read. With --pause, wait for Enter anywhere.
finish_in_tmux() {
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
trap 'finish_in_tmux $?' EXIT

for setting in SERVER_A_USER GPG_FINGERPRINT LND_DIR LND_VOLUME LND_CONTAINER_NAME DOCKER_ROOT; do
    if [[ -z "${!setting:-}" ]]; then
        say "❌ %s is empty in config. Run setup_script.sh first." "$setting" >&2
        exit 1
    fi
done

# === ENSURE JQ IS INSTALLED ON HOST ===
if ! command -v jq &> /dev/null; then
    say "📦 'jq' not found, installing..."
    apt-get update && apt-get install -y jq
else
    say "✅ 'jq' is already installed."
fi

# === LOGGING FUNCTION ===
# Never pass a password or seed to it: it writes to the log file and the journal.
log_message() {
    # File names and error texts can come from Server B or a backup: no control characters, so
    # nothing can fake log lines or send escape codes to the terminal
    local message="${1//[[:cntrl:]]/?}"
    local timestamped="[$(date '+%Y-%m-%d %H:%M:%S')] $message"

    # Print to terminal
    echo "$timestamped"

    # Append to log file
    echo "$timestamped" >> "$LIGHTNING_BACKUP_LOG_FILE"

    # Send to systemd journal
    echo "$message" | systemd-cat -t btcpay-lightning-backup
}

die() {
    log_message "❌ $*"
    exit 1
}

# Asks until the exact phrase is typed; anything else returns 1
confirm_phrase() {
    local phrase="$1" prompt="$2" answer
    read -rp "$prompt" answer || answer=""
    [[ "$answer" == "$phrase" ]]
}

ask_yes() {
    local answer
    read -rp "$1" answer || answer=""
    [[ "$answer" == "yes" ]]
}

# === PATHS AND NAMES ===
MAINNET_REL="data/chain/bitcoin/mainnet"
LIVE_MAINNET="$LND_DIR/$MAINNET_REL"
UNLOCK_REL="$MAINNET_REL/walletunlock.json"
SCB_REL="$MAINNET_REL/channel.backup"
LND_INIT="lnd-init"
PRE_RECOVERY_LOCAL="${PRE_RECOVERY_DIR:-$SECOND_BACKUP_DIR/pre-recovery}"
BTCPAY_SERVICE="${BTCPAY_SERVICE_NAME:-btcpayserver.service}"
RECOVERY_WINDOW_DEFAULT=2500
# The file a channel restore reads, inside the LND volume (/data in the containers)
SCB_STAGING_REL="recovery-channel.backup"

GPG_PASS_OPTS=()
if [[ -n "${GPG_PASSPHRASE_FILE:-}" ]]; then
    GPG_PASS_OPTS=(--pinentry-mode loopback --passphrase-file "$GPG_PASSPHRASE_FILE")
fi

# Everything this script makes from here on is for root only, unless made readable on purpose.
# Programs it starts that make files for others (apt, btcpay-up.sh, the installer) get the
# usual umask back, see with_usual_umask.
umask 077

with_usual_umask() {
    (umask 022 && "$@")
}

btcpay_run() {
    with_usual_umask "$DOCKER_ROOT/$1"
}

# Lines from containers and installers, shown indented and without control characters
show_lines() {
    LC_ALL=C tr -d '\000-\010\013-\037\177' | sed 's/^/    /'
}

# === ONE RUN AT A TIME ===
# Held until the script exits. Two runs at once would both change the wallet, and the cleanup
# below would delete the other run's work folders.
exec 9> /run/lnd-wallet.lock
if ! flock -n 9; then
    say "❌ Another lnd-wallet.sh, or chain-tower.sh (/chain, /tower), is running. Let it finish first." >&2
    exit 1
fi
# For the dashboard: which operation runs, and whether its process is still alive
RUNNING_FILE="/run/lnd-wallet.running"
# The last field says whether /wallet attach can get back to it
install -m 644 /dev/null "$RUNNING_FILE"
echo "$$ ${CHOICE:-menu} $(date +%s) $([[ -n "$IN_OUR_TMUX" ]] && echo tmux || echo -)" > "$RUNNING_FILE"

# Work folders left by an earlier run that was killed or lost power before its cleanup: they can
# hold unencrypted copies (a safety backup being built, decrypted backups). With the lock held, no
# other run is using them. Only root's own folders with exactly this name pattern, never a link.
stale=0
for old_dir in /run/lnd-wallet.?????? /var/tmp/lnd-wallet.??????; do
    [[ -d "$old_dir" && ! -L "$old_dir" && "$(stat -c %u "$old_dir")" == "0" ]] || continue
    rm -rf --one-file-system --preserve-root -- "$old_dir"
    stale=$((stale + 1))
done
if (( stale > 0 )); then
    log_message "$(T "🧹 Removed %s work folder(s) left by an earlier run that didn't finish" "$stale")"
fi

# === WORK FOLDERS ===
# Decrypted backups (seed, password, wallet.db) go to /run, which is memory, when they fit.
# The safety backup of a whole volume can be large, so it's built on disk in /var/tmp. Both are
# root only and removed when the script exits.
SECRET_DIR=$(mktemp -d /run/lnd-wallet.XXXXXX)
BULK_DIR=$(mktemp -d /var/tmp/lnd-wallet.XXXXXX)
chmod 700 "$SECRET_DIR" "$BULK_DIR"

# === DELETING ===
# safe_delete (rsync_gpg_backup.sh) only deletes inside the installer's safe folders, which never
# include /run, /var/tmp or LND_DIR, so this script checks its own deletions the same way.

# Removes a path inside this run's own work folders (or one of them), never anything else,
# and never across into another filesystem
remove_work_path() {
    local target real
    # Without both work folders known, nothing could be checked against them
    if [[ -z "${SECRET_DIR:-}" || -z "${BULK_DIR:-}" ]]; then
        say "❌ Refusing to delete: this run's work folders are not known" >&2
        return 1
    fi
    for target in "$@"; do
        [[ -n "$target" ]] || continue
        real=$(realpath -m -- "$target")
        case "$real" in
            /run/lnd-wallet.?????? | /run/lnd-wallet.??????/* | /var/tmp/lnd-wallet.?????? | /var/tmp/lnd-wallet.??????/*) ;;
            *)
                say "❌ Refusing to delete outside this script's work folders: %s" "$real" >&2
                return 1
                ;;
        esac
        case "$real" in
            "$(realpath -m -- "$SECRET_DIR")" | "$(realpath -m -- "$SECRET_DIR")"/* | \
            "$(realpath -m -- "$BULK_DIR")" | "$(realpath -m -- "$BULK_DIR")"/*) ;;
            *)
                say "❌ Refusing to delete another run's work folder: %s" "$real" >&2
                return 1
                ;;
        esac
        rm -rf --one-file-system --preserve-root -- "$real"
    done
}

# Removes a half-copied safety backup (<name>.tmp) from the attached volume, with safe_delete's
# checks: an absolute path inside the pre-recovery folder, and the attached volume mounted
remove_pre_recovery_tmp() {
    local target="$1" real base
    [[ -n "$target" ]] || return 1
    real=$(realpath -m -- "$target")
    base=$(realpath -m -- "$PRE_RECOVERY_LOCAL")
    if [[ "$real" != "$base"/pre-recovery_*.gpg.tmp ]]; then
        log_message "$(T "❌ Refusing to delete %s: only half-copied safety backups (pre-recovery_*.gpg.tmp) in %s" "$real" "$PRE_RECOVERY_LOCAL")"
        return 1
    fi
    if ! attached_ok; then
        log_message "$(T "❌ Refusing delete: the attached volume is not mounted at %s" "$ATTACHED_VOLUME")"
        return 1
    fi
    sudo -u "$SERVER_A_USER" test -e "$real" || return 0
    # As the backup user, who owns that folder: root deleting there could be redirected
    sudo -u "$SERVER_A_USER" rm -f -- "$real"
}

# How far the script got, for the message when it stops early:
#   checks      nothing changed yet
#   stopped     BTCPay and the backup service are down, the old wallet is untouched
#   deleted     the old volume is gone (the safety backup holds it)
#   handed      walletunlock.json is written, BTCPay may be starting
#   done        finished
STAGE="checks"
BACKUP_SERVICE_WAS_ACTIVE=false
BTCPAY_SERVICE_DISABLED=false
# Written while this script has btcpayserver.service disabled, so a later run (after one that
# stopped partway) knows to enable it again. A service disabled by hand has no marker and is left alone.
BTCPAY_DISABLED_MARKER="/var/lib/lnd-wallet/btcpay-service-disabled"
SAFETY_BACKUP_NAME=""

on_exit() {
    local code=$?
    if [[ -n "${GITHUB_DIR:-}" ]]; then
        sudo -u "$SERVER_A_USER" rm -rf -- "$GITHUB_DIR" 2>/dev/null || true
    fi
    docker rm -f "$LND_INIT" >/dev/null 2>&1 || true
    rm -f "$LND_DIR/$SCB_STAGING_REL" 2>/dev/null || true
    remove_work_path "$SECRET_DIR" "$BULK_DIR" || true

    case "$STAGE" in
        stopped)
            # Nothing was deleted, so bring everything back as it was
            log_message "$(T "⚠️ Stopped before the wallet was touched. Starting BTCPay and the backup service again...")"
            enable_btcpay_service || true
            btcpay_run btcpay-up.sh >/dev/null 2>&1 ||
                log_message "$(T "❌ btcpay-up.sh failed. Run %s/btcpay-up.sh by hand." "$DOCKER_ROOT")"
            if $BACKUP_SERVICE_WAS_ACTIVE; then
                systemctl start "$RSYNC_BACKUP_SERVICE_NAME" ||
                    log_message "$(T "❌ Could not start %s. Start it by hand." "$RSYNC_BACKUP_SERVICE_NAME")"
            fi
            ;;
        deleted)
            log_message "$(T "⚠️ Stopped after the old wallet was deleted. BTCPay is down and stays down.")"
            log_message "$(T "⚠️ %s is disabled, so a reboot won't start BTCPay on the unfinished volume." "$BTCPAY_SERVICE")"
            if [[ -n "$SAFETY_BACKUP_NAME" ]]; then
                log_message "$(T "⚠️ The old wallet is in the safety backup %s." "$SAFETY_BACKUP_NAME")"
            fi
            log_message "$(T "⚠️ Run this script again: the same option to finish, or option 5 to put the safety backup back.")"
            ;;
        handed)
            log_message "$(T "⚠️ Stopped after the wallet was handed to BTCPay. Check BTCPay's LND before relying on it:")"
            log_message "$(T "⚠️   docker logs --tail 50 %s" "$LND_CONTAINER_NAME")"
            log_message "$(T "⚠️ The backup service is still stopped. When LND is fine, rerun %s." "$INSTALLER")"
            ;;
    esac
    finish_in_tmux "$code"
    # Only now: until Enter, the session is still there and the dashboard should say so
    rm -f "$RUNNING_FILE"
    exit "$code"
}
trap on_exit EXIT

# === SERVER B ===
# ssh as the backup user, with its key and known_hosts, never asking for a password.
# remote_ssh leaves stdin alone (-n), so it can run inside loops that read; remote_ssh_stdin sends
# stdin to the remote command.
# timeout: a hung or hostile Server B must not freeze a recovery halfway. Uploads of a large
# safety backup get longer.
remote_ssh() {
    timeout 120 sudo -u "$SERVER_A_USER" -- "${SSH_COMMAND_ARR[0]}" -n -o BatchMode=yes "${SSH_COMMAND_ARR[@]:1}" "$@"
}

remote_ssh_stdin() {
    timeout 1800 sudo -u "$SERVER_A_USER" -- "${SSH_COMMAND_ARR[0]}" -o BatchMode=yes "${SSH_COMMAND_ARR[@]:1}" "$@"
}
# put <area> <name> of file $3 with its sha256 $4: the gate refuses an upload cut off on the way.
# A gate older than that refuses the sha256 ("too many words"): then the old form.
remote_put() {
    local out rc=0
    out=$(remote_ssh_stdin "put $1 $2 $4" < "$3" 2>&1 >/dev/null | head -c 65536) || rc=$?
    if (( rc != 0 )) && [[ "$out" == *"too many words"* ]]; then
        remote_ssh_stdin "put $1 $2" < "$3" > /dev/null
        return
    fi
    return "$rc"
}

# Server B only runs the commands of its backup gate (server-b-install.sh): ping, list <area>,
# get <area> <name>, put <area> <name>. Areas: main, daily, monthly, pre-recovery.
REMOTE_OK=false
if [[ -n "${REMOTE_SERVER:-}" && -n "${SERVER_B_USER:-${REMOTE_USER:-}}" ]] && [[ "$(remote_ssh ping 2>/dev/null)" == "ok" ]]; then
    REMOTE_OK=true
fi

# GitHub (github-lib.sh): everything there runs as the backup user, who holds the deploy key.
# Restoring reads it whenever it is set up, also while BACKUP_TO_GITHUB is off.
github_wallet() {
    {
        declare -p I18N 2>/dev/null || true
        # The message functions (named through compgen, so the message extractor skips this line)
        declare -f $(compgen -A function | grep -xE "T|say|_i18n_unescape") 2>/dev/null || true
        echo 'log_message() { echo "$1"; }'
        printf 'GITHUB_REPO=%q SERVER_A_USER_HOME=%q GITHUB_KEY_FILENAME=%q BACKUP_METADATA_FOLDER=%q\n' \
            "$GITHUB_REPO" "$SERVER_A_USER_HOME" "${GITHUB_KEY_FILENAME:-lnd_backup_github_key}" "$BACKUP_METADATA_FOLDER"
        cat -- "$SCRIPT_DIR/github-lib.sh"
        printf '%s\n' "$1"
    } | sudo -u "$SERVER_A_USER" -H bash -s
}
GITHUB_SET_UP=false
if [[ -n "${GITHUB_REPO:-}" ]] && sudo -u "$SERVER_A_USER" test -f "$SERVER_A_USER_HOME/.ssh/${GITHUB_KEY_FILENAME:-lnd_backup_github_key}"; then
    GITHUB_SET_UP=true
fi
# What is on GitHub, fetched once (as the backup user, into a folder of its own)
GITHUB_DIR=""
GITHUB_FETCHED=false
github_fetch_once() {
    $GITHUB_SET_UP || return 1
    if ! $GITHUB_FETCHED; then
        GITHUB_FETCHED=true
        # On disk, not in /tmp (memory on some systems): the repository can be up to 3 GB
        GITHUB_DIR=$(sudo -u "$SERVER_A_USER" mktemp -d -p /var/tmp lnd-github.XXXXXX) || return 1
        if ! github_wallet "github_fetch_all $(printf '%q' "$GITHUB_DIR/c")" >/dev/null 2>&1; then
            log_message "$(T "⚠️ The GitHub repository %s can't be reached, so it isn't searched." "$GITHUB_REPO")"
            sudo -u "$SERVER_A_USER" rm -rf -- "$GITHUB_DIR"
            GITHUB_DIR=""
        fi
    fi
    [[ -n "$GITHUB_DIR" ]]
}

# The disk with config's UUID mounted exactly at ATTACHED_VOLUME, which is not a symlink.
# mountpoint -q follows symlinks and doesn't look at which disk it is.
attached_ok() {
    [[ -n "${UUID:-}" && -d "$ATTACHED_VOLUME" && ! -L "$ATTACHED_VOLUME" ]] || return 1
    [[ "$(findmnt -rn -M "$ATTACHED_VOLUME" -o UUID 2>/dev/null)" == "$UUID" ]]
}

# === GPG ===
gpg_as_backup_user() {
    sudo -u "$SERVER_A_USER" -H -- gpg --homedir "$GPG_KEY_DIR" --batch "${GPG_PASS_OPTS[@]}" "$@"
}

# Decrypts a backup made by the service (or a safety backup) and checks it.
# Usage: decrypt_bundle <file.gpg> <dir>. Leaves <dir>/backup_compressed.tar.gz, checked against its
# checksum and signed with GPG_FINGERPRINT. On failure, DECRYPT_ERROR says why.
DECRYPT_ERROR=""
NO_SECKEY_SEEN=false
# gpg's status lines (file $1) say it is signed with the backup key. Only gpg's own status lines
# count (they share the stream with its messages). GOODSIG, or EXPKEYSIG: a good signature by a
# key that has expired since (every backup would be refused the day the key expires, also those
# made while it was valid). A revoked key (REVKEYSIG) or a bad signature is refused.
KEY_EXPIRED_SEEN=false
gpg_signed_ok() {
    if ! awk -v fp="$GPG_FINGERPRINT" '$1 == "[GNUPG:]" && $2 == "VALIDSIG" && ($3 == fp || $NF == fp) {found = 1} END {exit !found}' "$1"; then
        DECRYPT_ERROR=$(T "it is not signed with the backup key %s" "$GPG_FINGERPRINT")
        return 1
    fi
    grep -q '^\[GNUPG:\] GOODSIG ' "$1" && return 0
    if grep -q '^\[GNUPG:\] EXPKEYSIG ' "$1" && ! grep -q '^\[GNUPG:\] REVKEYSIG ' "$1"; then
        KEY_EXPIRED_SEEN=true
        return 0
    fi
    DECRYPT_ERROR=$(T "it is not signed with the backup key %s" "$GPG_FINGERPRINT")
    return 1
}

# Once, if a backup was signed by the backup key that has expired since: it is still good, but
# the backup service can't make new backups with it
warn_key_expired() {
    $KEY_EXPIRED_SEEN || return 0
    [[ -z "${KEY_EXPIRED_WARNED:-}" ]] || return 0
    KEY_EXPIRED_WARNED=1
    echo
    say "⚠️  The backup GPG key %s has expired. Backups signed with it are still good and are used, but" "$GPG_FINGERPRINT"
    say "   the backup service can't make new ones. Remove the expiry (as root):"
    say "   sudo -u %s gpg --homedir %s --quick-set-expire %s 0 '*'" "$SERVER_A_USER" "$GPG_KEY_DIR" "$GPG_FINGERPRINT"
    say "   sudo -u %s gpg --homedir %s --quick-set-expire %s 0" "$SERVER_A_USER" "$GPG_KEY_DIR" "$GPG_FINGERPRINT"
    say "   and save the key again where you keep it (its copy elsewhere still has the old date)."
}

# Only the signed manifest of a backup, with no decrypted copy kept: streamed from where it is,
# through gpg, into tar, which keeps the manifest and reads on to the end, so gpg checks the
# signature over all of it. Usage: read_signed_manifest <where> <path> <dir>; then check_manifest.
read_signed_manifest() {
    local where="$1" path="$2" dir="$3"
    mkdir -p "$dir"
    if ! fetch_backup "$where" "$path" /dev/stdout 2>/dev/null |
         gpg_as_backup_user --status-fd 2 --decrypt 2> "$dir/gpg.status" |
         tar -xf - -C "$dir" --no-same-owner manifest 2>/dev/null; then
        DECRYPT_ERROR=$(T "its signed manifest couldn't be read")
        return 1
    fi
    gpg_signed_ok "$dir/gpg.status" || return 1
    if [[ ! -f "$dir/manifest" || -L "$dir/manifest" ]]; then
        DECRYPT_ERROR=$(T "its signed manifest couldn't be read")
        return 1
    fi
}

decrypt_bundle() {
    local file="$1" dir="$2"
    mkdir -p "$dir"
    # Status lines go to stderr with the messages: sudo closes any other file descriptor
    if ! gpg_as_backup_user --status-fd 2 --decrypt < "$file" > "$dir/bundle.tar" 2> "$dir/gpg.status"; then
        if grep -q '^\[GNUPG:\] NO_SECKEY ' "$dir/gpg.status" && ! grep -q '^\[GNUPG:\] DECRYPTION_OKAY' "$dir/gpg.status"; then
            NO_SECKEY_SEEN=true
            DECRYPT_ERROR=$(T "it is encrypted to a GPG key this server doesn't have")
        else
            DECRYPT_ERROR=$(T "GPG could not decrypt it (%s)" "$(grep -v '^\[GNUPG:\]' "$dir/gpg.status" | tail -n 1)")
        fi
        return 1
    fi
    gpg_signed_ok "$dir/gpg.status" || return 1
    if ! tar -xf "$dir/bundle.tar" -C "$dir" backup_compressed.tar.gz backup_compressed.tar.gz.sha256 2>/dev/null; then
        DECRYPT_ERROR=$(T "it does not hold backup_compressed.tar.gz and its checksum")
        return 1
    fi
    # Backups made before manifests existed have none
    tar -xf "$dir/bundle.tar" -C "$dir" manifest 2>/dev/null || true
    rm -f "$dir/bundle.tar"
    if ! (cd "$dir" && sha256sum --quiet -c backup_compressed.tar.gz.sha256 >/dev/null 2>&1); then
        DECRYPT_ERROR=$(T "its checksum does not match (the file is damaged)")
        return 1
    fi
    return 0
}

# Decrypts and unpacks a backup into <dir>/files. Usage: unpack_backup <file.gpg> <dir>
unpack_backup() {
    local file="$1" dir="$2"
    decrypt_bundle "$file" "$dir" || return 1
    mkdir -p "$dir/files"
    if ! tar -xzf "$dir/backup_compressed.tar.gz" -C "$dir/files" --no-same-owner; then
        DECRYPT_ERROR=$(T "its archive could not be unpacked")
        return 1
    fi
    rm -f "$dir/backup_compressed.tar.gz"
    # The service backs up plain files only. A link in here would make root copy what it points
    # to (a host file) into the LND volume.
    if [[ -n "$(find "$dir/files" ! -type f ! -type d -print -quit)" ]]; then
        DECRYPT_ERROR=$(T "it holds links or special files, which the service never backs up")
        return 1
    fi
}

# The signed manifest (kind and time) against the file name, which isn't signed: anyone who can
# write to the attached volume or Server B could rename an old backup to look like the newest.
# Usage: check_manifest <dir> <expected kind> <file name>. Sets MANIFEST_STATE to verified, legacy
# (made before manifests existed) or bad, MANIFEST_TIME, MANIFEST_NODE, and DECRYPT_ERROR if bad.
MANIFEST_STATE=""
MANIFEST_TIME=""
MANIFEST_NODE=""
MANIFEST_CHANNELS=""
check_manifest() {
    local dir="$1" expected="$2" name="$3" kind="" stamp="" node="" channels="" line name_time full_time
    MANIFEST_TIME=""
    MANIFEST_NODE=""
    MANIFEST_CHANNELS=""
    if [[ ! -f "$dir/manifest" ]]; then
        MANIFEST_STATE=legacy
        return 0
    fi
    while IFS= read -r line; do
        case "$line" in
            kind=*) kind="${line#kind=}" ;;
            time=*) stamp="${line#time=}" ;;
            node=*) node="${line#node=}" ;;
            channels=*) channels="${line#channels=}" ;;
        esac
    done < "$dir/manifest"
    MANIFEST_STATE=bad
    if [[ "$kind" != "$expected" ]]; then
        DECRYPT_ERROR=$(T "its signed manifest says it is a '%s' backup, not '%s'" "$kind" "$expected")
        return 1
    fi
    if [[ ! "$stamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$ ]]; then
        DECRYPT_ERROR=$(T "its signed manifest has no valid time")
        return 1
    fi
    full_time="$stamp"
    case "$name" in
        encrypted_backup_*.gpg) name_time="${name#encrypted_backup_}"; name_time="${name_time%.gpg}" ;;
        pre-recovery_*.gpg) name_time="${name#pre-recovery_}"; name_time="${name_time%.gpg}" ;;
        # Milestones are copies of the day's or month's first backup
        backup_????-??-??.gpg) name_time="${name#backup_}"; name_time="${name_time%.gpg}"; stamp="${stamp:0:10}" ;;
        backup_????-??.gpg) name_time="${name#backup_}"; name_time="${name_time%.gpg}"; stamp="${stamp:0:7}" ;;
        *) name_time="" ;;
    esac
    if [[ "$stamp" != "$name_time" ]]; then
        DECRYPT_ERROR=$(T "its name doesn't match the time in its signed manifest (%s): it was renamed" "$stamp")
        return 1
    fi
    [[ "$node" =~ ^[0-9a-f]{66}$ ]] || node=""
    [[ "$channels" =~ ^[0-9]{1,6}$ ]] || channels=""
    MANIFEST_STATE=verified
    MANIFEST_TIME="$full_time"
    MANIFEST_NODE="$node"
    MANIFEST_CHANNELS="$channels"
}

# Decrypted backups stay in memory (/run) if they fit, with room to spare
dir_for_size() {
    local size="$1" free
    free=$(df --output=avail -B1 /run | tail -n 1)
    if (( free > size * 4 )); then
        echo "$SECRET_DIR"
    else
        echo "$BULK_DIR"
    fi
}

# === BACKUPS ===
# Time of a backup from its name: encrypted_backup_<ISO time>.gpg, or a milestone
# backup_YYYY-MM-DD.gpg / backup_YYYY-MM.gpg
backup_epoch() {
    local name ts
    name=$(basename "$1")
    case "$name" in
        encrypted_backup_*.gpg) ts="${name#encrypted_backup_}"; ts="${ts%.gpg}" ;;
        pre-recovery_*.gpg) ts="${name#pre-recovery_}"; ts="${ts%.gpg}" ;;
        backup_????-??-??.gpg) ts="${name#backup_}"; ts="${ts%.gpg}" ;;
        backup_????-??.gpg) ts="${name#backup_}"; ts="${ts%.gpg}-01" ;;
        *) return 1 ;;
    esac
    date -d "$ts" +%s 2>/dev/null
}

# Only names the service and this script make: anything else (a newline, escape codes, spaces)
# could break the list below or reach the terminal
backup_name_ok() {
    [[ "$1" =~ ^[A-Za-z0-9:+._-]+$ ]]
}

# Lists backups as "<rank> <epoch> <where> <path>", best first (names dated more than 5 minutes
# in the future are left out): main backups newest first, then
# milestones (which hold the first backup of a day or month, never the last), newest first.
# Within the same time the attached volume comes before Server B.
# Usage: list_backups main|pre-recovery
list_backups() {
    local kind="$1" f epoch dir now
    local -a local_dirs=() remote_dirs=()
    now=$(date +%s)
    if [[ "$kind" == "main" ]]; then
        local_dirs=("0 $SECOND_BACKUP_DIR" "1 $SECOND_BACKUP_DIR/milestones/daily" "1 $SECOND_BACKUP_DIR/milestones/monthly")
        remote_dirs=("0 main" "1 daily" "1 monthly")
    else
        local_dirs=("0 $PRE_RECOVERY_LOCAL")
        remote_dirs=("0 pre-recovery")
    fi
    {
        if attached_ok; then
            for entry in "${local_dirs[@]}"; do
                dir="${entry#* }"
                for f in "$dir"/*.gpg; do
                    [[ -f "$f" ]] || continue
                    backup_name_ok "$(basename "$f")" || continue
                    epoch=$(backup_epoch "$f") || continue
                    (( epoch <= now + 300 )) || continue
                    printf '%s %s 0attached %s\n' "${entry%% *}" "$epoch" "$f"
                done
            done
        fi
        if $REMOTE_OK; then
            # On Server B a "path" is <area>/<name>, which fetch_backup turns into get <area> <name>
            for entry in "${remote_dirs[@]}"; do
                dir="${entry#* }"
                remote_ssh "list $dir" 2>/dev/null | head -c 1048576 |
                    while IFS= read -r f; do
                        backup_name_ok "$f" || continue
                        epoch=$(backup_epoch "$f") || continue
                        (( epoch <= now + 300 )) || continue
                        printf '%s %s 1serverb %s/%s\n' "${entry%% *}" "$epoch" "$dir" "$f"
                    done
            done
        fi
        if github_fetch_once; then
            # The same areas as on Server B, read as the backup user
            for entry in "${remote_dirs[@]}"; do
                dir="${entry#* }"
                sudo -u "$SERVER_A_USER" find "$GITHUB_DIR/c/$dir" -maxdepth 1 -type f -name '*.gpg' -printf '%f\n' 2>/dev/null |
                    while IFS= read -r f; do
                        backup_name_ok "$f" || continue
                        epoch=$(backup_epoch "$f") || continue
                        (( epoch <= now + 300 )) || continue
                        printf '%s %s 2github %s\n' "${entry%% *}" "$epoch" "$GITHUB_DIR/c/$dir/$f"
                    done
            done
        fi
    } | sort -k1,1n -k2,2nr -k3,3
}

# Copies a backup here. Usage: fetch_backup <where> <path> <dest>
fetch_backup() {
    local where="$1" path="$2" dest="$3"
    if [[ "$where" == "0attached" || "$where" == "2github" ]]; then
        # As the backup user, who owns these folders: root would follow a planted symlink and
        # copy whatever it points to. Root writes dest, in its own work folder.
        # shellcheck disable=SC2024
        sudo -u "$SERVER_A_USER" cat -- "$path" > "$dest"
    else
        # Can be a whole LND volume (a safety backup), so the longer timeout. Never more than the
        # gate takes (20 GiB a backup, its MAX_BYTES): a hostile Server B can't fill this
        # server's disk, where LND and bitcoind run
        local limit=$(( 20 * 1024 * 1024 * 1024 ))
        remote_ssh_stdin "get ${path%%/*} ${path#*/}" < /dev/null | head -c "$(( limit + 1 ))" > "$dest" || return 1
        if [[ -f "$dest" ]] && (( $(stat -c %s -- "$dest") > limit )); then
            rm -f -- "$dest"
            return 1
        fi
    fi
}

# Where a backup is, as a whole phrase ("on GitHub"), so each language can say it its own way
where_on() {
    case "$1" in
        0attached) say "on the attached volume" ;;
        2github) say "on GitHub" ;;
        *) say "on Server B" ;;
    esac
}

# A length of time, roughly: "40 minutes", "5 hours", "3 days"
duration_text() {
    local seconds="$1"
    if (( seconds < 7200 )); then say "%s minutes" "$(( seconds / 60 ))"
    elif (( seconds < 172800 )); then say "%s hours" "$(( seconds / 3600 ))"
    else say "%s days" "$(( seconds / 86400 ))"
    fi
}

age_text() {
    local seconds=$(( $(date +%s) - $1 ))
    if (( seconds < 3600 )); then say "%s minutes old" "$(( seconds / 60 ))"
    elif (( seconds < 172800 )); then say "%s hours old" "$(( seconds / 3600 ))"
    else say "%s days old" "$(( seconds / 86400 ))"
    fi
}

# Finds the newest backup that decrypts, is signed with the backup key, matches its checksum and
# whose signed manifest matches its name. Backups made before manifests existed are only used when
# no backup with a manifest works: otherwise an old one renamed to look newest could be picked.
# Sets BACKUP_FILES (its unpacked files) and BACKUP_LABEL; returns 1 if none works.
BACKUP_FILES=""
BACKUP_LABEL=""
CHOSEN_EPOCH=0
find_latest_backup() {
    local rank epoch where path n=0 work size pass dir
    local -a skipped=() candidates=()
    log_message "$(T "🔎 Looking for the latest backup on the attached volume, Server B and GitHub...")"
    attached_ok || log_message "$(T "⚠️ The attached volume is not mounted, so it isn't searched.")"
    $REMOTE_OK || log_message "$(T "⚠️ Server B can't be reached, so it isn't searched.")"
    # Fetched here, not in list_backups' pipeline (a subshell), so the result is known below
    github_fetch_once >/dev/null 2>&1 || true
    mapfile -t candidates < <(list_backups main)

    # A destination that is on but couldn't be searched may hold the newest backup. Server B is
    # the one place a broken-into Server A can't delete from, so it matters most.
    local unsearched
    unsearched=$(unsearched_places)
    if [[ -n "$unsearched" ]]; then
        echo
        say "⚠️  Not searched: %s. A newer backup may be there, with channels the others don't have." "$unsearched"
        say "   Best: make it reachable (mount the disk, check Server B's address and SSH), then run this again."
        confirm_phrase yes "$(T "Type yes to look only in the places that answered: ")" ||
            die "$(T "Stopped: nothing was changed.")"
    fi
    # The newest backup found anywhere, usable or not: the one chosen is compared with it below
    local newest_epoch=0
    for line in "${candidates[@]}"; do
        read -r rank epoch _ _ <<< "$line"
        [[ "$rank" == 0 ]] && (( epoch > newest_epoch )) && newest_epoch=$epoch
    done

    for pass in verified legacy; do
        for line in "${candidates[@]}"; do
            read -r rank epoch where path <<< "$line"
            [[ -n "$path" ]] || continue
            n=$((n + 1))
            work="$BULK_DIR/candidate.$n"
            mkdir -p "$work"
            if ! fetch_backup "$where" "$path" "$work/backup.gpg" 2>/dev/null; then
                [[ "$pass" == verified ]] && skipped+=("$(T "%s %s: could not be copied" "$(basename "$path")" "$(where_on "$where")")")
                remove_work_path "$work"
                continue
            fi
            size=$(stat -c %s "$work/backup.gpg")
            dir="$(dir_for_size "$size")/backup.$n"
            if ! unpack_backup "$work/backup.gpg" "$dir" || ! check_manifest "$dir" backup "$(basename "$path")"; then
                [[ "$pass" == verified ]] && skipped+=("$(T "%s %s: %s" "$(basename "$path")" "$(where_on "$where")" "$DECRYPT_ERROR")")
                remove_work_path "$work" "$dir"
                continue
            fi
            remove_work_path "$work"
            if [[ "$MANIFEST_STATE" != "$pass" ]]; then
                remove_work_path "$dir"
                continue
            fi
            BACKUP_FILES="$dir/files"
            CHOSEN_EPOCH=$epoch
            BACKUP_LABEL=$(T "%s %s (%s)" "$(basename "$path")" "$(where_on "$where")" "$(age_text "$epoch")")
            if [[ "$rank" == "1" ]]; then
                BACKUP_LABEL+=$(T ", a milestone: no regular backup could be used")
            fi
            if [[ "$pass" == legacy ]]; then
                BACKUP_LABEL+=$(T "; ⚠️ made before backups carried a signed date, so its date is not verified")
            fi
            break 2
        done
    done

    local s
    for s in "${skipped[@]}"; do
        log_message "$(T "⚠️ Skipped %s" "$s")"
    done
    [[ -n "$BACKUP_FILES" ]] || return 1
    BACKUP_OLDER_BY=0
    (( newest_epoch > CHOSEN_EPOCH + 60 )) && BACKUP_OLDER_BY=$(( newest_epoch - CHOSEN_EPOCH ))
    return 0
}

# The destinations that are on but couldn't be searched (after github_fetch_once), as one line
# ("Server B, GitHub"); nothing if every one answered
unsearched_places() {
    local -a places=()
    [[ "${BACKUP_TO_VOLUME:-yes}" == yes ]] && ! attached_ok && places+=("$(T "the attached volume")")
    [[ "${BACKUP_TO_SERVER_B:-yes}" == yes ]] && ! $REMOTE_OK && places+=("$(T "Server B")")
    [[ "${BACKUP_TO_GITHUB:-no}" == yes && -z "$GITHUB_DIR" ]] && places+=("$(T "GitHub")")
    (( ${#places[@]} > 0 )) || return 0
    local IFS=,
    echo "${places[*]}" | sed 's/,/, /g'
}

# When backups were found but none decrypts for lack of the key (a new server with a new key)
explain_no_seckey() {
    $NO_SECKEY_SEEN || return 0
    echo
    say "⚠️  The backups are encrypted to a GPG key this server doesn't have: this server's key (%s) isn't" "${GPG_FINGERPRINT:-?}"
    say "   the one they were made with. A new server needs the old key: run setup and paste it when asked"
    say "   (first delete the new key and empty GPG_FINGERPRINT in config), then run this again."
}

# Said right after the backup chosen is named: it is older than the newest backup there is, so
# channels opened since aren't in it
BACKUP_OLDER_BY=0
warn_if_older() {
    warn_key_expired
    (( BACKUP_OLDER_BY > 0 )) || return 0
    say "⚠️  This backup is %s older than the newest one found, which couldn't be used (listed above)." "$(duration_text "$BACKUP_OLDER_BY")"
    say "   Channels opened after it aren't in its channel.backup: their funds stay with the peer until"
    say "   it closes them. This server's own channel.backup is tried too, if it still has one."
}

# === LND HELPERS ===
lnd_state() {
    docker exec "$1" lncli --lnddir=/data state 2>/dev/null | jq -r '.state // empty' 2>/dev/null || true
}

# lncli on BTCPay's LND, with the macaroon BTCPay itself uses
btcpay_lncli() {
    docker exec "$LND_CONTAINER_NAME" lncli --macaroonpath=/data/admin.macaroon "$@"
}

init_lncli() {
    docker exec "$LND_INIT" lncli --lnddir=/data "$@"
}

# Waits until a container's LND reaches one of the given states; gives up early if lnd-init exits.
# Usage: wait_for_state <container> <seconds> <state>...
wait_for_state() {
    local container="$1" timeout="$2" waited=0 state
    shift 2
    while (( waited < timeout )); do
        state=$(lnd_state "$container")
        for wanted in "$@"; do
            [[ "$state" == "$wanted" ]] && return 0
        done
        if [[ "$container" == "$LND_INIT" && "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" != "true" ]]; then
            return 1
        fi
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}

# === STEP: WHAT THE CURRENT WALLET HOLDS ===
# Read while BTCPay's LND still runs. Sets OLD_READ, OLD_NODE_ID, OLD_CHANNELS, OLD_LIMBO and a summary.
OLD_READ=false
OLD_NODE_ID=""
OLD_CHANNELS=0
OLD_PENDING=0
OLD_LIMBO=0
OLD_HAS_FUNDS=false
OLD_SUMMARY=()
read_current_wallet() {
    local info balance chans pending synced
    OLD_SUMMARY=()

    if [[ ! -f "$LIVE_MAINNET/wallet.db" ]]; then
        OLD_SUMMARY+=("$(T "There is no wallet in %s, so nothing to check." "$LND_DIR")")
        return 0
    fi

    if [[ -z "$(docker ps -q -f name="^${LND_CONTAINER_NAME}$")" ]]; then
        log_message "$(T "⚠️ LND container '%s' is stopped. Starting BTCPay to read the current wallet..." "$LND_CONTAINER_NAME")"
        btcpay_run btcpay-up.sh >/dev/null 2>&1 || log_message "$(T "⚠️ btcpay-up.sh failed")"
    fi

    log_message "$(T "⏳ Waiting for the current LND to answer (up to 3 minutes)...")"
    if ! wait_for_state "$LND_CONTAINER_NAME" 180 RPC_ACTIVE SERVER_ACTIVE ||
       ! info=$(btcpay_lncli getinfo 2>/dev/null) ||
       ! balance=$(btcpay_lncli walletbalance 2>/dev/null) ||
       ! chans=$(btcpay_lncli listchannels 2>/dev/null) ||
       ! pending=$(btcpay_lncli pendingchannels 2>/dev/null); then
        OLD_SUMMARY+=("$(T "Couldn't read the current wallet: LND isn't answering (state: %s)." "$(lnd_state "$LND_CONTAINER_NAME" || true)")")
        return 0
    fi

    OLD_READ=true
    OLD_NODE_ID=$(jq -r '.identity_pubkey' <<< "$info")
    synced=$(jq -r '.synced_to_chain' <<< "$info")
    OLD_CHANNELS=$(jq '.channels | length' <<< "$chans")
    OLD_PENDING=$(jq '(.pending_open_channels | length) + (.pending_force_closing_channels | length) + (.waiting_close_channels | length) + (.pending_closing_channels // [] | length)' <<< "$pending")
    OLD_LIMBO=$(jq -r '.total_limbo_balance // "0"' <<< "$pending")

    local confirmed unconfirmed local_sat
    confirmed=$(jq -r '.confirmed_balance // "0"' <<< "$balance")
    unconfirmed=$(jq -r '.unconfirmed_balance // "0"' <<< "$balance")
    local_sat=$(btcpay_lncli channelbalance 2>/dev/null | jq -r '.local_balance.sat // .balance // "0"' || echo "?")

    OLD_SUMMARY+=("$(T "Node ID:           %s" "$OLD_NODE_ID")")
    OLD_SUMMARY+=("$(T "On-chain:          %s sat confirmed, %s sat unconfirmed" "$confirmed" "$unconfirmed")")
    OLD_SUMMARY+=("$(T "Open channels:     %s (your share: %s sat)" "$OLD_CHANNELS" "$local_sat")")
    OLD_SUMMARY+=("$(T "Opening/closing:   %s channels, %s sat waiting in closes (limbo)" "$OLD_PENDING" "$OLD_LIMBO")")
    if [[ "$synced" != "true" ]]; then
        OLD_SUMMARY+=("$(T "⚠️ LND is not synced to the chain, so these numbers may be out of date.")")
    fi
    if [[ "$confirmed" != "0" || "$unconfirmed" != "0" || "$OLD_CHANNELS" != "0" || "$OLD_PENDING" != "0" || "$OLD_LIMBO" != "0" ]]; then
        OLD_HAS_FUNDS=true
    fi
}

# === STEP: SAFETY BACKUP ===
# Saves the whole LND volume, encrypted and signed with the backup key like the service's backups,
# as pre-recovery_<time>.gpg on the attached volume and Server B. At least one copy must be stored
# and checked, or the script stops (nothing has been deleted at that point).
make_safety_backup() {
    local ts name size free stored=0 local_sum remote_sum
    # Server B's copy is downloaded back and checked here, not on Server B's word
    if [[ ! -d "$LND_DIR" || -z "$(ls -A "$LND_DIR" 2>/dev/null)" ]]; then
        log_message "$(T "ℹ️ The LND volume is missing or empty, so there is nothing to save in a safety backup.")"
        return 0
    fi

    ts=$(date -u --iso-8601=seconds)
    name="pre-recovery_${ts}.gpg"
    size=$(du -sb "$LND_DIR" | cut -f1)
    free=$(df --output=avail -B1 "$BULK_DIR" | tail -n 1)
    (( free > size * 3 )) || die "$(T "Not enough free space in /var/tmp for the safety backup (LND volume: %s bytes)" "$size")"

    log_message "$(T "💾 Making the safety backup of the current LND volume (%s)..." "$(numfmt --to=iec "$size")")"
    tar -czf "$BULK_DIR/backup_compressed.tar.gz" -C "$LND_DIR" . ||
        die "$(T "Could not archive %s for the safety backup" "$LND_DIR")"
    (cd "$BULK_DIR" && sha256sum backup_compressed.tar.gz > backup_compressed.tar.gz.sha256)
    # Signed with the rest: what this is, when it was made, which wallet it holds and how many
    # channels (when LND could tell), checked when it is put back (option 5)
    printf 'kind=pre-recovery\ntime=%s\nnode=%s\n' "$ts" "$OLD_NODE_ID" > "$BULK_DIR/manifest"
    $OLD_READ && printf 'channels=%s\n' "$(( OLD_CHANNELS + OLD_PENDING ))" >> "$BULK_DIR/manifest"
    tar -cf "$BULK_DIR/payload.tar" -C "$BULK_DIR" backup_compressed.tar.gz backup_compressed.tar.gz.sha256 manifest
    rm -f "$BULK_DIR/backup_compressed.tar.gz" "$BULK_DIR/backup_compressed.tar.gz.sha256" "$BULK_DIR/manifest"
    gpg_as_backup_user --yes --recipient "$GPG_FINGERPRINT" --local-user "$GPG_FINGERPRINT" \
        --encrypt --sign < "$BULK_DIR/payload.tar" > "$BULK_DIR/$name" ||
        die "$(T "GPG could not encrypt the safety backup")"
    rm -f "$BULK_DIR/payload.tar"

    if ! decrypt_bundle "$BULK_DIR/$name" "$BULK_DIR/verify"; then
        die "$(T "The safety backup failed its check: %s" "$DECRYPT_ERROR")"
    fi
    remove_work_path "$BULK_DIR/verify"
    local_sum=$(sha256sum "$BULK_DIR/$name" | cut -d' ' -f1)

    if [[ "${BACKUP_TO_VOLUME:-yes}" != yes ]]; then
        :
    elif attached_ok; then
        # Written by the backup user, who owns the attached volume: root writing, changing owners
        # or modes there would follow symlinks the backup user can plant
        if sudo -u "$SERVER_A_USER" sh -c 'umask 077 && mkdir -p -- "$1" && cat > "$1/$2.tmp"' _ \
                "$PRE_RECOVERY_LOCAL" "$name" < "$BULK_DIR/$name" &&
           [[ "$(sudo -u "$SERVER_A_USER" sha256sum -- "$PRE_RECOVERY_LOCAL/$name.tmp" | cut -d' ' -f1)" == "$local_sum" ]] &&
           sudo -u "$SERVER_A_USER" mv -f -- "$PRE_RECOVERY_LOCAL/$name.tmp" "$PRE_RECOVERY_LOCAL/$name"; then
            log_message "$(T "✅ Safety backup stored and checked: %s/%s" "$PRE_RECOVERY_LOCAL" "$name")"
            stored=$((stored + 1))
        else
            remove_pre_recovery_tmp "$PRE_RECOVERY_LOCAL/$name.tmp" || true
            log_message "$(T "⚠️ Could not store the safety backup on the attached volume")"
        fi
    else
        log_message "$(T "⚠️ The attached volume is not mounted, so the safety backup is not stored there")"
    fi

    if [[ "${BACKUP_TO_SERVER_B:-yes}" != yes ]]; then
        :
    elif $REMOTE_OK; then
        # The gate stores it under a new name only (never overwrites); downloaded back and checked
        # here rather than taken on Server B's word
        if remote_put pre-recovery "$name" "$BULK_DIR/$name" "$local_sum" &&
           remote_sum=$(remote_ssh_stdin "get pre-recovery $name" < /dev/null | head -c "$(( $(stat -c %s -- "$BULK_DIR/$name") + 1 ))" | sha256sum | cut -d' ' -f1) &&
           [[ "$remote_sum" == "$local_sum" ]]; then
            log_message "$(T "✅ Safety backup stored and checked on Server B: pre-recovery/%s" "$name")"
            stored=$((stored + 1))
        else
            log_message "$(T "⚠️ Could not store the safety backup on Server B")"
        fi
    else
        log_message "$(T "⚠️ Server B's backup gate can't be reached, so the safety backup is not stored there")"
    fi

    if [[ "${BACKUP_TO_GITHUB:-no}" == yes ]] && $GITHUB_SET_UP; then
        # Handed to the backup user, who stores it with its deploy key
        local gh_tmp
        gh_tmp=$(sudo -u "$SERVER_A_USER" mktemp -d) &&
            sudo -u "$SERVER_A_USER" sh -c 'cat > "$1"' _ "$gh_tmp/$name" < "$BULK_DIR/$name"
        if [[ -n "$gh_tmp" ]] && github_wallet "github_store $(printf '%q' "$gh_tmp/$name") pre-recovery"; then
            log_message "$(T "✅ Safety backup stored and checked on GitHub: pre-recovery/%s" "$name")"
            stored=$((stored + 1))
        else
            log_message "$(T "⚠️ Could not store the safety backup on GitHub")"
        fi
        [[ -n "$gh_tmp" ]] && sudo -u "$SERVER_A_USER" rm -rf -- "$gh_tmp"
    fi
    rm -f "$BULK_DIR/$name"

    (( stored > 0 )) || die "$(T "The safety backup could not be stored anywhere. Nothing has been deleted.")"
    SAFETY_BACKUP_NAME="$name"
}

# === STEP: STOP EVERYTHING ===
# Every option that stops BTCPay comes through here, so this is where stopping it is confirmed
confirm_btcpay_stop() {
    local downtime
    case "$CHOICE" in
        2 | 3) downtime=$(T "a few minutes, plus the scan for old funds, which can take minutes to hours") ;;
        4) downtime=$(T "a few minutes, for the safety backup") ;;
        *) downtime=$(T "a few minutes") ;;
    esac
    echo
    say "⚠️  BTCPay will be stopped: the store can't take payments and Lightning is offline until"
    say "   this finishes (%s)." "$downtime"
    say "   %s is disabled meanwhile, so a reboot can't start BTCPay too early;" "$BTCPAY_SERVICE"
    say "   the script starts BTCPay again at the end. The backup service pauses too."
    confirm_phrase "STOP BTCPAY" "$(T "Type 'STOP BTCPAY' to stop it: ")" ||
        die "$(T "Aborted by user: BTCPay was not stopped and nothing was changed.")"
}

stop_everything() {
    confirm_btcpay_stop
    # Running, or about to run again (activating, e.g. waiting to restart after a failure, which is
    # likely just when the wallet is broken): stopped either way, or systemd would start it in the
    # middle of the wallet change
    local state
    state=$(systemctl show -p ActiveState --value "$RSYNC_BACKUP_SERVICE_NAME" 2>/dev/null || true)
    if [[ "$state" == active || "$state" == activating || "$state" == reloading ]]; then
        BACKUP_SERVICE_WAS_ACTIVE=true
        log_message "$(T "🛑 Stopping the backup service (it would otherwise back up the new wallet and rotate the old one's backups out)...")"
    fi
    systemctl stop "$RSYNC_BACKUP_SERVICE_NAME" 2>/dev/null || true
    STAGE="stopped"
    # A reboot in the middle would otherwise start BTCPay on an unfinished volume
    if systemctl is-enabled --quiet "$BTCPAY_SERVICE" 2>/dev/null; then
        mkdir -p "$(dirname "$BTCPAY_DISABLED_MARKER")"
        touch "$BTCPAY_DISABLED_MARKER"
        systemctl disable --quiet "$BTCPAY_SERVICE"
        BTCPAY_SERVICE_DISABLED=true
        log_message "$(T "🔒 %s disabled until the script finishes" "$BTCPAY_SERVICE")"
    elif [[ -f "$BTCPAY_DISABLED_MARKER" ]]; then
        BTCPAY_SERVICE_DISABLED=true
        log_message "$(T "ℹ️ %s was left disabled by an earlier run that stopped partway; it is enabled again at the end" "$BTCPAY_SERVICE")"
    fi

    log_message "$(T "🛑 Stopping all BTCPay Server containers using btcpay-down.sh...")"
    if btcpay_run btcpay-down.sh; then
        log_message "$(T "✅ BTCPay stack stopped successfully.")"
    else
        die "$(T "Failed to stop BTCPay stack via btcpay-down.sh")"
    fi
}

enable_btcpay_service() {
    $BTCPAY_SERVICE_DISABLED || return 0
    systemctl enable --quiet "$BTCPAY_SERVICE" || return 1
    rm -f "$BTCPAY_DISABLED_MARKER"
    BTCPAY_SERVICE_DISABLED=false
}

# === STEP: NEW VOLUME ===
# Docker Compose labels of the old volume, so btcpay-up.sh accepts the new one without a warning
VOLUME_LABEL_ARGS=()
remember_volume_labels() {
    local labels
    labels=$(docker volume inspect -f '{{json .Labels}}' "$LND_VOLUME" 2>/dev/null || echo null)
    VOLUME_LABEL_ARGS=()
    if [[ "$labels" != "null" && "$labels" != "{}" && -n "$labels" ]]; then
        while IFS= read -r label; do
            VOLUME_LABEL_ARGS+=(--label "$label")
        done < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' <<< "$labels")
    else
        VOLUME_LABEL_ARGS=(--label "com.docker.compose.project=${LND_VOLUME%%_*}" --label "com.docker.compose.volume=${LND_VOLUME#*_}")
    fi
}

recreate_volume() {
    log_message "$(T "🧹 Deleting the old LND volume '%s'..." "${LND_VOLUME}")"
    if docker volume inspect "$LND_VOLUME" &>/dev/null; then
        if ! docker volume rm "$LND_VOLUME" >/dev/null; then
            local containers_using_volume
            containers_using_volume=$(docker ps -a --filter volume="$LND_VOLUME" -q)
            if [[ -n "$containers_using_volume" ]]; then
                log_message "$(T "⚠️ Containers using the volume still exist. Stopping and removing them...")"
                # shellcheck disable=SC2086
                docker stop $containers_using_volume >/dev/null
                # shellcheck disable=SC2086
                docker rm $containers_using_volume >/dev/null
            fi
            docker volume rm "$LND_VOLUME" >/dev/null || die "$(T "Still unable to remove volume '%s'." "${LND_VOLUME}")"
        fi
    fi
    STAGE="deleted"
    docker volume create "${VOLUME_LABEL_ARGS[@]}" "$LND_VOLUME" >/dev/null || die "$(T "Could not create volume '%s'" "${LND_VOLUME}")"

    # Everything below writes into LND_DIR, so it must be this volume
    local mountpoint
    mountpoint=$(docker volume inspect -f '{{.Mountpoint}}' "$LND_VOLUME")
    [[ "$(realpath -m "$mountpoint")" == "$(realpath -m "$LND_DIR")" ]] ||
        die "$(T "LND_DIR in config (%s) is not the volume's folder (%s)" "$LND_DIR" "$mountpoint")"
    log_message "$(T "✅ Empty volume '%s' created" "${LND_VOLUME}")"
}

# Empties the new volume again, for a second try (only ever the volume this run created)
empty_new_volume() {
    [[ "$STAGE" == "deleted" ]] || die "$(T "Refusing to empty %s outside a wallet setup" "$LND_DIR")"
    docker rm -f "$LND_INIT" >/dev/null 2>&1 || true
    # -xdev: never into another filesystem mounted inside, like safe_delete's --one-file-system
    find "$LND_DIR" -xdev -mindepth 1 -delete
}

# === STEP: TEMPORARY LND ===
FEE_FLAG=""
start_lnd_init() {
    docker rm -f "$LND_INIT" >/dev/null 2>&1 || true
    if [[ -z "$FEE_FLAG" ]]; then
        # LND refuses to run neutrino on mainnet without a fee URL. The flag was renamed in newer
        # LND versions, so ask the image which one it knows.
        local fee_url="https://nodes.lightning.computer/fees/v1/btc-fee-estimates.json" help
        # Captured first: grep -q stopping early would fail the pipeline under pipefail
        help=$(docker run --rm --entrypoint lnd "$LND_IMAGE" --help 2>&1 || true)
        if grep -q -- '--fee.url' <<< "$help"; then
            FEE_FLAG="--fee.url=$fee_url"
        else
            FEE_FLAG="--neutrino.feeurl=$fee_url"
        fi
        log_message "$(T "ℹ️ Using fee estimates flag: %s" "${FEE_FLAG%%=*}")"
    fi

    # No ports are published: the REST calls run inside the container. The plain lnd entrypoint
    # skips BTCPay's startup script, which would create a wallet of its own.
    log_message "$(T "🚀 Starting temporary LND container...")"
    docker run -d \
        --name="$LND_INIT" \
        -v "${LND_VOLUME}:/data" \
        --entrypoint lnd \
        "$LND_IMAGE" \
        --bitcoin.active \
        --bitcoin.mainnet \
        --bitcoin.node=neutrino \
        --neutrino.connect=btcd-mainnet.lightning.computer \
        "$FEE_FLAG" \
        --lnddir=/data \
        --tlscertpath=/data/tls.cert \
        --tlskeypath=/data/tls.key \
        --logdir=/data/logs \
        --restlisten=localhost:8080 \
        --rpclisten=localhost:10009 >/dev/null

    log_message "$(T "⏳ Waiting for LND to be ready for wallet creation (up to 180s)...")"
    wait_for_state "$LND_INIT" 180 NON_EXISTING || {
        docker logs --tail 20 "$LND_INIT" 2>&1 | show_lines
        die "$(T "Temporary LND did not get ready for wallet creation")"
    }
    docker exec "$LND_INIT" sh -c 'command -v curl' >/dev/null ||
        die "$(T "The LND image %s has no curl, which the wallet setup needs" "$LND_IMAGE")"
    log_message "$(T "✅ LND is ready for wallet creation")"
}

# REST call inside lnd-init; the request body comes on stdin, so secrets never appear on a command line
init_rest() {
    docker exec -i "$LND_INIT" curl -sS --cacert /data/tls.cert "$@"
}

# Puts files from the backup back that keep paired apps working: the TLS certificate and the
# macaroons. They only work with the wallet password they were made with, so only when the
# backup's password is used.
# Usage: place_credentials <unpacked backup folder>
place_credentials() {
    local from="$1" f
    mkdir -p "$LIVE_MAINNET"
    for f in tls.cert tls.key admin.macaroon invoice.macaroon readonly.macaroon; do
        [[ -f "$from/$f" ]] && install -m 600 "$from/$f" "$LND_DIR/$f"
    done
    for f in "$from/$MAINNET_REL"/macaroons.db "$from/$MAINNET_REL"/*.macaroon; do
        [[ -f "$f" ]] && install -m 600 "$f" "$LIVE_MAINNET/$(basename "$f")"
    done
    return 0
}

# Creates (or restores) the wallet in lnd-init. Returns 0 when LND answers with the new wallet,
# 2 when LND refused the seed, 3 when the restored macaroons don't open with this password.
init_wallet() {
    local response waited=0
    response=$(
        INIT_PW="$WALLET_PASSWORD" INIT_SEED="$SEED_WORDS" INIT_PASS="$SEED_PASSPHRASE" \
        jq -n --argjson rw "$RECOVERY_WINDOW" '
            {wallet_password: (env.INIT_PW | @base64), cipher_seed_mnemonic: (env.INIT_SEED | split(" "))}
            + (if env.INIT_PASS != "" then {aezeed_passphrase: (env.INIT_PASS | @base64)} else {} end)
            + (if $rw > 0 then {recovery_window: $rw} else {} end)' |
        init_rest -X POST --data-binary @- https://localhost:8080/v1/initwallet 2>&1
    ) || true
    if ! jq -e '.admin_macaroon' >/dev/null 2>&1 <<< "$response"; then
        # Only on screen: LND's reason can name a mistyped seed word and its position
        say "   LND says: %s" "$(jq -r '.message // .' 2>/dev/null <<< "$response" | head -c 300 | LC_ALL=C tr -d '\000-\037\177')"
        log_message "$(T "❌ LND refused the wallet (a seed word, the seed passphrase or the password; LND's reason is shown above, not logged)")"
        return 2
    fi

    log_message "$(T "⏳ Waiting for LND RPC to be available after wallet creation (up to 180s)...")"
    while (( waited < 180 )); do
        if init_lncli getinfo >/dev/null 2>&1; then
            log_message "$(T "✅ Wallet created in the temporary LND")"
            return 0
        fi
        if [[ "$(docker inspect -f '{{.State.Running}}' "$LND_INIT" 2>/dev/null)" != "true" ]]; then
            # Logs captured first: grep -q stopping early would fail the pipeline under pipefail
            if grep -q "unable to unlock macaroons" <<< "$(docker logs "$LND_INIT" 2>&1)"; then
                return 3
            fi
            docker logs --tail 20 "$LND_INIT" 2>&1 | show_lines
            die "$(T "Temporary LND stopped after wallet creation")"
        fi
        sleep 2
        waited=$((waited + 2))
    done
    die "$(T "Timed out waiting for the temporary LND after wallet creation")"
}

# === STEP: QUESTIONS ===
ask_password() {
    local first second
    while true; do
        read -rsp "$(T "Wallet password (at least 8 characters): ")" first; echo
        if (( ${#first} < 8 )); then
            say "The password must have at least 8 characters."
            continue
        fi
        read -rsp "$(T "Same password again: ")" second; echo
        if [[ "$first" != "$second" ]]; then
            say "The passwords don't match."
            continue
        fi
        WALLET_PASSWORD="$first"
        return 0
    done
}

# The seed stays inside bash (no tr, wc or temp files), lower case and single spaces
ask_seed() {
    local words
    local -a list
    while true; do
        read -rsp "$(T "Seed (24 words, separated by spaces, hidden while typed): ")" words; echo
        words="${words,,}"
        set -f
        # shellcheck disable=SC2206
        list=($words)
        set +f
        if (( ${#list[@]} != 24 )); then
            say "That's %s words, not 24." "${#list[@]}"
            continue
        fi
        SEED_WORDS="${list[*]}"
        break
    done
    read -rsp "$(T "Seed passphrase, only if you set one when the seed was made (Enter for none): ")" SEED_PASSPHRASE; echo
    local window
    read -rp "$(T "Addresses to look ahead when scanning for old funds (Enter for %s): " "$RECOVERY_WINDOW_DEFAULT")" window
    if [[ -z "$window" ]]; then
        RECOVERY_WINDOW=$RECOVERY_WINDOW_DEFAULT
    elif [[ "$window" =~ ^[0-9]+$ ]] && (( window > 0 )); then
        RECOVERY_WINDOW=$window
    else
        say "Not a number, using %s." "$RECOVERY_WINDOW_DEFAULT"
        RECOVERY_WINDOW=$RECOVERY_WINDOW_DEFAULT
    fi
}

# The backup's walletunlock.json: BTCPay's own place first, then the copy next to lnd.conf
backup_unlock_file() {
    local f
    [[ -n "$BACKUP_FILES" ]] || return 1
    for f in "$BACKUP_FILES/$UNLOCK_REL" "$BACKUP_FILES/walletunlock.json"; do
        if [[ -f "$f" ]]; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

# LND only makes chan-backup-archives when it first archives a channel.backup, but the backup
# service watches it, and its installer stops if it's missing. Not through a symlink: the volume
# may hold one a container planted.
ensure_archive_dir() {
    if [[ "$(realpath -m -- "$LND_BACKUP_ARCHIVE")" != "$(realpath -m -s -- "$LND_BACKUP_ARCHIVE")" ]]; then
        log_message "$(T "⚠️ %s goes through a symlink, so it is left alone" "$LND_BACKUP_ARCHIVE")"
        return 0
    fi
    mkdir -p "$LND_BACKUP_ARCHIVE"
    chmod 700 "$LND_BACKUP_ARCHIVE"
}

# True for a regular file reached without any symlink on the way
plain_file() {
    [[ -f "$1" && ! -L "$1" ]] || return 1
    [[ "$(realpath -e -- "$1" 2>/dev/null)" == "$(realpath -m -s -- "$1")" ]]
}

# Channel backups to try, best first, in SCB_CANDIDATES (files in SECRET_DIR) with a description
# in SCB_LABELS. The live volume's channel.backup is newer than any backup when a channel opened or
# closed after the last backup.
SCB_CANDIDATES=()
SCB_LABELS=()
collect_channel_backups() {
    local live="$LIVE_MAINNET/channel.backup" from_backup=""
    SCB_CANDIDATES=()
    SCB_LABELS=()
    [[ -n "$BACKUP_FILES" && -f "$BACKUP_FILES/$SCB_REL" ]] && from_backup="$BACKUP_FILES/$SCB_REL"

    # Only a plain file: a container that can write the volume could make it a symlink to a host
    # file, which root would then copy into the volume
    if plain_file "$live"; then
        # -p: with its time, for the "newer" comparison below
        install -p -m 600 "$live" "$SECRET_DIR/scb.live"
    elif [[ -e "$live" || -L "$live" ]]; then
        log_message "$(T "⚠️ This server's channel.backup is not a plain file (a symlink?), so it is not used")"
    fi
    if [[ -f "$SECRET_DIR/scb.live" && -n "$from_backup" ]]; then
        if cmp -s "$SECRET_DIR/scb.live" "$from_backup"; then
            SCB_CANDIDATES=("$from_backup")
            SCB_LABELS=("$(T "channel.backup from the backup (the same as on this server)")")
        elif [[ "$SECRET_DIR/scb.live" -nt "$from_backup" ]]; then
            log_message "$(T "ℹ️ This server's channel.backup is newer than the backup's: a channel opened or closed after the last backup.")"
            SCB_CANDIDATES=("$SECRET_DIR/scb.live" "$from_backup")
            SCB_LABELS=("$(T "channel.backup from this server (newer than the backup)")" "$(T "channel.backup from the backup")")
        else
            SCB_CANDIDATES=("$from_backup" "$SECRET_DIR/scb.live")
            SCB_LABELS=("$(T "channel.backup from the backup (newer than this server's)")" "$(T "channel.backup from this server")")
        fi
    elif [[ -n "$from_backup" ]]; then
        SCB_CANDIDATES=("$from_backup")
        SCB_LABELS=("$(T "channel.backup from the backup")")
    elif [[ -f "$SECRET_DIR/scb.live" ]]; then
        SCB_CANDIDATES=("$SECRET_DIR/scb.live")
        SCB_LABELS=("$(T "channel.backup from this server")")
    fi
}

# Checks the channel backups against the wallet in a container. Of those that open with this
# wallet's keys (which also proves they belong to this seed), it takes the one listing the most
# channels (the newer one when both list as many): a live file older than the backup, after an
# undo for example, could miss channels opened later. Sets SCB_FILE, SCB_LABEL and SCB_COUNT.
# Usage: verify_channel_backups <lncli function>
SCB_FILE=""
SCB_LABEL=""
SCB_COUNT=0
# SCB_FILES: every one that opens with this wallet, newest first, and SCB_POINTS the channels in
# them together. All of them are restored: an older one may list a channel the newest doesn't
# (closed since, and harmless to restore), and the newest may list one the older doesn't (opened
# since), so none of them alone is enough.
SCB_FILES=()
SCB_POINTS=()
verify_channel_backups() {
    local lncli_fn="$1" i out count opened=0 point
    local -A points=()
    SCB_FILE=""
    SCB_COUNT=0
    SCB_FILES=()
    SCB_POINTS=()
    for i in "${!SCB_CANDIDATES[@]}"; do
        install -m 600 "${SCB_CANDIDATES[$i]}" "$LND_DIR/$SCB_STAGING_REL"
        if out=$("$lncli_fn" verifychanbackup --multi_file="/data/$SCB_STAGING_REL" 2>&1); then
            count=$(jq '.chan_points | length' <<< "$out" 2>/dev/null || echo 0)
            [[ "$count" =~ ^[0-9]+$ ]] || count=0
            log_message "$(T "✅ %s belongs to this wallet: %s channels" "${SCB_LABELS[$i]}" "$count")"
            opened=$((opened + 1))
            SCB_FILES+=("${SCB_CANDIDATES[$i]}")
            while IFS= read -r point; do
                [[ "$point" =~ ^[0-9a-f]{64}:[0-9]+$ ]] && points[$point]=1
            done < <(jq -r '.chan_points[]? // empty' <<< "$out" 2>/dev/null)
            if [[ -z "$SCB_FILE" ]] || (( count > SCB_COUNT )); then
                SCB_FILE="${SCB_CANDIDATES[$i]}"
                SCB_LABEL="${SCB_LABELS[$i]}"
                SCB_COUNT=$count
            fi
        else
            log_message "$(T "⚠️ %s doesn't open with this wallet: %s" "${SCB_LABELS[$i]}" "$(tail -n 1 <<< "$out")")"
        fi
    done
    rm -f "$LND_DIR/$SCB_STAGING_REL"
    [[ -n "$SCB_FILE" ]] || return 1
    SCB_POINTS=("${!points[@]}")
    if (( opened > 1 )); then
        log_message "$(T "➡️ All %s channel.backup files are restored: %s channels together" "$opened" "${#SCB_POINTS[@]}")"
    fi
}

# === STEP: SCAN FOR OLD FUNDS ===
# LND only continues an interrupted scan when unlocked with --recovery_window, which BTCPay never
# passes, so the scan has to finish here before BTCPay takes over.
wait_for_recovery_scan() {
    local info finished progress answer
    log_message "$(T "🔎 Scanning for old funds. This can take minutes to hours, depending on the seed's age.")"
    say "   Progress is shown every 30 seconds. Type skip and Enter to stop waiting."
    while true; do
        info=$(init_lncli getrecoveryinfo 2>/dev/null || echo '{}')
        finished=$(jq -r '.recovery_finished // false' <<< "$info")
        progress=$(jq -r '((.progress // 0) * 100 | floor | tostring) + "%"' <<< "$info")
        if [[ "$finished" == "true" ]]; then
            log_message "$(T "✅ Scan for old funds finished")"
            return 0
        fi
        [[ "$(docker inspect -f '{{.State.Running}}' "$LND_INIT" 2>/dev/null)" == "true" ]] ||
            die "$(T "The temporary LND stopped during the scan")"
        say "   Scan progress: %s" "$progress"
        if read -r -t 30 answer && [[ "$answer" == "skip" ]]; then
            say "Without the finished scan, old funds may not show up in the wallet."
            say "To scan again later, run this script again and choose the same restore."
            if confirm_phrase "SKIP THE SCAN" "$(T "Type 'SKIP THE SCAN' to hand over to BTCPay now: ")"; then
                log_message "$(T "⚠️ Scan for old funds skipped at %s" "$progress")"
                return 0
            fi
        fi
    done
}

# === STEP: HAND OVER TO BTCPAY ===
write_walletunlock() {
    mkdir -p "$LIVE_MAINNET"
    install -m 600 /dev/null "$LND_DIR/$UNLOCK_REL"
    UNLOCK_PW="$WALLET_PASSWORD" UNLOCK_SEED="$SEED_WORDS" \
        jq -n -c '{wallet_password: env.UNLOCK_PW, cipher_seed_mnemonic: (env.UNLOCK_SEED | split(" "))}' \
        > "$LND_DIR/$UNLOCK_REL"
    log_message "$(T "✅ walletunlock.json written (BTCPay unlocks the wallet with it)")"
}

# Starts BTCPay and checks its LND unlocked the wallet made here. Usage: start_btcpay <expected node ID>
start_btcpay() {
    local expected="$1" since node
    since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    enable_btcpay_service
    log_message "$(T "🚀 Starting BTCPay with btcpay-up.sh...")"
    btcpay_run btcpay-up.sh >/dev/null 2>&1 || die "$(T "btcpay-up.sh failed")"

    log_message "$(T "⏳ Waiting for BTCPay's LND to unlock the wallet (up to 10 minutes)...")"
    if ! wait_for_state "$LND_CONTAINER_NAME" 600 RPC_ACTIVE SERVER_ACTIVE; then
        docker logs --since "$since" "$LND_CONTAINER_NAME" 2>&1 | grep -E 'initunlocklnd|ERR' | tail -5 | show_lines
        die "$(T "BTCPay's LND did not unlock the wallet")"
    fi
    if grep -q "autogenerated" <<< "$(docker logs --since "$since" "$LND_CONTAINER_NAME" 2>&1)"; then
        die "$(T "BTCPay made a wallet of its own instead of using this one. Its seed is in %s/%s." "$LND_DIR" "$UNLOCK_REL")"
    fi
    node=$(btcpay_lncli getinfo 2>/dev/null | jq -r '.identity_pubkey') || node=""
    if [[ "$node" != "$expected" ]]; then
        die "$(T "BTCPay's LND has node ID '%s', not this wallet's %s. The backup service stays off." "${node:-unknown}" "$expected")"
    fi
    log_message "$(T "✅ BTCPay's LND unlocked the wallet (node ID %s)" "$node")"
}

# Reinstalls the backup service, which watches the new volume's folders again, and backs up at once
reinstall_backup_service() {
    log_message "$(T "🔧 Reinstalling the backup service for the new volume...")"
    if ! with_usual_umask "$INSTALLER" < /dev/null > "$BULK_DIR/installer.log" 2>&1; then
        tail -n 5 "$BULK_DIR/installer.log" | show_lines
        log_message "$(T "❌ The backup installer failed. Rerun %s by hand." "$INSTALLER")"
        return 1
    fi
    # The service handles "check now" once it is running; give it a moment to start its check loop
    sleep 15
    if systemctl kill -s SIGUSR1 --kill-whom=main "$RSYNC_BACKUP_SERVICE_NAME" 2>/dev/null; then
        log_message "$(T "✅ Backup service running, and asked to back up the new wallet now")"
    else
        log_message "$(T "⚠️ Backup service installed, but 'check now' failed. It backs up on its next hourly check.")"
    fi
}

# === STEP: CHANNEL RESTORE (BTCPay's LND) ===
# Asked before anything is stopped or deleted (options 3 and 4), or when option 2 turns into 3
CHANNELS_CONFIRMED=false
confirm_channels() {
    echo
    say "⚠️  Restoring channels asks every channel peer to close its channel. Your share comes back"
    say "   on-chain once the peer's close confirms. A peer that stays offline keeps that channel's"
    say "   funds stuck until it comes back. Payments in flight when LND failed can be lost."
    say "⚠️  Make sure no other LND with this seed is running anywhere (an old server, a copy)."
    say "   Two nodes with the same channels can lose all the funds in them."
    if confirm_phrase "NO OTHER NODE IS RUNNING" "$(T "Type 'NO OTHER NODE IS RUNNING' to restore the channels: ")"; then
        CHANNELS_CONFIRMED=true
        return 0
    fi
    return 1
}

restore_channels() {
    local answer out restored state
    if ! $CHANNELS_CONFIRMED && ! confirm_channels; then
        log_message "$(T "⚠️ Channels not restored. Run this script with option 4 to restore them later.")"
        return 0
    fi

    verify_channel_backups btcpay_lncli || {
        log_message "$(T "❌ No channel.backup opens with this wallet, so no channels can be restored.")"
        return 1
    }

    # LND only restores channels once it is fully started, which needs it synced to the chain
    state=$(lnd_state "$LND_CONTAINER_NAME")
    if [[ "$state" != "SERVER_ACTIVE" ]]; then
        log_message "$(T "⏳ Waiting for BTCPay's LND to finish starting (it syncs to the chain first)...")"
        say "   Type later and Enter to stop waiting; option 4 restores the channels another time."
        while [[ "$(lnd_state "$LND_CONTAINER_NAME")" != "SERVER_ACTIVE" ]]; do
            if read -r -t 30 answer && [[ "$answer" == "later" ]]; then
                log_message "$(T "⚠️ Channels not restored yet. Run this script with option 4 once LND has synced.")"
                return 0
            fi
            say "   LND state: %s" "$(lnd_state "$LND_CONTAINER_NAME")"
        done
    fi

    # Each one, newest first. A channel already restored from an earlier file is LND's to skip;
    # what matters is that every channel in any of them is restored.
    local f n_ok=0 total=0 n counted=false
    for f in "${SCB_FILES[@]}"; do
        install -m 600 "$f" "$LND_DIR/$SCB_STAGING_REL"
        if out=$(btcpay_lncli restorechanbackup --multi_file="/data/$SCB_STAGING_REL" 2>&1); then
            n_ok=$((n_ok + 1))
            # Older LNDs answer {} without the number
            n=$(jq -r '.num_restored // empty' <<< "$out" 2>/dev/null || true)
            [[ "$n" =~ ^[0-9]+$ ]] && { total=$((total + n)); counted=true; }
        else
            log_message "$(T "⚠️ Restoring from %s: %s" "$(basename "$f")" "$(tail -n 1 <<< "$out")")"
        fi
    done
    rm -f "$LND_DIR/$SCB_STAGING_REL"
    if (( n_ok == 0 )); then
        log_message "$(T "❌ Channel restore failed: %s" "$(tail -n 1 <<< "$out")")"
        return 1
    fi
    $counted && restored=$total || restored=${#SCB_POINTS[@]}
    log_message "$(T "✅ %s channels restored. LND now asks each peer to close its channel." "$restored")"
    btcpay_lncli pendingchannels 2>/dev/null |
        jq -r '"   Waiting to close: \(.waiting_close_channels | length), force closing: \(.pending_force_closing_channels | length)"' || true
    show_channel_check
}

# Channels opened after the newest channel.backup aren't restored: their peers keep them open.
# LND can't find them itself (it ignores the network's announcements of its own channels, so a
# restored node's graph never shows them), but a public explorer lists the node's public channels:
# one there that isn't restored here was opened after the newest backup.
show_channel_check() {
    local own point
    own=$(btcpay_lncli getinfo 2>/dev/null | jq -r '.identity_pubkey // empty') || own=""
    [[ "$own" =~ ^0[23][0-9a-f]{64}$ ]] || return 0
    echo
    say "ℹ️ Channels opened after the newest backup aren't restored, and LND can't see them. Look your"
    say "   node up on a public explorer, for example https://mempool.space/lightning/node/%s" "$own"
    say "   A public channel there that isn't in this list stays with its peer: ask the peer to force-close"
    say "   it (your share then comes back on-chain), or see chantools (lightninglabs) for help."
    say "   Restored channels:"
    for point in "${SCB_POINTS[@]}"; do
        echo "   - $point"
    done
}

# === MENU ===
# Skipped when the option was given on the command line (lnd-wallet.sh restore, ...)
if [[ -z "$CHOICE" ]]; then
    echo
    say "What do you want to do?"
    say "  1) New wallet"
    say "  2) Restore the wallet (on-chain funds) from its seed"
    say "  3) Restore the wallet and the channels (seed + channel.backup)"
    say "  4) Restore the channels into the running wallet (channel.backup only)"
    say "  5) Undo: put a safety backup back"
    while [[ ! "$CHOICE" =~ ^[1-5]$ ]]; do
        read -rp "$(T "Choose 1-5: ")" CHOICE
    done
fi

log_message "$(T "🚀 Starting LND wallet script, option %s..." "$CHOICE")"

# --- The LND image, from BTCPay's own container ---
# btcpay-down.sh removes the containers, so after a run that stopped partway the image is read
# from BTCPay's generated compose file instead.
LND_IMAGE=$(docker inspect --format='{{.Config.Image}}' "$LND_CONTAINER_NAME" 2>/dev/null || true)
if [[ -z "$LND_IMAGE" ]]; then
    LND_IMAGE=$(awk -v name="$LND_CONTAINER_NAME" '
        $1 == "image:" {image = $2}
        $1 == "container_name:" && $2 == name {print image; exit}' \
        "$DOCKER_ROOT/Generated/docker-compose.generated.yml" 2>/dev/null || true)
fi
[[ -n "$LND_IMAGE" ]] || die "$(T "Could not find BTCPay's LND image (container '%s' or its compose file). Is BTCPay installed with LND?" "$LND_CONTAINER_NAME")"
log_message "$(T "📦 Using LND image: %s" "$LND_IMAGE")"

SWITCHED_TO_CHANNELS=false
WALLET_PASSWORD=""
SEED_WORDS=""
SEED_PASSPHRASE=""
RECOVERY_WINDOW=0
USE_BACKUP_PASSWORD=false

# === OPTION 5: UNDO ===
if [[ "$CHOICE" == "5" ]]; then
    log_message "$(T "🔎 Looking for safety backups...")"
    # Each safety backup is usually in both places: list it once, the attached volume's copy first.
    # GitHub fetched here first: list_backups runs in a subshell, which couldn't keep it.
    github_fetch_once >/dev/null 2>&1 || true
    mapfile -t SAFETY_ALL < <(list_backups pre-recovery)
    SAFETY_LIST=()
    declare -A SAFETY_ALSO=()
    for line in "${SAFETY_ALL[@]}"; do
        read -r _ epoch where path <<< "$line"
        name=$(basename "$path")
        if [[ -n "${SAFETY_ALSO[$name]+set}" ]]; then
            SAFETY_ALSO[$name]+=$(T " (also %s)" "$(where_on "$where")")
            continue
        fi
        SAFETY_ALSO[$name]=""
        SAFETY_LIST+=("$line")
    done
    (( ${#SAFETY_LIST[@]} > 0 )) || die "$(T "No safety backups found in %s, on Server B or on GitHub." "$PRE_RECOVERY_LOCAL")"
    say "Safety backups, newest first:"
    for i in "${!SAFETY_LIST[@]}"; do
        read -r _ epoch where path <<< "${SAFETY_LIST[$i]}"
        name=$(basename "$path")
        say "  %s) %s %s%s (%s)" "$((i + 1))" "$name" "$(where_on "$where")" "${SAFETY_ALSO[$name]}" "$(age_text "$epoch")"
    done
    while true; do
        read -rp "$(T "Which one (Enter for 1): ")" pick
        pick=${pick:-1}
        [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#SAFETY_LIST[@]} )) && break
    done
    read -r _ epoch where path <<< "${SAFETY_LIST[$((pick - 1))]}"

    # Checked before anything is asked: its signed manifest must match its name, so an older
    # backup renamed to look newer (or a regular backup renamed as a safety backup) is refused
    fetch_backup "$where" "$path" "$BULK_DIR/undo.gpg" || die "$(T "Could not copy %s" "$(basename "$path")")"
    decrypt_bundle "$BULK_DIR/undo.gpg" "$BULK_DIR/undo" || die "$(T "%s failed its check: %s" "$(basename "$path")" "$DECRYPT_ERROR")"
    check_manifest "$BULK_DIR/undo" pre-recovery "$(basename "$path")" ||
        die "$(T "%s is refused: %s" "$(basename "$path")" "$DECRYPT_ERROR")"
    rm -f "$BULK_DIR/undo.gpg"
    log_message "$(T "✅ %s decrypted and checked" "$(basename "$path")")"
    warn_key_expired

    SAFE_NODE="$MANIFEST_NODE" SAFE_TIME="$MANIFEST_TIME" SAFE_STATE="$MANIFEST_STATE" SAFE_CHANNELS="$MANIFEST_CHANNELS"
    SAFE_EPOCH=$(date -d "$SAFE_TIME" +%s 2>/dev/null || echo "$epoch")

    read_current_wallet
    # === Has this node run since? Then its channel state is newer than the safety backup's ===
    # Putting older channel state back and starting LND can broadcast it: the peers may then take
    # all the funds in those channels as a penalty. The evidence: the same node is running now (with
    # channels, or with regular backups newer than the safety backup), or a newer safety backup holds
    # the same node. Only a typed override gets past it.
    UNDO_RISK=()
    if $OLD_READ && [[ -n "$SAFE_NODE" && "$OLD_NODE_ID" == "$SAFE_NODE" ]] && (( OLD_CHANNELS > 0 || OLD_PENDING > 0 )); then
        UNDO_RISK+=("$(T "The wallet running now is the same node and has %s open and %s opening or closing channels: their state now is newer than the safety backup's." "$OLD_CHANNELS" "$OLD_PENDING")")
    fi
    # Whether the node ran since only matters if the safety backup holds channels: its manifest
    # says how many (safety backups made before that, or without LND running, don't)
    NEWER=()
    if [[ "$SAFE_CHANNELS" == 0 ]]; then
        say "ℹ️ The safety backup holds no channels, so no old channel state can be broadcast from it."
    else
        # A place that didn't answer may hold the newer backup that would show it ran
        unsearched=$(unsearched_places)
        if [[ -n "$unsearched" ]]; then
            UNDO_RISK+=("$(T "Not searched: %s, so a newer backup there, which would show the node ran since, can't be seen." "$unsearched")")
        fi
        # Regular backups don't say which node made them (the backup service can't ask LND), so
        # they count only together with what the running LND says
        mapfile -t NEWER < <(list_backups main | awk -v t="$SAFE_EPOCH" '$1 == 0 && $2 > t + 60')
    fi
    if (( ${#NEWER[@]} > 0 )); then
        read -r _ newer_epoch _ newer_path <<< "${NEWER[0]}"
        if $OLD_READ && [[ -n "$SAFE_NODE" && "$OLD_NODE_ID" == "$SAFE_NODE" ]]; then
            UNDO_RISK+=("$(T "This node ran after the safety backup was made: the newest regular backup, %s, is %s." "$(basename "$newer_path")" "$(age_text "$newer_epoch")")")
        elif ! $OLD_READ; then
            UNDO_RISK+=("$(T "A regular backup newer than the safety backup exists (%s), and LND isn't running to tell which wallet it holds." "$(basename "$newer_path")")")
        fi
    fi
    # Safety backups do say which node they hold: a newer one of the same node means it ran since.
    # The 3 newest are checked (each is decrypted).
    checked=0
    [[ "$SAFE_CHANNELS" == 0 ]] && checked=3
    for line in "${SAFETY_LIST[@]}"; do
        [[ -n "$SAFE_NODE" ]] && (( checked < 3 )) || break
        read -r _ newer_epoch newer_where newer_path <<< "$line"
        (( newer_epoch > SAFE_EPOCH + 60 )) || continue
        checked=$((checked + 1))
        # Only its signed manifest is read (no decrypted copy of a whole LND volume kept)
        newer_dir="$BULK_DIR/undo-newer"
        if read_signed_manifest "$newer_where" "$newer_path" "$newer_dir" &&
           check_manifest "$newer_dir" pre-recovery "$(basename "$newer_path")" &&
           [[ "$MANIFEST_STATE" == verified && "$MANIFEST_NODE" == "$SAFE_NODE" ]]; then
            UNDO_RISK+=("$(T "A newer safety backup of this node exists (%s): the node ran after the one you picked." "$(basename "$newer_path")")")
            checked=3
        fi
        remove_work_path "$newer_dir" || true
        MANIFEST_NODE="$SAFE_NODE" MANIFEST_TIME="$SAFE_TIME" MANIFEST_STATE="$SAFE_STATE" MANIFEST_CHANNELS="$SAFE_CHANNELS"
    done
    echo
    if [[ "$MANIFEST_STATE" == verified ]]; then
        say "The safety backup: made %s (signed), wallet %s" "$MANIFEST_TIME" "${MANIFEST_NODE:-unknown}"
    else
        say "⚠️  This safety backup was made before they carried a signed date: its date and wallet can't"
        say "   be verified. Only use it if you know it is the one you want."
    fi
    say "The wallet running now:"
    printf '  %s\n' "${OLD_SUMMARY[@]}"
    echo
    say "⚠️  This puts back the whole LND volume as it was, channel state included. That is only safe if"
    say "   no LND has run with those channels since the safety backup was made. If channels were restored"
    say "   from channel.backup in between, their peers have closed them: don't put the old state back."
    if (( ${#UNDO_RISK[@]} > 0 )); then
        echo
        say "🛑 This node may have run since this safety backup was made:"
        for r in "${UNDO_RISK[@]}"; do
            echo "   - $r"
        done
        say "   Putting older channel state back and starting LND can broadcast it, and then the peers can take"
        say "   all the funds in those channels. Don't, unless you know those channels are closed and settled."
        say "   To get channel funds back, restore the channels instead (options 3 and 4): that is safe with any backup."
        confirm_phrase "I KNOW THIS CAN LOSE THE CHANNEL FUNDS" "$(T "Type 'I KNOW THIS CAN LOSE THE CHANNEL FUNDS' to go on anyway: ")" ||
            die "$(T "Stopped: nothing was changed.")"
        log_message "$(T "⚠️ Undo with newer channel state on this node (confirmed by user)")"
    fi
    confirm_phrase "PUT IT BACK" "$(T "Type 'PUT IT BACK' to replace the current wallet with this safety backup: ")" ||
        die "$(T "Aborted by user.")"

    remember_volume_labels
    stop_everything
    make_safety_backup
    recreate_volume
    # Unpacked and checked first, as a restore does: plain files and folders only, no setuid,
    # setgid or sticky bits. The backup user holds the signing key and owns the pre-recovery
    # folder, so the signature alone doesn't prove root may put this into the LND volume as it is.
    mkdir -p "$BULK_DIR/undo/files"
    tar -xzf "$BULK_DIR/undo/backup_compressed.tar.gz" -C "$BULK_DIR/undo/files" --no-same-owner ||
        die "$(T "Could not unpack the safety backup")"
    odd=$(find "$BULK_DIR/undo/files" \( ! -type f ! -type d -o -perm /7000 \) -print -quit)
    [[ -z "$odd" ]] ||
        die "$(T "The safety backup holds links, special files or setuid/setgid files (%s), which a safety backup never has: not used" "${odd#"$BULK_DIR/undo/files"}")"
    cp -a --no-preserve=ownership -- "$BULK_DIR/undo/files/." "$LND_DIR/" ||
        die "$(T "Could not unpack the safety backup into %s" "$LND_DIR")"
    remove_work_path "$BULK_DIR/undo"
    log_message "$(T "✅ Safety backup put back into %s" "$LND_DIR")"
    STAGE="handed"

    enable_btcpay_service
    btcpay_run btcpay-up.sh >/dev/null 2>&1 || die "$(T "btcpay-up.sh failed")"
    if wait_for_state "$LND_CONTAINER_NAME" 600 RPC_ACTIVE SERVER_ACTIVE; then
        log_message "$(T "✅ BTCPay's LND is up (node ID %s)" "$(btcpay_lncli getinfo 2>/dev/null | jq -r '.identity_pubkey')")"
    else
        die "$(T "BTCPay's LND did not unlock the restored wallet")"
    fi
    ensure_archive_dir
    STAGE="done"
    if ! reinstall_backup_service; then
        log_message "$(T "⚠️ Safety backup put back, but the backup service is NOT running. Rerun %s." "$INSTALLER")"
        exit 1
    fi
    log_message "$(T "🚀 Safety backup put back.")"
    exit 0
fi

# === OPTION 4: CHANNELS INTO THE RUNNING WALLET ===
if [[ "$CHOICE" == "4" ]]; then
    if find_latest_backup; then
        log_message "$(T "✅ Using %s" "$BACKUP_LABEL")"
        warn_if_older
    else
        log_message "$(T "⚠️ No backup could be used")"
        explain_no_seckey
    fi
    collect_channel_backups
    (( ${#SCB_CANDIDATES[@]} > 0 )) || die "$(T "No channel.backup found, neither in a backup nor on this server.")"
    [[ "$(lnd_state "$LND_CONTAINER_NAME")" =~ ^(RPC_ACTIVE|SERVER_ACTIVE)$ ]] ||
        die "$(T "BTCPay's LND isn't running with an unlocked wallet. Start BTCPay first.")"
    confirm_channels || die "$(T "Aborted by user: nothing was changed.")"

    # The channel restore changes LND's channel data, so it is saved first like for the other options
    remember_volume_labels
    stop_everything
    make_safety_backup
    enable_btcpay_service
    btcpay_run btcpay-up.sh >/dev/null 2>&1 || die "$(T "btcpay-up.sh failed")"
    STAGE="handed"
    wait_for_state "$LND_CONTAINER_NAME" 600 RPC_ACTIVE SERVER_ACTIVE || die "$(T "BTCPay's LND did not come back up")"
    restore_channels || true
    if $BACKUP_SERVICE_WAS_ACTIVE; then
        systemctl start "$RSYNC_BACKUP_SERVICE_NAME" || log_message "$(T "⚠️ Could not start %s" "$RSYNC_BACKUP_SERVICE_NAME")"
    fi
    STAGE="done"
    exit 0
fi

# === OPTIONS 1-3: QUESTIONS (nothing is changed until the confirmation) ===
if [[ "$CHOICE" == "2" || "$CHOICE" == "3" ]]; then
    if find_latest_backup; then
        log_message "$(T "✅ Latest usable backup: %s" "$BACKUP_LABEL")"
        warn_if_older
        if ! ask_yes "$(T "Use this backup? Type yes: ")"; then
            BACKUP_FILES=""
            log_message "$(T "ℹ️ Not using a backup")"
        fi
    else
        log_message "$(T "⚠️ No backup could be used")"
        explain_no_seckey
    fi

    if unlock_file=$(backup_unlock_file 2>/dev/null) &&
       [[ "$(jq -r '.cipher_seed_mnemonic | length' "$unlock_file" 2>/dev/null)" == "24" ]]; then
        say "The backup holds the wallet's seed and password (walletunlock.json)."
        if ask_yes "$(T "Use the seed from this backup? Type yes (anything else to type the seed yourself): ")"; then
            SEED_WORDS=$(jq -r '.cipher_seed_mnemonic | join(" ")' "$unlock_file")
            WALLET_PASSWORD=$(jq -r '.wallet_password // ""' "$unlock_file")
            # BTCPay treats an empty password as its old default and changes it on the next start
            if [[ -z "$WALLET_PASSWORD" || "$WALLET_PASSWORD" == "null" || ${#WALLET_PASSWORD} -lt 8 ]]; then
                WALLET_PASSWORD=""
            else
                USE_BACKUP_PASSWORD=true
            fi
            read -rsp "$(T "Seed passphrase, only if you set one when the seed was made (Enter for none): ")" SEED_PASSPHRASE; echo
            read -rp "$(T "Addresses to look ahead when scanning for old funds (Enter for %s): " "$RECOVERY_WINDOW_DEFAULT")" RECOVERY_WINDOW
            [[ "$RECOVERY_WINDOW" =~ ^[0-9]+$ ]] && (( RECOVERY_WINDOW > 0 )) || RECOVERY_WINDOW=$RECOVERY_WINDOW_DEFAULT
        fi
    elif [[ -n "$BACKUP_FILES" ]]; then
        say "This backup has no seed (walletunlock.json without one), so type the seed yourself."
    fi
    if [[ -z "$SEED_WORDS" ]]; then
        ask_seed
    fi
    if [[ -z "$WALLET_PASSWORD" ]]; then
        say "Choose the wallet password."
        ask_password
    fi
    if ! $USE_BACKUP_PASSWORD; then
        # The backup's macaroons only open with its own password
        BACKUP_FILES_FOR_CREDENTIALS=""
    else
        BACKUP_FILES_FOR_CREDENTIALS="$BACKUP_FILES"
    fi
else
    ask_password
    BACKUP_FILES_FOR_CREDENTIALS=""
fi

collect_channel_backups
if [[ "$CHOICE" == "3" ]] && (( ${#SCB_CANDIDATES[@]} == 0 )); then
    die "$(T "Option 3 needs a channel.backup, and there is none in a backup or on this server.")"
fi

# --- What the current wallet holds ---
read_current_wallet
echo
say "The current wallet:"
printf '  %s\n' "${OLD_SUMMARY[@]}"

if $OLD_READ && (( OLD_PENDING > 0 )) || [[ "$OLD_LIMBO" != "0" ]]; then
    echo
    say "⚠️  Channels are still opening or closing. Funds from a force close are timelocked, and only"
    say "   this LND's current data (channel.db) can sweep them. channel.backup doesn't cover channels"
    say "   that are already closing. Wait until they have finished, then run this script again."
    confirm_phrase "I ACCEPT THE RISK" "$(T "Type 'I ACCEPT THE RISK' to continue anyway: ")" || die "$(T "Aborted: channels are still opening or closing.")"
    log_message "$(T "⚠️ Continuing with channels still opening or closing (confirmed by user)")"
fi

if [[ "$CHOICE" == "1" ]] && $OLD_HAS_FUNDS; then
    echo
    say "⚠️  The current wallet still holds funds or channels. After this, they are only reachable"
    say "   through its old seed (in its walletunlock.json and in the safety backup). Better: close the"
    say "   channels cooperatively and send the funds out first."
fi

if [[ "$CHOICE" == "2" ]] && (( OLD_CHANNELS > 0 )); then
    echo
    say "⚠️  The current wallet has %s open channels. The seed alone doesn't bring back money in" "$OLD_CHANNELS"
    say "   channels: it stays stuck until the channels are restored from channel.backup."
    if (( ${#SCB_CANDIDATES[@]} > 0 )) && ask_yes "$(T "Restore the channels too (option 3)? Type yes: ")"; then
        CHOICE=3
        SWITCHED_TO_CHANNELS=true
    fi
fi

if ! $OLD_READ && [[ -f "$LIVE_MAINNET/wallet.db" ]]; then
    echo
    say "⚠️  The current wallet couldn't be read, so it's unknown what it holds. The safety backup keeps"
    say "   everything in it."
fi

if [[ "$CHOICE" == "3" ]] && $OLD_READ; then
    echo
    say "⚠️  LND is running and its data looks intact. Option 3 closes all your channels. If LND's data"
    say "   is fine, recovery is probably not what you need."
fi

if [[ "$CHOICE" == "3" ]] && ! confirm_channels; then
    if $SWITCHED_TO_CHANNELS; then
        log_message "$(T "ℹ️ Channels not confirmed: going on as a plain restore (option 2), without channels")"
        CHOICE=2
    else
        die "$(T "Aborted by user: nothing was changed. /wallet restore restores the wallet without channels.")"
    fi
fi

echo
log_message "$(T "⚠️  WARNING: This will DELETE the current LND wallet in volume '%s' (a safety backup is made first)." "${LND_VOLUME}")"
if ! confirm_phrase "YES I WANT TO DELETE" "$(T "⚠️  Type 'YES I WANT TO DELETE' to confirm: ")"; then
    log_message "$(T "❌ Aborted by user. You did not type the exact confirmation phrase.")"
    exit 1
fi

# === OPTIONS 1-3: THE CHANGES ===
remember_volume_labels
stop_everything
make_safety_backup
recreate_volume

NEW_NODE_ID=""
while true; do
    if [[ -n "$BACKUP_FILES_FOR_CREDENTIALS" ]]; then
        place_credentials "$BACKUP_FILES_FOR_CREDENTIALS"
        log_message "$(T "ℹ️ TLS certificate and macaroons put back from the backup, so paired apps keep working")"
    fi
    start_lnd_init

    if [[ "$CHOICE" == "1" ]]; then
        seed_json=$(init_rest https://localhost:8080/v1/genseed) || die "$(T "LND could not make a seed")"
        SEED_WORDS=$(jq -r '.cipher_seed_mnemonic | join(" ")' <<< "$seed_json")
        set -f
        # shellcheck disable=SC2206
        words=($SEED_WORDS)
        set +f
        (( ${#words[@]} == 24 )) || die "$(T "LND did not return a 24-word seed")"
        echo
        say "!!! WRITE DOWN THIS SEED. It is the only way to restore the wallet. !!!"
        say "---------------BEGIN LND CIPHER SEED---------------"
        for i in "${!words[@]}"; do
            printf '%2d. %-12s' "$((i + 1))" "${words[$i]}"
            (( (i + 1) % 4 == 0 )) && echo
        done
        say "---------------END LND CIPHER SEED-----------------"
        until confirm_phrase "I WROTE IT DOWN" "$(T "Type 'I WROTE IT DOWN' once you have: ")"; do :; done
        # The seed shouldn't stay readable on screen or in the scrollback (clear fails on an unknown TERM)
        clear 2>/dev/null || true
        if [[ -n "$IN_OUR_TMUX" ]]; then
            tmux -S "$TMUX_SOCKET" clear-history -t "${TMUX_PANE:-}" 2>/dev/null || true
            say "ℹ️ The seed was cleared from the screen and this tmux session's scrollback."
        else
            say "⚠️ Clear your terminal's scrollback too: the seed is still in it."
        fi
    fi

    result=0
    init_wallet || result=$?
    if (( result == 3 )); then
        log_message "$(T "⚠️ The backup's macaroons don't open with this password. Making new ones (apps need pairing again).")"
        BACKUP_FILES_FOR_CREDENTIALS=""
        empty_new_volume
        continue
    fi

    retry_reason=""
    if (( result == 2 )); then
        retry_reason=$(T "LND refused the seed")
    else
        NEW_NODE_ID=$(init_lncli getinfo | jq -r '.identity_pubkey')
        log_message "$(T "ℹ️ New wallet's node ID: %s" "$NEW_NODE_ID")"
        if [[ "$CHOICE" != "1" && -n "$OLD_NODE_ID" && "$NEW_NODE_ID" != "$OLD_NODE_ID" ]]; then
            retry_reason=$(T "this seed gives node ID %s, but the wallet that was running had %s" "$NEW_NODE_ID" "$OLD_NODE_ID")
        elif [[ "$CHOICE" != "1" ]] && (( ${#SCB_CANDIDATES[@]} > 0 )); then
            if verify_channel_backups init_lncli; then
                if [[ "$CHOICE" == "2" ]] && (( SCB_COUNT > 0 )); then
                    say "⚠️  %s lists %s channels. Option 2 leaves their funds stuck until the" "$SCB_LABEL" "$SCB_COUNT"
                    say "   channels are restored."
                    if ask_yes "$(T "Restore the channels too (option 3)? Type yes: ")"; then
                        CHOICE=3
                    fi
                fi
            else
                retry_reason=$(T "no channel.backup opens with this seed (a different wallet's backup, or a damaged file)")
            fi
        fi
    fi

    if [[ -z "$retry_reason" ]]; then
        break
    fi
    log_message "⚠️ $retry_reason"
    [[ "$CHOICE" == "1" ]] && die "$(T "LND refused the new wallet. BTCPay is down; run the script again.")"
    if (( result == 2 )); then
        say "Check the seed and type it again."
        empty_new_volume
        ask_seed
        continue
    fi
    while true; do
        read -rp "$(T "Choose: 1) type the seed again  2) continue anyway  3) stop: ")" answer
        case "$answer" in
            1)
                empty_new_volume
                ask_seed
                continue 2
                ;;
            2)
                if [[ "$CHOICE" == "3" ]] && [[ -z "$SCB_FILE" ]]; then
                    log_message "$(T "⚠️ Continuing without channels: no channel.backup opens with this wallet")"
                    CHOICE=2
                fi
                log_message "$(T "⚠️ Continuing anyway (confirmed by user)")"
                break 2
                ;;
            3)
                die "$(T "Stopped by user. BTCPay is down; run the script again, or option 5 to undo.")"
                ;;
        esac
    done
done

if [[ "$CHOICE" != "1" ]]; then
    wait_for_recovery_scan
fi

log_message "$(T "🛑 Stopping and removing the temporary LND container '%s'..." "$LND_INIT")"
docker stop "$LND_INIT" >/dev/null
docker rm "$LND_INIT" >/dev/null
# BTCPay's LND uses bitcoind, so lnd-init's neutrino data is of no use to it
rm -f "$LIVE_MAINNET"/neutrino.db "$LIVE_MAINNET"/block_headers.bin \
    "$LIVE_MAINNET"/reg_filter_headers.bin "$LIVE_MAINNET"/peers.json
ensure_archive_dir
write_walletunlock
STAGE="handed"

start_btcpay "$NEW_NODE_ID"

if [[ "$CHOICE" == "3" ]]; then
    restore_channels || log_message "$(T "⚠️ Channels not restored. Run this script with option 4 to try again.")"
fi

BACKUPS_OK=true
reinstall_backup_service || BACKUPS_OK=false
STAGE="done"

log_message "$(T "✅ New wallet in volume %s, node ID %s" "${LND_VOLUME}" "$NEW_NODE_ID")"
if [[ -n "$SAFETY_BACKUP_NAME" ]]; then
    log_message "$(T "ℹ️ The previous wallet is kept in the safety backup %s (pre-recovery folders)." "$SAFETY_BACKUP_NAME")"
fi
if ! $BACKUPS_OK; then
    log_message "$(T "⚠️ The wallet is done, but the backup service is NOT running. Rerun %s." "$INSTALLER")"
    exit 1
fi
log_message "$(T "🚀 Wallet script completed successfully.")"
