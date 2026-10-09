#!/usr/bin/env python3
"""istatus sidebar: the live, interactive view of one pane's istatus state.

Runs in its own tmux split, paired with one Claude pane (istatus-attach.sh
starts it through istatus-sidebar.sh). It lists the session's summary and its
items in the same order as istatus resolve's [N] ordinals, and acts on the
selected item through `istatus --pane`, the way Gmail acts on a message:

  j / k, down / up   move the selection
  r                  mark a notice read (istatus defer)
  u                  mark a notice unread (istatus undefer)
  e                  resolve a notice (istatus resolve)

A blocking item only clears by answering its prompt (or by prefix A C for a
prompt interrupted with Esc), so the keys explain that instead of acting.

The pane's session is re-resolved on every refresh rather than cached: a
/resume into the paired pane swaps the session while keeping the pane, and a
cached session would show the previous occupant's state. Refreshes poll once
a second, which covers the pane pointer and the status file alike.

Usage: istatus_sidebar.py <paired-tmux-pane-id>   (e.g. %83)
"""

from __future__ import annotations

import curses
import json
import locale
import os
import subprocess
import sys
import textwrap
from typing import NamedTuple, Optional

ISTATUS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "istatus.sh")
PRIORITY_RANK = {"high": 0, "low": 2}
REFRESH_MS = 1000
HINT = ["j/k move", "r read", "u unread", "e done"]
BLOCKING_HINT = "blocked: answer it (or prefix A C)"
TAG_WIDTH = len("blocked")


class View(NamedTuple):
    summary: str = ""
    items: list = []
    problem: Optional[str] = None


def main(argv: list) -> int:
    if len(argv) != 2:
        print("usage: istatus_sidebar.py <paired-tmux-pane-id>", file=sys.stderr)
        return 2
    locale.setlocale(locale.LC_ALL, "")
    try:
        curses.wrapper(Sidebar(argv[1], state_root()).loop)
    except KeyboardInterrupt:
        pass
    return 0


def state_root() -> str:
    # The state directory keeps the name of the old claude-tmux-attention plugin.
    return os.environ.get("CLAUDE_TMUX_ATTENTION_DIR") or os.path.expanduser(
        "~/.claude-tmux-attention")


def load(root: str, pane: str) -> View:
    try:
        with open(os.path.join(root, "panes", f"{pane}.session_id")) as f:
            session_id = f.read().strip()
    except OSError:
        session_id = ""
    if not session_id:
        return View(problem="no session resolved for this pane yet")
    try:
        with open(os.path.join(root, "status", f"{session_id}.json")) as f:
            state = json.load(f)
    except FileNotFoundError:
        return View(problem="no istatus state for this session yet")
    except (OSError, ValueError):
        return View(problem="could not read this session's istatus state")
    return View(summary=state.get("summary") or "", items=ordered(state.get("items") or []))


def ordered(items: list) -> list:
    """Blocking first, then notices by priority, then oldest first: the order
    istatus resolve's ordinals use, so a [N] here names the same item there."""
    def key(item):
        blocking = item.get("kind") == "blocking"
        rank = 0 if blocking else PRIORITY_RANK.get(item.get("priority"), 1)
        return (0 if blocking else 1, rank, item.get("created_at") or "")
    return sorted(items, key=key)


def command_for(key: str, item: dict, pane: str, istatus: str):
    """The istatus command a key runs on an item, as (argv, None), or
    (None, message) when the key cannot act on it, or (None, None) when it has
    nothing to do. Items are named by id, not ordinal, so an item arriving
    between the keypress and the command cannot shift the target."""
    if key not in ("r", "u", "e"):
        return None, None
    if item.get("kind") == "blocking":
        return None, BLOCKING_HINT
    unread = item.get("state") != "read"
    if key == "r" and not unread or key == "u" and unread:
        return None, None
    verb = {"r": "defer", "u": "undefer", "e": "resolve"}[key]
    return [istatus, "--pane", pane, verb, item["id"]], None


def run(argv: list, root: str) -> Optional[str]:
    """Runs an istatus command and returns its error, or None."""
    env = {**os.environ, "CLAUDE_TMUX_ATTENTION_DIR": root}
    result = subprocess.run(argv, env=env, capture_output=True, text=True)
    if result.returncode == 0:
        return None
    return (result.stderr.strip().splitlines() or ["istatus failed"])[-1]


class Selection:
    """Which item is selected, by id, so it stays selected while items arrive
    and leave around it. When it leaves, the selection keeps its place."""

    def __init__(self):
        self.id = None
        self.place = 0

    def index(self, items: list) -> Optional[int]:
        if not items:
            return None
        for i, item in enumerate(items):
            if item.get("id") == self.id:
                return i
        return min(self.place, len(items) - 1)

    def select(self, items: list, i: int) -> None:
        self.place = max(0, min(i, len(items) - 1))
        self.id = items[self.place].get("id") if items else None

    def move(self, items: list, delta: int) -> None:
        self.select(items, (self.index(items) or 0) + delta)


class Sidebar:

    def __init__(self, pane: str, root: str):
        self.pane = pane
        self.root = root
        self.selection = Selection()
        self.message = None
        self.top = 0

    def loop(self, screen) -> None:
        curses.curs_set(0)
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_RED, -1)
        curses.init_pair(2, curses.COLOR_MAGENTA, -1)
        screen.timeout(REFRESH_MS)
        while True:
            view = load(self.root, self.pane)
            self.draw(screen, view)
            key = screen.getch()
            if key == -1 or key == curses.KEY_RESIZE:
                continue
            self.message = None
            self.handle(key, view.items)

    def handle(self, key: int, items: list) -> None:
        if key in (ord("j"), curses.KEY_DOWN):
            self.selection.move(items, +1)
        elif key in (ord("k"), curses.KEY_UP):
            self.selection.move(items, -1)
        elif 0 <= key < 256 and (i := self.selection.index(items)) is not None:
            argv, self.message = command_for(chr(key), items[i], self.pane, ISTATUS)
            if argv:
                self.message = run(argv, self.root)

    def draw(self, screen, view: View) -> None:
        screen.erase()
        height, width = screen.getmaxyx()
        lines = self.header(view, width)
        item_lines, selected = self.item_lines(view.items, width)
        # The footer wraps rather than truncates: a sidebar is narrow.
        footer = wrap(self.message, width, "") if self.message else pack(HINT, width)
        footer = footer[:max(height - 1, 1)]
        footer_attr = curses.color_pair(1) if self.message else curses.A_DIM
        body = height - len(lines) - len(footer)
        self.scroll(selected, body)
        lines += item_lines[self.top:self.top + max(body, 0)]
        for y, (text, attr) in enumerate(lines[:height - len(footer)]):
            screen.addnstr(y, 0, text, width - 1, attr)
        for y, text in enumerate(footer, start=height - len(footer)):
            screen.addnstr(y, 0, text, width - 1, footer_attr)
        screen.refresh()

    def header(self, view: View, width: int) -> list:
        lines = [(f" istatus — {self.pane}", curses.A_BOLD), ("─" * (width - 1), 0)]
        if view.problem:
            return lines + [(f" ({view.problem})", curses.A_DIM)]
        if view.summary:
            lines.append(("Working on:", curses.A_BOLD))
            lines += [(line, 0) for line in wrap(view.summary, width, " ")]
            lines.append(("", 0))
        if not view.items:
            return lines + [("(nothing open)", curses.A_DIM)]
        return lines + [(f"Open ({len(view.items)}):", curses.A_BOLD)]

    def item_lines(self, items: list, width: int):
        """Each item's wrapped lines, and the span of the selected one."""
        lines, selected = [], None
        chosen = self.selection.index(items)
        for n, item in enumerate(items):
            tag, attr = tag_for(item)
            start = len(lines)
            prefix = f"[{n + 1}] {tag:<{TAG_WIDTH}}  "
            wrapped = wrap(item.get("text") or "", width - len(prefix), "") or [""]
            lines.append((prefix + wrapped[0], attr))
            lines += [(" " * len(prefix) + rest, attr) for rest in wrapped[1:]]
            if n == chosen:
                lines[start:] = [(text, a | curses.A_REVERSE) for text, a in lines[start:]]
                selected = (start, len(lines))
        return lines, selected

    def scroll(self, selected, body: int) -> None:
        """Keeps the selected item on screen."""
        if selected is None or body <= 0:
            self.top = 0
            return
        start, end = selected
        if start < self.top:
            self.top = start
        elif end > self.top + body:
            self.top = max(start, end - body) if end - start <= body else start


def tag_for(item: dict):
    if item.get("kind") == "blocking":
        return "blocked", curses.color_pair(1)
    if item.get("state") == "read":
        return "read", curses.A_DIM
    return "unread", curses.color_pair(2)


def pack(chunks: list, width: int) -> list:
    """Lays chunks out two spaces apart, breaking lines only between them."""
    lines, line = [], ""
    for chunk in chunks:
        joined = f"{line}  {chunk}" if line else chunk
        if line and len(joined) > width - 1:
            lines.append(line)
            line = chunk
        else:
            line = joined
    return lines + [line]


def wrap(text: str, width: int, indent: str) -> list:
    text = " ".join(text.split())
    return textwrap.wrap(text, max(width - 1, 10), initial_indent=indent,
                         subsequent_indent=indent)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
