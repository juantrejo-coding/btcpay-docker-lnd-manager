# i18n.sh: the scripts' messages in the language chosen in config (UI_LANGUAGE: en, es, fr, de).
# Sourced by the scripts after config; the Server B scripts get it built in.
#
#   T "Format with %s" "$value"     prints the message, translated, without a newline
#   say "Format with %s" "$value"   the same, with a newline
#
# The first argument is a printf format: values go in as arguments, never into the format
# itself, so a value can't be taken for a format (and a literal % is written %%). The English
# text is the key; a message with no translation stays English.
#
# Translations come from locale/<language>.cat: one "English<TAB>translation" pair per line,
# with \n, \t and \\ escaped. It is made from locale/<language>.po (tools/i18n.py compile) and
# read as plain data, never run. A script running as root uses it only if it is root's and only
# root can change it, like config; otherwise its messages stay English.

declare -gA I18N=()

# Each language's name, and its word for "Language", in that language. A language is available
# when locale/<code>.cat holds translations (English always is); one missing here shows as
# its code.
declare -gA I18N_NAMES=([en]="English" [es]="Español" [fr]="Français" [de]="Deutsch")
declare -gA I18N_WORD=([en]="Language" [es]="Idioma" [fr]="Langue" [de]="Sprache")

# The available languages' codes, English first, into I18N_LANGUAGES. $1: the locale folder.
# A catalog without a single translation yet (a language just started) doesn't count.
i18n_languages() {
    local dir="${1:-${SCRIPT_DIR:-.}/locale}" f code
    I18N_LANGUAGES=(en)
    for f in "$dir"/*.cat; do
        [[ -f "$f" ]] && grep -q $'\t' "$f" || continue
        code=$(basename -- "$f" .cat)
        [[ "$code" =~ ^[a-z]{2}$ && "$code" != en ]] && I18N_LANGUAGES+=("$code")
    done
}

# The escapes in a catalog line undone, into REPLY (no subshell: a catalog has many lines)
_i18n_unescape() {
    local s="$1"
    [[ "$s" == *\\* ]] || { REPLY="$s"; return; }
    s="${s//\\\\/$'\x01'}"
    s="${s//\\n/$'\n'}"
    s="${s//\\t/$'\t'}"
    REPLY="${s//$'\x01'/\\}"
}

# True if root owns $1 and every folder above it, and none is writable by others
_i18n_root_owned() {
    local path
    path=$(realpath -m -- "$1")
    while :; do
        [[ -e "$path" && "$(stat -c %u -- "$path")" == 0 ]] || return 1
        (( (8#$(stat -c %a -- "$path") & 8#022) == 0 )) || return 1
        [[ "$path" == / ]] && return 0
        path=$(dirname -- "$path")
    done
}

# Loads the catalog for UI_LANGUAGE from folder $1 (default: locale next to the script).
# "any-owner" as $2 skips the root-owned check: only for a script that runs from that same
# folder (install-scripts.sh), where whoever can change the catalog can change the script too.
i18n_load() {
    local dir="${1:-${SCRIPT_DIR:-.}/locale}" lang="${UI_LANGUAGE:-en}" owner="${2:-}" file key
    I18N=()
    [[ "$lang" =~ ^[a-z]{2}$ && "$lang" != en ]] || return 0
    file="$dir/$lang.cat"
    [[ -f "$file" ]] || return 0
    if (( EUID == 0 )) && [[ "$owner" != any-owner ]] && ! _i18n_root_owned "$file"; then
        echo "⚠️ $file can be changed by users other than root: messages stay in English" >&2
        return 0
    fi
    i18n_read < "$file"
}

# Reads catalog lines from stdin into I18N (also used for catalogs built into a script)
i18n_read() {
    local k v key
    while IFS=$'\t' read -r k v; do
        [[ -z "$k" || -z "$v" || "$k" == "#"* ]] && continue
        _i18n_unescape "$k"
        key="$REPLY"
        _i18n_unescape "$v"
        I18N["$key"]="$REPLY"
    done
}

T() {
    local format="$1"
    shift
    [[ -n "${I18N[$format]+set}" ]] && format="${I18N[$format]}"
    # shellcheck disable=SC2059
    printf -- "$format" "$@"
}

say() {
    T "$@"
    echo
}
# --- end of i18n.sh ---
