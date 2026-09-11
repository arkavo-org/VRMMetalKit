#!/usr/bin/env python3
# Copyright 2026 Arkavo
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Tests for scripts/acceptance_run.py.

    python3 scripts/test_acceptance_run.py

Every case runs from a synthetic pack built around the spec-minimal VRM from
test_style_lint.minimal_vrm, so no gitignored .vrm fixture is needed.
"""
import contextlib
import copy
import io
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import acceptance_run as R  # noqa: E402
import test_style_lint as T  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ACCEPTANCE = os.path.join(REPO, "docs", "proposals", "vrm-author-cli", "acceptance")
SCHEMA_PATH = os.path.join(ACCEPTANCE, "pack.schema.json")
SHIPPED_PACK = os.path.join(ACCEPTANCE, "packs", "style-lint.json")
LINTER = "scripts/style_lint.py"
PROFILE = "docs/style/profiles/vroid-lineage-anime.json"


def run_main(argv):
    out = io.StringIO()
    err = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = R.main(argv)
    return code, out.getvalue(), err.getvalue()


class PackFactory:
    """Builds a valid synthetic pack whose single fixture is the minimal VRM written into a temp dir."""

    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="acceptance_test_")
        self.fixture_bytes = T.pack_glb(*T.minimal_vrm(T.RobustnessTests.REQUIRED))
        self.fixture_path = os.path.join(self.dir, "minimal.bin")
        with open(self.fixture_path, "wb") as fh:
            fh.write(self.fixture_bytes)
        self.profile = R.load_json(os.path.join(REPO, PROFILE))

    def cleanup(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def pack(self, **overrides):
        oracles = {LINTER: R.sha256_file(os.path.join(REPO, LINTER)), PROFILE: R.sha256_file(os.path.join(REPO, PROFILE))}
        p = {
            "id": "synthetic", "version": "0.0.1", "operation": "style lint", "operationVersion": 1,
            "requestSchemaHash": "", "resultSchemaHash": "", "packHash": "",
            "provenance": {"author": {"provider": "t", "family": "t", "version": "t", "role": "acceptance-author"},
                           "reviewer": {"provider": "", "family": "", "version": "", "role": "independent-reviewer"},
                           "sources": [], "reviewReceipt": ""},
            "scope": {"inputClasses": ["vrm-1.0"], "parameterRanges": {}, "invariants": [], "units": "m", "excluded": []},
            "fixtures": [{"id": "minimal", "path": "minimal.bin", "pathEnv": "SYNTHETIC_FIXTURES",
                          "sha256": R.sha256_bytes(self.fixture_bytes), "class": "degenerate",
                          "expected": {"verdict": "nonconforming", "exit_code": 1}}],
            "seeds": [],
            "runner": {"kind": "python", "entryPoint": LINTER, "profile": PROFILE,
                       "environment": {"pinnedCommit": "0" * 40, "oracleHashes": oracles}},
            "assertions": [
                {"id": "verdict", "kind": "report-field", "target": "verdict", "expected": "conforming"},
                {"id": "profile", "kind": "report-field", "target": "profile", "expected": self.profile["id"]},
                {"id": "exit_code", "kind": "exit-code", "target": "process", "expected": 0},
                {"id": "error_class", "kind": "error-class", "target": "process", "expected": None},
            ],
            "mutants": [{"id": "noop", "description": "control", "expectedClassification": "reject",
                         "transform": {"kind": "metadata-noop", "fixture": "minimal", "field": "asset.generator", "value": "edited"}}],
            "visual": {"applicable": False, "applicabilityRecord": "numeric-only", "views": [], "motions": [], "landmarks": [], "thresholds": {}, "adjudication": "none"},
            "evidencePolicy": {"requiredLevel": "fixture-tested",
                               "dimensions": {"fixture": "required", "corpus": "inapplicable", "visual": "inapplicable", "interoperability": "inapplicable", "provenance": "required"},
                               "heldOutPolicy": "none"},
            "resources": {"cpuSeconds": 60, "gpuSeconds": 0, "judgeCalls": 0, "deadlineSeconds": 60, "maxRepairAttempts": 0, "onFailure": "fail"},
            "reproduction": {"entryPoint": "python3 scripts/acceptance_run.py", "inputManifestSchema": SCHEMA_PATH, "outputManifestSchema": "", "canonicalArtifacts": []},
        }
        p.update(overrides)
        p["packHash"] = R.compute_pack_hash(p)
        return p

    def write(self, pack, name="pack.json"):
        path = os.path.join(self.dir, name)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(pack, fh)
        return path

    def run(self, pack, fixtures=None):
        path = self.write(pack)
        argv = [path, "--json"]
        if fixtures is not None:
            argv += ["--fixtures", fixtures]
        else:
            argv += ["--fixtures", self.dir]
        code, out, err = run_main(argv)
        return code, (json.loads(out) if out.strip().startswith("{") else None), err


class RunnerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.f = PackFactory()
        cls.schema = R.load_json(SCHEMA_PATH)

    @classmethod
    def tearDownClass(cls):
        cls.f.cleanup()

    def test_schema_rejects_unknown_top_level_key(self):
        pack = self.f.pack()
        pack["bogus"] = 1
        pack["packHash"] = R.compute_pack_hash(pack)
        errors = R.validate_pack(pack, self.schema)
        self.assertTrue(any("bogus" in e for e in errors), errors)
        code, _, err = self.f.run(pack)
        self.assertEqual(code, 4)
        self.assertIn("bogus", err)

    def test_pack_hash_mismatch_is_invalid(self):
        pack = self.f.pack()
        pack["packHash"] = "0" * 64
        code, result, err = self.f.run(pack)
        self.assertEqual(code, 4)
        self.assertIsNone(result)
        self.assertIn("packHash", err)

    def test_oracle_hash_mismatch_fails(self):
        pack = self.f.pack()
        pack["runner"]["environment"]["oracleHashes"][LINTER] = "1" * 64
        pack["packHash"] = R.compute_pack_hash(pack)
        code, result, _ = self.f.run(pack)
        self.assertEqual(code, 1)
        self.assertEqual(result["status"], "fail")
        self.assertIn("oracle hash mismatch", result["reason"])
        self.assertEqual(result["oracleMismatches"][0]["path"], LINTER)
        self.assertEqual(result["fixtures"], [])

    def test_absent_fixture_is_pending_not_pass(self):
        pack = self.f.pack()
        pack["fixtures"][0]["path"] = "does-not-exist.bin"
        pack["mutants"] = [{"id": "fab", "description": "", "expectedClassification": "reject",
                            "transform": {"kind": "report-fabricated", "envelope": {"report": None, "oracleHashes": {}, "exitCode": 0}}}]
        pack["packHash"] = R.compute_pack_hash(pack)
        code, result, _ = self.f.run(pack)
        self.assertEqual(code, 2)
        self.assertEqual(result["status"], "pending")
        self.assertEqual(result["fixtures"][0]["status"], "pending")
        self.assertEqual(result["dimensions"]["fixture"], "pending")

    def test_fixture_hash_mismatch_fails(self):
        pack = self.f.pack()
        pack["fixtures"][0]["sha256"] = "2" * 64
        pack["packHash"] = R.compute_pack_hash(pack)
        code, result, _ = self.f.run(pack)
        self.assertEqual(code, 1)
        self.assertEqual(result["fixtures"][0]["status"], "fail")
        self.assertIn("sha256", result["fixtures"][0]["reason"])

    def test_synthetic_pack_passes_with_controls(self):
        pack = self.f.pack()
        pack["mutants"].append({"id": "fab", "description": "", "expectedClassification": "reject",
                                "transform": {"kind": "report-fabricated",
                                              "envelope": {"report": {"profile": self.f.profile["id"], "profile_version": self.f.profile["version"], "verdict": "conforming",
                                                                      "summary": {}, "results": []},
                                                           "oracleHashes": {LINTER: pack["runner"]["environment"]["oracleHashes"][LINTER], PROFILE: "3" * 64},
                                                           "exitCode": 0}}})
        pack["packHash"] = R.compute_pack_hash(pack)
        code, result, _ = self.f.run(pack)
        self.assertEqual(code, 0, json.dumps(result, indent=1))
        self.assertEqual(result["status"], "pass")
        by_id = {m["id"]: m for m in result["mutants"]}
        self.assertEqual(by_id["noop"]["classification"], "reject")
        self.assertTrue(by_id["noop"]["integrityRejected"] and by_id["noop"]["gradeUnchanged"])
        self.assertEqual(by_id["fab"]["classification"], "reject")
        self.assertEqual(result["dimensions"]["provenance"], "pass")

    def test_fabricated_report_with_correct_hashes_is_not_rejected(self):
        pack = self.f.pack()
        pack["mutants"] = [{"id": "fab", "description": "", "expectedClassification": "reject",
                            "transform": {"kind": "report-fabricated",
                                          "envelope": {"report": {"profile": self.f.profile["id"], "profile_version": self.f.profile["version"], "verdict": "conforming", "summary": {}, "results": []},
                                                       "oracleHashes": dict(pack["runner"]["environment"]["oracleHashes"]), "exitCode": 0}}}]
        pack["packHash"] = R.compute_pack_hash(pack)
        code, result, _ = self.f.run(pack)
        self.assertEqual(code, 1)
        self.assertEqual(result["mutants"][0]["classification"], "accepted")
        self.assertEqual(result["dimensions"]["provenance"], "fail")

    def test_insensitive_mutant_fails_the_pack(self):
        pack = self.f.pack()
        pack["mutants"] = [{"id": "dead-mutation", "description": "matches no material", "expectedClassification": "reject",
                            "transform": {"kind": "style-mutation:mtoon", "fixture": "minimal", "materialNameContains": ["NO_SUCH_MATERIAL"],
                                          "changes": {"shadingToonyFactor": 0.2}, "expectFlip": {"shade.body_two_tone": "fail"}}}]
        pack["packHash"] = R.compute_pack_hash(pack)
        code, result, _ = self.f.run(pack)
        self.assertEqual(code, 1)
        self.assertEqual(result["status"], "fail")
        m = result["mutants"][0]
        self.assertEqual(m["classification"], "not-rejected")
        self.assertFalse(m["flips"][0]["flipped"])
        self.assertEqual(m["baselineVerdict"], m["mutantVerdict"])

    def test_metadata_noop_that_changes_grade_breaks_control(self):
        pack = self.f.pack()
        pack["mutants"] = [{"id": "not-a-noop", "description": "", "expectedClassification": "reject",
                            "transform": {"kind": "metadata-noop", "fixture": "minimal", "field": "extensions.VRMC_vrm.meta.name", "value": ""}}]
        pack["packHash"] = R.compute_pack_hash(pack)
        code, result, _ = self.f.run(pack)
        self.assertEqual(code, 1)
        self.assertEqual(result["mutants"][0]["classification"], "control-broken")

    def test_metadata_noop_that_edits_nothing_breaks_control(self):
        pack = self.f.pack()
        pack["mutants"] = [{"id": "same-value", "description": "", "expectedClassification": "reject",
                            "transform": {"kind": "metadata-noop", "fixture": "minimal", "field": "asset.version", "value": "2.0"}}]
        pack["packHash"] = R.compute_pack_hash(pack)
        code, result, _ = self.f.run(pack)
        self.assertEqual(code, 1)
        self.assertEqual(result["mutants"][0]["classification"], "control-broken")
        self.assertIn("nothing was edited", result["mutants"][0]["reason"])

    def test_missing_entry_point_is_missing_handler(self):
        pack = self.f.pack()
        pack["runner"]["entryPoint"] = "scripts/no_such_handler.py"
        pack["runner"]["environment"]["oracleHashes"]["scripts/no_such_handler.py"] = "4" * 64
        pack["packHash"] = R.compute_pack_hash(pack)
        code, result, _ = self.f.run(pack)
        self.assertEqual(code, 3)
        self.assertEqual(result["status"], "missing-handler")
        self.assertEqual(result["fixtures"], [])
        self.assertNotEqual(result["status"], "pass")

    def test_unknown_expected_key_is_invalid(self):
        pack = self.f.pack()
        pack["fixtures"][0]["expected"]["not_an_assertion"] = 1
        pack["packHash"] = R.compute_pack_hash(pack)
        code, _, err = self.f.run(pack)
        self.assertEqual(code, 4)
        self.assertIn("not_an_assertion", err)


FAKE_SWIFT = r"""#!/bin/sh
printf '%s\n' "$@" > "$FAKE_SWIFT_ARGS"
case "$FAKE_SWIFT_MODE" in
  pass)
    echo "Building for debugging..."
    echo "Test Suite 'FakeSuite' started at 2026-09-10 12:00:00.000."
    echo "Test Case '-[VRMAuthorKitTests.FakeSuite testAlpha]' started."
    echo "Test Case '-[VRMAuthorKitTests.FakeSuite testAlpha]' passed (0.001 seconds)."
    echo "Test Case '-[VRMAuthorKitTests.FakeSuite testMutantRejected]' started."
    echo "Test Case '-[VRMAuthorKitTests.FakeSuite testMutantRejected]' passed (0.001 seconds)."
    echo "Test Suite 'FakeSuite' passed at 2026-09-10 12:00:00.002."
    printf '\t Executed 2 tests, with 0 failures (0 unexpected) in 0.002 (0.003) seconds\n'
    echo "Test Suite 'OtherBundle.xctest' passed at 2026-09-10 12:00:00.003."
    printf '\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds\n'
    exit 0 ;;
  fail)
    echo "Test Case '-[VRMAuthorKitTests.FakeSuite testAlpha]' started."
    echo "/repo/Tests/FakeSuite.swift:10: error: -[VRMAuthorKitTests.FakeSuite testAlpha] : XCTAssertEqual failed: (\"1\") is not equal to (\"2\")"
    echo "Test Case '-[VRMAuthorKitTests.FakeSuite testAlpha]' failed (0.001 seconds)."
    echo "Test Case '-[VRMAuthorKitTests.FakeSuite testMutantRejected]' started."
    echo "Test Case '-[VRMAuthorKitTests.FakeSuite testMutantRejected]' passed (0.001 seconds)."
    printf '\t Executed 2 tests, with 1 failure (1 unexpected) in 0.002 (0.003) seconds\n'
    exit 1 ;;
  mutant-missing)
    echo "Test Case '-[VRMAuthorKitTests.FakeSuite testAlpha]' passed (0.001 seconds)."
    printf '\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 (0.001) seconds\n'
    exit 0 ;;
  none)
    echo "Building for debugging..."
    echo "Build complete! (0.48 sec)"
    echo "warning: No matching test cases were run" >&2
    exit 0 ;;
  override)
    echo "Test Case '-[VRMAuthorKitTests.FakeSuite testAlpha]' passed (0.001 seconds)."
    echo "Test Case '-[VRMAuthorKitTests.FakeSuite testMutantRejected]' passed (0.001 seconds)."
    echo "Test Case '-[VRMAuthorKitTests.OtherSuite testOtherMutantRejected]' passed (0.001 seconds)."
    printf '\t Executed 3 tests, with 0 failures (0 unexpected) in 0.003 (0.003) seconds\n'
    exit 0 ;;
  override-only)
    echo "Test Case '-[VRMAuthorKitTests.OtherSuite testOtherMutantRejected]' passed (0.001 seconds)."
    printf '\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 (0.001) seconds\n'
    exit 0 ;;
  compile-error)
    echo "/repo/Sources/X.swift:1:1: error: cannot find 'Nope' in scope" >&2
    echo "error: fatalError" >&2
    exit 1 ;;
esac
"""


class SwiftTestRunnerTests(unittest.TestCase):
    """swift-test packs run against a fake `swift` on PATH so the tests stay fast and hermetic."""

    @classmethod
    def setUpClass(cls):
        cls.f = PackFactory()
        cls.bin = os.path.join(cls.f.dir, "bin")
        os.makedirs(cls.bin)
        cls.swift = os.path.join(cls.bin, "swift")
        with open(cls.swift, "w", encoding="utf-8") as fh:
            fh.write(FAKE_SWIFT)
        os.chmod(cls.swift, 0o755)
        cls.args_file = os.path.join(cls.f.dir, "swift-args.txt")

    @classmethod
    def tearDownClass(cls):
        cls.f.cleanup()

    def pack(self, **overrides):
        base = {
            "runner": {"kind": "swift-test", "entryPoint": "FakeSuite",
                       "environment": {"pinnedCommit": "0" * 40, "oracleHashes": {LINTER: R.sha256_file(os.path.join(REPO, LINTER))}}},
            "assertions": [
                {"id": "exit_code", "kind": "exit-code", "target": "process", "expected": 0},
                {"id": "executed", "kind": "report-field", "target": "executed", "expected": 2},
                {"id": "failed", "kind": "report-field", "target": "failed", "expected": 0},
            ],
            "mutants": [{"id": "wrong-units", "description": "suite injects metre/centimetre confusion", "expectedClassification": "reject",
                         "transform": {"kind": "swift-test", "test": "testMutantRejected"}}],
        }
        base.update(overrides)
        p = self.f.pack(**base)
        p["fixtures"][0]["expected"] = {}
        p["packHash"] = R.compute_pack_hash(p)
        return p

    def run_mode(self, mode, pack):
        env = dict(os.environ)
        env.update({"PATH": self.bin + os.pathsep + env.get("PATH", ""), "FAKE_SWIFT_MODE": mode, "FAKE_SWIFT_ARGS": self.args_file})
        if os.path.exists(self.args_file):
            os.remove(self.args_file)
        old = os.environ.copy()
        os.environ.clear()
        os.environ.update(env)
        try:
            return self.f.run(pack)
        finally:
            os.environ.clear()
            os.environ.update(old)

    def test_swift_test_pack_validates(self):
        self.assertEqual(R.validate_pack(self.pack(), R.load_json(SCHEMA_PATH)), [])
        bad = self.pack()
        bad["mutants"][0]["transform"] = {"kind": "swift-test"}
        bad["packHash"] = R.compute_pack_hash(bad)
        self.assertTrue(any("test name" in e for e in R.validate_pack(bad, R.load_json(SCHEMA_PATH))))
        py = self.f.pack(mutants=[{"id": "m", "description": "", "expectedClassification": "reject", "transform": {"kind": "swift-test", "test": "t"}}])
        self.assertTrue(any("require runner.kind swift-test" in e for e in R.validate_pack(py, R.load_json(SCHEMA_PATH))))

    def test_passing_suite_passes_fixture_dimension_and_mutants(self):
        code, result, err = self.run_mode("pass", self.pack())
        self.assertEqual(code, 0, err)
        self.assertEqual(result["status"], "pass")
        self.assertEqual(result["dimensions"]["fixture"], "pass")
        self.assertEqual(result["dimensions"]["provenance"], "pass")
        self.assertEqual(result["fixtures"][0]["status"], "pass")
        self.assertEqual(result["mutants"][0]["classification"], "reject")
        self.assertEqual(result["swiftTest"]["executed"], 2)
        with open(self.args_file, encoding="utf-8") as fh:
            self.assertEqual(fh.read().split(), ["test", "--disable-sandbox", "--filter", "FakeSuite"])

    def test_failing_tests_fail_with_names(self):
        code, result, _ = self.run_mode("fail", self.pack())
        self.assertEqual(code, 1)
        self.assertEqual(result["status"], "fail")
        self.assertIn("FakeSuite.testAlpha", result["reason"])
        self.assertIn("FakeSuite.testAlpha", result["fixtures"][0]["reason"])
        self.assertEqual(result["swiftTest"]["failingTests"], ["FakeSuite.testAlpha"])
        self.assertEqual(result["mutants"][0]["status"], "pass")

    def test_missing_mutant_test_is_not_rejected(self):
        code, result, _ = self.run_mode("mutant-missing", self.pack())
        self.assertEqual(code, 1)
        self.assertEqual(result["mutants"][0]["classification"], "not-executed")
        self.assertEqual(result["fixtures"][0]["status"], "fail")

    def test_zero_matching_tests_is_missing_handler(self):
        code, result, _ = self.run_mode("none", self.pack())
        self.assertEqual(code, 3)
        self.assertEqual(result["status"], "missing-handler")
        self.assertIn("FakeSuite", result["reason"])
        self.assertEqual(result["fixtures"], [])

    def test_compile_error_fails_with_diagnostic(self):
        code, result, _ = self.run_mode("compile-error", self.pack())
        self.assertEqual(code, 1)
        self.assertEqual(result["status"], "fail")
        self.assertIn("error:", result["reason"])
        self.assertEqual(result["dimensions"]["fixture"], "fail")

    def test_absent_fixture_is_pending_even_when_suite_passes(self):
        pack = self.pack()
        pack["fixtures"][0]["path"] = "does-not-exist.bin"
        pack["packHash"] = R.compute_pack_hash(pack)
        code, result, _ = self.run_mode("pass", pack)
        self.assertEqual(code, 2)
        self.assertEqual(result["fixtures"][0]["status"], "pending")

    def test_oracle_mismatch_short_circuits_before_swift(self):
        pack = self.pack()
        pack["runner"]["environment"]["oracleHashes"][LINTER] = "1" * 64
        pack["packHash"] = R.compute_pack_hash(pack)
        code, result, _ = self.run_mode("pass", pack)
        self.assertEqual(code, 1)
        self.assertIn("oracle hash mismatch", result["reason"])
        self.assertFalse(os.path.exists(self.args_file))

    def synthetic_pack(self, **overrides):
        pack = self.pack(**overrides)
        pack["fixtures"] = [{"id": "in-process", "path": "synthetic:project built by the suite", "synthetic": True,
                             "class": "positive", "expected": {}}]
        pack["packHash"] = R.compute_pack_hash(pack)
        return pack

    def test_synthetic_fixture_validation(self):
        schema = R.load_json(SCHEMA_PATH)
        self.assertEqual(R.validate_pack(self.synthetic_pack(), schema), [])
        no_hash = self.pack()
        del no_hash["fixtures"][0]["sha256"]
        self.assertTrue(any("sha256 is required" in e for e in R.validate_pack(no_hash, schema)))
        pinned_synthetic = self.synthetic_pack()
        pinned_synthetic["fixtures"][0]["sha256"] = "5" * 64
        self.assertTrue(any("omit sha256" in e for e in R.validate_pack(pinned_synthetic, schema)))
        py = self.f.pack()
        py["fixtures"] = [{"id": "s", "path": "synthetic:x", "synthetic": True, "class": "positive", "expected": {}}]
        self.assertTrue(any("require runner.kind swift-test" in e for e in R.validate_pack(py, schema)))
        fab = self.pack(mutants=[{"id": "fab", "description": "", "expectedClassification": "reject",
                                  "transform": {"kind": "report-fabricated", "suite": "OtherSuite", "envelope": {"report": None, "oracleHashes": {}, "exitCode": 0}}}])
        self.assertTrue(any("transform.suite applies only" in e for e in R.validate_pack(fab, schema)))

    def test_synthetic_fixture_is_graded_from_the_suite_without_a_file(self):
        code, result, err = self.run_mode("pass", self.synthetic_pack())
        self.assertEqual(code, 0, err)
        fx = result["fixtures"][0]
        self.assertEqual(fx["status"], "pass")
        self.assertTrue(fx["synthetic"])
        self.assertEqual(fx["sha256"], "")
        self.assertNotIn("resolvedPath", fx)
        code, result, _ = self.run_mode("fail", self.synthetic_pack())
        self.assertEqual(code, 1)
        self.assertEqual(result["fixtures"][0]["status"], "fail")

    def test_mutant_suite_override_adds_filter_and_locates_the_test(self):
        pack = self.synthetic_pack(mutants=[
            {"id": "in-suite", "description": "", "expectedClassification": "reject", "transform": {"kind": "swift-test", "test": "testMutantRejected"}},
            {"id": "elsewhere", "description": "", "expectedClassification": "reject",
             "transform": {"kind": "swift-test", "suite": "OtherSuite", "test": "testOtherMutantRejected"}}],
            assertions=[{"id": "exit_code", "kind": "exit-code", "target": "process", "expected": 0},
                        {"id": "failed", "kind": "report-field", "target": "failed", "expected": 0}])
        code, result, err = self.run_mode("override", pack)
        self.assertEqual(code, 0, err)
        by_id = {m["id"]: m for m in result["mutants"]}
        self.assertEqual(by_id["in-suite"]["test"], "FakeSuite.testMutantRejected")
        self.assertEqual(by_id["elsewhere"]["test"], "OtherSuite.testOtherMutantRejected")
        self.assertEqual(by_id["elsewhere"]["classification"], "reject")
        with open(self.args_file, encoding="utf-8") as fh:
            self.assertEqual(fh.read().split(), ["test", "--disable-sandbox", "--filter", "FakeSuite", "--filter", "OtherSuite"])
        code, result, _ = self.run_mode("pass", pack)
        self.assertEqual(code, 1)
        by_id = {m["id"]: m for m in result["mutants"]}
        self.assertEqual(by_id["in-suite"]["classification"], "reject")
        self.assertEqual(by_id["elsewhere"]["classification"], "not-executed")

    def test_entry_point_suite_absent_is_missing_handler_even_when_an_override_suite_ran(self):
        pack = self.synthetic_pack(mutants=[{"id": "elsewhere", "description": "", "expectedClassification": "reject",
                                             "transform": {"kind": "swift-test", "suite": "OtherSuite", "test": "testOtherMutantRejected"}}])
        code, result, _ = self.run_mode("override-only", pack)
        self.assertEqual(code, 3)
        self.assertEqual(result["status"], "missing-handler")
        self.assertIn("FakeSuite", result["reason"])
        self.assertEqual(result["fixtures"], [])
        self.assertEqual(result["mutants"], [])

    def test_parse_output_keeps_last_status_per_test(self):
        text = ("Test Case '-[M.S testA]' started.\nTest Case '-[M.S testA]' passed (0.1 seconds).\n"
                "Test Case '-[M.S testB]' failed (0.1 seconds).\nTest Case '-[M.S testB]' passed (0.1 seconds).\n")
        self.assertEqual(R.Runner.parse_swift_test_output(text), {"S.testA": "passed", "S.testB": "passed"})
        self.assertEqual(R.Runner.parse_swift_test_output("warning: No matching test cases were run"), {})


class ShippedPackTests(unittest.TestCase):
    def setUp(self):
        self.schema = R.load_json(SCHEMA_PATH)
        self.pack = R.load_json(SHIPPED_PACK)

    def test_shipped_pack_validates(self):
        self.assertEqual(R.validate_pack(self.pack, self.schema), [])

    def test_shipped_pack_hash_verifies(self):
        self.assertEqual(self.pack["packHash"], R.compute_pack_hash(self.pack))

    def test_shipped_pack_pins_the_decided_oracles(self):
        oracles = self.pack["runner"]["environment"]["oracleHashes"]
        self.assertEqual(oracles["scripts/style_lint.py"], "ff9d41334e670747df1f8c28561cfb263b40325d427690c3aef052a173f05fcb")
        self.assertEqual(oracles["docs/style/profiles/vroid-lineage-anime.json"], "7eeb1f41bada650d39b7c32a31c273bbd889cca22d390164b8a7dd9b1f9c1f35")
        self.assertEqual(oracles["docs/style/corpus/vroid-lineage-anime.manifest.json"], "b393eb0c8c49050caab772f8bdd6ad884d6dd027ad310249ae9805a22b1a8cb6")
        self.assertEqual(self.pack["runner"]["environment"]["pinnedCommit"], "a020125384c0c15b6479e7dc304ec48c899887dc")

    def test_shipped_pack_covers_every_fixture_class_and_mutant_kind(self):
        self.assertEqual({f["class"] for f in self.pack["fixtures"]}, {"positive", "negative", "degenerate"})
        kinds = {m["transform"]["kind"].split(":")[0] for m in self.pack["mutants"]}
        self.assertEqual(kinds, {"metadata-noop", "style-mutation", "report-fabricated"})
        self.assertFalse(self.pack["visual"]["applicable"])
        self.assertEqual(self.pack["evidencePolicy"]["requiredLevel"], "corpus-validated")

    def test_schema_and_pack_under_jsonschema_when_available(self):
        try:
            from jsonschema import Draft202012Validator
        except ImportError:
            self.skipTest("jsonschema not installed")
        Draft202012Validator.check_schema(self.schema)
        Draft202012Validator(self.schema).validate(self.pack)
        bad = copy.deepcopy(self.pack)
        bad["evidencePolicy"]["requiredLevel"] = "hand-wavy"
        with self.assertRaises(Exception):
            Draft202012Validator(self.schema).validate(bad)

    def test_every_shipped_pack_validates_and_hashes(self):
        packs_dir = os.path.join(ACCEPTANCE, "packs")
        names = sorted(n for n in os.listdir(packs_dir) if n.endswith(".json"))
        self.assertIn("style-lint.json", names)
        ids = set()
        for name in names:
            pack = R.load_json(os.path.join(packs_dir, name))
            with self.subTest(pack=name):
                self.assertEqual(R.validate_pack(pack, self.schema), [])
                self.assertEqual(pack["packHash"], R.compute_pack_hash(pack))
                self.assertEqual(pack["id"] + ".json", name)
                self.assertNotIn(pack["operation"], ids)
                ids.add(pack["operation"])
                if pack["runner"]["kind"] == "swift-test":
                    self.assertEqual({f["class"] for f in pack["fixtures"]}, {"positive", "negative", "degenerate"})
                    kinds = [m["transform"]["kind"] for m in pack["mutants"]]
                    self.assertGreaterEqual(kinds.count("swift-test"), 2)
                    self.assertIn("report-fabricated", kinds)

    def test_evidence_registry_is_empty_and_pinned(self):
        reg = R.load_json(os.path.join(ACCEPTANCE, "evidence.json"))
        self.assertEqual(reg, {"schemaVersion": 1, "pinnedCommit": "a020125384c0c15b6479e7dc304ec48c899887dc", "entries": []})


if __name__ == "__main__":
    unittest.main()
