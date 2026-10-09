#!/usr/bin/env python3
"""Tests for istatus_sidebar.py, the interactive sidebar.

The model is tested here: the order items are listed in, which item stays
selected as the list changes, and what each key does to the selected item.
One case runs a key's command against the real istatus.sh. Drawing with
curses needs a terminal, so it is exercised end to end.

Run: claude/skills/istatus/scripts/istatus_sidebar_test.py
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import istatus_sidebar as sidebar  # noqa: E402


def notice(id, state="unread", priority="normal", created_at="2026-01-01T00:00:00Z"):
    return {"id": id, "kind": "notice", "text": id, "state": state,
            "priority": priority, "created_at": created_at}


def blocking(id, created_at="2026-01-01T00:00:00Z"):
    return {"id": id, "kind": "blocking", "source": "", "text": id,
            "state": "unread", "created_at": created_at}


class OrderedTest(unittest.TestCase):
    """The same order istatus resolve's [N] ordinals use."""

    def test_blocking_first_then_priority_then_oldest(self):
        items = [
            notice("low", priority="low"),
            notice("normal-new", created_at="2026-01-01T00:00:02Z"),
            notice("normal-old", created_at="2026-01-01T00:00:01Z"),
            notice("high", priority="high"),
            blocking("prompt", created_at="2026-01-02T00:00:00Z"),
        ]
        self.assertEqual(
            [i["id"] for i in sidebar.ordered(items)],
            ["prompt", "high", "normal-old", "normal-new", "low"])

    def test_a_notice_without_a_priority_sorts_as_normal(self):
        items = [notice("low", priority="low"), {**notice("bare"), "priority": None}]
        self.assertEqual([i["id"] for i in sidebar.ordered(items)], ["bare", "low"])


class SelectionTest(unittest.TestCase):

    def test_with_nothing_selected_yet_the_first_item_is_selected(self):
        self.assertEqual(sidebar.Selection().index([notice("a"), notice("b")]), 0)

    def test_the_selected_item_stays_selected_when_items_arrive_before_it(self):
        selection = sidebar.Selection()
        selection.select([notice("a"), notice("b")], 1)
        self.assertEqual(selection.index([blocking("new"), notice("a"), notice("b")]), 2)

    def test_when_the_selected_item_goes_the_selection_stays_at_its_place(self):
        selection = sidebar.Selection()
        selection.select([notice("a"), notice("b"), notice("c")], 1)
        self.assertEqual(selection.index([notice("a"), notice("c")]), 1)

    def test_when_the_last_item_goes_the_selection_moves_up(self):
        selection = sidebar.Selection()
        selection.select([notice("a"), notice("b")], 1)
        self.assertEqual(selection.index([notice("a")]), 0)

    def test_with_no_items_nothing_is_selected(self):
        selection = sidebar.Selection()
        selection.select([notice("a")], 0)
        self.assertIsNone(selection.index([]))

    def test_moving_past_the_end_stays_on_the_last_item(self):
        selection = sidebar.Selection()
        items = [notice("a"), notice("b")]
        selection.move(items, +5)
        self.assertEqual(selection.index(items), 1)

    def test_moving_before_the_start_stays_on_the_first_item(self):
        selection = sidebar.Selection()
        items = [notice("a"), notice("b")]
        selection.select(items, 1)
        selection.move(items, -5)
        self.assertEqual(selection.index(items), 0)


class CommandForTest(unittest.TestCase):
    """What a key does to the selected item: an istatus command, or a reason
    it does nothing."""

    def command(self, key, item):
        return sidebar.command_for(key, item, "%9", "/x/istatus.sh")

    def test_r_marks_an_unread_notice_read(self):
        self.assertEqual(self.command("r", notice("n1")),
                         (["/x/istatus.sh", "--pane", "%9", "defer", "n1"], None))

    def test_r_on_a_read_notice_does_nothing(self):
        self.assertEqual(self.command("r", notice("n1", state="read")), (None, None))

    def test_u_marks_a_read_notice_unread(self):
        self.assertEqual(self.command("u", notice("n1", state="read")),
                         (["/x/istatus.sh", "--pane", "%9", "undefer", "n1"], None))

    def test_u_on_an_unread_notice_does_nothing(self):
        self.assertEqual(self.command("u", notice("n1")), (None, None))

    def test_e_resolves_a_notice(self):
        self.assertEqual(self.command("e", notice("n1")),
                         (["/x/istatus.sh", "--pane", "%9", "resolve", "n1"], None))

    def test_a_key_on_a_blocking_item_explains_instead(self):
        for key in "rue":
            argv, message = self.command(key, blocking("b1"))
            self.assertEqual((argv, "answer" in (message or "")), (None, True), key)

    def test_an_unbound_key_does_nothing(self):
        self.assertEqual(self.command("x", notice("n1")), (None, None))


class PackTest(unittest.TestCase):
    """The key hint, laid out to the sidebar's width."""

    def test_chunks_that_fit_share_a_line(self):
        self.assertEqual(sidebar.pack(["j/k move", "r read"], 40), ["j/k move  r read"])

    def test_a_line_breaks_between_chunks_never_inside_one(self):
        self.assertEqual(sidebar.pack(["j/k move", "r read", "u unread"], 18),
                         ["j/k move  r read", "u unread"])


class LoadTest(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = self.dir.name
        os.makedirs(os.path.join(self.root, "status"))
        os.makedirs(os.path.join(self.root, "panes"))

    def tearDown(self):
        self.dir.cleanup()

    def seed(self, session_id, state, pane="%9"):
        with open(os.path.join(self.root, "status", f"{session_id}.json"), "w") as f:
            json.dump(state, f)
        with open(os.path.join(self.root, "panes", f"{pane}.session_id"), "w") as f:
            f.write(session_id)

    def test_a_pane_with_no_session_says_so(self):
        self.assertEqual(sidebar.load(self.root, "%9").problem,
                         "no session resolved for this pane yet")

    def test_a_session_with_no_status_file_says_so(self):
        with open(os.path.join(self.root, "panes", "%9.session_id"), "w") as f:
            f.write("sess-1")
        self.assertEqual(sidebar.load(self.root, "%9").problem,
                         "no istatus state for this session yet")

    def test_a_session_loads_its_summary_and_its_items_in_order(self):
        self.seed("sess-1", {"summary": "working", "items": [notice("n1"), blocking("b1")]})
        view = sidebar.load(self.root, "%9")
        self.assertEqual((view.summary, [i["id"] for i in view.items]),
                         ("working", ["b1", "n1"]))

    def test_a_key_runs_against_the_real_istatus(self):
        self.seed("sess-1", {"summary": "", "items": [notice("n1"), notice("n2")]})
        item = sidebar.load(self.root, "%9").items[1]
        istatus = os.path.join(os.path.dirname(os.path.abspath(__file__)), "istatus.sh")
        argv, _ = sidebar.command_for("r", item, "%9", istatus)
        sidebar.run(argv, self.root)
        self.assertEqual([i["state"] for i in sidebar.load(self.root, "%9").items],
                         ["unread", "read"])


if __name__ == "__main__":
    unittest.main()
