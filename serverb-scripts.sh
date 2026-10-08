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
#   ./serverb-scripts.sh tower-client   (lnd-manager: /tower add) asks for the tower's public key
#   and address if config lacks them, installs config, then runs chain-tower.sh tower-add, which
#   turns on BTCPay's watchtower client and adds the tower.
#
# Settings they need that are empty in config are asked for and saved there. The scripts go into
# SERVER_B_SCRIPTS_DIR; copy them to Server B yourself and run them there with sudo. Server A's
# backup key can't put them there: Server B would then run with sudo whatever a compromised
# Server A had put there.

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

WHICH="${1:-all}"
case "$WHICH" in
    user | bitcoind | import | tower | dashboard | all | tower-client) ;;
    -h | --help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) say "❌ Unknown script: %s (user, bitcoind, import, tower, dashboard or all)" "$WHICH" >&2; exit 2 ;;
esac
wanted() {
    [[ "$WHICH" == all || "$WHICH" == "$1" ]]
}

# === Checks for the settings asked for here ===
prune_problem() {
    if [[ ! "$1" =~ ^[0-9]+$ ]] || (( 10#$1 < 550 )); then
        say "enter a size in MB, at least 550 (Bitcoin Core's minimum)"
    fi
}
ipv4_problem() {
    local IFS=. part
    if [[ ! "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ && ! "$1" =~ ^[0-9A-Fa-f:]{2,39}$ ]]; then
        say "enter an IPv4 or IPv6 address"
        return
    fi
    if [[ "$1" == *.* ]]; then
        for part in $1; do
            (( 10#$part <= 255 )) || { say "enter an IPv4 or IPv6 address"; return; }
        done
    fi
}
admin_user_problem() {
    if [[ ! "$1" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
        say "use up to 32 lowercase letters, digits, _ or -, starting with a letter"
    elif [[ "$1" == root || "$1" == bitcoin || "$1" == lndtower || "$1" == "${SERVER_B_USER:-}" ]]; then
        say "use an account of its own, not root, bitcoin, lndtower or SERVER_B_USER"
    fi
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

declare -A V=()
if wanted user || wanted bitcoind || wanted import || wanted dashboard; then
    if [[ -z "$SERVER_B_USER" ]]; then
        say "SERVER_B_USER is not set in config: the user on Server B that holds the backups."
    fi
    setting SERVER_B_USER "$(T "User on Server B: ")" remote_user_problem
    V[SERVER_B_USER]="$SERVER_B_USER"
fi
if wanted user; then
    if [[ -z "${SERVER_A_USER:-}" || -z "${KEY_FILENAME:-}" ]] || ! V[SERVER_A_KEY]=$(sudo cat -- "$PUB_KEY_FILE" 2>/dev/null) ||
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
if wanted tower; then
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

# Fills in a template: the settings between "# @@SETTINGS" and "# @@END-SETTINGS" get their
# values (quoted for bash), "# @@INCLUDE f" and "# @@EMBED f" are replaced by file f (an embedded
# file filled in the same way first, so its own INCLUDE lines are replaced too).
# Translations (i18n.sh), in config's UI_LANGUAGE:
#   "# @@I18N"           UI_LANGUAGE, and the translations of the messages in this template and
#                        its INCLUDEs, built in (read with i18n_read)
#   "# @@CATALOG f ..."  the catalog lines the messages of templates f ... use (for a here-
#                        document that installs them as a file)
# Server B scripts are single files copied over by hand, so they carry what they need.
catalog_for() {
    local cat="$SCRIPT_DIR/locale/${UI_LANGUAGE:-en}.cat"
    [[ "${UI_LANGUAGE:-en}" != en && -f "$cat" ]] || return 0
    python3 "$SCRIPT_DIR/tools/i18n.py" subset "$cat" "$@"
}
render() {
    local template="$1" line name in_settings=false file next content
    local -a lines sources names
    mapfile -t lines < "$template"
    local i
    # This template and the files it includes: their messages are the ones # @@I18N builds in
    sources=("$template")
    for line in "${lines[@]}"; do
        if [[ "$line" =~ ^#\ @@INCLUDE\ ([A-Za-z0-9._-]+)$ ]]; then
            file="$TEMPLATES/${BASH_REMATCH[1]}"
            [[ -f "$file" ]] || file="$SCRIPT_DIR/${BASH_REMATCH[1]}"
            sources+=("$file")
        fi
    done
    for (( i = 0; i < ${#lines[@]}; i++ )); do
        line="${lines[$i]}"
        if [[ "$line" == "# @@I18N" ]]; then
            printf 'UI_LANGUAGE=%q\n' "${UI_LANGUAGE:-en}"
            content=$(catalog_for "${sources[@]}") || return 1
            if [[ -n "$content" ]]; then
                printf '%s\n' "i18n_read <<'I18N_CATALOG_EOF'" "$content" "I18N_CATALOG_EOF"
            fi
        elif [[ "$line" =~ ^#\ @@CATALOG((\ [A-Za-z0-9._-]+)+)$ ]]; then
            read -r -a names <<< "${BASH_REMATCH[1]}"
            content=$(catalog_for "${names[@]/#/$TEMPLATES/}") || return 1
            [[ -n "$content" ]] && printf '%s\n' "$content"
        elif [[ "$line" == "# @@SETTINGS" ]]; then
            in_settings=true
            say "# Filled in on Server A by serverb-scripts.sh, %s" "$(date '+%Y-%m-%d %H:%M')"
        elif [[ "$line" == "# @@END-SETTINGS" ]]; then
            in_settings=false
        elif $in_settings && [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)= ]]; then
            name="${BASH_REMATCH[1]}"
            if [[ -z "${V[$name]+set}" ]]; then
                say "❌ %s needs %s, which serverb-scripts.sh didn't set" "$template" "$name" >&2
                return 1
            fi
            printf '%s=%q\n' "$name" "${V[$name]}"
        elif [[ "$line" =~ ^#\ @@(INCLUDE|EMBED)\ ([A-Za-z0-9._-]+)$ ]]; then
            file="$TEMPLATES/${BASH_REMATCH[2]}"
            [[ -f "$file" ]] || file="$SCRIPT_DIR/${BASH_REMATCH[2]}"
            [[ -f "$file" ]] || { say "❌ %s is missing" "${BASH_REMATCH[2]}" >&2; return 1; }
            if [[ "${BASH_REMATCH[1]}" == EMBED ]]; then
                name="${BASH_REMATCH[2]}"
                content=$(render "$file") || return 1
                # An embedded file must not hold the line that ends its here-document
                next="${lines[$((i + 1))]:-}"
                if grep -qxF -- "$next" <<< "$content"; then
                    say "❌ %s holds the line %s" "$name" "$next" >&2
                    return 1
                fi
                printf '%s\n' "$content"
            else
                cat -- "$file"
            fi
        else
            printf '%s\n' "$line"
        fi
    done
}

make_script() {
    local name="$1" target="$OUT/$1"
    if ! render "$TEMPLATES/$name" > "$target.new" || ! bash -n "$target.new"; then
        rm -f "$target.new"
        say "❌ Could not make %s" "$name"
        exit 1
    fi
    chmod 600 "$target.new"
    mv -f "$target.new" "$target"
    MADE+=("$name")
}

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
