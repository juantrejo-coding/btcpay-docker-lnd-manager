#!/bin/bash
# serverb-dashboard-setup.sh: the Server B dashboard and its admin account.
# Made on Server A by serverb-scripts.sh with your settings filled in. Run it on Server B, after
# serverb-bitcoind-setup.sh and serverb-watchtower-setup.sh:
#
#   sudo bash serverb-dashboard-setup.sh
#
#   - The admin account SERVER_B_ADMIN_USER, made for the dashboard if it doesn't exist. It gets
#     no general sudo: it may run one root helper, /usr/local/sbin/serverb-control, which only
#     reads the status and logs of bitcoind and the watchtower and starts, stops and restarts
#     them (one sudoers line, /etc/sudoers.d/serverb-dashboard). Older examples allowed
#     "sudo journalctl -f" and "sudo systemctl status": both open a pager, and from a pager you
#     can start a root shell.
#   - The dashboard: /usr/local/bin/serverb-dashboard. Log in as the admin account and run it.
#   - serverb-update in /usr/local/lib/serverb-dashboard: the dashboard checks with it for new
#     Bitcoin Core and LND releases, and /update installs one (through the root helper, after you
#     type UPDATE; signatures checked as in the setup scripts). Nothing updates by itself.

# @@SETTINGS
SERVER_B_ADMIN_USER=""
SERVER_B_USER=""
WATCHTOWER_PORT=""
WATCHTOWER_ADDRESS=""
SERVER_A_IP=""
SUPPORT_BTC_ADDRESS=""
SUPPORT_URL=""
# @@END-SETTINGS

# @@INCLUDE i18n.sh
# @@I18N
# @@INCLUDE serverb-common.sh

need_root
need_settings SERVER_B_ADMIN_USER
[[ "$SERVER_B_ADMIN_USER" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die "$(T "SERVER_B_ADMIN_USER (%s) is not a usable user name" "$SERVER_B_ADMIN_USER")"
for forbidden in root bitcoin lndtower "${SERVER_B_USER:-}"; do
    [[ "$SERVER_B_ADMIN_USER" != "$forbidden" ]] ||
        die "$(T "SERVER_B_ADMIN_USER can't be %s: that account has another job" "$forbidden")"
done

LIB=/usr/local/lib/serverb-dashboard
HELPER=/usr/local/sbin/serverb-control
SUDOERS=/etc/sudoers.d/serverb-dashboard
apt_install python3 sudo curl ca-certificates gnupg git

# === The admin account ===
if id "$SERVER_B_ADMIN_USER" &>/dev/null; then
    say "ℹ️ %s exists already: left as it is (its password and groups too)" "$SERVER_B_ADMIN_USER"
else
    updating && die "$(T "There is no account %s yet: an update only updates what is set up" "$SERVER_B_ADMIN_USER")"
    confirm_phrase yes "$(T "Create the dashboard's admin account %s? Type yes: " "$SERVER_B_ADMIN_USER")" ||
        die "$(T "Stopped: nothing was changed.")"
    adduser --disabled-password --gecos "" "$SERVER_B_ADMIN_USER" >/dev/null || die "$(T "Could not create %s" "$SERVER_B_ADMIN_USER")"
    say "✅ %s created (no password yet)" "$SERVER_B_ADMIN_USER"
    # A way to log in: the SSH keys of the account running this, and/or a password
    keys_from="${SUDO_USER:-}"
    keys_home=""
    [[ -n "$keys_from" && "$keys_from" != root ]] && keys_home=$(getent passwd "$keys_from" | cut -d: -f6 || true)
    if [[ -n "$keys_home" && -s "$keys_home/.ssh/authorized_keys" && ! -L "$keys_home/.ssh/authorized_keys" ]] &&
       confirm_phrase yes "$(T "Let the SSH keys that log in as %s log in as %s too? Type yes: " "$keys_from" "$SERVER_B_ADMIN_USER")"; then
        # Only plain key lines, without options such as command= that belong to $keys_from
        grep -E '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) ' \
            "$keys_home/.ssh/authorized_keys" |
            sudo -u "$SERVER_B_ADMIN_USER" -H bash -c 'umask 077 && mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys'
        say "✅ %s key(s) may log in as %s" "$(sudo -u "$SERVER_B_ADMIN_USER" -H bash -c 'wc -l < ~/.ssh/authorized_keys')" "$SERVER_B_ADMIN_USER"
    fi
    if confirm_phrase yes "$(T "Set a password for %s now? Type yes: " "$SERVER_B_ADMIN_USER")"; then
        passwd "$SERVER_B_ADMIN_USER" || say "⚠️ No password set: run passwd %s later" "$SERVER_B_ADMIN_USER"
    fi
fi

# === Root helper, dashboard, settings ===
install -d -o root -g root -m 755 "$LIB"
helper_file() {
    cat <<'SERVERB_CONTROL_EOF'
# @@EMBED serverb-control
SERVERB_CONTROL_EOF
}
dashboard_file() {
    cat <<'SERVERB_DASHBOARD_EOF'
# @@EMBED serverb-dashboard.py
SERVERB_DASHBOARD_EOF
}
update_file() {
    cat <<'SERVERB_UPDATE_EOF'
# @@EMBED serverb-update
SERVERB_UPDATE_EOF
}
# The dashboard's translations, in the language Server A's config chose (empty for English)
catalog_file() {
    cat <<'SERVERB_CATALOG_EOF'
# @@CATALOG serverb-dashboard.py
SERVERB_CATALOG_EOF
}
helper_file > "$HELPER.new"
dashboard_file > "$LIB/serverb-dashboard.py.new"
update_file > "$LIB/serverb-update.new"
catalog_file > "$LIB/messages.cat.new"
bash -n "$LIB/serverb-update.new" || die "$(T "serverb-update has a syntax error; nothing was changed")"
chown root:root "$HELPER.new" "$LIB/serverb-dashboard.py.new" "$LIB/serverb-update.new"
chmod 755 "$HELPER.new" "$LIB/serverb-dashboard.py.new" "$LIB/serverb-update.new"
mv -f "$HELPER.new" "$HELPER"
mv -f "$LIB/serverb-dashboard.py.new" "$LIB/serverb-dashboard.py"
mv -f "$LIB/serverb-update.new" "$LIB/serverb-update"
chown root:root "$LIB/messages.cat.new"
chmod 644 "$LIB/messages.cat.new"
mv -f "$LIB/messages.cat.new" "$LIB/messages.cat"
ln -sfn "$LIB/serverb-dashboard.py" /usr/local/bin/serverb-dashboard
python3 -I - "$LIB/settings.json.new" "$WATCHTOWER_PORT" "$WATCHTOWER_ADDRESS" "$SUPPORT_BTC_ADDRESS" "$SUPPORT_URL" "${SERVER_B_USER:-}" "${UI_LANGUAGE:-en}" "$SERVER_A_IP" <<'PY'
import json, sys
path, port, address, btc, url, backup_user, language, server_a_ip = sys.argv[1:]
json.dump({"watchtower_port": port, "watchtower_address": address, "server_a_ip": server_a_ip,
           "support_btc_address": btc, "support_url": url, "backup_user": backup_user,
           "language": language},
          open(path, "w"), indent=1)
PY
chmod 644 "$LIB/settings.json.new"
mv -f "$LIB/settings.json.new" "$LIB/settings.json"
say "✅ %s, /usr/local/bin/serverb-dashboard, %s/serverb-update" "$HELPER" "$LIB"

# === sudo: that helper only ===
printf '# Server B dashboard (serverb-dashboard-setup.sh): %s may run only this helper as root\n%s ALL=(root) NOPASSWD: %s\n' \
    "$SERVER_B_ADMIN_USER" "$SERVER_B_ADMIN_USER" "$HELPER" > "$SUDOERS.new"
chmod 440 "$SUDOERS.new"
visudo -cf "$SUDOERS.new" >/dev/null || { rm -f "$SUDOERS.new"; die "$(T "visudo rejected the sudoers line; nothing was changed")"; }
mv -f "$SUDOERS.new" "$SUDOERS"
say "✅ %s: %s may run %s as root, nothing else" "$SUDOERS" "$SERVER_B_ADMIN_USER" "$HELPER"

# === A waiting Bitcoin Core or LND update, at boot (serverb-update: not safe for 24 hours) ===
cat > /etc/systemd/system/serverb-update-boot.service.new <<UNIT
[Unit]
Description=Installs a waiting Bitcoin Core or LND update (serverb-update) before they start
After=local-fs.target
Before=bitcoind.service lnd-watchtower.service

[Service]
Type=oneshot
ExecStart=$LIB/serverb-update boot
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
UNIT
chmod 644 /etc/systemd/system/serverb-update-boot.service.new
mv -f /etc/systemd/system/serverb-update-boot.service.new /etc/systemd/system/serverb-update-boot.service
systemctl daemon-reload
systemctl enable --quiet serverb-update-boot.service
say "✅ serverb-update-boot.service: an update that waited too long is installed at the next boot"

echo
say "✅ Done. Log in as %s and run: serverb-dashboard" "$SERVER_B_ADMIN_USER"
# An update writes the new version only after this step: the preview would offer it again
updating || sudo -u "$SERVER_B_ADMIN_USER" -H /usr/local/bin/serverb-dashboard --once | show_lines || true
