#!/bin/bash
# serverb-install.sh: all the Server B scripts in one file, with Server A's settings filled in.
# Made on Server A by serverb-scripts.sh (lnd-manager: /serverb send, "config and scripts"), which
# puts it in the backup user's ~/serverb-setup on Server B. Root must not run it from there (that
# user, and Server A's key, can change it), so copy it out first, as your admin account:
#
#   sudo -u <backup user> cat ~<backup user>/serverb-setup/serverb-install.sh > serverb-install.sh
#   sha256sum serverb-install.sh       (the same as Server A showed?)
#   sudo bash serverb-install.sh
#
# It writes the scripts into /var/lib/serverb-setup/scripts (root's only) and runs them in order,
# asking before each: the backup user and gate, Bitcoin Core, the blockchain import, the
# watchtower, the dashboard. Run it again to go on after the blockchain copy, or to update.
# The scripts come from Server A as they are: this is as safe as copying them over by hand. To use
# only code you checked yourself, use serverb-setup.sh from a git clone instead (README.md).

# @@SETTINGS
SOURCE_VERSION=""
SERVER_B_USER=""
SERVER_A_KEY=""
PRUNE_MB=""
WATCHTOWER_ADDRESS=""
WATCHTOWER_PORT=""
SERVER_A_IP=""
SERVER_B_ADMIN_USER=""
SUPPORT_BTC_ADDRESS=""
SUPPORT_URL=""
# @@END-SETTINGS

# @@INCLUDE i18n.sh
# @@I18N
# @@INCLUDE serverb-common.sh
# @@INCLUDE serverb-steps.sh

need_root
need_settings SERVER_B_USER SERVER_A_KEY

# This file must be one only root (or you, who ran sudo) can change, outside the backup user's home
SELF=$(realpath -- "$0") || die "$(T "Could not find this script's file")"
B_HOME=$(getent passwd "$SERVER_B_USER" | cut -d: -f6 || true)
[[ -n "$B_HOME" ]] && B_HOME=$(realpath -m -- "$B_HOME")
read -r owner mode owner_name group_name < <(stat -c '%u %a %U %G' -- "$SELF")
# Group-writable is fine only for the owner's own group (Ubuntu's usual umask 002)
if [[ "$owner" != 0 && "$owner" != "${SUDO_UID:-0}" ]] || (( 8#$mode & 8#002 )) ||
   { (( 8#$mode & 8#020 )) && [[ "$group_name" != "$owner_name" ]]; } ||
   [[ -n "$B_HOME" && "$SELF" == "$B_HOME"/* ]]; then
    say "❌ Don't run this file where %s (or Server A's key) can change it. Copy it out first, as your" "$SERVER_B_USER" >&2
    say "   admin account, then run the copy:" >&2
    say "   sudo -u %s cat %s > serverb-install.sh" "$SERVER_B_USER" "$SELF" >&2
    say "   sudo bash serverb-install.sh" >&2
    exit 1
fi

say "Server B scripts from Server A (version %s)" "${SOURCE_VERSION:-?}"
say "sha256 of this file: %s" "$(sha256sum -- "$SELF" | cut -d' ' -f1)"
say "   Is it the one Server A showed (lnd-manager /serverb send)? If not, stop here."
echo
say "Settings filled in on Server A:"
say "   Backup user:           %s" "$SERVER_B_USER"
say "   Server A's key:        %s" "${SERVER_A_KEY:0:20}...${SERVER_A_KEY: -16}"
say "   Server A's address:    %s (only it may reach the watchtower)" "$SERVER_A_IP"
say "   Watchtower:            %s:%s" "$WATCHTOWER_ADDRESS" "$WATCHTOWER_PORT"
say "   Blockchain kept (MB):  %s" "$PRUNE_MB"
say "   Dashboard admin:       %s" "$SERVER_B_ADMIN_USER"
echo
confirm_phrase yes "$(T "Type yes to write the scripts and go through the steps: ")" || die "$(T "Cancelled")"

new_scripts_dir
umask 077
write_script() {
    "$2" > "$SCRIPTS_DIR/$1.new" && bash -n "$SCRIPTS_DIR/$1.new" || die "$(T "Could not write %s" "$1")"
    mv -f "$SCRIPTS_DIR/$1.new" "$SCRIPTS_DIR/$1"
}
user_script() {
    cat <<'SERVERB_USER_SETUP_EOF'
# @@EMBED serverb-user-setup.sh
SERVERB_USER_SETUP_EOF
}
bitcoind_script() {
    cat <<'SERVERB_BITCOIND_SETUP_EOF'
# @@EMBED serverb-bitcoind-setup.sh
SERVERB_BITCOIND_SETUP_EOF
}
import_script() {
    cat <<'SERVERB_IMPORT_CHAIN_EOF'
# @@EMBED serverb-import-chain.sh
SERVERB_IMPORT_CHAIN_EOF
}
tower_script() {
    cat <<'SERVERB_WATCHTOWER_SETUP_EOF'
# @@EMBED serverb-watchtower-setup.sh
SERVERB_WATCHTOWER_SETUP_EOF
}
dashboard_script() {
    cat <<'SERVERB_DASHBOARD_SETUP_EOF'
# @@EMBED serverb-dashboard-setup.sh
SERVERB_DASHBOARD_SETUP_EOF
}
write_script serverb-user-setup.sh user_script
write_script serverb-bitcoind-setup.sh bitcoind_script
write_script serverb-import-chain.sh import_script
write_script serverb-watchtower-setup.sh tower_script
write_script serverb-dashboard-setup.sh dashboard_script
# For later updates (serverb-update install scripts, if this server can reach GitHub): the same
# settings serverb-setup.sh saves, and the version
{
    echo "FORMAT=1"
    echo "SOURCE_VERSION=$SOURCE_VERSION"
    echo "TEMPLATES_SHA256=0000000000000000000000000000000000000000000000000000000000000000"
    echo "UI_LANGUAGE=${UI_LANGUAGE:-en}"
    for name in SERVER_B_USER SERVER_A_KEY PRUNE_MB WATCHTOWER_ADDRESS WATCHTOWER_PORT SERVER_A_IP \
                SERVER_B_ADMIN_USER SUPPORT_BTC_ADDRESS SUPPORT_URL; do
        echo "$name=${!name}"
    done
    echo "# end of serverb.conf"
} > "$SERVERB_SETUP_DIR/serverb.conf"
save_scripts_version "${SOURCE_VERSION:-unknown}"
umask 022
say "✅ Scripts written to %s" "$SCRIPTS_DIR"
echo
run_steps
