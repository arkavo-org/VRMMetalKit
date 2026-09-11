#!/usr/bin/env python3
"""Unit tests for the corpus witness generator. Run: python3 scripts/test_corpus_witness.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import corpus_witness as W


PROFILE = {"rules": [
    {"metric": "asset.height_m", "severity": "should", "check": {"type": "range", "min": 1.1, "max": 2.0}},
    {"metric": "proportions.head_count", "severity": "should", "check": {"type": "range", "min": 4.5, "max": 8.0}},
    {"metric": "proportions.hips_height_ratio", "severity": "must", "check": {"type": "range", "min": 0.5, "max": 0.62}},
    {"metric": "proportions.limb_asymmetry", "severity": "must", "check": {"type": "range", "max": 0.02}},
]}


class Widths(unittest.TestCase):
    def test_two_sided_ranges_yield_widths(self):
        w = W.rule_widths(PROFILE)
        self.assertAlmostEqual(w["asset.height_m"], 0.9)
        self.assertAlmostEqual(w["proportions.hips_height_ratio"], 0.12)

    def test_one_sided_rules_have_no_width(self):
        self.assertNotIn("proportions.limb_asymmetry", W.rule_widths(PROFILE))


class Residuals(unittest.TestCase):
    def test_residual_is_scaled_by_rule_width(self):
        w = W.rule_widths(PROFILE)
        r = W.residuals({"asset.height_m": 1.19}, {"asset.height_m": 1.10}, w)
        self.assertAlmostEqual(r["asset.height_m"], 0.1)

    def test_a_metric_without_a_width_is_skipped(self):
        w = W.rule_widths(PROFILE)
        r = W.residuals({"proportions.limb_asymmetry": 0.5}, {"proportions.limb_asymmetry": 0.0}, w)
        self.assertEqual(r, {})

    def test_eligible_requires_every_residual_within_tolerance(self):
        self.assertTrue(W.eligible({"a": 0.1, "b": 0.2}, 0.25))
        self.assertFalse(W.eligible({"a": 0.1, "b": 0.9}, 0.25))

    def test_eligible_is_false_when_nothing_was_measured(self):
        self.assertFalse(W.eligible({}, 0.25))


class Solve(unittest.TestCase):
    def test_solver_reaches_a_linear_target_and_is_deterministic(self):
        target = {"asset.height_m": 1.75, "proportions.head_count": 7.0}
        widths = W.rule_widths(PROFILE)

        def evaluate(controls):
            return {"asset.height_m": controls["body.heightM"],
                    "proportions.head_count": controls["body.headCount"]}

        a = W.solve("f", target, evaluate, widths, tolerance=0.01, budget=50, seed=42)
        b = W.solve("f", target, evaluate, widths, tolerance=0.01, budget=50, seed=42)
        self.assertTrue(a["eligible"])
        self.assertEqual(a, b)
        self.assertAlmostEqual(a["controls"]["body.heightM"], 1.75)

    def test_unreachable_target_is_ineligible_with_named_residuals(self):
        target = {"asset.height_m": 9.0}
        widths = W.rule_widths(PROFILE)

        def evaluate(controls):
            return {"asset.height_m": 1.6}

        w = W.solve("f", target, evaluate, widths, tolerance=0.01, budget=10, seed=42)
        self.assertFalse(w["eligible"])
        self.assertGreater(w["residuals"]["asset.height_m"], 0.01)


if __name__ == "__main__":
    unittest.main(verbosity=2)
