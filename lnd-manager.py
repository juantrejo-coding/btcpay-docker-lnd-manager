#!/usr/bin/env python3
"""lnd-manager: the btcpay-docker-lnd-manager dashboard on Server A.

The LND backup service (rsync_gpg_backup.sh), the wallet commands (lnd-wallet.sh) and Server B.

Shows what the service is doing, the last file change, each backup type's last success and
failure, problems and the log. It reads the status file the service writes (STATUS_FILE),
systemctl and the log. Its actions run the usual commands (systemctl through sudo, the setup
scripts), each after showing the command and asking. The scripts and the service work the
same without it.

Usage: lnd-manager.py          full-screen dashboard
       lnd-manager.py --once   print the status as text and exit (1 if there are problems)

Until everything is set up, a line at the top says what to do next; /checklist shows every step.

Commands: type / for the list of commands; it narrows as you type, Up/Down picks, Tab completes,
Enter runs, Esc closes. Shortcuts: s start/stop the service, r restart it, c run the hourly check
now, l full log, w the wallet commands, q quit.
Wallet commands run lnd-wallet.sh in a tmux session, so a dropped SSH connection doesn't stop
them; /wallet attach goes back to one that is still running.

Keep it next to config and the scripts; it reads config from its own folder.
"""

import curses
import datetime
import os
import re
import subprocess
import stat
import sys
import threading
import time
import unicodedata

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
CONFIG_FILE = os.path.join(SCRIPT_DIR, "config")

REFRESH_SECONDS = 2
# A file change older than this without a newer successful backup is a problem
BACKUP_LATE_SECONDS = 15 * 60
# Server B is behind when its last success is this much older than the attached volume's
REMOTE_BEHIND_SECONDS = 15 * 60
# A retry marker older than this is a problem
PENDING_LATE_SECONDS = 60 * 60
# The hourly check is late after this long (it runs every RECON_INTERVAL, default 1h)
CHECK_LATE_SECONDS = 2 * 60 * 60
ERROR_WINDOW_SECONDS = 24 * 60 * 60
LOG_TAIL_BYTES = 256 * 1024

# === Translations (see i18n.sh) ===
# config's UI_LANGUAGE picks locale/<language>.cat next to this script. The English text is the
# key; text without a translation stays English.
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
    if not re.fullmatch(r"[a-z]{2}", language or "") or language == "en":
        return
    try:
        # errors="replace": a damaged catalog gives odd characters, not a crash at start
        with open(os.path.join(SCRIPT_DIR, "locale", language + ".cat"), encoding="utf-8", errors="replace") as f:
            for line in f:
                key, tab, value = line.rstrip("\n").partition("\t")
                if tab and key and value and not key.startswith("#"):
                    TRANSLATIONS[catalog_unescape(key)] = catalog_unescape(value)
    except (OSError, ValueError):
        pass


# Words the dashboard shows as they come from systemd and the status file. The code compares
# the English ones; _() translates them only where they are shown. Listed here to be translated.
SHOWN_WORDS = (
    # systemd's states (ActiveState/SubState) and results
    N_("active"), N_("inactive"), N_("failed"), N_("activating"), N_("deactivating"),
    N_("reloading"), N_("running"), N_("dead"), N_("exited"), N_("auto-restart"),
    N_("start"), N_("stop"), N_("success"), N_("exit-code"), N_("signal"), N_("timeout"),
    N_("unknown"),
    # The backup service's jobs (set_job in rsync_gpg_backup.sh)
    N_("idle"), N_("starting"), N_("stopped"), N_("hourly check"),
    N_("backup: checking files"), N_("backup: compressing"), N_("backup: copying LND files"),
    N_("backup: copying to Server B"), N_("backup: copying to the attached volume"),
    N_("backup: copying to GitHub"),
    N_("backup: encrypting"), N_("backup: milestones"), N_("backup: removing old backups"),
    N_("backup: verifying the copy"), N_("backup: waiting for files to settle"),
)

# The settings setup asks for: the checklist's first step is done when none is empty
SETUP_VARS = ["MAIN_USER", "SERVER_A_USER", "SERVER_B_USER", "REMOTE_SERVER", "REMOTE_SSH_PORT",
              "SERVER_B_KNOWN_HOST_FINGERPRINT", "UUID", "GPG_FINGERPRINT", "GITHUB_REPO"]
# Which setting each of them needs: only asked for while that destination is on
SETUP_VAR_DESTINATION = {"SERVER_B_USER": "BACKUP_TO_SERVER_B", "REMOTE_SERVER": "BACKUP_TO_SERVER_B",
                         "REMOTE_SSH_PORT": "BACKUP_TO_SERVER_B",
                         "SERVER_B_KNOWN_HOST_FINGERPRINT": "BACKUP_TO_SERVER_B",
                         "UUID": "BACKUP_TO_VOLUME", "GITHUB_REPO": "BACKUP_TO_GITHUB"}
DESTINATIONS = [("volume", "BACKUP_TO_VOLUME", "yes"), ("serverb", "BACKUP_TO_SERVER_B", "yes"),
                ("github", "BACKUP_TO_GITHUB", "no")]
CONFIG_VARS = ["STATUS_FILE", "RSYNC_BACKUP_SERVICE_NAME", "LIGHTNING_BACKUP_LOG_FILE",
               "BACKUP_SCRIPTS_FOLDER", "BACKUP_INSTALL_DIR", "ATTACHED_VOLUME", "WATCHTOWER_PUBKEY",
               "SUPPORT_BTC_ADDRESS", "SUPPORT_URL", "UI_LANGUAGE", "BACKUP_TO_VOLUME",
               "BACKUP_TO_SERVER_B", "BACKUP_TO_GITHUB", "SECOND_BACKUP_DIR",
               "BACKUP_METADATA_FOLDER"] + SETUP_VARS
# BTCPay's settings, readable by everyone: which fragments (opt-lnd-wtclient) it runs with
BTCPAY_ENV = "/etc/profile.d/btcpay-env.sh"

# (label, ok key, fail key, pending key, the destination it belongs to)
BACKUP_ROWS = [
    (N_("Backup"), "backup_last_ok", "backup_last_fail", None, None),
    (N_("Attached volume"), "local_last_ok", "local_last_fail", None, "BACKUP_TO_VOLUME"),
    (N_("Server B"), "remote_last_ok", "remote_last_fail", "remote_pending_since", "BACKUP_TO_SERVER_B"),
    (N_("GitHub"), "github_last_ok", "github_last_fail", "github_pending_since", "BACKUP_TO_GITHUB"),
    (N_("Milestones, local"), "milestone_local_last_ok", "milestone_local_last_fail",
     "milestones_pending_since", "BACKUP_TO_VOLUME"),
    # Server B and GitHub keep their own milestones, so there is no row for them
]


def destination_on(config, setting):
    """True if the backups go to that destination (config: BACKUP_TO_*; older configs: the
    attached volume and Server B on, GitHub off)."""
    default = "no" if setting == "BACKUP_TO_GITHUB" else "yes"
    return (config.get(setting) or default) == "yes"

# The commands the / list offers: (name, description, action, details). Typed text only ever
# selects one of these; it is never passed to a shell. The details show under the list for the
# highlighted command: what it does, what it stops or deletes, what is kept.
COMMANDS = [
    ("/checklist", N_("what is set up, and what to do next"), "checklist",
     N_("Shows each setup step, whether it is done, and what to run for the ones that aren't: "
     "settings, the root-owned install, the attached volume, your seed and GPG key stored "
     "safely, the backup service, the first backups, and the watchtower (optional). Read only.")),
    ("/check", N_("run the hourly check now"), "check",
     N_("Asks the backup service to check LND's files now instead of at the next hourly check. "
     "If any changed, it makes a backup. Nothing is stopped or deleted.")),
    ("/log", N_("full backup log"), "log",
     N_("Opens the whole backup log in less (q comes back here). Read only.")),
    ("/start", N_("start the backup service"), "start",
     N_("Starts the backup service. BTCPay and LND aren't touched.")),
    ("/stop", N_("stop the backup service"), "stop",
     N_("Stops the backup service: no backups are made until it is started again. "
     "BTCPay and LND keep running.")),
    ("/restart", N_("restart the backup service"), "restart",
     N_("Stops and starts the backup service, for example after editing config. A backup that is "
     "running is stopped and made again later. BTCPay and LND keep running.")),
    ("/setup", N_("setup_script.sh: users, keys, attached volume, Server B"), "setup",
     N_("Runs setup_script.sh: the backup user, the SSH key for Server B, the GPG backup key, the "
     "attached volume. It asks before each step and doesn't touch BTCPay or LND.")),
    ("/serverb scripts", N_("make the scripts to run on Server B"), "serverb scripts",
     N_("Runs serverb-scripts.sh: makes the scripts you run on Server B with sudo (the backup user, "
     "a pruned bitcoind, the blockchain import, the watchtower, the Server B dashboard), with your "
     "settings filled in. Asks for settings config doesn't have yet. Shows each script's sha256 "
     "and how to copy them to Server B. Changes nothing on either server.")),
    ("/destinations", N_("where the backups go: each destination on or off"), "destinations",
     N_("Shows the attached volume, Server B and GitHub, each on or off, with its last copy. "
     "/destination volume, /destination serverb and /destination github turn one on or off. Read only.")),
    ("/destination volume", N_("turn the attached volume on or off"), "destination volume",
     N_("Runs destinations.sh volume. Off: new backups no longer go to the attached volume (type TURN "
     "OFF); the copies there stay, and restoring still looks there. On: runs setup, which mounts the "
     "disk, then reinstalls the backup service. At least one destination stays on.")),
    ("/destination serverb", N_("turn Server B on or off"), "destination serverb",
     N_("Runs destinations.sh serverb. Off: new backups no longer go to Server B (type TURN OFF); "
     "its copies stay. On: runs setup, which sets up Server B's key and gate, then reinstalls the "
     "backup service. At least one destination stays on.")),
    ("/destination github", N_("turn GitHub on or off"), "destination github",
     N_("Runs destinations.sh github. On: runs setup, which asks for your private repository "
     "(owner/name), makes a deploy key and shows it to add on GitHub with write access, then "
     "reinstalls the backup service. Off: new backups no longer go there (type TURN OFF); its "
     "copies stay. A broken-into server could delete the copies on GitHub: Server B's can't.")),
    ("/foreign ok", N_("accept the backup on Server B this server didn't send"), "foreign ok",
     N_("Only once you know no other LND with this seed runs: an old server you have switched off for "
     "good, a test. The backup service then ignores that one backup on Server B and the warning goes; "
     "a newer one from elsewhere warns again. Changes nothing on Server B. If you aren't sure, find "
     "and stop the other node first: two nodes with the same channels can lose all the funds in them.")),
    ("/serverb send", N_("send Server B its settings (and the scripts, if you choose)"), "serverb send",
     N_("Runs serverb-scripts.sh send: asks for settings config doesn't have yet, then sends Server B "
     "serverb.conf through the backup gate, and, if you choose, serverb-install.sh with all the "
     "scripts made here. They go into the backup user's ~/serverb-setup; nothing runs there. Then "
     "shows what to run on Server B with sudo: serverb-setup.sh from a git clone, or serverb-install.sh.")),
    ("/chain prune", N_("prune BTCPay's blockchain (BTCPay's presets)"), "chain prune",
     N_("Prunes BTCPay's blockchain with one of BTCPay's opt-save-storage presets: ~100, ~50, ~25 "
     "(recommended) or ~5 GB. Old blocks are deleted: BTCPay can then no longer rescan for old "
     "transactions. Stops BTCPay's bitcoind and LND for a few minutes while btcpay-setup.sh "
     "applies it; you type STOP BTCPAY first.")),
    ("/chain copy", N_("copy BTCPay's pruned blockchain to Server B"), "chain copy",
     N_("Copies BTCPay's pruned blockchain to Server B's bitcoind (into the folder "
     "serverb-bitcoind-setup.sh made), so it doesn't sync for days. It asks where it is pruned to "
     "Server B's size: here, in a copy beside BTCPay's (BTCPay's own blockchain isn't changed; less "
     "to send), or on Server B after the import. It checks there is room on both servers first. Two "
     "passes: the first while BTCPay runs, the second stops BTCPay for a few minutes (you type STOP "
     "BTCPAY). Runs in tmux; /chain attach goes back to it. Then run serverb-import-chain.sh on "
     "Server B.")),
    ("/chain attach", N_("back to a chain or tower operation that is still running"), "chain attach",
     N_("Goes back to /chain prune, /chain copy or /tower add still running in tmux, for example "
     "after the SSH connection dropped. Ctrl-b d leaves it running and comes back here.")),
    ("/tower add", N_("use Server B's watchtower for this node"), "tower add",
     N_("Asks for the watchtower's public key and address if config lacks them, then turns on "
     "BTCPay's watchtower client (opt-lnd-wtclient: Stops BTCPay's LND for a few minutes, you "
     "type STOP BTCPAY) and adds the tower. LND then sends it encrypted channel updates.")),
    ("/tower status", N_("the watchtower client's towers"), "tower status",
     N_("Shows the towers BTCPay's LND uses and its statistics (lncli wtclient towers, stats). "
     "Read only.")),
    ("/update", N_("install the newest release of these scripts"), "update",
     N_("Runs sudo lnd-update: gets the newest release from GitHub, checks its signature against the "
     "release key installed with the scripts, and asks you to type UPDATE. It installs it when no "
     "backup, wallet operation or /chain or /tower operation runs (else it waits up to 24 hours, then "
     "at the next boot), and reinstalls the backup service. LND and BTCPay keep running.")),
    ("/install", N_("rsync_gpg_backup.sh: install or update the backup service"), "install",
     N_("Installs or updates the backup service: encrypted, signed backups of LND's files to the "
     "attached volume and Server B, run as the backup user. Also its read-only root helper and "
     "sudo rule. It explains everything first, and deletes existing backups only if you type "
     "DELETE ALL BACKUPS. BTCPay and LND aren't touched.")),
    ("/wallet new", N_("replace the wallet with a new one"), "wallet new",
     N_("Makes a new LND wallet in place of the current one. Stops BTCPay for a few minutes. The "
     "current wallet is kept in a safety backup, but its funds stay reachable only through its "
     "old seed. Asks you to type confirmations before anything changes.")),
    ("/wallet restore", N_("restore the wallet from its seed"), "wallet restore",
     N_("Restores the wallet's on-chain funds from its seed: from the latest backup, or typed. "
     "Stops BTCPay; the scan for old funds can take minutes to hours. Channels are not restored "
     "(/wallet channels). Safety backup and typed confirmations first.")),
    ("/wallet channels", N_("restore the wallet and the channels"), "wallet channels",
     N_("Restores the wallet from its seed and the channels from channel.backup: each peer closes "
     "its channel and your share comes back on-chain. Stops BTCPay. Never while another LND with "
     "this seed runs. Safety backup and typed confirmations first.")),
    ("/wallet channels-only", N_("restore the channels into the running wallet"), "wallet channels-only",
     N_("Restores the channels from channel.backup into the wallet that runs now, for example after "
     "/wallet restore. Stops BTCPay for a few minutes for a safety backup. Never while another LND "
     "with this seed runs. Typed confirmations first.")),
    ("/wallet undo", N_("put a safety backup back"), "wallet undo",
     N_("Puts a safety backup back as the whole LND volume, channel state included. Only safe if no "
     "LND has run with those channels since. Stops BTCPay. Saves the current wallet first, and "
     "asks you to type confirmations.")),
    ("/wallet attach", N_("back to a wallet operation that is still running"), "wallet attach",
     N_("Goes back to a wallet operation still running in tmux, for example after the SSH connection "
     "dropped. Ctrl-b d leaves it running and comes back here.")),
    ("/support", N_("support the project, license"), "support",
     N_("Shows the project's donation address, its page and a summary of the license. Text only: "
     "nothing is fetched or sent.")),
    ("/quit", N_("leave the dashboard"), "quit",
     N_("Leaves the dashboard. The backup service keeps running.")),
]
# Single keys, for the actions used most
SHORTCUTS = {"s": "start/stop", "r": "restart", "c": "check", "l": "log", "m": "setup",
             "i": "install"}
# lnd-wallet.sh writes this while it runs: "<pid> <option> <start time> <tmux or ->"
WALLET_RUNNING_FILE = "/run/lnd-wallet.running"
WALLET_TMUX_SESSION = "lnd-wallet"
# lnd-wallet.sh's own tmux socket, in a folder only root can write to
WALLET_TMUX_SOCKET = "/run/lnd-wallet-tmux/sock"
# lnd-update check (no root): "scripts <installed> <newest>" and "pending <tag> waiting|boot <since>"
UPDATE_TOOL = "/usr/local/bin/lnd-update"
UPDATE_CHECK_SECONDS = 12 * 3600
# lnd-wallet.sh's exit codes when you detach from its tmux session while it keeps running, and
# when it only went back to an earlier operation's session without starting the one asked for
WALLET_STILL_RUNNING = 3
WALLET_NOT_STARTED = 4
WALLET_OPTIONS = {"1": "new", "2": "restore", "3": "channels", "4": "channels-only", "5": "undo",
                  "menu": "menu"}

LOG_TIME_RE = re.compile(r"^\[(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2})([+-]\d{2}:\d{2})?\]")


def load_config():
    """Reads the needed values from config by letting bash source it (config is a bash file)."""
    script = 'source "$1" >/dev/null 2>&1 || exit 1; shift; for v in "$@"; do printf "%s=%s\\0" "$v" "${!v-}"; done'
    try:
        out = subprocess.run(["bash", "-c", script, "_", CONFIG_FILE] + CONFIG_VARS,
                             capture_output=True, check=True).stdout.decode(errors="replace")
    except (OSError, subprocess.CalledProcessError):
        sys.exit("Could not load %s (keep config next to lnd-manager.py)" % CONFIG_FILE)
    values = dict(item.split("=", 1) for item in out.split("\0") if "=" in item)
    if not values.get("RSYNC_BACKUP_SERVICE_NAME"):
        sys.exit("RSYNC_BACKUP_SERVICE_NAME is not set in %s" % CONFIG_FILE)
    return values


STATUS_MAX_BYTES = 64 * 1024


def read_status(path):
    """The service's status file as a dict, or None if there is none to read. It is the backup
    user's: opened without following a link and without waiting (a pipe there would hang the
    screen), only if it is a plain file, and only its first STATUS_MAX_BYTES."""
    if not path:
        return None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None
        lines = os.read(fd, STATUS_MAX_BYTES).decode("utf-8", errors="replace").splitlines()
    except OSError:
        return None
    finally:
        os.close(fd)
    status = {}
    for line in lines:
        if "=" in line:
            key, value = line.split("=", 1)
            status[key] = value
    return status


def read_service(name):
    props = ["LoadState", "ActiveState", "SubState", "Result", "NRestarts",
             "ActiveEnterTimestampMonotonic"]
    try:
        out = subprocess.run(["systemctl", "show", name, "-p", ",".join(props)],
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}
    service = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)
    # Uptime from the monotonic clock, so a clock change doesn't distort it
    try:
        entered = int(service.get("ActiveEnterTimestampMonotonic", "0")) / 1e6
        if entered > 0 and service.get("ActiveState") == "active":
            service["uptime"] = time.monotonic() - entered
    except ValueError:
        pass
    return service


def read_log(path, service_name):
    """The last log lines: from the log file if readable, else from the journal."""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - LOG_TAIL_BYTES))
            data = f.read().decode("utf-8", errors="replace")
        lines = data.splitlines()
        if size > LOG_TAIL_BYTES:
            lines = lines[1:]  # the first line is probably cut
        return lines, None
    except OSError as e:
        file_error = "%s: %s" % (path, e.strerror)
    try:
        result = subprocess.run(["journalctl", "-u", service_name, "-n", "2000", "-o", "cat",
                                 "--no-pager", "-q"], capture_output=True, text=True, timeout=10)
        lines = [line for line in result.stdout.splitlines() if line.startswith("[")]
        if lines:
            return lines, None
    except (OSError, subprocess.TimeoutExpired):
        pass
    return [], _("Can't read the log (%s) or the journal") % file_error


def log_line_time(line):
    m = LOG_TIME_RE.match(line)
    if not m:
        return None
    text = m.group(1).replace(" ", "T") + (m.group(2) or "")
    try:
        stamp = datetime.datetime.fromisoformat(text)
    except ValueError:
        return None
    if stamp.tzinfo is None:
        stamp = stamp.astimezone()  # setup_script.sh logs local time without an offset
    return stamp.timestamp()


def is_noise(line):
    """Lines left out of the log pane: heartbeats and rsync's verbose output."""
    body = LOG_TIME_RE.sub("", line, count=1)
    # The text after the timestamp starts with a space; the heartbeat is known by its 💓 alone,
    # since its words are in the chosen language
    return body.lstrip().startswith("💓") or body.startswith("    ") or body.startswith("   [")


def num(status, key):
    """A time or count from the status file; None when it isn't a sensible one (a time before
    2000 or after 2200 can't be right, and would make the time functions fail)."""
    try:
        value = int(status.get(key, ""))
    except ValueError:
        return None
    return value if 0 <= value < 7258118400 else None


def fmt_time(ts, now):
    if ts is None:
        return _("never")
    dt = datetime.datetime.fromtimestamp(ts)
    today = datetime.datetime.fromtimestamp(now).date()
    if dt.date() == today:
        when = dt.strftime("%H:%M:%S")
    elif dt.date() == today - datetime.timedelta(days=1):
        when = dt.strftime(_("yesterday %H:%M"))
    else:
        when = dt.strftime("%Y-%m-%d %H:%M")
    return _("%s (%s ago)") % (when, fmt_age(now - ts))


def fmt_age(seconds):
    seconds = max(0, int(seconds))
    if seconds < 60:
        return "%ds" % seconds
    if seconds < 3600:
        return "%dm" % (seconds // 60)
    if seconds < 86400:
        return "%dh %dm" % (seconds // 3600, seconds % 3600 // 60)
    return "%dd %dh" % (seconds // 86400, seconds % 86400 // 3600)


def read_wallet_running():
    """The wallet operation lnd-wallet.sh is running, as (option, start time, in tmux), or None."""
    try:
        with open(WALLET_RUNNING_FILE, encoding="utf-8", errors="replace") as f:
            parts = f.read().split()
        pid, option, started = int(parts[0]), parts[1], int(parts[2])
    except (OSError, ValueError, IndexError):
        return None
    # A run killed hard leaves the file behind: only a live process counts
    if not os.path.exists("/proc/%d" % pid):
        return None
    in_tmux = len(parts) > 3 and parts[3] == "tmux"
    return WALLET_OPTIONS.get(option, option), started, in_tmux


def read_file(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        return None


def read_setup_state(folder):
    """What setup remembered for the checklist (setup-state in the working folder): name -> time."""
    data = read_file(os.path.join(folder, "setup-state")) if folder else None
    state = {}
    for line in (data or b"").decode("utf-8", "replace").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            state[key] = value
    return state


def btcpay_fragments():
    """BTCPAYGEN_ADDITIONAL_FRAGMENTS from BTCPay's settings, read as text (never run)."""
    data = read_file(BTCPAY_ENV) or b""
    m = re.search(rb'^export\s+BTCPAYGEN_ADDITIONAL_FRAGMENTS=(.*)$', data, re.M)
    if not m:
        return []
    # Written as a\;b by btcpay-setup.sh, sometimes quoted
    value = m.group(1).decode("utf-8", "replace").strip().strip("'\"").replace("\\", "")
    return value.split(";")


def checklist(config, status, service):
    """The setup steps as (state, title, what to do, optional), state "done", "todo" or
    "optional" (an optional step not done)."""
    steps = []

    def step(done, title, todo, optional=False):
        steps.append(("done" if done else "optional" if optional else "todo", title, todo, optional))

    missing = [v for v in SETUP_VARS
               if (v not in SETUP_VAR_DESTINATION or destination_on(config, SETUP_VAR_DESTINATION[v]))
               and (not config.get(v) or (v == "SERVER_B_KNOWN_HOST_FINGERPRINT" and config[v] == "SHA256:"))]
    step(not missing, _("Settings in config"),
         _("/setup asks for them: ") + ", ".join(missing))

    working = config.get("BACKUP_SCRIPTS_FOLDER", "")
    # Older configs have no BACKUP_INSTALL_DIR; the scripts then use this default too
    install_dir = config.get("BACKUP_INSTALL_DIR") or "/usr/local/lib/btcpay-docker-lnd-manager"
    installed = read_file(os.path.join(install_dir, "config"))
    ours = read_file(os.path.join(working, "config")) if working else None
    if installed is None:
        todo = _("/setup installs them (or sudo ./install-scripts.sh in your working folder)")
    else:
        todo = (_("config in your working folder changed since it was installed: "
                "sudo ./install-scripts.sh there (setup does it too)"))
    step(installed is not None and installed == ours, _("Scripts installed root-owned"), todo)

    volume, uuid = config.get("ATTACHED_VOLUME", ""), config.get("UUID", "")
    mounted = ""
    if volume and uuid:
        try:
            mounted = subprocess.run(["findmnt", "-n", "-o", "UUID", "--mountpoint", volume],
                                     capture_output=True, text=True, timeout=5).stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            pass
    if destination_on(config, "BACKUP_TO_VOLUME"):
        step(bool(uuid) and mounted == uuid, _("Attached volume mounted at %s") % (volume or "?"),
             _("/setup mounts it (attach the disk first)"))

    remembered = read_setup_state(working)
    unconfirmed = [what for key, what in (("lnd_seed_stored", _("your LND seed")),
                                          ("gpg_key_saved", _("the GPG backup key")))
                   if key not in remembered]
    step(not unconfirmed, _("LND seed and GPG key stored safely, away from this server"),
         _("not confirmed yet: %s. /setup asks (for the GPG key: answer y to view it, then confirm)")
         % _(" and ").join(unconfirmed))

    if service.get("LoadState") != "loaded":
        todo = _("/install installs it")
    else:
        todo = _("it is %s: /start, and /log if it stops again") % _(service.get("ActiveState", "?"))
    step(service.get("ActiveState") == "active", _("Backup service running"), todo)

    if destination_on(config, "BACKUP_TO_VOLUME"):
        step(num(status, "local_last_ok") is not None, _("First backup on the attached volume"),
             _("made at the next change of LND's channel backup; /check looks now. /log says why it fails"))
    if destination_on(config, "BACKUP_TO_SERVER_B"):
        step(num(status, "remote_last_ok") is not None, _("First backup on Server B"),
             _("made with the next backup. If it fails, /log says why (Server B's gate: /setup installs it)"))
    if destination_on(config, "BACKUP_TO_GITHUB"):
        step(num(status, "github_last_ok") is not None, _("First backup on GitHub"),
             _("made with the next backup. If it fails, /log says why (the deploy key: /setup shows it)"))

    tower = (config.get("WATCHTOWER_PUBKEY", "") not in ("", "your-watchtower-public-key")
             and "opt-lnd-wtclient" in btcpay_fragments())
    step(tower, _("Watchtower on Server B (optional)"),
         _("/serverb send gives Server B its settings and says what to run there; then /tower add"),
         optional=True)
    return steps


def checklist_lines(steps):
    """The /checklist page."""
    out = [(_("Setup checklist"), "head"), ("", None)]
    marks = {"done": ("✅", "ok"), "todo": ("❌", "fail"), "optional": ("➖", "dim")}
    for state, title, todo, _optional in steps:
        mark, style = marks[state]
        out.append(("%s %s" % (mark, title), style))
        if state != "done":
            out.append(("     " + todo, None))
    out.append(("", None))
    out.append((_("Everything above is read from config, the status file and the system; only the"), "dim"))
    out.append((_("seed and GPG key step comes from your answers in setup."), "dim"))
    return out


class UpdateChecker:
    """Asks lnd-update check in the background every UPDATE_CHECK_SECONDS, so the screen never
    waits for the network."""

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
        found = {}
        try:
            result = subprocess.run([UPDATE_TOOL, "check"], capture_output=True, text=True,
                                    timeout=120, stdin=subprocess.DEVNULL)
            for line in result.stdout.splitlines():
                parts = line.split()
                if len(parts) == 3 and parts[0] == "scripts":
                    found["scripts"] = (parts[1], parts[2])
                elif len(parts) == 4 and parts[0] == "pending":
                    found["pending"] = (parts[1], parts[2])
        except (OSError, subprocess.TimeoutExpired):
            pass
        with self.lock:
            self.found, self.checked_at, self.running = found, time.time(), False


UPDATES = UpdateChecker()


def release_newer(installed, latest):
    """True if release latest (v1.2.3) is newer than installed (v1.2.0, v1.2.0-3-gabc, unknown)."""
    def key(v):
        m = re.match(r"v?(\d+)\.(\d+)\.(\d+)", v)
        return tuple(int(x) for x in m.groups()) if m else (0, 0, 0)
    return bool(re.fullmatch(r"v\d+\.\d+\.\d+", latest or "")) and key(latest) > key(installed or "")


PENDING_FILE = "/var/lib/lnd-update.pending"


def read_pending():
    """(tag, "waiting"|"boot") from lnd-update's note, read at every refresh, or None."""
    try:
        with open(PENDING_FILE, encoding="utf-8", errors="replace") as f:
            parts = f.read(200).split()
    except OSError:
        return None
    if len(parts) >= 2 and parts[1] in ("waiting", "boot") and re.fullmatch(r"v\d+\.\d+\.\d+", parts[0]):
        return parts[0], parts[1]
    return None


def update_lines():
    found = UPDATES.found
    out = []
    pending = read_pending()
    if pending:
        tag, state = pending
        if state == "boot":
            out.append((_("Update waiting: %s is installed at the next boot (not safe for 24 hours)") % tag, "warn"))
        else:
            out.append((_("Update waiting: %s, installed once it is safe (no backup or wallet operation running)") % tag, "warn"))
    elif "scripts" in found and release_newer(*found["scripts"]):
        installed, latest = found["scripts"]
        out.append((_("Update: these scripts %s are out (installed: %s). /update") % (latest, installed), "warn"))
    return out


def collect(config):
    """Everything the screen shows, plus the list of problems."""
    now = time.time()
    status = read_status(config.get("STATUS_FILE", ""))
    service = read_service(config["RSYNC_BACKUP_SERVICE_NAME"])
    log_lines, log_error = read_log(config.get("LIGHTNING_BACKUP_LOG_FILE", ""),
                                    config["RSYNC_BACKUP_SERVICE_NAME"])
    problems = []

    state = service.get("ActiveState", "unknown")
    if state != "active":
        problems.append(_("Service is %s (%s)") % (_(state), _(service.get("Result", "?"))))
    elif service.get("SubState") not in ("running", None):
        problems.append(_("Service is %s") % _(service.get("SubState")))
    try:
        restarts = int(service.get("NRestarts", "0"))
    except ValueError:
        restarts = 0
    if restarts:
        problems.append(_("Service restarted %d time(s) since it was started") % restarts)

    if status is None:
        if config.get("STATUS_FILE"):
            problems.append(_("No status file at %s (rerun rsync_gpg_backup.sh, then wait for the "
                            "service to start)") % config["STATUS_FILE"])
        else:
            problems.append(_("STATUS_FILE is empty in config, so the service writes no status"))
        status = {}

    rows = []
    for label, ok_key, fail_key, pending_key, setting in BACKUP_ROWS:
        # A destination that is off has no row
        if setting and not destination_on(config, setting):
            continue
        ok, fail = num(status, ok_key), num(status, fail_key)
        pending = num(status, pending_key) if pending_key else None
        if fail is not None and (ok is None or fail > ok):
            state_ = "fail"
        elif pending is not None:
            state_ = "pending"
        elif ok is not None:
            state_ = "ok"
        else:
            state_ = "never"
        rows.append((label, ok, fail, pending, state_))
        if pending is not None and now - pending > PENDING_LATE_SECONDS:
            problems.append(_("%s: retry pending for %s") % (_(label), fmt_age(now - pending)))

    backup_fail, backup_ok = num(status, "backup_last_fail"), num(status, "backup_last_ok")
    if backup_fail is not None and (backup_ok is None or backup_fail > backup_ok):
        cause = status.get("backup_last_error", "")
        problems.append(_("Last backup failed %s%s") % (fmt_time(backup_fail, now),
                                                     (": " + cause) if cause else ""))

    event = num(status, "last_event_time")
    job = status.get("job", "")
    if (event is not None and (backup_ok is None or event > backup_ok)
            and now - event > BACKUP_LATE_SECONDS and not job.startswith("backup")):
        problems.append(_("Files changed %s ago and no backup has succeeded since")
                        % fmt_age(now - event))

    local_ok, remote_ok = num(status, "local_last_ok"), num(status, "remote_last_ok")
    if (destination_on(config, "BACKUP_TO_VOLUME") and destination_on(config, "BACKUP_TO_SERVER_B")
            and local_ok is not None and (remote_ok is None or local_ok - remote_ok > REMOTE_BEHIND_SECONDS)):
        problems.append(_("Server B is behind: its last copy is older than the attached volume's"))
    if status.get("foreign_backup_name"):
        problems.append(_("Server B has a backup this server didn't send (%s): another LND with this seed may "
                          "be running. Two nodes with the same channels can lose all the funds in them: stop "
                          "the other one now (/foreign ok once you know it is safe)") % status["foreign_backup_name"][:80])
    # Set again by each refused upload (the hourly retry too): shown while that goes on
    clock_ahead = num(status, "remote_clock_ahead")
    if clock_ahead is not None and now - clock_ahead < 7200 and destination_on(config, "BACKUP_TO_SERVER_B"):
        problems.append(_("Server B refuses the backups as dated in the future: this server's clock is ahead of "
                          "Server B's. Check the time on both (timedatectl)"))
    expires = num(status, "gpg_key_expires")
    if expires is not None and expires - now < 30 * 86400:
        day = datetime.datetime.fromtimestamp(expires).strftime("%Y-%m-%d")
        fix = "sudo -u %s gpg --quick-set-expire %s 0" % (config.get("SERVER_A_USER") or "?",
                                                         config.get("GPG_FINGERPRINT") or "?")
        if expires <= now:
            problems.append(_("The backup GPG key expired on %s: no new backup can be made. Remove the expiry: "
                              "%s (then again with '*' at the end)") % (day, fix))
        else:
            problems.append(_("The backup GPG key expires on %s: from then no backup can be made. Remove the "
                              "expiry: %s (then again with '*' at the end)") % (day, fix))
    if not destination_on(config, "BACKUP_TO_SERVER_B") and not destination_on(config, "BACKUP_TO_GITHUB"):
        problems.append(_("No copy leaves this server (only the attached volume is on): /destinations"))

    started = num(status, "service_started")
    check = num(status, "check_last_run")
    if state == "active" and started is not None and now - started > CHECK_LATE_SECONDS:
        if check is None or now - check > CHECK_LATE_SECONDS:
            problems.append(_("The hourly check hasn't run for %s")
                            % fmt_age(now - (check or started)))

    errors = []
    for line in log_lines:
        if "❌" in line:
            ts = log_line_time(line)
            if ts is not None and now - ts <= ERROR_WINDOW_SECONDS:
                errors.append(line)
    if not errors and status.get("last_error"):
        last = num(status, "last_error_time")
        if last is not None and now - last <= ERROR_WINDOW_SECONDS:
            errors.append("[%s] %s" % (datetime.datetime.fromtimestamp(last).isoformat(" ", "seconds"),
                                       status["last_error"]))

    return {
        "now": now, "status": status, "service": service, "rows": rows, "problems": problems,
        "checklist": checklist(config, status, service),
        "wallet": read_wallet_running(),
        "errors": errors, "log": [line for line in log_lines if not is_noise(line)],
        "log_error": log_error,
    }


def service_text(info):
    service = info["service"]
    text = "%s/%s" % (_(service.get("ActiveState", "unknown")), _(service.get("SubState", "?")))
    if "uptime" in service:
        text += _(" for %s") % fmt_age(service["uptime"])
    text += _(", restarts: %s") % service.get("NRestarts", "?")
    return text


def summary_lines(info):
    """The top part of the screen as (text, style) pairs; style is ok/warn/fail/dim/head/None."""
    now, status = info["now"], info["status"]
    service_state = info["service"].get("ActiveState")
    out = []
    todo = [step for step in info["checklist"] if step[0] == "todo"]
    if todo:
        required = [step for step in info["checklist"] if not step[3]]
        out.append((_("Setup: %d of %d steps done. Next: %s (/checklist)")
                    % (len(required) - len(todo), len(required), todo[0][1]), "warn"))
    out.extend(update_lines())
    out.append((_("Service: ") + service_text(info), "ok" if service_state == "active" else "fail"))
    if info.get("wallet"):
        option, started, in_tmux = info["wallet"]
        where = _("/wallet attach to go back to it") if in_tmux else _("in another terminal (not in tmux)")
        out.append((_("Wallet operation running: %s, since %s, %s")
                    % (option, fmt_time(started, now), where), "warn"))

    job = status.get("job")
    if job:
        since = num(status, "job_since")
        out.append((_("Job: %s%s") % (_(job), _(", since ") + fmt_time(since, now) if since else ""),
                    None if job in ("idle", "stopped") else "warn"))
    event = num(status, "last_event_time")
    if event is not None:
        out.append((_("Last file change: %s  %s") % (os.path.basename(status.get("last_event_file", "")),
                                                  fmt_time(event, now)), None))
    else:
        out.append((_("Last file change: none since the status file was created"), "dim"))

    out.append(("", None))
    # The table's columns are as wide as their longest text in the language shown (at least the
    # English widths, 22 and 32), so longer translations stay in line
    check = num(status, "check_last_run")
    cells = [(_("Backups"), _("Last success"), _("Last failure"), "head", None)]
    for label, ok, fail, pending, state in info["rows"]:
        # A label as a row's first word: capitalized, even where a language writes the same
        # words in lowercase inside sentences ("Server B" in French)
        name = _(label)
        cells.append((name[:1].upper() + name[1:], fmt_time(ok, now), fmt_time(fail, now) if fail else "-",
                      {"ok": "ok", "fail": "fail", "pending": "warn", "never": "dim"}[state], pending))
    cells.append((_("Hourly check"), fmt_time(check, now), status.get("check_last_result", ""),
                  None if check else "dim", None))
    first = max([22] + [len(c[0]) + 1 for c in cells])
    second = max([32] + [len(c[1]) + 1 for c in cells])
    for name, when, last, style, pending in cells:
        line = "%-*s %-*s %s" % (first, name, second, when, last)
        if pending is not None:
            line += _("   retry pending since %s") % fmt_time(pending, now)
        out.append((line, style))

    out.append(("", None))
    out.append((_("Problems"), "head"))
    if info["problems"]:
        out.extend(("  " + p, "fail") for p in info["problems"])
    else:
        out.append((_("  none"), "ok"))
    out.append((_("Errors in the last 24h: %d") % len(info["errors"]), "head"))
    out.extend(("  " + e, "fail") for e in info["errors"][-3:])
    return out


def print_once(config):
    info = collect(config)
    for text, _style in summary_lines(info):
        print(clean(text))
    print(_("Log:"))
    if info["log_error"]:
        print("  " + clean(info["log_error"]))
    for line in info["log"][-10:]:
        print("  " + clean(line))
    return 1 if info["problems"] else 0


FOOTER_KEYS = N_(" / commands  s start/stop  r restart  c check now  l log  w wallet  q quit")


def run_outside(stdscr, command, wait, pause_on_fail=True, env=None):
    """Runs a command on the normal terminal, then returns to the dashboard. Waits for Enter
    when asked to, or when the command failed, so its output can be read. Returns the exit code."""
    curses.def_prog_mode()
    curses.endwin()
    print("\n$ " + " ".join(command), flush=True)
    try:
        code = subprocess.call(command, env=env)
    except KeyboardInterrupt:
        code = 130
    except OSError as e:
        print(_("Could not run it: %s") % e.strerror)
        code = 127
    if wait or (code != 0 and pause_on_fail):
        print(_("\nExit code %d. Press Enter to return to the dashboard.") % code, flush=True)
        try:
            input()
        except (EOFError, KeyboardInterrupt):
            pass
    curses.reset_prog_mode()
    stdscr.clear()
    return code


def ask(stdscr, question, styles):
    """y/N question on the footer row. A long question is cut so " (y/N) " always shows."""
    height, width = stdscr.getmaxyx()
    stdscr.move(height - 1, 0)
    stdscr.clrtoeol()
    question = clip(question, max(1, width - 1 - len(" (y/N) ")))
    put(stdscr, height - 1, question + " (y/N) ", styles["warn"] | curses.A_REVERSE, footer=True)
    stdscr.timeout(-1)
    key = stdscr.getch()
    stdscr.timeout(REFRESH_SECONDS * 1000)
    return key in (ord("y"), ord("Y"))


def shown(command):
    """A command as shown in questions: the scripts' folder left out, so it fits on a line."""
    return " ".join(os.path.basename(part) if part.startswith(SCRIPT_DIR + os.sep) else part
                    for part in command)


def do_action(stdscr, action, config, info, styles):
    """Runs an action from COMMANDS or SHORTCUTS. Returns a message for the footer."""
    service = config["RSYNC_BACKUP_SERVICE_NAME"]
    active = info["service"].get("ActiveState") == "active"
    script = lambda name: os.path.join(SCRIPT_DIR, name)

    if action == "start/stop":
        action = "stop" if active else "start"
    if action in ("start", "stop", "restart"):
        command = ["sudo", "systemctl", action, service]
    elif action == "check":
        if not active:
            return _("The service isn't running, so there is no check to run")
        # Only the main process: SIGUSR1 to every process would kill rsync and inotifywait
        command = ["sudo", "systemctl", "kill", "-s", "SIGUSR1", "--kill-whom=main", service]
    elif action == "log":
        log = config.get("LIGHTNING_BACKUP_LOG_FILE", "")
        # LESS emptied: with -R (often set by users) less would pass escape codes in the log,
        # which can carry text from Server B, straight to the terminal
        env = dict(os.environ, LESS="", SYSTEMD_LESS="FXMK")
        if log and os.access(log, os.R_OK):
            command = ["less", "+G", log]
        else:
            command = ["journalctl", "-u", service, "-e"]
        run_outside(stdscr, command, wait=False, env=env)
        return _("Back from the log")
    elif action == "setup":
        # From the working folder: setup saves its answers into config there, then installs
        # the root-owned copies this dashboard runs
        working = config.get("BACKUP_SCRIPTS_FOLDER", "")
        if not working or not os.path.isfile(os.path.join(working, "setup_script.sh")):
            return _("setup_script.sh not found in BACKUP_SCRIPTS_FOLDER (%s)") % (working or _("not set"))
        command = [os.path.join(working, "setup_script.sh")]
    elif action == "serverb scripts":
        working = config.get("BACKUP_SCRIPTS_FOLDER", "")
        if not working or not os.path.isfile(os.path.join(working, "serverb-scripts.sh")):
            return _("serverb-scripts.sh not found in BACKUP_SCRIPTS_FOLDER (%s)") % (working or _("not set"))
        command = [os.path.join(working, "serverb-scripts.sh")]
    elif action == "destinations" or action.startswith("destination "):
        working = config.get("BACKUP_SCRIPTS_FOLDER", "")
        if not working or not os.path.isfile(os.path.join(working, "destinations.sh")):
            return _("destinations.sh not found in BACKUP_SCRIPTS_FOLDER (%s)") % (working or _("not set"))
        command = [os.path.join(working, "destinations.sh")]
        if action != "destinations":
            command.append(action.split(" ", 1)[1])
    elif action == "foreign ok":
        name = (read_status(config.get("STATUS_FILE", "")) or {}).get("foreign_backup_name", "")
        user, metadata = config.get("SERVER_A_USER", ""), config.get("BACKUP_METADATA_FOLDER", "")
        if not re.fullmatch(r"encrypted_backup_[0-9T:+-]+\.gpg", name):
            return _("No backup from elsewhere is shown, so there is nothing to accept")
        if not user or not metadata:
            return _("SERVER_A_USER or BACKUP_METADATA_FOLDER is empty in config")
        # As the backup user, whose folder it is; the name goes in as data, never through a shell
        command = ["sudo", "-u", user, "--", "sh", "-c", 'printf "%s\\n" "$1" >> "$2"', "_", name,
                   os.path.join(metadata, "foreign_backups_ok")]
    elif action == "serverb send":
        working = config.get("BACKUP_SCRIPTS_FOLDER", "")
        if not working or not os.path.isfile(os.path.join(working, "serverb-scripts.sh")):
            return _("serverb-scripts.sh not found in BACKUP_SCRIPTS_FOLDER (%s)") % (working or _("not set"))
        command = [os.path.join(working, "serverb-scripts.sh"), "send"]
    elif action == "update":
        command = ["sudo", UPDATE_TOOL]
    elif action == "install":
        command = [script("rsync_gpg_backup.sh")]
    elif action == "support":
        show_page(stdscr, _("Support"), support_lines(config), styles)
        return None
    elif action == "checklist":
        show_page(stdscr, _("Checklist"), checklist_lines(info["checklist"]), styles)
        return None
    elif action in ("chain prune", "chain copy", "tower status"):
        verb = {"chain prune": "prune", "chain copy": "copy", "tower status": "tower-status"}[action]
        command = ["sudo", script("chain-tower.sh"), verb, "--pause"]
    elif action == "tower add":
        working = config.get("BACKUP_SCRIPTS_FOLDER", "")
        if not working or not os.path.isfile(os.path.join(working, "serverb-scripts.sh")):
            return _("serverb-scripts.sh not found in BACKUP_SCRIPTS_FOLDER (%s)") % (working or _("not set"))
        command = [os.path.join(working, "serverb-scripts.sh"), "tower-client"]
    elif action == "chain attach":
        command = ["sudo", "tmux", "-S", WALLET_TMUX_SOCKET, "attach-session", "-t", "=lnd-chain"]
    elif action == "wallet attach":
        if not info.get("wallet"):
            return _("No wallet operation is running")
        if not info["wallet"][2]:
            return _("The wallet operation runs in another terminal, not in tmux: nothing to attach to")
        command = ["sudo", "tmux", "-S", WALLET_TMUX_SOCKET, "attach-session", "-t",
                   "=" + WALLET_TMUX_SESSION]
    elif action.startswith("wallet "):
        if info.get("wallet"):
            return _("A wallet operation is already running: wait for it, or /wallet attach")
        # --pause: the script waits for Enter at the end, so its last messages can be read
        command = ["sudo", script("lnd-wallet.sh"), action.split(" ", 1)[1], "--pause"]
    else:
        return None

    if not ask(stdscr, _("Run: ") + shown(command) + " ?", styles):
        return _("Cancelled")
    is_script = (action in ("setup", "install", "serverb scripts", "serverb send", "update", "destinations")
                 or action.startswith("destination "))
    # chain-tower.sh, like lnd-wallet.sh, waits for Enter itself and uses the same exit codes
    is_wallet = action.startswith("wallet ") or action in ("chain prune", "chain copy", "tower add",
                                                           "tower status", "chain attach")
    # lnd-wallet.sh waits for Enter itself (--pause, or its tmux session); tmux attach doesn't
    code = run_outside(stdscr, command, wait=is_script,
                       pause_on_fail=not is_wallet or action in ("wallet attach", "chain attach", "tower add"))
    name = shown(command[1:] if command[0] == "sudo" else command)
    if action == "update":
        UPDATES.start(force=True)
    if action == "foreign ok" and code == 0:
        # The warning goes with the next check: run it now
        if active:
            subprocess.run(["sudo", "-n", "systemctl", "kill", "-s", "SIGUSR1", "--kill-whom=main", service],
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return _("✅ Accepted %s: the warning goes with the next check") % command[-2]
    if code == 0:
        return _("✅ %s: done") % name
    if is_wallet and code == WALLET_STILL_RUNNING:
        return _("⚠️ %s: still running in tmux. /%s attach to go back to it") % (
            name, "wallet" if action.startswith("wallet ") else "chain")
    if is_wallet and code == WALLET_NOT_STARTED:
        return _("⚠️ %s: not started, an earlier wallet operation was still open") % name
    return _("❌ %s: exit code %d") % (name, code)


def support_lines(config):
    """The /support page. The address and page come from config, shown as typed there."""
    address = config.get("SUPPORT_BTC_ADDRESS") or _("(placeholder: SUPPORT_BTC_ADDRESS in config)")
    url = config.get("SUPPORT_URL") or _("(placeholder: SUPPORT_URL in config)")
    return [
        ("btcpay-docker-lnd-manager", "head"),
        ("", None),
        (_("If it keeps your node safe, please support its development:"), None),
        (_("  Bitcoin:  ") + address, "ok"),
        (_("  Project:  ") + url, None),
        ("", None),
        (_("License (the full text is in LICENSE, next to the scripts)"), "head"),
        (_("  Free for personal and business use up to USD 1,000,000 annual sales income."), None),
        (_("  Above that: a one-time USD 50 payment in bitcoin to the donation address."), None),
        (_("  Used in another commercial node service or tool: a one-time USD 500 payment."), None),
        (_("  A commercial user that doesn't pay agrees to pay 10 percent of those sales instead."), None),
        (_("  Keep your bitcoin payment receipt (transaction ID) as proof."), None),
        ("", None),
        (_("No warranty: use it at your own risk."), "dim"),
    ]


def show_page(stdscr, title, lines, styles):
    """A full-screen text page; Up/Down/PgUp/PgDn scroll, q, Esc or Enter go back."""
    top = 0
    stdscr.timeout(-1)
    try:
        while True:
            stdscr.erase()
            height, width = stdscr.getmaxyx()
            put(stdscr, 0, " " + title + " " * width, curses.A_REVERSE)
            room = max(1, height - 2)
            top = max(0, min(top, len(lines) - room))
            for i, (text, style) in enumerate(lines[top:top + room]):
                put(stdscr, 1 + i, " " + text, styles[style])
            put(stdscr, height - 1, _(" q back   Up/Down scroll") + " " * width, curses.A_REVERSE,
                footer=True)
            stdscr.refresh()
            key = stdscr.getch()
            if key in (ord("q"), ord("Q"), 27, 10, 13, curses.KEY_ENTER):
                return
            if key == curses.KEY_UP:
                top -= 1
            elif key == curses.KEY_DOWN:
                top += 1
            elif key == curses.KEY_PPAGE:
                top -= room
            elif key == curses.KEY_NPAGE:
                top += room
    finally:
        stdscr.timeout(REFRESH_SECONDS * 1000)


def matching_commands(text):
    """The commands whose name holds every word typed after the slash."""
    words = text.lower().split()
    return [c for c in COMMANDS if all(w in c[0] for w in words)]


def run_dashboard(stdscr, config):
    cursor(0)
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

    message, message_until = "", 0
    palette = None  # the / command line while it is open: {"text": typed, "sel": highlighted}
    # The status is read every REFRESH_SECONDS and after each action, not on every key, so typing
    # in the command list doesn't lag (reading it takes a moment on a busy server)
    info, read_at = None, 0.0
    while True:
        UPDATES.start()
        if info is None or time.time() - read_at >= REFRESH_SECONDS:
            info, read_at = collect(config), time.time()
        footer = message if time.time() < message_until else _(FOOTER_KEYS)
        draw(stdscr, info, styles, footer, palette)
        key = stdscr.getch()
        if key == -1:
            continue
        action = None

        if palette is not None:
            matches = matching_commands(palette["text"])
            if key == 27:  # Esc
                palette = None
            elif key in (curses.KEY_BACKSPACE, 127, 8):
                if palette["text"]:
                    palette["text"] = palette["text"][:-1]
                    palette["sel"] = 0
                else:
                    palette = None
            elif key == curses.KEY_UP:
                palette["sel"] = max(0, palette["sel"] - 1)
            elif key == curses.KEY_DOWN:
                palette["sel"] = min(max(0, len(matches) - 1), palette["sel"] + 1)
            elif key == 9:  # Tab completes to the highlighted command
                if matches:
                    palette["text"] = matches[min(palette["sel"], len(matches) - 1)][0][1:]
                    palette["sel"] = 0
            elif key in (10, 13, curses.KEY_ENTER):
                if matches:
                    action = matches[min(palette["sel"], len(matches) - 1)][2]
                palette = None
            elif 32 <= key < 127:
                palette["text"] += chr(key)
                palette["sel"] = 0
        elif key == ord("/"):
            palette = {"text": "", "sel": 0}
        elif key in (ord("w"), ord("W")):
            palette = {"text": "wallet ", "sel": 0}
        elif key in (ord("q"), ord("Q")):
            return
        elif 0 <= key < 256:
            action = SHORTCUTS.get(chr(key).lower())

        if action == "quit":
            return
        if action:
            result = do_action(stdscr, action, config, info, styles)
            if result:
                message, message_until = " " + result, time.time() + 10
            info = None


def cursor(visible):
    """Shows or hides the cursor; some terminals (vt100, some web consoles) can't, which is fine."""
    try:
        curses.curs_set(visible)
    except curses.error:
        pass


def clean(text):
    """Text safe to show: control characters (escape codes among them, which could change the
    terminal) and invisible format characters (which can reorder a line on screen, such as
    right-to-left marks) become "?", tabs become spaces. Log lines and status values can hold
    anything."""
    return "".join(" " if ch == "\t" else "?" if unicodedata.category(ch) in ("Cc", "Cf") else ch
                   for ch in text)


def clip(text, width):
    """Cuts text to a number of terminal columns. Emoji and other wide characters take two,
    combining marks and variation selectors none, so counting characters would overflow.
    Control characters are replaced first (see clean)."""
    text = clean(text)
    out, used = [], 0
    for i, ch in enumerate(text):
        if unicodedata.combining(ch) or unicodedata.category(ch) in ("Mn", "Me", "Cf"):
            cols = 0
        elif (unicodedata.east_asian_width(ch) in ("W", "F")
              or text[i + 1:i + 2] == "\ufe0f"):  # e.g. 🗑️: emoji presentation is two wide
            cols = 2
        else:
            cols = 1
        if used + cols > width:
            break
        out.append(ch)
        used += cols
    return "".join(out)


def put(stdscr, y, text, attr=curses.A_NORMAL, footer=False):
    """Writes one line. Only the footer may use the last row."""
    height, width = stdscr.getmaxyx()
    last = height - 1 if footer else height - 2
    if 0 <= y <= last:
        try:
            stdscr.addstr(y, 0, clip(text, width - 1), attr)
        except curses.error:
            pass


def draw(stdscr, info, styles, footer, palette=None):
    stdscr.erase()
    height, width = stdscr.getmaxyx()
    title = " btcpay-docker-lnd-manager"
    clock = time.strftime("%Y-%m-%d %H:%M:%S ")
    put(stdscr, 0, title + " " * max(1, width - len(title) - len(clock) - 1) + clock,
        curses.A_REVERSE)

    y = 1
    for text, style in summary_lines(info):
        put(stdscr, y, text, styles[style])
        y += 1

    put(stdscr, y, _("Log"), styles["head"])
    y += 1
    room = height - y - 1
    if info["log_error"]:
        put(stdscr, y, "  " + info["log_error"], styles["warn"])
    elif room > 0:
        for line in info["log"][-room:]:
            put(stdscr, y, line, styles["fail"] if "❌" in line else styles[None])
            y += 1

    if palette is None:
        put(stdscr, height - 1, footer + " " * width, curses.A_REVERSE, footer=True)
        cursor(0)
    else:
        draw_palette(stdscr, palette, styles)
    stdscr.refresh()


def wrap(text, width):
    """Splits text into lines of at most width columns, at spaces."""
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


def draw_palette(stdscr, palette, styles):
    """The / command line on the last row, the matching commands above it, and under them the
    details of the highlighted command."""
    height, width = stdscr.getmaxyx()
    matches = matching_commands(palette["text"])
    sel = min(palette["sel"], max(0, len(matches) - 1))
    details = wrap(_(matches[sel][3]), max(10, width - 4)) if matches else []
    # The details get room first (they say what the command stops or deletes), the list the rest
    detail_rows = min(len(details), max(0, height - 4))
    room = max(0, height - 2 - (detail_rows + 1 if detail_rows else 0))
    shown_rows = min(len(matches), room)
    top = height - 1 - shown_rows - (detail_rows + 1 if detail_rows else 0)
    name_width = max([len(c[0]) for c in COMMANDS] + [0]) + 1
    # Keep the highlighted command in view when the list is longer than the room
    first = max(0, sel - shown_rows + 1)
    for row, (name, description, _action, _details) in enumerate(matches[first:first + shown_rows]):
        attr = curses.A_REVERSE if first + row == sel else curses.A_NORMAL
        stdscr.move(top + row, 0)
        stdscr.clrtoeol()
        put(stdscr, top + row, " %-*s %s" % (name_width, name, _(description)), attr)
    if detail_rows:
        y = top + shown_rows
        stdscr.move(y, 0)
        stdscr.clrtoeol()
        put(stdscr, y, " " + "─" * max(0, width - 3), styles["dim"])
        for i, text in enumerate(details[:detail_rows]):
            stdscr.move(y + 1 + i, 0)
            stdscr.clrtoeol()
            put(stdscr, y + 1 + i, "   " + text, styles["warn"] if "Stops BTCPay" in matches[sel][3] else styles[None])
    if not matches:
        stdscr.move(height - 2, 0)
        stdscr.clrtoeol()
        put(stdscr, height - 2, _(" no matching command"), styles["dim"])
    line = "/ " + palette["text"]
    stdscr.move(height - 1, 0)
    stdscr.clrtoeol()
    put(stdscr, height - 1, line, curses.A_BOLD, footer=True)
    try:
        cursor(1)
        stdscr.move(height - 1, min(len(line), width - 1))
    except curses.error:
        pass


def main():
    config = load_config()
    load_translations(config.get("UI_LANGUAGE", ""))
    if "--once" in sys.argv[1:]:
        sys.exit(print_once(config))
    if not sys.stdout.isatty():
        sys.exit(_("Not a terminal. Use --once for a text status."))
    # Esc closes the command list without curses' default 1 s wait. Not shorter: over a slow SSH
    # link the bytes of an arrow key can arrive a little apart and would be read as Esc.
    os.environ.setdefault("ESCDELAY", "100")
    try:
        curses.wrapper(run_dashboard, config)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
