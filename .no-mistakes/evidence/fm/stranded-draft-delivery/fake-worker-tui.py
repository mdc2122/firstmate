#!/usr/bin/env python3
"""Disposable stand-in worker TUI: a bordered composer that submits on Enter.

argv: <submit-log> <mode>   mode=normal (Enter clears) | stuck (Enter ignored)
"""
import os, sys, tty, termios, shutil

log, mode = sys.argv[1], sys.argv[2]
style = sys.argv[3] if len(sys.argv) > 3 else "box"
fd = sys.stdin.fileno()
tty.setraw(fd)
buf = ""
transcript = ["fake-harness ready"]

def draw():
    cols = shutil.get_terminal_size((100, 30)).columns
    rows = shutil.get_terminal_size((100, 30)).lines
    w = min(cols - 2, 160)
    out = "\x1b[H\x1b[2J"
    for t in transcript[-(rows - 6):]:
        out += t[: cols - 1] + "\r\n"
    out += "\r\n"
    if style == "box":
        out += "╭" + "─" * (w - 2) + "╮\r\n"
        line = "> " + buf
        shown = line[: w - 4]
        out += "│ " + shown + " " * (w - 4 - len(shown)) + " │\r\n"
        out += "╰" + "─" * (w - 2) + "╯\r\n"
        crow = len(transcript[-(rows - 6):]) + 3
        out += "\x1b[%d;%dH" % (crow, 3 + len(shown) + 1)
    else:
        out += "─" * cols + "\r\n"
        shown = ("❯ " + buf if style == "claude" else buf)[: cols - 2]
        out += shown + "\r\n"
        out += "─" * cols + "\r\n"
        out += "~/work (main)\r\n"
        crow = len(transcript[-(rows - 6):]) + 3
        out += "\x1b[%d;%dH" % (crow, len(shown) + 1)
    sys.stdout.write(out)
    sys.stdout.flush()

draw()
pending = b""
while True:
    ch = os.read(fd, 4096)
    if not ch:
        break
    data = pending + ch
    pending = b""
    try:
        s = data.decode("utf-8")
    except UnicodeDecodeError:
        pending = data
        continue
    i = 0
    while i < len(s):
        c = s[i]
        if c == "\x1b":
            # drop escape sequences (bracketed paste markers etc.)
            j = i + 1
            if j < len(s) and s[j] == "[":
                j += 1
                while j < len(s) and not ("@" <= s[j] <= "~"):
                    j += 1
                j += 1
            i = j
            continue
        if c in "\r\n":
            if mode == "stuck":
                with open(log, "a") as f:
                    f.write("ENTER-IGNORED (stuck mode)\n")
            elif buf:
                with open(log, "a") as f:
                    f.write("SUBMITTED: " + buf + "\n")
                transcript.append("user> " + buf)
                transcript.append("assistant: ok")
                buf = ""
        elif c == "\x03":
            with open(log, "a") as f:
                f.write("CTRL-C\n")
        elif c == "\x7f":
            buf = buf[:-1]
        elif c >= " " or c == "⁣":
            buf += c
        i += 1
    draw()
