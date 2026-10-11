#!/bin/bash
# serverb-watchtower-setup.sh: LND as a watchtower for Server A's node, on Server B.
# Made on Server A by serverb-scripts.sh with your settings filled in. Run it on Server B, after
# serverb-bitcoind-setup.sh:
#
#   sudo bash serverb-watchtower-setup.sh
#
#   - The latest LND release (or LND_VERSION) from github.com/lightningnetwork/lnd. Its manifest
#     must carry good signatures from at least MIN_SIGNATURES of LND's release signers (keys from
#     the lnd repository, fingerprints shown so you can compare them with LND's docs), and the
#     download must match the manifest. lnd and lncli go into /usr/local/bin.
#   - System user lndtower (in the bitcoin group, for bitcoind's cookie), data in /var/lib/lndtower,
#     settings in /etc/lndtower/lnd.conf: watchtower on WATCHTOWER_PORT, bitcoind backend through
#     the cookie and ZMQ, no Lightning peer port, RPC on 127.0.0.1 only. REST (127.0.0.1) is on
#     only until the tower's wallet is made.
#   - The tower's wallet: its seed is shown once to write down. Its password is random and kept in
#     /var/lib/lndtower/unlock (only lndtower can read it), so the tower unlocks by itself.
#     The tower needs no bitcoin: it broadcasts justice transactions your node signed already.
#   - Firewall: WATCHTOWER_PORT only from Server A's address, if ufw is active. If it isn't, it
#     offers to turn it on (with SSH allowed, so you aren't locked out).
#   - A systemd service, lnd-watchtower.
# Rerunning it updates LND and rewrites lnd.conf; the wallet stays.

# @@SETTINGS
WATCHTOWER_PORT=""
WATCHTOWER_ADDRESS=""
SERVER_A_IP=""
# @@END-SETTINGS
# Pin a version (e.g. v0.19.3-beta), or leave empty for the latest release
LND_VERSION="${LND_VERSION:-}"
MIN_SIGNATURES="${MIN_SIGNATURES:-2}"

# @@INCLUDE i18n.sh
# @@I18N
# @@INCLUDE serverb-common.sh
# @@INCLUDE serverb-releases.sh

need_root
need_settings WATCHTOWER_PORT WATCHTOWER_ADDRESS SERVER_A_IP
[[ "$WATCHTOWER_PORT" =~ ^[0-9]{1,5}$ ]] || die "$(T "WATCHTOWER_PORT is not a port number")"
[[ -f /etc/bitcoin/bitcoin.conf ]] || die "$(T "Bitcoin Core isn't set up here yet: run serverb-bitcoind-setup.sh first")"

LND_HOME=/var/lib/lndtower
CONF_DIR=/etc/lndtower
CONF="$CONF_DIR/lnd.conf"
UNLOCK_DIR="$LND_HOME/unlock"
PASSWORD_FILE="$UNLOCK_DIR/password"
RPC=127.0.0.1:10019
REST=127.0.0.1:8099
NET_DIR="$LND_HOME/data/chain/bitcoin/mainnet"
UNIT=/etc/systemd/system/lnd-watchtower.service

apt_install curl ca-certificates gnupg python3

# === Download, check, install ===
if [[ -z "$LND_VERSION" ]]; then
    say "🔎 Looking up the latest LND release..."
    LND_VERSION=$(lnd_latest) || die "$(T "Could not find the latest LND release on api.github.com")"
fi
lnd_install "$LND_VERSION" "$MIN_SIGNATURES"

# === User, settings, service ===
system_user lndtower "$LND_HOME"
usermod -aG bitcoin lndtower
# lndtower owns its folder: everything in it is done as lndtower, so root never follows a link
# that user put there
as_tower() {
    runuser -u lndtower -- "$@"
}
wallet_exists() {
    as_tower test -f "$NET_DIR/wallet.db"
}
install -d -o root -g lndtower -m 750 "$CONF_DIR"
# REST only to make the wallet; nothing needs it afterwards
write_conf() {
    local rest_line="$1"
    cat > "$CONF.new" <<CONF
; Made by serverb-watchtower-setup.sh; rerunning it rewrites this file.
[Application Options]
lnddir=$LND_HOME
; A watchtower needs no Lightning peers, so no peer port
nolisten=true
rpclisten=$RPC
$rest_line
debuglevel=info
; Unlocks by itself with the password in $PASSWORD_FILE
wallet-unlock-password-file=$PASSWORD_FILE
wallet-unlock-allow-create=true

[Bitcoin]
bitcoin.mainnet=true
bitcoin.node=bitcoind

[Bitcoind]
bitcoind.rpchost=127.0.0.1:8332
bitcoind.rpccookie=/var/lib/bitcoind/.cookie
bitcoind.zmqpubrawblock=tcp://127.0.0.1:28332
bitcoind.zmqpubrawtx=tcp://127.0.0.1:28333

[watchtower]
watchtower.active=true
watchtower.listen=0.0.0.0:$WATCHTOWER_PORT
watchtower.externalip=$WATCHTOWER_ADDRESS:$WATCHTOWER_PORT
CONF
    chown root:lndtower "$CONF.new"
    chmod 640 "$CONF.new"
    mv -f "$CONF.new" "$CONF"
}
if wallet_exists; then
    write_conf "norest=true"
else
    write_conf "restlisten=$REST"
fi
echo "✅ $CONF"

# Random: nobody types it, and the tower holds no funds it would protect
head -c 48 /dev/urandom | base64 | tr -d '/+=\n' | head -c 40 | as_tower bash -c '
    set -euo pipefail
    umask 077
    mkdir -p "$1"
    chmod 700 "$1"
    if [[ ! -s "$2" ]]; then
        cat > "$2.new"
        chmod 400 "$2.new"
        mv -f "$2.new" "$2"
    else
        cat > /dev/null
    fi' _ "$UNLOCK_DIR" "$PASSWORD_FILE"

cat > "$UNIT" <<UNIT
[Unit]
Description=LND watchtower for Server A's node
After=bitcoind.service network-online.target
Wants=bitcoind.service network-online.target

[Service]
Type=exec
ExecStart=/usr/local/bin/lnd --configfile=$CONF
User=lndtower
Group=lndtower
Restart=on-failure
RestartSec=30
TimeoutStopSec=300
LimitNOFILE=4096
# Hardening
ProtectSystem=strict
ReadWritePaths=$LND_HOME
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
NoNewPrivileges=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --quiet lnd-watchtower
systemctl restart lnd-watchtower
say "✅ systemd service lnd-watchtower (enabled, started)"

# === The tower's wallet ===
# LND's REST interface on 127.0.0.1, with its own TLS certificate, called as lndtower (the
# certificate and the password are in its folder); the password and seed go to curl on stdin,
# never on a command line
rest() {
    as_tower curl --silent --show-error --fail --cacert "$LND_HOME/tls.cert" "$@"
}
state=""
if wallet_exists; then
    state=exists
else
    say "⏳ Waiting for LND to start..."
    for _ in $(seq 1 60); do
        rest "https://$REST/v1/state" >/dev/null 2>&1 && break
        sleep 2
    done
    state=$(rest "https://$REST/v1/state" 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("state",""))' 2>/dev/null || true)
fi
if [[ "$state" == NON_EXISTING ]]; then
    seed_json=$(rest "https://$REST/v1/genseed") || die "$(T "LND could not make a seed")"
    echo
    say "🔑 The tower's seed. Write it down: it is the tower's identity (its public key). Without it,"
    say "   a lost tower is replaced by a new one with a new key, which Server A then adds instead."
    say "-----------------BEGIN TOWER SEED-----------------"
    python3 -I -c 'import json,sys; w=json.load(sys.stdin)["cipher_seed_mnemonic"]; [print("%2d. %-12s" % (i+1, x), end="\n" if i % 4 == 3 else "") for i, x in enumerate(w)]' <<< "$seed_json"
    say "------------------END TOWER SEED------------------"
    confirm_phrase "I WROTE IT DOWN" "$(T "Type 'I WROTE IT DOWN' once you have: ")" || die "$(T "Stopped: the tower's wallet was not made. Run this script again.")"
    clear 2>/dev/null || true
    # The password read as lndtower too
    python3 -I -c '
import base64, json, sys
seed = json.load(sys.stdin)["cipher_seed_mnemonic"]
pw = open(sys.argv[1], "rb").read().strip()
print(json.dumps({"wallet_password": base64.b64encode(pw).decode(), "cipher_seed_mnemonic": seed}))' \
        <(as_tower cat "$PASSWORD_FILE") <<< "$seed_json" | rest -X POST --data-binary @- "https://$REST/v1/initwallet" >/dev/null ||
        die "$(T "LND could not make the tower's wallet")"
    unset seed_json
    say "✅ The tower's wallet is made; it unlocks by itself from now on"
    for _ in $(seq 1 30); do
        wallet_exists && break
        sleep 1
    done
    write_conf "norest=true"
    systemctl restart lnd-watchtower
    say "✅ LND's REST interface is off again (only needed to make the wallet)"
elif [[ "$state" == exists ]]; then
    say "ℹ️ The tower's wallet exists already (it unlocks by itself)"
elif [[ -n "$state" ]]; then
    say "ℹ️ The tower's wallet exists already (state: %s; it unlocks by itself)" "$state"
else
    say "⚠️ LND's REST interface doesn't answer: journalctl -u lnd-watchtower"
fi

# === Firewall ===
tower_rule() {
    ufw allow from "$SERVER_A_IP" to any port "$WATCHTOWER_PORT" proto tcp comment 'LND watchtower for Server A' >/dev/null
    say "✅ ufw: port %s open only to Server A (%s)" "$WATCHTOWER_PORT" "$SERVER_A_IP"
}
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
    tower_rule
else
    echo
    say "⚠️ No active ufw firewall: port %s is open to everyone. Anyone could then store" "$WATCHTOWER_PORT"
    say "   sessions in the tower and fill its disk."
    say "   ufw can be turned on with the tower port open only to Server A (%s) and SSH open to" "$SERVER_A_IP"
    say "   all. Every other incoming port is then closed: if this server offers anything else, say no"
    say "   and add ufw rules for it yourself first."
    if confirm_phrase yes "$(T "Turn on ufw that way? Type yes: ")"; then
        apt_install ufw
        mapfile -t ssh_ports < <(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | sort -u)
        (( ${#ssh_ports[@]} > 0 )) || ssh_ports=(22)
        for p in "${ssh_ports[@]}"; do
            [[ "$p" =~ ^[0-9]{1,5}$ ]] || die "$(T "Odd SSH port from sshd -T (%s): ufw not turned on" "$p")"
            ufw allow "$p/tcp" comment 'SSH' >/dev/null
            say "✅ ufw: SSH port %s open" "$p"
        done
        tower_rule
        ufw --force enable >/dev/null || die "$(T "ufw could not be turned on")"
        say "✅ ufw is on"
    else
        say "   Later: ufw allow from %s to any port %s proto tcp (with SSH allowed), ufw enable" "$SERVER_A_IP" "$WATCHTOWER_PORT"
    fi
fi

# === What Server A needs ===
# An array, not a function: timeout runs programs, not shell functions
LNCLI_RO=(runuser -u lndtower -- /usr/local/bin/lncli --lnddir="$LND_HOME" --rpcserver="$RPC"
          --macaroonpath="$NET_DIR/readonly.macaroon")
echo
info=""
for _ in $(seq 1 36); do
    info=$(timeout 20 "${LNCLI_RO[@]}" tower info 2>/dev/null) && break
    info=""
    sleep 5
done
if [[ -n "$info" ]]; then
    pubkey=$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["pubkey"])' <<< "$info")
    say "✅ The watchtower runs. For Server A (lnd-manager: /tower add):"
    echo "   $pubkey@$WATCHTOWER_ADDRESS:$WATCHTOWER_PORT"
else
    say "ℹ️ The watchtower starts once bitcoind has caught up. Its address for Server A then shows in"
    say "   the Server B dashboard (/status), or: sudo -u lndtower lncli --lnddir=%s --rpcserver=%s --macaroonpath=%s/readonly.macaroon tower info" "$LND_HOME" "$RPC" "$NET_DIR"
fi
