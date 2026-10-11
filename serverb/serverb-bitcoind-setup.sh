#!/bin/bash
# serverb-bitcoind-setup.sh: a pruned Bitcoin Core on Server B, the watchtower's backend.
# Made on Server A by serverb-scripts.sh with your settings filled in. Run it on Server B:
#
#   sudo bash serverb-bitcoind-setup.sh
#
#   - The latest Bitcoin Core release (or BITCOIN_CORE_VERSION) from bitcoincore.org. Its
#     SHA256SUMS must carry good signatures from at least MIN_SIGNATURES different builders,
#     whose keys come from github.com/bitcoin-core/guix.sigs; the download must match SHA256SUMS.
#     bitcoind and bitcoin-cli go into /usr/local/bin.
#   - System user bitcoin, data in /var/lib/bitcoind, settings in /etc/bitcoin/bitcoin.conf:
#     pruned to PRUNE_MB, no txindex (Bitcoin Core refuses txindex with pruning), no inbound
#     peers, RPC on 127.0.0.1 only with a cookie file the bitcoin group may read (no password in
#     a file), ZMQ for LND. Your own additions go in /etc/bitcoin/local.conf (kept on reruns).
#   - A systemd service, bitcoind, with hardening.
#   - Optional: ~/chain-incoming for SERVER_B_USER, so Server A can copy its pruned blockchain
#     there (lnd-manager: /chain copy); serverb-import-chain.sh then takes it over. That is much
#     faster than downloading the blockchain from the network.
# Rerunning it updates Bitcoin Core to the latest release and rewrites bitcoin.conf.

# @@SETTINGS
PRUNE_MB=""
SERVER_B_USER=""
# @@END-SETTINGS
# Pin a version (e.g. 29.1), or leave empty for the latest release
BITCOIN_CORE_VERSION="${BITCOIN_CORE_VERSION:-}"
# Good builder signatures SHA256SUMS needs
MIN_SIGNATURES="${MIN_SIGNATURES:-3}"

# @@INCLUDE i18n.sh
# @@I18N
# @@INCLUDE serverb-common.sh
# @@INCLUDE serverb-releases.sh

need_root
need_settings PRUNE_MB
[[ "$PRUNE_MB" =~ ^[0-9]+$ ]] && (( PRUNE_MB >= 550 )) || die "$(T "PRUNE_MB must be at least 550 (Bitcoin Core's minimum)")"

DATA_DIR=/var/lib/bitcoind
CONF_DIR=/etc/bitcoin
CONF="$CONF_DIR/bitcoin.conf"
UNIT=/etc/systemd/system/bitcoind.service

apt_install curl ca-certificates gnupg git rsync python3

# === Download, check, install ===
if [[ -z "$BITCOIN_CORE_VERSION" ]]; then
    say "🔎 Looking up the latest Bitcoin Core release..."
    BITCOIN_CORE_VERSION=$(bitcoin_core_latest) || die "$(T "Could not find a Bitcoin Core release on bitcoincore.org/bin/")"
fi
[[ "$BITCOIN_CORE_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "$(T "Not a release version: %s" "$BITCOIN_CORE_VERSION")"
INSTALLED=$(bitcoin_core_installed)
[[ -n "$INSTALLED" ]] && say "   installed now: %s" "$INSTALLED"
bitcoin_core_install "$BITCOIN_CORE_VERSION" "$MIN_SIGNATURES"

# === User, settings, service ===
system_user bitcoin "$DATA_DIR"
install -d -o root -g bitcoin -m 750 "$CONF_DIR"
[[ -f "$CONF_DIR/local.conf" ]] || install -o root -g bitcoin -m 640 /dev/null "$CONF_DIR/local.conf"
COOKIE_PERMS="rpccookieperms=group"
if [[ "${BITCOIN_CORE_VERSION%%.*}" -lt 28 ]]; then
    # Older releases can't make the cookie group-readable; the watchtower couldn't read it
    COOKIE_PERMS="# rpccookieperms needs Bitcoin Core 28 or later"
fi
cat > "$CONF.new" <<CONF
# Made by serverb-bitcoind-setup.sh; rerunning it rewrites this file. Your own settings go in
# $CONF_DIR/local.conf.
server=1
# Pruned: keeps about ${PRUNE_MB} MB of blocks. txindex can't be used with pruning.
prune=$PRUNE_MB
# No inbound peers: the watchtower's backend only needs outbound ones
listen=0
# RPC only from this server, through the cookie file in $DATA_DIR (no password in a file).
# The bitcoin group (the watchtower's user) may read the cookie.
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
$COOKIE_PERMS
# Blocks and transactions for LND
zmqpubrawblock=tcp://127.0.0.1:28332
zmqpubrawtx=tcp://127.0.0.1:28333
includeconf=$CONF_DIR/local.conf
CONF
chown root:bitcoin "$CONF.new"
chmod 640 "$CONF.new"
mv -f "$CONF.new" "$CONF"
say "✅ %s (prune=%s)" "$CONF" "$PRUNE_MB"

cat > "$UNIT" <<UNIT
[Unit]
Description=Bitcoin Core (pruned, for the LND watchtower)
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
ExecStart=/usr/local/bin/bitcoind -conf=$CONF -datadir=$DATA_DIR -daemon=0 -printtoconsole=0
User=bitcoin
Group=bitcoin
Restart=on-failure
RestartSec=30
TimeoutStartSec=infinity
TimeoutStopSec=600
# Hardening
ProtectSystem=strict
ReadWritePaths=$DATA_DIR
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
NoNewPrivileges=true
MemoryDenyWriteExecute=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --quiet bitcoind
say "✅ systemd service bitcoind (enabled)"

# === Copy of Server A's blockchain, or a sync from the network ===
COPY=false
# A rerun (to update Bitcoin Core) on a bitcoind that has its blockchain already: no copy needed
HAS_CHAIN=false
[[ -d "$DATA_DIR/blocks/index" && -d "$DATA_DIR/chainstate" ]] && HAS_CHAIN=true
INCOMING=""
[[ -n "${SERVER_B_USER:-}" ]] && INCOMING="$(getent passwd "$SERVER_B_USER" | cut -d: -f6 || true)/chain-incoming"
if $HAS_CHAIN; then
    say "ℹ️ bitcoind has its blockchain already: no copy from Server A is needed."
    if [[ "$INCOMING" != /chain-incoming && -d "$INCOMING" ]]; then
        say "⚠️ %s still exists, so Server A's key may write there. Not needed now:" "$INCOMING"
        say "   delete it (sudo rm -rf %s), unless you mean to import a new copy" "$INCOMING"
        say "   with serverb-import-chain.sh."
    fi
elif [[ -n "${SERVER_B_USER:-}" ]] && id "$SERVER_B_USER" &>/dev/null; then
    if ! command -v rrsync >/dev/null; then
        say "ℹ️ rrsync is missing (rsync 3.2.4 or later has it), so Server A can't copy its blockchain here."
    elif [[ -d "$INCOMING" ]]; then
        say "ℹ️ ~%s/chain-incoming exists: Server A may copy its blockchain there." "$SERVER_B_USER"
        COPY=true
    else
        echo
        say "Server A can copy its pruned blockchain here instead: hours, rather than days of"
        say "syncing from the network. Server A's key may then write into ~%s/chain-incoming" "$SERVER_B_USER"
        say "(only there, and only until serverb-import-chain.sh has taken the copy over)."
        if confirm_phrase yes "$(T "Let Server A copy its blockchain here? Type yes: ")"; then
            sudo -u "$SERVER_B_USER" -H bash -c 'umask 077 && mkdir -p ~/chain-incoming'
            COPY=true
            say "✅ ~%s/chain-incoming made" "$SERVER_B_USER"
        fi
    fi
fi
free_gb=$(( $(df --output=avail -k /var/lib | tail -n 1) / 1024 / 1024 ))
say "   Free space for /var/lib: %s GB" "${free_gb}"

if $COPY; then
    systemctl stop bitcoind 2>/dev/null || true
    echo
    say "✅ Bitcoin Core is installed; it starts when the copy is in place."
    say "   Next: on Server A, lnd-manager: /chain copy. Then here: sudo bash serverb-import-chain.sh"
else
    systemctl restart bitcoind
    echo
    if $HAS_CHAIN; then
        say "✅ Bitcoin Core runs again, on the version installed above."
    else
        say "✅ Bitcoin Core runs and syncs from the network (this takes a long time)."
        say "   Progress: the Server B dashboard, or journalctl -u bitcoind."
    fi
fi
