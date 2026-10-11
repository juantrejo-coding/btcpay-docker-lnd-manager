# --- Common to the Server B scripts (serverb-common.sh, copied in by serverb-scripts.sh) ---
set -euo pipefail
umask 022

die() {
    echo "❌ $*" >&2
    exit 1
}

# Every Server B script changes the system, so it runs as root, in a terminal, with the
# settings Server A filled in. SERVERB_UPDATE=1 (serverb-update, through serverb-setup.sh
# --update): no terminal; only what was set up before is updated, nothing new is asked for.
need_root() {
    [[ $EUID -eq 0 ]] || die "$(T "Run it with sudo: sudo bash %s" "$0")"
    [[ -t 0 || "${SERVERB_UPDATE:-}" == 1 ]] || die "$(T "Run it in a terminal: it asks before it changes things.")"
}
updating() {
    [[ "${SERVERB_UPDATE:-}" == 1 ]]
}
need_settings() {
    local v
    for v in "$@"; do
        [[ -n "${!v:-}" ]] || die "$(T "%s is empty. Make this script on Server A (lnd-manager: /serverb scripts) and copy it here." "$v")"
    done
}

# Asks for an exact phrase. Usage: confirm_phrase <phrase> <prompt>
confirm_phrase() {
    local answer
    read -r -p "$2" answer || return 1
    [[ "$answer" == "$1" ]]
}

# Installs the Debian/Ubuntu packages that are missing
apt_install() {
    local missing=() p
    for p in "$@"; do
        dpkg -s "$p" &>/dev/null || missing+=("$p")
    done
    (( ${#missing[@]} == 0 )) && return 0
    say "📦 Installing %s..." "${missing[*]}"
    # NEEDRESTART_SUSPEND: Ubuntu's needrestart would otherwise restart services (bitcoind, the
    # tower) by itself, without the checks serverb-update makes first
    apt-get update -q >/dev/null &&
        NEEDRESTART_SUSPEND=1 DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}" >/dev/null ||
        die "$(T "Could not install %s" "${missing[*]}")"
}

# Downloads $1 to $2 over HTTPS only. A download cut off partway (bitcoincore.org does that with
# large files) goes on where it stopped, up to 10 tries; HTTP errors such as 404 aren't retried.
fetch() {
    local try rc err
    rm -f -- "$2"
    for try in 1 2 3 4 5 6 7 8 9 10; do
        rc=0
        err=$(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 -C - -o "$2" -- "$1" 2>&1) || rc=$?
        case $rc in
            0) return 0 ;;
            22) break ;;
            # The server can't resume: start over
            33) rm -f -- "$2" ;;
        esac
        (( try < 10 )) && say "   download interrupted (curl %s), going on (try %s of 10)..." "$rc" "$((try + 1))" >&2
        sleep 2
    done
    echo "$err" >&2
    return 1
}

# A system account for a service: no password, no login shell, home = its data folder
system_user() {
    local name="$1" home="$2"
    if ! id "$name" &>/dev/null; then
        useradd --system --user-group --home-dir "$home" --no-create-home --shell /usr/sbin/nologin "$name" ||
            die "$(T "Could not create the system user %s" "$name")"
        say "✅ System user %s created" "$name"
    fi
    install -d -o "$name" -g "$name" -m 750 "$home"
}

# Machine name for downloads: x86_64, aarch64 or armv7 (32-bit ARM, e.g. Raspberry Pi OS 32-bit).
# The programs' width decides, not the kernel's: a Raspberry Pi can run a 64-bit kernel with
# 32-bit programs, and then only 32-bit downloads run.
machine_arch() {
    local bits
    bits=$(getconf LONG_BIT 2>/dev/null || echo 64)
    case "$(uname -m)" in
        x86_64 | amd64) echo x86_64 ;;
        aarch64 | arm64) [[ "$bits" == 32 ]] && echo armv7 || echo aarch64 ;;
        armv7l | armv7 | armv8l) echo armv7 ;;
        *) die "$(T "Unsupported CPU: %s (x86_64, aarch64 and 32-bit ARM, armv7, are supported)" "$(uname -m)")" ;;
    esac
}

# Primary key fingerprints of the good signatures in gpg's status output (stdin), one per line.
# Only a signature gpg calls GOODSIG counts: VALIDSIG comes for expired and revoked keys too
# (EXPKEYSIG, REVKEYSIG). Each signature starts with NEWSIG; its VALIDSIG holds the fingerprint.
valid_signers() {
    awk '$1 != "[GNUPG:]" { next }
         $2 == "NEWSIG" { good = 0 }
         $2 == "GOODSIG" { good = 1 }
         $2 == "VALIDSIG" && good { print $NF; good = 0 }' | sort -u
}

# Text from programs and the network, without control characters
show_lines() {
    LC_ALL=C tr -d '\000-\010\013-\037\177' | sed 's/^/    /'
}
# --- end of serverb-common.sh ---
