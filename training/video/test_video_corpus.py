#!/usr/bin/env python3
"""Invariant tests for the video corpus module.

    training/video/.venv/bin/python -m unittest discover -s training/video -p 'test_*.py'

`fake_track` hides the source frame index in the hand-count column. Augmentation
never touches that column, which is what lets a test read back exactly which
frames of a clip survived into a window and prove that references and queries
are disjoint.
"""

from __future__ import annotations

import unittest

import numpy as np

import video_corpus as vc

LEFT, RIGHT = vc.HAND_BLOCKS


def fake_track(rows: int, key: str = "asl/test.mp4") -> vc.Track:
    features = np.zeros((rows, vc.FEATURES_PER_FRAME), dtype=np.float32)
    for row in range(rows):
        features[row, LEFT][: vc.COORDS] = row + np.arange(vc.COORDS) / 100.0
        features[row, RIGHT][: vc.COORDS] = row + np.arange(vc.COORDS) / 50.0
        features[row, LEFT.start + 45] = 1.0
        features[row, RIGHT.start + 45] = 1.0
        features[row, vc.POSE_PRESENT] = 1.0
        features[row, vc.HAND_COUNT] = float(row)
    return vc.Track(key=key, features=features, stamps=np.arange(rows, dtype=np.int32) * 100)


def source_rows(sample: vc.Sample) -> set[int]:
    live = sample.mask > 0.5
    return {int(round(value)) for value in sample.features[live, vc.HAND_COUNT]}


class LayoutTest(unittest.TestCase):
    def test_feature_layout_has_no_gaps(self):
        self.assertEqual(LEFT.stop, RIGHT.start)
        self.assertEqual(RIGHT.stop + 2, vc.FEATURES_PER_FRAME)

    def test_tracked_frames_counts_rows_with_any_hand(self):
        track = fake_track(10)
        self.assertEqual(track.tracked_frames(), 10)
        track.features[3, LEFT.start + 45] = 0.0
        track.features[3, RIGHT.start + 45] = 0.0
        self.assertEqual(track.tracked_frames(), 9)


class WindowTest(unittest.TestCase):
    def test_short_tracks_yield_one_padded_window(self):
        sample = vc.Sample.from_block(fake_track(5).features, vc.WINDOW)
        self.assertEqual(sample.features.shape, (vc.WINDOW, vc.FEATURES_PER_FRAME))
        self.assertEqual(float(sample.mask.sum()), 5.0)
        self.assertTrue((sample.features[5:] == 0).all())

    def test_clips_at_the_window_length_produce_full_windows(self):
        for rows in range(vc.WINDOW, vc.WINDOW + 6):
            for block in vc.windows(fake_track(rows)):
                self.assertEqual(float(block.mask.min()), 1.0, rows)

    def test_reference_and_query_windows_never_share_a_frame(self):
        """The retrieval score only means something while this holds."""
        for rows in (32, 40, 57, 90):
            reference, queries = vc.split_windows(fake_track(rows), vc.WINDOW)
            reference_rows = source_rows(reference)
            self.assertTrue(reference_rows, rows)
            for query in queries:
                self.assertFalse(reference_rows & source_rows(query), f"rows={rows}")

    def test_queries_cover_the_second_half_only(self):
        rows = 60
        reference, queries = vc.split_windows(fake_track(rows), vc.WINDOW)
        self.assertTrue(max(source_rows(reference)) < rows // 2)
        for query in queries:
            self.assertTrue(min(source_rows(query)) >= rows // 2)


class AugmentTest(unittest.TestCase):
    def setUp(self) -> None:
        self.rng = np.random.default_rng(7)
        self.sample = vc.Sample.from_block(fake_track(40).features, vc.WINDOW)

    def test_mirror_is_its_own_inverse(self):
        np.testing.assert_allclose(
            vc.mirror(vc.mirror(self.sample)).features, self.sample.features, atol=1e-5
        )

    def test_mirror_moves_the_right_hand_into_the_left_slot_and_flips_x(self):
        original = self.sample.features
        mirrored = vc.mirror(self.sample).features
        expected_x = -original[:, RIGHT][:, : vc.COORDS : 2]
        np.testing.assert_allclose(mirrored[:, LEFT][:, : vc.COORDS : 2], expected_x, atol=1e-6)
        np.testing.assert_allclose(
            mirrored[:, LEFT][:, 1 : vc.COORDS : 2],
            original[:, RIGHT][:, 1 : vc.COORDS : 2],
            atol=1e-6,
        )

    def test_augmentation_keeps_presence_flags_binary(self):
        for _ in range(30):
            augmented = vc.augment(self.sample, self.rng)
            self.assertTrue(set(np.unique(augmented.features[:, LEFT.start + 45])) <= {0.0, 1.0})
            self.assertTrue(set(np.unique(augmented.features[:, RIGHT.start + 45])) <= {0.0, 1.0})

    def test_augmentation_never_invents_padded_frames(self):
        for _ in range(30):
            augmented = vc.augment(self.sample, self.rng)
            self.assertTrue((augmented.features[augmented.mask < 0.5] == 0).all())

    def test_augmentation_keeps_at_least_one_live_frame(self):
        for _ in range(50):
            self.assertGreaterEqual(float(vc.augment(self.sample, self.rng).mask.sum()), 1.0)

    def test_speed_warp_preserves_window_shape(self):
        augmented = vc.augment(self.sample, self.rng)
        self.assertEqual(augmented.features.shape, self.sample.features.shape)

    def test_augmentation_only_keeps_frames_it_claims_to(self):
        augmented = vc.augment(self.sample, self.rng, warp=False)
        self.assertTrue(source_rows(augmented) <= source_rows(self.sample))

    def test_sample_pair_of_a_long_clip_draws_two_disjoint_views(self):
        first, second = vc.sample_pair(fake_track(80), self.rng)
        self.assertTrue(source_rows(first).isdisjoint(source_rows(second)))
        self.assertLess(max(source_rows(first)), min(source_rows(second)))

    def test_sample_pair_of_a_short_clip_still_returns_two_views(self):
        first, second = vc.sample_pair(fake_track(9), self.rng)
        self.assertEqual(first.features.shape, (vc.WINDOW, vc.FEATURES_PER_FRAME))
        self.assertEqual(second.features.shape, first.features.shape)


class BankTest(unittest.TestCase):
    """The bank the app ships covers whole clips; the bank a score is taken
    against may not, or the query is being matched against its own frames."""

    def test_eval_bank_windows_never_touch_query_frames(self):
        import verify_video_match as vm

        for rows in (32, 40, 57, 90):
            track = fake_track(rows)
            _, queries = vc.split_windows(track, vc.WINDOW)
            bank_rows: set[int] = set()
            for sample in vm.disjoint_bank_windows(track):
                bank_rows |= source_rows(sample)
            for query in queries:
                self.assertFalse(bank_rows & source_rows(query), f"rows={rows}")

    def test_eval_bank_still_spreads_across_the_reference_half(self):
        import verify_video_match as vm

        self.assertGreater(len(vm.disjoint_bank_windows(fake_track(90))), 1)

    def test_the_shipped_whole_clip_bank_would_leak(self):
        import train_match as tm

        track = fake_track(90)
        _, queries = vc.split_windows(track, vc.WINDOW)
        bank_rows: set[int] = set()
        for sample in tm.bank_windows(track):
            bank_rows |= source_rows(sample)
        self.assertTrue(any(bank_rows & source_rows(query) for query in queries))

    def test_shipped_bank_takes_every_stride_position_up_to_the_cap(self):
        """Reference density is what the app is scored on, so the window starts
        must be real positions in the clip, not padding or duplicates."""
        import train_match as tm

        for rows in (16, 20, 40, 63, 90):
            starts = [min(source_rows(s)) for s in tm.bank_windows(fake_track(rows))]
            fits = list(range(0, max(rows - vc.WINDOW, 0) + 1, vc.WINDOW_STRIDE))
            expected = fits if len(fits) <= tm.BANK_WINDOWS else [
                fits[int(p)] for p in np.linspace(0, len(fits) - 1, tm.BANK_WINDOWS).round()
            ]
            self.assertEqual(starts, sorted(set(starts)), f"rows={rows}")
            self.assertEqual(starts, expected, f"rows={rows}")

    def test_short_clips_still_get_a_reference(self):
        import train_match as tm

        for rows in (1, 8, 15):
            bank = tm.bank_windows(fake_track(rows))
            self.assertEqual(len(bank), 1, f"rows={rows}")
            self.assertEqual(max(source_rows(bank[0])), rows - 1, f"rows={rows}")


class WristFrameTest(unittest.TestCase):
    """The phone has hands but no shoulders, so this frame is the only one it can build."""

    @staticmethod
    def hand_row(block: slice, wrist, knuckle_offset, tip_offset) -> np.ndarray:
        """One frame row holding a hand with the given wrist, palm and fingertip offsets.

        The offsets are in whatever units the input row happens to use; only their
        ratios matter, which is what makes the wrist frame reachable on a phone.
        """
        row = np.zeros(vc.FEATURES_PER_FRAME, dtype=np.float32)
        points = np.zeros((21, 2), dtype=np.float32)
        points[vc.WRIST] = wrist
        points[vc.MIDDLE_MCP] = np.array(wrist) + np.array(knuckle_offset)
        points[5] = np.array(wrist) + np.array(tip_offset) * 0.6
        points[17] = np.array(wrist) - np.array([0.02, 0.0])
        for tip in (8, 12, 16, 20):
            points[tip] = np.array(wrist) + np.array(tip_offset)
        row[block][: vc.COORDS] = points.reshape(-1)
        palm = float(np.linalg.norm(points[vc.MIDDLE_MCP] - points[vc.WRIST]))
        span = float(np.mean(np.linalg.norm(points[[8, 12, 16, 20]] - points[vc.WRIST], axis=1)))
        row[block.start + vc.SPREAD] = span / (palm or 1e-3)
        row[block.start + 43] = float(np.sin(np.arctan2(0.3, 0.4)))
        row[block.start + 44] = float(np.cos(np.arctan2(0.3, 0.4)))
        row[block.start + 45] = 1.0
        return row

    def two_hand_row(self, left_wrist=(0.3, 0.2), right_wrist=(0.5, 0.4)):
        row = np.zeros(vc.FEATURES_PER_FRAME, dtype=np.float32)
        left = self.hand_row(LEFT, left_wrist, (0.1, 0.0), (0.1, 0.2))
        right = self.hand_row(RIGHT, right_wrist, (0.1, 0.0), (0.1, 0.2))
        row[:] = left + right
        row[vc.POSE_PRESENT] = 1.0
        row[vc.HAND_COUNT] = 2.0
        return row

    def test_the_anchoring_hands_set_the_unit_of_length(self):
        converted = vc.wrist_frame(self.two_hand_row()[None, :])[0]
        for block in (LEFT, RIGHT):
            coords = converted[: vc.COORDS].reshape(21, 2)
            palm = np.linalg.norm(coords[vc.MIDDLE_MCP] - coords[vc.WRIST])
            self.assertAlmostEqual(float(palm), 1 / 2.6, places=5)
        self.assertAlmostEqual(float(converted[LEFT.start + 45]), 1.0)
        self.assertAlmostEqual(float(converted[vc.HAND_COUNT]), 2.0)
        self.assertAlmostEqual(float(converted[vc.POSE_PRESENT]), 0.0)

    def test_both_wrists_average_to_the_origin(self):
        converted = vc.wrist_frame(self.two_hand_row()[None, :])[0]
        left = converted[: vc.COORDS].reshape(21, 2)[vc.WRIST]
        right = converted[RIGHT.start : RIGHT.start + vc.COORDS].reshape(21, 2)[vc.WRIST]
        self.assertTrue(np.allclose(left + right, 0.0, atol=1e-5))

    def test_a_collapsed_palm_is_declared_untracked_not_used_as_the_ruler(self):
        row = self.two_hand_row()
        # A knuckle a hundred-thousandth of a unit from the wrist, under fingertips
        # a fifth of a unit away: a detection artifact, not a small hand.
        broken = self.hand_row(LEFT, (0.3, 0.2), (1e-5, 0.0), (0.0, 0.2))
        row[LEFT] = broken[LEFT]
        converted = vc.wrist_frame(row[None, :])[0]
        self.assertTrue(np.all(converted[: vc.COORDS] == 0.0))
        self.assertAlmostEqual(float(converted[LEFT.start + 45]), 0.0)
        self.assertAlmostEqual(float(converted[vc.HAND_COUNT]), 1.0)
        # The hand that is left has to anchor the row by itself.
        remaining = converted[RIGHT.start : RIGHT.start + vc.COORDS].reshape(21, 2)
        self.assertAlmostEqual(float(np.linalg.norm(remaining[vc.MIDDLE_MCP] - remaining[vc.WRIST])), 1 / 2.6, places=5)

    def test_a_row_whose_hands_all_collapse_comes_out_empty(self):
        row = self.two_hand_row()
        for block in (LEFT, RIGHT):
            wrist = tuple(float(value) for value in row[block][:2])
            row[block] = self.hand_row(block, wrist, (1e-5, 0.0), (0.0, 0.2))[block]
        converted = vc.wrist_frame(row[None, :])[0]
        self.assertAlmostEqual(float(np.abs(converted).max()), 0.0)

    def test_the_conversion_is_idempotent(self):
        features = self.two_hand_row()[None, :]
        once = vc.wrist_frame(features)
        self.assertTrue(np.allclose(vc.wrist_frame(once), once, atol=1e-5))

    def test_shape_and_roll_fields_survive_the_conversion(self):
        row = self.two_hand_row()
        converted = vc.wrist_frame(row[None, :])[0]
        for block in (LEFT, RIGHT):
            for offset in (vc.SPREAD, 43, 44):
                self.assertAlmostEqual(float(converted[block.start + offset]), float(row[block.start + offset]))


class StoredPrecisionTest(unittest.TestCase):
    """Half-precision storage is only safe while a hand is long compared to its own step."""

    @staticmethod
    def hand_row(block, wrist, palm, finger):
        """A hand `palm` long sitting at `wrist`, with its fingertips `finger` away.

        Deliberately proportioned like a real hand (fingertips about 2.5 palms out)
        so the only thing that can make it unreadable is where it sits.
        """
        return WristFrameTest.hand_row(block, wrist, (palm, 0.0), finger)

    def test_a_hand_shorter_than_its_own_storage_step_is_blind(self):
        # A palm of 0.02 shoulder units sits at coordinate 0.8, where half precision
        # can only land on multiples of about 0.0005: the hand is 41 steps long.
        row = np.zeros(vc.FEATURES_PER_FRAME, dtype=np.float32)
        row[LEFT] = self.hand_row(LEFT, (0.8, 0.2), 0.02, (0.02, 0.05))[LEFT]
        stored = row.astype(np.float16)[None, :]
        self.assertTrue(bool(vc.precision_blind_rows(stored)[0]))
        # The very same numbers held in float32 are fine, so this is about the
        # storage, not about the hand.
        self.assertFalse(bool(vc.precision_blind_rows(row[None, :].astype(np.float32))[0]))

    def test_a_hand_that_signs_close_enough_is_kept(self):
        stored = WristFrameTest().two_hand_row().astype(np.float16)[None, :]
        self.assertFalse(bool(vc.precision_blind_rows(stored)[0]))

    def test_an_unreadable_row_loses_both_hands_rather_than_re_anchoring_one(self):
        tiny = self.hand_row(LEFT, (0.8, 0.2), 0.02, (0.02, 0.05))
        row = WristFrameTest().two_hand_row()
        row[LEFT] = tiny[LEFT]
        stored = row.astype(np.float16)[None, :]
        blind = vc.precision_blind_rows(stored)
        converted = vc.wrist_frame(stored.astype(np.float32), blind)
        # Dropping only the small hand would leave the other one divided by a
        # different ruler than the phone divides it by, which measured worse than
        # the rounding itself by two orders of magnitude.
        self.assertTrue(np.all(converted[0] == 0.0))

    def test_the_rule_alone_still_leaves_a_good_hand_alone(self):
        tiny = self.hand_row(LEFT, (0.8, 0.2), 0.02, (0.02, 0.05))
        row = WristFrameTest().two_hand_row()
        row[LEFT] = tiny[LEFT]
        converted = vc.wrist_frame(row.astype(np.float16)[None, :].astype(np.float32))
        self.assertAlmostEqual(float(converted[0, RIGHT.start + 45]), 1.0)
        self.assertAlmostEqual(float(converted[0, vc.HAND_COUNT]), 2.0)


class LabelTest(unittest.TestCase):
    def test_gloss_labels_are_keyed_by_clip_not_by_gloss(self):
        labels = vc.load_gloss_labels()
        self.assertIn("hello", labels["asl/hello.mp4"])
        self.assertIn("hi", labels["asl/hi.mp4"])
        self.assertTrue(all(key.startswith(("asl/", "isl/")) for key in list(labels)[:200]))

    def test_language_and_gloss_helpers(self):
        self.assertEqual(vc.language_of("isl/how_long.mp4"), "isl")
        self.assertEqual(vc.gloss_of("isl/how_long.mp4"), "how_long")


if __name__ == "__main__":
    unittest.main()
