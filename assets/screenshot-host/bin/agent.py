#!/usr/bin/env python3
"""Scripted coding agent for Hoshi's screenshots and App Preview.

Plays a fixed, ANSI-styled transcript in a Herdr pane and reports its state to
Herdr (`herdr pane report-agent`), so Hoshi's Herdr list, inbox and Live
Activity see a real working / blocked / done agent. The `approval` scenario
blocks until a line arrives on stdin, which is exactly what Hoshi's Reply sends
through `herdr agent send-keys`.

usage: agent.py SCENARIO [--label NAME] [--fast]
"""
import argparse
import os
import signal
import subprocess
import sys
import time

R = "\x1b[0m"
B = "\x1b[1m"
DIM = "\x1b[2m"
GREEN = "\x1b[38;5;114m"
BLUE = "\x1b[38;5;75m"
GOLD = "\x1b[38;5;221m"
ORANGE = "\x1b[38;5;215m"
RED = "\x1b[38;5;203m"
GREY = "\x1b[38;5;245m"
PURPLE = "\x1b[38;5;141m"

PANE = os.environ.get("HERDR_PANE_ID")
SPEED = 1.0
START = None      # --start: file that releases the scripted work
LOG = []          # every line printed so far, replayed on resize
PROMPT = ""       # trailing partial line (input prompt), replayed on resize
HOLD = None       # when set, wait for this file before the key moment


def hold():
    """Pause before blocking/finishing until the capture script triggers it
    (touch the file), so Hoshi sees the state change happen live."""
    if HOLD:
        while not os.path.exists(HOLD):
            time.sleep(0.2)


def wait_for_start():
    """With --start, show the task, then wait for the capture script so the
    work streams in on camera (App Preview video)."""
    if START:
        while not os.path.exists(START):
            time.sleep(0.1)


def emit(text):
    """Write straight to the tty. The SIGWINCH handler also writes, and
    re-entering sys.stdout's buffer from a signal handler raises."""
    data = text.encode()
    while data:
        try:
            data = data[os.write(1, data):]
        except InterruptedError:
            pass


def redraw(*_):
    """Repaint the transcript after a resize, like a real agent TUI."""
    emit("\x1b[3J\x1b[2J\x1b[H" + "\n".join(LOG) + ("\n" if LOG else "") + PROMPT)


def report(label, state, title=None):
    if not PANE:
        return
    seq = str(time.time_ns() // 1_000_000)
    subprocess.run(
        ["herdr", "pane", "report-agent", PANE, "--source=shots", f"--agent={label}",
         f"--state={state}", f"--seq={seq}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    if title:
        subprocess.run(
            ["herdr", "pane", "report-metadata", PANE, "--source", "shots", "--title", title],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )


def out(text="", pause=0.12):
    LOG.append(text or "")
    emit((text or "") + "\n")
    time.sleep(pause * SPEED)


def header(label, *task):
    # Phone width is ~32 columns at 15 pt; keep every line under that.
    out(f"{B}{PURPLE}◆ {label}{R} {GREY}· ~/hoshi{R}", 0.05)
    for i, line in enumerate(task):
        out(f"{GREY}task:{R} {line}" if i == 0 else line, 0.1)
    out(None, 0.2)


def step(verb, target, detail=None):
    out(f"{BLUE}▸{R} {B}{verb}{R} {target}", 0.35)
    if detail:
        out(f"  {GREY}└ {detail}{R}", 0.25)


def diff(path, added, removed, inline=False):
    stats = f"{GREEN}+{added}{R} {RED}−{removed}{R}"
    if inline:
        out(f"{BLUE}▸{R} {B}Edit{R} {path} {stats}", 0.35)
    else:
        out(f"{BLUE}▸{R} {B}Edit{R} {path}", 0.1)
        out(f"  {stats}", 0.3)


def code(*lines):
    for line in lines:
        out(f"  {GREY}│{R} {GREEN}{line}{R}", 0.08)


def spinner_forever(message, started):
    frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    i = 0
    while True:
        elapsed = int(time.time() - started) + 92
        emit(f"\r{ORANGE}{frames[i % len(frames)]}{R} {message} {GREY}{elapsed // 60}m{elapsed % 60:02d}s{R}\x1b[K")
        i += 1
        time.sleep(0.1)


def scenario_working(label):
    """Mid-task: fixing Mosh silence detection, tests running."""
    title = "Detect a silent mosh-server"
    report(label, "working", title)
    header(label, "recover when", "mosh-server goes silent")
    wait_for_start()
    step("Read", "MoshStateSync.swift")
    step("Read", "MoshSession.swift", "transmitter loop")
    step("Search", '"lastHeardAt"', "3 matches in 2 files")
    diff("MoshStateSync.swift", 18, 4)
    code("+ let silenceTimeout = 15.0",
         "+ func serverIsSilent(",
         "+   now: Date) -> Bool {",
         "+   now.timeIntervalSince(",
         "+     lastHeardAt)",
         "+     > silenceTimeout",
         "+ }")
    diff("MoshSession.swift", 9, 2, inline=True)
    step("Test", "MoshTransportTests")
    out(f"  {GREEN}✔{R} 41 passed {GREY}(3.8s){R}", 0.4)
    step("Test", "full suite")
    out(None, 0.1)
    spinner_forever("Running 692 tests", time.time())


def scenario_approval(label):
    """Blocked on an approval, continues when a reply arrives."""
    title = "Migrate session store"
    report(label, "working", title)
    header(label, "restore each session's", "mosh-server after relaunch")
    step("Read", "SessionPersistence.swift")
    diff("SessionPersistence.swift", 42, 7)
    diff("SessionManager.swift", 12, 3)
    step("Test", "SessionPersistenceTests")
    out(f"  {GREEN}✔{R} 18 passed {GREY}(1.2s){R}", 0.4)
    hold()
    out(None, 0.1)
    out(f"{GOLD}╭─ Approval needed ──────────╮{R}", 0.05)
    out(f"{GOLD}│{R} Migrate 3 saved sessions?  {GOLD}│{R}", 0.05)
    out(f"{GOLD}│{R} {GREY}scripts/migrate.sh --apply{R} {GOLD}│{R}", 0.05)
    out(f"{GOLD}╰────────────────────────────╯{R}", 0.05)
    report(label, "blocked", title)
    global PROMPT
    PROMPT = f"{ORANGE}❯{R} "
    emit(PROMPT)
    answer = sys.stdin.readline().strip() or "yes"
    PROMPT = ""
    LOG.append(f"{ORANGE}❯{R} {answer}")
    report(label, "working", title)
    step("Run", "scripts/migrate.sh --apply")
    out(f"  {GREEN}✔{R} 3 sessions migrated", 0.5)
    step("Test", "full suite")
    out(f"  {GREEN}✔{R} 692 passed {GREY}(48s){R}", 0.4)
    out(None, 0.1)
    out(f"{GREEN}●{R} {B}Done.{R} Sessions now keep", 0.05)
    out("  their mosh-server.", 0.1)
    report(label, "idle", title)
    while True:
        time.sleep(3600)


def scenario_done(label):
    """Finished: opened a pull request."""
    title = "Rewrite gethoshi.app"
    report(label, "working", title)
    header(label, "rewrite the website", "around open source")
    diff("site/index.html", 412, 188)
    step("Run", "html-validate", "no problems")
    hold()
    step("Run", "gh pr create --fill")
    out(f"  {GREY}└{R} {BLUE}fcoury/hoshi#25{R}", 0.3)
    out(None, 0.1)
    out(f"{GREEN}●{R} {B}Done.{R} PR #25 is ready", 0.05)
    out("  for review.", 0.1)
    report(label, "idle", title)
    while True:
        time.sleep(3600)


SCENARIOS = {"working": scenario_working, "approval": scenario_approval, "done": scenario_done}


def main():
    global SPEED, HOLD, START
    p = argparse.ArgumentParser()
    p.add_argument("scenario", choices=SCENARIOS)
    p.add_argument("--label", default="agent")
    p.add_argument("--fast", action="store_true", help="no typing delays (stills)")
    p.add_argument("--hold", help="wait for this file before blocking or finishing")
    p.add_argument("--start", help="wait for this file before starting the work")
    a = p.parse_args()
    HOLD = a.hold
    START = a.start
    if a.fast:
        SPEED = 0.0
    signal.signal(signal.SIGWINCH, redraw)
    os.system("clear")
    try:
        SCENARIOS[a.scenario](a.label)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
