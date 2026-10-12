#!/bin/bash
# destinations.sh: where the backups go. Run it from your working folder, as yourself (lnd-manager:
# /destinations, /destination volume|serverb|github):
#
#   ./destinations.sh                          each destination, on or off, and its last copy
#   ./destinations.sh volume|serverb|github    turns that one on or off
#
# Turning one on runs setup, which sets up what it needs (the disk, Server B's key and gate, the
# GitHub deploy key) and asks first, then reinstalls the backup service. Turning one off asks you
# to type TURN OFF, then reinstalls the service without it; the copies already there stay there.
# At least one stays on.

if ! SCRIPT_DIR=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")"); then
    echo "❌ Could not determine this script's folder"
    exit 1
fi
CONFIG_FILE="$SCRIPT_DIR/config"
[[ -f "$CONFIG_FILE" ]] || { echo "❌ No config next to this script ($CONFIG_FILE)"; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG_FILE" || { echo "❌ Failed to load $CONFIG_FILE"; exit 1; }
if [[ ! -w "$CONFIG_FILE" ]]; then
    echo "❌ $CONFIG_FILE can't be edited by you. Run destinations.sh from your working folder" >&2
    echo "   (${BACKUP_SCRIPTS_FOLDER:-~/btcpay-docker-lnd-manager}), not from the installed copy." >&2
    exit 1
fi
log_message() {
    echo "$1"
}
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config-lib.sh" || { echo "❌ Failed to load $SCRIPT_DIR/config-lib.sh"; exit 1; }
# shellcheck disable=SC1091
source "$SCRIPT_DIR/i18n.sh" || { echo "❌ Failed to load $SCRIPT_DIR/i18n.sh"; exit 1; }
i18n_load
upgrade_config >/dev/null || exit 1

setting_of() {
    case "$1" in
        volume) echo BACKUP_TO_VOLUME ;;
        serverb) echo BACKUP_TO_SERVER_B ;;
        github) echo BACKUP_TO_GITHUB ;;
    esac
}
name_of() {
    case "$1" in
        volume) T "the attached volume (%s)" "${SECOND_BACKUP_DIR:-?}" ;;
        serverb) T "Server B (%s)" "${REMOTE_SERVER:-?}" ;;
        github) T "GitHub (%s)" "${GITHUB_REPO:-?}" ;;
    esac
}
state_of() {
    local setting value
    setting=$(setting_of "$1")
    value="${!setting:-}"
    [[ -z "$value" ]] && { [[ "$1" == github ]] && value=no || value=yes; }
    echo "$value"
}
# The time of the last copy there, from the backup service's status file
last_copy() {
    local key t
    case "$1" in
        volume) key=local_last_ok ;;
        serverb) key=remote_last_ok ;;
        github) key=github_last_ok ;;
    esac
    t=$(sed -n "s/^$key=//p" "${STATUS_FILE:-/var/lib/rsync_gpg_backup/status}" 2>/dev/null | head -n 1)
    if [[ "$t" =~ ^[0-9]+$ ]]; then
        date -d "@$t" '+%Y-%m-%d %H:%M'
    else
        T "never"
    fi
}

show() {
    local d state
    say "Where the backups go:"
    for d in volume serverb github; do
        state=$(state_of "$d")
        if [[ "$state" == yes ]]; then
            say "  ✅ on   %s, last copy: %s" "$(name_of "$d")" "$(last_copy "$d")"
        else
            say "  ➖ off  %s" "$(name_of "$d")"
        fi
    done
    if [[ "$(state_of serverb)" != yes && "$(state_of github)" != yes ]]; then
        say "⚠️  No copy leaves this server: if it is lost, the backups are lost with it."
    fi
}

case "${1:-}" in
    "") show; exit 0 ;;
    volume | serverb | github) WHICH="$1" ;;
    -h | --help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) say "❌ Unknown destination: %s (volume, serverb or github)" "$1" >&2; exit 2 ;;
esac
if [[ ! -t 0 ]]; then
    say "❌ destinations.sh needs a terminal: it asks before it changes anything." >&2
    exit 1
fi

show
echo
SETTING=$(setting_of "$WHICH")
if [[ "$(state_of "$WHICH")" == yes ]]; then
    # === Off ===
    others=0
    for d in volume serverb github; do
        [[ "$d" != "$WHICH" && "$(state_of "$d")" == yes ]] && others=$((others + 1))
    done
    if (( others == 0 )); then
        say "❌ %s is the only destination that is on: turn another one on first." "$(name_of "$WHICH")"
        exit 1
    fi
    say "Turning off %s: new backups no longer go there. The copies already there stay there," "$(name_of "$WHICH")"
    say "and restoring still looks there. The backup service is reinstalled (a few seconds without it)."
    if [[ "$WHICH" != volume && ( "$WHICH" == serverb && "$(state_of github)" != yes || "$WHICH" == github && "$(state_of serverb)" != yes ) ]]; then
        say "⚠️  After this, no copy leaves this server."
    fi
    read -r -p "$(T "Type TURN OFF to turn it off: ")" answer || exit 1
    [[ "$answer" == "TURN OFF" ]] || { say "Cancelled: nothing was changed."; exit 1; }
    save_config_value "$SETTING" no || exit 1
    sudo "$SCRIPT_DIR/install-scripts.sh" >/dev/null || { say "❌ install-scripts.sh failed"; exit 1; }
    # Without a terminal the installer keeps the safe folders and the backups as they are
    if sudo "${BACKUP_INSTALL_DIR:-/usr/local/lib/btcpay-docker-lnd-manager}/rsync_gpg_backup.sh" < /dev/null > /dev/null; then
        say "✅ %s is off. The backup service runs without it." "$(name_of "$WHICH")"
    else
        say "❌ The backup service installer failed: lnd-manager /install shows why."
        exit 1
    fi
else
    # === On ===
    say "Turning on %s. Setup sets up what it needs, asking before each step, then the backup" "$(name_of "$WHICH")"
    say "service is reinstalled with it (setup's last question: answer y)."
    read -r -p "$(T "Type yes to go on: ")" answer || exit 1
    [[ "$answer" == yes ]] || { say "Cancelled: nothing was changed."; exit 1; }
    save_config_value "$SETTING" yes || exit 1
    exec "$SCRIPT_DIR/setup_script.sh"
fi
