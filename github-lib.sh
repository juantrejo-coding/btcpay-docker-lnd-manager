# shellcheck shell=bash
# github-lib.sh: the GitHub destination. The backups go to a private repository of yours
# (GITHUB_REPO, owner/name), written with a deploy key: an SSH key that reaches only that one
# repository (GitHub: the repository's Settings -> Deploy keys, write access allowed). No GitHub
# password or account token is on the server.
#
# Sourced by the backup service (which runs as the backup user) and, as that user too, by
# lnd-wallet.sh and setup (sudo -u). Needs T, say and log_message, and config.
#
# The repository holds the backups only, in the same layout as Server B:
#   main/            the 10 newest backups
#   daily/, monthly/ the first backup of each day (30) and month (12)
#   pre-recovery/    lnd-wallet.sh's safety backups (at most 20; never deleted here)
# It keeps only the current backups: every upload is one new commit, with no history, pushed
# with --force, so the backups rotated out are really gone and the repository stays small.
# A free private repository can't be protected against that push, so whoever has the deploy key
# (a broken-into Server A) could also delete everything there. Server B's gate prevents that on
# Server B: GitHub is an extra copy, not a replacement for Server B.

# github.com's SSH host key, so the key never goes to a server pretending to be GitHub. The same
# in GitHub's own list (api.github.com/meta) and from github.com itself (ssh-keyscan), 2026-10-12:
# SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU
GITHUB_HOST_KEY="github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
# GitHub refuses files over 100 MiB
GITHUB_MAX_BYTES=$((95 * 1024 * 1024))
GITHUB_KEEP_MAIN=10 GITHUB_KEEP_DAILY=30 GITHUB_KEEP_MONTHLY=12 GITHUB_MAX_PRE_RECOVERY=20
GITHUB_TS='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}'

# Prints why $1 can't be GITHUB_REPO; nothing if it can
github_repo_problem() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$ && "$1" != */. && "$1" != */.. ]] ||
        say "enter the repository as owner/name, for example juan/lnd-backups"
}

# Where the backup user's GitHub files are (that user's home, ~/.ssh)
github_key_path() {
    echo "${SERVER_A_USER_HOME:-$HOME}/.ssh/${GITHUB_KEY_FILENAME:-lnd_backup_github_key}"
}
github_known_hosts() {
    echo "${SERVER_A_USER_HOME:-$HOME}/.ssh/known_hosts_github"
}

# The repository's address. Tests only: a root-owned /etc/btcpay-lnd-github-test.conf may give
# another one (a VM can't use your GitHub account).
github_url() {
    local test=/etc/btcpay-lnd-github-test.conf line
    if [[ -f "$test" && ! -L "$test" && "$(stat -c %u -- "$test")" == 0 ]] &&
       (( (8#$(stat -c %a -- "$test") & 8#022) == 0 )); then
        while IFS= read -r line; do
            [[ "$line" == GITHUB_TEST_URL=* ]] && { echo "${line#*=}"; return; }
        done < "$test"
    fi
    echo "git@github.com:${GITHUB_REPO}.git"
}

# git with the deploy key only (IdentitiesOnly), github.com's pinned host key, never a prompt.
# Run as the backup user.
github_git() {
    local ssh
    ssh=$(printf '%q ' ssh -i "$(github_key_path)" -o IdentitiesOnly=yes -o BatchMode=yes \
          -o ConnectTimeout=20 -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$(github_known_hosts)")
    GIT_SSH_COMMAND="$ssh" GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 \
        GIT_AUTHOR_NAME=lnd-backup GIT_AUTHOR_EMAIL=lnd-backup@localhost \
        GIT_COMMITTER_NAME=lnd-backup GIT_COMMITTER_EMAIL=lnd-backup@localhost \
        timeout 600 git "$@"
}

# True if the deploy key may write: a dry-run push of a throwaway commit (GitHub refuses a read-only
# deploy key as soon as a push connects). Nothing is written to the repository.
github_git_push_test() {
    local dir rc=0
    dir=$(mktemp -d) || return 1
    git init -q "$dir" &&
        GIT_AUTHOR_NAME=lnd-backup GIT_AUTHOR_EMAIL=lnd-backup@localhost GIT_COMMITTER_NAME=lnd-backup \
        GIT_COMMITTER_EMAIL=lnd-backup@localhost git -C "$dir" commit -q --allow-empty -m "write test" &&
        github_git -C "$dir" push -q --dry-run "$(github_url)" HEAD:refs/heads/lnd-backup-write-test 2>/dev/null || rc=1
    rm -rf -- "$dir"
    return "$rc"
}

# The commit the repository's main branch points to, or nothing (empty repository)
github_remote_head() {
    github_git ls-remote "$(github_url)" refs/heads/main | cut -f1
}

# The working copy of what is on GitHub, in the backup user's metadata folder. It is the truth
# for each upload: if GitHub has something else (a first run on a new server, or a change made
# by hand), GitHub's is taken first, so no backup there is lost.
GITHUB_WORK="${BACKUP_METADATA_FOLDER:-$HOME/backup_metadata_folder}/github"
github_sync_work() {
    local remote local_head
    if [[ ! -d "$GITHUB_WORK/.git" ]]; then
        rm -rf -- "$GITHUB_WORK"
        git init -q -b main "$GITHUB_WORK" || return 1
    fi
    remote=$(github_remote_head) || return 1
    local_head=$(git -C "$GITHUB_WORK" rev-parse -q --verify HEAD 2>/dev/null || true)
    if [[ -n "$remote" && "$remote" != "$local_head" ]]; then
        github_git -C "$GITHUB_WORK" fetch -q --depth 1 "$(github_url)" main || return 1
        git -C "$GITHUB_WORK" reset -q --hard FETCH_HEAD || return 1
    fi
    mkdir -p "$GITHUB_WORK/main" "$GITHUB_WORK/daily" "$GITHUB_WORK/monthly" "$GITHUB_WORK/pre-recovery"
}

# Adds backup file $1 to area $2 (main or pre-recovery), makes the milestones, rotates, and pushes
# the result as one commit. Verified: GitHub's main branch then points to exactly that commit, which
# holds every file by its hash. Returns 1 (with a message) if anything fails.
github_store() {
    local file="$1" area="$2" name size dest day month n stamp epoch commit tree remote f kind
    local -a sorted
    name=$(basename -- "$file")
    size=$(stat -c %s -- "$file") || return 1
    if (( size > GITHUB_MAX_BYTES )); then
        log_message "$(T "❌ %s is %s MB: GitHub takes files up to 100 MB, so it isn't stored there" "$name" "$(( size / 1024 / 1024 ))")"
        return 1
    fi
    github_sync_work || { log_message "$(T "❌ Could not reach the GitHub repository %s with its deploy key" "${GITHUB_REPO:-?}")"; return 1; }
    dest="$GITHUB_WORK/$area/$name"
    if [[ "$area" == pre-recovery ]]; then
        n=$(find "$GITHUB_WORK/pre-recovery" -maxdepth 1 -name 'pre-recovery_*.gpg' | wc -l)
        if [[ ! -e "$dest" ]] && (( n >= GITHUB_MAX_PRE_RECOVERY )); then
            log_message "$(T "❌ The GitHub repository holds %s safety backups already: delete old ones there first" "$GITHUB_MAX_PRE_RECOVERY")"
            return 1
        fi
    fi
    cp -- "$file" "$dest.tmp" && mv -f -- "$dest.tmp" "$dest" || return 1

    if [[ "$area" == main ]]; then
        # Milestones: the day and month in the name (lnd-wallet.sh checks them against the signed
        # time inside)
        day="${name:17:10}" month="${name:17:7}"
        [[ -e "$GITHUB_WORK/daily/backup_$day.gpg" ]] || cp -- "$dest" "$GITHUB_WORK/daily/backup_$day.gpg"
        [[ -e "$GITHUB_WORK/monthly/backup_$month.gpg" ]] || cp -- "$dest" "$GITHUB_WORK/monthly/backup_$month.gpg"
        # main: the newest by their real time
        sorted=()
        for f in "$GITHUB_WORK"/main/encrypted_backup_*.gpg; do
            [[ -f "$f" && "${f##*/}" =~ ^encrypted_backup_${GITHUB_TS}\.gpg$ ]] || continue
            stamp="${f##*/encrypted_backup_}"
            epoch=$(date -d "${stamp%.gpg}" +%s 2>/dev/null) || continue
            sorted+=("$epoch $f")
        done
        mapfile -t sorted < <(printf '%s\n' "${sorted[@]}" | sort -k1,1nr | cut -d' ' -f2-)
        for f in "${sorted[@]:GITHUB_KEEP_MAIN}"; do
            [[ -n "$f" && "$f" != "$dest" ]] && rm -f -- "$f"
        done
        for kind in daily:$GITHUB_KEEP_DAILY monthly:$GITHUB_KEEP_MONTHLY; do
            mapfile -t sorted < <(find "$GITHUB_WORK/${kind%%:*}" -maxdepth 1 -name 'backup_*.gpg' -printf '%f\n' | sort -r)
            for f in "${sorted[@]:${kind#*:}}"; do
                [[ -n "$f" ]] && rm -f -- "$GITHUB_WORK/${kind%%:*}/$f"
            done
        done
    fi

    # One commit with no parent: what is on GitHub is exactly the current backups
    git -C "$GITHUB_WORK" add -A || return 1
    tree=$(git -C "$GITHUB_WORK" write-tree) || return 1
    commit=$(GIT_AUTHOR_NAME=lnd-backup GIT_AUTHOR_EMAIL=lnd-backup@localhost GIT_COMMITTER_NAME=lnd-backup \
             GIT_COMMITTER_EMAIL=lnd-backup@localhost git -C "$GITHUB_WORK" commit-tree "$tree" -m "LND backups $(date -u +%Y-%m-%dT%H:%M:%SZ)") || return 1
    if ! github_git -C "$GITHUB_WORK" push -q --force "$(github_url)" "$commit:refs/heads/main"; then
        log_message "$(T "❌ Pushing to the GitHub repository %s failed (is the deploy key allowed to write?)" "${GITHUB_REPO:-?}")"
        git -C "$GITHUB_WORK" reset -q --hard HEAD 2>/dev/null || true
        return 1
    fi
    remote=$(github_remote_head) || remote=""
    if [[ "$remote" != "$commit" ]]; then
        log_message "$(T "❌ GitHub doesn't show the backup just pushed: not counted as stored")"
        return 1
    fi
    git -C "$GITHUB_WORK" update-ref refs/heads/main "$commit"
    git -C "$GITHUB_WORK" reset -q --soft "$commit"
    # The local copy keeps no history either
    git -C "$GITHUB_WORK" reflog expire --expire=now --all 2>/dev/null || true
    git -C "$GITHUB_WORK" gc -q --prune=now 2>/dev/null || true
    log_message "$(T "✅ Stored on GitHub (%s) and checked: GitHub shows commit %s" "$GITHUB_REPO" "${commit:0:12}")"
}

# A fresh copy of what is on GitHub in folder $1 (for restoring: it doesn't need this server's
# working copy, so it works on a new server too). Run as the backup user.
github_fetch_all() {
    local dir="$1" remote
    remote=$(github_remote_head) || return 1
    [[ -n "$remote" ]] || return 0
    git init -q "$dir" && github_git -C "$dir" fetch -q --depth 1 "$(github_url)" main &&
        git -C "$dir" checkout -q FETCH_HEAD
}
