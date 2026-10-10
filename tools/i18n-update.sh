#!/bin/bash
# i18n-update.sh: collects the messages from the scripts into locale/messages.pot, merges them
# into each locale/<language>.po (new messages untranslated, removed ones kept as obsolete), checks
# every translation (its %s and %d must match the English), then compiles the .cat files.
# Needs gettext (xgettext, msgmerge, msgfmt): run it while developing, not on the servers.
#
#   tools/i18n-update.sh              update every locale/<language>.po and its .cat
#   tools/i18n-update.sh --new fr     first make locale/fr.po (all messages untranslated)
#
# A new language: --new <code>, translate locale/<code>.po (Poedit, or any text editor), run this
# script again, and add the language's name and its word for "Language" to I18N_NAMES and
# I18N_WORD in i18n.sh. Setup offers it as soon as locale/<code>.cat exists.
set -euo pipefail
cd "$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")/.."
NEW_LANGUAGE=""
if [[ "${1:-}" == --new ]]; then
    NEW_LANGUAGE="${2:-}"
    [[ "$NEW_LANGUAGE" =~ ^[a-z]{2}$ && "$NEW_LANGUAGE" != en ]] || { echo "❌ --new needs a two-letter language code, not en" >&2; exit 2; }
    [[ ! -e "locale/$NEW_LANGUAGE.po" ]] || { echo "❌ locale/$NEW_LANGUAGE.po exists already" >&2; exit 1; }
fi

BASH_FILES=(setup_script.sh config-lib.sh rsync_gpg_backup.sh lnd-wallet.sh chain-tower.sh lnd-update.sh update-lib.sh
            install-scripts.sh serverb-scripts.sh serverb-lib.sh serverb-setup.sh server-b-install.sh serverb/*.sh serverb/serverb-update)
PYTHON_FILES=(lnd-manager.py serverb/serverb-dashboard.py serverb/serverb-control)

for tool in xgettext msgmerge msgfmt; do
    command -v "$tool" >/dev/null || { echo "❌ $tool is missing: sudo apt-get install gettext" >&2; exit 1; }
done

xgettext -L Shell -k -kT -ksay --flag=T:1:c-format --flag=say:1:c-format --from-code=UTF-8 \
    --sort-by-file --no-wrap --package-name=btcpay-docker-lnd-manager -o locale/shell.pot "${BASH_FILES[@]}"
xgettext -L Python -k -k_ -kN_ --flag=_:1:python-format --flag=N_:1:python-format --from-code=UTF-8 \
    --sort-by-file --no-wrap --package-name=btcpay-docker-lnd-manager -o locale/python.pot "${PYTHON_FILES[@]}"
msgcat --no-wrap --use-first -o locale/messages.pot locale/shell.pot locale/python.pot
# xgettext misses a few (a T or say after "then" on the same line, code inside trap '...')
python3 tools/i18n.py extra-pot locale/messages.pot "${BASH_FILES[@]}" "${PYTHON_FILES[@]}" > locale/extra.pot
if [[ -s locale/extra.pot ]]; then
    msgcat --no-wrap --use-first -o locale/messages.pot locale/messages.pot locale/extra.pot
fi
rm -f locale/shell.pot locale/python.pot locale/extra.pot
echo "✅ locale/messages.pot: $(grep -c '^msgid "' locale/messages.pot) messages"

if [[ -n "$NEW_LANGUAGE" ]]; then
    msginit --no-translator --no-wrap -l "$NEW_LANGUAGE.UTF-8" -i locale/messages.pot -o "locale/$NEW_LANGUAGE.po"
    sed -i "s/^\"Language: .*\\\\n\"$/\"Language: $NEW_LANGUAGE\\\\n\"/" "locale/$NEW_LANGUAGE.po"
    echo "✅ locale/$NEW_LANGUAGE.po: translate it, then run this script again"
fi

for po in locale/*.po; do
    [[ -e "$po" ]] || continue
    msgmerge --quiet --update --backup=none --no-wrap --no-fuzzy-matching --sort-by-file "$po" locale/messages.pot
    msgfmt --check-format --check-header -o /dev/null --statistics "$po"
    # Shell messages carry no format flag for msgfmt: their %s, %d and %% are checked here
    python3 tools/i18n.py check-format "$po"
    python3 tools/i18n.py compile "$po"
done
