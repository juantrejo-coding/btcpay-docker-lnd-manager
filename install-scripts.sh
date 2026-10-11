#!/bin/bash
set -euo pipefail

# Installs the scripts and config root-owned, so nothing root runs can be changed by an ordinary
# user. Run it from your working folder (where you edit config) after every change:
#
#   sudo ./install-scripts.sh
#
# It copies them to BACKUP_INSTALL_DIR (config; default /usr/local/lib/btcpay-docker-lnd-manager),
# owned by root and writable only by root, and adds two commands:
#   lnd-wallet    -> lnd-wallet.sh    (sudo lnd-wallet restore, ...)
#   lnd-manager   -> lnd-manager.py   (the dashboard)
#   lnd-update    -> lnd-update.sh    (sudo lnd-update: the newest signed release)
# and the systemd units lnd-update-boot.service (a waiting update, at boot) and
# server-a-status.timer (Server A's LND state to Server B every 5 minutes, server-a-status.sh).
# Root-run scripts refuse to run from a folder an ordinary user can write to.
#
# It refuses to install an older version than the one installed (the release in VERSION): after
# sudo lnd-update, a working folder left at the old version would otherwise undo the update.
# --force installs it anyway. lnd-update.sh runs a release's own copy with --update <tag>
# <installed config>: that config is kept, and VERSION becomes <tag>.

if ! SRC_DIR=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")"); then
    echo "❌ Could not determine this script's folder" >&2
    exit 1
fi
if [[ $EUID -ne 0 ]]; then
    echo "❌ Run it with sudo: sudo $0" >&2
    exit 1
fi
CONFIG_FILE="$SRC_DIR/config"
UPDATE_TAG="" FORCE=false
while (( $# )); do
    case "$1" in
        --update) UPDATE_TAG="${2:-}" CONFIG_FILE="${3:-}"; shift 3 || shift $# ;;
        --force) FORCE=true; shift ;;
        *) echo "❌ Unknown option: $1" >&2; exit 2 ;;
    esac
done
if [[ -n "$UPDATE_TAG" && ( ! "$UPDATE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ || ! -f "$CONFIG_FILE" ) ]]; then
    echo "❌ --update needs a release tag and the installed config" >&2
    exit 2
fi
[[ -f "$CONFIG_FILE" ]] || { echo "❌ No config next to this script ($CONFIG_FILE)" >&2; exit 1; }
bash -n "$CONFIG_FILE" || { echo "❌ $CONFIG_FILE has a syntax error" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG_FILE"
# Messages in config's language. This script runs from your working folder, so its catalog is
# that folder's too: whoever can change it can change this script as well.
# shellcheck disable=SC1091
source "$SRC_DIR/i18n.sh" || { echo "❌ Failed to load $SRC_DIR/i18n.sh" >&2; exit 1; }
i18n_load "$SRC_DIR/locale" any-owner

DEST="${BACKUP_INSTALL_DIR:-/usr/local/lib/btcpay-docker-lnd-manager}"
case "$DEST" in
    /usr/local/* | /opt/*) ;;
    *) say "❌ BACKUP_INSTALL_DIR must be under /usr/local or /opt: %s" "$DEST" >&2; exit 1 ;;
esac
if [[ "$(realpath -m -- "$DEST")" == "$(realpath -m -- "$SRC_DIR")" ]]; then
    say "❌ Run this from your working folder, not from %s" "$DEST" >&2
    exit 1
fi

SCRIPTS=(setup_script.sh config-lib.sh rsync_gpg_backup.sh lnd-wallet.sh lnd-manager.py server-b-install.sh
         chain-tower.sh i18n.sh lnd-update.sh update-lib.sh server-a-status.sh)
for f in "${SCRIPTS[@]}"; do
    [[ -f "$SRC_DIR/$f" ]] || { say "❌ Missing %s/%s" "$SRC_DIR" "$f" >&2; exit 1; }
    case "$f" in
        *.sh) bash -n "$SRC_DIR/$f" || { say "❌ %s has a syntax error" "$f" >&2; exit 1; } ;;
    esac
done

# Every folder on the way must be root's and not writable by others, or the install would still
# be changeable by someone else
install -d -o root -g root -m 755 "$DEST"
path="$DEST"
while [[ "$path" != "/" ]]; do
    if [[ -L "$path" || "$(stat -c %u "$path")" != 0 ]] || (( 8#$(stat -c %a "$path") & 8#022 )); then
        say "❌ %s is a symlink, not owned by root, or writable by others" "$path" >&2
        exit 1
    fi
    path=$(dirname -- "$path")
done

# === Which version this is ===
# shellcheck disable=SC1091
source "$SRC_DIR/update-lib.sh"
if [[ -n "$UPDATE_TAG" ]]; then
    NEW_VERSION="$UPDATE_TAG"
else
    NEW_VERSION=""
    # As you, not as root: git reads the folder's own settings, which you control
    if [[ -d "$SRC_DIR/.git" && -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
        NEW_VERSION=$(runuser -u "$SUDO_USER" -- git -C "$SRC_DIR" describe --tags --always 2>/dev/null || true)
    fi
    [[ "$NEW_VERSION" =~ ^[A-Za-z0-9._+-]{1,80}$ ]] || NEW_VERSION="unknown"
fi
OLD_VERSION=$(head -n 1 "$DEST/VERSION" 2>/dev/null || true)
if [[ -n "$OLD_VERSION" ]] && release_newer "$NEW_VERSION" "$OLD_VERSION" && ! $FORCE; then
    say "❌ %s is %s, older than the installed %s (sudo lnd-update installed it)." "$SRC_DIR" "$NEW_VERSION" "$OLD_VERSION" >&2
    say "   Move this folder to that release first: git fetch --tags && git checkout %s" "$(release_of "$OLD_VERSION")" >&2
    say "   (--force installs the older version anyway)" >&2
    exit 1
fi

changed=()
[[ -f "$SRC_DIR/LICENSE" ]] || { say "❌ Missing %s/LICENSE" "$SRC_DIR" >&2; exit 1; }
[[ -f "$SRC_DIR/release-key.asc" ]] || { say "❌ Missing %s/release-key.asc" "$SRC_DIR" >&2; exit 1; }
for f in "${SCRIPTS[@]}" config LICENSE release-key.asc; do
    mode=755
    [[ "$f" == config || "$f" == LICENSE || "$f" == release-key.asc ]] && mode=644
    from="$SRC_DIR/$f"
    # An update keeps the installed config
    [[ "$f" == config ]] && from="$CONFIG_FILE"
    if ! cmp -s "$from" "$DEST/$f" 2>/dev/null; then
        changed+=("$f")
    fi
    install -o root -g root -m "$mode" "$from" "$DEST/$f.new"
    mv -f "$DEST/$f.new" "$DEST/$f"
done
echo "$NEW_VERSION" > "$DEST/VERSION.new" && chmod 644 "$DEST/VERSION.new" && mv -f "$DEST/VERSION.new" "$DEST/VERSION"

# The translations (i18n.sh): data the scripts read, root's like config
install -d -o root -g root -m 755 "$DEST/locale"
for f in "$SRC_DIR"/locale/*.cat; do
    [[ -f "$f" ]] || continue
    name=$(basename -- "$f")
    cmp -s "$f" "$DEST/locale/$name" 2>/dev/null || changed+=("locale/$name")
    install -o root -g root -m 644 "$f" "$DEST/locale/$name.new"
    mv -f "$DEST/locale/$name.new" "$DEST/locale/$name"
done
for f in "$DEST"/locale/*.cat; do
    [[ -f "$f" && ! -f "$SRC_DIR/locale/$(basename -- "$f")" ]] && rm -f -- "$f"
done
# No ACLs: the installer's default ACL on this folder (read for the backup user, from when config
# lived in a home folder) would give locale/ an entry without x, which locks the backup service
# out of the translations. 755 and 644 already let everyone read them.
if command -v setfacl >/dev/null; then
    setfacl -b "$DEST/locale" "$DEST"/locale/*.cat 2>/dev/null || true
fi

ln -sfn "$DEST/lnd-wallet.sh" /usr/local/bin/lnd-wallet
ln -sfn "$DEST/lnd-manager.py" /usr/local/bin/lnd-manager
ln -sfn "$DEST/lnd-update.sh" /usr/local/bin/lnd-update

# === systemd: a waiting update at boot, and Server A's state for Server B ===
SERVICE_NAME="${RSYNC_BACKUP_SERVICE_NAME:-rsync_gpg_backup.service}"
write_unit() {
    local name="$1" content="$2"
    if ! cmp -s <(printf '%s\n' "$content") "/etc/systemd/system/$name" 2>/dev/null; then
        printf '%s\n' "$content" > "/etc/systemd/system/$name.new"
        chmod 644 "/etc/systemd/system/$name.new"
        mv -f "/etc/systemd/system/$name.new" "/etc/systemd/system/$name"
        changed+=("$name")
    fi
}
write_unit lnd-update-boot.service "[Unit]
Description=Installs a waiting update of btcpay-docker-lnd-manager (lnd-update) before the backup service starts
ConditionPathExists=/var/lib/lnd-update/src/.release
# The network for the working folder's git fetch (the update itself needs none)
Wants=network-online.target
After=local-fs.target network-online.target
Before=$SERVICE_NAME

[Service]
Type=oneshot
ExecStart=$DEST/lnd-update.sh boot
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target"
write_unit server-a-status.service "[Unit]
Description=Tells Server B whether it is safe to restart its watchtower (server-a-status.sh)
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=$DEST/server-a-status.sh
TimeoutStartSec=120"
write_unit server-a-status.timer "[Unit]
Description=Server A's LND state to Server B every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target"
if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
    systemctl daemon-reload
    systemctl enable --quiet lnd-update-boot.service
    systemctl enable --quiet --now server-a-status.timer
fi

# Left from before the rename to btcpay-docker-lnd-manager (main-script.sh, backup-tui)
for old in main-script.sh backup-tui.py; do
    rm -f -- "$DEST/$old"
done
if [[ -L /usr/local/bin/backup-tui ]]; then
    rm -f /usr/local/bin/backup-tui
fi
if (( ${#changed[@]} > 0 )); then
    say "✅ Installed into %s (changed: %s)" "$DEST" "${changed[*]}"
else
    say "✅ %s is up to date" "$DEST"
fi
say "   Wallet: sudo lnd-wallet [new|restore|channels|channels-only|undo]   Dashboard: lnd-manager"
say "   Version: %s   Updates: sudo lnd-update" "$NEW_VERSION"
# (lnd-update reinstalls the service itself right after an --update)
if [[ -z "$UPDATE_TAG" ]] && [[ " ${changed[*]} " == *" rsync_gpg_backup.sh "* || " ${changed[*]} " == *" config "* ]]; then
    say "   The backup service uses the installed copy: rerun %s/rsync_gpg_backup.sh to apply the changes." "$DEST"
fi

# The install folder before the rename. Removed once the backup service no longer reads its
# config, that is after rsync_gpg_backup.sh was rerun from the new folder.
OLD_DEST=/usr/local/lib/btcpay-backup
SERVICE_SCRIPT="${RSYNC_FOLDER_MIRROR_SYSTEMD_SCRIPT_PATH:-/usr/local/bin/systemd-rsync_gpg_backup.sh}"
if [[ "$DEST" != "$OLD_DEST" && -d "$OLD_DEST" && ! -L "$OLD_DEST" ]]; then
    if [[ -f "$SERVICE_SCRIPT" ]] && grep -q "^CONFIG_FILE=$OLD_DEST/" "$SERVICE_SCRIPT"; then
        say "   The backup service still reads %s/config: rerun %s/rsync_gpg_backup.sh," "$OLD_DEST" "$DEST"
        say "   then sudo ./install-scripts.sh again removes %s." "$OLD_DEST"
    else
        for old in main-script.sh backup-tui.py rsync_gpg_backup.sh lnd-wallet.sh server-b-install.sh config; do
            rm -f -- "$OLD_DEST/$old"
        done
        if rmdir -- "$OLD_DEST" 2>/dev/null; then
            say "   Removed the old install folder %s" "$OLD_DEST"
        else
            say "   %s holds files this project didn't put there; left as it is" "$OLD_DEST"
        fi
    fi
fi
