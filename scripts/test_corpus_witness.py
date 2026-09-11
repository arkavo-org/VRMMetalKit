#!/usr/bin/env python3
"""Unit tests for the corpus witness generator. Run: python3 scripts/test_corpus_witness.py"""
import itertools
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import corpus_witness as W

STUB_BINARY = """#!/usr/bin/env python3
import json
import sys

if sys.argv[1:3] == ["template", "list"]:
    print(json.dumps({"result": {"packs": [{"id": "test-template", "sha256": "deadbeef"}]}}))
    sys.exit(0)
sys.exit(1)
"""

EXIT_STUB = """#!/usr/bin/env python3
import sys

sys.stderr.write("stub stderr marker\\n")
sys.exit(%d)
"""

LOGGING_STUB = """#!/usr/bin/env python3
import json
import sys

stdin = None
if "--request" in sys.argv:
    index = sys.argv.index("--request")
    if index + 1 < len(sys.argv) and sys.argv[index + 1] == "-":
        stdin = sys.stdin.read()
with open(sys.argv[0] + ".log", "a", encoding="utf-8") as fh:
    fh.write(json.dumps({"argv": sys.argv[1:], "stdin": stdin}) + "\\n")
sys.exit(0)
"""

LINTER_STUB = """#!/usr/bin/env python3
import json

print(json.dumps([{"asset": {"height_m": 1.6}}]))
"""

DISABLE_REQUEST = {"edit": {"id": "outfit.top", "values": {"/enabled": False}}}


def command_name(argv):
    return " ".join(itertools.takewhile(lambda token: not token.startswith("--"), argv))


def write_stub(path, source, executable=False):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(source)
    if executable:
        os.chmod(path, 0o755)
    return path


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

    def test_search_reaches_a_target_only_the_accept_branch_can_find(self):
        """Target is reachable only by moving a SEARCH_CONTROLS key, never by the two
        DIRECT_CONTROLS keys, so the accept branch (`score < best_score`) must fire at
        least once for this to pass."""
        widths = W.rule_widths(PROFILE)

        def evaluate(controls):
            return {"proportions.hips_height_ratio": 0.5 + 0.10 * controls["body.proportion.legLength"]}

        target = {"proportions.hips_height_ratio": 0.51}
        starting_residual = W.residuals(evaluate({"body.proportion.legLength": 0.0}), target, widths)
        starting_score = max(starting_residual.values())

        a = W.solve("f", target, evaluate, widths, tolerance=0.02, budget=200, seed=42)
        b = W.solve("f", target, evaluate, widths, tolerance=0.02, budget=200, seed=42)

        self.assertEqual(a, b)
        self.assertTrue(a["eligible"])
        self.assertLess(max(a["residuals"].values()), starting_score)
        self.assertNotEqual(a["controls"]["body.proportion.legLength"], 0.0)

    def test_search_reaches_a_target_needing_several_coordinates_to_move_together(self):
        """A shared, monotonically shrinking step collapses to its floor after roughly 14
        rejections and then can barely move any coordinate for the rest of the budget. A
        target that needs three coordinates to move substantially and simultaneously is
        reachable only if a rejection on one coordinate leaves the others' exploration
        radius intact."""
        profile = {"rules": [
            {"metric": "proportions.hips_height_ratio", "severity": "must", "check": {"type": "range", "min": 0.5, "max": 0.62}},
            {"metric": "proportions.shoulder_width_ratio", "severity": "must", "check": {"type": "range", "min": 0.05, "max": 0.18}},
            {"metric": "proportions.arm_span_height_ratio", "severity": "must", "check": {"type": "range", "min": 0.5, "max": 0.7}},
        ]}
        widths = W.rule_widths(profile)

        def evaluate(controls):
            return {
                "proportions.hips_height_ratio": 0.5 + 0.06 * controls["body.proportion.legLength"],
                "proportions.shoulder_width_ratio": 0.10 + 0.06 * controls["body.proportion.shoulderWidth"],
                "proportions.arm_span_height_ratio": 0.55 + 0.10 * controls["body.proportion.armLength"],
            }

        target = {"proportions.hips_height_ratio": 0.55, "proportions.shoulder_width_ratio": 0.155,
                  "proportions.arm_span_height_ratio": 0.64}

        a = W.solve("multi", target, evaluate, widths, tolerance=0.05, budget=200, seed=42)
        b = W.solve("multi", target, evaluate, widths, tolerance=0.05, budget=200, seed=42)

        self.assertEqual(a, b)
        self.assertTrue(a["eligible"])
        for key in ("body.proportion.legLength", "body.proportion.shoulderWidth", "body.proportion.armLength"):
            self.assertGreater(abs(a["controls"][key]), 0.3)

    def test_infeasible_candidates_are_rejected_but_the_search_still_reaches_a_feasible_target(self):
        """Part of the legLength range is infeasible, simulating a build-time domain
        rejection (e.g. GARMENT_PENETRATION) discovered only by evaluating a candidate."""
        widths = W.rule_widths(PROFILE)
        infeasible_hits = []

        def evaluate(controls):
            if controls["body.proportion.legLength"] > 0.6:
                infeasible_hits.append(controls["body.proportion.legLength"])
                raise W.InfeasibleCandidate("simulated GARMENT_PENETRATION")
            return {"proportions.hips_height_ratio": 0.5 + 0.10 * controls["body.proportion.legLength"]}

        target = {"proportions.hips_height_ratio": 0.555}

        a = W.solve("f", target, evaluate, widths, tolerance=0.02, budget=200, seed=42)
        self.assertGreater(len(infeasible_hits), 0, "the search never reached the infeasible region; test is not exercising the rejection path")

        infeasible_hits.clear()
        b = W.solve("f", target, evaluate, widths, tolerance=0.02, budget=200, seed=42)

        self.assertEqual(a, b)
        self.assertTrue(a["eligible"])
        self.assertIsNone(a["infeasible"])
        self.assertLessEqual(a["controls"]["body.proportion.legLength"], 0.6)

    def test_infeasible_initial_candidate_is_ineligible_with_reason_and_no_search(self):
        """If the starting point (direct controls at target, search controls at zero) is
        itself infeasible, the family has no feasible baseline: record it ineligible with
        the rejection reason and never enter the search loop at all."""
        widths = W.rule_widths(PROFILE)
        calls = []

        def evaluate(controls):
            calls.append(dict(controls))
            raise W.InfeasibleCandidate("GARMENT_PENETRATION: top-v1 penetrates the body at rest")

        target = {"asset.height_m": 1.7584, "proportions.head_count": 7.232}

        w = W.solve("heroes-commander", target, evaluate, widths, tolerance=0.25, budget=200, seed=42)

        self.assertFalse(w["eligible"])
        self.assertEqual(w["residuals"], {})
        self.assertIn("GARMENT_PENETRATION", w["infeasible"])
        self.assertEqual(len(calls), 1)


class OutOfRangeControls(unittest.TestCase):
    def test_family_outside_a_direct_controls_range_is_ineligible_without_calling_evaluate(self):
        widths = W.rule_widths(PROFILE)
        control_ranges = {"body.heightM": (1.2, 2.0), "body.headCount": (4.5, 8.0)}
        target = {"asset.height_m": 1.1764, "proportions.head_count": 5.674}

        def evaluate(controls):
            raise AssertionError("evaluate() must not be called for an out-of-range family")

        witness = W.solve_family("heroes-alex", target, control_ranges, widths, evaluate,
                                 tolerance=0.25, budget=200, seed=42)

        self.assertFalse(witness["eligible"])
        self.assertIn("body.heightM", witness["residuals"])
        self.assertNotIn("body.headCount", witness["residuals"])

    def test_in_range_target_is_unaffected_and_still_calls_evaluate(self):
        widths = W.rule_widths(PROFILE)
        control_ranges = {"body.heightM": (1.2, 2.0), "body.headCount": (4.5, 8.0)}
        target = {"asset.height_m": 1.65, "proportions.head_count": 6.0}
        calls = []

        def evaluate(controls):
            calls.append(controls)
            return {"asset.height_m": controls["body.heightM"], "proportions.head_count": controls["body.headCount"]}

        witness = W.solve_family("in-range", target, control_ranges, widths, evaluate,
                                 tolerance=0.01, budget=50, seed=42)

        self.assertTrue(witness["eligible"])
        self.assertGreater(len(calls), 0)


class MainZeroFamilies(unittest.TestCase):
    """A measurements input with no families must still produce a complete, valid document."""

    def test_zero_families_still_writes_a_complete_document(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = os.path.join(tmp, "vrm-author")
            with open(binary, "w", encoding="utf-8") as fh:
                fh.write(STUB_BINARY)
            os.chmod(binary, 0o755)

            measurements = os.path.join(tmp, "measurements.json")
            with open(measurements, "w", encoding="utf-8") as fh:
                json.dump({"measurements": []}, fh)

            manifest = os.path.join(tmp, "manifest.json")
            with open(manifest, "w", encoding="utf-8") as fh:
                json.dump({"assets": []}, fh)

            profile = os.path.join(tmp, "profile.json")
            with open(profile, "w", encoding="utf-8") as fh:
                json.dump({"id": "test-profile", "rules": []}, fh)

            out = os.path.join(tmp, "witnesses.json")

            rc = W.main(["--measurements", measurements, "--manifest", manifest,
                        "--profile", profile, "--template", "test-template", "--out", out,
                        "--binary", binary, "--budget", "1", "--seed", "1"])

            self.assertEqual(rc, 0)
            self.assertTrue(os.path.exists(out))
            with open(out, encoding="utf-8") as fh:
                document = json.load(fh)
            self.assertEqual(document["families"], {})
            for key in ("corpusManifestSha256", "templateId", "templateSha256", "profileId",
                       "solver", "generated", "families"):
                self.assertIn(key, document)
            self.assertIn("styleLintSha256", document["generated"])
            self.assertIn("measurementsSha256", document["generated"])


class CLIExitClassification(unittest.TestCase):
    """Exit 1 and 2 are domain rejections; every other non-zero exit, and a failure to launch
    the binary at all, is infrastructure and must abort the run."""

    def test_exit_beyond_the_domain_codes_aborts_instead_of_rejecting_the_candidate(self):
        with tempfile.TemporaryDirectory() as tmp:
            for code in (3, 4, 5):
                with self.subTest(code=code):
                    binary = write_stub(os.path.join(tmp, f"exit{code}"), EXIT_STUB % code, executable=True)
                    with self.assertRaises(RuntimeError) as ctx:
                        W.run_cli([binary], tmp)
                    self.assertNotIsInstance(ctx.exception, W.InfeasibleCandidate)
                    self.assertIn(f"({code})", str(ctx.exception))
                    self.assertIn("stub stderr marker", str(ctx.exception))

    def test_a_launch_failure_aborts_and_is_not_a_domain_rejection(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(OSError) as ctx:
                W.run_cli([os.path.join(tmp, "no-such-binary"), "build"], tmp)
            self.assertNotIsInstance(ctx.exception, W.InfeasibleCandidate)


class DefaultGarmentDisable(unittest.TestCase):
    def test_disable_is_issued_after_project_init_and_before_the_first_control_set(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = write_stub(os.path.join(tmp, "vrm-author"), LOGGING_STUB, executable=True)
            linter = write_stub(os.path.join(tmp, "style_lint.py"), LINTER_STUB)
            workdir = os.path.join(tmp, "work")
            os.makedirs(workdir)

            evaluate = W.cli_evaluator(binary, "test-template", 42, linter, workdir, ["asset.height_m"])
            observed = evaluate({"body.heightM": 1.65})

            self.assertEqual(observed, {"asset.height_m": 1.6})
            with open(binary + ".log", encoding="utf-8") as fh:
                calls = [json.loads(line) for line in fh if line.strip()]
            self.assertEqual([command_name(c["argv"]) for c in calls],
                             ["project init", "object set", "control set", "build"])
            disable = calls[1]
            self.assertEqual(disable["argv"],
                             ["object", "set", "--project", os.path.join(workdir, "a.vrmauthor"),
                              "--request", "-"])
            self.assertEqual(json.loads(disable["stdin"]), DISABLE_REQUEST)

    def test_the_verification_evaluator_builds_the_same_controls_with_the_garment_enabled(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = write_stub(os.path.join(tmp, "vrm-author"), LOGGING_STUB, executable=True)
            linter = write_stub(os.path.join(tmp, "style_lint.py"), LINTER_STUB)
            workdir = os.path.join(tmp, "work")
            os.makedirs(workdir)

            verify = W.cli_evaluator(binary, "test-template", 42, linter, workdir, ["asset.height_m"],
                                     disable_default_garment=False)
            verify({"body.heightM": 1.65})

            with open(binary + ".log", encoding="utf-8") as fh:
                calls = [json.loads(line) for line in fh if line.strip()]
            self.assertEqual([command_name(c["argv"]) for c in calls],
                             ["project init", "control set", "build"])


class GarmentFit(unittest.TestCase):
    WIDTHS = W.rule_widths(PROFILE)
    RANGES = {"body.heightM": (1.2, 2.0), "body.headCount": (4.5, 8.0)}
    TARGET = {"asset.height_m": 1.75, "proportions.head_count": 7.0}

    @staticmethod
    def evaluate(controls):
        return {"asset.height_m": controls["body.heightM"],
                "proportions.head_count": controls["body.headCount"]}

    def solve(self, verify, target=None, ranges=None):
        return W.solve_family("f", target or self.TARGET, ranges if ranges is not None else self.RANGES,
                              self.WIDTHS, self.evaluate, tolerance=0.01, budget=50, seed=42,
                              verify=verify)

    def test_a_solved_witness_records_the_disable_step_in_its_replay_steps(self):
        witness = self.solve(lambda controls: {})
        steps = witness["replaySteps"]
        self.assertEqual([s["command"] for s in steps],
                         ["project init", "object set", "control set", "build"])
        self.assertEqual(steps[1]["request"], DISABLE_REQUEST)
        self.assertEqual(steps[2]["request"], {"edit": {"object": "avatar:main", "values": witness["controls"]}})

    def test_a_garment_rejection_on_the_verification_build_is_recorded_not_penalised(self):
        seen = []

        def verify(controls):
            seen.append(dict(controls))
            raise W.InfeasibleCandidate("GARMENT_PENETRATION: top-v1 penetrates the body")

        rejected = self.solve(verify)
        accepted = self.solve(lambda controls: {})

        self.assertTrue(rejected["eligible"])
        self.assertEqual(rejected["garmentFit"], "fail")
        self.assertEqual(rejected["controls"], accepted["controls"])
        self.assertEqual(rejected["residuals"], accepted["residuals"])
        self.assertEqual(seen, [accepted["controls"]])

    def test_a_verification_build_that_succeeds_is_recorded_as_a_pass(self):
        witness = self.solve(lambda controls: {"asset.height_m": 1.75})
        self.assertTrue(witness["eligible"])
        self.assertEqual(witness["garmentFit"], "pass")

    def test_an_ineligible_family_carries_no_garment_fit(self):
        def verify(controls):
            raise AssertionError("an ineligible family must not be verified")

        unreachable = W.solve_family("f", {"asset.height_m": 9.0}, {}, self.WIDTHS,
                                     lambda controls: {"asset.height_m": 1.6},
                                     tolerance=0.01, budget=10, seed=42, verify=verify)
        out_of_range = W.solve_family("f", {"asset.height_m": 1.1764}, self.RANGES, self.WIDTHS,
                                      self.evaluate, tolerance=0.25, budget=200, seed=42, verify=verify)

        for witness in (unreachable, out_of_range):
            self.assertFalse(witness["eligible"])
            self.assertNotIn("garmentFit", witness)
            self.assertNotIn("replaySteps", witness)

    def test_an_infrastructure_failure_on_the_verification_build_still_raises(self):
        def verify(controls):
            raise RuntimeError("command failed (5): vrm-author build")

        with self.assertRaises(RuntimeError) as ctx:
            self.solve(verify)
        self.assertNotIsInstance(ctx.exception, W.InfeasibleCandidate)


if __name__ == "__main__":
    unittest.main(verbosity=2)
