# --- serverb-releases.sh (copied in by serverb-scripts.sh): Bitcoin Core and LND releases ---
# Finds the latest release, checks its signatures and checksums, and installs it into
# /usr/local/bin. Used by serverb-bitcoind-setup.sh, serverb-watchtower-setup.sh and
# serverb-update (the Server B dashboard's /update). Needs serverb-common.sh.

# The installed versions as their releases are named (31.1, 24.0.1; v0.21.4-beta), or nothing
bitcoin_core_installed() {
    local v
    v=$(/usr/local/bin/bitcoind -version 2>/dev/null | head -n 1 | grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1) || true
    v="${v#v}"
    # bitcoind says v31.1.0 for the release 31.1
    [[ "$v" =~ ^([0-9]+\.[0-9]+)\.0$ ]] && v="${BASH_REMATCH[1]}"
    echo "$v"
}
lnd_installed() {
    local v
    v=$(/usr/local/bin/lnd --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?-beta' | head -n 1) || true
    echo "${v:+v$v}"
}

# The latest release's version. Release candidates never count.
bitcoin_core_latest() (
    local v
    cd "$(mktemp -d)" || exit 1
    trap 'rm -rf -- "$PWD"' EXIT
    fetch https://bitcoincore.org/bin/ index.html || exit 1
    # Folders are bitcoin-core-29.1/ or bitcoin-core-24.0.1/. A new version's folder holds only
    # its release candidates (test.rc1/) until the release: the newest with SHA256SUMS is it.
    for v in $(grep -oE 'bitcoin-core-[0-9]+\.[0-9]+(\.[0-9]+)?/' index.html |
               sed 's#^bitcoin-core-##; s#/$##' | sort -uV | tail -n 5 | tac); do
        if fetch "https://bitcoincore.org/bin/bitcoin-core-$v/SHA256SUMS" SHA256SUMS 2>/dev/null; then
            echo "$v"
            exit 0
        fi
    done
    exit 1
)
lnd_latest() (
    local tag
    cd "$(mktemp -d)" || exit 1
    trap 'rm -rf -- "$PWD"' EXIT
    fetch https://api.github.com/repos/lightningnetwork/lnd/releases/latest release.json || exit 1
    tag=$(python3 -c 'import json; print(json.load(open("release.json"))["tag_name"])') || exit 1
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?-beta$ ]] || exit 1
    echo "$tag"
)

# True if version $2 is newer than $1
newer_version() {
    [[ "$1" != "$2" && "$(printf '%s\n' "${1#v}" "${2#v}" | sort -V | tail -n 1)" == "${2#v}" ]]
}

# Downloads Bitcoin Core $1, checks that its SHA256SUMS carries good signatures from at least $2
# builders (keys from github.com/bitcoin-core/guix.sigs) and that the download matches, then
# installs bitcoind and bitcoin-cli into folder $3 (default /usr/local/bin; serverb-update stages
# them in its own folder first). Stops the script if anything fails; nothing is installed then.
bitcoin_core_install() (
    local version="$1" min="$2" target="${3:-/usr/local/bin}" arch tarball base_url status fpr uid
    local -a signers
    [[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "$(T "Not a Bitcoin Core release version: %s" "$version")"
    arch=$(machine_arch)
    cd "$(mktemp -d)" || die "$(T "No temporary folder")"
    trap 'rm -rf -- "$PWD"' EXIT
    # 32-bit ARM is called arm-linux-gnueabihf in Bitcoin Core's downloads
    if [[ "$arch" == armv7 ]]; then
        tarball="bitcoin-$version-arm-linux-gnueabihf.tar.gz"
    else
        tarball="bitcoin-$version-$arch-linux-gnu.tar.gz"
    fi
    base_url="https://bitcoincore.org/bin/bitcoin-core-$version"
    say "📥 Bitcoin Core %s (%s)" "$version" "$tarball"
    fetch "$base_url/SHA256SUMS" SHA256SUMS || die "$(T "Could not download SHA256SUMS")"
    fetch "$base_url/SHA256SUMS.asc" SHA256SUMS.asc || die "$(T "Could not download SHA256SUMS.asc")"
    fetch "$base_url/$tarball" "$tarball" || die "$(T "Could not download %s" "$tarball")"

    say "🔐 Getting the builders' keys (github.com/bitcoin-core/guix.sigs, builder-keys only)..."
    if ! GIT_TERMINAL_PROMPT=0 git clone -q --depth 1 --filter=blob:none --sparse \
            https://github.com/bitcoin-core/guix.sigs guix.sigs > git.log 2>&1 ||
       ! git -C guix.sigs sparse-checkout set builder-keys >> git.log 2>&1; then
        show_lines < git.log
        die "$(T "Could not get guix.sigs/builder-keys")"
    fi
    export GNUPGHOME="$PWD/gnupg"
    install -d -m 700 "$GNUPGHOME"
    gpg --batch --quiet --import guix.sigs/builder-keys/*.gpg 2>/dev/null || true

    status=$(gpg --batch --status-fd 1 --verify SHA256SUMS.asc SHA256SUMS 2>/dev/null || true)
    if grep -q '^\[GNUPG:\] BADSIG' <<< "$status"; then
        die "$(T "SHA256SUMS has a BAD signature: the download may have been tampered with")"
    fi
    mapfile -t signers < <(valid_signers <<< "$status")
    say "   Good signatures from %s builders:" "${#signers[@]}"
    for fpr in "${signers[@]}"; do
        uid=$(gpg --batch --with-colons --list-keys "$fpr" 2>/dev/null | awk -F: '$1 == "uid" { print $10; exit }')
        echo "     $fpr  $uid" | LC_ALL=C tr -d '\000-\010\013-\037\177'
    done
    (( ${#signers[@]} >= min )) ||
        die "$(T "SHA256SUMS needs good signatures from at least %s builders (MIN_SIGNATURES)" "$min")"
    grep -E "^[0-9a-f]{64}  $tarball\$" SHA256SUMS | sha256sum -c --quiet - ||
        die "$(T "%s doesn't match SHA256SUMS" "$tarball")"
    say "✅ %s matches SHA256SUMS, which %s builders signed" "$tarball" "${#signers[@]}"

    tar -xzf "$tarball" || die "$(T "Could not unpack %s" "$tarball")"
    install -o root -g root -m 755 "bitcoin-$version/bin/bitcoind" "bitcoin-$version/bin/bitcoin-cli" "$target/" ||
        die "$(T "Could not install bitcoind and bitcoin-cli")"
    if [[ "$target" == /usr/local/bin ]]; then
        say "✅ Installed %s" "$(/usr/local/bin/bitcoind -version | head -n 1)"
    else
        say "✅ Checked and ready to install: Bitcoin Core %s" "$version"
    fi
)

# Downloads LND $1 (a tag such as v0.21.4-beta), checks that its manifest carries good
# signatures from at least $2 of LND's release signers (keys from the lnd repository at that
# release) and that the download matches, then installs lnd and lncli into folder $3 (default
# /usr/local/bin). Stops the script if anything fails; nothing is installed then.
lnd_install() (
    local version="$1" min="$2" target="${3:-/usr/local/bin}" lnd_arch tarball base_url url file signer status fpr
    local -a sig_urls
    local -A signers=()
    [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?-beta$ ]] || die "$(T "Not an LND release tag: %s" "$version")"
    case "$(machine_arch)" in
        x86_64) lnd_arch=amd64 ;;
        aarch64) lnd_arch=arm64 ;;
        armv7) lnd_arch=armv7 ;;
    esac
    cd "$(mktemp -d)" || die "$(T "No temporary folder")"
    trap 'rm -rf -- "$PWD"' EXIT
    fetch "https://api.github.com/repos/lightningnetwork/lnd/releases/tags/$version" release.json ||
        die "$(T "No LND release %s" "$version")"
    # The manifest's signature files, one per signer: manifest-<signer>-<version>.sig
    mapfile -t sig_urls < <(python3 -c '
import json, re, sys
v = sys.argv[1]
for a in json.load(open("release.json"))["assets"]:
    if re.fullmatch(r"manifest-[A-Za-z0-9_-]+-" + re.escape(v) + r"\.sig", a["name"]):
        print(a["browser_download_url"])' "$version")
    tarball="lnd-linux-$lnd_arch-$version.tar.gz"
    base_url="https://github.com/lightningnetwork/lnd/releases/download/$version"
    say "📥 LND %s (%s), %s signature files" "$version" "$tarball" "${#sig_urls[@]}"
    fetch "$base_url/manifest-$version.txt" manifest.txt || die "$(T "Could not download the manifest")"
    fetch "$base_url/$tarball" "$tarball" || die "$(T "Could not download %s" "$tarball")"

    export GNUPGHOME="$PWD/gnupg"
    install -d -m 700 "$GNUPGHOME"
    for url in "${sig_urls[@]}"; do
        file="${url##*/}"
        signer="${file#manifest-}"
        signer="${signer%-"$version".sig}"
        [[ "$signer" =~ ^[A-Za-z0-9_-]+$ ]] || continue
        fetch "$url" "$file" || continue
        # The signer's key, from the lnd repository at this release
        fetch "https://raw.githubusercontent.com/lightningnetwork/lnd/$version/scripts/keys/$signer.asc" "$signer.asc" ||
            { say "   %s: no key in the lnd repository, skipped" "$signer"; continue; }
        gpg --batch --quiet --import "$signer.asc" 2>/dev/null || continue
        status=$(gpg --batch --status-fd 1 --verify "$file" manifest.txt 2>/dev/null || true)
        if grep -q '^\[GNUPG:\] BADSIG' <<< "$status"; then
            die "$(T "The manifest has a BAD signature (%s): the download may have been tampered with" "$signer")"
        fi
        fpr=$(valid_signers <<< "$status" | head -n 1)
        if [[ -n "$fpr" ]]; then
            signers["$fpr"]="$signer"
            say "   good signature: %s  %s" "$signer" "$fpr"
        fi
    done
    (( ${#signers[@]} >= min )) ||
        die "$(T "The manifest needs good signatures from at least %s signers (MIN_SIGNATURES), it has %s" "$min" "${#signers[@]}")"
    say "   Compare these fingerprints with LND's own list (docs: \"verifying the release\") if you can."
    grep -E "^[0-9a-f]{64}  $tarball\$" manifest.txt | sha256sum -c --quiet - || die "$(T "%s doesn't match the manifest" "$tarball")"
    say "✅ %s matches the manifest, which %s signers signed" "$tarball" "${#signers[@]}"
    tar -xzf "$tarball" || die "$(T "Could not unpack %s" "$tarball")"
    install -o root -g root -m 755 "lnd-linux-$lnd_arch-$version/lnd" "lnd-linux-$lnd_arch-$version/lncli" "$target/" ||
        die "$(T "Could not install lnd and lncli")"
    if [[ "$target" == /usr/local/bin ]]; then
        say "✅ Installed %s" "$(/usr/local/bin/lnd --version)"
    else
        say "✅ Checked and ready to install: LND %s" "$version"
    fi
)
# --- end of serverb-releases.sh ---
