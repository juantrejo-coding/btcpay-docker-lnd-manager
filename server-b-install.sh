#!/bin/bash
set -euo pipefail
# Messages in the language Server A's config chose: setup sends i18n.sh, the language and these
# messages' translations ahead of this file, and serverb-user-setup.sh builds them in here
# (# @@ lines). The gate and the rotation below always answer in English: Server A reads them.
# @@INCLUDE i18n.sh
# @@I18N
# Run by hand, without them: English
if ! declare -F T >/dev/null; then
    T() { local format="$1"; shift; printf -- "$format" "$@"; }
    # shellcheck disable=SC2059
    say() { printf -- "$1" "${@:2}"; echo; }
fi

# Installs the backup gate on Server B. Run it on Server B as the user that holds the backups
# (SERVER_B_USER in config), not as root: sudo isn't needed.
#
#   ./server-b-install.sh /path/to/server-a-key.pub
#
# What it sets up, all in this user's home:
#   ~/.local/bin/lnd-backup-gate     The only thing Server A's key may run (forced command).
#                                    It allows: ping, list, get, and put of NEW backups.
#                                    No delete, no overwrite, no shell. put-setup stores
#                                    serverb.conf or serverb-install.sh in ~/serverb-setup
#                                    (never run here; you run them with sudo). put-status
#                                    stores Server A's LND state (data, for serverb-update).
#                                    And, only while
#                                    ~/chain-incoming exists, rsync into that folder alone
#                                    (Server A's pruned blockchain for this server's bitcoind).
#   ~/.local/bin/lnd-backup-rotate   Rotation, run by this user's cron every hour: keeps the 10
#                                    newest backups, makes the daily and monthly milestones
#                                    (30 and 12 kept), never deletes safety backups.
#   ~/.ssh/authorized_keys           Server A's key line gets restrict,command="...gate".
#                                    The old file is kept as authorized_keys.before-gate.
#
# Server A's scripts must use the gate's operations before this is installed: today they run
# shell commands on Server B (rsync, mkdir, ls/rm for rotation), which the gate refuses.
#
# The backups stay where they are: ~/encrypted_lnd_backups, with milestones/daily,
# milestones/monthly and pre-recovery inside.

KEY_FILE="${1:-}"
if [[ -z "$KEY_FILE" || ! -f "$KEY_FILE" ]]; then
    say "Usage: %s /path/to/server-a-key.pub" "$0" >&2
    exit 2
fi
if [[ $EUID -eq 0 ]]; then
    say "❌ Run this as the Server B backup user, not as root." >&2
    exit 1
fi

read -r KEY_TYPE KEY_BLOB _ < "$KEY_FILE"
if [[ ! "$KEY_TYPE" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))$ || ! "$KEY_BLOB" =~ ^[A-Za-z0-9+/=]+$ ]]; then
    say "❌ %s doesn't look like an SSH public key." "$KEY_FILE" >&2
    exit 1
fi

BIN="$HOME/.local/bin"
mkdir -p "$BIN" "$HOME/.local/state" "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
umask 077

# === The gate ===
cat > "$BIN/lnd-backup-gate.new" <<'GATE'
#!/bin/bash
# Server A's key may run only this (forced command in ~/.ssh/authorized_keys). It reads the
# command Server A asked for from SSH_ORIGINAL_COMMAND and allows:
#   ping                       answers "ok"
#   client-address             the address Server A connects from, as this server sees it
#   list <area>                the backup names in an area, one per line
#   get <area> <name>          a backup's contents
#   put <area> <name> [<sha256>]
#                              stores a NEW backup from stdin, prints its sha256; never
#                              overwrites, refuses names dated in the future. With the sha256
#                              (Server A sends it), an upload cut off on the way is refused
#                              instead of being kept as if complete. pre-recovery holds at most
#                              20 backups and 50 GiB.
#   put-setup <name>           stores Server B's settings or scripts from stdin in
#                              ~/serverb-setup, prints the sha256: serverb.conf or
#                              serverb-install.sh only, replacing the one there. Never run here:
#                              you run them yourself, with sudo (lnd-manager: /serverb send).
#   put-status                 Server A's LND state, every 5 minutes (server-a-status.sh), into
#                              ~/.local/state/server-a-status: serverb-update reads it before it
#                              restarts the watchtower. A few lines of data, checked here too.
# Areas: main, daily, monthly, pre-recovery (put: main and pre-recovery only; the milestones
# are made here by lnd-backup-rotate). Nothing is run through a shell.
# Also rsync into ~/chain-incoming, only while that folder exists (serverb-bitcoind-setup.sh makes
# it when you choose to copy Server A's blockchain, serverb-import-chain.sh removes it).
set -euo pipefail
umask 077
# sshd may pass on Server A's language settings; ranges like [a-z] must mean ASCII here
export LC_ALL=C

BASE="$HOME/encrypted_lnd_backups"
LOG="$HOME/.local/state/lnd-backup-gate.log"
LOG_MAX_BYTES=$((5 * 1024 * 1024))       # above this the gate stops logging (rotation trims it)
PRE_RECOVERY_MAX_FILES=20
PRE_RECOVERY_MAX_KB=$((50 * 1024 * 1024))
MAX_BYTES=$((20 * 1024 * 1024 * 1024))   # largest backup accepted (a whole LND volume fits)
RESERVE_KB=$((1024 * 1024))              # free space that must stay after a put
CHAIN_RESERVE_KB=$((5 * 1024 * 1024))    # free space a chain copy needs to start
TS='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}'

# One short line per event: a refused command is cut to 200 characters, and nothing is logged once
# the log is LOG_MAX_BYTES, so Server A can't fill this disk through it
log() {
    local msg="${*//[[:cntrl:]]/?}" size
    (( ${#msg} <= 200 )) || msg="${msg:0:200}..."
    size=$(stat -c %s -- "$LOG" 2>/dev/null || echo 0)
    (( size < LOG_MAX_BYTES )) || return 0
    printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$msg" >> "$LOG" 2>/dev/null || true
}

refuse() {
    log "refused: $*"
    echo "lnd-backup-gate: $*" >&2
    exit 2
}

area_dir() {
    case "$1" in
        main) echo "$BASE" ;;
        daily) echo "$BASE/milestones/daily" ;;
        monthly) echo "$BASE/milestones/monthly" ;;
        pre-recovery) echo "$BASE/pre-recovery" ;;
        *) refuse "unknown area: $1" ;;
    esac
}

name_ok() {
    local area="$1" name="$2"
    case "$area" in
        main) [[ "$name" =~ ^encrypted_backup_${TS}\.gpg$ ]] ;;
        pre-recovery) [[ "$name" =~ ^pre-recovery_${TS}\.gpg$ ]] ;;
        daily) [[ "$name" =~ ^backup_[0-9]{4}-[0-9]{2}-[0-9]{2}\.gpg$ ]] ;;
        monthly) [[ "$name" =~ ^backup_[0-9]{4}-[0-9]{2}\.gpg$ ]] ;;
        *) return 1 ;;
    esac
}

# Server A's pruned blockchain: rrsync (rsync's own restricted mode) keeps rsync inside
# ~/chain-incoming and write-only, so nothing can be read back and nothing outside it touched.
# Deleting inside it is allowed: the second pass removes files Server A has pruned meanwhile.
# -munge: links rsync creates there can't point anywhere real.
if [[ "${SSH_ORIGINAL_COMMAND:-}" == "rsync --server "* ]]; then
    CHAIN_DIR="$HOME/chain-incoming"
    [[ -d "$CHAIN_DIR" && ! -L "$CHAIN_DIR" ]] || refuse "chain copy not enabled here (no ~/chain-incoming)"
    RRSYNC=$(command -v rrsync 2>/dev/null) || refuse "rrsync is not installed (it comes with rsync 3.2.4 or later)"
    # rsync can't be capped from here, so at least don't start with the disk nearly full: the
    # backups need room too
    free=$(df --output=avail -k "$CHAIN_DIR" | tail -n 1)
    (( free > CHAIN_RESERVE_KB )) || refuse "chain copy: less than $(( CHAIN_RESERVE_KB / 1024 / 1024 )) GiB free on this server"
    log "chain copy into ~/chain-incoming"
    exec "$RRSYNC" -wo -munge "$CHAIN_DIR"
fi

read -r -a WORDS <<< "${SSH_ORIGINAL_COMMAND:-}"
(( ${#WORDS[@]} <= 4 )) || refuse "too many words: ${SSH_ORIGINAL_COMMAND:-}"
VERB="${WORDS[0]:-}"

case "$VERB" in
    ping)
        (( ${#WORDS[@]} == 1 )) || refuse "usage: ping"
        echo ok
        ;;
    client-address)
        (( ${#WORDS[@]} == 1 )) || refuse "usage: client-address"
        echo "${SSH_CONNECTION%% *}"
        ;;
    list)
        (( ${#WORDS[@]} == 2 )) || refuse "usage: list <area>"
        dir=$(area_dir "${WORDS[1]}")
        [[ -d "$dir" ]] || exit 0
        for f in "$dir"/*.gpg; do
            [[ -f "$f" && ! -L "$f" ]] || continue
            name="${f##*/}"
            if name_ok "${WORDS[1]}" "$name"; then
                echo "$name"
            fi
        done
        ;;
    get)
        (( ${#WORDS[@]} == 3 )) || refuse "usage: get <area> <name>"
        dir=$(area_dir "${WORDS[1]}")
        name_ok "${WORDS[1]}" "${WORDS[2]}" || refuse "bad name: ${WORDS[2]}"
        f="$dir/${WORDS[2]}"
        [[ -f "$f" && ! -L "$f" ]] || refuse "no such backup: ${WORDS[1]}/${WORDS[2]}"
        cat -- "$f"
        ;;
    put)
        (( ${#WORDS[@]} == 3 || ${#WORDS[@]} == 4 )) || refuse "usage: put <area> <name> [<sha256>]"
        area="${WORDS[1]}" name="${WORDS[2]}" want="${WORDS[3]:-}"
        [[ -z "$want" || "$want" =~ ^[0-9a-f]{64}$ ]] || refuse "bad sha256: $want"
        [[ "$area" == main || "$area" == pre-recovery ]] || refuse "put only into main or pre-recovery"
        name_ok "$area" "$name" || refuse "bad name: $name"
        stamp="${name%.gpg}"; stamp="${stamp#encrypted_backup_}"; stamp="${stamp#pre-recovery_}"
        epoch=$(date -d "$stamp" +%s 2>/dev/null) || refuse "bad time in name: $name"
        (( epoch <= $(date +%s) + 300 )) || refuse "name dated in the future: $name"
        dir=$(area_dir "$area")
        mkdir -p "$dir"
        # One upload at a time, so the free-space checks below can't be raced
        exec 8> "$HOME/.local/state/lnd-backup-gate-put.lock"
        flock 8
        final="$dir/$name"
        [[ -e "$final" || -L "$final" ]] && refuse "already exists, never overwritten: $area/$name"
        # Safety backups are never rotated: only so many of them
        if [[ "$area" == pre-recovery ]]; then
            count=0 used=0
            for f in "$dir"/pre-recovery_*.gpg; do
                [[ -f "$f" && ! -L "$f" ]] || continue
                count=$((count + 1))
                used=$((used + $(du -k -- "$f" | cut -f1)))
            done
            (( count < PRE_RECOVERY_MAX_FILES )) ||
                refuse "pre-recovery holds $PRE_RECOVERY_MAX_FILES safety backups already: delete old ones on Server B first"
            (( used < PRE_RECOVERY_MAX_KB )) ||
                refuse "pre-recovery holds $(( PRE_RECOVERY_MAX_KB / 1024 / 1024 )) GiB already: delete old ones on Server B first"
        fi
        # Never more than would leave RESERVE_KB free
        free=$(df --output=avail -k "$dir" | tail -n 1)
        (( free > RESERVE_KB )) || refuse "not enough free space for $area/$name"
        cap=$(( (free - RESERVE_KB) * 1024 ))
        (( cap < MAX_BYTES )) || cap=$MAX_BYTES
        tmp="$dir/.incoming-$name.$$"
        trap 'rm -f -- "$tmp"' EXIT
        head -c $((cap + 1)) > "$tmp"
        size=$(stat -c %s "$tmp")
        (( size > 0 )) || refuse "empty upload: $area/$name"
        (( size <= cap )) || refuse "too large, or not enough free space: $area/$name"
        # Cut off on the way (Server A's ssh was stopped): stdin just ended early
        if [[ -n "$want" && "$(sha256sum -- "$tmp" | cut -d' ' -f1)" != "$want" ]]; then
            refuse "incomplete upload (sha256 differs), not kept: $area/$name"
        fi
        sync -f "$tmp" 2>/dev/null || true
        # A hard link fails if the name exists: no overwrite, even when two puts race
        ln -- "$tmp" "$final" || refuse "already exists, never overwritten: $area/$name"
        rm -f -- "$tmp"
        trap - EXIT
        sha256sum -- "$final" | cut -d' ' -f1
        log "stored $area/$name ($size bytes)"
        ;;
    put-setup)
        (( ${#WORDS[@]} == 2 )) || refuse "usage: put-setup <name>"
        name="${WORDS[1]}"
        case "$name" in
            serverb.conf) max=$((64 * 1024)) ;;
            serverb-install.sh) max=$((16 * 1024 * 1024)) ;;
            *) refuse "put-setup: only serverb.conf or serverb-install.sh" ;;
        esac
        dir="$HOME/serverb-setup"
        [[ ! -L "$dir" ]] || refuse "put-setup: ~/serverb-setup is a symlink"
        mkdir -p "$dir"
        chmod 700 "$dir"
        tmp="$dir/.incoming-$name.$$"
        trap 'rm -f -- "$tmp"' EXIT
        head -c $((max + 1)) > "$tmp"
        size=$(stat -c %s "$tmp")
        (( size > 0 )) || refuse "empty upload: $name"
        (( size <= max )) || refuse "too large: $name"
        free=$(df --output=avail -k "$dir" | tail -n 1)
        (( free > RESERVE_KB )) || refuse "not enough free space left after $name"
        # A rename replaces the name itself, never a file a symlink there would point to
        mv -f -- "$tmp" "$dir/$name"
        trap - EXIT
        sha256sum -- "$dir/$name" | cut -d' ' -f1
        log "stored setup file $name ($size bytes)"
        ;;
    put-status)
        (( ${#WORDS[@]} == 1 )) || refuse "usage: put-status"
        dir="$HOME/.local/state"
        tmp="$dir/.incoming-server-a-status.$$"
        trap 'rm -f -- "$tmp"' EXIT
        head -c 1025 > "$tmp"
        (( $(stat -c %s "$tmp") <= 1024 )) || refuse "put-status: too large"
        # Only the lines server-a-status.sh writes
        if ! LC_ALL=C awk 'NR == 1 && $0 != "server-a-status 1" { bad = 1 }
                           NR > 1 && $0 !~ /^(lnd=[A-Z_]{1,40}|htlcs=-?[0-9]{1,9}|pending_channels=-?[0-9]{1,9})$/ { bad = 1 }
                           END { exit (bad || NR != 4) ? 1 : 0 }' "$tmp"; then
            refuse "put-status: not a status"
        fi
        mv -f -- "$tmp" "$dir/server-a-status"
        trap - EXIT
        echo ok
        ;;
    *)
        refuse "not allowed: ${SSH_ORIGINAL_COMMAND:-<interactive login>}"
        ;;
esac
GATE

# === Rotation ===
cat > "$BIN/lnd-backup-rotate.new" <<'ROTATE'
#!/bin/bash
# Run by this user's cron every hour. Rotation used to be done by Server A over SSH; with the
# gate, Server A can't delete anything here, so this does it.
#   - milestones: the first backup of each day and month, as hard links (no extra space)
#   - keeps the 10 newest backups, 30 daily and 12 monthly milestones
#   - never touches pre-recovery (safety backups are deleted by hand only)
#   - removes uploads that never finished (.incoming-*, older than a day)
set -euo pipefail
umask 077
# Wherever it was started from (find needs a folder it can return to)
cd "$HOME"
BASE="$HOME/encrypted_lnd_backups"
KEEP_MAIN=10 KEEP_DAILY=30 KEEP_MONTHLY=12
TS='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}'
exec 9> "$HOME/.local/state/lnd-backup-rotate.lock"
flock -n 9 || exit 0

mkdir -p "$BASE/milestones/daily" "$BASE/milestones/monthly"
shopt -s nullglob

# The backups in main as "<epoch> <name>", oldest first. By the real time in the name, not its
# text: names from Server A may carry any UTC offset, and its text would sort them wrongly.
mapfile -t backups < <(for f in "$BASE"/encrypted_backup_*.gpg; do
    n="${f##*/}"
    [[ -f "$f" && ! -L "$f" && "$n" =~ ^encrypted_backup_${TS}\.gpg$ ]] || continue
    stamp="${n#encrypted_backup_}"
    epoch=$(date -d "${stamp%.gpg}" +%s 2>/dev/null) || continue
    echo "$epoch $n"
done | sort -n)

# The first one of each day and month becomes its milestone. The day is the one in the name:
# lnd-wallet.sh checks a milestone's name against the time signed inside the backup.
for line in "${backups[@]}"; do
    n="${line#* }"
    day="${n:17:10}" month="${n:17:7}"
    [[ -e "$BASE/milestones/daily/backup_$day.gpg" ]] || ln -- "$BASE/$n" "$BASE/milestones/daily/backup_$day.gpg"
    [[ -e "$BASE/milestones/monthly/backup_$month.gpg" ]] || ln -- "$BASE/$n" "$BASE/milestones/monthly/backup_$month.gpg"
done

# main: the KEEP_MAIN newest by time
for line in "${backups[@]:0:$(( ${#backups[@]} > KEEP_MAIN ? ${#backups[@]} - KEEP_MAIN : 0 ))}"; do
    rm -f -- "$BASE/${line#* }"
done

keep_newest() {
    local dir="$1" keep="$2" pattern="$3" n
    mapfile -t files < <(for f in "$dir"/*.gpg; do
        n="${f##*/}"
        [[ -f "$f" && ! -L "$f" && "$n" =~ $pattern ]] && echo "$n"
    done | sort -r)
    for n in "${files[@]:keep}"; do
        rm -f -- "$dir/$n"
    done
}
keep_newest "$BASE/milestones/daily" "$KEEP_DAILY" '^backup_[0-9]{4}-[0-9]{2}-[0-9]{2}\.gpg$'
keep_newest "$BASE/milestones/monthly" "$KEEP_MONTHLY" '^backup_[0-9]{4}-[0-9]{2}\.gpg$'

find "$BASE" -maxdepth 2 -name '.incoming-*' -type f -mmin +1440 -delete

# The gate's log: the newest 1 MiB is kept
GATE_LOG="$HOME/.local/state/lnd-backup-gate.log"
if [[ -f "$GATE_LOG" && ! -L "$GATE_LOG" ]] && (( $(stat -c %s -- "$GATE_LOG") > 1024 * 1024 )); then
    tail -c $((1024 * 1024)) -- "$GATE_LOG" > "$GATE_LOG.new" && mv -f -- "$GATE_LOG.new" "$GATE_LOG"
fi
ROTATE

chmod 700 "$BIN/lnd-backup-gate.new" "$BIN/lnd-backup-rotate.new"
bash -n "$BIN/lnd-backup-gate.new" && bash -n "$BIN/lnd-backup-rotate.new"
mv -f "$BIN/lnd-backup-gate.new" "$BIN/lnd-backup-gate"
mv -f "$BIN/lnd-backup-rotate.new" "$BIN/lnd-backup-rotate"
say "✅ Installed %s/lnd-backup-gate and %s/lnd-backup-rotate" "$BIN" "$BIN"

# === Cron: rotation every hour ===
CRON_LINE="17 * * * * $BIN/lnd-backup-rotate"
if ! crontab -l 2>/dev/null | grep -qxF "$CRON_LINE"; then
    { crontab -l 2>/dev/null | grep -vF "$BIN/lnd-backup-rotate" || true; echo "$CRON_LINE"; } | crontab -
fi
say "✅ Rotation runs every hour (crontab -l shows it)"

# === Restrict Server A's key ===
AUTH="$HOME/.ssh/authorized_keys"
touch "$AUTH"
if [[ ! -f "$AUTH.before-gate" ]]; then
    cp -p "$AUTH" "$AUTH.before-gate"
fi
{
    # Every other line stays; any line with this key (restricted or not) is replaced
    grep -vF " $KEY_BLOB" "$AUTH" || true
    printf 'restrict,command="%s" %s %s lnd-backup-gate\n' "$BIN/lnd-backup-gate" "$KEY_TYPE" "$KEY_BLOB"
} > "$AUTH.new"
chmod 600 "$AUTH.new"
mv -f "$AUTH.new" "$AUTH"
say "✅ Server A's key may now only run the gate (old file: %s.before-gate)" "$AUTH"
echo
say "Check from Server A, as the backup user:"
say "  ssh -i <its key> %s@<this server> ping      -> ok" "$(id -un)"
say "  ssh -i <its key> %s@<this server> 'rm -rf ~' -> refused" "$(id -un)"
say "To undo: mv %s.before-gate %s, and remove the line from crontab -e." "$AUTH" "$AUTH"
