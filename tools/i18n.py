#!/usr/bin/env python3
"""i18n.py: the translation catalogs (see i18n.sh).

  tools/i18n.py compile locale/es.po        writes locale/es.cat, the catalog the scripts read
  tools/i18n.py check                       exit 1 if a .cat is older than its .po's content
  tools/i18n.py subset locale/es.cat FILE   prints the catalog lines FILE's messages use (for
                                            the Server B scripts, which carry their own)
  tools/i18n.py check-format locale/es.po   exit 1 if a translation's %s, %d, %% differ from the
                                            English (count or order); warns about changed spaces
                                            at either end and a changed first emoji
  tools/i18n.py extra-pot POT FILE...       prints, as .pot entries, the T/say/_ messages in
                                            FILE... that POT lacks (xgettext misses a few)
  tools/i18n.py set locale/es.po FILE.json  sets translations: FILE.json is {"English": "translation"};
                                            each English text must be a message of the .po

tools/i18n-update.sh collects the messages from the scripts into locale/es.po (needs gettext's
xgettext, msgmerge and msgfmt; only when developing, never on the servers).

A .cat line is "English<TAB>translation", with backslash, tab and newline written \\\\, \\t, \\n.
Entries marked fuzzy or not translated yet are left out: those messages stay English.
"""

import ast
import os
import re
import sys

HERE = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
LOCALE = os.path.join(HERE, "locale")
PO_ESCAPES = {"n": "\n", "t": "\t", '"': '"', "\\": "\\"}


def po_string(text):
    """The value of one "..." piece of a .po file."""
    out, i = [], 0
    while i < len(text):
        ch = text[i]
        if ch == "\\" and i + 1 < len(text):
            out.append(PO_ESCAPES.get(text[i + 1], "\\" + text[i + 1]))
            i += 2
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def read_po(path):
    """[(msgid, msgstr, fuzzy)] from a .po file (msgctxt and plurals are not used here)."""
    entries, current, field, fuzzy = [], {}, None, False

    def finish():
        if "msgid" in current:
            entries.append((current["msgid"], current.get("msgstr", ""), fuzzy))

    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if not line.strip():
                finish()
                current, field, fuzzy = {}, None, False
                continue
            if line.startswith("#,") and "fuzzy" in line:
                fuzzy = True
                continue
            if line.startswith("#"):
                continue
            m = re.match(r'^(msgid|msgstr)\s+"(.*)"$', line)
            if m:
                if m.group(1) == "msgid" and "msgid" in current:
                    finish()
                    current, fuzzy = {}, False
                field = m.group(1)
                current[field] = po_string(m.group(2))
                continue
            m = re.match(r'^"(.*)"$', line)
            if m and field:
                current[field] += po_string(m.group(1))
    finish()
    return [(i, s, z) for i, s, z in entries if i]


def cat_escape(text):
    return text.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")


def cat_lines(po_path):
    lines = ["# Made by tools/i18n.py from %s; edit that file, not this one" % os.path.basename(po_path)]
    for msgid, msgstr, fuzzy in sorted(read_po(po_path)):
        if msgstr and not fuzzy:
            lines.append(cat_escape(msgid) + "\t" + cat_escape(msgstr))
    return lines


def compile_po(po_path):
    target = os.path.splitext(po_path)[0] + ".cat"
    with open(target, "w", encoding="utf-8") as f:
        f.write("\n".join(cat_lines(po_path)) + "\n")
    print("%s: %d translated" % (target, len(cat_lines(po_path)) - 1))


def check():
    stale = []
    for name in sorted(os.listdir(LOCALE)):
        if not name.endswith(".po"):
            continue
        po = os.path.join(LOCALE, name)
        cat = os.path.splitext(po)[0] + ".cat"
        try:
            with open(cat, encoding="utf-8") as f:
                current = f.read()
        except OSError:
            current = None
        if current != "\n".join(cat_lines(po)) + "\n":
            stale.append(cat)
    for cat in stale:
        print("%s is out of date: tools/i18n.py compile %s" % (cat, os.path.splitext(cat)[0] + ".po"))
    return 1 if stale else 0


def bash_messages(text):
    """The first argument of every T or say call: a double-quoted string, as bash reads it."""
    found = set()
    for m in re.finditer(r'(?:^|[\s(;|&`])(?:T|say)\s+"((?:[^"\\]|\\.)*)"', text, re.M):
        s = re.sub(r'\\([\\"$`])', r"\1", m.group(1))
        found.add(s)
    return found


def python_messages(text):
    """The string argument of every _() and N_() call."""
    found = set()
    for node in ast.walk(ast.parse(text)):
        if (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                and node.func.id in ("_", "N_") and node.args
                and isinstance(node.args[0], ast.Constant) and isinstance(node.args[0].value, str)):
            found.add(node.args[0].value)
    return found


def subset(cat_path, files):
    wanted = set()
    for path in files:
        with open(path, encoding="utf-8") as f:
            text = f.read()
        if path.endswith(".py") or text.startswith("#!/usr/bin/env python3") or text.startswith("#!/usr/bin/python3"):
            wanted |= python_messages(text)
        else:
            wanted |= bash_messages(text)
    with open(cat_path, encoding="utf-8") as f:
        for line in f:
            if "\t" not in line or line.startswith("#"):
                continue
            key = line.split("\t", 1)[0]
            unescaped = key.replace("\\\\", "\x01").replace("\\n", "\n").replace("\\t", "\t").replace("\x01", "\\")
            if unescaped in wanted:
                sys.stdout.write(line)


FORMAT_RE = re.compile(r"%(?:%|[-+ #0]*[0-9*]*(?:\.[0-9*]+)?[a-zA-Z])")
# What bash's printf and Python's % take: any other % (a lone "100 %", %1$s) makes bash's printf
# fail, which stops a set -e script
STRICT_RE = re.compile(r"%(?:%|[-+ #0]*[0-9]*(?:\.[0-9]+)?[diouxXeEfFgGcsbq])")


def stray_percents(text):
    """The % signs in text that don't start a format bash's printf and Python both take."""
    out, i = [], 0
    while True:
        i = text.find("%", i)
        if i < 0:
            return out
        m = STRICT_RE.match(text, i)
        if m:
            i = m.end()
        else:
            out.append(text[i:i + 3])
            i += 1


def unsafe_chars(text):
    """Backslashes and control characters other than newline and tab: bash's printf turns
    backslash escapes into control codes, which could rewrite or clear the terminal."""
    return sorted({c for c in text if c == "\\" or (ord(c) < 32 and c not in "\n\t") or ord(c) == 127})


def check_format(po_path):
    errors = warnings = 0
    for msgid, msgstr, fuzzy in read_po(po_path):
        if not msgstr or fuzzy:
            continue
        if FORMAT_RE.findall(msgid) != FORMAT_RE.findall(msgstr):
            print("ERROR   placeholders %s -> %s: %r" % (FORMAT_RE.findall(msgid), FORMAT_RE.findall(msgstr), msgid))
            errors += 1
        if len(stray_percents(msgstr)) > len(stray_percents(msgid)):
            print("ERROR   a %% that is no format (write %%%% for a percent sign) %s: %r" % (stray_percents(msgstr), msgid))
            errors += 1
        extra = [c for c in unsafe_chars(msgstr) if c not in unsafe_chars(msgid)]
        if extra:
            print("ERROR   backslash or control characters %r the English doesn't have: %r" % (extra, msgid))
            errors += 1
        lead = lambda t: t[:len(t) - len(t.lstrip())]
        trail = lambda t: t[len(t.rstrip()):]
        if lead(msgid) != lead(msgstr) or trail(msgid) != trail(msgstr):
            print("WARNING spaces at the ends differ: %r" % msgid)
            warnings += 1
        first = msgid.lstrip()[:1]
        if first and not first.isalnum() and first not in "%(<\"'/[-." and msgstr.lstrip()[:1] != first:
            print("WARNING the first character (emoji) changed: %r" % msgid)
            warnings += 1
    print("%s: %d errors, %d warnings" % (po_path, errors, warnings))
    return 1 if errors else 0


def po_quote(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t") + '"'


def extra_pot(pot_path, files):
    known = {i for i, _, _ in read_po(pot_path)}
    print('msgid ""\nmsgstr ""\n"Content-Type: text/plain; charset=UTF-8\\n"\n')
    for path in files:
        with open(path, encoding="utf-8") as f:
            text = f.read()
        if path.endswith(".py") or text.startswith(("#!/usr/bin/env python3", "#!/usr/bin/python3")):
            found = python_messages(text)
        else:
            found = bash_messages(text)
        for msgid in sorted(found - known):
            print("#: %s\nmsgid %s\nmsgstr \"\"\n" % (path, po_quote(msgid)))
            known.add(msgid)


def set_translations(po_path, json_path):
    import json
    with open(json_path, encoding="utf-8") as f:
        pairs = json.load(f)
    with open(po_path, encoding="utf-8") as f:
        text = f.read()
    for english, translation in pairs.items():
        entry = "msgid %s\nmsgstr " % po_quote(english)
        i = text.find(entry)
        if i < 0:
            sys.exit("%s: no message %r (single-line msgid expected)" % (po_path, english))
        j = text.index("\n", i + len(entry))
        text = text[:i] + entry + po_quote(translation) + text[j:]
    with open(po_path, "w", encoding="utf-8") as f:
        f.write(text)
    print("%s: %d set" % (po_path, len(pairs)))


def main():
    args = sys.argv[1:]
    if len(args) == 2 and args[0] == "compile":
        # Never a catalog with a translation that would break the scripts
        if check_format(args[1]):
            sys.exit("%s: not compiled, fix the errors above" % args[1])
        compile_po(args[1])
    elif args == ["check"]:
        sys.exit(check())
    elif len(args) >= 3 and args[0] == "subset":
        subset(args[1], args[2:])
    elif len(args) == 2 and args[0] == "check-format":
        sys.exit(check_format(args[1]))
    elif len(args) == 3 and args[0] == "set":
        set_translations(args[1], args[2])
    elif len(args) >= 3 and args[0] == "extra-pot":
        extra_pot(args[1], args[2:])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
