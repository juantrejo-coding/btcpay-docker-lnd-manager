# shellcheck shell=bash
# update-lib.sh: updates of these scripts, shared by lnd-update.sh (Server A) and serverb-update
# (Server B, built in). Needs T and say (i18n.sh), and die.
#
# A release is a git tag vX.Y.Z of the project, signed with the release key below. Only the key
# file installed with the scripts counts (never one from the download), and the update never goes
# back to an older version. Two sources:
#   git  (now)    root's own bare clone (UPDATE_STATE/source.git), the tag checked, then exported
#   apt  (later)  the package from the project's APT repository; apt checks its signature. Used
#                 once the installed files belong to a package (dpkg -S); nothing uses it yet.
# Then the same steps for both: stage (download and check, now, while you watch), apply (when it
# is safe; waits up to UPDATE_WAIT_SECONDS, else at the next boot).

RELEASE_REPO_URL="https://github.com/juantrejo-coding/btcpay-docker-lnd-manager.git"
RELEASE_KEY_FINGERPRINT="93F4433DCE56353BD7E69D42CBFE4123CF4121FA"
UPDATE_WAIT_SECONDS=$((24 * 3600))
UPDATE_RETRY_SECONDS=300

# Tests only: a root-owned /etc/btcpay-lnd-update-test.conf may point at another repository and
# key (a VM can't sign with the real key). Ignored unless root owns it and only root can write it.
UPDATE_TEST_CONF=/etc/btcpay-lnd-update-test.conf
load_update_test_conf() {
    local line
    [[ -f "$UPDATE_TEST_CONF" && ! -L "$UPDATE_TEST_CONF" && "$(stat -c %u -- "$UPDATE_TEST_CONF")" == 0 ]] || return 0
    (( (8#$(stat -c %a -- "$UPDATE_TEST_CONF") & 8#022) == 0 )) || return 0
    while IFS= read -r line; do
        case "$line" in
            RELEASE_REPO_URL=/*) RELEASE_REPO_URL="${line#*=}" ;;
            RELEASE_KEY_FINGERPRINT=*) [[ "${line#*=}" =~ ^[0-9A-F]{40}$ ]] && RELEASE_KEY_FINGERPRINT="${line#*=}" ;;
            RELEASE_KEY_FILE=/*) RELEASE_KEY_FILE_OVERRIDE="${line#*=}" ;;
            UPDATE_WAIT_SECONDS=*) [[ "${line#*=}" =~ ^[0-9]+$ ]] && UPDATE_WAIT_SECONDS="${line#*=}" ;;
            UPDATE_RETRY_SECONDS=*) [[ "${line#*=}" =~ ^[0-9]+$ ]] && UPDATE_RETRY_SECONDS="${line#*=}" ;;
        esac
    done < "$UPDATE_TEST_CONF"
}
load_update_test_conf

# === Versions ===
# The release part of a version: v1.2.3 from v1.2.3, v1.2.3-4-gabcdef or 1.2.3-1 (a package);
# v0.0.0 when there is none (a clone without tags)
release_of() {
    if [[ "$1" =~ ^v?([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        echo "v${BASH_REMATCH[1]}"
    else
        echo v0.0.0
    fi
}
# True if release $2 is newer than release $1
release_newer() {
    local a b
    a=$(release_of "$1") b=$(release_of "$2")
    [[ "$a" != "$b" && "$(printf '%s\n' "${a#v}" "${b#v}" | sort -V | tail -n 1)" == "${b#v}" ]]
}

# How these scripts were installed: apt once a package owns file $1, else git
update_source() {
    if command -v dpkg-query >/dev/null && dpkg-query -S -- "$1" &>/dev/null; then
        echo apt
    else
        echo git
    fi
}

# The newest release tag in the repository, or nothing. Needs no root. Never a pre-release.
latest_release() {
    GIT_TERMINAL_PROMPT=0 timeout 60 git ls-remote --tags --refs "$RELEASE_REPO_URL" 'v*' 2>/dev/null |
        sed -n 's#^[0-9a-f]*[[:space:]]*refs/tags/\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$#\1#p' |
        sort -V | tail -n 1
}

# === git: stage a release ===
# Fetches tag $1 into root's bare clone $2/source.git, checks it, and exports it into $2/src.
# $3: the release key file installed with the scripts. Stops (die) if any check fails.
stage_release_git() {
    local tag="$1" state="$2" key="${RELEASE_KEY_FILE_OVERRIDE:-$3}" repo status name type gnupg
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$(T "Not a release tag: %s" "$tag")"
    [[ -f "$key" ]] || die "$(T "The release key %s is missing" "$key")"
    command -v git >/dev/null || die "$(T "git is not installed")"
    install -d -o root -g root -m 700 "$state"
    repo="$state/source.git"
    [[ -d "$repo" ]] || git init -q --bare "$repo" || die "$(T "Could not make %s" "$repo")"
    say "📥 Getting %s from %s..." "$tag" "$RELEASE_REPO_URL"
    GIT_TERMINAL_PROMPT=0 git -C "$repo" fetch -q --force --no-tags "$RELEASE_REPO_URL" "+refs/tags/$tag:refs/tags/$tag" ||
        die "$(T "Could not download %s" "$tag")"

    # The tag must be signed with the release key, and be the tag it says it is: an old signed tag
    # under a new name would otherwise bring back an old version
    type=$(git -C "$repo" cat-file -t "refs/tags/$tag" 2>/dev/null || true)
    [[ "$type" == tag ]] || die "$(T "%s is not a signed tag" "$tag")"
    name=$(git -C "$repo" cat-file -p "refs/tags/$tag" | sed -n 's/^tag //p' | head -n 1)
    [[ "$name" == "$tag" ]] || die "$(T "The tag %s calls itself %s: refused" "$tag" "$name")"
    gnupg=$(mktemp -d)
    gpg --homedir "$gnupg" --batch --quiet --import "$key" 2>/dev/null || { rm -rf -- "$gnupg"; die "$(T "Could not read the release key %s" "$key")"; }
    status=$(GNUPGHOME="$gnupg" git -C "$repo" -c gpg.program=gpg verify-tag --raw "refs/tags/$tag" 2>&1 || true)
    rm -rf -- "$gnupg"
    if ! awk -v fpr="$RELEASE_KEY_FINGERPRINT" '
            $1 == "[GNUPG:]" && $2 == "GOODSIG" { good = 1 }
            $1 == "[GNUPG:]" && $2 == "BADSIG" { bad = 1 }
            $1 == "[GNUPG:]" && $2 == "VALIDSIG" && good && $NF == fpr { ok = 1 }
            END { exit (ok && !bad) ? 0 : 1 }' <<< "$status"; then
        die "$(T "%s is not signed with the release key %s: nothing was changed" "$tag" "$RELEASE_KEY_FINGERPRINT")"
    fi
    say "✅ %s is signed with the release key %s" "$tag" "$RELEASE_KEY_FINGERPRINT"

    rm -rf -- "$state/src"
    install -d -o root -g root -m 700 "$state/src"
    git -C "$repo" archive "refs/tags/$tag" | tar -x -C "$state/src" --no-same-owner ||
        die "$(T "Could not unpack %s" "$tag")"
    echo "$tag" > "$state/src/.release"
}

# === apt: the same steps, for later ===
stage_release_apt() {
    local package="$1"
    say "📥 Getting the new %s package (apt checks its signature)..." "$package"
    apt-get update -q >/dev/null && apt-get install -y -q --download-only --only-upgrade "$package" >/dev/null ||
        die "$(T "Could not download the %s package" "$package")"
}
apply_release_apt() {
    local package="$1"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q --only-upgrade "$package" ||
        die "$(T "Could not install the %s package" "$package")"
}

# === Waiting until it is safe ===
# Runs check function $1 (it prints why it isn't safe, nothing when it is) every
# UPDATE_RETRY_SECONDS until it is safe (true) or the time is up: until second $2 (date +%s).
wait_until_safe() {
    local check="$1" deadline="$2" reason last="" left
    while :; do
        reason=$("$check")
        [[ -z "$reason" ]] && return 0
        if [[ "$reason" != "$last" ]]; then
            say "⏳ Not safe yet: %s" "$reason"
            last="$reason"
        fi
        left=$(( deadline - $(date +%s) ))
        (( left > 0 )) || return 1
        sleep "$(( left < UPDATE_RETRY_SECONDS ? left : UPDATE_RETRY_SECONDS ))"
    done
}

# Until when an update staged at second $1 may wait: UPDATE_WAIT_SECONDS later
wait_deadline() {
    local since="$1"
    [[ "$since" =~ ^[0-9]+$ ]] || since=$(date +%s)
    echo $(( since + UPDATE_WAIT_SECONDS ))
}

# Starts "$@" in the background as a systemd unit named $1, so it goes on after you log out
start_waiter() {
    local unit="$1"
    shift
    systemctl stop "$unit.service" 2>/dev/null || true
    systemctl reset-failed "$unit.service" 2>/dev/null || true
    systemd-run --quiet --unit="$unit" --collect --description="Waits until it is safe to update" "$@"
}
