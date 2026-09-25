#!/usr/bin/env python3
"""Regenerate the README/demo screenshots from real CLI output.

Runs bin/sciebo against a throwaway sandbox: a temporary HOME, a temporary
`local` rclone remote for sync commands, and a temporary `webdav` remote so
`doctor --offline` can validate a realistic config. Nothing outside the
sandbox (and docs/assets/screenshots/) is touched; no network is used.

Rendered SVGs are plain text on a dark window frame, safe for GitHub.

Usage:
  tools/screenshots.py [--out DIR] [--only NAME...]

Requires python3 and rclone on PATH.
"""

import argparse
import os
import pty
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(REPO, "bin", "sciebo")
RCLONE = shutil.which("rclone") or "/opt/homebrew/bin/rclone"
# The first bash on PATH, like the Makefile: macOS /bin/bash is 3.2 and the
# CLI needs 5.3+.
BASH = shutil.which("bash") or "/bin/bash"
MONO = "ui-monospace, SFMono-Regular, Menlo, Consolas, Liberation Mono, monospace"

# ---------------------------------------------------------------------------
# Sandbox
# ---------------------------------------------------------------------------


def sh(cmd, env=None, cwd=None, check=True):
    return subprocess.run(
        cmd, env=env, cwd=cwd, check=check, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
    )


def build_sandbox():
    root = tempfile.mkdtemp(prefix="sciebo-demo.")
    home = os.path.join(root, "home")
    os.makedirs(os.path.join(home, ".config", "rclone"))
    os.makedirs(os.path.join(root, "filters"))
    os.makedirs(os.path.join(root, "state"))

    sync_conf = os.path.join(home, ".config", "rclone", "rclone.conf")
    doctor_conf = os.path.join(root, "doctor-rclone.conf")
    sh([RCLONE, "config", "create", "sciebo", "local", "--config", sync_conf])
    obscured = sh([RCLONE, "obscure", "demo-app-password"]).stdout.decode().strip()
    sh([
        RCLONE, "config", "create", "sciebo", "webdav",
        "url=https://demo.sciebo.de/remote.php/dav/files/demo/",
        "vendor=nextcloud", "user=demo@uni-demo.de", "pass=" + obscured,
        "--config", doctor_conf,
    ])

    # Remote tree. With the `local` backend, remote paths resolve relative
    # to rclone's working directory, so commands run from root/remote.
    remote = os.path.join(root, "remote")
    write(os.path.join(remote, "backup", "repos", "website", "index.html"), "<h1>site</h1>\n")
    write(os.path.join(remote, "backup", "repos", "website", "assets", "style.css"), "body{}\n")
    write(os.path.join(remote, "backup", "repos", "thesis", "chapter1.tex"), "% chapter 1\n")
    write(os.path.join(remote, "backup", "notes", "todo.md"), "- [ ] demo\n")
    write(os.path.join(remote, "backup", "shared", "review.pdf"), "pdf\n")
    os.makedirs(os.path.join(remote, "backup", "papers"), exist_ok=True)
    os.makedirs(os.path.join(remote, "backup", "photos", "raw"), exist_ok=True)

    # Local tree.
    write(os.path.join(home, "Projects", "website", ".git", "HEAD"), "ref: refs/heads/main\n")
    write(os.path.join(home, "Projects", "website", "index.html"), "<h1>site</h1>\n")
    write(os.path.join(home, "Projects", "website", ".DS_Store"), "junk\n")
    os.makedirs(os.path.join(home, "Projects", "website", "tmp"), exist_ok=True)
    write(os.path.join(home, "Projects", "website", "tmp", ".nosync"), "")
    write(os.path.join(home, "Projects", "website", "tmp", "scratch.txt"), "scratch\n")
    write(os.path.join(home, "Projects", "thesis", ".git", "HEAD"), "ref: refs/heads/main\n")
    write(os.path.join(home, "Projects", "thesis", "chapter1.tex"), "% chapter 1\n")
    write(os.path.join(home, "Notes", "todo.md"), "- [ ] demo\n")
    write(os.path.join(home, "Downloads", "shared", "review.pdf"), "pdf\n")

    # A committed defaults snapshot keeps screenshots independent of any
    # local settings.local.env.
    shutil.copy(os.path.join(REPO, "config", "settings.env"), os.path.join(root, "settings.env"))
    # A cached capabilities probe so `doctor --offline` has server facts to
    # report; a real online run caches this itself.
    write(os.path.join(root, "state", "capabilities.env"), (
        "CAP_VERSION=30.0.5\n"
        "CAP_BIGFILE_CHUNKING=true\n"
        "CAP_CHUNK_MAX_SIZE=10485760\n"
        "CAP_UNDELETE=true\n"
        "CAP_CHECKSUMS=true\n"
        "CAP_PROBED_AT=%d\n" % int(time.time())
    ))
    shutil.copy(
        os.path.join(REPO, "config", "filters", "clutter.txt"),
        os.path.join(root, "filters", "clutter.txt"),
    )
    write(os.path.join(root, "no-local.env"), "")
    write(os.path.join(root, "no-env.env"), "")
    write(os.path.join(root, "sources.conf"), (
        "# Sources to sync to sciebo.\n"
        "sync|~/Projects/website|repos/website\n"
        "sync|~/Projects/thesis|repos/thesis\n"
        "bisync|~/Notes|notes\n"
        "pull|~/Downloads/shared|shared\n"
    ))
    write(os.path.join(root, "folders.conf"), "# Folders chosen with the folder wizard (sciebo folders).\n")
    write(os.path.join(root, "roots.conf"), "# Roots for automatic git-repository discovery.\n")
    return {
        "root": root,
        "home": home,
        "remote": remote,
        "sync_conf": sync_conf,
        "doctor_conf": doctor_conf,
        "settings": os.path.join(root, "settings.env"),
    }


def write(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(content)


def base_env(box, *, doctor=False):
    env = dict(os.environ)
    env.update({
        "HOME": box["home"],
        "SETTINGS_FILE": box["settings"],
        "SETTINGS_LOCAL_FILE": os.path.join(box["root"], "no-local.env"),
        "ENV_FILE": os.path.join(box["root"], "no-env.env"),
        "RCLONE_REMOTE": "sciebo",
        "RCLONE_CONFIG": box["doctor_conf"] if doctor else box["sync_conf"],
        "REMOTE_BASE": "backup",
        "STATE_DIR": os.path.join(box["root"], "state"),
        "MANIFEST_FILE": os.path.join(box["root"], "sources.conf"),
        "MANIFEST_GENERATED_FILE": os.path.join(box["root"], "sources.generated.conf"),
        "ROOTS_FILE": os.path.join(box["root"], "roots.conf"),
        "FOLDERS_FILE": os.path.join(box["root"], "folders.conf"),
        "FILTER_DIR": os.path.join(box["root"], "filters"),
        # Keep the sandbox away from the real Keychain and Notification Center.
        "KEYCHAIN": "0",
        "NOTIFY": "0",
        "TRANSFERS": "1",
        "RETRIES": "1",
        "LOW_LEVEL_RETRIES": "1",
        "TIMEOUT": "10s",
        "CONTIMEOUT": "1s",
    })
    env.pop("TMPDIR", None)
    return env


def run_cli(box, argv, *, doctor=False, cwd=None, check=False):
    env = base_env(box, doctor=doctor)
    return subprocess.run(
        [BASH, CLI] + argv,
        cwd=cwd or box["remote"],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=check,
    ).stdout.decode("utf-8", "replace")


def run_cli_pty(box, argv, answers, *, timeout=90):
    """Run the CLI on a pty so typed answers are echoed like a real session.

    `answers` is a list of (regex_to_wait_for, text_to_send) pairs; after the
    last answer the process is drained until EOF.
    """
    env = base_env(box)
    master, slave = pty.openpty()
    proc = subprocess.Popen(
        [BASH, CLI] + argv,
        cwd=box["remote"],
        env=env,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        close_fds=True,
    )
    os.close(slave)
    out = bytearray()
    deadline = time.time() + timeout
    matched = 0
    try:
        for pattern, answer in answers:
            rx = re.compile(pattern.encode())
            while not rx.search(out):
                if time.time() > deadline or not read_chunk(master, out, 0.2):
                    if proc.poll() is not None:
                        break
            if not rx.search(out):
                raise RuntimeError("prompt never appeared: %s" % pattern)
            matched += 1
            drain(master, out, 0.1)
            os.write(master, answer.encode())
            time.sleep(0.1)
        while time.time() < deadline:
            if not read_chunk(master, out, 0.2) and proc.poll() is not None:
                break
    finally:
        if proc.poll() is None:
            proc.terminate()
        rc = proc.wait(timeout=10)
        os.close(master)
    if matched != len(answers):
        raise RuntimeError("answered %d of %d prompts" % (matched, len(answers)))
    if rc != 0:
        raise RuntimeError("interactive run exited %d:\n%s" % (rc, out.decode("utf-8", "replace")))
    return out.decode("utf-8", "replace")


def drain(fd, out, idle):
    """Read until the child has been quiet for `idle` seconds."""
    while read_chunk(fd, out, idle):
        pass


def read_chunk(fd, out, timeout):
    ready, _, _ = select.select([fd], [], [], timeout)
    if not ready:
        return False
    try:
        chunk = os.read(fd, 65536)
    except OSError:
        return False
    if not chunk:
        return False
    out.extend(chunk)
    return True


# ---------------------------------------------------------------------------
# Transcripts
# ---------------------------------------------------------------------------


def display_text(text, box):
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    # Demo-only path normalization so screenshots read like a normal setup.
    text = text.replace(box["doctor_conf"], "~/.config/rclone/rclone.conf")
    text = text.replace(box["sync_conf"], "~/.config/rclone/rclone.conf")
    text = text.replace(box["home"], "~")
    text = text.replace(box["root"], "~/sciebo-demo")
    return text.rstrip("\n")


def make_transcripts(box):
    shots = []

    def command(label, output, note=None):
        text = "$ %s\n%s" % (label, output)
        shots.append({"name": note or label.split()[1], "title": label, "text": display_text(text, box)})

    command("bin/sciebo help", run_cli(box, ["help"]))

    # First bisync initialization, then the quiet parts of the tour.
    run_cli(box, ["sync", "--resync", "--apply", "--only", "notes", "--quiet"], check=True)

    command("bin/sciebo doctor --offline", run_cli(box, ["doctor", "--offline"], doctor=True))
    command("bin/sciebo list", run_cli(box, ["list"]))
    command("bin/sciebo check", run_cli(box, ["check"]))

    # Make the apply screenshot show a real (sandboxed) transfer.
    write(os.path.join(box["home"], "Projects", "website", "about.html"), "<h1>about</h1>\n")
    command("bin/sciebo sync", run_cli(box, ["sync"]))
    command("bin/sciebo status", run_cli(box, ["status"]))

    wizard = run_cli_pty(box, ["folders", "choose", "--no-fzf", "--depth", "2"], answers=[
        (r"Select folders \(e\.g\.", "2\n"),
        (r"Local path \[", "\n"),
        (r"Direction for 'photos'", "\n"),
        (r"Exclude subfolders of 'photos'\?", "y\n"),
        (r"Select subfolders to exclude", "1\n"),
        (r"Add these 1 pair\(s\)", "y\n"),
        (r"Run a dry run for the new pairs now\?", "n\n"),
    ])
    command("bin/sciebo folders choose", display_text(wizard, box), note="folders")

    return shots


# ---------------------------------------------------------------------------
# SVG rendering
# ---------------------------------------------------------------------------

FONT_SIZE = 14.0
CHAR_W = FONT_SIZE * 0.62
LINE_H = 21.0
PAD_X = 22.0
PAD_TOP = 16.0
PAD_BOTTOM = 22.0
TITLE_H = 36.0
MIN_COLS = 64

BG = "#0d1117"
BAR = "#161b22"
BORDER = "#30363d"
FG = "#c9d1d9"
DIM = "#8b949e"
GREEN = "#3fb950"
RED = "#f85149"
AMBER = "#d29922"
BLUE = "#58a6ff"
BRIGHT = "#f0f6fc"


def esc(text):
    return (
        text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    )


def line_colors(line):
    """Split a line into (prefix, prefix_color, rest, rest_color, bold)."""
    if line.startswith("$ "):
        return "$ ", GREEN, line[2:], BRIGHT, True
    for word, color in (("FAIL", RED), ("WARN", AMBER), ("PASS", GREEN), ("OK", GREEN), ("SKIP", DIM)):
        if line.startswith(word + " ") or line == word:
            return line[: len(word)], color, line[len(word):], FG, False
    ts = re.match(r"^(\[\d{4}-\d{2}-\d{2} [0-9:]+\])(.*)$", line)
    if ts:
        rest_color = FG
        if "ERROR" in ts.group(2):
            rest_color = RED
        elif "WARN" in ts.group(2):
            rest_color = AMBER
        return ts.group(1), DIM, ts.group(2), rest_color, False
    if line.startswith("Summary:"):
        return "", FG, line, BRIGHT, True
    if line.startswith(("reason:", "log:", "Note:", "Next:", "First run:")):
        return "", DIM, line, DIM, False
    if line.startswith("INVALID"):
        return "INVALID", RED, line[len("INVALID"):], FG, False
    return "", FG, line, FG, False


def render_svg(title, text, path):
    lines = text.split("\n")
    cols = max([len(line) for line in lines] + [MIN_COLS])
    width = PAD_X * 2 + cols * CHAR_W
    height = TITLE_H + PAD_TOP + len(lines) * LINE_H + PAD_BOTTOM

    parts = [
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
        'viewBox="0 0 %d %d" role="img" aria-label="%s">'
        % (round(width), round(height), round(width), round(height), esc(title)),
        "<title>%s</title>" % esc(title),
        "<defs><clipPath id=\"win\"><rect x=\"0.5\" y=\"0.5\" width=\"%d\" height=\"%d\" rx=\"10\"/>"
        "</clipPath></defs>" % (round(width) - 1, round(height) - 1),
        '<g clip-path="url(#win)">',
        '<rect x="0.5" y="0.5" width="%d" height="%d" rx="10" fill="%s" stroke="%s"/>'
        % (round(width) - 1, round(height) - 1, BG, BORDER),
        '<rect x="0.5" y="0.5" width="%d" height="%d" fill="%s"/>'
        % (round(width) - 1, TITLE_H, BAR),
        '<line x1="0.5" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s"/>'
        % (TITLE_H + 0.5, round(width) - 0.5, TITLE_H + 0.5, BORDER),
    ]
    for i, color in enumerate(("#ff5f56", "#ffbd2e", "#27c93f")):
        parts.append('<circle cx="%.1f" cy="18.5" r="6" fill="%s"/>' % (20 + i * 20, color))
    parts.append(
        '<text x="%.1f" y="23" text-anchor="middle" font-family="%s" font-size="12.5" '
        'fill="%s">%s</text>' % (round(width) / 2, MONO, DIM, esc(title))
    )

    font = 'font-family="%s" font-size="%.1f"' % (MONO, FONT_SIZE)
    y = TITLE_H + PAD_TOP + FONT_SIZE
    for line in lines:
        prefix, pcolor, rest, rcolor, bold = line_colors(line)
        weight = ' font-weight="600"' if bold else ""
        x = PAD_X
        if prefix:
            parts.append(
                '<text x="%.1f" y="%.1f" %s fill="%s"%s xml:space="preserve">%s</text>'
                % (x, y, font, pcolor, weight, esc(prefix))
            )
            x += len(prefix) * CHAR_W
        if rest:
            parts.append(
                '<text x="%.1f" y="%.1f" %s fill="%s"%s xml:space="preserve">%s</text>'
                % (x, y, font, rcolor, weight, esc(rest))
            )
        y += LINE_H

    parts.append("</g></svg>")
    write(path, "\n".join(parts) + "\n")


MONO = "ui-monospace, SFMono-Regular, Menlo, Consolas, Liberation Mono, monospace"


# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", default=os.path.join(REPO, "docs", "assets", "screenshots"))
    parser.add_argument("--only", nargs="*", default=None, help="render only these screenshot names")
    args = parser.parse_args()

    if not os.access(CLI, os.X_OK):
        sys.exit("error: %s is not executable" % CLI)

    box = build_sandbox()
    try:
        shots = make_transcripts(box)
    finally:
        shutil.rmtree(box["root"], ignore_errors=True)

    os.makedirs(args.out, exist_ok=True)
    selected = set(args.only or [s["name"] for s in shots])
    for shot in shots:
        if shot["name"] not in selected:
            continue
        render_svg(shot["title"], shot["text"], os.path.join(args.out, shot["name"] + ".svg"))
        print("wrote %s.svg" % shot["name"])


if __name__ == "__main__":
    main()
