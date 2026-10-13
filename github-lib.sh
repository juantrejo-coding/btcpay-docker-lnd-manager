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
# with --force, so the repository stays small. (GitHub may keep the commits replaced for a while
# before its garbage collection; they are encrypted.)
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

# Whether the key is a deploy key for GITHUB_REPO alone. GitHub greets a deploy key with the
# repository ("Hi owner/name! You've successfully authenticated...") and a key added to an account
# with the account ("Hi owner! ..."). An account key writes to every repository of that account,
# so a broken-into Server A could force-push over all of them: it is never used.
# Returns 0 (a deploy key for GITHUB_REPO), 1 (an account key, or another repository's: refused),
# 2 (no answer, or a test repository: unknown, the push decides). Run as the backup user.
github_key_check() {
    local greeting who
    [[ "$(github_url)" == "git@github.com:${GITHUB_REPO}.git" ]] || return 2
    greeting=$(timeout 60 ssh -i "$(github_key_path)" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20 \
               -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$(github_known_hosts)" \
               -T git@github.com < /dev/null 2>&1 | grep -m1 -o "^Hi [^!]*!" || true)
    [[ -n "$greeting" ]] || return 2
    who="${greeting#Hi }"
    who="${who%!}"
    [[ "${who,,}" == "${GITHUB_REPO,,}" ]] && return 0
    if [[ "$who" == */* ]]; then
        log_message "$(T "❌ The GitHub key is a deploy key of another repository (%s), not of %s" "$who" "$GITHUB_REPO")"
    else
        log_message "$(T "❌ The GitHub key is added to the GitHub account %s, not as a deploy key of %s: it could write to every repository of that account. Remove it there (Settings, SSH keys) and add it to the repository's Deploy keys." "$who" "$GITHUB_REPO")"
    fi
    return 1
}

# The commit the repository's main branch points to, or nothing (empty repository)
github_remote_head() {
    github_git ls-remote "$(github_url)" refs/heads/main | cut -f1
}

# At most this much is fetched from GitHub at once (KiB): with fetch.unpackLimit=1 a fetch arrives
# as one pack file, which ulimit -f caps. Whoever controls the GitHub account could otherwise fill
# this server's disk, where LND and bitcoind run, with whatever they put in the repository.
GITHUB_MAX_FETCH_KB=$((3 * 1024 * 1024))

# Fetches main's newest commit into git folder $1 (a repository's .git, or a bare one)
github_fetch_head() {
    local rc=0
    ( ulimit -f "$GITHUB_MAX_FETCH_KB" && github_git -c fetch.unpackLimit=1 -C "$1" fetch -q --depth 1 "$(github_url)" main ) || rc=$?
    # A fetch cut off by the limit leaves its partial pack behind
    (( rc == 0 )) || find "$1" -path '*/objects/pack/tmp_*' -type f -delete 2>/dev/null
    return "$rc"
}

# The repository's expected entries only: a plain file (mode 100644) under main/, daily/, monthly/
# or pre-recovery/ with a backup's name, at most GITHUB_MAX_BYTES. Anything else (put there by
# whoever controls the GitHub account) is left out: never written into a file, never pushed back.
# Reads "git ls-tree -r -l" lines, prints the entries kept as "git update-index --index-info" lines.
github_valid_entries() {
    local mode type sha size path
    while IFS=$' \t' read -r mode type sha size path; do
        [[ "$mode" == 100644 && "$type" == blob && "$sha" =~ ^[0-9a-f]{40}$ && "$size" =~ ^[0-9]+$ ]] || continue
        [[ "$path" =~ ^main/encrypted_backup_${GITHUB_TS}\.gpg$ ||
           "$path" =~ ^daily/backup_[0-9]{4}-[0-9]{2}-[0-9]{2}\.gpg$ ||
           "$path" =~ ^monthly/backup_[0-9]{4}-[0-9]{2}\.gpg$ ||
           "$path" =~ ^pre-recovery/pre-recovery_${GITHUB_TS}\.gpg$ ]] || continue
        (( size <= GITHUB_MAX_BYTES )) || continue
        printf '%s %s\t%s\n' "$mode" "$sha" "$path"
    done
}

# What is on GitHub, as git's index in the backup user's metadata folder: no files are checked
# out (git would keep each backup twice, in .git and as a file), each upload builds its commit in
# the index. GitHub's content is the truth for each upload: if GitHub has something else (a first
# run on a new server, or a change made by hand), its expected entries are taken first, so no
# backup there is lost.
GITHUB_WORK="${BACKUP_METADATA_FOLDER:-$HOME/backup_metadata_folder}/github"
github_index() {
    git -C "$GITHUB_WORK" "$@"
}
github_sync_work() {
    local remote local_head entries
    if [[ ! -d "$GITHUB_WORK/.git" ]]; then
        rm -rf -- "$GITHUB_WORK"
        git init -q -b main "$GITHUB_WORK" || return 1
    fi
    # Older versions kept the files checked out here too: only .git stays
    find "$GITHUB_WORK" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf -- {} + 2>/dev/null || true
    remote=$(github_remote_head) || return 1
    local_head=$(github_index rev-parse -q --verify HEAD 2>/dev/null || true)
    if [[ -n "$remote" && "$remote" != "$local_head" ]]; then
        github_fetch_head "$GITHUB_WORK/.git" || return 1
        entries=$(github_index ls-tree -r -l FETCH_HEAD | github_valid_entries) || return 1
        github_index read-tree --empty || return 1
        if [[ -n "$entries" ]]; then
            github_index update-index --index-info <<< "$entries" || return 1
        fi
    elif [[ -n "$local_head" ]]; then
        github_index read-tree "$local_head" || return 1
    else
        github_index read-tree --empty || return 1
    fi
}

# True if the index has an entry at path $1
github_has() {
    github_index ls-files --error-unmatch -- "$1" >/dev/null 2>&1
}

# Adds backup file $1 to area $2 (main or pre-recovery), makes the milestones, rotates, and pushes
# the result as one commit. Verified: GitHub's main branch then points to exactly that commit, which
# holds every file by its hash. Returns 1 (with a message) if anything fails.
github_store() {
    local file="$1" area="$2" name size blob day month n stamp epoch commit tree remote f kind local_head
    local -a sorted
    name=$(basename -- "$file")
    size=$(stat -c %s -- "$file") || return 1
    if (( size > GITHUB_MAX_BYTES )); then
        log_message "$(T "❌ %s is %s MB: GitHub takes files up to 100 MB, so it isn't stored there" "$name" "$(( size / 1024 / 1024 ))")"
        return 1
    fi
    # An account key (1) is refused; no answer (2) goes on, the push fails by itself then
    local key_state=0
    github_key_check || key_state=$?
    (( key_state != 1 )) || return 1
    github_sync_work || { log_message "$(T "❌ Could not reach the GitHub repository %s with its deploy key" "${GITHUB_REPO:-?}")"; return 1; }
    if [[ "$area" == pre-recovery ]]; then
        n=$(github_index ls-files -- pre-recovery/ | wc -l)
        if ! github_has "pre-recovery/$name" && (( n >= GITHUB_MAX_PRE_RECOVERY )); then
            log_message "$(T "❌ The GitHub repository holds %s safety backups already: delete old ones there first" "$GITHUB_MAX_PRE_RECOVERY")"
            return 1
        fi
    fi
    blob=$(github_index hash-object -w -- "$(realpath -- "$file")") || return 1
    github_index update-index --add --cacheinfo "100644,$blob,$area/$name" || return 1

    if [[ "$area" == main ]]; then
        # Milestones: the day and month in the name (lnd-wallet.sh checks them against the signed
        # time inside). The same object as the backup: git stores it once.
        day="${name:17:10}" month="${name:17:7}"
        github_has "daily/backup_$day.gpg" ||
            github_index update-index --add --cacheinfo "100644,$blob,daily/backup_$day.gpg" || return 1
        github_has "monthly/backup_$month.gpg" ||
            github_index update-index --add --cacheinfo "100644,$blob,monthly/backup_$month.gpg" || return 1
        # main: the newest by their real time
        sorted=()
        while IFS= read -r f; do
            [[ "$f" =~ ^main/encrypted_backup_${GITHUB_TS}\.gpg$ ]] || continue
            stamp="${f#main/encrypted_backup_}"
            epoch=$(date -d "${stamp%.gpg}" +%s 2>/dev/null) || continue
            sorted+=("$epoch $f")
        done < <(github_index ls-files -- main/)
        mapfile -t sorted < <(printf '%s\n' "${sorted[@]}" | sort -k1,1nr | cut -d' ' -f2-)
        for f in "${sorted[@]:GITHUB_KEEP_MAIN}"; do
            if [[ -n "$f" && "$f" != "main/$name" ]]; then
                github_index update-index --force-remove -- "$f" || return 1
            fi
        done
        for kind in daily:$GITHUB_KEEP_DAILY monthly:$GITHUB_KEEP_MONTHLY; do
            mapfile -t sorted < <(github_index ls-files -- "${kind%%:*}/" | sort -r)
            for f in "${sorted[@]:${kind#*:}}"; do
                if [[ -n "$f" ]]; then
                    github_index update-index --force-remove -- "$f" || return 1
                fi
            done
        done
    fi

    # One commit with no parent: what is on GitHub is exactly the current backups
    tree=$(github_index write-tree) || return 1
    commit=$(GIT_AUTHOR_NAME=lnd-backup GIT_AUTHOR_EMAIL=lnd-backup@localhost GIT_COMMITTER_NAME=lnd-backup \
             GIT_COMMITTER_EMAIL=lnd-backup@localhost github_index commit-tree "$tree" -m "LND backups $(date -u +%Y-%m-%dT%H:%M:%SZ)") || return 1
    if ! github_git -C "$GITHUB_WORK" push -q --force "$(github_url)" "$commit:refs/heads/main"; then
        log_message "$(T "❌ Pushing to the GitHub repository %s failed (is the deploy key allowed to write?)" "${GITHUB_REPO:-?}")"
        # The index goes back to the last commit pushed
        local_head=$(github_index rev-parse -q --verify HEAD 2>/dev/null || true)
        if [[ -n "$local_head" ]]; then github_index read-tree "$local_head"; else github_index read-tree --empty; fi
        return 1
    fi
    remote=$(github_remote_head) || remote=""
    if [[ "$remote" != "$commit" ]]; then
        log_message "$(T "❌ GitHub doesn't show the backup just pushed: not counted as stored")"
        return 1
    fi
    github_index update-ref refs/heads/main "$commit"
    # No history here either: the objects of earlier commits go
    github_index reflog expire --expire=now --all 2>/dev/null || true
    github_index gc -q --prune=now 2>/dev/null || true
    log_message "$(T "✅ Stored on GitHub (%s) and checked: GitHub shows commit %s" "$GITHUB_REPO" "${commit:0:12}")"
}

# A fresh copy of what is on GitHub in folder $1, as files: <area>/<name> (for restoring: it
# doesn't need this server's index, so it works on a new server too). Only the expected entries
# are written, never a link or another path. The git objects go in $1.git. Run as the backup user.
github_fetch_all() {
    local dir="$1" remote mode sha path
    remote=$(github_remote_head) || return 1
    [[ -n "$remote" ]] || return 0
    git init -q --bare "$dir.git" || return 1
    github_fetch_head "$dir.git" || return 1
    mkdir -p "$dir/main" "$dir/daily" "$dir/monthly" "$dir/pre-recovery" || return 1
    while IFS=$' \t' read -r mode sha path; do
        git -C "$dir.git" cat-file blob "$sha" > "$dir/$path" || return 1
    done < <(git -C "$dir.git" ls-tree -r -l FETCH_HEAD | github_valid_entries)
}
