#!/bin/bash
# lnd-update.sh: updates these scripts on Server A to the newest signed release. Installed root-owned
# by install-scripts.sh, with the command lnd-update (lnd-manager: /update).
#
#   lnd-update check        installed and newest release, and an update waiting to be applied
#                           (one line each; no root needed, nothing changes)
#   sudo lnd-update         gets the newest release, checks its signature against the release key
#                           installed with the scripts, and asks you to type UPDATE. Then, when it
#                           is safe (no backup, no wallet operation, no /chain or /tower operation
#                           running), installs it and reinstalls the backup service. LND and BTCPay
#                           keep running: BTCPay updates them itself (btcpay-update.sh).
#                           Not safe right away: it waits in the background (lnd-update-wait), up
#                           to 24 hours, then the update is applied at the next boot, before the
#                           backup service starts.
#   lnd-update boot         (lnd-update-boot.service) applies a waiting update at boot
#   lnd-update apply-wait   (lnd-update-wait) waits until it is safe, then applies
#
# Your working folder (BACKUP_SCRIPTS_FOLDER) is moved to the same release too, your config kept,
# so a later sudo ./install-scripts.sh there doesn't install the old version again.

set -euo pipefail
umask 022
if ! SCRIPT_DIR=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")"); then
    echo "❌ Could not determine this script's folder" >&2
    exit 1
fi
CONFIG_FILE="$SCRIPT_DIR/config"
[[ -f "$CONFIG_FILE" ]] || { echo "❌ Configuration file not found at $CONFIG_FILE" >&2; exit 1; }
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
# Root runs only the installed copy, as the other root-run scripts
if (( EUID == 0 )) && ! root_owned_chain "$SCRIPT_DIR/lnd-update.sh" "$CONFIG_FILE" "$SCRIPT_DIR/i18n.sh" \
                                         "$SCRIPT_DIR/update-lib.sh" "$SCRIPT_DIR/release-key.asc"; then
    echo "❌ $SCRIPT_DIR/lnd-update.sh or its files can be changed by users other than root, so root won't run it." >&2
    echo "   Run the installed copy: sudo lnd-update" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE" || { echo "❌ Failed to load $CONFIG_FILE" >&2; exit 1; }
# shellcheck disable=SC1091
source "$SCRIPT_DIR/i18n.sh" || { echo "❌ Failed to load $SCRIPT_DIR/i18n.sh" >&2; exit 1; }
i18n_load

LOG_FILE=/var/log/lnd-update.log
log_message() {
    local message="${1//[[:cntrl:]]/?}"
    echo "$message"
    if (( EUID == 0 )); then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$LOG_FILE" 2>/dev/null || true
    fi
}
die() {
    log_message "❌ $*"
    exit 1
}
# shellcheck disable=SC1091
source "$SCRIPT_DIR/update-lib.sh" || die "Failed to load $SCRIPT_DIR/update-lib.sh"

DEST="$SCRIPT_DIR"
VERSION_FILE="$DEST/VERSION"
STATE=/var/lib/lnd-update
# Readable by everyone (the dashboard shows it): "<tag> waiting|boot <since>"
PENDING_FILE=/var/lib/lnd-update.pending

installed_version() {
    [[ -f "$VERSION_FILE" ]] && head -n 1 "$VERSION_FILE" || echo "-"
}

# === Is it safe? Prints why not; nothing when it is ===
lock_busy() {
    [[ -e "$1" ]] || return 1
    ! flock -n "$1" true 2>/dev/null
}
backup_busy_reason() {
    local job
    job=$(sed -n 's/^job=//p' "${STATUS_FILE:-/var/lib/rsync_gpg_backup/status}" 2>/dev/null | head -n 1 || true)
    if [[ -n "$job" && "$job" != idle ]]; then
        T "the backup service is busy (%s)" "$job"
    fi
}
safe_check() {
    local reason
    reason=$(backup_busy_reason)
    if [[ -n "$reason" ]]; then
        echo "$reason"
    elif lock_busy /run/lnd-wallet.lock; then
        T "a wallet operation (lnd-wallet) is running"
    elif lock_busy /run/lnd-chain.lock; then
        T "/chain prune, /chain copy or /tower add is running"
    fi
}

# === Applying a staged release ===
# The working folder follows the release: your config stays as it is (its contents, owner and
# mode). Skipped, with what to do, if the folder has other changes of yours.
update_working_folder() {
    local tag="$1" folder="${BACKUP_SCRIPTS_FOLDER:-}" user="${MAIN_USER:-}" changes
    [[ -n "$folder" && -n "$user" && -d "$folder/.git" ]] || return 0
    as_main() { runuser -u "$user" -- "$@"; }
    changes=$(as_main git -C "$folder" status --porcelain --untracked-files=no 2>/dev/null | grep -vE '^ ?M config$' || true)
    if [[ -n "$changes" ]]; then
        log_message "$(T "⚠️ Your working folder %s has changes of yours, so it was left as it is. Update it yourself before you run install-scripts.sh there again: git fetch --tags && git checkout %s" "$folder" "$tag")"
        return 0
    fi
    if as_main bash -c '
        set -e
        cd "$1"
        GIT_TERMINAL_PROMPT=0 git fetch -q --tags origin
        [[ "$(git rev-parse "$2^{commit}")" == "$3" ]]
        keep=$(mktemp)
        cp -p config "$keep"
        git checkout -q -- config
        git checkout -q --detach "$2"
        cat "$keep" > config
        chmod --reference="$keep" config
        rm -f "$keep"' _ "$folder" "$tag" "$(git -C "$STATE/source.git" rev-parse "refs/tags/$tag^{commit}")"; then
        log_message "$(T "✅ Working folder %s is at %s now (your config kept)" "$folder" "$tag")"
    else
        log_message "$(T "⚠️ Could not move your working folder %s to %s. Do it yourself before you run install-scripts.sh there again: git fetch --tags && git checkout %s" "$folder" "$tag" "$tag")"
    fi
}

apply_staged() {
    local at_boot="${1:-0}" tag
    [[ -f "$STATE/src/.release" ]] || die "$(T "No update is waiting")"
    tag=$(head -n 1 "$STATE/src/.release")
    log_message "$(T "🔄 Installing %s..." "$tag")"
    # The staged copy installs itself, keeping the installed config
    bash "$STATE/src/install-scripts.sh" --update "$tag" "$DEST/config" || die "$(T "install-scripts.sh of %s failed; the backup service wasn't touched" "$tag")"
    log_message "$(T "🔄 Reinstalling the backup service...")"
    if ! (umask 022 && LND_UPDATE_AT_BOOT="$at_boot" "$DEST/rsync_gpg_backup.sh" < /dev/null >> "$LOG_FILE" 2>&1); then
        die "$(T "The backup service installer failed (details in %s). Run it by hand: sudo %s/rsync_gpg_backup.sh" "$LOG_FILE" "$DEST")"
    fi
    update_working_folder "$tag"
    rm -f -- "$PENDING_FILE"
    rm -rf -- "$STATE/src"
    # On disk before anything else happens (at boot, a power cut right after would lose it)
    sync
    log_message "$(T "✅ Updated to %s" "$tag")"
}

# Applies now if it is safe, holding the locks lnd-wallet and chain-tower take, so neither starts
# meanwhile. Returns 1 (nothing done) if it isn't safe.
apply_if_safe() {
    local reason
    exec 7> /run/lnd-wallet.lock 8> /run/lnd-chain.lock
    if ! flock -n 7 || ! flock -n 8; then
        exec 7>&- 8>&-
        return 1
    fi
    # Holding both locks shows no wallet or chain operation runs; only the backup is left to check
    reason=$(backup_busy_reason)
    if [[ -n "$reason" ]]; then
        exec 7>&- 8>&-
        return 1
    fi
    apply_staged 0
    exec 7>&- 8>&-
}

need_root() {
    (( EUID == 0 )) || { say "❌ Run it with sudo: sudo lnd-update %s" "$*" >&2; exit 1; }
}

case "${1:-install}" in
    check)
        # Data for the dashboard: never translated
        printf 'scripts %s %s\n' "$(installed_version)" "$(latest_release || true)"
        [[ -f "$PENDING_FILE" ]] && printf 'pending %s\n' "$(head -n 1 "$PENDING_FILE")"
        exit 0
        ;;
    install)
        need_root
        [[ -t 0 ]] || die "$(T "lnd-update needs a terminal: you type UPDATE to confirm")"
        # A wait from an earlier run is replaced by this one
        systemctl stop lnd-update-wait.service 2>/dev/null || true
        exec 9> /run/lnd-update.lock
        flock -n 9 || die "$(T "Another update is running")"
        source_kind=$(update_source "$DEST/lnd-update.sh")
        [[ "$source_kind" == git ]] || die "$(T "These scripts come from a package: update them with apt (sudo apt upgrade)")"
        installed=$(installed_version)
        say "🔎 Looking for the newest release..."
        latest=$(latest_release) || true
        [[ -n "$latest" ]] || die "$(T "No release found at %s (no network, or no release yet)" "$RELEASE_REPO_URL")"
        if ! release_newer "$installed" "$latest"; then
            say "✅ %s is the newest release: nothing to do" "$installed"
            exit 0
        fi
        say "These scripts: %s -> %s" "$installed" "$latest"
        say "   LND and BTCPay aren't touched. The backup service is reinstalled (a few seconds without it)."
        read -r -p "$(T "Type UPDATE to get it and install it when it is safe: ")" answer || exit 1
        [[ "$answer" == UPDATE ]] || die "$(T "Cancelled: nothing was updated")"
        stage_release_git "$latest" "$STATE" "$DEST/release-key.asc"
        [[ -f "$STATE/src/install-scripts.sh" && -f "$STATE/src/lnd-update.sh" ]] ||
            die "$(T "%s doesn't look like a release of these scripts" "$latest")"
        if apply_if_safe; then
            exit 0
        fi
        reason=$(safe_check)
        printf '%s waiting %s\n' "$latest" "$(date +%s)" > "$PENDING_FILE"
        chmod 644 "$PENDING_FILE"
        log_message "$(T "⏳ Not safe to update now: %s" "${reason:-?}")"
        start_waiter lnd-update-wait "$DEST/lnd-update.sh" apply-wait ||
            die "$(T "Could not start the background wait; the update is applied at the next boot")"
        say "   It waits in the background (lnd-update-wait) and installs %s once it is safe, for up to" "$latest"
        say "   24 hours. After that it is installed at the next boot. lnd-update check shows where it is."
        exit 0
        ;;
    apply-wait)
        need_root apply-wait
        exec 9> /run/lnd-update.lock
        flock 9
        deadline=$(wait_deadline "$(awk '{ print $3 }' "$PENDING_FILE" 2>/dev/null)")
        while wait_until_safe safe_check "$deadline"; do
            apply_if_safe && exit 0
            # It changed at the last moment: look again shortly
            (( $(date +%s) < deadline )) || break
            sleep "$UPDATE_RETRY_SECONDS"
        done
        tag=$(head -n 1 "$STATE/src/.release" 2>/dev/null || echo "?")
        printf '%s boot %s\n' "$tag" "$(date +%s)" > "$PENDING_FILE"
        log_message "$(T "⏸️ Still not safe after 24 hours: %s is installed at the next boot" "$tag")"
        exit 0
        ;;
    boot)
        need_root boot
        [[ -f "$STATE/src/.release" ]] || exit 0
        exec 9> /run/lnd-update.lock
        flock 9
        # At boot nothing else runs yet: the backup service starts after this step
        apply_staged 1
        ;;
    -h | --help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
