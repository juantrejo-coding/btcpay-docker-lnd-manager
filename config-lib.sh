#!/bin/bash
# Shared by setup_script.sh and serverb-scripts.sh, which source it: reading, asking for and saving
# settings in config. The script that sources it sets CONFIG_FILE and defines log_message.

# ----------------------------
# Settings that may need a prompt
# ----------------------------
# A setting that has a value in config is used as it is. An empty one is asked for here and
# saved in config, so rsync_gpg_backup.sh and the service still see it after this script ends.

# Writes NAME="value" into config and reloads it. Only that line changes, and the file is
# rewritten in place, so its owner, mode and ACLs stay.
save_config_value() {
    local name="$1" value="$2" new orig
    # config is bash that root reads: a value must stay a plain string between the quotes
    if [[ "$value" == *[\"\$\`\\]* || "$value" == *[[:cntrl:]]* ]]; then
        log_message "$(T "❌ %s can't hold \", \$, \`, \\ or control characters: %s" "$name" "$value")"
        return 1
    fi
    if [[ $(grep -c "^$name=" "$CONFIG_FILE") -ne 1 ]]; then
        log_message "$(T "❌ Expected exactly one %s= line in %s" "$name" "$CONFIG_FILE")"
        return 1
    fi
    new=$(mktemp) && orig=$(mktemp) || return 1
    cp "$CONFIG_FILE" "$orig"
    awk -v name="$name=" -v line="$name=\"$value\"" 'index($0, name) == 1 { print line; next } { print }' \
        "$CONFIG_FILE" > "$new"
    if ! cat "$new" > "$CONFIG_FILE"; then
        log_message "$(T "❌ Could not write %s (the original is saved in %s)" "$CONFIG_FILE" "$orig")"
        rm -f "$new"
        return 1
    fi
    rm -f "$new" "$orig"
    if ! source "$CONFIG_FILE" || [[ "${!name}" != "$value" ]]; then
        log_message "$(T "❌ Failed to reload %s with %s=\"%s\"" "$CONFIG_FILE" "$name" "$value")"
        return 1
    fi
    log_message "$(T "✅ Saved %s=\"%s\" in %s" "$name" "$value" "$CONFIG_FILE")"
}

# Stops unless an empty setting can be saved: needs exactly one NAME= line in config. Checked
# before asking, so nothing is created that config won't name.
require_prompt() {
    local name="$1"
    if [[ $(grep -c "^$name=" "$CONFIG_FILE") -ne 1 ]]; then
        log_message "$(T "❌ Expected exactly one %s= line in %s" "$name" "$CONFIG_FILE")"
        exit 1
    fi
}

# Asks with prompt $2 (text $4 prefilled) until check function $3 prints no problem.
# Sets ASKED_VALUE; the caller saves it.
ask_config_value() {
    local name="$1" prompt="$2" check="$3" answer="${4:-}" problem
    require_prompt "$name"
    while true; do
        if ! read -r -e -p "$prompt" -i "$answer" answer; then
            exit 1
        fi
        problem=$("$check" "$answer")
        if [[ -z "$problem" ]]; then
            ASKED_VALUE="$answer"
            return 0
        fi
        say "❌ Not allowed: %s" "$problem"
    done
}

# Checks a setting that config already has a value for; stops if it's not allowed
check_config_value() {
    local name="$1" check="$2" problem
    problem=$("$check" "${!name}")
    if [[ -n "$problem" ]]; then
        log_message "$(T "❌ %s in config is not allowed: %s" "$name" "$problem")"
        exit 1
    fi
}


# Prints why $1 can't be Server B's address (hostname, IPv4 or IPv6); nothing if it can
remote_server_problem() {
    if [[ ! "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.:-]{0,251}[A-Za-z0-9])?$ ]]; then
        say "enter a hostname or IP address (letters, digits, '.', ':' and '-', no user@ or spaces)"
    fi
}

# Prints why $1 can't be the user on Server B; nothing if it can
remote_user_problem() {
    # The same rule as serverb-user-setup.sh and adduser, which make this user on Server B
    if [[ ! "$1" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
        say "use up to 32 lowercase letters, digits, _ or -, starting with a letter"
    elif [[ "$1" == root || "$1" == bitcoin || "$1" == lndtower ]]; then
        say "use an account of its own on Server B, not root, bitcoin or lndtower"
    fi
}

# Prints why $1 can't be an SSH port; nothing if it can
ssh_port_problem() {
    if [[ ! "$1" =~ ^[0-9]{1,5}$ ]] || (( 10#$1 < 1 || 10#$1 > 65535 )); then
        say "enter a port number from 1 to 65535"
    fi
}

# === Settings added since this config was made ===
# config holds your answers, so a new version of the scripts doesn't replace it. What it lacks is
# added here: SERVER_B_USER takes REMOTE_USER's value (REMOTE_USER becomes an alias for it), and
# new settings are added at the end with their defaults. Each change is listed.
CONFIG_ADDITIONS=$(cat <<'ADDITIONS'
@@ SUPPORT_BTC_ADDRESS
# /support in both dashboards: the project's Bitcoin donation address (the one in README.md and
# LICENSE section 5) and the project's page (e.g. GitHub).
# Shown as text only; nothing is fetched. Empty shows a placeholder.
SUPPORT_BTC_ADDRESS="bc1qevxw36e4htzvlke3y0kqqz3qs0nfmreqhxkt73"
@@ SUPPORT_URL
SUPPORT_URL="https://github.com/juantrejo-coding/btcpay-docker-lnd-manager"
@@ SERVER_B_SCRIPTS_DIR
# Server B scripts (serverb-scripts.sh, lnd-manager: /serverb scripts). Empty ones are asked for.
# Where the scripts are made, to copy to Server B yourself
SERVER_B_SCRIPTS_DIR="${MAIN_USER_HOME}/serverb-scripts"
@@ SERVER_B_PRUNE_MB
# How much of the blockchain Server B's bitcoind keeps, in MB (2000 recommended, 550 minimum)
SERVER_B_PRUNE_MB=""
@@ SERVER_A_PUBLIC_IP
# This server's address as Server B sees it: Server B's firewall lets only it reach the tower
SERVER_A_PUBLIC_IP=""
@@ SERVER_B_ADMIN_USER
# The account on Server B that runs the Server B dashboard (made by serverb-dashboard-setup.sh)
SERVER_B_ADMIN_USER=""
@@ WATCHTOWER_PUBKEY
# Watchtower on Server B: its public key, filled in by /tower add
WATCHTOWER_PUBKEY=""
@@ WATCHTOWER_IP
WATCHTOWER_IP=""
@@ WATCHTOWER_PORT
WATCHTOWER_PORT="9911"
@@ UI_LANGUAGE
# Language of the scripts, the dashboards and the backup log: en (English), or any language
# with a translation in locale/ (es: Español). Left empty, setup asks.
UI_LANGUAGE=""
ADDITIONS
)
upgrade_config() {
    local new added=() name line block=""
    new=$(mktemp) || return 1
    cp "$CONFIG_FILE" "$new"
    if ! grep -q '^SERVER_B_USER=' "$new" && [[ $(grep -c '^REMOTE_USER=' "$new") -eq 1 ]]; then
        awk 'index($0, "REMOTE_USER=") == 1 {
                 print "# The user on Server B that holds the backups (Server A'"'"'s key reaches only this account)"
                 print "SERVER_B_USER=" substr($0, 13)
                 print "# REMOTE_USER is SERVER_B_USER'"'"'s older name, kept for older scripts. Set SERVER_B_USER, not this."
                 print "REMOTE_USER=\"$SERVER_B_USER\""
                 next
             } { print }' "$CONFIG_FILE" > "$new"
        added+=("SERVER_B_USER (from REMOTE_USER)")
    fi
    # The install folder's name before the rename to btcpay-docker-lnd-manager. install-scripts.sh
    # removes the old folder once the backup service no longer uses it.
    if grep -qx 'BACKUP_INSTALL_DIR="/usr/local/lib/btcpay-backup"' "$new"; then
        sed -i 's#^BACKUP_INSTALL_DIR="/usr/local/lib/btcpay-backup"$#BACKUP_INSTALL_DIR="/usr/local/lib/btcpay-docker-lnd-manager"#' "$new"
        added+=("BACKUP_INSTALL_DIR (now /usr/local/lib/btcpay-docker-lnd-manager)")
    fi
    # CONFIG_ADDITIONS: blocks that start with "@@ NAME"; a block is added when config has no NAME=
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "@@ "* ]]; then
            [[ -n "$block" ]] && printf '%s' "$block" >> "$new"
            name="${line#@@ }" block=""
            if grep -q "^$name=" "$new"; then
                name=""
            else
                block=$'\n'
                added+=("$name")
            fi
        elif [[ -n "$name" ]]; then
            block+="$line"$'\n'
        fi
    done <<< "$CONFIG_ADDITIONS"
    [[ -n "$block" ]] && printf '%s' "$block" >> "$new"
    if (( ${#added[@]} == 0 )); then
        rm -f "$new"
        return 0
    fi
    if ! bash -n "$new" || ! cat "$new" > "$CONFIG_FILE"; then
        log_message "$(T "❌ Could not add the new settings to %s" "$CONFIG_FILE")"
        rm -f "$new"
        return 1
    fi
    rm -f "$new"
    if ! source "$CONFIG_FILE"; then
        log_message "$(T "❌ Failed to reload %s after adding new settings" "$CONFIG_FILE")"
        return 1
    fi
    log_message "$(T "✅ Updated %s: %s" "$CONFIG_FILE" "${added[*]}")"
}
