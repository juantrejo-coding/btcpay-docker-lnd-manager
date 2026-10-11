#!/bin/bash
# serverb-import-chain.sh: takes over the blockchain Server A copied into ~SERVER_B_USER/chain-incoming
# (lnd-manager on Server A: /chain copy). Made on Server A by serverb-scripts.sh. Run it on
# Server B after the copy has finished:
#
#   sudo bash serverb-import-chain.sh
#
#   - Takes the folder away from SERVER_B_USER first (root-owned), so nothing can change it
#     while it is checked and moved; refuses links, devices and wallets in it.
#   - Refuses hard links: they could be SERVER_B_USER's other files (its backups), which root
#     would otherwise take away from that user.
#   - Stops bitcoind, keeps its current blocks/ and chainstate/ in /var/lib/bitcoind-before-import-<time>,
#     moves the copy in for the bitcoin user, starts bitcoind. Bitcoin Core then prunes it down
#     to this server's prune size by itself.
#   - ~/chain-incoming is gone afterwards, so Server A's key can't write here any more.

# @@SETTINGS
SERVER_B_USER=""
# @@END-SETTINGS

# @@INCLUDE i18n.sh
# @@I18N
# @@INCLUDE serverb-common.sh

need_root
need_settings SERVER_B_USER
DATA_DIR=/var/lib/bitcoind
CONF=/etc/bitcoin/bitcoin.conf
[[ -f "$CONF" && -x /usr/local/bin/bitcoind ]] || die "$(T "Bitcoin Core isn't set up here yet: run serverb-bitcoind-setup.sh first")"
B_HOME=$(getent passwd "$SERVER_B_USER" | cut -d: -f6 || true)
[[ -n "$B_HOME" ]] || die "$(T "There is no user %s" "$SERVER_B_USER")"
SRC="$B_HOME/chain-incoming"
[[ -d "$SRC" && ! -L "$SRC" ]] || die "$(T "There is no %s: copy the blockchain from Server A first (lnd-manager: /chain copy)" "$SRC")"
if pgrep -u "$SERVER_B_USER" -x rsync >/dev/null || pgrep -u "$SERVER_B_USER" -f rrsync >/dev/null; then
    die "$(T "A copy from Server A is still running. Wait until /chain copy on Server A has finished.")"
fi
for d in blocks chainstate blocks/index; do
    [[ -d "$SRC/$d" && ! -L "$SRC/$d" ]] || die "$(T "%s/%s is missing: the copy isn't complete. Run /chain copy on Server A again." "$SRC" "$d")"
done
say "Copy from Server A: %s in %s" "$(du -sh "$SRC" | cut -f1)" "$SRC"
confirm_phrase yes "$(T "Stop bitcoind and use this copy? Type yes: ")" || die "$(T "Stopped: nothing was changed.")"

# === Take it away from SERVER_B_USER, then check it ===
# First out of that user's home, into root's own folder: in the home, the user could rename the
# folder and put a link in its place at any moment, and root would then work on the link's target.
# mv moves a link as a link, so what arrives is checked once more. Then the folders inside are
# closed, so nothing can be added or linked in them any more. Never following links (-h; find
# doesn't follow them).
STAMP=$(date +%Y%m%d-%H%M%S)
WORK="/var/lib/bitcoind-import-$STAMP"
say "📦 Taking the copy into %s (across disks this takes a while)..." "$WORK"
mv -T -- "$SRC" "$WORK" || die "$(T "Could not move %s to %s" "$SRC" "$WORK")"
if [[ -L "$WORK" || ! -d "$WORK" ]]; then
    rm -f -- "$WORK"
    die "$(T "%s was replaced by something that isn't a folder meanwhile: not used" "$SRC")"
fi
AGAIN=$(T "To copy again: sudo rm -rf %s; sudo -u %s mkdir -m 700 %s; then /chain copy on Server A." "$WORK" "$SERVER_B_USER" "$SRC")
chown -h root:root "$WORK"
chmod 700 "$WORK"
# A copy that started during the question can't write here any more; it may have left it incomplete
if pgrep -u "$SERVER_B_USER" -x rsync >/dev/null || pgrep -u "$SERVER_B_USER" -f rrsync >/dev/null; then
    die "$(T "A copy from Server A started meanwhile, so this one may be incomplete: not used. %s" "$AGAIN")"
fi
SRC="$WORK"
find "$SRC" -type d -exec chown -h root:root {} + -exec chmod 700 {} +
# A file with more than one link may be one of that user's other files (a backup) linked in
# here. Root would give it to root and then to bitcoin, and the backup gate couldn't read it.
linked=$(find "$SRC" -type f -links +1 -print -quit)
[[ -z "$linked" ]] || die "$(T "%s holds a hard link (%s), maybe to one of %s's other files. Nothing was used or changed except the folders in %s, now root's. %s" "$SRC" "$linked" "$SERVER_B_USER" "$SRC" "$AGAIN")"
chown -R -h root:root "$SRC"
odd=$(find "$SRC" ! -type f ! -type d -print -quit)
[[ -z "$odd" ]] || die "$(T "%s holds something that is neither a file nor a folder (%s). Not used; it stays root-owned in %s." "$SRC" "$odd" "$SRC")"
wallet=$(find "$SRC" \( -name 'wallet.dat' -o -name 'wallets' \) -print -quit)
[[ -z "$wallet" ]] || die "$(T "%s holds a wallet (%s). Not used. %s" "$SRC" "$wallet" "$AGAIN")"

# === Swap ===
say "🛑 Stopping bitcoind..."
systemctl stop bitcoind 2>/dev/null || true
# In root's own folder: root doesn't make or fill folders inside the bitcoin user's
OLD="/var/lib/bitcoind-before-import-$STAMP"
install -d -o root -g root -m 700 "$OLD"
for d in blocks chainstate indexes; do
    [[ -e "$DATA_DIR/$d" ]] && mv -- "$DATA_DIR/$d" "$OLD/"
done
say "📦 Moving the copy in..."
mv -- "$SRC/blocks" "$SRC/chainstate" "$DATA_DIR/"
chown -R -h bitcoin:bitcoin "$DATA_DIR/blocks" "$DATA_DIR/chainstate"
chmod -R u=rwX,go= "$DATA_DIR/blocks" "$DATA_DIR/chainstate"
rm -rf -- "$SRC"
say "✅ The copy is in %s; ~%s/chain-incoming is gone (Server A can't write here now)" "$DATA_DIR" "$SERVER_B_USER"

say "🚀 Starting bitcoind..."
systemctl start bitcoind
# As the bitcoin user: the RPC cookie is in its folder, and root shouldn't read files there
cli=(runuser -u bitcoin -- /usr/local/bin/bitcoin-cli -conf="$CONF" -datadir="$DATA_DIR")
info=""
for _ in $(seq 1 60); do
    info=$("${cli[@]}" getblockchaininfo 2>/dev/null) && break
    sleep 5
done
if [[ -n "$info" ]]; then
    python3 -I -c 'import json,sys; i=json.load(sys.stdin); print("   chain %s, blocks %s, headers %s, pruned %s" % (i["chain"], i["blocks"], i["headers"], i.get("pruned")))' <<< "$info"
    say "✅ bitcoind runs on the copy. It prunes it to this server's size and catches up from the network."
    say "   The old blocks are in %s; delete that folder once all is well: sudo rm -rf %s" "$OLD" "$OLD"
else
    say "⚠️ bitcoind doesn't answer yet. Look at /var/lib/bitcoind/debug.log, or journalctl -u bitcoind."
    say "   To go back: stop bitcoind, move %s/* back into %s, start it." "$OLD" "$DATA_DIR"
fi
