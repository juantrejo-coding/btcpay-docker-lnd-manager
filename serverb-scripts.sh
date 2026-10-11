#!/bin/bash
# serverb-scripts.sh: makes the scripts you run on Server B, with your settings filled in.
# Run it on Server A, from your working folder, as yourself (lnd-manager: /serverb scripts):
#
#   ./serverb-scripts.sh [user|bitcoind|import|tower|dashboard|all]     (default: all)
#
#   serverb-user-setup.sh        the backup user SERVER_B_USER, with Server A's key restricted
#   serverb-bitcoind-setup.sh    a pruned Bitcoin Core (the watchtower's backend)
#   serverb-import-chain.sh      takes over the blockchain copied from Server A (/chain copy)
#   serverb-watchtower-setup.sh  LND as a watchtower for this node
#   serverb-dashboard-setup.sh   the Server B dashboard and its admin account
#
#   ./serverb-scripts.sh send   (lnd-manager: /serverb send) sends Server B its settings through
#   the backup gate (put-setup: into the backup user's ~/serverb-setup, nothing is run there):
#     1. serverb.conf only: on Server B, serverb-setup.sh from a git clone makes the scripts
#     2. serverb.conf and serverb-install.sh: all the scripts in one file, made here
#   Either way you run it on Server B yourself, with sudo. A gate older than put-setup refuses:
#   then serverb.conf is shown to paste into serverb-setup.sh --paste.
#
#   ./serverb-scripts.sh tower-client   (lnd-manager: /tower add) asks for the tower's public key
#   and address if config lacks them, installs config, then runs chain-tower.sh tower-add, which
#   turns on BTCPay's watchtower client and adds the tower.
#
# Settings they need that are empty in config are asked for and saved there. The scripts go into
# SERVER_B_SCRIPTS_DIR; copy them to Server B yourself and run them there with sudo. Server A's
# backup key never runs anything on Server B: root there runs only what you start yourself.

if ! SCRIPT_DIR=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")"); then
    echo "❌ Could not determine this script's folder"
    exit 1
fi
CONFIG_FILE="$SCRIPT_DIR/config"
TEMPLATES="$SCRIPT_DIR/serverb"
[[ -f "$CONFIG_FILE" ]] || { echo "❌ No config next to this script ($CONFIG_FILE)"; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG_FILE" || { echo "❌ Failed to load $CONFIG_FILE"; exit 1; }
if [[ ! -w "$CONFIG_FILE" ]]; then
    echo "❌ $CONFIG_FILE can't be edited by you. Run serverb-scripts.sh from your working folder" >&2
    echo "   (${BACKUP_SCRIPTS_FOLDER:-~/btcpay-docker-lnd-manager}), not from the installed copy." >&2
    exit 1
fi
[[ -d "$TEMPLATES" ]] || { echo "❌ $TEMPLATES is missing (it comes with the scripts)"; exit 1; }
if [[ ! -t 0 ]]; then
    echo "❌ serverb-scripts.sh needs a terminal: it may ask for settings." >&2
    exit 1
fi

log_message() {
    echo "$1"
}
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config-lib.sh" || { echo "❌ Failed to load $SCRIPT_DIR/config-lib.sh"; exit 1; }
# shellcheck disable=SC1091
source "$SCRIPT_DIR/i18n.sh" || { echo "❌ Failed to load $SCRIPT_DIR/i18n.sh"; exit 1; }
i18n_load
upgrade_config || exit 1
declare -A V=()
# shellcheck disable=SC1091
source "$SCRIPT_DIR/serverb-lib.sh" || { echo "❌ Failed to load $SCRIPT_DIR/serverb-lib.sh"; exit 1; }

WHICH="${1:-all}"
case "$WHICH" in
    user | bitcoind | import | tower | dashboard | all | tower-client | send) ;;
    -h | --help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) say "❌ Unknown script: %s (user, bitcoind, import, tower, dashboard, all or send)" "$WHICH" >&2; exit 2 ;;
esac
wanted() {
    [[ "$WHICH" == all || "$WHICH" == send || "$WHICH" == "$1" ]]
}

# Asks for $1 when config has no value for it (or only the placeholder $4), saves the answer
setting() {
    local name="$1" prompt="$2" check="$3" placeholder="${4:-}" suggested="${5:-}"
    local value="${!name:-}"
    if [[ -n "$value" && "$value" != "$placeholder" ]]; then
        check_config_value "$name" "$check"
        return
    fi
    ask_config_value "$name" "$prompt" "$check" "$suggested"
    save_config_value "$name" "$ASKED_VALUE" || exit 1
}

if wanted user || wanted bitcoind || wanted import || wanted dashboard; then
    if [[ -z "$SERVER_B_USER" ]]; then
        say "SERVER_B_USER is not set in config: the user on Server B that holds the backups."
    fi
    setting SERVER_B_USER "$(T "User on Server B: ")" remote_user_problem
    V[SERVER_B_USER]="$SERVER_B_USER"
fi
if wanted user; then
    if [[ -z "${SERVER_A_USER:-}" || -z "${KEY_FILENAME:-}" ]] || ! V[SERVER_A_KEY]=$(sudo -u "$SERVER_A_USER" cat -- "$PUB_KEY_FILE" 2>/dev/null) ||
       [[ "${V[SERVER_A_KEY]}" != ssh-* && "${V[SERVER_A_KEY]}" != ecdsa-* ]]; then
        say "❌ Server A's public key (%s) isn't there yet. Run setup first (lnd-manager: /setup):" "$PUB_KEY_FILE"
        say "   it makes the backup user and its key, then offers this script."
        exit 1
    fi
    V[SERVER_A_KEY]=$(head -n 1 <<< "${V[SERVER_A_KEY]}")
fi
if wanted bitcoind; then
    if [[ -z "${SERVER_B_PRUNE_MB:-}" ]]; then
        say "How much of the blockchain Server B keeps, in MB. 2000 (2 GB) is recommended: the watchtower"
        say "only needs recent blocks. 550 is Bitcoin Core's minimum."
    fi
    setting SERVER_B_PRUNE_MB "$(T "Prune size on Server B in MB [2000 recommended]: ")" prune_problem "" 2000
    V[PRUNE_MB]="$SERVER_B_PRUNE_MB"
fi
if wanted tower || wanted dashboard; then
    [[ -n "${WATCHTOWER_PORT:-}" ]] || WATCHTOWER_PORT=9911
    check_config_value WATCHTOWER_PORT ssh_port_problem
    if [[ -z "${WATCHTOWER_IP:-}" || "$WATCHTOWER_IP" == your-watchtower-ip ]]; then
        say "The address Server A's node uses to reach the watchtower on Server B (usually Server B's address)."
    fi
    setting WATCHTOWER_IP "$(T "Watchtower address (Server B): ")" remote_server_problem your-watchtower-ip "${REMOTE_SERVER:-}"
    V[WATCHTOWER_PORT]="$WATCHTOWER_PORT"
    V[WATCHTOWER_ADDRESS]="$WATCHTOWER_IP"
fi
# The tower's firewall rule lets only it in, and the Server B dashboard checks that rule
if wanted tower || wanted dashboard; then
    if [[ -z "${SERVER_A_PUBLIC_IP:-}" ]]; then
        say "Server A's address as Server B sees it: Server B's firewall lets only this address reach the tower."
    fi
    # Server B's gate tells which address Server A connects from. This server's own source
    # address is only a guess: behind NAT (many VPS) it is a private one.
    detected=""
    if [[ -z "${SERVER_A_PUBLIC_IP:-}" ]]; then
        detected=$(timeout 30 sudo -u "$SERVER_A_USER" -- "${SSH_COMMAND_ARR[0]}" -n -o BatchMode=yes \
                   "${SSH_COMMAND_ARR[@]:1}" client-address 2>/dev/null | head -n 1)
        if [[ -n "$detected" && -z "$(ipv4_problem "$detected")" ]]; then
            say "Server B sees Server A connect from %s." "$detected"
        else
            detected=$(ip -o route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | cut -d' ' -f2)
            say "⚠️ Server B's gate didn't say which address it sees (older gate, or not reachable). The suggestion"
            say "   below is this server's own address, which behind NAT is a private one: check it."
        fi
    fi
    setting SERVER_A_PUBLIC_IP "$(T "Server A's address: ")" ipv4_problem "" "$detected"
    V[SERVER_A_IP]="$SERVER_A_PUBLIC_IP"
fi
if wanted dashboard; then
    if [[ -z "${SERVER_B_ADMIN_USER:-}" ]]; then
        say "The Server B dashboard runs as an admin account of its own; serverb-dashboard-setup.sh makes it."
    fi
    setting SERVER_B_ADMIN_USER "$(T "Admin account for the Server B dashboard: ")" admin_user_problem "" lndadmin
    V[SERVER_B_ADMIN_USER]="$SERVER_B_ADMIN_USER"
    V[SUPPORT_BTC_ADDRESS]="${SUPPORT_BTC_ADDRESS:-}"
    V[SUPPORT_URL]="${SUPPORT_URL:-}"
fi

# === The tower for this node's LND ===
pubkey_problem() {
    [[ "$1" =~ ^0[23][0-9a-f]{64}$ ]] || say "enter the tower's public key: 66 hex characters, starting with 02 or 03"
}
if [[ "$WHICH" == tower-client ]]; then
    [[ -n "${WATCHTOWER_PORT:-}" ]] || WATCHTOWER_PORT=9911
    check_config_value WATCHTOWER_PORT ssh_port_problem
    if [[ -z "${WATCHTOWER_PUBKEY:-}" || "$WATCHTOWER_PUBKEY" == your-watchtower-public-key ]]; then
        say "The watchtower's public key: serverb-watchtower-setup.sh and the Server B dashboard show it"
        say "as <pubkey>@<address>:<port>. Type the part before the @."
    fi
    setting WATCHTOWER_PUBKEY "$(T "Watchtower public key: ")" pubkey_problem your-watchtower-public-key
    setting WATCHTOWER_IP "$(T "Watchtower address (Server B): ")" remote_server_problem your-watchtower-ip "${REMOTE_SERVER:-}"
    say "Tower: %s@%s:%s" "$WATCHTOWER_PUBKEY" "$WATCHTOWER_IP" "$WATCHTOWER_PORT"
    # Root runs only the installed copy of config
    sudo "$SCRIPT_DIR/install-scripts.sh" >/dev/null || { say "❌ install-scripts.sh failed"; exit 1; }
    exec sudo "${BACKUP_INSTALL_DIR:-/usr/local/lib/btcpay-docker-lnd-manager}/chain-tower.sh" tower-add
fi

# === Making them ===
OUT="${SERVER_B_SCRIPTS_DIR:-$HOME/serverb-scripts}"
if [[ -L "$OUT" ]]; then
    say "❌ %s is a symlink; set SERVER_B_SCRIPTS_DIR to a folder of yours" "$OUT"
    exit 1
fi
install -d -m 700 "$OUT" || exit 1

RENDER_NOTE=$(T "# Filled in on Server A by serverb-scripts.sh, %s" "$(date '+%Y-%m-%d %H:%M')")
make_script() {
    make_serverb_script "$1" "$OUT" || exit 1
    MADE+=("$1")
}

# === Sending them to Server B (send) ===
# Stores file $2 as $1 in the backup user's ~/serverb-setup through the gate; prints the sha256
# the gate answers
gate_put_setup() {
    timeout 300 sudo -u "$SERVER_A_USER" -- "${SSH_COMMAND_ARR[0]}" -o BatchMode=yes \
        "${SSH_COMMAND_ARR[@]:1}" put-setup "$1" < "$2"
}
show_conf_to_paste() {
    say "To paste it instead: on Server B, in a git clone of the project, run sudo ./serverb-setup.sh --paste"
    say "and paste these lines:"
    echo
    cat -- "$OUT/serverb.conf"
    echo
}
if [[ "$WHICH" == send ]]; then
    # Only the key itself: Server B checks it is nothing more
    read -r key_type key_blob _ <<< "${V[SERVER_A_KEY]}"
    V[SERVER_A_KEY]="$key_type $key_blob"
    V[SOURCE_VERSION]=$(git -C "$SCRIPT_DIR" describe --tags --always --dirty 2>/dev/null || true)
    [[ "${V[SOURCE_VERSION]}" =~ ^[A-Za-z0-9._+-]{1,80}$ ]] || V[SOURCE_VERSION]=""
    echo
    say "What to send to Server B (into %s's ~/serverb-setup; nothing is run there):" "$SERVER_B_USER"
    say "   1. serverb.conf only. On Server B you get the scripts with git clone and check their"
    say "      signature yourself, so root there runs only code you checked (recommended)."
    say "   2. serverb.conf and serverb-install.sh, all the scripts made here, in one file. For a Server B"
    say "      without GitHub. As safe as copying them by hand: root there runs what this server made."
    while :; do
        read -r -p "$(T "Choose 1 or 2: ")" choice || exit 1
        [[ "$choice" == 1 || "$choice" == 2 ]] && break
    done
    write_serverb_conf > "$OUT/serverb.conf.new" && chmod 600 "$OUT/serverb.conf.new" &&
        mv -f "$OUT/serverb.conf.new" "$OUT/serverb.conf" || { say "❌ Could not write %s" "$OUT/serverb.conf"; exit 1; }
    SEND=(serverb.conf)
    if [[ "$choice" == 2 ]]; then
        make_script serverb-install.sh
        SEND+=(serverb-install.sh)
    fi
    echo
    for f in "${SEND[@]}"; do
        local_sum=$(sha256sum -- "$OUT/$f" | cut -d' ' -f1)
        rc=0
        answer=$(gate_put_setup "$f" "$OUT/$f" 2> "$OUT/.send-error") || rc=$?
        error=$(LC_ALL=C tr -d '\000-\010\013-\037\177' < "$OUT/.send-error" | head -n 3)
        rm -f -- "$OUT/.send-error"
        if (( rc != 0 )); then
            say "❌ Sending %s failed: %s" "$f" "$error"
            if [[ "$error" == *"not allowed: put-setup"* ]]; then
                say "   Server B's backup gate is older than /serverb send. Step 1 on Server B updates it."
            fi
            show_conf_to_paste
            exit 1
        fi
        if [[ "$answer" != "$local_sum" ]]; then
            say "❌ Server B stored %s with another sha256 (%s, here %s): send it again" "$f" "${answer//[^0-9a-f]/}" "$local_sum"
            exit 1
        fi
        say "✅ Sent %s, sha256 %s" "$f" "$local_sum"
    done
    echo
    say "On Server B, as your admin account (the one with sudo):"
    if [[ "$choice" == 1 ]]; then
        say "   git clone https://github.com/juantrejo-coding/btcpay-docker-lnd-manager.git"
        say "   cd btcpay-docker-lnd-manager    then check the signature (README.md, \"Check what you download\")"
        say "   sudo ./serverb-setup.sh %s" "$SERVER_B_USER"
    else
        say "   sudo -u %s cat ~%s/serverb-setup/serverb-install.sh > serverb-install.sh" "$SERVER_B_USER" "$SERVER_B_USER"
        say "   sha256sum serverb-install.sh     must be %s" "$(sha256sum -- "$OUT/serverb-install.sh" | cut -d' ' -f1)"
        say "   sudo bash serverb-install.sh"
    fi
    say "It shows the settings, then goes through the steps, asking before each. Run it again after"
    say "lnd-manager /chain copy (if you chose to copy the blockchain) to go on with the import."
    exit 0
fi

MADE=()
wanted user && make_script serverb-user-setup.sh
wanted bitcoind && make_script serverb-bitcoind-setup.sh
wanted import && make_script serverb-import-chain.sh
wanted tower && make_script serverb-watchtower-setup.sh
wanted dashboard && make_script serverb-dashboard-setup.sh

echo
say "✅ Made in %s:" "$OUT"
(cd "$OUT" && sha256sum -- "${MADE[@]}") | sed 's/^/   /'
echo
say "Copy them to Server B yourself, from a computer you trust (not with Server A's backup key):"
say "   scp %s@<this server>:%s/serverb-*.sh ." "${MAIN_USER:-you}" "$OUT"
say "   scp serverb-*.sh <your account>@%s:" "${REMOTE_SERVER:-<Server B>}"
say "On Server B, check them against the sha256 sums above (sha256sum serverb-*.sh). That shows the"
say "copy is the one made here, not that this server is sound: before running one with sudo, glance at"
say "its \"Filled in on Server A\" settings at the top. Then run each with sudo bash, in this order:"
say "   1. serverb-user-setup.sh        then on Server A: lnd-manager /setup (it installs the backup gate)"
say "   Watchtower (optional):"
say "   2. serverb-bitcoind-setup.sh"
say "   3. on Server A: lnd-manager /chain prune (if BTCPay's chain isn't pruned), then /chain copy"
say "   4. serverb-import-chain.sh      (skip 3 and 4 to let Server B sync from the network: slower)"
say "   5. serverb-watchtower-setup.sh  note the tower's pubkey@address:port it shows"
say "   6. on Server A: lnd-manager /tower add"
say "   7. serverb-dashboard-setup.sh"
