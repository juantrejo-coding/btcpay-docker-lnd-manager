#!/bin/bash
# serverb-user-setup.sh: the backup user on Server B (SERVER_B_USER), made safely.
# Made on Server A by serverb-scripts.sh with your settings filled in. Run it on Server B:
#
#   sudo bash serverb-user-setup.sh
#
# It sets up, for a new or an existing user:
#   - the user, with no password (login with Server A's key only); an existing user's password
#     is left as it is, but it asks first, since the sshd limits below stop password logins. An
#     existing user in the sudo, admin or wheel group is refused.
#   - its home closed to other users, ~/.ssh 700
#   - Server A's public key in ~/.ssh/authorized_keys, restricted: no terminal, no forwarding (a
#     line with that key and no restrictions is replaced)
#   - an sshd "Match User" block (/etc/ssh/sshd_config.d/60-lnd-backup-<user>.conf): keys only,
#     no terminal, no forwarding of any kind; checked with sshd -t before sshd is reloaded
#   - if Server B's backup gate is installed for this user already: the gate is updated to the
#     version made with this script (needed for copying Server A's blockchain)
# Afterwards, setup on Server A (lnd-manager: /setup) installs the backup gate over this key.
# Not done, unlike older examples: no chroot or internal-sftp (they would block the gate), no
# second sshd, no Server A user on Server B.

# @@SETTINGS
SERVER_B_USER=""
SERVER_A_KEY=""
# @@END-SETTINGS

# @@INCLUDE i18n.sh
# @@I18N
# @@INCLUDE serverb-common.sh

need_root
need_settings SERVER_B_USER SERVER_A_KEY
[[ "$SERVER_B_USER" =~ ^[a-z][a-z0-9_-]{0,31}$ && "$SERVER_B_USER" != root ]] ||
    die "$(T "SERVER_B_USER (%s) is not a usable user name" "$SERVER_B_USER")"
read -r KEY_TYPE KEY_BLOB _ <<< "$SERVER_A_KEY"
[[ "$KEY_TYPE" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))$ && "$KEY_BLOB" =~ ^[A-Za-z0-9+/=]+$ ]] ||
    die "$(T "SERVER_A_KEY doesn't look like an SSH public key")"

say "Server B backup user: %s" "$SERVER_B_USER"
say "Server A's key:       %s ...%s" "$KEY_TYPE" "${KEY_BLOB: -16}"
echo

# rrsync, for the blockchain copy from Server A, comes with rsync
apt_install rsync

# === The user ===
if id "$SERVER_B_USER" &>/dev/null; then
    say "ℹ️ User %s exists already: its password (if any) is left as it is." "$SERVER_B_USER"
    # Server A's key must never reach an account that can become root
    for g in $(id -nG "$SERVER_B_USER"); do
        case "$g" in
            sudo | admin | wheel | root)
                die "$(T "%s is in the %s group. Server A's key must reach an account of its own, without sudo: set another SERVER_B_USER on Server A." "$SERVER_B_USER" "$g")" ;;
        esac
    done
    # The sshd limits below take password and terminal logins away from this user
    if [[ "$(passwd -S "$SERVER_B_USER" 2>/dev/null | awk '{ print $2 }')" == P ]]; then
        echo
        say "⚠️ %s has a password, so a person may log in with it. This script limits the" "$SERVER_B_USER"
        say "   account to keys, with no terminal: nobody could then log in as %s with a" "$SERVER_B_USER"
        say "   password or get a shell over SSH. If a person uses this account, stop here and set"
        say "   another SERVER_B_USER on Server A."
        # An update keeps what you agreed to before: the limits are there already
        if updating; then
            [[ -f "/etc/ssh/sshd_config.d/60-lnd-backup-$SERVER_B_USER.conf" ]] ||
                die "$(T "%s has a password and no sshd limits yet: run this step by hand once (sudo ./serverb-setup.sh)" "$SERVER_B_USER")"
        else
            confirm_phrase yes "$(T "Limit %s that way anyway? Type yes: " "$SERVER_B_USER")" || die "$(T "Stopped: nothing was changed.")"
        fi
    fi
else
    updating && die "$(T "There is no user %s yet: an update only updates what is set up" "$SERVER_B_USER")"
    confirm_phrase yes "$(T "Create user %s (no password, Server A's key only)? Type yes: " "$SERVER_B_USER")" ||
        die "$(T "Stopped: nothing was changed.")"
    # --disabled-password: no password at all, but key logins work. (passwd -d, in older
    # examples, would leave an EMPTY password, which lets anyone in where that is allowed.)
    adduser --disabled-password --gecos "" "$SERVER_B_USER" >/dev/null ||
        die "$(T "Could not create user %s" "$SERVER_B_USER")"
    say "✅ User %s created" "$SERVER_B_USER"
fi
B_HOME=$(getent passwd "$SERVER_B_USER" | cut -d: -f6)
[[ -n "$B_HOME" && -d "$B_HOME" && ! -L "$B_HOME" ]] || die "$(T "%s has no usable home folder (%s)" "$SERVER_B_USER" "$B_HOME")"
# Closed to other users; the group may read (adduser's default) but not write
chmod g-w,o-rwx "$B_HOME"

# === Server A's key ===
# Written as the user itself, so root never writes into a folder that user controls
as_user() {
    sudo -u "$SERVER_B_USER" -H "$@"
}
# The messages come translated as $1 to $4: the user's shell has no translations
printf '%s %s\n' "$KEY_TYPE" "$KEY_BLOB" | as_user bash -c '
    set -euo pipefail
    umask 077
    read -r type blob
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    touch ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    # A line with this key and no "restrict" (a full shell) is replaced by the restricted one
    if grep -qF " $blob" ~/.ssh/authorized_keys; then
        awk -v type="$type" -v blob="$blob" "
            { for (i = 1; i <= NF; i++) if (\$i == blob) break }
            i <= NF && \$1 !~ /^restrict(,|\$)/ { print \"restrict \" type \" \" blob \" lnd-backup-server-a\"; changed = 1; next }
            { print }
            END { exit changed ? 3 : 0 }" ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.new && rc=0 || rc=$?
        if (( rc == 3 )); then
            mv -f ~/.ssh/authorized_keys.new ~/.ssh/authorized_keys
            echo "$1"
        elif (( rc == 0 )); then
            rm -f ~/.ssh/authorized_keys.new
            echo "$2"
        else
            rm -f ~/.ssh/authorized_keys.new
            echo "$4" >&2
            exit 1
        fi
    else
        printf "restrict %s %s lnd-backup-server-a\n" "$type" "$blob" >> ~/.ssh/authorized_keys
        echo "$3"
    fi
' _ "$(T "✅ Server A's key was in ~/.ssh/authorized_keys without restrictions: now restricted")" \
    "$(T "ℹ️ Server A's key is in ~/.ssh/authorized_keys already, restricted: left as it is")" \
    "$(T "✅ Server A's key added, restricted (no terminal, no forwarding)")" \
    "$(T "❌ Could not check ~/.ssh/authorized_keys")"

# === sshd: what this user may do ===
SSHD_DROPIN="/etc/ssh/sshd_config.d/60-lnd-backup-$SERVER_B_USER.conf"
if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
    say "⚠️ /etc/ssh/sshd_config doesn't include /etc/ssh/sshd_config.d/*.conf: the sshd limits for"
    say "   %s were not added. The restricted key line still applies." "$SERVER_B_USER"
else
    before_root=$(sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null | grep -E '^(permittty|passwordauthentication|allowtcpforwarding) ' || true)
    tmp="$SSHD_DROPIN.new"
    cat > "$tmp" <<SSHD
# Server B backup user for Server A (serverb-user-setup.sh): keys only, no terminal, no forwarding.
# Server A's key may then only run the backup gate (~/.local/bin/lnd-backup-gate).
Match User $SERVER_B_USER
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AuthenticationMethods publickey
    PermitTTY no
    AllowTcpForwarding no
    AllowStreamLocalForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTunnel no
    PermitUserRC no
SSHD
    chmod 644 "$tmp"
    if [[ -f "$SSHD_DROPIN" ]] && cmp -s "$tmp" "$SSHD_DROPIN"; then
        rm -f "$tmp"
        say "ℹ️ %s is up to date" "$SSHD_DROPIN"
    else
        old=""
        [[ -f "$SSHD_DROPIN" ]] && old=$(cat "$SSHD_DROPIN")
        mv -f "$tmp" "$SSHD_DROPIN"
        if ! sshd -t; then
            if [[ -n "$old" ]]; then printf '%s\n' "$old" > "$SSHD_DROPIN"; else rm -f "$SSHD_DROPIN"; fi
            die "$(T "sshd rejected the new settings; they were taken out again and sshd was not reloaded")"
        fi
        after_root=$(sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null | grep -E '^(permittty|passwordauthentication|allowtcpforwarding) ' || true)
        if [[ "$before_root" != "$after_root" ]]; then
            if [[ -n "$old" ]]; then printf '%s\n' "$old" > "$SSHD_DROPIN"; else rm -f "$SSHD_DROPIN"; fi
            die "$(T "The new settings would also have changed other users' logins; taken out again")"
        fi
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null ||
            say "⚠️ Could not reload sshd: the limits apply after its next restart"
        say "✅ sshd limits for %s in %s" "$SERVER_B_USER" "$SSHD_DROPIN"
    fi
    sshd -T -C "user=$SERVER_B_USER,host=localhost,addr=127.0.0.1" 2>/dev/null |
        grep -E '^(permittty|passwordauthentication|allowtcpforwarding|x11forwarding) ' | show_lines
fi

# === The backup gate, if it is installed already ===
# The gate can't be updated from Server A once it is installed (that's its point), so a new
# version comes this way
gate_installer() {
    cat <<'GATE_INSTALLER_EOF'
# @@EMBED server-b-install.sh
GATE_INSTALLER_EOF
}
if as_user test -x "$B_HOME/.local/bin/lnd-backup-gate" &&
   as_user grep -q 'command="[^"]*lnd-backup-gate"' "$B_HOME/.ssh/authorized_keys"; then
    say "🔄 Updating Server B's backup gate for %s..." "$SERVER_B_USER"
    keyfile=$(as_user mktemp)
    printf '%s %s\n' "$KEY_TYPE" "$KEY_BLOB" | as_user tee "$keyfile" >/dev/null
    gate_installer | as_user bash -s -- "$keyfile" | show_lines
    as_user rm -f "$keyfile"
    NEXT=$(T "Server A reaches %s through the updated gate." "$SERVER_B_USER")
else
    NEXT=$(T "On Server A, run setup (lnd-manager: /setup): it installs the backup gate over this key.")
fi

echo
say "✅ %s is ready." "$SERVER_B_USER"
echo "   $NEXT"
