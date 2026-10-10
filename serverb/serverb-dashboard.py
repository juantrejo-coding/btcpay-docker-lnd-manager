#!/usr/bin/env python3
"""serverb-dashboard: the btcpay-docker-lnd-manager dashboard on Server B.

Shows bitcoind's sync and the watchtower, and starts, stops and restarts them. Run it as the
dashboard's admin user (serverb-dashboard-setup.sh makes it). Everything that needs root goes
through one fixed root helper, /usr/local/sbin/serverb-control, which sudo allows this user to
run without a password; nothing else runs as root.

Usage: serverb-dashboard          full-screen dashboard
       serverb-dashboard --once   print the status as text and exit (1 if there are problems)

Until everything is set up, a line at the top says what to do next; /checklist shows every step.
It looks for new Bitcoin Core and LND releases when it starts and every 12 hours, and says when
one is out; /update bitcoind and /update tower install it. Nothing updates by itself.

Commands: type / for the list; it narrows as you type, Up/Down picks, Tab completes, Enter runs,
Esc closes. q quits.
"""

import curses
import json
import os
import subprocess
import sys
import threading
import time
import unicodedata

# === Translations (see i18n.sh on Server A) ===
# serverb-dashboard-setup.sh installs the catalog of the language Server A's config chose
# (settings.json: "language") as messages.cat. The English text is the key; text without a
# translation stays English.
CATALOG_FILE = "/usr/local/lib/serverb-dashboard/messages.cat"
TRANSLATIONS = {}


def _(text):
    return TRANSLATIONS.get(text, text)


def N_(text):
    """Marks text for translation where it is defined; _() translates it where it is shown."""
    return text


def catalog_unescape(text):
    return text.replace("\\\\", "\x01").replace("\\n", "\n").replace("\\t", "\t").replace("\x01", "\\")


def load_translations(language):
    TRANSLATIONS.clear()
    if not language or language == "en":
        return
    try:
        with open(CATALOG_FILE, encoding="utf-8") as f:
            for line in f:
                key, tab, value = line.rstrip("\n").partition("\t")
                if tab and key and value and not key.startswith("#"):
                    TRANSLATIONS[catalog_unescape(key)] = catalog_unescape(value)
    except OSError:
        pass


# Words shown as systemd gives them; compared in English, translated where shown
SHOWN_WORDS = (N_("active"), N_("inactive"), N_("failed"), N_("activating"), N_("deactivating"),
               N_("reloading"), N_("unknown"))

HELPER = "/usr/local/sbin/serverb-control"
# Run as this user for the check (no root needed); the helper runs it as root for /update
UPDATE_TOOL = "/usr/local/lib/serverb-dashboard/serverb-update"
UPDATE_CHECK_SECONDS = 12 * 3600
UPDATE_NAMES = {"bitcoind": N_("Bitcoin Core"), "tower": N_("LND (the watchtower)"),
                "scripts": N_("these scripts")}
SETTINGS_FILE = "/usr/local/lib/serverb-dashboard/settings.json"
REFRESH_SECONDS = 5

# (name, description, action, details). Typed text only ever selects one of these.
COMMANDS = [
    ("/checklist", N_("what is set up, and what to do next"), "checklist",
     N_("Shows each Server B setup step, whether it is done, and which script runs the ones that "
     "aren't: the backup user and its gate, backups arriving, Bitcoin Core, the blockchain, the "
     "watchtower, the firewall. Read only.")),
    ("/status", N_("refresh the status now"), "status",
     N_("Reads bitcoind's sync and the watchtower's state again. Read only.")),
    ("/bitcoind start", N_("start bitcoind"), "start bitcoind",
     N_("Starts Bitcoin Core. The watchtower needs it to see new blocks.")),
    ("/bitcoind stop", N_("stop bitcoind"), "stop bitcoind",
     N_("Stops Bitcoin Core. While it is stopped the watchtower sees no new blocks, so it can't "
     "catch a cheating channel peer. You type STOP to confirm.")),
    ("/bitcoind restart", N_("restart bitcoind"), "restart bitcoind",
     N_("Stops and starts Bitcoin Core, for example after changing /etc/bitcoin/local.conf, then "
     "the watchtower if it was running (it loses bitcoind meanwhile): both offline for a minute "
     "or so.")),
    ("/tower start", N_("start the watchtower"), "start tower",
     N_("Starts the LND watchtower. It unlocks its wallet by itself.")),
    ("/tower stop", N_("stop the watchtower"), "stop tower",
     N_("Stops the LND watchtower: while it is stopped it doesn't protect Server A's channels, and "
     "Server A's node keeps its updates until the tower is back. You type STOP to confirm.")),
    ("/tower restart", N_("restart the watchtower"), "restart tower",
     N_("Stops and starts the LND watchtower; it is offline for a minute or so.")),
    ("/update check", N_("look for new Bitcoin Core and LND releases now"), "update check",
     N_("Asks bitcoincore.org and api.github.com for the latest releases and compares them with what "
     "is installed. It also does that by itself every 12 hours. Changes nothing.")),
    ("/update bitcoind", N_("install the latest Bitcoin Core"), "update bitcoind",
     N_("Downloads the latest Bitcoin Core release, checks its signatures (at least 3 builders) and "
     "checksum like serverb-bitcoind-setup.sh, installs it and restarts bitcoind, then the "
     "watchtower (it loses bitcoind meanwhile): offline for a minute or so. Only while Server A says "
     "it is safe (its LND runs, nothing in flight, no channel opening or closing); else it waits up to "
     "24 hours, then installs at the next boot. Nothing is installed if a check fails. You type UPDATE.")),
    ("/update tower", N_("install the latest LND for the watchtower"), "update tower",
     N_("Downloads the latest LND release, checks its signatures (at least 2 signers) and checksum "
     "like serverb-watchtower-setup.sh, installs it and restarts the watchtower: offline for a "
     "minute or so. Only while Server A says it is safe, as /update bitcoind. LND updates its "
     "database at the first start, so the old version may not open it again. Nothing is installed "
     "if a check fails. You type UPDATE.")),
    ("/update scripts", N_("install the newest release of these scripts"), "update scripts",
     N_("Gets the newest release of these scripts from GitHub, checks its signature against the "
     "release key built in here, and updates the backup gate and this dashboard with the settings "
     "serverb-setup.sh saved. bitcoind and the watchtower keep running. You type UPDATE.")),
    ("/log bitcoind", N_("bitcoind's log"), "log bitcoind",
     N_("Shows the last lines of /var/lib/bitcoind/debug.log. Read only.")),
    ("/log tower", N_("the watchtower's log"), "log tower",
     N_("Shows the last lines of the watchtower's journal. Read only.")),
    ("/support", N_("support the project, license"), "support",
     N_("Shows the project's donation address, its page and a summary of the license. Text only: "
     "nothing is fetched or sent.")),
    ("/quit", N_("leave the dashboard"), "quit",
     N_("Leaves the dashboard. bitcoind and the watchtower keep running.")),
]


def load_settings():
    try:
        with open(SETTINGS_FILE, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def helper(*args, timeout=30):
    """Runs the root helper through sudo (never asks for a password). Returns (code, output)."""
    try:
        result = subprocess.run(["sudo", "-n", HELPER] + list(args), capture_output=True,
                                text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        return result.returncode, result.stdout + result.stderr
    except subprocess.TimeoutExpired:
        return 124, _("timed out")
    except OSError as e:
        return 127, e.strerror


def collect():
    code, out = helper("status")
    if code != 0:
        return {"error": out.strip().splitlines()[-1] if out.strip() else _("exit code %d") % code}
    try:
        return json.loads(out)
    except ValueError:
        return {"error": _("unexpected answer from %s") % HELPER}


def gb(n):
    return "%.1f GB" % (n / 1e9) if isinstance(n, (int, float)) else "?"


def check_updates():
    """{"bitcoind": (installed, latest), "tower": (...)} from serverb-update check; "-" is unknown."""
    try:
        result = subprocess.run([UPDATE_TOOL, "check"], capture_output=True, text=True,
                                timeout=120, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        return {}
    found = {}
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[0] in UPDATE_NAMES:
            found[parts[0]] = (parts[1], parts[2])
        # "pending <name> <version> waiting|boot": staged, waiting until Server A says it is safe
        elif len(parts) == 4 and parts[0] == "pending" and parts[1] in UPDATE_NAMES:
            found["pending " + parts[1]] = (parts[2], parts[3])
    return found


class UpdateChecker:
    """Checks in the background, so the screen never waits for the network."""

    def __init__(self):
        self.found, self.checked_at, self.running = {}, 0.0, False
        self.lock = threading.Lock()

    def start(self, force=False):
        with self.lock:
            if self.running or (not force and time.time() - self.checked_at < UPDATE_CHECK_SECONDS):
                return
            self.running = True
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        found = check_updates()
        with self.lock:
            self.found, self.checked_at, self.running = found, time.time(), False


def newer(installed, latest):
    """True if the version latest is newer than installed (both like 31.1 or v0.21.4-beta)."""
    def key(v):
        return [int(p) if p.isdigit() else 0 for p in v.lstrip("v").split("-")[0].split(".")]
    if "-" in (installed, latest) or not installed or not latest:
        return False
    try:
        return key(latest) > key(installed)
    except ValueError:
        return False


def update_lines(updates):
    """One line per available update, for the top of the screen."""
    out = []
    for name, (installed, latest) in sorted(updates.found.items()):
        if name.startswith("pending "):
            what = _(UPDATE_NAMES[name.split(" ", 1)[1]])
            if latest == "boot":
                out.append((_("Update waiting: %s %s is installed at the next boot (not safe for 24 hours)")
                            % (what, installed), "warn"))
            else:
                out.append((_("Update waiting: %s %s, installed once Server A says it is safe")
                            % (what, installed), "warn"))
            continue
        if name == "scripts" and newer(installed, latest):
            out.append((_("Update: these scripts %s are out (installed: %s). /update scripts")
                        % (latest, installed), "warn"))
        elif newer(installed, latest):
            out.append((_("Update: %s %s is out (installed: %s). /update %s")
                        % (_(UPDATE_NAMES[name]), latest, installed, name), "warn"))
    return out


def checklist(info):
    """The setup steps as (state, title, what to do), state "done", "todo" or "optional"."""
    facts = info.get("setup") or {}
    user = facts.get("backup_user") or "SERVER_B_USER"
    steps = []

    def step(done, title, todo, optional=False):
        steps.append(("done" if done else "optional" if optional else "todo", title, todo))

    step(facts.get("user_exists") and facts.get("sshd_limits"), _("Backup user %s, keys only") % user,
         _("sudo bash serverb-user-setup.sh (made on Server A: lnd-manager /serverb scripts)"))
    step(facts.get("gate"), _("Backup gate installed for Server A's key"),
         _("on Server A: lnd-manager /setup (it installs the gate over the key)"))
    # Server A backs up only when its channel backup changes, so an old newest backup is normal
    newest = facts.get("newest_backup")
    have = isinstance(newest, (int, float))
    step(have, _("Backups from Server A") + (_(" (newest %s old)") % age(time.time() - newest) if have else ""),
         _("none yet: on Server A, lnd-manager shows whether its backups reach Server B"))
    # The watchtower and what it needs
    step(facts.get("bitcoind_installed") and info.get("bitcoind_state") == "active",
         _("Bitcoin Core running (watchtower, optional)"),
         _("sudo bash serverb-bitcoind-setup.sh"), optional=True)
    step(facts.get("bitcoind_installed") and "chain_incoming" not in info,
         _("Blockchain imported, or syncing from the network"),
         _("the copy from Server A (lnd-manager /chain copy) waits in ~/chain-incoming: "
         "sudo bash serverb-import-chain.sh") if "chain_incoming" in info
         else _("after Bitcoin Core: copy it from Server A (/chain copy), or let it sync"), optional=True)
    tower = info.get("tower") or {}
    step(info.get("tower_state") == "active" and tower.get("pubkey"),
         _("Watchtower running"), _("sudo bash serverb-watchtower-setup.sh, then on Server A: /tower add"),
         optional=True)
    step(facts.get("ufw_active") and facts.get("ufw_tower_rule"),
         _("Firewall: the tower's port open only to Server A"),
         _("rerun serverb-watchtower-setup.sh: it offers to turn ufw on (SSH stays open)"), optional=True)
    # Once part of the watchtower is set up, the rest of it is needed too
    if any(state == "done" for state, _title, _todo in steps[3:]):
        steps = [("todo" if state == "optional" else state, title, todo) for state, title, todo in steps]
    return steps


def checklist_lines(info):
    """The /checklist page."""
    if "error" in info:
        return [(_("Can't read the status: %s") % info["error"], "fail")]
    out = [(_("Server B setup checklist"), "head"), ("", None)]
    marks = {"done": ("✅", "ok"), "todo": ("❌", "fail"), "optional": ("➖", "dim")}
    for state, title, todo in checklist(info):
        mark, style = marks[state]
        out.append(("%s %s" % (mark, title), style))
        if state != "done":
            out.append(("     " + todo, None))
    out.append(("", None))
    out.append((_("➖ optional: the watchtower and what it needs. Once one of them is set up, all count."), "dim"))
    return out


def age(seconds):
    seconds = max(0, int(seconds))
    if seconds < 3600:
        return "%dm" % (seconds // 60)
    if seconds < 86400:
        return "%dh" % (seconds // 3600)
    return "%dd" % (seconds // 86400)


def summary_lines(info, settings, updates=None):
    """The screen's top part as (text, style) pairs, plus the problems."""
    out, problems = [], []
    if updates is not None:
        out.extend(update_lines(updates))
    if "error" in info:
        problems.append(_("Can't read the status: %s") % info["error"])
        return out, problems
    steps = checklist(info)
    todo = [s for s in steps if s[0] == "todo"]
    if todo:
        required = [s for s in steps if s[0] != "optional"]
        out.append((_("Setup: %d of %d steps done. Next: %s (/checklist)")
                    % (len(required) - len(todo), len(required), todo[0][1]), "warn"))
        out.append(("", None))
    state = info.get("bitcoind_state", "unknown")
    out.append((_("Bitcoin Core: %s") % _(state), "ok" if state == "active" else "fail"))
    if state != "active":
        problems.append(_("bitcoind is %s") % _(state))
    b = info.get("bitcoind")
    if b:
        progress = b.get("verificationprogress") or 0
        out.append((_("  %s, blocks %s of %s headers (%.2f%%)%s") % (
            b.get("chain"), b.get("blocks"), b.get("headers"), progress * 100,
            _(", syncing") if b.get("initialblockdownload") else ""),
            "warn" if b.get("initialblockdownload") else None))
        out.append((_("  peers %s, on disk %s%s, %s") % (b.get("connections"), gb(b.get("size_on_disk")),
                                                     _(" (pruned)") if b.get("pruned") else "",
                                                     b.get("version") or ""), None))
        if b.get("connections") == 0:
            problems.append(_("bitcoind has no peers"))
    elif state == "active":
        out.append((_("  starting (no answer from bitcoin-cli yet)"), "dim"))
    out.append(("", None))
    state = info.get("tower_state", "unknown")
    out.append((_("Watchtower: %s") % _(state), "ok" if state == "active" else "fail"))
    if state != "active":
        problems.append(_("the watchtower is %s") % _(state))
    t, node = info.get("tower"), info.get("tower_node")
    if node:
        synced = node.get("synced_to_chain")
        out.append((_("  LND %s, block %s, %s") % (node.get("version", "?").split(" ")[0],
                                                node.get("block_height"),
                                                _("synced") if synced else _("catching up")),
                    None if synced else "warn"))
    if t:
        out.append((_("  pubkey ") + str(t.get("pubkey")), None))
        port = settings.get("watchtower_port", "")
        address = settings.get("watchtower_address", "")
        uris = t.get("uris") or (["%s@%s:%s" % (t.get("pubkey"), address, port)] if address else [])
        for uri in uris:
            out.append((_("  for Server A (lnd-manager: /tower add): ") + uri, "ok"))
    elif state == "active":
        out.append((_("  the tower starts once bitcoind has caught up"), "dim"))
    incoming = info.get("chain_incoming")
    if incoming:
        free = incoming.get("free_bytes")
        low = isinstance(free, (int, float)) and free < 5 * 1024 ** 3
        out.append(("", None))
        out.append((_("Chain copy from Server A: ~/chain-incoming is open, %s free") % gb(free),
                    "fail" if low else "warn"))
        out.append((_("  until serverb-import-chain.sh takes it over, Server A's key can write there"), "dim"))
        if low:
            problems.append(_("less than 5 GiB free while ~/chain-incoming is open"))
    return out, problems


def support_lines(settings):
    address = settings.get("support_btc_address") or _("(placeholder: SUPPORT_BTC_ADDRESS in Server A's config)")
    url = settings.get("support_url") or _("(placeholder: SUPPORT_URL in Server A's config)")
    return [
        ("btcpay-docker-lnd-manager", "head"),
        ("", None),
        (_("If it keeps your node safe, please support its development:"), None),
        (_("  Bitcoin:  ") + address, "ok"),
        (_("  Project:  ") + url, None),
        ("", None),
        (_("License (the full text is in LICENSE, with the scripts on Server A)"), "head"),
        (_("  Free for personal and business use up to USD 1,000,000 annual sales income."), None),
        (_("  Above that: a one-time USD 50 payment in bitcoin to the donation address."), None),
        (_("  Used in another commercial node service or tool: a one-time USD 500 payment."), None),
        (_("  A commercial user that doesn't pay agrees to pay 10 percent of those sales instead."), None),
        (_("  Keep your bitcoin payment receipt (transaction ID) as proof."), None),
        ("", None),
        (_("No warranty: use it at your own risk."), "dim"),
    ]


def clean(text):
    """Control characters (escape codes among them) become "?", tabs spaces."""
    return "".join(" " if ch == "\t" else "?" if unicodedata.category(ch) == "Cc" else ch
                   for ch in text)


def clip(text, width):
    """Cuts text to a number of terminal columns (wide characters take two)."""
    text = clean(text)
    out, used = [], 0
    for i, ch in enumerate(text):
        if unicodedata.combining(ch) or unicodedata.category(ch) in ("Mn", "Me", "Cf"):
            cols = 0
        elif unicodedata.east_asian_width(ch) in ("W", "F") or text[i + 1:i + 2] == "️":
            cols = 2
        else:
            cols = 1
        if used + cols > width:
            break
        out.append(ch)
        used += cols
    return "".join(out)


def put(stdscr, y, text, attr=curses.A_NORMAL, footer=False):
    height, width = stdscr.getmaxyx()
    last = height - 1 if footer else height - 2
    if 0 <= y <= last:
        try:
            stdscr.addstr(y, 0, clip(text, width - 1), attr)
        except curses.error:
            pass


def wrap(text, width):
    lines, line = [], ""
    for word in text.split():
        if line and len(line) + 1 + len(word) > width:
            lines.append(line)
            line = word
        else:
            line = (line + " " + word) if line else word
    if line:
        lines.append(line)
    return lines


def matching_commands(text):
    words = text.lower().split()
    return [c for c in COMMANDS if all(w in c[0] for w in words)]


def show_page(stdscr, title, lines, styles):
    """A full-screen text page; Up/Down/PgUp/PgDn/Home/End scroll, q, Esc or Enter go back."""
    top = None
    stdscr.timeout(-1)
    try:
        while True:
            stdscr.erase()
            height, width = stdscr.getmaxyx()
            room = max(1, height - 2)
            if top is None:
                top = 0 if title == _("Support") else max(0, len(lines) - room)
            top = max(0, min(top, len(lines) - room))
            put(stdscr, 0, " " + title + " " * width, curses.A_REVERSE)
            for i, (text, style) in enumerate(lines[top:top + room]):
                put(stdscr, 1 + i, " " + text, styles[style])
            put(stdscr, height - 1, _(" q back   Up/Down/PgUp/PgDn scroll") + " " * width,
                curses.A_REVERSE, footer=True)
            stdscr.refresh()
            key = stdscr.getch()
            if key in (ord("q"), ord("Q"), 27, 10, 13, curses.KEY_ENTER):
                return
            top += {curses.KEY_UP: -1, curses.KEY_DOWN: 1, curses.KEY_PPAGE: -room,
                    curses.KEY_NPAGE: room, curses.KEY_HOME: -len(lines),
                    curses.KEY_END: len(lines)}.get(key, 0)
    finally:
        stdscr.timeout(REFRESH_SECONDS * 1000)


def ask_typed(stdscr, question, phrase, styles):
    """Asks for an exact phrase on the footer row; Enter ends, Esc cancels."""
    typed = ""
    stdscr.timeout(-1)
    curses.curs_set(1)
    try:
        while True:
            height, width = stdscr.getmaxyx()
            line = _("%s Type %s: %s") % (question, phrase, typed)
            stdscr.move(height - 1, 0)
            stdscr.clrtoeol()
            put(stdscr, height - 1, line, styles["warn"] | curses.A_REVERSE, footer=True)
            stdscr.refresh()
            key = stdscr.getch()
            if key == 27:
                return False
            if key in (10, 13, curses.KEY_ENTER):
                return typed == phrase
            if key in (curses.KEY_BACKSPACE, 127, 8):
                typed = typed[:-1]
            elif 32 <= key < 127:
                typed += chr(key)
    finally:
        curses.curs_set(0)
        stdscr.timeout(REFRESH_SECONDS * 1000)


def run_update(stdscr, name):
    """/update: the helper installs the release on the normal terminal, so its progress shows."""
    curses.def_prog_mode()
    curses.endwin()
    print("\n$ sudo %s update %s" % (HELPER, name), flush=True)
    try:
        code = subprocess.call(["sudo", "-n", HELPER, "update", name])
    except KeyboardInterrupt:
        code = 130
    except OSError as e:
        print(_("Could not run it: %s") % e.strerror)
        code = 127
    print(_("\nExit code %d. Press Enter to return to the dashboard.") % code, flush=True)
    try:
        input()
    except (EOFError, KeyboardInterrupt):
        pass
    curses.reset_prog_mode()
    stdscr.clear()
    return code


def do_action(stdscr, action, settings, styles, info, updates):
    """Runs an action from COMMANDS. Returns a message for the footer."""
    verb, _space, name = action.partition(" ")
    label = {"bitcoind": "bitcoind", "tower": _("the watchtower")}.get(name, name)
    if action == "update check":
        updates.start(force=True)
        return _("Looking for new releases (the top line shows any)...")
    if verb == "update":
        current = updates.found.get(name)
        if current and not newer(*current):
            question = _("%s %s is the latest. Check again and update if newer?") % (_(UPDATE_NAMES[name]), current[0])
        elif name == "scripts":
            question = _("Update these scripts? bitcoind and the watchtower keep running.")
        else:
            question = _("Update %s? It restarts %s.") % (_(UPDATE_NAMES[name]), label)
        if not ask_typed(stdscr, question, "UPDATE", styles):
            return _("Cancelled: nothing was updated")
        code = run_update(stdscr, name)
        updates.start(force=True)
        return (_("✅ update %s: done") % name) if code == 0 else (_("❌ update %s: exit code %d") % (name, code))
    if action == "checklist":
        show_page(stdscr, _("Checklist"), checklist_lines(info), styles)
        return None
    if action == "support":
        show_page(stdscr, _("Support"), support_lines(settings), styles)
        return None
    if verb == "log":
        code, out = helper("log", name)
        lines = [(line, "fail" if "error" in line.lower() else None) for line in out.splitlines()]
        show_page(stdscr, _("Log: ") + label, lines or [(_("(empty)"), "dim")], styles)
        return None
    if verb in ("start", "stop", "restart"):
        if verb == "stop" and not ask_typed(stdscr, _("Stop %s?") % label, _("STOP"), styles):
            return _("Cancelled: %s keeps running") % label
        height, _width = stdscr.getmaxyx()
        doing = {"start": _("Starting %s..."), "stop": _("Stopping %s..."), "restart": _("Restarting %s...")}[verb]
        put(stdscr, height - 1, " " + doing % label + " " * 80,
            curses.A_REVERSE, footer=True)
        stdscr.refresh()
        code, out = helper(verb, name, timeout=900)
        if code == 0:
            return {"start": _("✅ %s started"), "stop": _("✅ %s stopped"), "restart": _("✅ %s restarted")}[verb] % label
        reason = (out.strip().splitlines() or [_("exit code %d") % code])[-1]
        return {"start": _("❌ starting %s: %s"), "stop": _("❌ stopping %s: %s"),
                "restart": _("❌ restarting %s: %s")}[verb] % (label, reason)
    return None


def draw(stdscr, info, settings, styles, footer, palette, updates):
    stdscr.erase()
    height, width = stdscr.getmaxyx()
    title = " btcpay-docker-lnd-manager: Server B"
    clock = time.strftime("%Y-%m-%d %H:%M:%S ")
    put(stdscr, 0, title + " " * max(1, width - len(title) - len(clock) - 1) + clock, curses.A_REVERSE)
    lines, problems = summary_lines(info, settings, updates)
    y = 2
    for text, style in lines:
        put(stdscr, y, text, styles[style])
        y += 1
    y += 1
    put(stdscr, y, _("Problems"), styles["head"])
    y += 1
    for p in problems or [_("none")]:
        put(stdscr, y, "  " + p, styles["fail"] if problems else styles["ok"])
        y += 1
    if palette is None:
        put(stdscr, height - 1, footer + " " * width, curses.A_REVERSE, footer=True)
    else:
        draw_palette(stdscr, palette, styles)
    stdscr.refresh()


def draw_palette(stdscr, palette, styles):
    height, width = stdscr.getmaxyx()
    matches = matching_commands(palette["text"])
    sel = min(palette["sel"], max(0, len(matches) - 1))
    details = wrap(_(matches[sel][3]), max(10, width - 4)) if matches else []
    detail_rows = min(len(details), max(0, height - 4))
    room = max(0, height - 2 - (detail_rows + 1 if detail_rows else 0))
    shown = min(len(matches), room)
    top = height - 1 - shown - (detail_rows + 1 if detail_rows else 0)
    name_width = max(len(c[0]) for c in COMMANDS) + 1
    first = max(0, sel - shown + 1)
    for row, (name, description, _action, _details) in enumerate(matches[first:first + shown]):
        stdscr.move(top + row, 0)
        stdscr.clrtoeol()
        put(stdscr, top + row, " %-*s %s" % (name_width, name, _(description)),
            curses.A_REVERSE if first + row == sel else curses.A_NORMAL)
    if detail_rows:
        y = top + shown
        stdscr.move(y, 0)
        stdscr.clrtoeol()
        put(stdscr, y, " " + "─" * max(0, width - 3), styles["dim"])
        for i, text in enumerate(details[:detail_rows]):
            stdscr.move(y + 1 + i, 0)
            stdscr.clrtoeol()
            put(stdscr, y + 1 + i, "   " + text, styles[None])
    if not matches:
        stdscr.move(height - 2, 0)
        stdscr.clrtoeol()
        put(stdscr, height - 2, _(" no matching command"), styles["dim"])
    line = "/ " + palette["text"]
    stdscr.move(height - 1, 0)
    stdscr.clrtoeol()
    put(stdscr, height - 1, line, curses.A_BOLD, footer=True)
    try:
        curses.curs_set(1)
        stdscr.move(height - 1, min(len(line), width - 1))
    except curses.error:
        pass


FOOTER_KEYS = N_(" / commands  q quit")


def run_dashboard(stdscr, settings):
    curses.curs_set(0)
    stdscr.timeout(REFRESH_SECONDS * 1000)
    styles = {None: curses.A_NORMAL, "head": curses.A_BOLD, "dim": curses.A_DIM}
    if curses.has_colors():
        curses.use_default_colors()
        for i, (name, color) in enumerate([("ok", curses.COLOR_GREEN), ("warn", curses.COLOR_YELLOW),
                                           ("fail", curses.COLOR_RED)], start=1):
            curses.init_pair(i, color, -1)
            styles[name] = curses.color_pair(i)
    else:
        styles.update(ok=curses.A_NORMAL, warn=curses.A_BOLD, fail=curses.A_REVERSE)
    message, message_until, palette = "", 0, None
    info, read_at = None, 0.0
    updates = UpdateChecker()
    while True:
        # At the start, then every UPDATE_CHECK_SECONDS
        updates.start()
        if info is None or time.time() - read_at >= REFRESH_SECONDS:
            info, read_at = collect(), time.time()
        footer = message if time.time() < message_until else _(FOOTER_KEYS)
        draw(stdscr, info, settings, styles, footer, palette, updates)
        key = stdscr.getch()
        if key == -1:
            continue
        action = None
        if palette is not None:
            matches = matching_commands(palette["text"])
            if key == 27:
                palette = None
            elif key in (curses.KEY_BACKSPACE, 127, 8):
                if palette["text"]:
                    palette["text"], palette["sel"] = palette["text"][:-1], 0
                else:
                    palette = None
            elif key == curses.KEY_UP:
                palette["sel"] = max(0, palette["sel"] - 1)
            elif key == curses.KEY_DOWN:
                palette["sel"] = min(max(0, len(matches) - 1), palette["sel"] + 1)
            elif key == 9 and matches:
                palette["text"], palette["sel"] = matches[min(palette["sel"], len(matches) - 1)][0][1:], 0
            elif key in (10, 13, curses.KEY_ENTER):
                if matches:
                    action = matches[min(palette["sel"], len(matches) - 1)][2]
                palette = None
            elif 32 <= key < 127:
                palette["text"] += chr(key)
                palette["sel"] = 0
        elif key == ord("/"):
            palette = {"text": "", "sel": 0}
        elif key in (ord("q"), ord("Q")):
            return
        if action == "quit":
            return
        if action == "status":
            info = None
        elif action:
            result = do_action(stdscr, action, settings, styles, info, updates)
            if result:
                message, message_until = " " + result, time.time() + 10
            info = None


def main():
    settings = load_settings()
    load_translations(settings.get("language", ""))
    if "--once" in sys.argv[1:]:
        updates = UpdateChecker()
        updates.found = check_updates()
        lines, problems = summary_lines(collect(), settings, updates)
        for text, _style in lines:
            print(clean(text))
        print(_("Problems:"))
        for p in problems or [_("none")]:
            print("  " + clean(p))
        sys.exit(1 if problems else 0)
    if not sys.stdout.isatty():
        sys.exit(_("Not a terminal. Use --once for a text status."))
    os.environ.setdefault("ESCDELAY", "100")
    try:
        curses.wrapper(run_dashboard, settings)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
