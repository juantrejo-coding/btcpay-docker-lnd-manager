# shellcheck shell=bash
# serverb-lib.sh: shared by serverb-scripts.sh (Server A) and serverb-setup.sh (Server B), which
# source it after i18n.sh and config-lib.sh. It makes the Server B scripts from the templates in
# serverb/ and reads and writes serverb.conf, the settings Server A sends to Server B.
# The script that sources it sets SCRIPT_DIR (the project folder) and fills in V (the settings).

TEMPLATES="$SCRIPT_DIR/serverb"
# The settings the templates use, in serverb.conf's order. SUPPORT_* may be empty.
SERVERB_SETTINGS=(SERVER_B_USER SERVER_A_KEY PRUNE_MB WATCHTOWER_ADDRESS WATCHTOWER_PORT SERVER_A_IP
                  SERVER_B_ADMIN_USER SUPPORT_BTC_ADDRESS SUPPORT_URL)
# The scripts made from the templates, in the order they run on Server B
SERVERB_SCRIPTS=(serverb-user-setup.sh serverb-bitcoind-setup.sh serverb-import-chain.sh
                 serverb-watchtower-setup.sh serverb-dashboard-setup.sh)
SERVERB_CONF_END="# end of serverb.conf"
# The line in a template's settings block that says where the values came from
RENDER_NOTE="${RENDER_NOTE:-}"

# === Checks for the settings ===
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
    local backup_user="${V[SERVER_B_USER]:-${SERVER_B_USER:-}}"
    if [[ ! "$1" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
        say "use up to 32 lowercase letters, digits, _ or -, starting with a letter"
    elif [[ "$1" == root || "$1" == bitcoin || "$1" == lndtower || "$1" == "$backup_user" ]]; then
        say "use an account of its own, not root, bitcoin, lndtower or SERVER_B_USER"
    fi
}
server_a_key_problem() {
    [[ "$1" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))\ [A-Za-z0-9+/=]+$ ]] ||
        say "not an SSH public key (type and key, nothing else)"
}
support_address_problem() {
    [[ "$1" =~ ^[A-Za-z0-9]{0,100}$ ]] || say "letters and digits only"
}
support_url_problem() {
    [[ -z "$1" || "$1" =~ ^https?://[A-Za-z0-9./:_~%?#=\&+@-]{1,300}$ ]] || say "an http:// or https:// address, without spaces or quotes"
}

# Prints why setting $1 can't have value $2; nothing if it can
serverb_setting_problem() {
    case "$1" in
        SERVER_B_USER) remote_user_problem "$2" ;;
        SERVER_A_KEY) server_a_key_problem "$2" ;;
        PRUNE_MB) prune_problem "$2" ;;
        WATCHTOWER_ADDRESS) remote_server_problem "$2" ;;
        WATCHTOWER_PORT) ssh_port_problem "$2" ;;
        SERVER_A_IP) ipv4_problem "$2" ;;
        SERVER_B_ADMIN_USER) admin_user_problem "$2" ;;
        SUPPORT_BTC_ADDRESS) support_address_problem "$2" ;;
        SUPPORT_URL) support_url_problem "$2" ;;
        *) say "unknown setting" ;;
    esac
}

# The sha256 of everything the scripts are made from, in language $1: Server B compares it with
# its own copy, so both make the same scripts
templates_sha256() {
    local lang="${1:-en}" files=()
    files=("$SCRIPT_DIR/i18n.sh" "$SCRIPT_DIR/server-b-install.sh" "$SCRIPT_DIR/update-lib.sh" "$SCRIPT_DIR/release-key.asc" "$TEMPLATES"/*)
    [[ "$lang" != en && -f "$SCRIPT_DIR/locale/$lang.cat" ]] && files+=("$SCRIPT_DIR/locale/$lang.cat")
    cat -- "${files[@]}" | sha256sum | cut -d' ' -f1
}

# === serverb.conf ===
# One NAME=value per line, the value as it is (no quotes): Server B reads it as data, never runs it.
write_serverb_conf() {
    local name
    say "# serverb.conf: the settings for the Server B scripts, made on Server A by serverb-scripts.sh, %s." "$(date '+%Y-%m-%d %H:%M')"
    say "# On Server B, serverb-setup.sh reads it as data (it is never run) and shows it before using it."
    echo "FORMAT=1"
    echo "SOURCE_VERSION=${V[SOURCE_VERSION]:-}"
    echo "TEMPLATES_SHA256=$(templates_sha256 "${UI_LANGUAGE:-en}")"
    echo "UI_LANGUAGE=${UI_LANGUAGE:-en}"
    for name in "${SERVERB_SETTINGS[@]}"; do
        echo "$name=${V[$name]:-}"
    done
    echo "$SERVERB_CONF_END"
}

# Reads serverb.conf from stdin into V (and UI_LANGUAGE, SOURCE_VERSION, TEMPLATES_SHA256 into V
# too). Every line is checked; on the first problem it says which line and returns 1.
read_serverb_conf() {
    local line name value problem n=0 ended=false
    local -A seen=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        (( n <= 100 && ${#line} <= 1000 )) || { say "❌ serverb.conf, line %s: too long, or too many lines" "$n" >&2; return 1; }
        line="${line%$'\r'}"
        [[ "$line" == "$SERVERB_CONF_END" ]] && { ended=true; break; }
        [[ -z "$line" || "$line" == "#"* ]] && continue
        if [[ "$line" == *[[:cntrl:]]* || ! "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
            say "❌ serverb.conf, line %s: not NAME=value" "$n" >&2
            return 1
        fi
        name="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"
        [[ -z "${seen[$name]:-}" ]] || { say "❌ serverb.conf, line %s: %s is there twice" "$n" "$name" >&2; return 1; }
        seen[$name]=1
        case "$name" in
            FORMAT) [[ "$value" == 1 ]] && problem="" || problem=$(T "made by a newer version of the scripts") ;;
            SOURCE_VERSION) [[ "$value" =~ ^[A-Za-z0-9._+-]{0,80}$ ]] && problem="" || problem=$(T "not a version") ;;
            TEMPLATES_SHA256) [[ "$value" =~ ^[0-9a-f]{64}$ ]] && problem="" || problem=$(T "not a sha256") ;;
            UI_LANGUAGE) [[ "$value" =~ ^[a-z]{2}$ ]] && problem="" || problem=$(T "not a language code") ;;
            *) problem=$(serverb_setting_problem "$name" "$value") ;;
        esac
        if [[ -n "$problem" ]]; then
            say "❌ serverb.conf, line %s: %s is not allowed: %s" "$n" "$name" "$problem" >&2
            return 1
        fi
        V[$name]="$value"
    done
    $ended || { say "❌ serverb.conf is incomplete: its last line, \"%s\", is missing" "$SERVERB_CONF_END" >&2; return 1; }
    for name in FORMAT TEMPLATES_SHA256 UI_LANGUAGE "${SERVERB_SETTINGS[@]}"; do
        if [[ -z "${seen[$name]:-}" ]] || [[ -z "${V[$name]}" && "$name" != SUPPORT_* ]]; then
            say "❌ serverb.conf has no value for %s" "$name" >&2
            return 1
        fi
    done
    # Checked again now that both are known
    problem=$(admin_user_problem "${V[SERVER_B_ADMIN_USER]}")
    [[ -z "$problem" ]] || { say "❌ serverb.conf: %s is not allowed: %s" SERVER_B_ADMIN_USER "$problem" >&2; return 1; }
}

# === Making the scripts ===
# Fills in a template: the settings between "# @@SETTINGS" and "# @@END-SETTINGS" get their
# values (quoted for bash), "# @@INCLUDE f" and "# @@EMBED f" are replaced by file f (an embedded
# file filled in the same way first, so its own INCLUDE lines are replaced too).
# Translations (i18n.sh), in UI_LANGUAGE:
#   "# @@I18N"           UI_LANGUAGE, and the translations of the messages in this template and
#                        its INCLUDEs, built in (read with i18n_read)
#   "# @@CATALOG f ..."  the catalog lines the messages of templates f ... use (for a here-
#                        document that installs them as a file)
# Server B scripts are single files, so they carry what they need.
catalog_for() {
    local cat="$SCRIPT_DIR/locale/${UI_LANGUAGE:-en}.cat"
    [[ "${UI_LANGUAGE:-en}" != en && -f "$cat" ]] || return 0
    python3 -I "$SCRIPT_DIR/tools/i18n.py" subset "$cat" "$@"
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
            printf '%s\n' "$RENDER_NOTE"
        elif [[ "$line" == "# @@END-SETTINGS" ]]; then
            in_settings=false
        elif $in_settings && [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)= ]]; then
            name="${BASH_REMATCH[1]}"
            if [[ -z "${V[$name]+set}" ]]; then
                say "❌ %s needs %s, which wasn't set" "$template" "$name" >&2
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

# Makes script $1 from its template into folder $2 (mode 600), checked with bash -n
make_serverb_script() {
    local name="$1" target="$2/$1"
    if ! render "$TEMPLATES/$name" > "$target.new" || ! bash -n "$target.new"; then
        rm -f "$target.new"
        say "❌ Could not make %s" "$name" >&2
        return 1
    fi
    chmod 600 "$target.new"
    mv -f "$target.new" "$target"
}
