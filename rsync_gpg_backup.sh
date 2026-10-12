#!/bin/bash
set -eEuo pipefail

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
# --test-mode: the service also watches a test folder (TEST_INOTIFY_FOLDER in config), for the
# test VM; nobody needs it on a real server
ENABLE_TEST_MODE=n
for arg in "$@"; do
    case "$arg" in
        --test-mode) ENABLE_TEST_MODE=y ;;
        -h | --help)
            echo "Usage: rsync_gpg_backup.sh [--test-mode]"
            echo "  Installs or updates the backup service. --test-mode also watches a test folder (tests only)."
            exit 0 ;;
        *) echo "❌ Unknown option: $arg (see --help)" >&2; exit 2 ;;
    esac
done

# The installer runs its commands with sudo, and the service it installs reads this config:
# both must come from the root-owned install. Checked before config is read.
if ! root_owned_chain "$SCRIPT_DIR/rsync_gpg_backup.sh" "$CONFIG_FILE" "$SCRIPT_DIR/i18n.sh"; then
    echo "❌ $SCRIPT_DIR/rsync_gpg_backup.sh or its config can be changed by users other than root." >&2
    echo "   Install the scripts root-owned (sudo ./install-scripts.sh in your working folder), then run" >&2
    echo "   ${BACKUP_INSTALL_DIR:-/usr/local/lib/btcpay-docker-lnd-manager}/rsync_gpg_backup.sh" >&2
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

# === Where the backups go (config: BACKUP_TO_*, lnd-manager: /destinations) ===
TO_VOLUME="${BACKUP_TO_VOLUME:-yes}" TO_SERVER_B="${BACKUP_TO_SERVER_B:-yes}" TO_GITHUB="${BACKUP_TO_GITHUB:-no}"
if [[ "$TO_VOLUME" != yes && "$TO_SERVER_B" != yes && "$TO_GITHUB" != yes ]]; then
    say "❌ No backup destination is on (BACKUP_TO_VOLUME, BACKUP_TO_SERVER_B, BACKUP_TO_GITHUB in config): lnd-manager /destinations" >&2
    exit 1
fi
if [[ "$TO_GITHUB" == yes && -z "${GITHUB_REPO:-}" ]]; then
    say "❌ BACKUP_TO_GITHUB is yes but GITHUB_REPO is empty: run setup (lnd-manager: /setup)" >&2
    exit 1
fi
DESTINATIONS=()
[[ "$TO_VOLUME" == yes ]] && DESTINATIONS+=("$(T "the attached volume (%s)" "$SECOND_BACKUP_DIR")")
[[ "$TO_SERVER_B" == yes ]] && DESTINATIONS+=("$(T "Server B (%s)" "$REMOTE_SERVER")")
[[ "$TO_GITHUB" == yes ]] && DESTINATIONS+=("$(T "GitHub (%s)" "$GITHUB_REPO")")

# ==== Initiate the log file ===
sudo touch "$LIGHTNING_BACKUP_LOG_FILE"
sudo chown "$SERVER_A_USER":"$SERVER_A_USER" "$LIGHTNING_BACKUP_LOG_FILE"
sudo chmod 640 "$LIGHTNING_BACKUP_LOG_FILE"

# === Logging Function ===
log_message() {
    local message="${1:-'Default message'}"    
    local timestamped="[$(date --iso-8601=seconds)] $message"
    echo "$timestamped"
    echo "$timestamped" | sudo tee -a "$LIGHTNING_BACKUP_LOG_FILE" > /dev/null
}

# Safe folders: safe_delete only removes paths inside these. The list is chosen below and
# written into the root-owned service script, so the backup user can't widen it.
SAFE_BASES=()

# === Check that a path falls under one of the SAFE_BASES ===
is_under_safe_bases() {
    local real_target base real_base
    real_target=$(realpath -m "$1" 2>/dev/null) || return 1

    for base in "${SAFE_BASES[@]}"; do
        [[ -z "$base" ]] && continue
        real_base=$(realpath -m "$base" 2>/dev/null) || continue
        case "$real_target" in
            "$real_base" | "$real_base"/*)
                return 0
                ;;
        esac
    done

    return 1
}

# True when the disk with config's UUID is mounted exactly at ATTACHED_VOLUME, and that path is
# not a symlink. mountpoint -q follows symlinks and doesn't look at which disk it is.
attached_volume_ok() {
    [[ -n "${UUID:-}" && -d "$ATTACHED_VOLUME" && ! -L "$ATTACHED_VOLUME" ]] || return 1
    [[ "$(findmnt -rn -M "$ATTACHED_VOLUME" -o UUID 2>/dev/null)" == "$UUID" ]]
}

# === Safe Delete: files or directories ===
safe_delete() {
    local TARGET
    local FILE=""
    local DIR=""

    # --- Support both call styles ---
    if [[ $# -eq 1 ]]; then
        TARGET="$1"
    elif [[ $# -eq 2 ]]; then
        DIR="$1"
        FILE="$2"
        TARGET="$DIR/$FILE"
    else
        log_message "$(T "❌ Invalid safe_delete usage")"
        return 1
    fi

    # 🚨 Reject empty TARGET
    if [[ -z "$TARGET" ]]; then
        log_message "$(T "❌ Unsafe path: empty target")"
        return 1
    fi

    # Resolve real path
    local REAL_TARGET
    REAL_TARGET=$(realpath -m "$TARGET" 2>/dev/null || echo "")

    if [[ -z "$REAL_TARGET" ]]; then
        log_message "$(T "❌ Failed to resolve path: %s" "$TARGET")"
        return 1
    fi

    # 🚨 Hard safety checks
    if [[ "$REAL_TARGET" == "/" || "$REAL_TARGET" == "." || "$REAL_TARGET" == ".." ]]; then
        log_message "$(T "❌ Unsafe path: %s" "$REAL_TARGET")"
        return 1
    fi

    # 🚨 Ensure target is within allowed bases
    if ! is_under_safe_bases "$REAL_TARGET"; then
        log_message "$(T "❌ Refusing to delete outside safe bases: %s" "$REAL_TARGET")"
        return 1
    fi

    # Ensure ATTACHED_VOLUME is actually mounted
    # Compared with the resolved path: a symlink or trailing slash in config would skip the check
    local ATTACHED_REAL
    ATTACHED_REAL=$(realpath -m -- "$ATTACHED_VOLUME")
    if [[ "$REAL_TARGET" == "$ATTACHED_REAL" || "$REAL_TARGET" == "$ATTACHED_REAL"/* ]]; then
        if ! attached_volume_ok; then
            log_message "$(T "❌ Refusing delete: the attached volume (UUID %s) is not mounted at %s" "$UUID" "$ATTACHED_VOLUME")"
            return 1
        fi
    fi

    # Ensure target exists (as SAFE_DELETE_AS when set: the installer's user may not see it)
    local EXISTS=(test -e "$REAL_TARGET")
    if [[ -n "${SAFE_DELETE_AS:-}" ]]; then
        EXISTS=(sudo -u "$SAFE_DELETE_AS" "${EXISTS[@]}")
    fi
    if ! "${EXISTS[@]}"; then
        log_message "$(T "⚠️ Target not found: %s" "$REAL_TARGET")"
        return 0
    fi

    # Perform deletion, as SAFE_DELETE_AS when set (the backups belong to the backup user)
    local RM=(rm -rf --one-file-system --preserve-root -- "$REAL_TARGET")
    if [[ -n "${SAFE_DELETE_AS:-}" ]]; then
        RM=(sudo -u "$SAFE_DELETE_AS" "${RM[@]}")
    fi
    if "${RM[@]}"; then
        log_message "$(T "🗑️ Safely removed: %s" "$REAL_TARGET")"
    else
        log_message "$(T "❌ Failed to remove: %s" "$REAL_TARGET")"
        return 1
    fi
}

# === What this installs ===
# Shown in a terminal only: a reinstall without one (lnd-wallet.sh after a new wallet) just runs.
if [[ -t 0 ]]; then
    echo
    say "This installs or updates the LND backup service (%s)." "$RSYNC_BACKUP_SERVICE_NAME"
    echo
    say "What the service does"
    say "  It runs all the time as the backup user (%s), not as root. When LND's channel backup" "$SERVER_A_USER"
    say "  changes (a channel opens or closes), it packs LND's files (channel.backup, the wallet,"
    say "  walletunlock.json, macaroons, TLS certificate), encrypts and signs them with the backup GPG key,"
    say "  and copies the result to each destination that is on:"
    for d in "${DESTINATIONS[@]}"; do
        echo "    - $d"
    done
    say "  Each keeps the 10 newest, plus one"
    say "  per day for 30 days and one per month for 12 months. Once an hour it checks for a change it"
    say "  missed; the files LND rewrites by itself all the time (wallet.db, macaroons.db) don't count."
    echo
    say "What the installer sets up"
    say "  - The safe folders: the only folders the service may ever delete from (asked next)."
    say "  - Read access for the backup user to config, and to the LND folders it watches (the folders"
    say "    only, not the files in them)."
    say "  - A root helper, %s, that can only read files inside LND's folder," "$LND_BACKUP_HELPER_PATH"
    say "    and a sudo rule that lets the backup user run that helper and nothing else."
    say "  - Keeps the backup user out of the docker group (that would amount to root)."
    say "  - Installs missing tools: rsync, gnupg, inotify-tools, xxhash, acl."
    say "  - Stops the service, writes it to %s and" "$RSYNC_FOLDER_MIRROR_SYSTEMD_SCRIPT_PATH"
    say "    %s, then enables and starts it." "$RSYNC_BACKUP_SERVICE_PATH"
    say "  - Asks whether to delete the existing backups (only if you type DELETE ALL BACKUPS)."
    say "  It doesn't touch BTCPay or the LND wallet."
    echo
    read -rp "$(T "Press Enter to continue, or Ctrl-C to stop: ")" _ || exit 1
fi

# === Choose the safe folders (SAFE_BASES) ===
# Asked before the installer creates, changes or deletes anything. The folders may not exist
# yet on a first install, so every check works on the path text (realpath -m).
SAFE_BASES_REQUIRED=("$TEST_INOTIFY_PARENT_FOLDER" "$TMP_BACKUP_DIR" "$BACKUP_METADATA_FOLDER")
[[ "$TO_VOLUME" == yes ]] && SAFE_BASES_REQUIRED+=("$ATTACHED_VOLUME")

# True if path $1 is $2 or inside it (both already resolved)
path_is_within() {
    [[ "$2" == "/" || "$1" == "$2" || "$1" == "$2"/* ]]
}

# Prints why $1 can't be a safe folder; prints nothing if it can
safe_base_problem() {
    local entry="$1" real home protected

    if [[ "$entry" != /* ]]; then
        say "not an absolute path"
        return 0
    fi
    real=$(realpath -m -- "$entry")

    case "$real" in
        / | /bin | /boot | /dev | /etc | /home | /lib* | /media | /mnt | /opt | /proc | /root | /run | \
        /sbin | /srv | /sys | /tmp | /usr | /usr/* | /var | /var/lib | /var/log | /var/tmp)
            say "%s is a system folder" "$real"
            return 0
            ;;
    esac

    while IFS= read -r home; do
        [[ -z "$home" ]] && continue
        home=$(realpath -m -- "$home")
        if path_is_within "$home" "$real"; then
            say "%s is or contains the home folder %s" "$real" "$home"
            return 0
        fi
    done < <(getent passwd | cut -d: -f6)

    for protected in "$SCRIPT_DIR" "$LND_DIR" "$GPG_KEY_DIR" "$SERVER_A_USER_HOME/.ssh"; do
        [[ -z "$protected" ]] && continue
        protected=$(realpath -m -- "$protected")
        if path_is_within "$protected" "$real"; then
            say "%s is or contains %s" "$real" "$protected"
            return 0
        fi
    done
}

# The list in the installed service script, one entry per NUL. Only its SAFE_BASES+=(...) lines
# are read, in a subshell.
installed_safe_bases() {
    [[ -r "$RSYNC_FOLDER_MIRROR_SYSTEMD_SCRIPT_PATH" ]] || return 0
    (
        SAFE_BASES=()
        eval "$(grep -E '^SAFE_BASES\+=\(.*\)$' "$RSYNC_FOLDER_MIRROR_SYSTEMD_SCRIPT_PATH" || true)"
        if (( ${#SAFE_BASES[@]} > 0 )); then
            printf '%s\0' "${SAFE_BASES[@]}"
        fi
    )
}

# Adds $1 to SAFE_BASES (resolved) unless it's already there
add_safe_base() {
    local real existing
    real=$(realpath -m -- "$1")
    for existing in "${SAFE_BASES[@]}"; do
        [[ "$existing" == "$real" ]] && return 0
    done
    SAFE_BASES+=("$real")
}

# Asks for one folder with $2 prefilled until it's valid or empty. Sets ASKED_SAFE_BASE.
ask_safe_base() {
    local prompt="$1" text="$2" problem
    while true; do
        if ! read -r -e -p "$prompt" -i "$text" text; then
            text=""
        fi
        if [[ -z "$text" ]]; then
            ASKED_SAFE_BASE=""
            return 0
        fi
        problem=$(safe_base_problem "$text")
        if [[ -z "$problem" ]]; then
            ASKED_SAFE_BASE="$text"
            return 0
        fi
        say "❌ Not allowed: %s" "$problem"
    done
}

INSTALLED_SAFE_BASES=()
while IFS= read -r -d '' entry; do
    INSTALLED_SAFE_BASES+=("$entry")
done < <(installed_safe_bases)

if [[ ! -t 0 ]]; then
    # No human to confirm a list: only reuse the one confirmed at the last install
    if (( ${#INSTALLED_SAFE_BASES[@]} == 0 )); then
        log_message "$(T "❌ No terminal to confirm the safe folders, and no installed list to reuse. Run the installer in a terminal.")"
        exit 1
    fi
    for entry in "${INSTALLED_SAFE_BASES[@]}"; do
        problem=$(safe_base_problem "$entry")
        if [[ -n "$problem" ]]; then
            log_message "$(T "❌ Installed safe folder not allowed: %s. Run the installer in a terminal." "$problem")"
            exit 1
        fi
        add_safe_base "$entry"
    done
    log_message "$(T "ℹ️ No terminal: reusing the installed safe folders: %s" "${SAFE_BASES[*]}")"
else
    if (( ${#INSTALLED_SAFE_BASES[@]} > 0 )); then
        SAFE_BASES_SUGGESTED=("${INSTALLED_SAFE_BASES[@]}")
        say "Safe folders: the backup only deletes files inside these. Suggested: the list from the installed service."
    else
        SAFE_BASES_SUGGESTED=("${SAFE_BASES_REQUIRED[@]}")
        say "Safe folders: the backup only deletes files inside these. Suggested: the backup folders from config."
    fi
    say "Press Enter to keep a folder, edit it, or clear it to drop it."

    while true; do
        SAFE_BASES=()
        for suggested in "${SAFE_BASES_SUGGESTED[@]}"; do
            ask_safe_base "$(T "Safe folder: ")" "$suggested"
            [[ -n "$ASKED_SAFE_BASE" ]] && add_safe_base "$ASKED_SAFE_BASE"
        done
        while true; do
            ask_safe_base "$(T "Add another folder (Enter to finish): ")" ""
            [[ -z "$ASKED_SAFE_BASE" ]] && break
            add_safe_base "$ASKED_SAFE_BASE"
        done

        MISSING_SAFE_BASES=()
        for required_path in "${SAFE_BASES_REQUIRED[@]}"; do
            if ! is_under_safe_bases "$required_path"; then
                MISSING_SAFE_BASES+=("$required_path")
            fi
        done
        if (( ${#MISSING_SAFE_BASES[@]} > 0 )); then
            for required_path in "${MISSING_SAFE_BASES[@]}"; do
                say "❌ %s (from config) is not inside any safe folder" "$required_path"
            done
            say "Let's go through the list again."
            SAFE_BASES_SUGGESTED=("${SAFE_BASES[@]}" "${MISSING_SAFE_BASES[@]}")
            continue
        fi

        say "Safe folders:"
        printf '  %s\n' "${SAFE_BASES[@]}"
        if ! read -r -p "$(T "Type yes to use these folders: ")" SAFE_BASES_CONFIRM; then
            log_message "$(T "❌ Safe folders not confirmed")"
            exit 1
        fi
        [[ "$SAFE_BASES_CONFIRM" == "yes" ]] && break
        say "Let's go through the list again."
        SAFE_BASES_SUGGESTED=("${SAFE_BASES[@]}")
    done
    log_message "$(T "✅ Safe folders confirmed: %s" "${SAFE_BASES[*]}")"
fi

# === Ensure SAFE_BASES cover the configured paths ===
REQUIRED_PATHS=("$TMP_BACKUP_DIR" "$BACKUP_METADATA_FOLDER" "$TEST_INOTIFY_PARENT_FOLDER")
[[ "$TO_VOLUME" == yes ]] && REQUIRED_PATHS+=("$ATTACHED_VOLUME")
for required_path in "${REQUIRED_PATHS[@]}"; do
    if ! is_under_safe_bases "$required_path"; then
        log_message "$(T "❌ %s is not under any SAFE_BASES entry" "$required_path")"
        log_message "$(T "❌ Rerun the installer and include it in the safe folders")"
        exit 1
    fi
done

# Ensure metadata root exists. It is in the backup user's home: made and closed by that user,
# never by root through a path that user could turn into a link.
if sudo test -L "$BACKUP_METADATA_FOLDER"; then
    log_message "$(T "❌ %s is a symlink. Stopping: changing it as root could change its target." "$BACKUP_METADATA_FOLDER")"
    exit 1
fi
sudo -u "$SERVER_A_USER" mkdir -p -- "$BACKUP_METADATA_FOLDER"
# Older installers made it as root: what is there goes to the backup user (-h and -R never
# follow links)
sudo chown -R -h "$SERVER_A_USER":"$SERVER_A_USER" -- "$BACKUP_METADATA_FOLDER"
sudo -u "$SERVER_A_USER" chmod 700 -- "$BACKUP_METADATA_FOLDER"

# === ENSURE CONFIG IS READABLE BY SERVER_A_USER ===
# Read-only ACLs, not group membership: the config usually belongs to MAIN_USER's own group,
# and with Ubuntu's umask 0002 that group can write MAIN_USER's files. Being in it would let
# the backup user rewrite the config and scripts that MAIN_USER runs with sudo.
if [ -f "$CONFIG_FILE" ]; then
    CONFIG_DIR=$(dirname "$CONFIG_FILE")

    # Undo the group membership that older versions of this installer added
    FILE_GROUP=$(stat -c "%G" "$CONFIG_FILE")
    if [[ "$FILE_GROUP" != "$(id -gn "$SERVER_A_USER")" && " $(id -nG "$SERVER_A_USER") " == *" $FILE_GROUP "* ]]; then
        sudo gpasswd -d "$SERVER_A_USER" "$FILE_GROUP"
        say "✅ Removed %s from group %s (replaced by read-only ACLs)" "$SERVER_A_USER" "$FILE_GROUP"
    fi

    # x on each folder above the config that SERVER_A_USER can't pass through yet
    DIR_PATH="$CONFIG_DIR"
    while [ "$DIR_PATH" != "/" ]; do
        if ! sudo -u "$SERVER_A_USER" test -x "$DIR_PATH"; then
            sudo setfacl -m u:"$SERVER_A_USER":x "$DIR_PATH"
        fi
        DIR_PATH=$(dirname "$DIR_PATH")
    done

    # r on the config, and a default ACL so a config saved as a new file stays readable
    sudo setfacl -m u:"$SERVER_A_USER":r "$CONFIG_FILE"
    sudo setfacl -d -m u:"$SERVER_A_USER":r "$CONFIG_DIR"

    if ! sudo -u "$SERVER_A_USER" test -r "$CONFIG_FILE"; then
        say "❌ %s still can't read %s" "$SERVER_A_USER" "$CONFIG_FILE"
        exit 1
    fi
    # The config is sourced as root by setup_script.sh, and the scripts next to it run with sudo
    if sudo -u "$SERVER_A_USER" test -w "$CONFIG_FILE" || sudo -u "$SERVER_A_USER" test -w "$CONFIG_DIR"; then
        say "❌ %s can write %s or %s, which root uses. Fix their permissions first." "$SERVER_A_USER" "$CONFIG_FILE" "$CONFIG_DIR"
        exit 1
    fi

    # Load the configuration
    source "$CONFIG_FILE"
else
    say "❌ Configuration file not found at %s" "$CONFIG_FILE"
    exit 1
fi

# === ROOT-OWNED LND BACKUP HELPER ===
# SERVER_A_USER may run only this helper as root. It reads files inside LND_DIR and nothing else.
# LND_DIR and LND_BACKUP_ARCHIVE are written into the helper at install time. The helper must
# never source config, because config lives in a folder MAIN_USER can write to.
if [[ "$LND_BACKUP_HELPER_PATH" != /* ]]; then
    log_message "$(T "❌ LND_BACKUP_HELPER_PATH must be an absolute path: %s" "$LND_BACKUP_HELPER_PATH")"
    exit 1
fi

log_message "$(T "⚙️ Installing %s..." "$LND_BACKUP_HELPER_PATH")"

# The files the backup reads, relative to LND_DIR: the only ones the helper opens, besides the
# channel backup archives. Keep in step with FILES_TO_BACKUP in the service below.
HELPER_FILES=(
    data/chain/bitcoin/mainnet/chainnotifier.macaroon
    data/chain/bitcoin/mainnet/invoices.macaroon
    data/chain/bitcoin/mainnet/router.macaroon
    data/chain/bitcoin/mainnet/wallet.db
    data/chain/bitcoin/mainnet/walletunlock.json
    data/chain/bitcoin/mainnet/channel.backup
    data/chain/bitcoin/mainnet/macaroons.db
    data/chain/bitcoin/mainnet/signer.macaroon
    data/chain/bitcoin/mainnet/walletkit.macaroon
    admin.macaroon
    invoice.macaroon
    lnd.conf
    readonly.macaroon
    tls.cert
    tls.key
    walletunlock.json
)

HELPER_TMP=$(mktemp)
{
    echo '#!/bin/bash'
    echo '# Generated by rsync_gpg_backup.sh. Do not edit; rerun the installer instead.'
    printf 'LND_DIR=%q\n' "$(realpath -m "$LND_DIR")"
    printf 'LND_BACKUP_ARCHIVE=%q\n' "$(realpath -m "$LND_BACKUP_ARCHIVE")"
    printf 'ALLOWED_FILES=(%s)\n' "$(printf '%q ' "${HELPER_FILES[@]}")"
    cat <<'HELPER_EOF'
set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

die() {
    echo "lnd-backup-helper: $*" >&2
    exit 1
}

# sudoers doesn't log helper calls (to keep the journal readable), so the helper logs the
# refusals that matter for security itself. Control characters are replaced so a crafted
# argument can't add fake log lines.
refuse() {
    local msg="$*"
    logger -t lnd-backup-helper -p auth.warning -- \
        "refused for ${SUDO_USER:-unknown}: ${msg//[[:cntrl:]]/?}" 2>/dev/null || true
    die "$@"
}

# Opens one of the backed-up files (or a channel backup archive) on fd 3, then checks the file
# that was actually opened, not the path: a container that can write the LND volume could
# otherwise swap a folder for a symlink between the check and the read, and have root read any
# file. The commands below read from fd 3. Sets REL to the path inside LND_DIR.
REL=""
open_lnd_file() {
    local want opened allowed ok=false
    want=$(realpath -m -- "$1")
    # Checked before anything touches the disk, so the answer never tells whether some file
    # elsewhere exists
    case "$want" in
        "$LND_DIR"/*) ;;
        *) refuse "outside $LND_DIR: $1" ;;
    esac
    REL="${want#"$LND_DIR"/}"
    for allowed in "${ALLOWED_FILES[@]}"; do
        [[ "$REL" == "$allowed" ]] && ok=true
    done
    if [[ "$(dirname -- "$want")" == "$LND_BACKUP_ARCHIVE" && "$(basename -- "$want")" == channel.backup-* ]]; then
        ok=true
    fi
    $ok || refuse "not a file the backup reads: $1"

    exec 3< "$want" 2>/dev/null || die "not found: $1"
    opened=$(readlink -f /proc/self/fd/3) || die "cannot check: $1"
    [[ "$opened" == "$want" ]] || refuse "changed while it was opened: $1"
    [[ -f /proc/self/fd/3 ]] || die "not a regular file: $1"
}

cmd="${1:-}"
case "$cmd" in
    list-archives)
        (( $# == 1 )) || die "usage: list-archives"
        [[ -d "$LND_BACKUP_ARCHIVE" ]] || exit 0
        find "$LND_BACKUP_ARCHIVE" -maxdepth 1 -type f -name 'channel.backup-*' -printf '%T@ %p\n'
        ;;
    test-file)
        (( $# == 2 )) || die "usage: test-file <path>"
        open_lnd_file "$2"
        ;;
    hash)
        (( $# == 2 )) || die "usage: hash <path>"
        open_lnd_file "$2"
        out=$(xxhsum -H128 - <&3)
        printf '%s\n' "${out%% *}"
        ;;
    read)
        (( $# == 2 )) || die "usage: read <path>"
        open_lnd_file "$2"
        # Reads hand out the wallet's secrets, so each one is logged (sudoers logs none)
        logger -t lnd-backup-helper -p auth.info -- "read by ${SUDO_USER:-unknown}: $REL" 2>/dev/null || true
        cat <&3
        ;;
    mtime)
        (( $# == 2 )) || die "usage: mtime <path>"
        open_lnd_file "$2"
        stat -L -c %Y /proc/self/fd/3
        ;;
    *)
        refuse "unknown command: ${cmd:-<none>} (allowed: list-archives, test-file, hash, read, mtime)"
        ;;
esac
HELPER_EOF
} > "$HELPER_TMP"

if ! bash -n "$HELPER_TMP"; then
    log_message "$(T "❌ Generated helper has a syntax error — not installed")"
    rm -f "$HELPER_TMP"
    exit 1
fi

sudo install -o root -g root -m 755 "$HELPER_TMP" "$LND_BACKUP_HELPER_PATH"
rm -f "$HELPER_TMP"
log_message "$(T "✅ Installed %s" "$LND_BACKUP_HELPER_PATH")"

# === SUDOERS CONFIGURATION BLOCK (idempotent) ===
log_message "$(T "⚙️ Configuring sudoers for %s..." "$SERVER_A_USER")"

SUDOERS_FILE="/etc/sudoers.d/$SERVER_A_USER"
SUDOERS_TMP=$(mktemp)

# Desired sudoers content (IMPORTANT: no unnecessary line continuations)
# Only the helper is allowed. find, cp, chown etc. as root would be equivalent to full root.
# The Defaults line stops each of the service's helper calls from adding three lines
# (command, PAM session opened/closed) to the logs. The helper itself logs the calls it
# refuses (paths outside LND_DIR, unknown commands) with the tag lnd-backup-helper.
cat > "$SUDOERS_TMP" <<EOF
Defaults!$LND_BACKUP_HELPER_PATH !log_allowed, !pam_session
$SERVER_A_USER ALL=(root) NOPASSWD: $LND_BACKUP_HELPER_PATH
EOF

# Strict permission requirement (sudoers WILL fail without this)
sudo chmod 440 "$SUDOERS_TMP"

# Validate temp file (critical step)
if ! sudo visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then
    log_message "$(T "❌ visudo validation failed — sudoers not updated")"
    rm -f "$SUDOERS_TMP"
    exit 1
fi

# Only update if content changed
if ! sudo cmp -s "$SUDOERS_TMP" "$SUDOERS_FILE" 2>/dev/null; then
    sudo cp "$SUDOERS_TMP" "$SUDOERS_FILE"
    sudo chmod 440 "$SUDOERS_FILE"

    # Final global validation safety check
    if sudo visudo -c >/dev/null 2>&1; then
        log_message "$(T "✅ Sudoers updated and validated for %s" "$SERVER_A_USER")"
    else
        log_message "$(T "❌ Global sudoers validation failed — reverting changes")"
        sudo rm -f "$SUDOERS_FILE"
        rm -f "$SUDOERS_TMP"
        exit 1
    fi
else
    log_message "$(T "ℹ️ Sudoers already up-to-date for %s" "$SERVER_A_USER")"
fi

rm -f "$SUDOERS_TMP"

# === Keep SERVER_A_USER out of the docker group ===
# The backup service never runs docker, and docker group membership is equivalent to root.
if [[ " $(id -nG "$SERVER_A_USER") " == *" docker "* ]]; then
    log_message "$(T "Removing %s from the docker group..." "$SERVER_A_USER")"
    sudo gpasswd -d "$SERVER_A_USER" docker
    log_message "$(T "%s removed from docker group." "$SERVER_A_USER")"
fi

# Check if 'mountpoint' command exists
if ! command -v mountpoint >/dev/null 2>&1; then
    say "mountpoint command not found. Installing util-linux..."
    sudo apt update
    sudo apt install -y util-linux
fi

# === Check and Install Dependencies for Debian 13 ===
REQUIRED_COMMANDS=(rsync gpg inotifywait sha256sum xxhsum realpath flock find setfacl)

# Add systemd-notify
REQUIRED_COMMANDS+=(systemd-notify)

# Map commands to packages (may vary slightly depending on system)
declare -A CMD_TO_PKG=(
    [rsync]="rsync"
    [gpg]="gnupg"
    [inotifywait]="inotify-tools"
    [sha256sum]="coreutils"
    [realpath]="coreutils"
    [flock]="util-linux"
    [find]="findutils"
    [xxhsum]="xxhash"
    [setfacl]="acl"
    [systemd-notify]="systemd"
)

# Function to check if command exists
check_command() {
    command -v "$1" >/dev/null 2>&1
}

# Check and install missing dependencies
MISSING_PKGS=()
for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! check_command "$cmd"; then
        pkg="${CMD_TO_PKG[$cmd]}"
        say "Missing dependency: %s (package: %s). Installing..." "$cmd" "$pkg"
        MISSING_PKGS+=("$pkg")
    fi
done

# Install missing packages if any
if (( ${#MISSING_PKGS[@]} > 0 )); then
    sudo apt update
    sudo apt install -y "${MISSING_PKGS[@]}"
    # Verify installation
    for pkg in "${MISSING_PKGS[@]}"; do
        # Check if command is now available
        # Map package to command to verify
        for cmd in "${!CMD_TO_PKG[@]}"; do
            if [[ "${CMD_TO_PKG[$cmd]}" == "$pkg" ]]; then
                if ! check_command "$cmd"; then
                    say "Failed to install %s or command %s is still missing." "$pkg" "$cmd"
                    exit 1
                fi
            fi
        done
    done
else
    say "All dependencies are already installed."
fi

# === LND's archive folder ===
# LND makes chan-backup-archives only when it first replaces an existing channel.backup: at its
# second start, or the first channel opening or closing. The service watches it, so on a new node
# it is made here, the way LND would (root's, 700), as lnd-wallet.sh does after a new volume.
# Only inside LND's existing mainnet folder, and not through a symlink: a container that mounts
# the volume could have planted one.
ensure_archive_dir() {
    local parent
    parent=$(dirname -- "$LND_BACKUP_ARCHIVE")
    sudo test -d "$LND_BACKUP_ARCHIVE" && return 0
    # No wallet folder yet: grant_inotify_acls below says so
    sudo test -d "$parent" || return 0
    if [[ "$(sudo realpath -m -- "$LND_BACKUP_ARCHIVE")" != "$(realpath -m -s -- "$LND_BACKUP_ARCHIVE")" ]]; then
        log_message "$(T "⚠️ %s goes through a symlink, so it was not made" "$LND_BACKUP_ARCHIVE")"
        return 0
    fi
    if sudo mkdir -m 700 -- "$LND_BACKUP_ARCHIVE"; then
        log_message "$(T "✅ Made %s (LND makes it only when it first archives a channel.backup)" "$LND_BACKUP_ARCHIVE")"
    else
        log_message "$(T "❌ Could not make %s" "$LND_BACKUP_ARCHIVE")"
    fi
}
ensure_archive_dir

# === Give SERVER_A_USER inotify access to the LND folders ===
# inotifywait needs read on each watched folder and x on every folder above it.
# The watched folders are LND_BACKUP_ARCHIVE (the watcher) plus LND_DIR and mainnet
# (wait_for_files_to_settle watches the folders of every file in FILES_TO_BACKUP).
# The parents only get x, so SERVER_A_USER can pass through them but not list them.
#
# No default ACL: it would give SERVER_A_USER read access to every new file LND creates
# (wallet.db, macaroons). inotify only needs the folders, and the backup reads file
# contents through $LND_BACKUP_HELPER_PATH anyway.
#
# Deleting the LND volume (for example with lnd-wallet.sh) removes these ACLs.
# Rerun this installer afterwards.
grant_inotify_acls() {
    local dir i rc
    local parents=()
    local watched=(
        "$LND_DIR"
        "$LND_DIR/data/chain/bitcoin/mainnet"
        "$LND_BACKUP_ARCHIVE"
    )

    # The LND volume can be written from inside BTCPay's containers: a folder there replaced by a
    # link would get these ACLs on the link's target (setfacl follows links). Refused instead.
    for dir in "${watched[@]}"; do
        if ! sudo test -d "$dir"; then
            log_message "$(T "❌ LND folder does not exist: %s" "$dir")"
            return 1
        fi
        if [[ "$(sudo realpath -m -- "$dir")" != "$(realpath -m -s -- "$dir")" ]]; then
            log_message "$(T "❌ %s, or a folder above it, is a symlink: no ACLs set there" "$dir")"
            return 1
        fi
    done

    # Collect the parents of LND_BACKUP_ARCHIVE, closest first
    dir=$(dirname "$LND_BACKUP_ARCHIVE")
    while [[ "$dir" != "/" ]]; do
        parents+=("$dir")
        dir=$(dirname "$dir")
    done

    # Walk from / downwards, so each test only fails on the folder that actually blocks
    for (( i=${#parents[@]}-1; i>=0; i-- )); do
        dir="${parents[i]}"
        if ! sudo -u "$SERVER_A_USER" test -x "$dir"; then
            sudo setfacl -P -m "u:$SERVER_A_USER:x" "$dir" || return 1
            log_message "$(T "🔑 Added x ACL for %s on %s" "$SERVER_A_USER" "$dir")"
        fi
    done

    for dir in "${watched[@]}"; do
        sudo setfacl -P -m "u:$SERVER_A_USER:rx" "$dir" || return 1
        log_message "$(T "🔑 Added rx ACL for %s on %s" "$SERVER_A_USER" "$dir")"
    done

    # Verify: exit code 2 = timeout (watch was set up), 0 = event seen, 1 = watch failed
    for dir in "${watched[@]}"; do
        rc=0
        sudo -u "$SERVER_A_USER" inotifywait -qq -t 1 -e create "$dir" || rc=$?
        if (( rc == 1 )); then
            log_message "$(T "❌ %s still cannot watch %s" "$SERVER_A_USER" "$dir")"
            return 1
        fi
    done

    log_message "$(T "✅ %s can watch the LND folders" "$SERVER_A_USER")"
}

if ! grant_inotify_acls; then
    log_message "$(T "❌ Failed to set up inotify access for %s" "$SERVER_A_USER")"
    exit 1
fi

# The test mode file ($TEST_INOTIFY_CONFIG) belongs to SERVER_A_USER, so the installer never
# sources it: whoever had that account would get code run as the installer's user (or root,
# when lnd-wallet.sh reinstalls). The mode is asked again below; only the service reads the file.

# === Trap Error and Log Line Number ===
trap '
rc=$?
log_message "❌ ERR line=$LINENO rc=$rc cmd=$BASH_COMMAND"
' ERR

if [[ "$TO_VOLUME" == yes ]]; then
# === Validate ATTACHED_VOLUME ===
if [[ -z "$ATTACHED_VOLUME" || "$ATTACHED_VOLUME" == "/" ]]; then
    log_message "$(T "❌ Refusing to operate on invalid ATTACHED_VOLUME: %s" "$ATTACHED_VOLUME")"
    exit 1
fi

# === Check if ATTACHED_VOLUME exists ===
if [ ! -d "$ATTACHED_VOLUME" ]; then
    log_message "$(T "❌ ATTACHED_VOLUME does not exist: %s" "$ATTACHED_VOLUME")"
    exit 1
fi

# === Check if ATTACHED_VOLUME mount exists ===
if ! attached_volume_ok; then
    log_message "$(T "❌ The attached volume (UUID %s) is not mounted at %s" "$UUID" "$ATTACHED_VOLUME")"
    exit 1
fi

# The disk's root belongs to root, so the backup user can't make its folder there itself.
# Inside a root-owned folder nobody else can swap it for a symlink.
if [[ ! -d "$SECOND_BACKUP_DIR" ]]; then
    sudo install -d -o "$SERVER_A_USER" -g "$SERVER_A_USER" -m 700 "$SECOND_BACKUP_DIR"
    log_message "$(T "📁 Created %s for %s" "$SECOND_BACKUP_DIR" "$SERVER_A_USER")"
fi
fi

# === Stop Existing Service if Exists === #
# Not at boot (lnd-update-boot.service): the service hasn't started yet, and a stop would cancel
# the start systemd has queued for after this step
if [[ "${LND_UPDATE_AT_BOOT:-}" != 1 ]] && ! sudo systemctl stop "$RSYNC_BACKUP_SERVICE_NAME"; then
    log_message "$(T "⚠️ Failed to stop service (may not exist or already stopped)")"
fi

# === Clear Directories Prompt ===
# Without a terminal (a reinstall reusing the confirmed safe folders), backups are kept: they are
# never deleted without a person saying so. read would fail there and stop the installer with
# the service stopped.
if [[ -t 0 ]]; then
    echo
    say "⚠️  The existing backups can be deleted now: everything in %s" "$( [[ "$TO_VOLUME" == yes ]] && echo "$SECOND_BACKUP_DIR" || echo "-")"
    say "   and in %s. The wallet safety backups in" "$TMP_BACKUP_DIR"
    say "   %s are kept. Server B's copies aren't touched." "${PRE_RECOVERY_DIR:-$(T "the pre-recovery folder")}"
    say "   Usually you keep them: they are your only copies of older wallet states."
    read -rp "$(T "Type DELETE ALL BACKUPS to delete them, or press Enter to keep them: ")" CLEAR_ANSWER || CLEAR_ANSWER=""
    if [[ "$CLEAR_ANSWER" == "DELETE ALL BACKUPS" ]]; then
        CLEAR_DIRECTORIES=y
    else
        CLEAR_DIRECTORIES=n
    fi
else
    log_message "$(T "ℹ️ No terminal: keeping existing backups")"
    CLEAR_DIRECTORIES=n
fi

# Check user input
if [[ "$CLEAR_DIRECTORIES" =~ ^[Yy]$ ]]; then
    log_message "$(T "⛔ Clearing attached volume and temporary backup directory...")"

    # The backups belong to SERVER_A_USER, and folders the service makes later have no ACL for
    # the user running this installer, so they are deleted as SERVER_A_USER. Whatever can't be
    # deleted is listed and left, and the install goes on: stopping here would leave the
    # service stopped.
    SAFE_DELETE_AS="$SERVER_A_USER"
    CLEAR_FAILED=()

    # === Clear the backups on the attached volume ===
    # Only inside SECOND_BACKUP_DIR: the rest of the disk (its root belongs to root) isn't the
    # backups'. The wallet safety backups lnd-wallet.sh makes before changing the wallet are kept.
	if [[ "$TO_VOLUME" == yes ]] && [ -d "$SECOND_BACKUP_DIR" ]; then
	    log_message "$(T "🧹 Clearing the backups in %s..." "$SECOND_BACKUP_DIR")"
	    PRE_RECOVERY_REAL=""
	    if [[ -n "${PRE_RECOVERY_DIR:-}" && -d "$PRE_RECOVERY_DIR" ]]; then
	        PRE_RECOVERY_REAL=$(realpath -m "$PRE_RECOVERY_DIR")
	        log_message "$(T "🔒 Keeping the wallet safety backups in %s" "$PRE_RECOVERY_DIR")"
	    fi
	    while IFS= read -r -d '' f; do
	        [[ -n "$PRE_RECOVERY_REAL" && "$(realpath -m "$f")" == "$PRE_RECOVERY_REAL" ]] && continue
	        safe_delete "$f" || CLEAR_FAILED+=("$f")
	    done < <(sudo find "$SECOND_BACKUP_DIR" -mindepth 1 -maxdepth 1 -print0)
	elif [[ "$TO_VOLUME" == yes ]]; then
	    log_message "$(T "⚠️ No backups folder on the attached volume: %s" "$SECOND_BACKUP_DIR")"
	fi

    # === Clear TMP_BACKUP_DIR contents safely ===
    if [ -d "$TMP_BACKUP_DIR" ]; then
        safe_delete "$TMP_BACKUP_DIR" || CLEAR_FAILED+=("$TMP_BACKUP_DIR")
    else
        log_message "$(T "⚠️ Temporary backup directory does not exist: %s" "$TMP_BACKUP_DIR")"
    fi

    SAFE_DELETE_AS=""
    if (( ${#CLEAR_FAILED[@]} > 0 )); then
        log_message "$(T "⚠️ %s item(s) could not be deleted and were left in place:" "${#CLEAR_FAILED[@]}")"
        for f in "${CLEAR_FAILED[@]}"; do
            log_message "⚠️   $f"
        done
        log_message "$(T "⚠️ The install goes on; delete them by hand if you need them gone.")"
    fi

else
    log_message "$(T "✔️ Skipping directory clearing.")"
fi

# === Ensure safe removal of old test config ===
# As SERVER_A_USER, who owns it: as anyone else a symlink there could redirect the delete
if [[ -n "${TEST_INOTIFY_CONFIG:-}" ]] && sudo -u "$SERVER_A_USER" test -e "$TEST_INOTIFY_CONFIG"; then
    SAFE_DELETE_AS="$SERVER_A_USER"
    safe_delete "$TEST_INOTIFY_CONFIG" || log_message "$(T "⚠️ Could not remove the old %s" "$TEST_INOTIFY_CONFIG")"
    SAFE_DELETE_AS=""
fi

# === No docker group access to the unencrypted archives ===
# Older versions of setup_script.sh gave the docker group access to TMP_BACKUP_DIR, where the
# service makes its unencrypted archives. Not through a symlink: as root that would change the
# target's ACLs.
if [[ -d "$TMP_BACKUP_DIR" && ! -L "$TMP_BACKUP_DIR" ]]; then
    sudo setfacl -P -R -x g:docker "$TMP_BACKUP_DIR" 2>/dev/null || true
    sudo setfacl -P -d -x g:docker "$TMP_BACKUP_DIR" 2>/dev/null || true
fi

# === Ensure the test parent folder exists safely ===
if [[ -n "${TEST_INOTIFY_PARENT_FOLDER:-}" ]]; then
    if ! sudo -u "$SERVER_A_USER" mkdir -p -- "$TEST_INOTIFY_PARENT_FOLDER"; then
        log_message "$(T "❌ Failed to create TEST_INOTIFY_PARENT_FOLDER")"
        exit 1
    fi

    if ! sudo -u "$SERVER_A_USER" mkdir -p -- "$TEST_INOTIFY_FOLDER"; then
        log_message "$(T "❌ Failed to create TEST_INOTIFY_FOLDER")"
        exit 1
    fi
fi

# === Test mode for the inotify watcher (--test-mode, tests only) ===
if [[ "$ENABLE_TEST_MODE" == y ]]; then
    INOTIFY_MODE="test"
else
    INOTIFY_MODE="real"
fi

# Write mode to config safely
if [[ -n "${TEST_INOTIFY_CONFIG:-}" ]]; then
    sudo -u "$SERVER_A_USER" bash -c '
        printf "%s\n" "INOTIFY_MODE=\"$1\"" > "$2"
    ' _ "$INOTIFY_MODE" "$TEST_INOTIFY_CONFIG"

    log_message "$(T "ℹ️ Inotify test mode set to: %s (config: %s)" "$INOTIFY_MODE" "$TEST_INOTIFY_CONFIG")"
fi

# === Backup Script ===
log_message "$(T "📄 Creating rsync-folder-mirror script at %s..." "$RSYNC_FOLDER_MIRROR_SYSTEMD_SCRIPT_PATH")"
# The service runs from /usr/local/bin, so the config's path is written into it here.
SERVICE_TMP=$(mktemp)
{
    echo '#!/bin/bash'
    echo '# Generated by rsync_gpg_backup.sh. Do not edit; rerun the installer instead.'
    printf 'CONFIG_FILE=%q\n' "$CONFIG_FILE"
    printf 'SAFE_BASES+=(%q)\n' "${SAFE_BASES[@]}"
    cat <<'EOF'
set -eEuo pipefail
# Nothing this service makes needs to be readable by anyone else (the status file is made 644 on
# purpose). Unencrypted archives get mode 600 anyway, see perform_backup.
umask 077

MAIN_PID=$$

# === CONFIG ===
# CONFIG_FILE is set at the top by the installer. Without config every path would be
# empty, so stop rather than let the service act on the wrong files.
if [ -z "${CONFIG_FILE:-}" ] || [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Configuration file not found at ${CONFIG_FILE:-<not set>}. Rerun rsync_gpg_backup.sh."
    exit 1
fi
if ! source "$CONFIG_FILE"; then
    echo "❌ Failed to load $CONFIG_FILE"
    exit 1
fi
# Messages and the log in config's language (i18n.sh and locale/, root's, next to config)
if ! source "$(dirname -- "$CONFIG_FILE")/i18n.sh"; then
    echo "❌ Failed to load $(dirname -- "$CONFIG_FILE")/i18n.sh. Rerun rsync_gpg_backup.sh."
    exit 1
fi
i18n_load "$(dirname -- "$CONFIG_FILE")/locale"
# === Where the backups go (config: BACKUP_TO_*, lnd-manager: /destinations) ===
TO_VOLUME="${BACKUP_TO_VOLUME:-yes}" TO_SERVER_B="${BACKUP_TO_SERVER_B:-yes}" TO_GITHUB="${BACKUP_TO_GITHUB:-no}"
GITHUB_PENDING_FILE="${BACKUP_METADATA_FOLDER}/github_pending"
# A backup waiting for a retry when there is no copy on the attached volume to retry from
OUTBOX_DIR="${BACKUP_METADATA_FOLDER}/outbox"

# === Logging Function ===
log_message() {
    local message="${1:-'Default message'}"
    # Messages can carry text from Server B (ssh errors, rsync output): no control characters,
    # so nothing can fake log lines or send escape codes to whoever reads the log
    message="${message//[[:cntrl:]]/?}"
    local timestamped="[$(date --iso-8601=seconds)] $message"

    # stdout is ONLY for logs (not event stream)
    echo "$timestamped" >&2

    # The dashboard shows the last error, and for a failed backup its first error (the cause;
    # later ones like "Backup failed" only follow from it)
    if [[ "$message" == "❌"* ]]; then
        set_status last_error "$message" last_error_time "$(date +%s)" "backup_error?" "$message"
    fi

    # file logging stays separate
    echo "$timestamped" | tee -a "$LIGHTNING_BACKUP_LOG_FILE" > /dev/null
}

# === Status file for the dashboard (lnd-manager.py) ===
# key=value lines that any local user can read; only this service writes them. Writing the
# status must never affect a backup, so every failure here is ignored. Times are epoch seconds.
# STATUS_FILE="" in config turns it off.
STATUS_FILE="${STATUS_FILE-/var/lib/rsync_gpg_backup/status}"

# Usage: set_status key value [key value ...]. An empty value removes the key. A key ending
# in "?" is only set when it has no value yet. The main loop and the hourly check both write,
# so each update rereads and replaces the file under a lock.
set_status() {
    [[ -n "$STATUS_FILE" ]] || return 0
    (
        set +eE
        trap - ERR
        exec 9>>"$STATUS_FILE.lock" || exit 0
        flock -w 5 9 || exit 0

        declare -A status=()
        order=()
        if [[ -f "$STATUS_FILE" ]]; then
            while IFS= read -r line; do
                [[ "$line" == *=* ]] || continue
                key=${line%%=*}
                [[ -n "${status[$key]+set}" ]] || order+=("$key")
                status[$key]=${line#*=}
            done < "$STATUS_FILE"
        fi

        while (( $# >= 2 )); do
            key=$1
            value=${2//[$'\n\r']/ }
            shift 2
            if [[ "$key" == *"?" ]]; then
                key=${key%"?"}
                [[ -n "${status[$key]:-}" ]] && continue
            fi
            [[ "$key" =~ ^[a-z0-9_]+$ ]] || continue
            [[ -n "${status[$key]+set}" ]] || order+=("$key")
            status[$key]=$value
        done

        tmp="$STATUS_FILE.tmp.$BASHPID"
        for key in "${order[@]}"; do
            if [[ -n "${status[$key]}" ]]; then
                printf '%s=%s\n' "$key" "${status[$key]}"
            fi
        done > "$tmp"
        if chmod 644 "$tmp" && mv -f "$tmp" "$STATUS_FILE"; then
            exit 0
        fi
        rm -f "$tmp"
    ) 2>/dev/null || true
}

# Prints one value from the status file (empty if unset)
get_status() {
    [[ -n "$STATUS_FILE" && -f "$STATUS_FILE" ]] || return 0
    sed -n "s/^$1=//p" "$STATUS_FILE" 2>/dev/null | head -n 1 || true
}

# What the service is doing right now, e.g. "backup: encrypting" or "idle"
set_job() {
    set_status job "$1" job_since "$(date +%s)"
}

# Records since when each retry marker exists, and clears it once the marker is gone
update_pending_status() {
    if [[ -f "$REMOTE_PENDING_FILE" ]]; then
        set_status "remote_pending_since?" "$(date +%s)"
    else
        set_status remote_pending_since ""
    fi
    if [[ -f "$MILESTONES_PENDING_FILE" ]]; then
        set_status "milestones_pending_since?" "$(date +%s)"
    else
        set_status milestones_pending_since ""
    fi
    if [[ -f "${GITHUB_PENDING_FILE:-}" ]]; then
        set_status "github_pending_since?" "$(date +%s)"
    else
        set_status github_pending_since ""
    fi
}

# === SSH call wrapper: verbose logging, timing, and stall-context capture ===
# Requires SSH_COMMAND_ARR (array form of the SSH command) to be defined in
# config.
SSH_DEBUG_LOG="$BACKUP_METADATA_FOLDER/ssh_debug.log"
# Longest a single ssh command may take (seconds); config can override it
SSH_TIMEOUT="${SSH_TIMEOUT:-120}"
STALL_CONTEXT_LOG="$BACKUP_METADATA_FOLDER/stall_context.log"

# Usage: run_ssh_debug <remote_cmd> [label] [expected_rc...]
# Exit codes listed as expected (e.g. 1 for "test -f": file not there yet) are
# answers, not failures, so they're returned without the ❌ log line.
run_ssh_debug() {
    local remote_cmd="$1"
    local label="${2:-ssh_call}"
    local expected_rcs=" ${*:3} "

    local err_file
    err_file=$(mktemp)

    local t0 dt rc
    t0=$(date +%s)
    rc=0

    # Server B writes into this log (ssh -v output), so it is kept small
    if [[ -f "$SSH_DEBUG_LOG" ]] && (( $(stat -c %s "$SSH_DEBUG_LOG") > 1048576 )); then
        mv -f "$SSH_DEBUG_LOG" "$SSH_DEBUG_LOG.1"
    fi

    # -v goes to stderr; tee it to the rolling debug log and keep a copy
    # for immediate error logging on failure. "|| rc=$?" keeps this safe
    # under set -e so a failed ssh call doesn't abort the whole script.
    # BatchMode: fail at once if the key is refused instead of trying a password prompt.
    # timeout and heartbeats: a hung or hostile Server B would otherwise hold the call open until
    # the watchdog kills the service, again and again, which stops local backups too.
    run_with_heartbeat - timeout "$SSH_TIMEOUT" "${SSH_COMMAND_ARR[@]}" -o BatchMode=yes -v "$remote_cmd" \
        2> >(tee -a "$SSH_DEBUG_LOG" >"$err_file") || rc=$?

    dt=$(( $(date +%s) - t0 ))
    log_message "$(T "🔍 SSH[%s] took %ss (rc=%s)" "$label" "${dt}" "$rc")"

    if (( rc != 0 )) && [[ "$expected_rcs" != *" $rc "* ]]; then
        log_message "$(T "❌ SSH[%s] failed: %s" "$label" "$(tail -n 5 "$err_file" | tr '\n' ' ')")"
    fi

    # Capture local system state if the call ran unusually long
    if (( dt > 20 )); then
        {
            date
            ss -s
            cat /proc/net/sockstat
        } >> "$STALL_CONTEXT_LOG" 2>&1
    fi

    rm -f "$err_file"
    return $rc
}

update_heartbeat() {

    local now="${1:-$(date +%s)}"

    LAST_HEARTBEAT="$now"

    local interval="${HEARTBEAT_LOG_INTERVAL:-60}"

    if [[ -z "${LAST_HEARTBEAT_LOGGED:-}" ]] || \
       (( now - LAST_HEARTBEAT_LOGGED >= interval )); then
        log_message "$(T "💓 Heartbeat alive")"
        LAST_HEARTBEAT_LOGGED="$now"
    fi

    # Only main process sends watchdog ping
    if [[ -n "${NOTIFY_SOCKET:-}" ]]; then
	    systemd-notify WATCHDOG=1
	fi
}

# === Run a long command while keeping the systemd watchdog fed ===
# WatchdogSec=120 kills the service if no heartbeat arrives for 120 seconds, so
# rsync/scp must not run in the foreground without heartbeats.
# Usage: run_with_heartbeat <output_file|-> <command...>
# Output goes to <output_file>, or stays on stdout/stderr when it is "-".
# Returns the command's exit status.
run_with_heartbeat() {
    local output_file="$1"
    shift
    local pid rc=0
    local last_beat=$SECONDS

    if [[ "$output_file" == "-" ]]; then
        "$@" &
    else
        "$@" >"$output_file" 2>&1 &
    fi
    pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        if (( SECONDS - last_beat >= 10 )); then
            update_heartbeat
            last_beat=$SECONDS
        fi
        sleep 1
    done

    wait "$pid" || rc=$?
    return "$rc"
}

is_safe_path_ref() {
    local p="$1"

    # reject absolute paths immediately
    [[ "$p" == /* ]] && return 1

    # base directory we consider "safe root"
    local root="."

    # resolve full canonical path after applying tar entry
    local full_path
    full_path="$(realpath -m "$root/$p" 2>/dev/null)" || return 1

    local root_path
    root_path="$(realpath -m "$root")" || return 1

    # ensure resulting path is inside root
    [[ "$full_path" == "$root_path"* ]]
}

is_safe_path_abs() {
    local p="$1"
    local safe_root="${2:-$SAFE_ROOT}"

    # reject empty input
    [[ -z "$p" ]] && return 1

    # resolve safe root
    local root_path
    root_path="$(realpath -m "$safe_root" 2>/dev/null)" || return 1

    # resolve target path
    local full_path
    full_path="$(realpath -m "$p" 2>/dev/null)" || return 1

    # reject root filesystem escape
    [[ "$full_path" == "/" ]] && return 1

    # enforce containment
    [[ "$full_path" == "$root_path" || "$full_path" == "$root_path/"* ]]
}

# Safe folders: safe_delete only removes paths inside these. The installer writes them at the
# top of this script from the list confirmed at install time.
if [[ -z "${SAFE_BASES[*]:-}" ]]; then
    log_message "$(T "❌ No safe folders in this script. Rerun rsync_gpg_backup.sh.")"
    exit 1
fi

# === Check that a path falls under one of the SAFE_BASES ===
is_under_safe_bases() {
    local real_target base real_base
    real_target=$(realpath -m "$1" 2>/dev/null) || return 1

    for base in "${SAFE_BASES[@]}"; do
        [[ -z "$base" ]] && continue
        real_base=$(realpath -m "$base" 2>/dev/null) || continue
        case "$real_target" in
            "$real_base" | "$real_base"/*)
                return 0
                ;;
        esac
    done

    return 1
}

# True when the disk with config's UUID is mounted exactly at ATTACHED_VOLUME, and that path is
# not a symlink. mountpoint -q follows symlinks and doesn't look at which disk it is.
attached_volume_ok() {
    [[ -n "${UUID:-}" && -d "$ATTACHED_VOLUME" && ! -L "$ATTACHED_VOLUME" ]] || return 1
    [[ "$(findmnt -rn -M "$ATTACHED_VOLUME" -o UUID 2>/dev/null)" == "$UUID" ]]
}

# === Safe Delete: files or directories ===
safe_delete() {
    local TARGET
    local FILE=""
    local DIR=""

    # --- Support both call styles ---
    if [[ $# -eq 1 ]]; then
        TARGET="$1"
    elif [[ $# -eq 2 ]]; then
        DIR="$1"
        FILE="$2"
        TARGET="$DIR/$FILE"
    else
        log_message "$(T "❌ Invalid safe_delete usage")"
        return 1
    fi

    # 🚨 Reject empty TARGET
    if [[ -z "$TARGET" ]]; then
        log_message "$(T "❌ Unsafe path: empty target")"
        return 1
    fi

    # Resolve real path
    local REAL_TARGET
    REAL_TARGET=$(realpath -m "$TARGET" 2>/dev/null || echo "")

    if [[ -z "$REAL_TARGET" ]]; then
        log_message "$(T "❌ Failed to resolve path: %s" "$TARGET")"
        return 1
    fi

    # 🚨 Hard safety checks
    if [[ "$REAL_TARGET" == "/" || "$REAL_TARGET" == "." || "$REAL_TARGET" == ".." ]]; then
        log_message "$(T "❌ Unsafe path: %s" "$REAL_TARGET")"
        return 1
    fi

    # 🚨 Ensure target is within allowed bases
    if ! is_under_safe_bases "$REAL_TARGET"; then
        log_message "$(T "❌ Refusing to delete outside safe bases: %s" "$REAL_TARGET")"
        return 1
    fi

    # Ensure ATTACHED_VOLUME is actually mounted
    # Compared with the resolved path: a symlink or trailing slash in config would skip the check
    local ATTACHED_REAL
    ATTACHED_REAL=$(realpath -m -- "$ATTACHED_VOLUME")
    if [[ "$REAL_TARGET" == "$ATTACHED_REAL" || "$REAL_TARGET" == "$ATTACHED_REAL"/* ]]; then
        if ! attached_volume_ok; then
            log_message "$(T "❌ Refusing delete: the attached volume (UUID %s) is not mounted at %s" "$UUID" "$ATTACHED_VOLUME")"
            return 1
        fi
    fi

    # Ensure target exists
    if [[ ! -e "$REAL_TARGET" ]]; then
        log_message "$(T "⚠️ Target not found: %s" "$REAL_TARGET")"
        return 0
    fi

    # Perform deletion
    if rm -rf --one-file-system --preserve-root -- "$REAL_TARGET"; then
        log_message "$(T "🗑️ Safely removed: %s" "$REAL_TARGET")"
    else
        log_message "$(T "❌ Failed to remove: %s" "$REAL_TARGET")"
        return 1
    fi
}

# === Ensure SAFE_BASES cover the configured paths ===
REQUIRED_PATHS=("$TMP_BACKUP_DIR" "$BACKUP_METADATA_FOLDER" "$TEST_INOTIFY_PARENT_FOLDER")
[[ "$TO_VOLUME" == yes ]] && REQUIRED_PATHS+=("$ATTACHED_VOLUME")
for required_path in "${REQUIRED_PATHS[@]}"; do
    if ! is_under_safe_bases "$required_path"; then
        log_message "$(T "❌ %s is not under any SAFE_BASES entry" "$required_path")"
        log_message "$(T "❌ Rerun rsync_gpg_backup.sh and include it in the safe folders")"
        exit 1
    fi
done

# Server B only accepts the commands of its backup gate (server-b-install.sh): put, get, list,
# ping. Nothing here can delete or overwrite there; Server B rotates and makes the milestones
# itself. This checks that the gate answers.
validate_remote_backup_location() {
    local answer
    update_heartbeat
    if ! answer=$(run_ssh_debug "ping" "gate_ping"); then
        log_message "$(T "❌ Server B's backup gate didn't answer")"
        return 1
    fi
    update_heartbeat
    if [[ "$answer" != "ok" ]]; then
        log_message "$(T "❌ Server B answered without its backup gate. Install it there: server-b-install.sh")"
        return 1
    fi
}

# === Source Test Mode Variable ===
if [[ -f "$TEST_INOTIFY_CONFIG" ]]; then
    source "$TEST_INOTIFY_CONFIG"
    log_message "$(T "🧪 Loaded test config: %s" "$TEST_INOTIFY_CONFIG")"
fi

# === Global Lock Setup ===

# Open the lock file as FD 200
exec 200>"$LOCK_FILE"

# Try to acquire the lock, exit if another process holds it
if ! flock -n 200; then
    log_message "$(T "❌ Another backup process is already running. Exiting.")"
    exit 1
fi

log_message "$(T "🔒 Global lock acquired (PID %s)" "$$")"

# === Check PID Alive ===
check_pid_alive() {
    local pid="$1"
    local name="${2:-process}"

    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        log_message "$(T "❌ %s (PID %s) died unexpectedly" "$name" "$pid")"
        return 1
    fi

    return 0
}

# === Remove a backup's working files (plaintext copies included) ===
# Runs when perform_backup returns (success or failure) and from cleanup(),
# so no unencrypted copy is left in TMP_BACKUP_DIR.
cleanup_backup_workdirs() {
    local path

    for path in "${LND_TMP_BACKUP:-}" "${TIMESTAMPED_BACKUP:-}" "${TAR_FILE:-}" \
                "${CHECKSUM_FILE:-}" "${GPG_PAYLOAD:-}" "${MANIFEST_FILE:-}" "${TMP_VERIFY_DIR:-}" \
                "${ENCRYPTED_FILE:-}"; do
        [[ -n "$path" && -e "$path" ]] || continue
        if ! safe_delete "$path"; then
            log_message "$(T "❌ Failed to remove backup working file: %s" "$path")"
        fi
    done

    # Forget the paths, so a later cleanup cannot touch another run's files
    LND_TMP_BACKUP=""
    TIMESTAMPED_BACKUP=""
    TAR_FILE=""
    CHECKSUM_FILE=""
    GPG_PAYLOAD=""
    MANIFEST_FILE=""
    TMP_VERIFY_DIR=""
    ENCRYPTED_FILE=""
}

# === Global Cleanup ===
cleanup() {
    set +e  # prevent cleanup from masking original failure
    # Failures here are expected (e.g. killing a process that already exited). Without this,
    # the ERR trap would log them, and inside a trap bash reports the command that was
    # interrupted, so the log line would blame unrelated code.
    trap - ERR

    # === Release global lock if held ===
    if [[ -n "${LOCK_FILE:-}" ]]; then
        log_message "$(T "🔓 Releasing global lock on %s" "$LOCK_FILE")"
        exec 200>&-   # Close lock FD 200
    fi

    # === Kill inotify watcher if running ===
    [[ -n "${INOTIFY_PID:-}" ]] && kill "$INOTIFY_PID" 2>/dev/null
    
    # === Kill hash changer background process if running ===
    [[ -n "${HASH_CHANGER_PID:-}" ]] && kill "$HASH_CHANGER_PID" 2>/dev/null
    
    # === Kill Reconciliation loop process if running ===
    [[ -n "${RECON_PID:-}" ]] && kill "$RECON_PID" 2>/dev/null

    # === Remove the working files of a backup that was interrupted ===
    cleanup_backup_workdirs

    set_job "stopped"
}

# === Set EXIT Trap ONCE ===
# The signal traps must exit. A signal trap that only runs cleanup lets bash carry on
# where it was interrupted. exit fires the EXIT trap, so cleanup runs exactly once.
trap cleanup EXIT
trap 'exit 143' SIGTERM
trap 'exit 130' SIGINT
trap - SIGCHLD
# "Check now" (systemctl kill -s SIGUSR1 --kill-whom=main): pass it to the hourly-check loop.
# Before that loop runs, the signal is ignored instead of stopping the service.
trap 'if [[ -n "${RECON_PID:-}" ]]; then kill -USR1 "$RECON_PID" 2>/dev/null || true; fi' SIGUSR1

# === Trap ERRORS for logging ===
trap '
rc=$?
log_message "❌ ERR line=$LINENO rc=$rc cmd=$BASH_COMMAND"
' ERR

# === The destinations: at least one on, and the GitHub code if GitHub is ===
if [[ "$TO_VOLUME" != yes && "$TO_SERVER_B" != yes && "$TO_GITHUB" != yes ]]; then
    log_message "$(T "❌ No backup destination is on (BACKUP_TO_VOLUME, BACKUP_TO_SERVER_B, BACKUP_TO_GITHUB in config): lnd-manager /destinations")"
    exit 1
fi
if [[ "$TO_GITHUB" == yes ]]; then
    if ! source "$(dirname -- "$CONFIG_FILE")/github-lib.sh"; then
        log_message "$(T "❌ Failed to load %s. Rerun rsync_gpg_backup.sh." "$(dirname -- "$CONFIG_FILE")/github-lib.sh")"
        exit 1
    fi
    if [[ -z "${GITHUB_REPO:-}" ]]; then
        log_message "$(T "❌ BACKUP_TO_GITHUB is yes but GITHUB_REPO is empty: run setup (lnd-manager: /setup)")"
        exit 1
    fi
fi

if [[ "$TO_VOLUME" == yes ]]; then
# === Validate ATTACHED_VOLUME ===
if [[ -z "$ATTACHED_VOLUME" || "$ATTACHED_VOLUME" == "/" ]]; then
    log_message "$(T "❌ Refusing to operate on invalid ATTACHED_VOLUME: %s" "$ATTACHED_VOLUME")"
    exit 1
fi

# === Check if ATTACHED_VOLUME exists ===
if [ ! -d "$ATTACHED_VOLUME" ]; then
    log_message "$(T "❌ ATTACHED_VOLUME does not exist: %s" "$ATTACHED_VOLUME")"
    exit 1
fi

# === Check if ATTACHED_VOLUME mount exists ===
if ! attached_volume_ok; then
    log_message "$(T "❌ The attached volume (UUID %s) is not mounted at %s" "$UUID" "$ATTACHED_VOLUME")"
    exit 1
fi
fi

# === Remove working files left behind by a killed run ===
# A SIGKILL (for example from the watchdog) skips every trap. The global lock above
# guarantees no backup is running, so anything matching these names is a leftover.
if [[ -d "$TMP_BACKUP_DIR" ]]; then
    shopt -s nullglob
    for leftover in "$TMP_BACKUP_DIR"/backup_* "$TMP_BACKUP_DIR"/gpg_payload.tar "$TMP_BACKUP_DIR"/manifest \
                    "$TMP_BACKUP_DIR"/verify_* "$TMP_BACKUP_DIR"/encrypted_backup_*.gpg; do
        [[ -e "$leftover" ]] || continue
        if ! safe_delete "$leftover"; then
            log_message "$(T "❌ Failed to remove leftover backup file: %s" "$leftover")"
        fi
    done
    shopt -u nullglob
fi

# === Folder to watch ===
FOLDER_TO_WATCH=(
    "$LND_BACKUP_ARCHIVE"
)

# === Files To Backup List ===
# Keep in step with HELPER_FILES in the installer: the root helper opens only those
FILES_TO_BACKUP=(
    "$LND_DIR/data/chain/bitcoin/mainnet/chainnotifier.macaroon"
    "$LND_DIR/data/chain/bitcoin/mainnet/invoices.macaroon"
    "$LND_DIR/data/chain/bitcoin/mainnet/router.macaroon"
    "$LND_DIR/data/chain/bitcoin/mainnet/wallet.db"
    "$LND_DIR/data/chain/bitcoin/mainnet/walletunlock.json"
    "$LND_DIR/data/chain/bitcoin/mainnet/channel.backup"
    "$LND_DIR/data/chain/bitcoin/mainnet/macaroons.db"
    "$LND_DIR/data/chain/bitcoin/mainnet/signer.macaroon"
    "$LND_DIR/data/chain/bitcoin/mainnet/walletkit.macaroon"
    "$LND_DIR/admin.macaroon"
    "$LND_DIR/invoice.macaroon"
    "$LND_DIR/lnd.conf"
    "$LND_DIR/readonly.macaroon"
    "$LND_DIR/tls.cert"
    "$LND_DIR/tls.key"
    "$LND_DIR/walletunlock.json"
)
# Files LND rewrites by itself while it runs: wallet.db with every new block, macaroons.db when
# LND starts. They go into every backup, but a change in them alone is no reason for one: the
# hourly check would then back up every hour, and the 10 newest backups would push out the one
# made at the last channel change within hours. Recovery uses the seed and channel.backup.
SELF_CHANGING_FILES=(
    "$LND_DIR/data/chain/bitcoin/mainnet/wallet.db"
    "$LND_DIR/data/chain/bitcoin/mainnet/macaroons.db"
)

# === Root-only LND files are read through the root-owned helper ===
# sudoers allows SERVER_A_USER to run only this helper as root.
LND_HELPER=(sudo -n "$LND_BACKUP_HELPER_PATH")

is_lnd_path() {
    case "$1" in
        "$LND_DIR"/*) return 0 ;;
        *) return 1 ;;
    esac
}

# Regular-file check that also works for root-only LND files
file_exists() {
    if is_lnd_path "$1"; then
        "${LND_HELPER[@]}" test-file "$1" 2>/dev/null
    else
        [[ -f "$1" ]]
    fi
}

hash_file() {
    local file="$1"
    local output

    if is_lnd_path "$file"; then
        "${LND_HELPER[@]}" hash "$file"
        return
    fi

    if ! output=$(xxhsum -H128 "$file"); then
        return 1
    fi

    # parse without pipe
    set -- $output
    echo "$1"
}

verify_copy_stability() {
    local src_files=("$@")
    local stable=true

    log_message "$(T "🔍 Verifying copy stability...")"

    for src in "${src_files[@]}"; do

        # === DEBUG: verify temp dir still exists ===
        if [[ ! -d "$LND_TMP_BACKUP" ]]; then
            log_message "$(T "❌ Temp dir vanished before processing file: %s" "$LND_TMP_BACKUP")"
            ls -ld "$LND_TMP_BACKUP" >&2 || true
            return 1
        fi

        rel="${src#$LND_DIR/}"
		copy="$LND_TMP_BACKUP/$rel"
		mkdir -p "$(dirname "$copy")"

        # === DEBUG: verify destination path exists ===
        if [[ ! -d "$LND_TMP_BACKUP" ]]; then
            log_message "$(T "❌ Temp dir missing right before copy: %s" "$LND_TMP_BACKUP")"
            return 1
        fi

        # File existence check
        if ! file_exists "$src" || [[ ! -f "$copy" ]]; then
            log_message "$(T "❌ Missing file during verification: %s" "$src")"
            return 1
        fi

        # Hash checks
        hash1=$(hash_file "$src")
        sleep 0.2
        hash2=$(hash_file "$src")
        hash_copy=$(hash_file "$copy")

        if [[ "$hash1" != "$hash2" ]]; then
            log_message "$(T "⚠️ Source changed during read: %s" "$src")"
            stable=false
            continue
        fi

        if [[ "$hash1" != "$hash_copy" ]]; then
            log_message "$(T "❌ Copy mismatch: %s" "$src")"
            stable=false
            continue
        fi

        log_message "$(T "✅ Verified: %s" "$src")"
    done

    $stable
}

verify_copied_hashes() {

    local files=("$@")

    for file in "${files[@]}"; do
	    if ! file_exists "$file"; then
	        log_message "$(T "❌ Cannot access file (missing or permission denied): %s" "$file")"
	        return 1
	    fi

        local original_hash="${COPY_VERIFY_HASHES[$file]:-}"
        if [[ -z "$original_hash" ]]; then
            log_message "$(T "❌ Missing original hash for %s" "$file")"
            return 1
        fi

        local rel
		rel="${file#$LND_DIR/}"
		local copied_file="$LND_TMP_BACKUP/$rel"

        if [[ ! -f "$copied_file" ]]; then
            log_message "$(T "❌ Copied file missing: %s" "$copied_file")"
            return 1
        fi

        local copied_hash
        if ! copied_hash=$(hash_file "$copied_file"); then
            log_message "$(T "❌ Failed to hash copied file: %s" "$copied_file")"
            return 1
        fi

        if [[ "$copied_hash" != "$original_hash" ]]; then
            log_message "$(T "❌ Hash mismatch after rsync:")"
            log_message "$(T "   Source: %s" "$file")"
            log_message "$(T "   Copy:   %s" "$copied_file")"
            return 1
        fi
    done

    log_message "$(T "✅ Copied file hash verification passed")"
    return 0
}

# === File change simulator for test mode ===
start_hash_changer() {
    local test_file="$TEST_HASH_TARGET_FILE"
    local test_dir
    test_dir="$(dirname "$test_file")"

    # Ensure the parent directory exists
    if [[ ! -d "$test_dir" ]]; then
        log_message "$(T "📁 Creating test directory: %s" "$test_dir")"
        mkdir -p "$test_dir"
    fi

    # Ensure the test file exists
    if [[ ! -f "$test_file" ]]; then
        echo "Initial test hash target file created at $(date)" > "$test_file"
    fi

    # Run in background and track PID globally
    (
        set -eEuo pipefail
        trap 'echo "❌ start_hash_changer failed at line $LINENO"' ERR

        while true; do
            echo "Test modification at $(date +%s)" >> "$test_file"
            sleep 60
        done
    ) &

    # Track PID in global variable for cleanup
    HASH_CHANGER_PID=$!
    log_message "$(T "🟢 start_hash_changer running in background with PID: %s" "$HASH_CHANGER_PID")"
}

# === Redirect $FOLDER_TO_WATCH to $TEST_HASH_TARGET_FILE if in test mode ===
if [[ "${INOTIFY_MODE:-real}" == "test" ]]; then
    FOLDER_TO_WATCH+=("$TEST_HASH_TARGET_FILE")
fi

# === Find latest channel backup ===
find_latest_channel_backup() {
    local latest_backup

    # The helper lists the archive folder as root
    latest_backup=$(
        "${LND_HELPER[@]}" list-archives 2>/dev/null | \
        sort -nr | \
        head -n1 | \
        cut -d' ' -f2-
    )

    # No results
    if [[ -z "$latest_backup" ]]; then
        log_message "$(T "⚠️ No channel backups found in %s" "$LND_BACKUP_ARCHIVE")"
        echo ""
        return 0
    fi

    # Verify file exists (as root, via the helper)
    if ! file_exists "$latest_backup"; then
        log_message "$(T "⚠️ Latest backup exists but is not a valid file: %s" "$latest_backup")"
        echo ""
        return 1
    fi

    # Success
    echo "$latest_backup"
}

# === Build Snapshot ===
build_files_snapshot() {
    local snapshot=()

    # Static files
    for f in "${FILES_TO_BACKUP[@]}"; do
        if file_exists "$f"; then
            snapshot+=("$f")
        fi
    done

    # Dynamic latest channel backup
    local latest_backup
    latest_backup=$(find_latest_channel_backup)

    if [[ -n "$latest_backup" ]] && file_exists "$latest_backup"; then
        snapshot+=("$latest_backup")
    fi

    # Output ONLY valid file paths
    printf "%s\n" "${snapshot[@]}"
}

# === Build Snapshot Fingerprint Suitable For Snapshot Array === 
build_snapshot_fingerprint() {
    local files=("$@")

    # fail fast if empty snapshot
    if (( ${#files[@]} == 0 )); then
        echo ""
        return 1
    fi

    # hash each file, normalize ordering, then fold into final hash
    for f in "${files[@]}"; do
        hash_file "$f" 2>/dev/null || return 1
    done |
        sort |
        xxhsum -H128 |
        awk '{print $1}'
}

# The fingerprint that decides whether something changed that needs a backup: the files given,
# without SELF_CHANGING_FILES. Saved after each backup, compared by the hourly check.
build_change_fingerprint() {
    local f skip kept=()
    for f in "$@"; do
        for skip in "${SELF_CHANGING_FILES[@]}"; do
            [[ "$f" == "$skip" ]] && continue 2
        done
        kept+=("$f")
    done
    build_snapshot_fingerprint "${kept[@]}"
}

wait_for_files_to_settle() {
    set -eEuo pipefail

    local MAX_WAIT=600
    local DEBOUNCE=30
    local HEARTBEAT=15

    local START_TIME last_change_time last_heartbeat now
    local files=("$@")

    START_TIME=$(date +%s)
    last_change_time=$START_TIME
    last_heartbeat=$START_TIME

    # Track frequency of changes per file
    declare -A CHANGE_COUNTS

    log_message "$(T "⏳ Waiting for files to settle (no changes for %s seconds)..." "$DEBOUNCE")"

    # Precompute directories containing files
    local watch_dirs=()
    for f in "${files[@]}"; do
        watch_dirs+=("$(dirname "$f")")
    done

    # Remove duplicates
    mapfile -t watch_dirs < <(printf "%s\n" "${watch_dirs[@]}" | sort -u)

    # Ensure all files exist before starting monitoring
    for file in "${files[@]}"; do
	    local wait_start=$(date +%s)
	
	    while ! file_exists "$file"; do
	        if (( $(date +%s) - wait_start > MAX_WAIT )); then
	            log_message "$(T "❌ File never appeared: %s" "$file")"
	            return 1
	        fi
	        log_message "$(T "⏳ Waiting for file to exist: %s" "$file")"
	        sleep 5
	    done
	done

    # === Main loop (non-blocking, cannot hang) ===
    while true; do
        now=$(date +%s)

        # === Timeout check ===
        if (( now - START_TIME > MAX_WAIT )); then
            log_message "$(T "❌ Timeout waiting for files to settle (%ss exceeded)" "${MAX_WAIT}")"
            for f in "${!CHANGE_COUNTS[@]}"; do
                log_message "$(T "⚠️ File flapping: %s (changes: %s)" "$f" "${CHANGE_COUNTS[$f]}")"
            done
            return 1
        fi

        # === Non-blocking inotify check (1s window) ===
        changed_file="$(
		    inotifywait -q -e modify,create,delete,move,close_write \
		    --format '%w%f' -t 1 "${watch_dirs[@]}" 2>/dev/null
		)" || true
		
		if [[ -n "${changed_file:-}" ]]; then

            # Only track relevant files
            local relevant=false
            for f in "${files[@]}"; do
                if [[ "$changed_file" == "$f" ]]; then
                    relevant=true
                    break
                fi
            done

            if $relevant; then
			    # not ((x++)): an unset key fails under set -u, and 0 returns 1 under set -e
			    CHANGE_COUNTS["$changed_file"]=$(( ${CHANGE_COUNTS["$changed_file"]:-0} + 1 ))
			    last_change_time=$now
			    log_message "$(T "🌀 Relevant file change detected: %s (count=%s)" "$changed_file" "${CHANGE_COUNTS["$changed_file"]}")"
			else
			    log_message "$(T "⏩ Ignoring unrelated file: %s" "$changed_file")"
			fi
        fi

        # === Heartbeat logging ===
		if (( now - last_heartbeat >= HEARTBEAT )); then
		    log_message "$(T "⏳ Waiting for files to settle...")"
		    update_heartbeat
		    last_heartbeat=$now
		fi

        # === Debounce condition (core logic) ===
        if (( now - last_change_time >= DEBOUNCE )); then
            log_message "$(T "✅ Files are stable. Proceeding.")"
            return 0
        fi
    done
}

check_file_hash() {

    local files=("$@")
    local backup_needed=0

    for file in "${files[@]}"; do

        if ! file_exists "$file"; then
            log_message "$(T "⚠️ File missing: %s" "$file")"
            continue
        fi

        local new_hash
        if ! new_hash=$(hash_file "$file"); then
            log_message "$(T "❌ Failed to hash file: %s" "$file")"
            continue
        fi

        local last_hash=""

        if [[ -f "$COMMIT_HASHES_FILE" ]]; then
            last_hash=$(awk -F'|' -v file="$file" '
                $1 == file { print $2; exit }
            ' "$COMMIT_HASHES_FILE")
        fi

        if [[ "$new_hash" != "$last_hash" ]]; then
            log_message "$(T "🔄 Change detected in %s" "$file")"
            backup_needed=1
        else
            log_message "$(T "⏩ No change in %s" "$file")"
        fi
    done

    (( backup_needed )) && return 1 || return 0
}

# Function to commit source hash if backup is completed
commit_file_hashes() {

    local files=("$@")

    # Ensure metadata directory exists
    if ! mkdir -p "$COMMIT_HASHES_FOLDER"; then
        log_message "$(T "❌ Failed to create metadata directory: %s" "$COMMIT_HASHES_FOLDER")"
        return 1
    fi

    # Create temporary file for atomic update
    local tmp_file
    if ! tmp_file=$(mktemp "$COMMIT_HASHES_FOLDER/committed_hashes.tmp.XXXXXX"); then
        log_message "$(T "❌ Failed to create temporary hash file")"
        return 1
    fi

    # Build new hash database
    for file in "${files[@]}"; do

        local new_hash="${STAGED_HASHES[$file]}"

        if [[ -z "$new_hash" ]]; then
            log_message "$(T "❌ Missing staged hash for: %s" "$file")"
            rm -f "$tmp_file"
            return 1
        fi

        if ! printf '%s|%s\n' "$file" "$new_hash" >> "$tmp_file"; then
            log_message "$(T "❌ Failed writing hash entry for: %s" "$file")"
            rm -f "$tmp_file"
            return 1
        fi
    done

    # Atomically replace committed hash database
	if mv "$tmp_file" "$COMMIT_HASHES_FILE"; then
	    log_message "$(T "🧾 Stored updated file hashes")"
	    return 0
	else
	    log_message "$(T "❌ Failed to commit file hashes to %s" "$COMMIT_HASHES_FILE")"
	    rm -f "$tmp_file"
	    return 1
	fi
}

check_disk_space() {

    : "${SERVER_A_USER_HOME:?SERVER_A_USER_HOME not set}"
    : "${ATTACHED_VOLUME:?ATTACHED_VOLUME not set}"

    # === TMP space check (based on SERVER_A_USER_HOME) ===
    local min_required_kb=$((2 * 1024 * 1024))  # 2GB

    local available
    if ! available=$(df -k "$SERVER_A_USER_HOME" | awk 'NR==2 {print $4}'); then
        log_message "$(T "❌ Failed to determine disk space for %s" "$SERVER_A_USER_HOME")"
        return 1
    fi

    if (( available < min_required_kb )); then
        log_message "$(T "❌ Insufficient disk space in %s" "$SERVER_A_USER_HOME")"
        log_message "$(T "Required: %s KB, Available: %s KB" "${min_required_kb}" "${available}")"
        return 1
    else
        log_message "$(T "✅ TMP space check passed (home FS): %s KB available" "${available}")"
    fi


    # === SECOND BACKUP ===
    local min_required_kb=$((200 * 1024))  # 200MB

    local available_attached
    if ! available_attached=$(df -k "$ATTACHED_VOLUME" | awk 'NR==2 {print $4}'); then
        log_message "$(T "❌ Failed to determine disk space for %s" "$ATTACHED_VOLUME")"
        return 1
    fi

    if (( available_attached < min_required_kb )); then
        log_message "$(T "❌ Insufficient disk space in ATTACHED_VOLUME")"
        log_message "$(T "Required: %s KB, Available: %s KB" "${min_required_kb}" "${available_attached}")"
        return 1
    else
        log_message "$(T "✅ ATTACHED_VOLUME space check passed: %s KB available" "${available_attached}")"
    fi
}

should_run_backup() {
    local now
    now=$(date +%s)

    # 1. Debounce (normal operation)
    if (( now - LAST_BACKUP_TS < DEBOUNCE_SECONDS )); then
        log_message "$(T "⏳ Skipping: debounce active")"
        return 1
    fi

    # 2. Failure backoff (only if failures occurred)
    if (( FAILURE_COUNT > 0 )); then
        local cooldown=$(( BASE_COOLDOWN * (2 ** FAILURE_COUNT) ))
        (( cooldown > MAX_COOLDOWN )) && cooldown=$MAX_COOLDOWN

        if (( now - LAST_FAILURE_TS < cooldown )); then
            log_message "$(T "⏳ Skipping: failure cooldown active (%ss)" "${cooldown}")"
            return 1
        fi
    fi

    return 0
}

handle_event() {
    local changed_file="$1"
    local now
    now=$(date +%s)

    LAST_FILE_EVENT_TIME="$now"
    set_status last_event_file "$changed_file" last_event_time "$now"

    log_message "$(T "🌀 Detected change in: %s" "$changed_file")"

    # ✅ Unified gate
    if ! should_run_backup; then
        return
    fi

    # Build snapshot
    mapfile -t CURRENT_FILES < <(build_files_snapshot)

    if (( ${#CURRENT_FILES[@]} == 0 )); then
        log_message "$(T "⚠️ Snapshot empty during event — skipping")"
        return
    fi

    if check_file_hash "${CURRENT_FILES[@]}"; then
        log_message "$(T "⏩ No meaningful changes detected, skipping backup")"
        return
    fi

    log_message "$(T "🚀 Changes confirmed → performing backup...")"

    # Debounce and cooldown count from when the backup ended: a backup can take longer
    # than either, so counting from the event made both expire before it finished.
    if run_backup; then
        log_message "$(T "✅ Backup completed successfully")"
        LAST_BACKUP_TS=$(date +%s)

        # ✅ Reset failure state
        FAILURE_COUNT=0

    else
        log_message "$(T "❌ Backup failed")"

        LAST_FAILURE_TS=$(date +%s)
        FAILURE_COUNT=$(( FAILURE_COUNT + 1 ))   # not ((x++)): that returns 1 when x was 0
    fi
}

load_last_snapshot_hash() {
    if [[ -f "$LAST_SNAPSHOT_HASH_FILE" ]]; then
        cat "$LAST_SNAPSHOT_HASH_FILE"
    else
        echo ""
    fi
}

save_last_snapshot_hash() {
    local hash="$1"
    echo "$hash" > "$LAST_SNAPSHOT_HASH_FILE"
}

start_reconciliation_loop() {
    local interval="${RECON_INTERVAL:-3600}"

    (
        # If this loop is stopped mid-backup, remove that backup's working files.
        # sleep runs in the background so SIGTERM is handled at once, not after the sleep.
        trap cleanup_backup_workdirs EXIT
        trap 'exit 143' SIGTERM
        # SIGUSR1 (from the main process, see its trap) runs the check now instead of after the
        # sleep. It interrupts the wait; a request during a check runs the next check at once.
        CHECK_NOW=false
        trap 'CHECK_NOW=true' SIGUSR1

        while true; do
            if ! $CHECK_NOW; then
                sleep "$interval" &
                wait "$!" || true
                kill "$!" 2>/dev/null || true
            fi
            if $CHECK_NOW; then
                log_message "$(T "▶️ Check requested")"
            fi
            CHECK_NOW=false
            set_job "hourly check"
            set_status check_last_run "$(date +%s)"

            # Catch up on a remote copy that failed earlier
            if ! retry_remote_pending; then
                log_message "$(T "❌ remote_pending retry failed")"
            fi
            if ! retry_github_pending; then
                log_message "$(T "❌ github_pending retry failed")"
            fi

            # Catch up on milestones a backup couldn't create
            if ! retry_milestones_pending; then
                log_message "$(T "❌ milestones_pending retry failed")"
            fi
            update_pending_status

            log_message "$(T "🔎 Running fingerprint reconciliation...")"

            mapfile -t SNAPSHOT < <(build_files_snapshot)

            if (( ${#SNAPSHOT[@]} == 0 )); then
                log_message "$(T "⚠️ Empty snapshot — skipping reconciliation")"
                set_status check_last_result "$(T "skipped: no LND files found")"
                set_job idle
                continue
            fi

            # Compute current fingerprint (without the files LND rewrites by itself). Checked, not
            # a plain statement: under set -e a failure (a file LND replaced just then) would end
            # this whole loop, and the hourly checks with it.
            if ! CURRENT_HASH=$(build_change_fingerprint "${SNAPSHOT[@]}") || [[ -z "$CURRENT_HASH" ]]; then
                log_message "$(T "⚠️ Could not fingerprint LND's files this time (a file changed while being read?): next check in an hour")"
                set_status check_last_result "$(T "skipped: files changed while being read")"
                set_job idle
                continue
            fi

            # Load last known fingerprint
            LAST_HASH=$(load_last_snapshot_hash) || LAST_HASH=""

            if [[ "$CURRENT_HASH" == "$LAST_HASH" ]]; then
                log_message "$(T "✅ No changes detected (fingerprint match)")"
                set_status check_last_result "$(T "no changes")"
                set_job idle
                continue
            fi

            log_message "$(T "🚨 Change detected via fingerprint mismatch")"

            # perform_backup saves the new fingerprint itself after committing the hashes
            if run_backup; then
                log_message "$(T "✅ Reconciliation backup completed")"
                set_status check_last_result "$(T "changes found, backed up")"
            else
                log_message "$(T "❌ Backup failed during reconciliation")"
                set_status check_last_result "$(T "changes found, backup failed")"
            fi
            set_job idle

        done
    ) &

    RECON_PID=$!
    log_message "$(T "🟢 Reconciliation loop started (PID: %s)" "$RECON_PID")"
}

# Written by perform_backup when milestones couldn't be created; retried by the hourly check.
# The default covers configs from before this setting existed.
MILESTONES_PENDING_FILE="${MILESTONES_PENDING_FILE:-$BACKUP_METADATA_FOLDER/milestones_pending}"

# === Remote copy settings ===
RETRY_COUNT=3
RETRY_DELAY=10
# 10 minutes, also used for the scp milestone copies. Can be overridden from the
# environment (e.g. a systemd drop-in), like RECON_INTERVAL.
RSYNC_TIMEOUT="${RSYNC_TIMEOUT:-600}"

# === Copy one encrypted backup to the remote server, with retries ===
# Used by perform_backup and by retry_remote_pending. Returns 0 on success.
copy_to_remote() {
    if copy_to_remote_attempts "$1"; then
        set_status remote_last_ok "$(date +%s)"
        return 0
    fi
    set_status remote_last_fail "$(date +%s)"
    return 1
}

# The upload itself, for run_with_heartbeat: a background command only gets stdin from a
# redirect of its own, and timeout can't run a function, so both are in here. The sha256 ($2)
# lets the gate refuse an upload cut off on the way; a gate older than that (it answers "too many
# words") gets the old form, see copy_to_remote_attempts.
PUT_WITH_SUM=true
put_to_gate() {
    local cmd="put main $(basename -- "$1")"
    $PUT_WITH_SUM && cmd+=" $2"
    timeout "$RSYNC_TIMEOUT" "${SSH_COMMAND_ARR[0]}" -o BatchMode=yes "${SSH_COMMAND_ARR[@]:1}" "$cmd" < "$1"
}

copy_to_remote_attempts() {
    local file="$1"
    local name i start_time duration output rc=1 local_sum stored_sum backoff_delay
    name=$(basename -- "$file")
    local_sum=$(sha256sum -- "$file" | cut -d' ' -f1)

    validate_remote_backup_location || return 1

    log_message "$(T "📦 Sending %s to Server B's backup gate..." "$name")"
    for ((i=1; i<=RETRY_COUNT; i++)); do
        start_time=$(date +%s)
        output=$(mktemp)
        update_heartbeat
        rc=0
        run_with_heartbeat "$output" put_to_gate "$file" "$local_sum" || rc=$?
        update_heartbeat
        if (( rc != 0 )) && $PUT_WITH_SUM && grep -q 'too many words' "$output"; then
            log_message "$(T "⚠️ Server B's backup gate is older and can't check uploads: update it there (step 1 of serverb-setup.sh, or /update scripts)")"
            PUT_WITH_SUM=false
            rm -f "$output"
            i=$((i - 1))
            continue
        fi
        stored_sum=$(grep -m1 -oE '^[0-9a-f]{64}$' "$output" || true)

        # An earlier attempt may have got there before its answer was lost: the gate never
        # overwrites, so check the copy that is there
        if (( rc != 0 )) && grep -q 'already exists' "$output"; then
            stored_sum=$("${SSH_COMMAND_ARR[0]}" -n -o BatchMode=yes "${SSH_COMMAND_ARR[@]:1}" "get main $name" 2>/dev/null |
                sha256sum | cut -d' ' -f1) || stored_sum=""
            [[ "$stored_sum" == "$local_sum" ]] && rc=0
        fi

        if (( rc == 0 )) && [[ "$stored_sum" == "$local_sum" ]]; then
            duration=$(( $(date +%s) - start_time ))
            log_message "$(T "✅ Stored on Server B and checked (sha256) in %ss (attempt %s/%s)" "${duration}" "$i" "$RETRY_COUNT")"
            rm -f "$output"
            return 0
        fi

        if (( rc == 124 )); then
            log_message "$(T "⏱️ Timeout after %ss" "${RSYNC_TIMEOUT}")"
        elif (( rc == 0 )); then
            log_message "$(T "❌ Server B's checksum doesn't match this copy")"
        fi
        log_message "$(T "❌ Copy to Server B failed (attempt %s/%s, exit code %s): %s" "$i" "$RETRY_COUNT" "$rc" "$(tail -n 2 "$output" | tr '\n' ' ')")"
        rm -f "$output"

        if (( i < RETRY_COUNT )); then
            backoff_delay=$((RETRY_DELAY * i))
            log_message "$(T "⏳ Retrying in %s seconds..." "$backoff_delay")"
            sleep "$backoff_delay"
            update_heartbeat
        fi
    done

    log_message "$(T "🚨 COPY TO SERVER B FAILED AFTER ALL RETRIES (exit code: %s)" "$rc")"
    return 1
}

# === Retry the remote copy of a backup that only reached the attached volume ===
# perform_backup writes REMOTE_PENDING_FILE (holding the path of the attached-volume
# copy) when the remote copy fails, and removes it when a later remote copy succeeds.
retry_remote_pending() {
    [[ -f "$REMOTE_PENDING_FILE" ]] || return 0
    if [[ "$TO_SERVER_B" != yes ]]; then
        # Turned off meanwhile: nothing to catch up
        rm -f -- "$REMOTE_PENDING_FILE"
        clean_outbox
        return 0
    fi

    local lock_fd pending

    # Same lock as perform_backup, so a backup cannot rewrite the marker meanwhile
    exec {lock_fd}>"$FUNCTION_LOCK_FILE"
    if ! flock -n "$lock_fd"; then
        log_message "$(T "⏩ Backup running, will retry remote_pending next time")"
        exec {lock_fd}>&-
        return 0
    fi
    trap "trap - RETURN; exec ${lock_fd}>&-" RETURN

    pending=$(<"$REMOTE_PENDING_FILE")

    if [[ -z "$pending" || ! -f "$pending" ]]; then
        log_message "$(T "⚠️ remote_pending points to a missing file (%s), removing marker" "${pending:-empty}")"
        rm -f -- "$REMOTE_PENDING_FILE"
        return 0
    fi

    log_message "$(T "🔁 Retrying remote copy of %s" "$pending")"
    if copy_to_remote "$pending"; then
        rm -f -- "$REMOTE_PENDING_FILE"
        log_message "$(T "✅ Remote copy caught up, remote_pending cleared")"
        clean_outbox
    else
        log_message "$(T "❌ Remote copy still failing, keeping remote_pending")"
        return 1
    fi
}

# === Milestones: one backup per day and per month, on the attached volume ===
# Server B makes its own (its rotation, see server-b-install.sh).
# Usage: update_milestones <encrypted_backup> [ignored]
# The date comes from the backup's own timestamp, so a retry on a later day files it
# under the day it was taken. Returns 1 if any milestone couldn't be created.
update_milestones() {
    local source="$1"
    local stamp date_key month_key

    log_message "$(T "📌 Starting milestone capture phase...")"

    stamp=$(basename -- "$source" .gpg)
    stamp=${stamp#encrypted_backup_}
    if [[ "$stamp" =~ ^(([0-9]{4}-[0-9]{2})-[0-9]{2}) ]]; then
        date_key=${BASH_REMATCH[1]}
        month_key=${BASH_REMATCH[2]}
    else
        date_key=$(date +%Y-%m-%d)
        month_key=$(date +%Y-%m)
    fi

    ensure_milestone_dirs || return 1
    update_heartbeat
    copy_milestones "$source" "$date_key" "$month_key"
}

ensure_milestone_dirs() {
    if ! mkdir -p "$SECOND_BACKUP_MILESTONE/daily" ||
       ! mkdir -p "$SECOND_BACKUP_MILESTONE/monthly"; then
        log_message "$(T "❌ Failed to create local milestone directories in %s" "$SECOND_BACKUP_MILESTONE")"
        set_status milestone_local_last_fail "$(date +%s)"
        return 1
    fi
}

# Copy to <target>.tmp first and then rename, so an interrupted copy never
# leaves a partial file that the "already exists" check would keep forever.
copy_milestones() {
    local source="$1"
    local date_key="$2"
    local month_key="$3"
    local kind kind_name key target

    if [[ -z "$source" || ! -f "$source" ]]; then
        log_message "$(T "⚠️ No backup found for milestone copy")"
        set_status milestone_local_last_fail "$(date +%s)"
        return 1
    fi

    for kind in daily monthly; do
        [[ "$kind" == daily ]] && key=$date_key || key=$month_key
        # The word shown in messages; $kind stays the folder name
        [[ "$kind" == daily ]] && kind_name=$(T "daily") || kind_name=$(T "monthly")
        target="$SECOND_BACKUP_MILESTONE/$kind/backup_$key.gpg"

        if [[ -f "$target" ]]; then
            log_message "$(T "⏩ %s milestone already exists: %s" "$kind_name" "$(basename "$target")")"
            continue
        fi
        if ! cp -- "$source" "$target.tmp" ||
           ! mv -- "$target.tmp" "$target"; then
            log_message "$(T "❌ Failed to create %s milestone: %s" "$kind_name" "$(basename "$target")")"
            rm -f -- "$target.tmp"
            set_status milestone_local_last_fail "$(date +%s)"
            return 1
        fi
        log_message "$(T "📌 Created %s milestone: %s" "$kind_name" "$(basename "$target")")"
    done
    set_status milestone_local_last_ok "$(date +%s)"
}

# Removes the backups in OUTBOX_DIR that no retry needs any more
clean_outbox() {
    local f keep=()
    [[ -d "$OUTBOX_DIR" ]] || return 0
    [[ -f "$REMOTE_PENDING_FILE" ]] && keep+=("$(<"$REMOTE_PENDING_FILE")")
    [[ -f "$GITHUB_PENDING_FILE" ]] && keep+=("$(<"$GITHUB_PENDING_FILE")")
    for f in "$OUTBOX_DIR"/*.gpg; do
        [[ -f "$f" ]] || continue
        [[ " ${keep[*]} " == *" $f "* ]] && continue
        safe_delete "$f" || true
    done
}

# === Retry a GitHub copy that failed ===
# perform_backup writes GITHUB_PENDING_FILE (the path of the copy to retry from)
retry_github_pending() {
    [[ -f "$GITHUB_PENDING_FILE" ]] || return 0
    local lock_fd pending
    if [[ "$TO_GITHUB" != yes ]]; then
        # Turned off meanwhile: nothing to catch up
        rm -f -- "$GITHUB_PENDING_FILE"
        clean_outbox
        return 0
    fi
    exec {lock_fd}>"$FUNCTION_LOCK_FILE"
    if ! flock -n "$lock_fd"; then
        log_message "$(T "⏩ Backup running, will retry GitHub next time")"
        exec {lock_fd}>&-
        return 0
    fi
    trap "trap - RETURN; exec ${lock_fd}>&-" RETURN
    pending=$(<"$GITHUB_PENDING_FILE")
    if [[ -z "$pending" || ! -f "$pending" ]]; then
        log_message "$(T "⚠️ github_pending points to a missing file (%s), removing marker" "${pending:-empty}")"
        rm -f -- "$GITHUB_PENDING_FILE"
        return 0
    fi
    log_message "$(T "🔁 Retrying the GitHub copy of %s" "$(basename -- "$pending")")"
    if github_store "$pending" main; then
        set_status github_last_ok "$(date +%s)"
        rm -f -- "$GITHUB_PENDING_FILE"
        clean_outbox
        log_message "$(T "✅ GitHub copy caught up, github_pending cleared")"
    else
        set_status github_last_fail "$(date +%s)"
        log_message "$(T "❌ GitHub copy still failing, keeping github_pending")"
        return 1
    fi
}

# === Retry milestones that a backup couldn't create ===
# perform_backup writes MILESTONES_PENDING_FILE (holding the path of the attached-volume
# copy) when a milestone failed.
retry_milestones_pending() {
    [[ -f "$MILESTONES_PENDING_FILE" ]] || return 0

    local lock_fd pending

    # Same lock as perform_backup
    exec {lock_fd}>"$FUNCTION_LOCK_FILE"
    if ! flock -n "$lock_fd"; then
        log_message "$(T "⏩ Backup running, will retry milestones next time")"
        exec {lock_fd}>&-
        return 0
    fi
    trap "trap - RETURN; exec ${lock_fd}>&-" RETURN

    pending=$(<"$MILESTONES_PENDING_FILE")

    if [[ -z "$pending" || ! -f "$pending" ]]; then
        log_message "$(T "⚠️ milestones_pending points to a missing file (%s), removing marker" "${pending:-empty}")"
        rm -f -- "$MILESTONES_PENDING_FILE"
        return 0
    fi

    log_message "$(T "🔁 Retrying milestones from %s" "$pending")"
    if update_milestones "$pending" true; then
        rm -f -- "$MILESTONES_PENDING_FILE"
        log_message "$(T "✅ Milestones caught up, milestones_pending cleared")"
    else
        log_message "$(T "❌ Milestones still failing, keeping milestones_pending")"
        return 1
    fi
}

# perform_backup returns this when LND changed files mid-run (a newer channel backup,
# a file that disappeared). It's not a failure: run_backup starts the backup again.
BACKUP_RESTART=75
BACKUP_MAX_RESTARTS=5

# === Run perform_backup, starting it again while LND keeps changing the files ===
run_backup() {
    local restarts rc

    for (( restarts = 0; ; restarts++ )); do
        rc=0
        BACKUP_SKIPPED=false
        perform_backup || rc=$?
        if (( rc != BACKUP_RESTART )); then
            # A skipped backup (another one holds the lock) is neither a success nor a failure
            if ! $BACKUP_SKIPPED; then
                if (( rc == 0 )); then
                    set_status backup_last_ok "$(date +%s)"
                else
                    set_status backup_last_fail "$(date +%s)" backup_last_error "$(get_status backup_error)"
                fi
                update_pending_status
                set_job idle
            fi
            return "$rc"
        fi

        if (( restarts == BACKUP_MAX_RESTARTS )); then
            log_message "$(T "❌ Files kept changing during the backup, giving up after %s restarts" "$BACKUP_MAX_RESTARTS")"
            set_status backup_last_fail "$(date +%s)" backup_last_error "$(get_status backup_error)"
            set_job idle
            return 1
        fi
        log_message "$(T "🔁 Starting the backup again (restart %s of %s)" "$(( restarts + 1 ))" "$BACKUP_MAX_RESTARTS")"
    done
}

# === Function to Perform Backup ===
perform_backup() {

    local lock_fd

    exec {lock_fd}>"$FUNCTION_LOCK_FILE"

    if ! flock -n "$lock_fd"; then
        log_message "$(T "⏩ Backup already running, skipping")"
        BACKUP_SKIPPED=true
        exec {lock_fd}>&-
        return 0
    fi

    # On every return (success or failure): delete the working files, including the
    # unencrypted copies, while still holding the lock, then release the lock.
    trap "trap - RETURN; cleanup_backup_workdirs; exec ${lock_fd}>&-" RETURN

    log_message "$(T "🔒 Function lock acquired")"
    set_job "backup: checking files"
    set_status backup_error ""
    update_heartbeat

    # Check TMP_BACKUP_DIR safety
	if [[ -z "$TMP_BACKUP_DIR" || "$TMP_BACKUP_DIR" == "/" ]]; then
	    log_message "$(T "❌ Unsafe TMP_BACKUP_DIR")"
	    return 1
	fi

    # === Call check_disk_space ===
    check_disk_space || return 1

    # === Ensure TMP_BACKUP_DIR exists FIRST ===
	if [[ ! -d "$TMP_BACKUP_DIR" ]]; then
	    log_message "$(T "📁 Creating TMP_BACKUP_DIR: %s" "$TMP_BACKUP_DIR")"
	
	    if ! mkdir -p -- "$TMP_BACKUP_DIR"; then
	        log_message "$(T "❌ Failed to create TMP_BACKUP_DIR")"
	        return 1
	    fi
	
	    chown "$SERVER_A_USER:$SERVER_A_USER" "$TMP_BACKUP_DIR"
	fi
	
	# === Create Temporary Backup Directory ===
	if ! LND_TMP_BACKUP=$(mktemp -d -p "$TMP_BACKUP_DIR" "backup_${BASHPID}_XXXXXX"); then
	    log_message "$(T "❌ Failed to create temporary backup directory")"
	    return 1
	fi
	
	# === Harden temp backup directory permissions ===
	if ! chown "$SERVER_A_USER:$SERVER_A_USER" "$LND_TMP_BACKUP"; then
	    log_message "$(T "❌ Failed to chown temporary backup directory")"
	    return 1
	fi
	
	if ! chmod 700 "$LND_TMP_BACKUP"; then
	    log_message "$(T "❌ Failed to chmod temporary backup directory")"
	    return 1
	fi

    # === Build fresh snapshot (single source of truth) ===
	mapfile -t FILES_SNAPSHOT < <(build_files_snapshot | sed '/^$/d')
	
	# === Log missing files (OPTIONAL but useful) ===
	for f in "${FILES_TO_BACKUP[@]}"; do
	    if ! file_exists "$f"; then
	        log_message "$(T "⚠️ Missing file (or not readable by the helper): %s" "$f")"
	    fi
	done
	
	# === Safety guard: empty snapshot ===
	if (( ${#FILES_SNAPSHOT[@]} == 0 )); then
	    log_message "$(T "⚠️ No files available yet — skipping backup")"
	    return 0
	fi
	
	# === Log snapshot contents ===
	log_message "$(T "📂 Snapshot contains %s files:" "${#FILES_SNAPSHOT[@]}")"
	for f in "${FILES_SNAPSHOT[@]}"; do
	    log_message "➡️ $f"
	done
	
	# ✅ Ensure all files exist before proceeding
	for f in "${FILES_SNAPSHOT[@]}"; do
	    if ! file_exists "$f"; then
	        log_message "$(T "⚠️ Snapshot inconsistent (file disappeared): %s" "$f")"
	        return "$BACKUP_RESTART"   # run_backup starts again instead of failing
	    fi
	done
	
	log_message "$(T "✅ All snapshot files exist")"
	
	# === Retry Loop (stability + hash consistency) ===
	LAST_STABLE_SNAPSHOT_HASH=""
	ATTEMPT=1
	MAX_ATTEMPTS=5
	SUCCESS=false
	
	while (( ATTEMPT <= MAX_ATTEMPTS )); do
	    log_message "$(T "🔁 Backup attempt %s of %s" "$ATTEMPT" "$MAX_ATTEMPTS")"
	
	    # Wait for files to settle
	    log_message "$(T "⏳ Waiting for files to settle before backup...")"
	    set_job "backup: waiting for files to settle"
	    update_heartbeat
	    if ! wait_for_files_to_settle "${FILES_SNAPSHOT[@]}"; then
	        log_message "$(T "❌ Files did not stabilize in time")"
	        ((ATTEMPT++))
	        continue
	    fi
	
	    # Compute fingerprint now
	    update_heartbeat
	    CURRENT_SNAPSHOT_HASH=$(build_snapshot_fingerprint "${FILES_SNAPSHOT[@]}")
	    update_heartbeat
	
	    # Compare to previous fingerprint if exists
	    if [[ -n "$LAST_STABLE_SNAPSHOT_HASH" && "$CURRENT_SNAPSHOT_HASH" != "$LAST_STABLE_SNAPSHOT_HASH" ]]; then
	        log_message "$(T "⚠️ Snapshot changed during stabilization — retrying...")"
	        ((ATTEMPT++))
	        continue
	    fi
	
	    # Set previous fingerprint for next iteration
	    LAST_STABLE_SNAPSHOT_HASH="$CURRENT_SNAPSHOT_HASH"
	    SUCCESS=true
	    break
	done
	
	if ! $SUCCESS; then
	    log_message "$(T "❌ Max attempts reached. Aborting backup.")"
	    return 1
	fi
	
	log_message "$(T "✅ Files stable. Proceeding with backup...")"
	update_heartbeat
	
	# === Capture source hashes AFTER stabilization ===
	declare -gA STAGED_HASHES
	
	update_heartbeat
	
	for f in "${FILES_SNAPSHOT[@]}"; do
	    if ! file_exists "$f"; then
	        log_message "$(T "⚠️ File missing (or inaccessible) in snapshot: %s" "$f")"
	        continue
	    fi
	
	    if ! hash=$(hash_file "$f"); then
	        log_message "$(T "❌ Failed to hash file (staging phase): %s" "$f")"
	        return 1
	    fi
	
	    if [[ -z "$hash" ]]; then
	        log_message "$(T "❌ Empty hash produced (unexpected): %s" "$f")"
	        return 1
	    fi
	
	    STAGED_HASHES["$f"]="$hash"
	done

	log_message "$(T "🧾 Captured source file hashes (post-stabilization)")"

	
	# 🚨 Race condition check: ensure snapshot includes latest channel backup

	latest_now=$(find_latest_channel_backup)
	
	snapshot_latest=$(printf "%s\n" "${FILES_SNAPSHOT[@]}" \
	    | grep 'channel.backup-' \
	    | sort \
	    | tail -n1)
	
	log_message "$(T "🔍 Latest on disk: %s" "${latest_now:-none}")"
	log_message "$(T "📦 Latest in snapshot: %s" "${snapshot_latest:-none}")"
	
	if [[ -n "$latest_now" && "$latest_now" != "$snapshot_latest" ]]; then
	    log_message "$(T "⚠️ Snapshot outdated vs latest backup")"
	    log_message "$(T "🔁 Restarting backup to include newest channel backup")"
	    return "$BACKUP_RESTART"
	fi
	
	# ✅ NEW: Final existence check RIGHT BEFORE rsync
	log_message "$(T "🔎 Final pre-rsync validation: ensuring all snapshot files still exist...")"
	
	for f in "${FILES_SNAPSHOT[@]}"; do
	    if ! file_exists "$f"; then
	        log_message "$(T "❌ Snapshot file disappeared before rsync: %s" "$f")"
	        log_message "$(T "🔁 Restarting backup due to inconsistent snapshot")"
	        return "$BACKUP_RESTART"
	    fi
	done
	
	# --- Populate COPY_VERIFY_HASHES from staged hashes ---
	declare -gA COPY_VERIFY_HASHES
	
	for f in "${FILES_SNAPSHOT[@]}"; do
	    if ! file_exists "$f"; then
	        log_message "$(T "❌ File missing in snapshot before copy: %s" "$f")"
	        return 1
	    fi
	
	    staged_hash="${STAGED_HASHES[$f]}"
	
	    if [[ -z "$staged_hash" ]]; then
	        log_message "$(T "❌ Missing staged hash for: %s" "$f")"
	        return 1
	    fi
	
	    COPY_VERIFY_HASHES["$f"]="$staged_hash"
	done
	
	log_message "$(T "🧾 Loaded staged hashes into COPY_VERIFY_HASHES")"
	
	# --- Build quick snapshot fingerprint for monitoring ---
	SOURCE_SNAPSHOT_HASH=$(build_snapshot_fingerprint "${FILES_SNAPSHOT[@]}")
	log_message "$(T "🔍 Snapshot fingerprint: %s" "$SOURCE_SNAPSHOT_HASH")"
	# What the hourly check compares with, taken at the same moment
	SOURCE_CHANGE_HASH=$(build_change_fingerprint "${FILES_SNAPSHOT[@]}")
	
	log_message "$(T "✅ Snapshot validated. All files exist.")"
	
	# === Copy to temporary directory ===
	update_heartbeat
	log_message "$(T "📦 Copying snapshot files to temporary directory...")"
	set_job "backup: copying LND files"

	COPIED_FILES=()
	
	for src in "${FILES_SNAPSHOT[@]}"; do
	    rel="${src#$LND_DIR/}"
		dest="$LND_TMP_BACKUP/$rel"
		if ! mkdir -p "$(dirname "$dest")"; then
		    log_message "$(T "❌ Failed to create directory for %s" "$dest")"
		    return 1
		fi

	    # Create the file as SERVER_A_USER with mode 600 before any data goes in.
	    # A plain chmod afterwards is not enough, because the default ACLs on
	    # TMP_BACKUP_DIR ignore the umask.
	    if ! install -m 600 /dev/null "$dest" ||
	       ! "${LND_HELPER[@]}" read "$src" > "$dest"; then
	        log_message "$(T "❌ Failed to copy %s" "$src")"
	        return 1
	    fi

	    # Keep the source modification time, as cp --preserve=timestamps did
	    if ! src_mtime=$("${LND_HELPER[@]}" mtime "$src") ||
	       ! touch -d "@$src_mtime" "$dest"; then
		    log_message "$(T "❌ Failed to set timestamp on %s" "$dest")"
		    return 1
		fi
	
	    COPIED_FILES+=("$dest")
	    log_message "$(T "➡️ Copied: %s → %s" "$src" "$dest")"
	done
	
	log_message "$(T "✅ Copy phase completed")"
	set_job "backup: verifying the copy"
	update_heartbeat
	
	# === Verify Fingerprint ===
	COPIED_FILES_HASH=$(build_snapshot_fingerprint "${COPIED_FILES[@]}")
	if [[ "$SOURCE_SNAPSHOT_HASH" != "$COPIED_FILES_HASH" ]]; then
	    log_message "$(T "❌ Copied snapshot fingerprint mismatch — retrying backup")"
	    return 1
	fi
	log_message "$(T "✅ Copy fingerprint verified")"
	
	# === verify_copy_stability ===
	update_heartbeat
	if ! verify_copy_stability "${FILES_SNAPSHOT[@]}"; then
	    log_message "$(T "❌ Copy stability check failed — retrying backup")"
	    return 1
	fi
	update_heartbeat
	
	# === verify copied files instead of source ===
	update_heartbeat
	if ! verify_copied_hashes "${FILES_SNAPSHOT[@]}"; then
	    log_message "$(T "❌ Aborting backup due to corrupted rsync copy")"
	
	    if [[ -n "${LND_TMP_BACKUP:-}" && -d "${LND_TMP_BACKUP}" ]]; then
	        REAL=$(realpath "$LND_TMP_BACKUP" 2>/dev/null || echo "")
	        SAFE_BASE=$(realpath "$(dirname "$REAL")" 2>/dev/null || echo "")
	
	        if [[ "$REAL" == "$SAFE_BASE/"* ]]; then
	            find "$REAL" -mindepth 1 -delete
	            log_message "$(T "🧹 Safely cleaned temporary backup directory: %s" "$REAL")"
	        else
	            log_message "$(T "❌ Unsafe LND_TMP_BACKUP — skipping cleanup: %s" "$LND_TMP_BACKUP")"
	        fi
	    fi
	
	    return 1
	fi
	
	update_heartbeat
	
	sleep 1

    # === Define Timestamp for Backup in TMP Directory ===
    # In UTC: the same on both servers and through daylight-saving changes (older backups carry the
    # local offset; everything orders them by their real time, not the name's text)
    TIMESTAMP=$(date -u --iso-8601=seconds)
    TIMESTAMPED_BACKUP="${TMP_BACKUP_DIR}/backup_${TIMESTAMP}"
    if ! mkdir -p "$TIMESTAMPED_BACKUP"; then
        log_message "$(T "❌ Failed to create timestamped backup directory: %s" "$TIMESTAMPED_BACKUP")"
        return 1
    fi
    log_message "$(T "🛠️ Created timestamped backup directory: %s" "$TIMESTAMPED_BACKUP")"
 
	# === Move Files to Timestamped Backup Directory ===
	log_message "$(T "🛠️ Moving files to timestamped directory: %s" "$TIMESTAMPED_BACKUP")"
	if ! mv "$LND_TMP_BACKUP"/* "$TIMESTAMPED_BACKUP/"; then
	    log_message "$(T "❌ Failed to move files to timestamped directory: %s" "$TIMESTAMPED_BACKUP")"
	    return 1
	fi
	
	log_message "$(T "✅ Files moved to timestamped directory: %s" "$TIMESTAMPED_BACKUP")"
	
	log_message "$(T "Using the wait_for_files_to_settle Function Before Compression...")"
	
	# Wait for the files that were moved to the timestamped backup directory to settle
    mapfile -t files_to_wait < <(find "$TIMESTAMPED_BACKUP" -type f)
	
	if (( ${#files_to_wait[@]} > 0 )); then
	    if ! wait_for_files_to_settle "${files_to_wait[@]}"; then
	        log_message "$(T "❌ Files in %s did not settle before compression" "$TIMESTAMPED_BACKUP")"
	        return 1
	    fi
	else
	    log_message "$(T "⚠️ No files to wait for in %s" "$TIMESTAMPED_BACKUP")"
	fi
	
	# === Compressing Folder ===
	log_message "$(T "🔐 Compressing Folder into One File...")"
	set_job "backup: compressing"
	
	update_heartbeat
	    
	# Tar and compress the backup directory. The unencrypted archives are created with mode 600
	# before anything is written to them: TMP_BACKUP_DIR's default ACLs would otherwise make them
	# readable by others for as long as they exist (default ACLs override the umask).
	TAR_FILE="${TMP_BACKUP_DIR}/backup_compressed.tar.gz"
	install -m 600 /dev/null "$TAR_FILE"
	if ! tar -czf "$TAR_FILE" -C "$TIMESTAMPED_BACKUP" .; then
	    log_message "$(T "❌ Failed to compress backup directory: %s" "$TIMESTAMPED_BACKUP")"
	    return 1
	fi
	
	log_message "$(T "📦 Backup compressed successfully into: %s" "$TAR_FILE")"
	
	update_heartbeat
	
	# Force flush to disk after compression
    log_message "$(T "⏳ Flushing file system buffers after compression.")"
    sync -f "$TAR_FILE"  # Ensure the compressed tar file is fully written to disk
    sleep 1
    
    if ! chown "$SERVER_A_USER":"$SERVER_A_USER" "$TAR_FILE"; then
        log_message "$(T "❌ Failed to chown %s" "$TAR_FILE")"
        return 1
    fi

    if ! chmod 600 "$TAR_FILE"; then
        log_message "$(T "❌ Failed to chmod %s" "$TAR_FILE")"
        return 1
    fi
	
	# === Compute checksum for the compressed backup ===
	update_heartbeat
	CHECKSUM_FILE="${TAR_FILE}.sha256"
	install -m 600 /dev/null "$CHECKSUM_FILE"
	
	(
	    cd "$(dirname "$TAR_FILE")"
	    sha256sum "$(basename "$TAR_FILE")"
	) > "$CHECKSUM_FILE"
	
	log_message "$(T "✅ SHA256 checksum created: %s" "$CHECKSUM_FILE")"
	update_heartbeat
	
	# === Encrypt the Backup with GPG ===
	log_message "$(T "🔐 Encrypting backup with GPG...")"
	set_job "backup: encrypting"
	
	# Ensure GPG_FINGERPRINT is set
	if [[ -z "${GPG_FINGERPRINT:-}" ]]; then
	    log_message "$(T "❌ GPG_FINGERPRINT is not set")"
	    return 1
	fi
	
	# Verify the GPG key exists (exact fingerprint match across full keyring)
	if ! gpg --list-keys --fingerprint --with-colons 2>/dev/null | \
	     grep -q "^fpr:::::::::$GPG_FINGERPRINT:$"; then
	    log_message "$(T "❌ GPG key with fingerprint not found: %s" "$GPG_FINGERPRINT")"
	    log_message "$(T "⚠️ Ensure the correct key is imported for user: %s" "$SERVER_A_USER")"
	    return 1
	fi
	
	# Encrypt + sign using pinned fingerprint
	# Written next to TIMESTAMPED_BACKUP rather than inside it, so the plaintext folder
	# can be deleted as soon as the encrypted file is verified.
	ENCRYPTED_FILE="$TMP_BACKUP_DIR/encrypted_backup_$TIMESTAMP.gpg"

	# Use loopback mode with a passphrase file if one is configured.
	# --passphrase-file keeps the passphrase out of the process list.
	GPG_PASSPHRASE_OPTS=()
	if [[ -n "${GPG_PASSPHRASE_FILE:-}" ]]; then
	    if [[ ! -f "$GPG_PASSPHRASE_FILE" || ! -O "$GPG_PASSPHRASE_FILE" ]]; then
	        log_message "$(T "❌ GPG_PASSPHRASE_FILE missing or not owned by %s: %s" "$(id -un)" "$GPG_PASSPHRASE_FILE")"
	        return 1
	    fi

	    case "$(stat -c %a "$GPG_PASSPHRASE_FILE")" in
	        600 | 400) ;;
	        *)
	            log_message "$(T "❌ GPG_PASSPHRASE_FILE must have mode 600: %s" "$GPG_PASSPHRASE_FILE")"
	            return 1
	            ;;
	    esac

	    log_message "$(T "🔐 Using loopback mode for GPG (passphrase file provided)")"
	    GPG_PASSPHRASE_OPTS=(
	        --pinentry-mode loopback
	        --passphrase-file "$GPG_PASSPHRASE_FILE"
	    )
	else
	    log_message "$(T "🔓 No GPG passphrase file provided (assuming unprotected key or agent)")"
	fi

	GPG_CMD=(
	    gpg --batch --yes
	    "${GPG_PASSPHRASE_OPTS[@]}"
	    --recipient "$GPG_FINGERPRINT"
	    --local-user "$GPG_FINGERPRINT"
	    --output "$ENCRYPTED_FILE"
	    --encrypt --sign
	)
	
	GPG_PAYLOAD="$TMP_BACKUP_DIR/gpg_payload.tar"
	install -m 600 /dev/null "$GPG_PAYLOAD"

	# Signed with the rest: what this backup is and when it was made. lnd-wallet.sh checks it
	# against the file name, which isn't signed and could be changed to pass an old backup off
	# as the newest.
	MANIFEST_FILE="$TMP_BACKUP_DIR/manifest"
	install -m 600 /dev/null "$MANIFEST_FILE"
	printf 'kind=backup\ntime=%s\n' "$TIMESTAMP" > "$MANIFEST_FILE"

	if ! tar -cf "$GPG_PAYLOAD" \
	    -C "$(dirname "$TAR_FILE")" "$(basename "$TAR_FILE")" \
	    -C "$(dirname "$CHECKSUM_FILE")" "$(basename "$CHECKSUM_FILE")" \
	    -C "$(dirname "$MANIFEST_FILE")" "$(basename "$MANIFEST_FILE")"; then
	
	    log_message "$(T "❌ Failed to create GPG payload archive")"
	    return 1
	fi
	
	update_heartbeat
	if ! "${GPG_CMD[@]}" "$GPG_PAYLOAD"; then
	    log_message "$(T "❌ GPG encrypt+sign failed for backup artifacts using fingerprint: %s" "$GPG_FINGERPRINT")"
	    return 1
	fi
	
	log_message "$(T "✅ GPG encryption + signing successful: %s" "$ENCRYPTED_FILE")"
	update_heartbeat
	
	# === Verify encrypted backup integrity via checksum ===

	TMP_VERIFY_DIR=$(mktemp -d -p "$TMP_BACKUP_DIR" verify_XXXXXX)
	
	DECRYPTED_BUNDLE="$TMP_VERIFY_DIR/backup_bundle.tar"
	
	log_message "$(T "🔓 Decrypting encrypted backup for verification...")"
	
	# Decrypt single tarball
	update_heartbeat
	if ! gpg --batch --yes \
	    "${GPG_PASSPHRASE_OPTS[@]}" \
	    --output "$DECRYPTED_BUNDLE" \
	    --decrypt "$ENCRYPTED_FILE"; then
	
	    log_message "$(T "❌ GPG decryption failed for verification")"
	    safe_delete "$TMP_VERIFY_DIR"
	    return 1
	fi
	
	log_message "$(T "📦 Extracting verification bundle...")"
	
	# Extract tar archive
	if ! tar -xf "$DECRYPTED_BUNDLE" -C "$TMP_VERIFY_DIR"; then
	    log_message "$(T "❌ Failed to extract verification bundle")"
	    safe_delete "$TMP_VERIFY_DIR"
	    return 1
	fi
	
	checksum_name="$(basename "$CHECKSUM_FILE")"
	
	log_message "$(T "🔍 Verifying checksum integrity...")"
	
	if ! (
	    cd "$TMP_VERIFY_DIR" &&
	    sha256sum -c "$checksum_name"
	); then
	    log_message "$(T "❌ Checksum verification failed! Backup corrupted!")"
	    safe_delete "$TMP_VERIFY_DIR"
	    return 1
	fi
	
	log_message "$(T "✅ Encrypted backup integrity verified via checksum")"
	update_heartbeat
	
	safe_delete "$TMP_VERIFY_DIR"

    # Remove the unencrypted tar.gz
    safe_delete "$TAR_FILE"
    log_message "$(T "🧹 Unencrypted tar.gz removed: %s" "$TAR_FILE")"

	# The encrypted file is verified, so the plaintext copies are no longer needed.
	# The RETURN trap removes them too if anything before this point fails.
	for plaintext in "$TIMESTAMPED_BACKUP" "$GPG_PAYLOAD" "$CHECKSUM_FILE"; do
	    if ! safe_delete "$plaintext"; then
	        log_message "$(T "❌ Failed to remove unencrypted file: %s" "$plaintext")"
	        return 1
	    fi
	done
	log_message "$(T "🧹 Unencrypted backup copies removed from %s" "$TMP_BACKUP_DIR")"

	# === The destinations that are on, each on its own ===
	LOCAL_OK=false
	REMOTE_OK=false
	GITHUB_OK=false
	SECOND_BACKUP_COPY=""
	RETRY_SOURCE=""

	if [[ "$TO_VOLUME" == yes ]]; then
	    log_message "$(T "📦 Rsync encrypted backup to %s..." "$SECOND_BACKUP_DIR")"
	    set_job "backup: copying to the attached volume"
	    update_heartbeat
	    SECOND_BACKUP_COPY="$SECOND_BACKUP_DIR/$(basename "$ENCRYPTED_FILE")"
	    if [ ! -d "$SECOND_BACKUP_DIR" ]; then
	        # The disk's root belongs to root, so the installer makes this folder; if it's gone,
	        # the disk was probably swapped or cleaned by hand
	        log_message "$(T "❌ %s doesn't exist. Rerun rsync_gpg_backup.sh: it creates it on the attached volume." "$SECOND_BACKUP_DIR")"
	        set_status local_last_fail "$(date +%s)"
	    elif rsync -av -- "$ENCRYPTED_FILE" "$SECOND_BACKUP_DIR/"; then
	        log_message "$(T "✅ Rsync completed successfully to second backup directory.")"
	        LOCAL_OK=true
	        RETRY_SOURCE="$SECOND_BACKUP_COPY"
	        set_status local_last_ok "$(date +%s)"
	        update_heartbeat
	    else
	        log_message "$(T "❌ Rsync failed to %s. Continuing backup process." "$SECOND_BACKUP_DIR")"
	        set_status local_last_fail "$(date +%s)"
	    fi
	fi

	if [[ "$TO_SERVER_B" == yes ]]; then
	    set_job "backup: copying to Server B"
	    if copy_to_remote "$ENCRYPTED_FILE"; then
	        REMOTE_OK=true
	        log_message "$(T "🎉 RSYNC STAGE CONFIRMED SUCCESS")"
	        # The remote now has the newest backup, so an older pending copy no longer matters
	        if [[ -f "$REMOTE_PENDING_FILE" ]]; then
	            rm -f -- "$REMOTE_PENDING_FILE"
	            log_message "$(T "🧾 Cleared remote_pending")"
	        fi
	    fi
	fi

	if [[ "$TO_GITHUB" == yes ]]; then
	    set_job "backup: copying to GitHub"
	    update_heartbeat
	    if github_store "$ENCRYPTED_FILE" main; then
	        GITHUB_OK=true
	        set_status github_last_ok "$(date +%s)"
	        rm -f -- "$GITHUB_PENDING_FILE"
	    else
	        set_status github_last_fail "$(date +%s)"
	    fi
	    update_heartbeat
	fi

	if ! $LOCAL_OK && ! $REMOTE_OK && ! $GITHUB_OK; then
	    # No copy anywhere, so don't commit the hashes. The next event retries the whole backup.
	    log_message "$(T "❌ The backup reached none of its destinations. Not committing hashes.")"
	    return 1
	fi
	# A destination that failed is retried by the hourly check, from the attached volume's copy,
	# or, without one, from a copy kept for that in OUTBOX_DIR
	if { [[ "$TO_SERVER_B" == yes ]] && ! $REMOTE_OK; } || { [[ "$TO_GITHUB" == yes ]] && ! $GITHUB_OK; }; then
	    if [[ -z "$RETRY_SOURCE" ]]; then
	        RETRY_SOURCE="$OUTBOX_DIR/$(basename "$ENCRYPTED_FILE")"
	        if ! mkdir -p "$OUTBOX_DIR" || ! cp -- "$ENCRYPTED_FILE" "$RETRY_SOURCE"; then
	            log_message "$(T "❌ Could not keep a copy for the retry in %s" "$OUTBOX_DIR")"
	            RETRY_SOURCE=""
	        fi
	    fi
	    log_message "$(T "🚨 Not every destination has it yet; the hourly check tries again.")"
	fi

	log_message "$(T "🔍 Proceeding to post-rsync validation")"

	# === Verify files match staged hashes before commit ===
	update_heartbeat
	for f in "${FILES_SNAPSHOT[@]}"; do
	
	    log_message "$(T "🔍 Verifying final hash: %s" "$f")"
	
	    if ! file_exists "$f"; then
	        log_message "$(T "❌ File missing before commit: %s" "$f")"
	        return 1
	    fi
	
	    if ! current_hash=$(hash_file "$f"); then
	        log_message "$(T "❌ Failed to hash file before commit: %s" "$f")"
	
	        if ! file_exists "$f"; then
	            log_message "$(T "❌ File disappeared: %s" "$f")"
	        fi
	
	        return 1
	    fi
	
	    if [[ "${STAGED_HASHES["$f"]}" != "$current_hash" ]]; then
	        log_message "$(T "❌ File changed since stabilization: %s" "$f")"
	        return 1
	    fi
	
	    log_message "$(T "✅ Final hash verified: %s" "$f")"
	done
	
	update_heartbeat
	
	log_message "$(T "✅ Post-rsync hash verification complete")"
	
	log_message "$(T "🧾 Starting hash commit phase")"
	update_heartbeat
	
	if ! commit_file_hashes "${FILES_SNAPSHOT[@]}"; then
	    log_message "$(T "❌ commit_file_hashes failed")"
	    return 1
	fi
	
	log_message "$(T "🧾 Hash commit phase complete")"
	log_message "$(T "🧾 Stored source file hashes captured post-stabilization to %s" "$COMMIT_HASHES_FOLDER")"
	update_heartbeat

	# Save the fingerprint here, not in the hourly check, so every committed backup
	# updates it and a backup skipped because of the lock saves nothing.
	if save_last_snapshot_hash "$SOURCE_CHANGE_HASH"; then
	    log_message "$(T "🧾 Updated stored snapshot fingerprint")"
	else
	    log_message "$(T "⚠️ Failed to save snapshot fingerprint to %s" "$LAST_SNAPSHOT_HASH_FILE")"
	fi

	# A destination that failed: the hourly check retries it from RETRY_SOURCE
	if [[ "$TO_SERVER_B" == yes ]] && ! $REMOTE_OK && [[ -n "$RETRY_SOURCE" ]]; then
	    if printf '%s\n' "$RETRY_SOURCE" > "$REMOTE_PENDING_FILE"; then
	        log_message "$(T "🚨 Marked for remote retry in %s: %s" "$REMOTE_PENDING_FILE" "$RETRY_SOURCE")"
	    else
	        log_message "$(T "❌ Failed to write %s" "$REMOTE_PENDING_FILE")"
	    fi
	fi
	if [[ "$TO_GITHUB" == yes ]] && ! $GITHUB_OK && [[ -n "$RETRY_SOURCE" ]]; then
	    if printf '%s\n' "$RETRY_SOURCE" > "$GITHUB_PENDING_FILE"; then
	        log_message "$(T "🚨 Marked for a GitHub retry: %s" "$RETRY_SOURCE")"
	    else
	        log_message "$(T "❌ Failed to write %s" "$GITHUB_PENDING_FILE")"
	    fi
	fi
	clean_outbox

	# =========================================================
	# 🟢 MILESTONE PHASE
	# =========================================================

	# The attached volume's milestones and rotation: only when it is on and has this backup
	if [[ "$TO_VOLUME" == yes ]] && $LOCAL_OK; then
	# The backup is complete at this point. A milestone failure is only a warning;
	# the hourly check retries it from the attached-volume copy.
	set_job "backup: milestones"
	update_heartbeat
	if update_milestones "$ENCRYPTED_FILE"; then
	    rm -f -- "$MILESTONES_PENDING_FILE"
	else
	    if printf '%s\n' "$SECOND_BACKUP_COPY" > "$MILESTONES_PENDING_FILE"; then
	        log_message "$(T "⚠️ Milestones not complete, the hourly check will retry them from %s" "$SECOND_BACKUP_COPY")"
	    else
	        log_message "$(T "❌ Failed to write %s" "$MILESTONES_PENDING_FILE")"
	    fi
	fi
	update_heartbeat


    # === Backup Rotation for Local Directory ===
	log_message "$(T "🧹 Starting safer backup rotation in %s..." "$SECOND_BACKUP_DIR")"
	set_job "backup: removing old backups"
	
	shopt -s nullglob
	
	# Newest first by the real time in the name, not its text (names from before the switch to
	# UTC carry a local offset; a clock that was wrong gives odd names too)
	sorted=()
	for f in "$SECOND_BACKUP_DIR"/encrypted_backup_*.gpg; do
	    stamp="${f##*/encrypted_backup_}"
	    epoch=$(date -d "${stamp%.gpg}" +%s 2>/dev/null) || continue
	    sorted+=("$epoch $f")
	done
	mapfile -t sorted < <(printf '%s\n' "${sorted[@]}" | sort -k1,1nr | cut -d' ' -f2-)
	# Never the backup just made, nor one a retry still needs (its Server B copy or milestones):
	# with the clock behind, the newest file could otherwise sort as the oldest
	keep_anyway=("$SECOND_BACKUP_COPY")
	[[ -f "$REMOTE_PENDING_FILE" ]] && keep_anyway+=("$(<"$REMOTE_PENDING_FILE")")
	[[ -f "$MILESTONES_PENDING_FILE" ]] && keep_anyway+=("$(<"$MILESTONES_PENDING_FILE")")

	# Skip first 10, delete the rest
	update_heartbeat
	for f in "${sorted[@]:10}"; do
	    [[ -z "$f" ]] && continue
	    [[ " ${keep_anyway[*]} " == *" $f "* ]] && continue
	
	    if ! safe_delete "$f"; then
	        log_message "$(T "❌ Failed to delete old backup: %s" "$f")"
	    fi
	done
	
	shopt -u nullglob
	
	log_message "$(T "🧹 Old encrypted backups cleaned in %s. Retained last 10 backups." "$SECOND_BACKUP_DIR")"
	update_heartbeat
	
	
	# === MILESTONE RETENTION === #
	# Retention policy
	MILESTONE_DAILY_COUNT=30
	MILESTONE_MONTHLY_COUNT=12
	
	
	# === Local Milestone Cleanup ===
	log_message "$(T "🧹 Cleaning local milestone retention...")"
	
	shopt -s nullglob
	
	# ----- Daily -----
	daily_files=("$SECOND_BACKUP_MILESTONE/daily"/backup_*.gpg)
	
	IFS=$'\n' daily_sorted=($(printf "%s\n" "${daily_files[@]}" | sort -r))
	unset IFS
	
	for f in "${daily_sorted[@]:$MILESTONE_DAILY_COUNT}"; do
	    [[ -z "$f" ]] && continue
	
	    if safe_delete "$f"; then
	        log_message "$(T "🗑️ Removed old daily milestone: %s" "$(basename "$f")")"
	    else
	        log_message "$(T "❌ Failed to delete daily milestone: %s" "$(basename "$f")")"
	    fi
	done
	
	# ----- Monthly -----
	monthly_files=("$SECOND_BACKUP_MILESTONE/monthly"/backup_*.gpg)
	
	IFS=$'\n' monthly_sorted=($(printf "%s\n" "${monthly_files[@]}" | sort -r))
	unset IFS
	
	for f in "${monthly_sorted[@]:$MILESTONE_MONTHLY_COUNT}"; do
	    [[ -z "$f" ]] && continue
	
	    if safe_delete "$f"; then
	        log_message "$(T "🗑️ Removed old monthly milestone: %s" "$(basename "$f")")"
	    else
	        log_message "$(T "❌ Failed to delete monthly milestone: %s" "$(basename "$f")")"
	    fi
	done
	
	shopt -u nullglob
	
	log_message "$(T "🧹 Local milestone cleanup complete")"
	fi

	# Clean up old hash files
	find "$COMMIT_HASHES_FOLDER" -name 'last_hash_*' -mtime +30 -print0 |
	while IFS= read -r -d '' f; do
	    if ! safe_delete "$f"; then
	        log_message "$(T "❌ Failed to delete old hash file: %s" "$(basename "$f")")"
	    fi
	done

	# Server B rotates its own copies and makes its milestones (server-b-install.sh): Server A
	# can't delete anything there.
}

# A new start: drop the previous run's job and record when this one started
set_status service_started "$(date +%s)"
set_job "starting"
update_pending_status

# Tell systemd startup is complete
if [[ -n "${NOTIFY_SOCKET:-}" ]]; then
    systemd-notify --ready --status="Initial setup done"
    log_message "$(T "✅ systemd READY notification sent")"
fi

# === If No Backups Exist, Perform an Initial Backup ===
# With the attached volume: when it holds none. Without it: when no backup was ever made here.
if { [[ "$TO_VOLUME" == yes ]] && { [ ! -d "$SECOND_BACKUP_DIR" ] || ! find "$SECOND_BACKUP_DIR" -maxdepth 1 -type f -name 'encrypted_backup_*' | grep -q .; }; } ||
   { [[ "$TO_VOLUME" != yes ]] && [[ ! -s "$LAST_SNAPSHOT_HASH_FILE" ]]; }; then
    log_message "$(T "⚡ No backup yet (%s). Performing initial backup..." "$( [[ "$TO_VOLUME" == yes ]] && echo "$SECOND_BACKUP_DIR" || echo "$LAST_SNAPSHOT_HASH_FILE")")"
    
    # Perform the backup
    if ! run_backup; then
        log_message "$(T "❌ Backup failed. Exiting script.")"
        exit 1
    fi
else
    log_message "$(T "⚠️ A backup folder (encrypted_backup_*) already exists in %s, skipping initial backup." "$SECOND_BACKUP_DIR")"
fi

# === Start Monitoring Specific Files ===
log_message "$(T "📡 Starting file watcher...")"

DEBOUNCE_SECONDS=10
LAST_BACKUP_TS=0
LAST_FAILURE_TS=0
FAILURE_COUNT=0
BASE_COOLDOWN=30
MAX_COOLDOWN=600

start_watcher() {
    log_message "$(T "📡 Starting inotify watcher...")"

    ACTIVE_WATCH=("${FOLDER_TO_WATCH[@]}")

    if [[ "${INOTIFY_MODE:-real}" == "test" ]]; then
        log_message "$(T "🧪 Test mode watcher started")"
        ACTIVE_WATCH+=("$TEST_INOTIFY_FOLDER")

        # Polling loop for test mode: only outputs file changes
        while true; do
            if [[ -f "$TEST_TRIGGER_FILE" ]]; then
                echo "$TEST_TRIGGER_FILE"   # send to main loop
            fi
            sleep 2
        done

    else
        log_message "$(T "📡 Running real inotifywait stream...")"
        inotifywait -m -e create,close_write,move \
            --format '%w%f' \
            "${ACTIVE_WATCH[@]}"
    fi
}

# === File Backup Monitoring Loop ===
LAST_FILE_EVENT_TIME=$(date +%s)
LAST_IDLE_LOG_TIME=$(date +%s)
LAST_HEARTBEAT_LOGGED=0  # Track last heartbeat log

RESTART_COUNT=0
MAX_BACKOFF=60
TODAY=$(date +%Y-%m-%d)
LAST_RESET_DAY="$TODAY"

log_message "$(T "🚀 Starting watcher...")"
start_reconciliation_loop
set_job idle

while true; do
    log_message "$(T "📡 Starting watcher stream...")"

    WATCHER_START_TIME=$(date +%s)

    while true; do

        changed_file=""
        # Timed read prevents infinite blocking
        if read -r -t 30 changed_file; then

            # Track the last event timestamp
            LAST_FILE_EVENT_TIME=$(date +%s)

            # Test trigger file handling
            if [[ "${changed_file}" == "${TEST_TRIGGER_FILE}" ]]; then
                log_message "$(T "🧪 Manual trigger detected")"

                if ! check_pid_alive "${HASH_CHANGER_PID:-}" "Hash changer"; then
                    log_message "$(T "🚀 Starting hash changer")"
                    start_hash_changer
                else
                    log_message "$(T "⏩ Hash changer already running")"
                fi

                if ! safe_delete "$TEST_TRIGGER_FILE"; then
                    log_message "$(T "❌ Failed to remove TEST_TRIGGER_FILE")"
                fi
            fi

            # Handle the file event
            if ! handle_event "$changed_file"; then
                log_message "$(T "❌ handle_event failed for: %s" "$changed_file")"
            fi

        fi

        # Heartbeat ALWAYS runs even during idle periods
        update_heartbeat

        # The hourly-check loop runs on its own: if it ever ended, start it again
        if [[ -n "${RECON_PID:-}" ]] && ! kill -0 "$RECON_PID" 2>/dev/null; then
            log_message "$(T "⚠️ The hourly check had stopped: starting it again")"
            start_reconciliation_loop
        fi

    done < <(start_watcher)

    # ================================
    # WATCHER EXIT HANDLING (CRASH PATH)
    # ================================

    log_message "$(T "⚠️ Watcher crashed or exited")"

    # === Increment failure pressure ===
    RESTART_COUNT=$((RESTART_COUNT + 1))

    # === Cap exponent growth ===
    (( RESTART_COUNT > 6 )) && RESTART_COUNT=6

    # === Exponential backoff ===
    BACKOFF=$(( 2 ** RESTART_COUNT ))

    # === Hard safety cap ===
    (( BACKOFF > MAX_BACKOFF )) && BACKOFF=$MAX_BACKOFF

    log_message "$(T "⏳ Restarting watcher in %s seconds (attempt #%s)..." "$BACKOFF" "$RESTART_COUNT")"
    sleep "$BACKOFF"

    # ================================
    # OPTION B: RECOVERY RESET (SAFE)
    # ================================

    WATCHER_RUNTIME=$(( $(date +%s) - WATCHER_START_TIME ))

    # Only reset if watcher was stable for a meaningful duration
    if (( WATCHER_RUNTIME > 300 )); then
        log_message "$(T "🟢 Watcher stable for %ss → resetting restart counter" "${WATCHER_RUNTIME}")"
        RESTART_COUNT=0
    fi

    # ================================
    # IDLE DETECTION LOG
    # ================================

    now=$(date +%s)
    if (( now - LAST_FILE_EVENT_TIME > 86400 )) && (( now - LAST_IDLE_LOG_TIME > 86400 )); then
        log_message "$(T "ℹ️ No file changes detected in 24h (system idle)")"
        LAST_IDLE_LOG_TIME="$now"
    fi
done
EOF
} > "$SERVICE_TMP"

if ! bash -n "$SERVICE_TMP"; then
    log_message "$(T "❌ Generated service script has a syntax error — not installed")"
    rm -f "$SERVICE_TMP"
    exit 1
fi

sudo install -o root -g root -m 755 "$SERVICE_TMP" "$RSYNC_FOLDER_MIRROR_SYSTEMD_SCRIPT_PATH"
rm -f "$SERVICE_TMP"

# === Write systemd Service ===
sudo tee "$RSYNC_BACKUP_SERVICE_PATH" > /dev/null <<EOF
[Unit]
Description=Rsync Backup Service for BTCPay Server (file change monitor)
After=network.target docker.service
Requires=docker.service
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=notify
User=$SERVER_A_USER
ExecStart=$RSYNC_FOLDER_MIRROR_SYSTEMD_SCRIPT_PATH
Restart=on-failure
RestartSec=30
TimeoutStartSec=15min
TimeoutStopSec=120
WatchdogSec=120
# The script exits with 143 on SIGTERM (systemctl stop); treat that as a clean stop
SuccessExitStatus=143
StandardOutput=journal
StandardError=journal

# Ensure the PATH includes the directory where gpg is located
Environment="PATH=/usr/bin:/usr/local/bin:/bin:/sbin"

NotifyAccess=all

# /var/lib/rsync_gpg_backup holds the status file for the dashboard (STATUS_FILE): owned by
# $SERVER_A_USER, readable by everyone
StateDirectory=rsync_gpg_backup
StateDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

# Enable + start service
if ! sudo systemctl daemon-reload; then
    log_message "$(T "❌ systemctl daemon-reload failed")"
    exit 1
fi
log_message "$(T "✅ systemctl daemon-reload completed")"

# lnd-update.sh at boot runs before the service starts: there its start is only queued
# (--no-block: waiting for it would wait for the boot step that runs this)
if [[ "${LND_UPDATE_AT_BOOT:-}" == 1 ]]; then
    if ! sudo systemctl enable "$RSYNC_BACKUP_SERVICE_NAME" ||
       ! sudo systemctl start --no-block "$RSYNC_BACKUP_SERVICE_NAME"; then
        log_message "$(T "❌ Failed to enable/start service: %s" "$RSYNC_BACKUP_SERVICE_NAME")"
        exit 1
    fi
    log_message "$(T "✅ Service enabled; it starts after this boot step: %s" "$RSYNC_BACKUP_SERVICE_NAME")"
elif ! sudo systemctl enable --now "$RSYNC_BACKUP_SERVICE_NAME"; then
    log_message "$(T "❌ Failed to enable/start service: %s" "$RSYNC_BACKUP_SERVICE_NAME")"
    exit 1
else
    log_message "$(T "✅ Service enabled and started: %s" "$RSYNC_BACKUP_SERVICE_NAME")"
fi
