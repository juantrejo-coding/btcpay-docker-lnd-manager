#!/bin/bash
# serverb-setup.sh: sets up Server B from a git clone of this project, with the settings Server A
# sent (serverb.conf). Run it on Server B, in the clone, with sudo:
#
#   sudo ./serverb-setup.sh <backup user>   reads ~<backup user>/serverb-setup/serverb.conf, which
#                                           Server A sent through the backup gate (lnd-manager:
#                                           /serverb send)
#   sudo ./serverb-setup.sh --paste         paste serverb.conf (the first time, before the gate
#                                           exists, or while the gate is older than /serverb send)
#   sudo ./serverb-setup.sh --file <file>   read it from a file
#   serverb-setup.sh --update <tag>         (serverb-update install scripts, as root, from the
#                                           checked release) the settings saved last time, no
#                                           questions: updates the backup gate and the dashboard
#
# serverb.conf is read as data, never run: each value is checked and shown before anything is
# made. The scripts are then made from this clone's templates (serverb/) into
# /var/lib/serverb-setup/scripts, root's only, and run in order, each asked for first: the backup
# user and gate, Bitcoin Core, the blockchain import, the watchtower, the dashboard. Run it again
# to go on after the blockchain copy from Server A, or to update after git pull.
#
# Check the clone first (README.md, "Check what you download"): root runs the code in it.

set -euo pipefail
umask 022
if ! SCRIPT_DIR=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")"); then
    echo "❌ Could not determine this script's folder" >&2
    exit 1
fi
for f in i18n.sh config-lib.sh serverb-lib.sh serverb/serverb-common.sh serverb/serverb-steps.sh; do
    [[ -f "$SCRIPT_DIR/$f" ]] || { echo "❌ $SCRIPT_DIR/$f is missing: run this from a full clone" >&2; exit 1; }
done
# shellcheck disable=SC1091
source "$SCRIPT_DIR/i18n.sh"
log_message() { echo "$1"; }
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config-lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/serverb/serverb-common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/serverb/serverb-steps.sh"
declare -A V=()
# shellcheck disable=SC1091
source "$SCRIPT_DIR/serverb-lib.sh"

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-2}"
}
FROM_USER="" FROM_FILE="" UPDATE_TAG=""
case "${1:-}" in
    -h | --help) usage 0 ;;
    --paste) ;;
    --update)
        UPDATE_TAG="${2:-}"
        [[ "$UPDATE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
        export SERVERB_UPDATE=1 ;;
    --file) FROM_FILE="${2:-}"; [[ -n "$FROM_FILE" ]] || usage ;;
    "" | -*) usage ;;
    *) FROM_USER="$1" ;;
esac
need_root
command -v python3 >/dev/null || apt_install python3

# === serverb.conf, as data ===
CONF_TEXT=""
SAVED_CONF="$SERVERB_SETUP_DIR/serverb.conf"
if [[ -n "$UPDATE_TAG" ]]; then
    [[ -f "$SAVED_CONF" && ! -L "$SAVED_CONF" && "$(stat -c %u -- "$SAVED_CONF")" == 0 ]] ||
        die "$(T "%s is missing: set Server B up with serverb-setup.sh once" "$SAVED_CONF")"
    CONF_TEXT=$(head -c 65536 -- "$SAVED_CONF")
elif [[ -n "$FROM_USER" ]]; then
    [[ -z "$(remote_user_problem "$FROM_USER")" ]] && id "$FROM_USER" &>/dev/null ||
        die "$(T "No user %s on this server" "$FROM_USER")"
    home=$(getent passwd "$FROM_USER" | cut -d: -f6)
    # Read as that user, not as root: root doesn't open files in a folder that user owns
    CONF_TEXT=$(runuser -u "$FROM_USER" -- head -c 65536 -- "$home/serverb-setup/serverb.conf") ||
        die "$(T "No %s/serverb-setup/serverb.conf. On Server A: lnd-manager /serverb send. Or: sudo %s --paste" "$home" "$0")"
elif [[ -n "$FROM_FILE" ]]; then
    CONF_TEXT=$(head -c 65536 -- "$FROM_FILE") || die "$(T "Could not read %s" "$FROM_FILE")"
else
    say "Paste serverb.conf (Server A shows it: lnd-manager /serverb send). It ends with the line"
    say "\"%s\"; reading stops there." "$SERVERB_CONF_END"
    while IFS= read -r line; do
        CONF_TEXT+="$line"$'\n'
        [[ "${line%$'\r'}" == "$SERVERB_CONF_END" ]] && break
        (( ${#CONF_TEXT} <= 65536 )) || die "$(T "That is more than serverb.conf holds")"
    done
fi
read_serverb_conf <<< "$CONF_TEXT" || die "$(T "serverb.conf not used: nothing was changed")"
if [[ -n "$FROM_USER" && "${V[SERVER_B_USER]}" != "$FROM_USER" ]]; then
    die "$(T "serverb.conf in %s's folder names another backup user, %s" "$FROM_USER" "${V[SERVER_B_USER]}")"
fi

# The language Server A chose, if this clone has it
UI_LANGUAGE="${V[UI_LANGUAGE]}"
[[ "$UI_LANGUAGE" == en || -f "$SCRIPT_DIR/locale/$UI_LANGUAGE.cat" ]] || UI_LANGUAGE=en
i18n_load "$SCRIPT_DIR/locale" any-owner
SERVER_B_USER="${V[SERVER_B_USER]}"

# === What will be used ===
here_version=""
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
    here_version=$(runuser -u "$SUDO_USER" -- git -C "$SCRIPT_DIR" describe --tags --always --dirty 2>/dev/null || true)
fi
if [[ -z "$UPDATE_TAG" ]]; then
echo
say "Settings from Server A (serverb.conf):"
say "   Backup user:           %s" "${V[SERVER_B_USER]}"
say "   Server A's key:        %s" "${V[SERVER_A_KEY]:0:20}...${V[SERVER_A_KEY]: -16}"
say "   Server A's address:    %s (only it may reach the watchtower)" "${V[SERVER_A_IP]}"
say "   Watchtower:            %s:%s" "${V[WATCHTOWER_ADDRESS]}" "${V[WATCHTOWER_PORT]}"
say "   Blockchain kept (MB):  %s" "${V[PRUNE_MB]}"
say "   Dashboard admin:       %s" "${V[SERVER_B_ADMIN_USER]}"
say "   Language:              %s" "$UI_LANGUAGE"
say "Scripts from this clone: %s (Server A runs %s)" "${here_version:-?}" "${V[SOURCE_VERSION]:-?}"
if [[ "$(templates_sha256 "$UI_LANGUAGE")" != "${V[TEMPLATES_SHA256]}" ]]; then
    echo
    say "⚠️ This clone's Server B scripts differ from Server A's version. Best: the same version on"
    say "   both (git checkout <tag> here, or update Server A), then /serverb send again."
fi
echo
confirm_phrase yes "$(T "Type yes to make the scripts with these settings and go through the steps: ")" ||
    die "$(T "Cancelled")"
fi

# === Make them, run them ===
RENDER_NOTE=$(T "# Filled in on Server B by serverb-setup.sh from Server A's serverb.conf, %s" "$(date '+%Y-%m-%d %H:%M')")
new_scripts_dir
for f in "${SERVERB_SCRIPTS[@]}"; do
    make_serverb_script "$f" "$SCRIPTS_DIR" || die "$(T "Nothing was run")"
done
say "✅ Scripts made in %s" "$SCRIPTS_DIR"
# For later updates (serverb-update install scripts): the settings, and which version made them
printf '%s' "$CONF_TEXT" > "$SAVED_CONF.new" && chmod 600 "$SAVED_CONF.new" && mv -f "$SAVED_CONF.new" "$SAVED_CONF"
version="${UPDATE_TAG:-${here_version%-dirty}}"
[[ "$version" =~ ^[A-Za-z0-9._+-]{1,80}$ ]] || version=unknown
echo

if [[ -n "$UPDATE_TAG" ]]; then
    # Only what is set up already; bitcoind and the tower keep running
    home=$(getent passwd "$SERVER_B_USER" | cut -d: -f6 || true)
    if [[ -n "$home" ]] && runuser -u "$SERVER_B_USER" -- test -x "$home/.local/bin/lnd-backup-gate"; then
        say "🔄 The backup user and its gate..."
        bash "$SCRIPTS_DIR/serverb-user-setup.sh" || die "$(T "serverb-user-setup.sh failed")"
    fi
    if [[ -x /usr/local/bin/serverb-dashboard ]]; then
        say "🔄 The dashboard..."
        bash "$SCRIPTS_DIR/serverb-dashboard-setup.sh" || die "$(T "serverb-dashboard-setup.sh failed")"
    fi
    save_scripts_version "$version"
    say "✅ These scripts are at %s now. bitcoind and the watchtower kept running." "$version"
    say "   A release that changes their own setup says so: then rerun that step (sudo ./serverb-setup.sh)."
    exit 0
fi
save_scripts_version "$version"
run_steps
