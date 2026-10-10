# --- Runs the Server B scripts in order (serverb-steps.sh: sourced by serverb-setup.sh, built into
# serverb-install.sh). Each step says whether it looks done and asks before it runs. ---

# Root's folder for the scripts it runs: never in a folder another user can write to
SERVERB_SETUP_DIR=/var/lib/serverb-setup
# Which version of these scripts is set up, readable by the dashboard (serverb-update check)
SERVERB_VERSION_FILE=/var/lib/serverb-update/scripts-version
save_scripts_version() {
    echo "$1" > "$SERVERB_SETUP_DIR/VERSION"
    install -d -o root -g root -m 755 "${SERVERB_VERSION_FILE%/*}"
    echo "$1" > "$SERVERB_VERSION_FILE.new" && chmod 644 "$SERVERB_VERSION_FILE.new" &&
        mv -f "$SERVERB_VERSION_FILE.new" "$SERVERB_VERSION_FILE"
}

# A fresh, empty, root-only folder for the scripts, in $SCRIPTS_DIR
new_scripts_dir() {
    install -d -o root -g root -m 700 "$SERVERB_SETUP_DIR" || die "$(T "Could not make %s" "$SERVERB_SETUP_DIR")"
    [[ ! -L "$SERVERB_SETUP_DIR" && "$(stat -c %u -- "$SERVERB_SETUP_DIR")" == 0 ]] ||
        die "$(T "%s is not root's own folder" "$SERVERB_SETUP_DIR")"
    rm -rf -- "$SERVERB_SETUP_DIR/scripts"
    install -d -o root -g root -m 700 "$SERVERB_SETUP_DIR/scripts"
    SCRIPTS_DIR="$SERVERB_SETUP_DIR/scripts"
}

# The blockchain copy from Server A: "none" (not chosen), "waiting" (folder there, empty) or "ready"
chain_copy_state() {
    local home="$1"
    if ! runuser -u "$SERVER_B_USER" -- test -d "$home/chain-incoming" 2>/dev/null; then
        echo none
    elif [[ -z "$(runuser -u "$SERVER_B_USER" -- find "$home/chain-incoming" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        echo waiting
    else
        echo ready
    fi
}

# Runs the scripts in $SCRIPTS_DIR, in order. Returns 0 when all wanted steps ran.
run_steps() {
    local step script done_text answer home state
    local -a steps=(user bitcoind import tower dashboard)
    for step in "${steps[@]}"; do
        home=$(getent passwd "$SERVER_B_USER" | cut -d: -f6)
        done_text=""
        case "$step" in
            user)
                script=serverb-user-setup.sh
                say "Step 1 of 5: the backup user %s, Server A's key, the backup gate." "$SERVER_B_USER"
                [[ -n "$home" && -f "$home/.local/bin/lnd-backup-gate" ]] &&
                    done_text=$(T "done already; running it again updates the gate to this version")
                ;;
            bitcoind)
                script=serverb-bitcoind-setup.sh
                say "Step 2 of 5 (watchtower): a pruned Bitcoin Core."
                [[ -f /etc/systemd/system/bitcoind.service ]] && done_text=$(T "done already; running it again updates Bitcoin Core")
                ;;
            import)
                script=serverb-import-chain.sh
                state=none
                [[ -n "$home" ]] && state=$(chain_copy_state "$home")
                case "$state" in
                    none)
                        continue ;;
                    waiting)
                        echo
                        say "⏸️ Waiting for the blockchain from Server A. On Server A: lnd-manager /chain copy"
                        say "   (/chain prune first, if BTCPay's chain isn't pruned). When it has finished, run this"
                        say "   again: it goes on with the import, then the watchtower and the dashboard."
                        return 0 ;;
                esac
                say "Step 3 of 5 (watchtower): take over the blockchain Server A copied here."
                ;;
            tower)
                script=serverb-watchtower-setup.sh
                say "Step 4 of 5 (watchtower): LND as a watchtower for Server A's node."
                [[ -f /etc/systemd/system/lnd-watchtower.service ]] && done_text=$(T "done already")
                ;;
            dashboard)
                script=serverb-dashboard-setup.sh
                say "Step 5 of 5: the Server B dashboard and its admin account."
                [[ -x /usr/local/bin/serverb-dashboard ]] && done_text=$(T "done already; running it again updates the dashboard")
                ;;
        esac
        [[ -n "$done_text" ]] && say "   (%s)" "$done_text"
        [[ -f "$SCRIPTS_DIR/$script" ]] || die "$(T "%s is missing" "$SCRIPTS_DIR/$script")"
        read -r -p "$(T "Run %s? Type yes, or press Enter to skip it: " "$script")" answer || return 1
        if [[ "$answer" == yes ]]; then
            echo
            if ! bash "$SCRIPTS_DIR/$script"; then
                say "❌ %s failed. Fix what it says, then run this again: steps already done can be skipped." "$script"
                return 1
            fi
            echo
            if [[ "$step" == user ]]; then
                say "➡️ Next on Server A, if it isn't set up yet: lnd-manager /setup installs the backup gate."
            elif [[ "$step" == tower ]]; then
                say "➡️ Next on Server A: lnd-manager /tower add, with the tower's pubkey@address:port shown above."
            fi
        else
            say "   Skipped."
        fi
        echo
    done
    say "✅ Server B steps finished. The scripts that ran are kept in %s." "$SCRIPTS_DIR"
}
# --- end of serverb-steps.sh ---
