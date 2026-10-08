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
# Root-run scripts refuse to run from a folder an ordinary user can write to.

if ! SRC_DIR=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")"); then
    echo "❌ Could not determine this script's folder" >&2
    exit 1
fi
if [[ $EUID -ne 0 ]]; then
    echo "❌ Run it with sudo: sudo $0" >&2
    exit 1
fi
CONFIG_FILE="$SRC_DIR/config"
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
         chain-tower.sh i18n.sh)
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

changed=()
[[ -f "$SRC_DIR/LICENSE" ]] || { say "❌ Missing %s/LICENSE" "$SRC_DIR" >&2; exit 1; }
for f in "${SCRIPTS[@]}" config LICENSE; do
    mode=755
    [[ "$f" == config || "$f" == LICENSE ]] && mode=644
    if ! cmp -s "$SRC_DIR/$f" "$DEST/$f" 2>/dev/null; then
        changed+=("$f")
    fi
    install -o root -g root -m "$mode" "$SRC_DIR/$f" "$DEST/$f.new"
    mv -f "$DEST/$f.new" "$DEST/$f"
done

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
if [[ " ${changed[*]} " == *" rsync_gpg_backup.sh "* || " ${changed[*]} " == *" config "* ]]; then
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
