#!/usr/bin/env python3
"""Invariant tests for the clip extractor's body frame.

    training/video/.venv/bin/python -m unittest discover -s training/video -p 'test_*.py'

`_body_frame` decides the origin and the unit of length for one frame, and the
wrist-only branch is the version the phone runs. These tests pin the rule that
only a hand which survives into the row may help build it, because a hand the
frame drops must not stay behind as the ruler for the hand that remains.
"""

from __future__ import annotations

import unittest

import numpy as np

import extract_tracks as et
import video_corpus as vc


class Landmark:
    def __init__(self, x: float, y: float) -> None:
        self.x, self.y, self.z, self.visibility = x, y, 0.0, 1.0


def hand(wrist=(0.4, 0.3), palm=0.07, finger=0.15) -> list[Landmark]:
    """A right-facing hand: palm along +x from the wrist, fingertips further out."""
    points = [Landmark(*wrist)] * 21
    points[vc.WRIST] = Landmark(*wrist)
    points[vc.MIDDLE_MCP] = Landmark(wrist[0] + palm, wrist[1])
    points[5] = Landmark(wrist[0] + palm, wrist[1] + 0.02)
    points[17] = Landmark(wrist[0] + palm, wrist[1] - 0.02)
    for tip in (8, 12, 16, 20):
        points[tip] = Landmark(wrist[0] + palm + finger, wrist[1])
    return points


def shoulders(width=0.3, centre=(0.5, 0.5)) -> list[Landmark]:
    return [Landmark(0.0, 0.0)] * 11 + [
        Landmark(centre[0] - width / 2, centre[1]),
        Landmark(centre[0] + width / 2, centre[1]),
    ]


class BodyFrameTest(unittest.TestCase):
    def test_shoulders_anchor_the_frame_and_every_detected_hand(self):
        centre, scale, present = et._body_frame(shoulders(), [hand(), None])
        self.assertTrue(present[0] and not present[1])
        self.assertAlmostEqual(float(centre[0]), 0.5)
        self.assertAlmostEqual(scale, 0.3)

    def test_without_shoulders_a_single_hand_sets_origin_and_unit(self):
        left = hand(wrist=(0.3, 0.2), palm=0.06)
        centre, scale, present = et._body_frame(None, [left, None])
        self.assertEqual(list(centre), [0.3, 0.2])
        self.assertAlmostEqual(scale, 2.6 * 0.06)
        self.assertEqual(present, [True, False])

    def test_both_hands_average_into_the_frame(self):
        left = hand(wrist=(0.3, 0.2), palm=0.06)
        right = hand(wrist=(0.5, 0.4), palm=0.10)
        centre, scale, present = et._body_frame(None, [left, right])
        self.assertTrue(np.allclose(centre, [0.4, 0.3]))
        self.assertAlmostEqual(scale, 2.6 * 0.08)
        self.assertEqual(present, [True, True])

    def test_a_hand_with_a_collapsed_palm_is_dropped_and_stops_setting_the_ruler(self):
        left = hand(wrist=(0.3, 0.2), palm=0.06)
        ghost = hand(wrist=(0.5, 0.4), palm=0.001, finger=0.15)
        centre, scale, present = et._body_frame(None, [left, ghost])
        self.assertEqual(present, [True, False])
        self.assertEqual(list(centre), [0.3, 0.2])
        self.assertAlmostEqual(scale, 2.6 * 0.06)

    def test_a_small_palm_still_anchors_when_its_fingers_are_close_too(self):
        # palm / span is 0.44 here, so this is a hand seen edge-on, not a bad track.
        near = hand(wrist=(0.3, 0.2), palm=0.02, finger=0.025)
        self.assertEqual(et._body_frame(None, [None, near])[2], [False, True])

    def test_a_frame_whose_hands_all_collapse_reports_nothing(self):
        ghost = hand(wrist=(0.5, 0.4), palm=0.0005, finger=0.15)
        self.assertIsNone(et._body_frame(None, [hand(wrist=(0.1, 0.1), palm=0.0004), ghost]))
        self.assertIsNone(et._body_frame(None, [None, None]))

    def test_narrow_shoulders_fall_back_to_the_hands(self):
        left = hand(wrist=(0.3, 0.2), palm=0.06)
        centre, scale, present = et._body_frame(shoulders(width=0.01), [left, None])
        self.assertEqual(list(centre), [0.3, 0.2])
        self.assertAlmostEqual(scale, 2.6 * 0.06)
        self.assertEqual(present, [True, False])


class SlotTest(unittest.TestCase):
    def test_each_hand_lands_in_the_slot_its_label_names(self):
        left, right = hand(wrist=(0.2, 0.2)), hand(wrist=(0.6, 0.2))
        slots = et._slots([left, right], ["Right", "Left"])
        self.assertIs(slots[0], right)
        self.assertIs(slots[1], left)

    def test_two_reports_for_one_slot_leave_the_last_one(self):
        first, second = hand(wrist=(0.2, 0.2)), hand(wrist=(0.6, 0.2))
        slots = et._slots([first, second], ["Left", "left"])
        self.assertIs(slots[0], second)
        self.assertIsNone(slots[1])


if __name__ == "__main__":
    unittest.main()
