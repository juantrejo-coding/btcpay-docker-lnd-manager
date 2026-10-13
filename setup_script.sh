#!/bin/bash

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
if ! source "$CONFIG_FILE"; then
    echo "❌ Failed to load $CONFIG_FILE"
    exit 1
fi

# setup_script.sh --check: only the checks below ("Before anything is changed"), then exit
CHECK_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --check) CHECK_ONLY=true ;;
        -h | --help)
            echo "Usage: ./setup_script.sh [--check]"
            echo "  Sets up the backup user, the attached volume, Server B, the SSH and GPG keys and the backup"
            echo "  service, asking as it goes. --check only checks this server and Server B first, changing nothing."
            exit 0 ;;
        *) echo "❌ Unknown option: $arg (see --help)" >&2; exit 2 ;;
    esac
done

# This is the one script you run from your working folder: it saves answers into config here,
# then install-scripts.sh copies everything root-owned to BACKUP_INSTALL_DIR, which root runs.
if [[ ! -w "$CONFIG_FILE" ]]; then
    echo "❌ $CONFIG_FILE can't be edited by you. Run setup_script.sh from your working folder" >&2
    echo "   (${BACKUP_SCRIPTS_FOLDER:-~/btcpay-docker-lnd-manager}), not from the installed copy." >&2
    exit 1
fi

# Setup asks questions only a person can answer (it ends by asking you to confirm your LND seed
# is stored), so without a terminal it can't finish. Stop before changing anything.
if [[ ! -t 0 ]] && ! $CHECK_ONLY; then
    echo "❌ setup_script.sh needs a terminal: it asks questions during setup. Run it in a terminal (e.g. over SSH)." >&2
    exit 1
fi

# Function to log messages to both log file and journal
log_message() {
    local message="$1"
    local timestamped="[$(date '+%Y-%m-%d %H:%M:%S')] $message"

    # Print once to terminal and append to log file
    echo "$timestamped" | sudo tee -a "$LIGHTNING_BACKUP_LOG_FILE"

    # Send the same timestamped message to systemd journal with tag
    echo "$timestamped" | systemd-cat -t btcpay-lightning-backup
}

# server-b-install.sh as it goes to Server B: i18n.sh, the language and the translations of its
# own messages first, so it speaks config's language (without them it falls back to English)
gate_installer() {
    local catalog="$SCRIPT_DIR/locale/${UI_LANGUAGE:-en}.cat"
    cat -- "$SCRIPT_DIR/i18n.sh"
    printf 'UI_LANGUAGE=%q\n' "${UI_LANGUAGE:-en}"
    if [[ "${UI_LANGUAGE:-en}" != en && -f "$catalog" ]]; then
        printf '%s\n' "i18n_read <<'I18N_CATALOG_EOF'"
        python3 -I "$SCRIPT_DIR/tools/i18n.py" subset "$catalog" "$SCRIPT_DIR/server-b-install.sh"
        printf '%s\n' "I18N_CATALOG_EOF"
    fi
    cat -- "$SCRIPT_DIR/server-b-install.sh"
}

# Answers the dashboard's checklist (lnd-manager: /checklist) can't check by itself: that your LND
# seed and the GPG key are stored somewhere safe. One "name=<time>" line each, in the working folder.
SETUP_STATE_FILE="$SCRIPT_DIR/setup-state"
mark_setup_state() {
    local tmp
    tmp=$(mktemp "$SETUP_STATE_FILE.XXXXXX") || return 0
    if { grep -v "^$1=" "$SETUP_STATE_FILE" 2>/dev/null; echo "$1=$(date +%s)"; } > "$tmp"; then
        chmod 644 "$tmp"
        mv -f "$tmp" "$SETUP_STATE_FILE"
    else
        rm -f "$tmp"
    fi
}

# This script changes owners, modes and ACLs as root on paths in SERVER_A_USER's home, which
# SERVER_A_USER can change. chown, chmod and setfacl follow symlinks, so a symlink planted there
# (tmp_backups -> /etc) would hand that target to SERVER_A_USER. Stop if the path, or any folder
# between it and the home, is a symlink. chown -h and setfacl -P below also don't follow links.
# Server A's public key, read as the backup user (its .ssh is that user's: root reading it by path
# would follow a link there), and only if it is one SSH key line
read_server_a_pubkey() {
    local line
    line=$(sudo -u "$SERVER_A_USER" cat -- "$PUB_KEY_FILE" 2>/dev/null | head -n 1) || return 1
    [[ "$line" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))\ [A-Za-z0-9+/=]+(\ [[:print:]]*)?$ ]] || return 1
    printf '%s\n' "$line"
}

refuse_links() {
    local path home
    home=$(realpath -m -- "$SERVER_A_USER_HOME")
    for path in "$@"; do
        while [[ -n "$path" && "$path" != "/" ]]; do
            if [[ -L "$path" ]]; then
                log_message "❌ $path is a symlink. Stopping: changing it as root could hand its target to $SERVER_A_USER."
                exit 1
            fi
            [[ "$(realpath -m -- "$path")" == "$home" ]] && break
            path=$(dirname -- "$path")
        done
    done
}

# ----------------------------
# Settings that may need a prompt
# ----------------------------
# save_config_value, ask_config_value, check_config_value, upgrade_config and the checks for
# Server B's address, user and port are in config-lib.sh, shared with serverb-scripts.sh
if ! source "$SCRIPT_DIR/config-lib.sh"; then
    echo "❌ Failed to load $SCRIPT_DIR/config-lib.sh (keep it next to setup_script.sh)"
    exit 1
fi

# === Language (UI_LANGUAGE) ===
# Asked first, in every available language, so everything after it is in the chosen one. The
# list is the translations in locale/ (English always). Saved after upgrade_config below, which
# gives older configs the UI_LANGUAGE line.
if ! source "$SCRIPT_DIR/i18n.sh"; then
    echo "❌ Failed to load $SCRIPT_DIR/i18n.sh (keep it next to setup_script.sh)"
    exit 1
fi
i18n_languages "$SCRIPT_DIR/locale"
language_available() {
    local code
    for code in "${I18N_LANGUAGES[@]}"; do
        [[ "$1" == "$code" ]] && return 0
    done
    return 1
}
CHOSEN_LANGUAGE=""
if [[ -z "${UI_LANGUAGE:-}" ]] && ! $CHECK_ONLY; then
    words=()
    for code in "${I18N_LANGUAGES[@]}"; do
        words+=("${I18N_WORD[$code]:-$code}")
    done
    header=$(printf ' / %s' "${words[@]}")
    printf '%s:\n' "${header:3}"
    for i in "${!I18N_LANGUAGES[@]}"; do
        code="${I18N_LANGUAGES[$i]}"
        printf '  %d) %s\n' "$((i + 1))" "${I18N_NAMES[$code]:-$code}"
    done
    while true; do
        read -r -p "1-${#I18N_LANGUAGES[@]}: " answer || exit 1
        if [[ "$answer" =~ ^[0-9]+$ ]] && (( 10#$answer >= 1 && 10#$answer <= ${#I18N_LANGUAGES[@]} )); then
            CHOSEN_LANGUAGE="${I18N_LANGUAGES[$((10#$answer - 1))]}"
        elif language_available "$answer"; then
            CHOSEN_LANGUAGE="$answer"
        else
            continue
        fi
        break
    done
    UI_LANGUAGE="$CHOSEN_LANGUAGE"
elif [[ -n "${UI_LANGUAGE:-}" ]] && ! language_available "$UI_LANGUAGE"; then
    echo "❌ UI_LANGUAGE in config is \"$UI_LANGUAGE\": use one of ${I18N_LANGUAGES[*]} (a language needs locale/$UI_LANGUAGE.cat)" >&2
    exit 1
fi
i18n_load

# Prints why $1 can't be the main user; prints nothing if it can
main_user_problem() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        say "use up to 32 lowercase letters, digits, _ or -, starting with a letter or _"
    elif [[ "$name" == root ]]; then
        say "use your own account, not root"
    elif [[ -n "${SERVER_A_USER:-}" && "$name" == "$SERVER_A_USER" ]]; then
        say "%s is the backup user (SERVER_A_USER)" "$name"
    elif ! id "$name" &>/dev/null; then
        say "there is no user %s on this server (MAIN_USER must already exist)" "$name"
    fi
}

# Prints why $1 can't be the backup user; prints nothing if it can
backup_user_problem() {
    local name="$1" forbidden
    if [[ ! "$name" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        say "use up to 32 lowercase letters, digits, _ or -, starting with a letter or _"
        return 0
    fi
    for forbidden in root "$MAIN_USER" "$(id -un)" "${SUDO_USER:-}"; do
        if [[ -n "$forbidden" && "$name" == "$forbidden" ]]; then
            say "%s is root, MAIN_USER or the user running this setup" "$name"
            return 0
        fi
    done
}

# ----------------------------
# Before anything is changed
# ----------------------------
# Fills VOL_DEVS, VOL_UUIDS, VOL_DESCS with the filesystems that can be the attached volume:
# FILE_SYSTEM_TYPE, with a UUID, and not mounted anywhere except ATTACHED_VOLUME (which leaves
# out the system disk and other disks in use). Read one device at a time: raw lsblk output
# collapses empty columns.
find_volume_candidates() {
    local dev uuid fstype size label mounts mp in_use
    VOL_DEVS=() VOL_UUIDS=() VOL_DESCS=()
    while IFS= read -r dev; do
        uuid=$(lsblk -dno UUID "$dev" 2>/dev/null)
        fstype=$(lsblk -dno FSTYPE "$dev" 2>/dev/null)
        [[ -n "$uuid" && "$fstype" == "$FILE_SYSTEM_TYPE" ]] || continue
        in_use=false
        mounts=""
        while IFS= read -r mp; do
            [[ -z "$mp" ]] && continue
            [[ "$mp" == "$ATTACHED_VOLUME" ]] || in_use=true
            mounts+=" $mp"
        # findmnt, not lsblk's MOUNTPOINTS column: that column only exists since util-linux 2.37
        # (not in Debian 11 or Ubuntu 20.04), and without it every disk, the system disk too,
        # would look unmounted
        done < <(findmnt -rno TARGET --source "$dev" 2>/dev/null)
        $in_use && continue
        size=$(lsblk -dno SIZE "$dev" 2>/dev/null)
        label=$(lsblk -dno LABEL "$dev" 2>/dev/null)
        VOL_DEVS+=("$dev")
        VOL_UUIDS+=("$uuid")
        VOL_DESCS+=("$dev  ${size// /}  $fstype${label:+  label $label}${mounts:+  mounted at$mounts}  UUID $uuid")
    done < <(lsblk -rpno NAME 2>/dev/null)
}

# What setup and the backup service need, checked before setup changes anything (and alone with
# --check). ❌ stops setup; ⚠️ is something setup or you can still do later.
CHECK_FAILS=0
check_ok() { echo "  ✅ $*"; }
check_warn() { echo "  ⚠️  $*"; }
check_fail() { echo "  ❌ $*"; CHECK_FAILS=$((CHECK_FAILS + 1)); }

preflight() {
    local cmd missing=() packages=() port
    say "🔎 Checking this server and Server B before anything is changed..."

    if (( EUID != 0 )) && ! sudo true; then
        check_fail "$(T "sudo doesn't work for %s: setup needs it for the backup user, the disk and the service" "$(id -un)")"
    fi
    if ! command -v apt-get >/dev/null; then
        check_fail "$(T "No apt-get: these scripts are made for Ubuntu and Debian")"
    fi

    # Programs setup and the dashboard use (the backup installer adds its own)
    declare -A package_of=([ssh]=openssh-client [ssh-keygen]=openssh-client [ssh-keyscan]=openssh-client
                           [gpg]=gnupg [setfacl]=acl [lsblk]=util-linux [findmnt]=util-linux
                           [adduser]=adduser [python3]=python3)
    for cmd in ssh ssh-keygen ssh-keyscan gpg setfacl lsblk findmnt adduser python3; do
        command -v "$cmd" >/dev/null && continue
        missing+=("$cmd")
        [[ " ${packages[*]} " == *" ${package_of[$cmd]} "* ]] || packages+=("${package_of[$cmd]}")
    done
    if (( ${#missing[@]} > 0 )) && command -v apt-get >/dev/null; then
        say "  Missing programs: %s (packages: %s)" "${missing[*]}" "${packages[*]}"
        if ! $CHECK_ONLY && read -r -p "$(T "  Install them now (sudo apt-get install %s)? Type yes: " "${packages[*]}")" answer &&
           [[ "$answer" == yes ]]; then
            sudo apt-get update -q >/dev/null && sudo apt-get install -y -q "${packages[@]}" >/dev/null
        fi
        missing=()
        for cmd in ssh ssh-keygen ssh-keyscan gpg setfacl lsblk findmnt adduser python3; do
            command -v "$cmd" >/dev/null || missing+=("$cmd")
        done
    fi
    if (( ${#missing[@]} > 0 )); then
        check_fail "$(T "Missing programs: %s. Install them: sudo apt-get install %s" "${missing[*]}" "${packages[*]}")"
    else
        check_ok "$(T "The programs setup needs are installed")"
    fi

    # BTCPay, the way its docs install it, and the LND folders the backup service watches
    if [[ -f /etc/profile.d/btcpay-env.sh ]] && sudo test -x "$DOCKER_ROOT/btcpay-setup.sh"; then
        check_ok "$(T "BTCPay Server is installed (%s)" "$DOCKER_ROOT")"
    else
        check_fail "$(T "BTCPay Server isn't installed the usual way (btcpayserver-docker in %s, DOCKER_ROOT in config). Install BTCPay first" "$DOCKER_ROOT")"
    fi
    # chan-backup-archives isn't checked: LND makes it late, and the backup installer makes it
    if sudo test -d "$LND_DIR/data/chain/bitcoin/mainnet"; then
        check_ok "$(T "BTCPay's LND has its wallet folder")"
    else
        check_warn "$(T "BTCPay's LND has no wallet folder yet (%s/data/chain/bitcoin/mainnet). It appears once" "$LND_DIR")"
        say "      Lightning is set up in BTCPay. Setup does the rest; the backup service can be installed"
        say "      once it exists (lnd-manager: /install)."
    fi
    if [[ -n "${LND_CONTAINER_NAME:-}" ]] && command -v docker >/dev/null &&
       [[ "$(sudo docker inspect -f '{{.State.Running}}' "$LND_CONTAINER_NAME" 2>/dev/null)" != true ]]; then
        check_warn "$(T "BTCPay's LND container (%s) isn't running. Backups start once it runs" "$LND_CONTAINER_NAME")"
    fi

    # The attached volume
    if [[ "${BACKUP_TO_VOLUME:-yes}" != yes ]]; then
        check_ok "$(T "The attached volume is off (BACKUP_TO_VOLUME)")"
    elif [[ -n "$UUID" ]]; then
        if [[ -n "$(lsblk -rpno NAME,UUID 2>/dev/null | awk -v u="$UUID" '$2 == u { print $1 }')" ]]; then
            check_ok "$(T "The attached volume (UUID %s) is attached" "$UUID")"
        else
            check_fail "$(T "No disk with UUID %s (UUID in config) is attached. Attach the backup disk, or empty UUID to choose another" "$UUID")"
        fi
    else
        find_volume_candidates
        if (( ${#VOL_UUIDS[@]} > 0 )); then
            check_ok "$(T "%s unused %s filesystem(s) for the attached volume; setup asks which" "${#VOL_UUIDS[@]}" "$FILE_SYSTEM_TYPE")"
        else
            check_warn "$(T "No unused %s filesystem for the attached volume yet: setup explains how to prepare the disk" "$FILE_SYSTEM_TYPE")"
        fi
    fi

    # Server B's SSH port, if config names it already (otherwise setup asks for it)
    if [[ "${BACKUP_TO_SERVER_B:-yes}" != yes ]]; then
        check_ok "$(T "Server B is off (BACKUP_TO_SERVER_B)")"
    elif [[ -n "$REMOTE_SERVER" ]]; then
        port="${REMOTE_SSH_PORT:-22}"
        if timeout 10 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$REMOTE_SERVER" "$port" 2>/dev/null; then
            check_ok "$(T "Server B answers at %s, port %s" "$REMOTE_SERVER" "$port")"
        else
            check_fail "$(T "Server B doesn't answer at %s, port %s: check REMOTE_SERVER and REMOTE_SSH_PORT in config, that Server B runs, and its firewall" "$REMOTE_SERVER" "$port")"
        fi
    else
        check_ok "$(T "Server B: setup asks for its address")"
    fi

    echo
    if (( CHECK_FAILS > 0 )); then
        log_message "$(T "❌ %s problem(s) above: fix them, then run setup again. Nothing was changed." "$CHECK_FAILS")"
        exit 1
    fi
    if $CHECK_ONLY; then
        say "✅ Ready for setup. Nothing was changed."
        exit 0
    fi
    say "✅ Ready. Setup asks before each step."
    echo
}
preflight

upgrade_config || exit 1
if [[ -n "$CHOSEN_LANGUAGE" ]]; then
    save_config_value UI_LANGUAGE "$CHOSEN_LANGUAGE" || exit 1
    i18n_load
fi

# === Main user (MAIN_USER) ===
# The account that runs this setup and the dashboard. It must exist already; it's never created.
# Asked first, because the backup user must not be the same account.
if [[ -n "$MAIN_USER" ]]; then
    check_config_value MAIN_USER main_user_problem
else
    say "MAIN_USER is not set in config. It's your own account on this server, usually the one running this setup."
    running_user="${SUDO_USER:-$(id -un)}"
    [[ "$running_user" == root ]] && running_user=""
    ask_config_value MAIN_USER "$(T "Main user: ")" main_user_problem "$running_user"
    save_config_value MAIN_USER "$ASKED_VALUE" || exit 1
fi

# === Working folder (BACKUP_SCRIPTS_FOLDER) ===
# The dashboard runs setup and makes the Server B scripts from here, so it must name the folder
# this script runs from (older configs name ~/btcpay-serverbackup)
if [[ "$(realpath -m -- "$BACKUP_SCRIPTS_FOLDER")" != "$SCRIPT_DIR" ]]; then
    save_config_value BACKUP_SCRIPTS_FOLDER "$SCRIPT_DIR" || exit 1
fi

# === Backup user (SERVER_A_USER) ===
# The backup service runs as this user, so it must be its own account, never root or the
# account running this setup.
if [[ -n "$SERVER_A_USER" ]]; then
    check_config_value SERVER_A_USER backup_user_problem
    if id "$SERVER_A_USER" &>/dev/null; then
        say "User '%s' already exists." "$SERVER_A_USER"
    else
        say "Creating user '%s'..." "$SERVER_A_USER"
        if ! sudo adduser --disabled-password --gecos "" "$SERVER_A_USER"; then
            log_message "$(T "❌ Could not create user '%s'" "$SERVER_A_USER")"
            exit 1
        fi
    fi
else
    say "SERVER_A_USER is not set in config. The backup service runs as its own user; choose its name."
    backup_user=""
    while true; do
        ask_config_value SERVER_A_USER "$(T "Backup user name: ")" backup_user_problem "$backup_user"
        backup_user="$ASKED_VALUE"
        if id "$backup_user" &>/dev/null; then
            prompt=$(T "User '%s' already exists. Use it as the backup user? Type yes: " "$backup_user")
        else
            prompt=$(T "Create user '%s'? Type yes: " "$backup_user")
        fi
        if ! read -r -p "$prompt" answer; then
            exit 1
        fi
        [[ "$answer" == "yes" ]] && break
    done
    if ! id "$backup_user" &>/dev/null; then
        say "Creating user '%s'..." "$backup_user"
        if ! sudo adduser --disabled-password --gecos "" "$backup_user"; then
            log_message "$(T "❌ Could not create user '%s'" "$backup_user")"
            exit 1
        fi
    fi
    save_config_value SERVER_A_USER "$backup_user" || exit 1
fi

# === SSH key file name (KEY_FILENAME) ===
# The key lives in SERVER_A_USER's ~/.ssh. Left empty, it gets a name that says what it's for,
# without a prompt; the SSH setup below reuses a key with that name or makes one.
key_filename_problem() {
    if [[ ! "$1" =~ ^[A-Za-z0-9._-]+$ || "$1" == "." || "$1" == ".." ]]; then
        say "use a file name only (letters, digits, '.', _ or -), no folders"
    fi
}

if [[ -n "$KEY_FILENAME" ]]; then
    check_config_value KEY_FILENAME key_filename_problem
else
    save_config_value KEY_FILENAME lnd_backup_ssh_key || exit 1
fi

# === Backup destinations (BACKUP_TO_VOLUME, BACKUP_TO_SERVER_B, BACKUP_TO_GITHUB) ===
# Each one on or off; the answers already in config are suggested (destinations.sh <name> passes
# SETUP_TURN_ON=<setting> to suggest yes for the one turned on). Setup then sets up only the ones
# that are on. At least one must be on. Later: lnd-manager /destinations.
# A destination turned on is saved in config only once setup has set it up (just before the
# install at the end): stopped halfway, config keeps it off, so no install uses it unprepared.
# Turned off is saved at once.
TURNED_ON=()
yes_no_problem() {
    [[ "$1" == yes || "$1" == no ]] || say "type yes or no"
}
echo
say "Where should the backups go? Each destination is on (yes) or off (no); at least one must be on."
say "  1. The attached volume: an extra disk on this server. Quick to restore from, but on this server."
say "  2. Server B: your second server, through its backup gate. A broken-into Server A can't delete there."
say "  3. GitHub: a private repository of yours, written with a deploy key (a key for that one"
say "     repository). Free, but a broken-into Server A could delete the copies there."
while :; do
    TURNED_ON=()
    for setting in BACKUP_TO_VOLUME BACKUP_TO_SERVER_B BACKUP_TO_GITHUB; do
        case "$setting" in
            BACKUP_TO_VOLUME) prompt=$(T "1. The attached volume (yes/no): ") ;;
            BACKUP_TO_SERVER_B) prompt=$(T "2. Server B (yes/no): ") ;;
            BACKUP_TO_GITHUB) prompt=$(T "3. GitHub (yes/no): ") ;;
        esac
        current="${!setting:-}"
        [[ "$current" == yes || "$current" == no ]] || { [[ "$setting" == BACKUP_TO_GITHUB ]] && current=no || current=yes; }
        suggested="$current"
        [[ "${SETUP_TURN_ON:-}" == "$setting" ]] && suggested=yes
        ask_config_value "$setting" "$prompt" yes_no_problem "$suggested"
        if [[ "$ASKED_VALUE" == yes && "$(sed -n "s/^$setting=\"\(.*\)\"$/\1/p" "$CONFIG_FILE")" != yes ]]; then
            printf -v "$setting" '%s' yes
            [[ " ${TURNED_ON[*]} " == *" $setting "* ]] || TURNED_ON+=("$setting")
        elif [[ "$ASKED_VALUE" != "${!setting:-}" ]]; then
            save_config_value "$setting" "$ASKED_VALUE" || exit 1
        fi
    done
    if [[ "$BACKUP_TO_VOLUME" != yes && "$BACKUP_TO_SERVER_B" != yes && "$BACKUP_TO_GITHUB" != yes ]]; then
        say "❌ At least one destination must be on."
        continue
    fi
    break
done
if [[ "$BACKUP_TO_SERVER_B" != yes && "$BACKUP_TO_GITHUB" != yes ]]; then
    say "⚠️  Only the attached volume: no copy leaves this server. If this server is lost, the backups are"
    say "   lost with it. Server B or GitHub can be turned on later: lnd-manager /destinations."
fi

if [[ "$BACKUP_TO_VOLUME" == yes ]]; then
# === Attached volume: a mount point no user can swap for a symlink ===
# Older versions mounted the attached volume in the backup user's home. That user can replace
# the empty folder with a symlink while the disk isn't mounted; the next mount follows it, and
# the backup user's files land in a system folder (for example the root helper's). The mount
# point must be owned by root and outside every home folder.
NEW_ATTACHED_VOLUME="/srv/lnd-backups"
attached_in_home() {
    local real home
    real=$(realpath -m -- "$1")
    while IFS= read -r home; do
        [[ -z "$home" || "$home" == "/" ]] && continue
        home=$(realpath -m -- "$home")
        [[ "$real" == "$home" || "$real" == "$home"/* ]] && return 0
    done < <(getent passwd | cut -d: -f6)
    return 1
}
if attached_in_home "$ATTACHED_VOLUME"; then
    echo
    say "⚠️  ATTACHED_VOLUME in config is %s, inside a home folder. Its owner could swap that" "$ATTACHED_VOLUME"
    say "   folder for a symlink while the disk isn't mounted, and the next mount would follow it."
    say "   The mount point should be %s (owned by root). If the disk is already" "$NEW_ATTACHED_VOLUME"
    say "   mounted at the old place, setup moves the mount below (it asks again first)."
    if ! read -r -p "$(T "Type MOVE to set ATTACHED_VOLUME to %s: " "$NEW_ATTACHED_VOLUME")" answer || [[ "$answer" != "MOVE" ]]; then
        log_message "$(T "❌ Stopped: ATTACHED_VOLUME stays %s. Set it outside home folders to go on." "$ATTACHED_VOLUME")"
        exit 1
    fi
    require_prompt ATTACHED_VOLUME
    save_config_value ATTACHED_VOLUME "$NEW_ATTACHED_VOLUME" || exit 1
fi

# The backup disk's files belong to the backup user, so nothing on it may run as a program or
# act as a device, whatever MOUNT_OPTIONS in an older config says
MOUNT_OPTS="$MOUNT_OPTIONS"
for opt in nosuid nodev noexec; do
    [[ ",$MOUNT_OPTS," == *",$opt,"* ]] || MOUNT_OPTS+=",$opt"
done

# === Attached volume (UUID) ===
# This script mounts an existing filesystem; it never partitions or formats a disk. Left empty,
# UUID is chosen from the unused FILE_SYSTEM_TYPE filesystems and confirmed by the user, because
# the backup user is made the owner of everything on it.

# Prints why $1 can't be the attached volume's UUID; nothing if it can
uuid_problem() {
    if [[ ! "$1" =~ ^[A-Za-z0-9-]{1,64}$ ]]; then
        say "not a filesystem UUID"
    elif [[ -z "$(lsblk -rpno NAME,UUID 2>/dev/null | awk -v u="$1" '$2 == u { print $1 }')" ]]; then
        say "no disk on this server has UUID %s (is the volume attached?)" "$1"
    fi
}

# Prints why $1 isn't a number from the list or one of its UUIDs; nothing if it is
volume_choice_problem() {
    local i
    if [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= ${#VOL_UUIDS[@]} )); then
        return 0
    fi
    for i in "${!VOL_UUIDS[@]}"; do
        [[ "$1" == "${VOL_UUIDS[$i]}" ]] && return 0
    done
    say "enter a number from the list (1-%s) or one of its UUIDs" "${#VOL_UUIDS[@]}"
}

if [[ -n "$UUID" ]]; then
    check_config_value UUID uuid_problem
else
    require_prompt UUID
    echo
    say "Preparing the attached volume"
    say "  The backups need a disk of their own: a block volume from your VPS provider, or a second disk."
    say "  Not the system disk. Before going on:"
    say "  1. Attach it to this server (in the provider's panel, or plug it in). Then"
    say "        lsblk -f"
    say "     lists it, usually as /dev/sdb or /dev/vdb. A new disk shows no FSTYPE and no UUID yet."
    say "  2. Only if it is new and empty: make a %s filesystem on it. This ERASES that disk, so" "$FILE_SYSTEM_TYPE"
    say "     check its name in lsblk twice; never the disk that holds / or /var/lib/docker:"
    say "        sudo mkfs.%s -L lnd-backups /dev/sdX        (sdX = the new disk)" "$FILE_SYSTEM_TYPE"
    say "     This script never formats disks itself."
    say "  3. lsblk -f now shows its UUID. Below, choose it from the list of unused %s filesystems." "$FILE_SYSTEM_TYPE"
    say "  Don't mount it or add it to /etc/fstab yourself: setup does that, at %s" "$ATTACHED_VOLUME"
    say "  (owned by root, with %s), and gives the backup user only" "$MOUNT_OPTS"
    say "  the %s folder on it." "$(basename "$SECOND_BACKUP_DIR")"
    echo
    find_volume_candidates
    while (( ${#VOL_UUIDS[@]} == 0 )); do
        say "No unused %s filesystem found yet (or set FILE_SYSTEM_TYPE in %s to its type)." "$FILE_SYSTEM_TYPE" "$CONFIG_FILE"
        if ! read -r -p "$(T "Prepare the disk as above, then press Enter to look again (Ctrl-C to stop): ")" _; then
            exit 1
        fi
        find_volume_candidates
    done

    # Prefill the one already mounted at ATTACHED_VOLUME or named for it in /etc/fstab
    FSTAB_VOLUME_UUID=$(awk -v mp="$ATTACHED_VOLUME" '$1 !~ /^#/ && $2 == mp && $1 ~ /^UUID=/ { sub(/^UUID=/, "", $1); print $1; exit }' /etc/fstab)
    MOUNTED_VOLUME_DEV=$(findmnt -no SOURCE --mountpoint "$ATTACHED_VOLUME" 2>/dev/null)
    suggested=""
    say "Unused %s filesystems:" "$FILE_SYSTEM_TYPE"
    for i in "${!VOL_UUIDS[@]}"; do
        echo "  $(( i + 1 ))) ${VOL_DESCS[$i]}"
        if [[ "${VOL_DEVS[$i]}" == "$MOUNTED_VOLUME_DEV" || "${VOL_UUIDS[$i]}" == "$FSTAB_VOLUME_UUID" ]]; then
            suggested=$(( i + 1 ))
        fi
    done

    while true; do
        ask_config_value UUID "$(T "Volume (number or UUID): ")" volume_choice_problem "$suggested"
        choice="$ASKED_VALUE"
        for i in "${!VOL_UUIDS[@]}"; do
            if [[ "$choice" == "$(( i + 1 ))" || "$choice" == "${VOL_UUIDS[$i]}" ]]; then
                chosen=$i
            fi
        done
        say "Setup will add %s to /etc/fstab, mount it at %s and make %s the owner of %s on it." "${VOL_DEVS[$chosen]}" "$ATTACHED_VOLUME" "$SERVER_A_USER" "$SECOND_BACKUP_DIR"
        if ! read -r -p "$(T "Use %s as the attached volume? Type yes: " "${VOL_DESCS[$chosen]}")" answer; then
            exit 1
        fi
        [[ "$answer" == "yes" ]] && break
        suggested="$choice"
    done
    save_config_value UUID "${VOL_UUIDS[$chosen]}" || exit 1
fi
fi

if [[ "$BACKUP_TO_SERVER_B" == yes ]]; then
# === Server B address and SSH port ===
if [[ -n "$REMOTE_SERVER" ]]; then
    check_config_value REMOTE_SERVER remote_server_problem
else
    say "REMOTE_SERVER is not set in config."
    ask_config_value REMOTE_SERVER "$(T "Server B address (hostname or IP): ")" remote_server_problem
    save_config_value REMOTE_SERVER "$ASKED_VALUE" || exit 1
fi

if [[ -n "$REMOTE_SSH_PORT" ]]; then
    check_config_value REMOTE_SSH_PORT ssh_port_problem
else
    say "REMOTE_SSH_PORT is not set in config."
    ask_config_value REMOTE_SSH_PORT "$(T "Server B SSH port: ")" ssh_port_problem 22
    save_config_value REMOTE_SSH_PORT "$ASKED_VALUE" || exit 1
fi

# === User on Server B (SERVER_B_USER) ===
# Can't be checked from here; the SSH key setup below shows whether it works
if [[ -n "$SERVER_B_USER" ]]; then
    check_config_value SERVER_B_USER remote_user_problem
else
    say "SERVER_B_USER is not set in config. It's the user on Server B that holds the backups; Server A's key"
    say "reaches only this account. It may exist already, or Server B's user script can create it."
    ask_config_value SERVER_B_USER "$(T "User on Server B: ")" remote_user_problem
    save_config_value SERVER_B_USER "$ASKED_VALUE" || exit 1
fi

# === Server B host fingerprint (SERVER_B_KNOWN_HOST_FINGERPRINT) ===
# Fetched from Server B, then confirmed by the user against Server B itself. "SHA256:" alone
# is the placeholder older configs shipped with.
if [[ -z "$SERVER_B_KNOWN_HOST_FINGERPRINT" || "$SERVER_B_KNOWN_HOST_FINGERPRINT" == "SHA256:" ]]; then
    say "SERVER_B_KNOWN_HOST_FINGERPRINT is not set in config."
    require_prompt SERVER_B_KNOWN_HOST_FINGERPRINT
    say "🔎 Fetching Server B's host keys from %s, port %s..." "$REMOTE_SERVER" "$REMOTE_SSH_PORT"
    FETCHED_FP=""
    FETCHED_TYPE=""
    while read -r key_line; do
        [[ -z "$key_line" || "$key_line" == \#* ]] && continue
        # ssh-keygen -l prints: bits fingerprint host (TYPE)
        read -r _ fp _ key_type < <(ssh-keygen -lf - <<< "$key_line")
        key_type="${key_type//[()]/}"
        echo "   $key_type: $fp"
        # Prefer ED25519; otherwise keep the first key found
        if [[ -z "$FETCHED_FP" || "$key_type" == "ED25519" ]]; then
            FETCHED_FP="$fp"
            FETCHED_TYPE="$key_type"
        fi
    done < <(ssh-keyscan -p "$REMOTE_SSH_PORT" "$REMOTE_SERVER" 2>/dev/null)

    if [[ "$FETCHED_FP" != SHA256:* ]]; then
        log_message "$(T "❌ Could not fetch a host key from %s port %s. Check REMOTE_SERVER, REMOTE_SSH_PORT and that Server B's SSH server is running." "$REMOTE_SERVER" "$REMOTE_SSH_PORT")"
        exit 1
    fi

    case "$FETCHED_TYPE" in
        ED25519) HOST_KEY_FILE=/etc/ssh/ssh_host_ed25519_key.pub ;;
        ECDSA)   HOST_KEY_FILE=/etc/ssh/ssh_host_ecdsa_key.pub ;;
        RSA)     HOST_KEY_FILE=/etc/ssh/ssh_host_rsa_key.pub ;;
        *)       HOST_KEY_FILE="/etc/ssh/ssh_host_<type>_key.pub" ;;
    esac

    echo ""
    echo "⚠️ ================================================================="
    say "⚠️  CHECK SERVER B'S FINGERPRINT YOURSELF BEFORE YOU CONTINUE"
    echo "⚠️ ================================================================="
    say "This fingerprint was fetched over the network, so it proves nothing yet."
    say "If someone is intercepting the connection, it is THEIR key: Server A would"
    say "trust them from now on and send every backup of your Lightning node to them."
    echo ""
    say "Fetched (%s): %s" "$FETCHED_TYPE" "$FETCHED_FP"
    echo ""
    say "On Server B itself (its console, or an SSH session you already trust), run:"
    say "    ssh-keygen -lf %s" "$HOST_KEY_FILE"
    say "It must show exactly the same fingerprint, character for character."
    say "If it doesn't, or you can't check, do NOT type yes."
    echo ""
    if ! read -r -p "$(T "Type yes if Server B shows exactly this fingerprint: ")" answer || [[ "$answer" != "yes" ]]; then
        log_message "$(T "❌ Server B's host fingerprint was not confirmed. Nothing was saved.")"
        exit 1
    fi
    save_config_value SERVER_B_KNOWN_HOST_FINGERPRINT "$FETCHED_FP" || exit 1
fi

# ----------------------------
# Initial SSH connection test
# ----------------------------

# Function to ask the user if they want to view the private key
view_private_key() {
    read -p "$(T "Do you want to view the private key now so you can save it securely? (y/n): ")" view_key_choice
    if [[ "$view_key_choice" =~ ^[Yy]$ ]]; then
        say "📋 Here is your private key (ensure you save it in a secure location):"
        sudo -u "$SERVER_A_USER" cat -- "$KEY_PATH"
    else
        say "❗ Make sure to save the private key in a secure location later."
    fi
}

# How Server B answers this key: "gate" once its backup gate is installed (server-b-install.sh:
# the key may then only put, get and list backups), "shell" while it still gives the key a
# shell, "none" when the key doesn't work there.
server_b_mode() {
    local ssh_cmd=(sudo -u "$SERVER_A_USER" ssh -n -o BatchMode=yes -o ConnectTimeout=5 -i "$KEY_PATH"
                   -p "$REMOTE_SSH_PORT" "$SERVER_B_USER@$REMOTE_SERVER")
    if [[ "$(timeout 60 "${ssh_cmd[@]}" ping 2>/dev/null | head -c 4096)" == "ok" ]]; then
        echo gate
    elif [[ "$("${ssh_cmd[@]}" 'echo shell-ok' 2>/dev/null)" == "shell-ok" ]]; then
        echo shell
    else
        echo none
    fi
}

say "🔍 Testing if SSH access already works..."

SKIP_SSH_SETUP=false
if [[ "$(server_b_mode)" != none ]]; then
    say "✅ SSH key already set up and working. Skipping setup."
    SKIP_SSH_SETUP=true
    
    # Call the function to ask if the user wants to view the private key
    view_private_key
else
    say "❌ SSH connection failed. Proceeding with SSH key setup..."
fi

if [ "$SKIP_SSH_SETUP" = false ]; then
    say "🔐 Setting up SSH key for %s..." "$SERVER_A_USER"

    sudo -u "$SERVER_A_USER" mkdir -p "$SERVER_A_USER_HOME/.ssh"

    if [ -f "$KEY_PATH" ]; then
        say "🔑 SSH key already exists at %s. Skipping generation." "$KEY_PATH"
    else
        # Prompt to paste private key or generate new key
        read -p "$(T "Do you want to paste an existing SSH private key? (y/n): ")" paste_key_choice
        if [[ "$paste_key_choice" =~ ^[Yy]$ ]]; then
            say "📋 Press ENTER, then paste your SSH private key. Press CTRL+D when finished:"
            # Read multiline input until EOF (CTRL+D)
            PASTED_PRIVATE_KEY=$(cat)

            if [ -n "$PASTED_PRIVATE_KEY" ]; then
                # Created with mode 600 before the key goes in, so it's never readable by others;
                # by the backup user, in its own .ssh, after making sure that is no link
                refuse_links "$SERVER_A_USER_HOME/.ssh" "$KEY_PATH"
                if ! sudo -u "$SERVER_A_USER" install -m 600 /dev/null "$KEY_PATH" ||
                   ! printf '%s\n' "$PASTED_PRIVATE_KEY" | sudo -u "$SERVER_A_USER" tee "$KEY_PATH" > /dev/null; then
                    say "❌ Failed to save the private key to %s. Exiting." "$KEY_PATH"
                    exit 1
                fi
                say "✅ Private SSH key saved to %s." "$KEY_PATH"

                # Derive the public key. tee writes it as SERVER_A_USER: a shell redirect would run
                # as the calling user, who can't write into SERVER_A_USER's .ssh.
                # -P "" fails at once on a passphrase-protected key, which the service couldn't use.
                if ! PUB_KEY_LINE=$(sudo -u "$SERVER_A_USER" ssh-keygen -y -P "" -f "$KEY_PATH") ||
                   ! printf '%s\n' "$PUB_KEY_LINE" | sudo -u "$SERVER_A_USER" tee "$PUB_KEY_FILE" > /dev/null ||
                   ! sudo chmod 644 "$PUB_KEY_FILE"; then
                    say "❌ Could not derive a public key. Is the pasted key valid and without a passphrase? Exiting."
                    # Removed so a rerun asks for the key again instead of skipping this step
                    sudo rm -f -- "$KEY_PATH" "$PUB_KEY_FILE"
                    exit 1
                fi
                say "✅ Derived public key saved to %s." "$PUB_KEY_FILE"
            else
                say "❌ No key data received. Exiting."
                exit 1
            fi
        else
            if ! sudo -u "$SERVER_A_USER" ssh-keygen -t ed25519 -N "" -f "$KEY_PATH"; then
                say "❌ SSH key generation failed. Exiting."
                exit 1
            fi
            say "✅ New SSH key generated at %s." "$KEY_PATH"
            
            # Call the function to ask if the user wants to view the private key
            view_private_key
        fi
    fi

    # Set permissions
    refuse_links "$SERVER_A_USER_HOME/.ssh" "$KEY_PATH" "$PUB_KEY_FILE"
    sudo chown -h -R "$SERVER_A_USER":"$SERVER_A_USER" "$SERVER_A_USER_HOME/.ssh"
    sudo chmod 700 "$SERVER_A_USER_HOME/.ssh"
    sudo chmod 600 "$KEY_PATH"
    sudo chmod 644 "$PUB_KEY_FILE"

    # Verify host fingerprint
    say "🔎 Fetching host fingerprints..."
    SCANNED_KEYS=$(ssh-keyscan -p "$REMOTE_SSH_PORT" "$REMOTE_SERVER" 2>/dev/null)

    # Keep only the scanned host keys whose fingerprint matches, so known_hosts gets exactly what was verified
    HOST_KEYS=""
    MATCHED_KEYS=""
    while read -r KEY_LINE; do
        [[ -z "$KEY_LINE" || "$KEY_LINE" == \#* ]] && continue
        HOST_KEY=$(ssh-keygen -lf - <<< "$KEY_LINE" | awk '{print $2}')
        HOST_KEYS+="$HOST_KEY"$'\n'
        if [ "$HOST_KEY" = "$SERVER_B_KNOWN_HOST_FINGERPRINT" ]; then
            MATCHED_KEYS+="$KEY_LINE"$'\n'
        fi
    done <<< "$SCANNED_KEYS"

    if [ -n "$MATCHED_KEYS" ]; then
        say "✅ Host fingerprint matches expected value."

        sudo -u "$SERVER_A_USER" mkdir -p "$SERVER_A_USER_HOME/.ssh"
        refuse_links "$SERVER_A_USER_HOME/.ssh"
        sudo chown -h "$SERVER_A_USER":"$SERVER_A_USER" "$SERVER_A_USER_HOME/.ssh"
        sudo chmod 700 "$SERVER_A_USER_HOME/.ssh"

        printf '%s' "$MATCHED_KEYS" | \
            sudo -u "$SERVER_A_USER" tee -a "$SERVER_A_USER_HOME/.ssh/known_hosts" > /dev/null

        refuse_links "$SERVER_A_USER_HOME/.ssh/known_hosts"
        sudo chown -h "$SERVER_A_USER":"$SERVER_A_USER" "$SERVER_A_USER_HOME/.ssh/known_hosts"
        sudo chmod 644 "$SERVER_A_USER_HOME/.ssh/known_hosts"
    else
        say "❌ ERROR: Host fingerprint does not match expected fingerprint!"
        say "Expected: %s" "$SERVER_B_KNOWN_HOST_FINGERPRINT"
        say "Found:"
        echo "$HOST_KEYS"
        say "Check SERVER_B_KNOWN_HOST_FINGERPRINT in config, or confirm Server B's host keys on Server B itself."
        exit 1
    fi

    # A SERVER_B_USER made by serverb-user-setup.sh has no password, so the key can't be copied
    # with one: that script puts the key in, restricted, instead
    echo
    say "Server A's key must get into ~/.ssh/authorized_keys of %s on Server B. Either:" "$SERVER_B_USER"
    say "  1) %s exists on Server B and you know its password: setup copies the key now" "$SERVER_B_USER"
    say "  2) setup makes serverb-user-setup.sh for you to run on Server B with sudo. It creates"
    say "     %s (no password, key login only), or sets up the existing one, with this key" "$SERVER_B_USER"
    while true; do
        read -r -p "$(T "Choose 1 or 2: ")" key_way || exit 1
        [[ "$key_way" == 1 || "$key_way" == 2 ]] && break
    done
    if [[ "$key_way" == 2 ]]; then
        "$SCRIPT_DIR/serverb-scripts.sh" user || exit 1
        echo
        log_message "$(T "ℹ️ Run serverb-user-setup.sh on Server B, then setup again: it goes on from here.")"
        exit 0
    fi

    # Copy public key to remote server
    say "📤 Copying SSH public key to remote server..."

    PUB_KEY_CONTENT=$(read_server_a_pubkey || true)
    if [[ "$PUB_KEY_CONTENT" != ssh-* ]]; then
        say "❌ No public key found in %s. Exiting." "$PUB_KEY_FILE"
        exit 1
    fi

    # Run as SERVER_A_USER: the key is only readable by them and the host key is in their known_hosts.
    # The key goes over stdin, so its text never becomes part of the remote command
    # (ssh asks for the password on the terminal, not on stdin).
    printf '%s\n' "$PUB_KEY_CONTENT" | sudo -u "$SERVER_A_USER" "${SSH_COMMAND_ARR[@]}" '
    IFS= read -r key || exit 1
    mkdir -p ~/.ssh && chmod 700 ~/.ssh &&
    { grep -qxF -- "$key" ~/.ssh/authorized_keys 2>/dev/null || printf "%s\n" "$key" >> ~/.ssh/authorized_keys; } &&
    chmod 600 ~/.ssh/authorized_keys
	'

    if [ $? -eq 0 ]; then
        say "✅ Public key successfully copied to remote server."
    else
        say "❌ Failed to automatically copy public key to remote server."
        echo ""
        say "=== MANUAL STEP REQUIRED ==="
        say "Copy the public key file:"
        echo "  📎 $PUB_KEY_FILE"
        say "To the remote server: %s@%s" "$SERVER_B_USER" "$REMOTE_SERVER"
        say "Then append its contents to ~/.ssh/authorized_keys on the remote server."
        say "You can run the following commands on the remote server:"
        echo "------------------------------------------------------------"
        say "mkdir -p ~/.ssh"
        say "chmod 700 ~/.ssh"
        say "cat <paste or copy contents of %s> >> ~/.ssh/authorized_keys" "$PUB_KEY_FILE"
        say "chmod 600 ~/.ssh/authorized_keys"
        echo "------------------------------------------------------------"
        echo ""

        read -p "$(T "💡 Would you like to manually paste the public SSH key now? (y/n): ")" paste_choice
        if [[ "$paste_choice" =~ ^[Yy]$ ]]; then
            say "📋 Press ENTER, then paste the public SSH key. Press CTRL+D when finished:"
            PASTED_KEY=$(cat)
            if [ -n "$PASTED_KEY" ]; then
                # The key goes on stdin: inside the remote command, a ' in the paste would run
                # commands on Server B
                printf '%s\n' "$PASTED_KEY" | sudo -u "$SERVER_A_USER" ssh -p "$REMOTE_SSH_PORT" "$SERVER_B_USER@$REMOTE_SERVER" \
                    'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'

                if [ $? -eq 0 ]; then
                    say "✅ Public key manually added to remote server successfully."
                else
                    say "❌ Failed to add pasted public key to remote server."
                fi
            else
                say "❌ No key was entered. Skipping manual key addition."
            fi
        fi

        echo ""
        say "After doing this, test the connection by running:"
        say "  sudo -u %s ssh -i %s -p %s %s@%s" "$SERVER_A_USER" "$KEY_PATH" "$REMOTE_SSH_PORT" "$SERVER_B_USER" "$REMOTE_SERVER"
        echo ""
    fi
fi

# ----------------------------
# Final SSH connection test (only if setup was attempted)
# ----------------------------
if [ "$SKIP_SSH_SETUP" = false ]; then
    say "🧪 Final test of SSH connection..."
    if [[ "$(server_b_mode)" != none ]]; then
        say "✅ Final SSH connection test succeeded."
    else
        say "❌ Final SSH connection test failed. Exiting."
        exit 1
    fi
fi

# ----------------------------
# Server B's backup gate
# ----------------------------
# While the key still gets a shell on Server B, whoever got the backup user here could delete
# every backup there. The gate (server-b-install.sh, run as SERVER_B_USER, no root) limits the key
# to storing new backups and listing and fetching them; Server B rotates them itself. Installed
# over the key while it still has a shell; afterwards only another login to Server B can change it.
if [[ "$(server_b_mode)" == shell ]]; then
    echo
    say "⚠️  Server B still gives this key a full shell: anyone who got %s here could delete" "$SERVER_A_USER"
    say "   every backup there. Setup can install Server B's backup gate now (as %s, no root):" "$SERVER_B_USER"
    say "   the key may then only store new backups, list and fetch them, and Server B rotates them"
    say "   itself. Keep another way into Server B (your own key or password) for later changes."
    say "   The backup service and lnd-wallet.sh need the gate: without it, copies to Server B fail."
    if read -r -p "$(T "Type yes to install the backup gate on Server B: ")" answer && [[ "$answer" == "yes" ]]; then
        GATE_SSH=(sudo -u "$SERVER_A_USER" ssh -o BatchMode=yes -i "$KEY_PATH" -p "$REMOTE_SSH_PORT" "$SERVER_B_USER@$REMOTE_SERVER")
        # Expanded on Server B, not here
        # shellcheck disable=SC2088
        GATE_DIR='~/.local/share/lnd-backup-gate'
        if gate_installer | "${GATE_SSH[@]}" "mkdir -p $GATE_DIR && cat > $GATE_DIR/server-b-install.sh" &&
           read_server_a_pubkey | "${GATE_SSH[@]}" "cat > $GATE_DIR/server-a-key.pub" &&
           "${GATE_SSH[@]}" -n "bash $GATE_DIR/server-b-install.sh $GATE_DIR/server-a-key.pub" &&
           [[ "$(server_b_mode)" == gate ]]; then
            log_message "$(T "✅ Server B's backup gate is installed: this key can no longer delete or overwrite there")"
        else
            # For installing it by hand: the same installer, in config's language, and the key, in
            # the folder serverb-scripts.sh uses too
            out="${SERVER_B_SCRIPTS_DIR:-$HOME/serverb-scripts}"
            if [[ ! -L "$out" ]] && install -d -m 700 "$out" &&
               gate_installer > "$out/server-b-install.sh" && chmod 600 "$out/server-b-install.sh" &&
               read_server_a_pubkey > "$out/server-a-key.pub" && chmod 600 "$out/server-a-key.pub"; then
                log_message "$(T "❌ Installing Server B's backup gate failed. Install it there by hand: copy server-b-install.sh and server-a-key.pub from %s to Server B and run there, as %s: bash server-b-install.sh server-a-key.pub" "$out" "$SERVER_B_USER")"
            else
                log_message "$(T "❌ Installing Server B's backup gate failed. Install it there by hand: copy server-b-install.sh and %s to Server B and run, as %s: ./server-b-install.sh server-a-key.pub" "$PUB_KEY_FILE" "$SERVER_B_USER")"
            fi
            exit 1
        fi
    else
        log_message "$(T "⚠️ Server B's backup gate not installed: copies to Server B will fail until it is (server-b-install.sh)")"
    fi
elif [[ "$(server_b_mode)" == gate ]]; then
    log_message "$(T "✅ Server B answers through its backup gate")"
fi
fi

# ----------------------------
# GitHub (BACKUP_TO_GITHUB)
# ----------------------------
# A deploy key for the backup user, made here, that you add to your private repository. Everything
# with it runs as the backup user (its key, its known_hosts with github.com's pinned host key).
github_as_backup_user() {
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
if [[ "$BACKUP_TO_GITHUB" == yes ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/github-lib.sh"
    echo
    say "GitHub: make a new, empty, PRIVATE repository for the backups only (github.com/new), for"
    say "example lnd-backups. Not this project's repository, and never a public one."
    if [[ -n "$GITHUB_REPO" ]]; then
        check_config_value GITHUB_REPO github_repo_problem
    else
        ask_config_value GITHUB_REPO "$(T "The repository, as owner/name: ")" github_repo_problem
        save_config_value GITHUB_REPO "$ASKED_VALUE" || exit 1
    fi
    # A public repository answers anyone; a private one looks missing to anyone without access
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://api.github.com/repos/$GITHUB_REPO" || true)
    if [[ "$code" == 200 ]]; then
        log_message "$(T "❌ %s is a public repository: anyone could download the backups (encrypted, but still). Make it private on GitHub (Settings, Danger Zone), then run setup again." "$GITHUB_REPO")"
        exit 1
    elif [[ "$code" != 404 ]]; then
        # A rate limit (403/429), GitHub's API down or no connection: it can't be told from here
        say "⚠️  GitHub didn't answer whether %s is private (HTTP %s). Check it yourself: open" "$GITHUB_REPO" "$code"
        say "   https://github.com/%s in a private browser window, not logged in: it must say \"Page not found\"." "$GITHUB_REPO"
        if ! read -r -p "$(T "Type yes if it is private: ")" answer || [[ "$answer" != yes ]]; then
            log_message "$(T "❌ Stopped: GitHub isn't set up. Run setup again to go on.")"
            exit 1
        fi
    fi
    github_key=$(github_key_path)
    refuse_links "$SERVER_A_USER_HOME/.ssh" "$github_key"
    sudo -u "$SERVER_A_USER" mkdir -p -m 700 "$SERVER_A_USER_HOME/.ssh"
    if ! sudo -u "$SERVER_A_USER" test -f "$github_key"; then
        sudo -u "$SERVER_A_USER" ssh-keygen -q -t ed25519 -N "" -C "lnd-backup deploy key $(hostname)" -f "$github_key" ||
            { log_message "$(T "❌ Could not make the deploy key %s" "$github_key")"; exit 1; }
        log_message "$(T "✅ Deploy key made: %s" "$github_key")"
    fi
    printf '%s\n' "$GITHUB_HOST_KEY" | sudo -u "$SERVER_A_USER" tee "$(github_known_hosts)" >/dev/null
    if github_as_backup_user 'github_git ls-remote "$(github_url)" >/dev/null 2>&1 && github_git_push_test'; then
        log_message "$(T "✅ The deploy key can write to %s" "$GITHUB_REPO")"
    else
        echo
        say "Add this deploy key to %s on GitHub: the repository's Settings, Deploy keys, Add deploy key." "$GITHUB_REPO"
        say "Paste the line below, and tick \"Allow write access\" (the backups are written with it):"
        echo
        sudo -u "$SERVER_A_USER" cat -- "$github_key.pub"
        echo
        while :; do
            read -r -p "$(T "Type yes once it is added (or no to stop): ")" answer || exit 1
            [[ "$answer" == no ]] && { log_message "$(T "❌ Stopped: GitHub isn't set up. Run setup again to go on.")"; exit 1; }
            [[ "$answer" == yes ]] || continue
            if github_as_backup_user 'github_git ls-remote "$(github_url)" >/dev/null 2>&1'; then
                if github_as_backup_user 'github_git_push_test'; then
                    log_message "$(T "✅ The deploy key can write to %s" "$GITHUB_REPO")"
                    break
                fi
                say "❌ The key can read %s but not write: tick \"Allow write access\" for it on GitHub." "$GITHUB_REPO"
            else
                say "❌ GitHub doesn't let this key into %s yet: check the repository name and the deploy key." "$GITHUB_REPO"
            fi
        done
    fi
    # Never a key added to the GitHub account: it would write to every repository of that account
    key_state=0
    github_as_backup_user 'github_key_check' || key_state=$?
    while (( key_state == 1 )); do
        echo
        say "Add the key to the repository only: remove it from your account (github.com: Settings, SSH and GPG"
        say "keys), then add it in %s's Settings, Deploy keys, with \"Allow write access\":" "$GITHUB_REPO"
        echo
        sudo -u "$SERVER_A_USER" cat -- "$github_key.pub"
        echo
        read -r -p "$(T "Type yes once it is moved (or no to stop): ")" answer || exit 1
        [[ "$answer" == no ]] && { log_message "$(T "❌ Stopped: GitHub isn't set up. Run setup again to go on.")"; exit 1; }
        key_state=0
        github_as_backup_user 'github_key_check' || key_state=$?
        if (( key_state != 1 )) && ! github_as_backup_user 'github_git_push_test'; then
            say "❌ The key can't write to %s: tick \"Allow write access\" for it on GitHub." "$GITHUB_REPO"
            key_state=1
        fi
    done
    if (( key_state == 0 )); then
        log_message "$(T "✅ GitHub greets the key as a deploy key of %s alone" "$GITHUB_REPO")"
    else
        log_message "$(T "⚠️ GitHub didn't say which repository the key is for; the backup service checks it again before each upload")"
    fi
fi

say "=== Setup complete on Server A ==="

# === GPG Keyfile handling logic (paste or generate) ===

# Make .gnupg folder
sudo -u "$SERVER_A_USER" mkdir -p "$GPG_KEY_DIR"

# Set permissions
refuse_links "$GPG_KEY_DIR"
sudo chown -h -R "$SERVER_A_USER:$SERVER_A_USER" "$GPG_KEY_DIR"
sudo chmod 700 "$GPG_KEY_DIR"

if ! sudo -u "$SERVER_A_USER" gpg --list-secret-keys "$GPG_KEY_NAME" > /dev/null 2>&1; then
    log_message "$(T "🔐 GPG private key not found for %s." "$GPG_KEY_NAME")"

    read -p "$(T "Do you want to paste an existing ASCII-armored GPG private key? (y/n): ")" use_gpg_key_now
    if [[ "$use_gpg_key_now" =~ ^[Yy]$ ]]; then
        log_message "$(T "🔐 Please paste your ASCII-armored GPG private key below.")"
        log_message "$(T "Press ENTER to begin, then paste the key, then press CTRL+D when done:")"
        echo

        # Read multi-line GPG key input
        pasted_key=$(cat)

        if [[ -z "$pasted_key" ]]; then
            log_message "$(T "❌ No GPG key content received. Aborting.")"
            exit 1
        fi

        # Import the key into GPG keyring
        echo "$pasted_key" | sudo -u "$SERVER_A_USER" gpg --batch --import

        if [ $? -eq 0 ]; then
            log_message "$(T "✅ GPG key imported successfully.")"
            # Pasted from somewhere: it is stored outside this server already
            mark_setup_state gpg_key_saved
        else
            log_message "$(T "❌ GPG key import failed.")"
            exit 1
        fi

    else
        read -p "$(T "Would you like to generate a new GPG key for %s? (y/n): " "$GPG_KEY_NAME")" generate_gpg
        if [[ "$generate_gpg" =~ ^[Yy]$ ]]; then
            log_message "$(T "🛠️ Generating new GPG key...")"
            sudo -u "$SERVER_A_USER" gpg --batch --gen-key <<-EOF
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Key-Usage: sign
Subkey-Type: ecdh
Subkey-Curve: cv25519
Subkey-Usage: encrypt
Name-Real: Backup
Name-Email: $GPG_KEY_NAME
Expire-Date: 0
%commit
EOF

            if [ $? -eq 0 ]; then
                log_message "$(T "✅ GPG key generated successfully.")"

                # Export private key to file. gpg writes it as SERVER_A_USER: a shell redirect
                # would run as the calling user, who can't write into SERVER_A_USER's .gnupg.
                if sudo -u "$SERVER_A_USER" gpg --batch --yes --armor --output "$GPG_KEY_PATH" \
                        --export-secret-keys "$GPG_KEY_NAME" &&
                   refuse_links "$GPG_KEY_PATH" &&
                   sudo chmod 600 "$GPG_KEY_PATH"; then
                    log_message "$(T "✅ GPG private key exported to %s for backup." "$GPG_KEY_PATH")"
                else
                    log_message "$(T "❌ GPG private key export to %s failed." "$GPG_KEY_PATH")"
                    exit 1
                fi

                read -p "$(T "Would you like to export and view the private key (for backup)? (y/n): ")" export_gpg_key
                if [[ "$export_gpg_key" =~ ^[Yy]$ ]]; then
                    echo
                    say "⚠️  COPY AND STORE THIS PRIVATE KEY SECURELY:"
                    echo "--------------------------------------------------"
                    sudo cat "$GPG_KEY_PATH"
                    echo "--------------------------------------------------"
                    echo

                    while true; do
                        read -p "$(T "Have you saved this GPG key securely? Type 'yes' or 'y' to continue: ")" confirm
                        if [[ "${confirm,,}" =~ ^(yes|y)$ ]]; then
                            mark_setup_state gpg_key_saved
                            break
                        else
                            say "❗ Please type 'yes' or 'y' only when you've saved the key securely."
                        fi
                    done
                fi
            else
                log_message "$(T "❌ GPG key generation failed.")"
                exit 1
            fi
        else
            log_message "$(T "❌ A GPG key is required. Exiting.")"
            exit 1
        fi
    fi
else
    log_message "$(T "🔐 GPG key for %s already exists." "$GPG_KEY_NAME")"


    read -p "$(T "Would you like to view/export the existing private key (ASCII-armored)? (y/n): ")" view_gpg
    if [[ "$view_gpg" =~ ^[Yy]$ ]]; then
        echo
        say "⚠️  COPY AND STORE THIS PRIVATE KEY SECURELY:"
        echo "--------------------------------------------------"
        sudo -u "$SERVER_A_USER" gpg --armor --export-secret-keys "$GPG_KEY_NAME"
        echo "--------------------------------------------------"
        echo

        while true; do
            read -p "$(T "Have you saved this GPG key securely? Type 'yes' or 'y' to continue: ")" confirm
            if [[ "${confirm,,}" =~ ^(yes|y)$ ]]; then
                mark_setup_state gpg_key_saved
                break
            else
                say "❗ Please type 'yes' or 'y' only when you've saved the key securely."
            fi
        done
    fi
fi

# --- Sanity Check --- #
	
# Check if GPG_KEY_DIR exists (as root: home folders are 750, so the calling user may not see inside)
if ! sudo test -d "$GPG_KEY_DIR"; then
    say "❌ GPG key directory %s does not exist. Exiting." "$GPG_KEY_DIR"
    exit 1
else
    say "✅ GPG key directory %s exists." "$GPG_KEY_DIR"
fi

# Check if GPG_RECIPIENT is valid
if ! sudo -u "$SERVER_A_USER" gpg --list-keys "$GPG_RECIPIENT" &>/dev/null; then
    log_message "$(T "❌ GPG recipient %s not found. Exiting." "$GPG_RECIPIENT")"
    exit 1
else
    log_message "$(T "✅ GPG recipient %s found successfully." "$GPG_RECIPIENT")"
fi

# === Which key the service uses (GPG_FINGERPRINT) ===
# The primary-key fingerprint of every key matching GPG_RECIPIENT (a pub line, then its fpr line;
# the fpr lines after sub lines are subkeys). gpg matches names as substrings, so a second key
# imported under the same or a longer name shows up here too.
mapfile -t GPG_FPRS < <(sudo -u "$SERVER_A_USER" gpg --with-colons --list-keys "$GPG_RECIPIENT" 2>/dev/null |
    awk -F: '/^pub/ { want = 1; next } /^fpr/ && want { print $10; want = 0 }')

if [[ -n "${GPG_FINGERPRINT:-}" ]]; then
    # A value in config is used as it is, but it must be one of these keys or every backup fails
    if [[ " ${GPG_FPRS[*]} " != *" $GPG_FINGERPRINT "* ]]; then
        log_message "$(T "❌ GPG_FINGERPRINT in config (%s) isn't the fingerprint of a key matching %s in %s's keyring. Fix it in %s (or empty it to have it filled in)." "$GPG_FINGERPRINT" "$GPG_RECIPIENT" "$SERVER_A_USER" "$CONFIG_FILE")"
        sudo -u "$SERVER_A_USER" gpg --list-keys "$GPG_RECIPIENT" 2>/dev/null
        exit 1
    fi
    GPG_FPR="$GPG_FINGERPRINT"
elif (( ${#GPG_FPRS[@]} == 1 )); then
    GPG_FPR="${GPG_FPRS[0]}"
    save_config_value GPG_FINGERPRINT "$GPG_FPR" || exit 1
elif (( ${#GPG_FPRS[@]} == 0 )); then
    log_message "$(T "❌ No fingerprint found for GPG key %s" "$GPG_RECIPIENT")"
    exit 1
else
    # Picking one would risk encrypting every backup to the wrong key
    log_message "$(T "❌ %s keys in %s's keyring match %s:" "${#GPG_FPRS[@]}" "$SERVER_A_USER" "$GPG_RECIPIENT")"
    sudo -u "$SERVER_A_USER" gpg --list-keys "$GPG_RECIPIENT" 2>/dev/null
    log_message "$(T "❌ Set GPG_FINGERPRINT in %s to the one the backups should use, or delete the others (sudo -u %s gpg --delete-secret-and-public-key <fingerprint>), then rerun setup_script.sh." "$CONFIG_FILE" "$SERVER_A_USER")"
    exit 1
fi

# The service signs every backup with this key, so its private key must be here too
if ! sudo -u "$SERVER_A_USER" gpg --list-secret-keys "$GPG_FPR" &>/dev/null; then
    log_message "$(T "❌ The private key for %s isn't in %s's keyring; the service needs it to sign backups." "$GPG_FPR" "$SERVER_A_USER")"
    exit 1
fi

# Trust the key fully, so the backup service's batch-mode gpg accepts it.
# A generated key already has this; an imported (pasted) key doesn't.
if printf '%s:6:\n' "$GPG_FPR" | sudo -u "$SERVER_A_USER" gpg --batch --import-ownertrust; then
    log_message "$(T "✅ GPG key trust level set to ultimate.")"
else
    log_message "$(T "❌ Setting GPG key trust failed.")"
    exit 1
fi

# === An expiry date on the key ===
# The day it passes, gpg won't encrypt to the key, so every backup fails. Keys made here never
# expire; one pasted in may. The earliest date of the key and its encryption subkeys counts.
gpg_key_expiry() {
    sudo -u "$SERVER_A_USER" gpg --with-colons --list-keys "$GPG_FPR" 2>/dev/null |
        awk -F: '($1 == "pub" || ($1 == "sub" && $12 ~ /e/)) && $2 != "r" && $7 ~ /^[0-9]+$/ {
                     if (min == "" || $7 < min) min = $7 }
                 END { print min }'
}
key_expiry=$(gpg_key_expiry)
if [[ -n "$key_expiry" ]]; then
    echo
    say "⚠️  The GPG key %s expires on %s. From that day the backup service can't make backups." "$GPG_FPR" "$(date -d "@$key_expiry" +%Y-%m-%d)"
    say "   Removing the expiry changes only the date (gpg may ask for the key's passphrase)."
    read -r -p "$(T "Remove the expiry now? Type yes: ")" answer || answer=""
    if [[ "$answer" == yes ]] &&
       sudo -u "$SERVER_A_USER" gpg --pinentry-mode loopback --quick-set-expire "$GPG_FPR" 0 &&
       sudo -u "$SERVER_A_USER" gpg --pinentry-mode loopback --quick-set-expire "$GPG_FPR" 0 '*' &&
       [[ -z "$(gpg_key_expiry)" ]]; then
        log_message "$(T "✅ The GPG key no longer expires. Save it again where you keep it: that copy still has the old date.")"
    else
        log_message "$(T "⚠️ The GPG key keeps its expiry; lnd-manager warns 30 days ahead. Later: sudo -u %s gpg --quick-set-expire %s 0, then again with '*' at the end." "$SERVER_A_USER" "$GPG_FPR")"
    fi
fi


# Install ACL, inotify-tools and fuse
say "Installing ACL and inotify-tools..."
sudo apt update
sudo apt install -y acl inotify-tools
say "ACL and inotify-tools installation complete."

# Create and grant full control over the backup log file to the specified user
say "Creating the backup log file at %s and granting full control to %s..." "$LIGHTNING_BACKUP_LOG_FILE" "$MAIN_USER"
sudo touch "$LIGHTNING_BACKUP_LOG_FILE"
sudo setfacl -m u:"$MAIN_USER":rw "$LIGHTNING_BACKUP_LOG_FILE"
log_message "$(T "Backup log file created and permissions set.")"

# Always apply ACLs to the user home directory
log_message "$(T "Granting full control over %s to %s..." "$SERVER_A_USER_HOME" "$MAIN_USER")"
refuse_links "$SERVER_A_USER_HOME"
sudo setfacl -P -R -m u:"$MAIN_USER":rwx "$SERVER_A_USER_HOME"
sudo setfacl -d -m u:"$MAIN_USER":rwx "$SERVER_A_USER_HOME"
log_message "$(T "Permissions for %s set." "$SERVER_A_USER_HOME")"

# Remove ACL for the SSH key
log_message "$(T "Removing ACL for SSH private key at %s..." "$KEY_PATH")"
refuse_links "$KEY_PATH" "$GPG_KEY_PATH" "$GPG_KEY_DIR"
# The private keys are the backup user's alone: the SSH key (Server B) and the deploy key (GitHub)
for private_key in "$KEY_PATH" "$SERVER_A_USER_HOME/.ssh/${GITHUB_KEY_FILENAME:-lnd_backup_github_key}"; do
    refuse_links "$private_key"
    sudo test -f "$private_key" || continue
    sudo setfacl -P -x u:"$MAIN_USER" "$private_key" 2>/dev/null || true
    if ! sudo chmod 600 "$private_key"; then
        log_message "$(T "❌ Failed to set permissions on %s" "$private_key")"
    else
        log_message "$(T "✅ Permissions for %s set." "$private_key")"
    fi
done
log_message "$(T "ACL for SSH key removed.")"

# Remove ACL for the GPG key
log_message "$(T "Removing ACL for GPG private key at %s..." "$GPG_KEY_PATH")"
sudo setfacl -P -x u:"$MAIN_USER" "$GPG_KEY_PATH"
log_message "$(T "ACL for GPG key removed.")"

# Set ownership and permissions for the GPG key directory
log_message "$(T "Setting ownership and permissions for the GPG key directory...")"

if ! sudo chown -h -R "$SERVER_A_USER":"$SERVER_A_USER" "$GPG_KEY_DIR"; then
  log_message "$(T "❌ Failed to set ownership on %s" "$GPG_KEY_DIR")"
else
  log_message "$(T "✅ Ownership for %s set." "$GPG_KEY_DIR")"
fi

if ! sudo chmod 700 "$GPG_KEY_DIR"; then
  log_message "$(T "❌ Failed to set permissions on %s" "$GPG_KEY_DIR")"
else
  log_message "$(T "✅ Permissions for %s set." "$GPG_KEY_DIR")"
fi


# === MAIN_USER and the docker group ===
# The docker group is root without a password: a member can read the wallet's password and seed
# from the LND container with no prompt and no log. Nothing in these scripts needs it (everything
# that uses docker runs as root, through sudo). Older versions added MAIN_USER to it.
if [[ " $(id -nG "$MAIN_USER") " == *" docker "* ]]; then
    echo
    say "⚠️  %s is in the docker group, which amounts to root without a password: anything" "$MAIN_USER"
    say "   running as %s can read the LND wallet's password and seed. These scripts don't need it." "$MAIN_USER"
    say "   Without it, use 'sudo docker ...' (asks for your password, and is logged)."
    say "   It takes effect at your next login. Anything of your own that runs docker as %s" "$MAIN_USER"
    say "   without sudo (a cron job, a monitor) would stop working."
    if read -r -p "$(T "Type REMOVE to take %s out of the docker group (Enter to keep): " "$MAIN_USER")" answer && [[ "$answer" == "REMOVE" ]]; then
        sudo gpasswd -d "$MAIN_USER" docker >/dev/null
        log_message "$(T "✅ %s removed from the docker group (from the next login)" "$MAIN_USER")"
    else
        log_message "$(T "⚠️ %s stays in the docker group" "$MAIN_USER")"
    fi
fi

# Create and grant full control over the tmp backup directory
sudo -u "$SERVER_A_USER" mkdir -p "$TMP_BACKUP_DIR"
refuse_links "$TMP_BACKUP_DIR"

# Set owner
sudo chown -h "$SERVER_A_USER":"$SERVER_A_USER" "$TMP_BACKUP_DIR"

# Update the mask for group permissions
sudo setfacl -P -R -m m:rwx "$TMP_BACKUP_DIR"  # Set the mask to rwx for the group

# No access for the docker group: the service's unencrypted archives are made in this folder.
# Removes the entries older versions of this script added.
sudo setfacl -P -R -x g:docker "$TMP_BACKUP_DIR" 2>/dev/null || true
sudo setfacl -P -d -x g:docker "$TMP_BACKUP_DIR" 2>/dev/null || true

# Grant MAIN_USER full access
sudo setfacl -P -R -m u:"$MAIN_USER":rwx "$TMP_BACKUP_DIR"
sudo setfacl -P -d -m u:"$MAIN_USER":rwx "$TMP_BACKUP_DIR"

# Grant SERVER_A_USER full access
sudo setfacl -P -R -m u:"$SERVER_A_USER":rwx "$TMP_BACKUP_DIR"
sudo setfacl -P -d -m u:"$SERVER_A_USER":rwx "$TMP_BACKUP_DIR"


###############################################################
#              MOUNT ATTACHED_VOLUME 
###############################################################
if [[ "$BACKUP_TO_VOLUME" == yes ]]; then

# Everything below matches the exact UUID and mount point: a substring match could pick the
# wrong disk or fstab line (and an empty UUID used to match all of them).

# === Find the device with this UUID ===
DEVICE=$(lsblk -rpno NAME,UUID | awk -v u="$UUID" '$2 == u { print $1; exit }')
if [ -z "$DEVICE" ]; then
    log_message "$(T "❌ No device found with UUID %s" "$UUID")"
    exit 1
fi
log_message "$(T "✅ Device for UUID %s is: %s" "$UUID" "$DEVICE")"

# === /etc/fstab: ATTACHED_VOLUME must be this UUID, and this UUID must not be mounted elsewhere ===
FSTAB_SOURCE=$(awk -v mp="$ATTACHED_VOLUME" '$1 !~ /^#/ && $2 == mp { print $1; exit }' /etc/fstab)
FSTAB_OTHER_MP=$(awk -v src="UUID=$UUID" -v mp="$ATTACHED_VOLUME" '$1 == src && $2 != mp { print $2; exit }' /etc/fstab)
if [[ -n "$FSTAB_SOURCE" && "$FSTAB_SOURCE" != "UUID=$UUID" ]]; then
    log_message "$(T "❌ /etc/fstab already mounts %s at %s, not UUID=%s. Fix /etc/fstab or UUID in %s." "$FSTAB_SOURCE" "$ATTACHED_VOLUME" "$UUID" "$CONFIG_FILE")"
    exit 1
fi
# The same disk at another place in /etc/fstab (an older setup's mount point in a home folder):
# move that entry to ATTACHED_VOLUME, after asking. Nothing on the disk changes.
if [[ -n "$FSTAB_OTHER_MP" ]]; then
    echo
    say "⚠️  /etc/fstab mounts this disk (UUID %s) at %s. It moves to %s:" "$UUID" "$FSTAB_OTHER_MP" "$ATTACHED_VOLUME"
    say "   the backup service is stopped, the disk unmounted from the old place, the /etc/fstab line"
    say "   changed (old file kept as /etc/fstab.before-lnd-backups-move), and the disk mounted at the"
    say "   new place. The backups on it stay as they are."
    if ! read -r -p "$(T "Type MOVE to move the mount: ")" answer || [[ "$answer" != "MOVE" ]]; then
        log_message "$(T "❌ Stopped: the mount stays at %s" "$FSTAB_OTHER_MP")"
        exit 1
    fi
    if systemctl is-active --quiet "$RSYNC_BACKUP_SERVICE_NAME"; then
        sudo systemctl stop "$RSYNC_BACKUP_SERVICE_NAME"
        log_message "$(T "🛑 Backup service stopped (setup's installer step starts it again)")"
    fi
    if findmnt -rn -M "$FSTAB_OTHER_MP" >/dev/null 2>&1 && ! sudo umount "$FSTAB_OTHER_MP"; then
        log_message "$(T "❌ Could not unmount %s: something still uses it (see: sudo lsof +f -- %s)" "$FSTAB_OTHER_MP" "$FSTAB_OTHER_MP")"
        exit 1
    fi
    sudo cp -p /etc/fstab /etc/fstab.before-lnd-backups-move
    # Built in a private mktemp file (a fixed /tmp name could be swapped by another user before
    # root copies it in), then rewritten in place, so /etc/fstab keeps its owner and mode
    FSTAB_NEW=$(mktemp)
    awk -v src="UUID=$UUID" -v old="$FSTAB_OTHER_MP" -v mp="$ATTACHED_VOLUME" -v opts="$MOUNT_OPTS" \
        'BEGIN { OFS = "  " } $1 == src && $2 == old { $2 = mp; $4 = opts } { print }' /etc/fstab > "$FSTAB_NEW" &&
        sudo sh -c 'cat "$1" > /etc/fstab' _ "$FSTAB_NEW"
    rm -f "$FSTAB_NEW"
    sudo systemctl daemon-reload
    log_message "$(T "📝 /etc/fstab: UUID=%s now mounts at %s" "$UUID" "$ATTACHED_VOLUME")"
    # The old, now empty mount point in the home folder (rmdir never follows a symlink)
    if [[ -d "$FSTAB_OTHER_MP" && ! -L "$FSTAB_OTHER_MP" ]] && sudo rmdir -- "$FSTAB_OTHER_MP" 2>/dev/null; then
        log_message "$(T "🧹 Removed the old mount point %s" "$FSTAB_OTHER_MP")"
    fi
    FSTAB_SOURCE="UUID=$UUID"
fi

# === Create the mount point: owned by root, not a symlink ===
if [[ -L "$ATTACHED_VOLUME" ]]; then
    log_message "$(T "❌ %s is a symlink. Remove it; the mount point must be a real folder owned by root." "$ATTACHED_VOLUME")"
    exit 1
fi
if [ ! -d "$ATTACHED_VOLUME" ]; then
    log_message "$(T "📁 Creating mount point directory: %s" "$ATTACHED_VOLUME")"
    sudo install -d -o root -g root -m 755 "$ATTACHED_VOLUME"
else
    log_message "$(T "📁 Mount point %s already exists." "$ATTACHED_VOLUME")"
fi

# === Add Entry to /etc/fstab if not already present ===
if [[ -n "$FSTAB_SOURCE" ]]; then
    FSTAB_OPTS=$(awk -v mp="$ATTACHED_VOLUME" '$1 !~ /^#/ && $2 == mp { print $4; exit }' /etc/fstab)
    if [[ "$FSTAB_OPTS" != "$MOUNT_OPTS" ]]; then
        sudo cp -p /etc/fstab /etc/fstab.before-lnd-backups-options
        FSTAB_NEW=$(mktemp)
        awk -v mp="$ATTACHED_VOLUME" -v opts="$MOUNT_OPTS" \
            'BEGIN { OFS = "  " } $1 !~ /^#/ && $2 == mp { $4 = opts } { print }' /etc/fstab > "$FSTAB_NEW" &&
            sudo sh -c 'cat "$1" > /etc/fstab' _ "$FSTAB_NEW"
        rm -f "$FSTAB_NEW"
        sudo systemctl daemon-reload
        log_message "$(T "📝 /etc/fstab: mount options for %s are now %s (were %s)" "$ATTACHED_VOLUME" "$MOUNT_OPTS" "$FSTAB_OPTS")"
        if findmnt -rn -M "$ATTACHED_VOLUME" >/dev/null 2>&1; then
            sudo mount -o "remount,$MOUNT_OPTS" "$ATTACHED_VOLUME"
        fi
    else
        log_message "$(T "✅ UUID %s is already in /etc/fstab at %s" "$UUID" "$ATTACHED_VOLUME")"
    fi
else
    log_message "$(T "📝 Adding entry for UUID %s to /etc/fstab..." "$UUID")"

    # Construct the fstab entry
    FSTAB_ENTRY="UUID=$UUID  $ATTACHED_VOLUME  $FILE_SYSTEM_TYPE  $MOUNT_OPTS  $DUMP  $PASS"

    # Append the entry to /etc/fstab
    echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab > /dev/null
    sudo systemctl daemon-reload
fi

# === MOUNT NOW === #
if findmnt -rn -M "$ATTACHED_VOLUME" >/dev/null 2>&1; then
    MOUNTED_SOURCE=$(findmnt -no SOURCE --mountpoint "$ATTACHED_VOLUME")
    if [[ "$MOUNTED_SOURCE" != "$DEVICE" ]]; then
        log_message "$(T "❌ %s is already mounted from %s, not %s (UUID %s). Unmount it or fix UUID in %s." "$ATTACHED_VOLUME" "$MOUNTED_SOURCE" "$DEVICE" "$UUID" "$CONFIG_FILE")"
        exit 1
    fi
    log_message "$(T "📂 %s is already mounted at %s" "$DEVICE" "$ATTACHED_VOLUME")"
else
    log_message "$(T "⛓️ Mounting %s to %s..." "$DEVICE" "$ATTACHED_VOLUME")"
    # With both device and folder given, mount ignores /etc/fstab's options: pass them
    sudo mount -o "$MOUNT_OPTS" "$DEVICE" "$ATTACHED_VOLUME"
fi

# === Verify the mount: this disk, at exactly this place, with nosuid,nodev,noexec ===
MOUNTED_OPTS=$(findmnt -rn -M "$ATTACHED_VOLUME" -o OPTIONS 2>/dev/null)
for opt in nosuid nodev noexec; do
    if [[ ",$MOUNTED_OPTS," != *",$opt,"* ]]; then
        log_message "$(T "⛓️ %s is mounted without %s: remounting with %s" "$ATTACHED_VOLUME" "$opt" "$MOUNT_OPTS")"
        sudo mount -o "remount,$MOUNT_OPTS" "$ATTACHED_VOLUME"
        break
    fi
done
if [[ "$(findmnt -rn -M "$ATTACHED_VOLUME" -o UUID 2>/dev/null)" == "$UUID" ]]; then
    log_message "$(T "✅ Successfully mounted %s at %s" "$UUID" "$ATTACHED_VOLUME")"
else
    log_message "$(T "❌ Mounting failed. Please check the /etc/fstab file for errors.")"
    exit 1
fi

log_message "$(T "✅ Mount setup complete. The device should be mounted now and will be automatically mounted on every reboot.")"


# === The disk's root stays root's; the backup user owns only its backups folder ===
# Then nobody but root can replace SECOND_BACKUP_DIR itself (older setups gave the backup user
# the whole disk).
sudo chown root:root "$ATTACHED_VOLUME"
sudo chmod 755 "$ATTACHED_VOLUME"
# ACLs an older setup left on the disk's root (it was inside the backup home, which gets ACLs)
sudo setfacl -b "$ATTACHED_VOLUME"
if [[ -L "$SECOND_BACKUP_DIR" ]]; then
    log_message "$(T "❌ %s is a symlink. Stopping." "$SECOND_BACKUP_DIR")"
    exit 1
fi
sudo install -d -o "$SERVER_A_USER" -g "$SERVER_A_USER" -m 700 "$SECOND_BACKUP_DIR"
if sudo chown -h -R "$SERVER_A_USER:$SERVER_A_USER" "$SECOND_BACKUP_DIR"; then
    log_message "$(T "Made %s owner of %s (%s itself stays root's)" "$SERVER_A_USER" "$SECOND_BACKUP_DIR" "$ATTACHED_VOLUME")"
else
    log_message "$(T "Changing ownership of %s to %s failed." "$SECOND_BACKUP_DIR" "$SERVER_A_USER")"
fi

###############################################################
#              ⚡ LND Lightning Scripts ⚡ 
###############################################################

fi

# === Manual Step Warning: Storing LND Seed ===
log_message "$(T "⚠️ WARNING: You are about to perform a manual step that involves storing a copy of your LND seed.")"
log_message "$(T "To securely store the seed, follow these steps:")"
log_message "$(T "1. Go to 'Server Settings' in your BTCpayServer dashboard.")"
log_message "$(T "2. Click on 'Services' in the menu.")"
log_message "$(T "3. Select 'LND Seed Backup'.")"
log_message "$(T "4. Click on 'See information' to view and copy your LND seed.")"
log_message "$(T "⚠️ Make sure to store this seed in a secure location! Losing the seed means losing access to your LND wallet.")"

# Prompt for confirmation before proceeding
read -p "$(T "Have you securely stored your LND seed? (y/n): ")" confirmation

if [[ "$confirmation" =~ ^[Yy]$ ]]; then
    log_message "$(T "✅ LND seed backup step confirmed. Proceeding with the backup process.")"
    mark_setup_state lnd_seed_stored
else
    log_message "$(T "❌ LND seed backup step not completed. Please ensure that the seed is securely stored before proceeding.")"
    exit 1
fi

# === The backup service ===
say "Last step: the backup service (rsync_gpg_backup.sh). It watches LND's channel backup and, after"
say "every change, stores an encrypted, signed copy at the destinations you chose."
say "It explains what it does first. Later: lnd-manager /install, or rerun setup."
echo ""

# === Root-owned install ===
# Root runs only the copies in BACKUP_INSTALL_DIR, so the config saved above is installed first
log_message "$(T "📦 Installing the scripts and config root-owned into %s..." "${BACKUP_INSTALL_DIR:-/usr/local/lib/btcpay-docker-lnd-manager}")"
# The destinations turned on are set up now
for setting in "${TURNED_ON[@]}"; do
    save_config_value "$setting" yes || exit 1
done
if ! sudo "$SCRIPT_DIR/install-scripts.sh"; then
    log_message "$(T "❌ install-scripts.sh failed: the installed copies are not up to date")"
    exit 1
fi

# The root-owned installer, whatever an older config's RSYNC_FOLDER_MIRROR_SCRIPT says
RSYNC_FOLDER_MIRROR_SCRIPT="${BACKUP_INSTALL_DIR:-/usr/local/lib/btcpay-docker-lnd-manager}/rsync_gpg_backup.sh"

read -p "$(T "📦 Install or update the backup service now? (y/n): ")" run_rsync_script
if [[ "$run_rsync_script" =~ ^[Yy]$ ]]; then
	log_message "$(T "▶️ Installing the backup service (%s)..." "$RSYNC_FOLDER_MIRROR_SCRIPT")"
	if [[ -x "$RSYNC_FOLDER_MIRROR_SCRIPT" ]]; then
		"$RSYNC_FOLDER_MIRROR_SCRIPT"
		log_message "$(T "✅ Backup service installer finished.")"
	else
		log_message "$(T "❌ The backup service installer is missing or not executable: %s" "$RSYNC_FOLDER_MIRROR_SCRIPT")"
	fi
else
	log_message "$(T "⏭️ Backup service not installed now. Later: lnd-manager /install")"
fi

# Create logrotate configuration
# su: logrotate skips folders that a non-root group can write to (Ubuntu's /var/log is
# root:syslog 775) unless told which user and group to rotate as.
# copytruncate: the service (SERVER_A_USER) appends to this file, and MAIN_USER has a read ACL on
# it. Copying and truncating keeps the same file, so its owner, mode and ACLs stay. A line written
# during the copy can be lost.
LOGROTATE_CONFIG="/etc/logrotate.d/backup_monitor"
LOG_DIR_GROUP=$(stat -c %G "$(dirname "$LIGHTNING_BACKUP_LOG_FILE")")
say "Writing logrotate configuration to %s..." "$LOGROTATE_CONFIG"
echo "$LIGHTNING_BACKUP_LOG_FILE {
	su root $LOG_DIR_GROUP
	daily
	size 10M
	rotate 7
	compress
	delaycompress
	missingok
	notifempty
	copytruncate
}" | sudo tee "$LOGROTATE_CONFIG" > /dev/null

say "Setup complete! What's done and what's next: lnd-manager, then /checklist"

# Exit successfully
exit 0

