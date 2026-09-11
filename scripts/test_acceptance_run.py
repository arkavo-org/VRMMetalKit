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
from unittest import mock

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
        self.fixture_bytes = T.pack_glb(*T.minimal_vrm(T.RobustnessTests.MINIMAL_BONES))
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


def swift_test_pack(f, **overrides):
    """A schema-valid swift-test pack built on a PackFactory, for tests that need runner.kind swift-test."""
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
    p = f.pack(**base)
    p["fixtures"][0]["expected"] = {}
    p["packHash"] = R.compute_pack_hash(p)
    return p


def corpus_entry(**over):
    """A schema-valid corpus entry for a swift-test pack; override fields per test."""
    e = {"styleId": "vroid-lineage-anime",
         "profile": "docs/style/profiles/vroid-lineage-anime.json", "profileSha256": "b" * 64,
         "manifest": "docs/style/corpus/vroid-lineage-anime.manifest.json", "manifestSha256": "c" * 64,
         "measurements": "docs/style/corpus/vroid-lineage-anime.measurements.json", "measurementsSha256": "d" * 64,
         "witnesses": "docs/style/corpus/vroid-lineage-anime.witnesses.native-anime-v1.json", "witnessesSha256": "e" * 64,
         "familyKey": "body_family", "driver": "vrm-author-cli",
         "tolerance": 0.25, "expectedFamilies": 18, "minEligibleFamilies": 4}
    e.update(over)
    return e


def command_name(tokens):
    """The leading non-flag tokens of a recorded CLI invocation, e.g. "control set"."""
    name = []
    for t in tokens:
        if t.startswith("--"):
            break
        name.append(t)
    return " ".join(name)


def synthetic_replay_steps(controls):
    """The shape scripts/corpus_witness.py records on a solved witness: the ordered steps that
    reproduce the build, the template's default garment disabled among them."""
    return [{"command": "project init", "request": None},
            {"command": "object set", "request": {"edit": {"id": "outfit.top", "values": {"/enabled": False}}}},
            {"command": "control set", "request": {"edit": {"object": "avatar:main", "values": controls}}},
            {"command": "build", "request": None}]


@contextlib.contextmanager
def binary_absent(binary_path):
    """Force os.path.exists(binary_path) to report absent regardless of whether the checkout
    actually has a built vrm-author, so the 'not built' path is deterministic in tests."""
    real_exists = os.path.exists
    with mock.patch("acceptance_run.os.path.exists", side_effect=lambda p: False if p == binary_path else real_exists(p)):
        yield


def with_corpus(pack, entries, pin=True):
    """Attaches a corpus array to a pack, marks the dimension required, and (optionally) pins
    every entry path in runner.environment.oracleHashes, recomputing packHash."""
    pack["corpus"] = entries
    pack["evidencePolicy"]["dimensions"]["corpus"] = "required"
    if pin:
        for e in entries:
            for path_key, hash_key in (("profile", "profileSha256"), ("manifest", "manifestSha256"),
                                        ("measurements", "measurementsSha256"), ("witnesses", "witnessesSha256")):
                if path_key in e:
                    pack["runner"]["environment"]["oracleHashes"][e[path_key]] = e[hash_key]
    pack["packHash"] = ""
    pack["packHash"] = R.compute_pack_hash(pack)
    return pack


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
        self.assertIsInstance(result["corpus"], list)

    def test_run_corpus_reads_the_first_entrys_manifest_and_sha256_field(self):
        manifest_bytes = json.dumps({"assets": [{"path": "missing.vrm.glb", "body_family": "solo"}]}).encode()
        manifest_path = os.path.join(self.f.dir, "corpus-manifest.json")
        with open(manifest_path, "wb") as fh:
            fh.write(manifest_bytes)
        manifest_sha = R.sha256_bytes(manifest_bytes)
        entry = {"styleId": "test-style",
                 "profile": PROFILE, "profileSha256": R.sha256_file(os.path.join(REPO, PROFILE)),
                 "manifest": manifest_path, "manifestSha256": manifest_sha,
                 "measurements": manifest_path, "measurementsSha256": manifest_sha,
                 "familyKey": "body_family", "tolerance": 0.25,
                 "expectedFamilies": 1, "minEligibleFamilies": 1}
        pack = self.f.pack(corpus=[entry],
                           evidencePolicy={"requiredLevel": "corpus-validated",
                                           "dimensions": {"fixture": "required", "corpus": "required",
                                                          "visual": "inapplicable", "interoperability": "inapplicable",
                                                          "provenance": "required"},
                                           "heldOutPolicy": "none"})
        pack["runner"]["environment"]["oracleHashes"][manifest_path] = manifest_sha
        pack["packHash"] = R.compute_pack_hash(pack)
        self.assertEqual(R.validate_pack(pack, self.schema), [])
        out = R.Runner(pack).run_corpus()
        self.assertEqual(out["manifest"], manifest_path)
        self.assertEqual(out["status"], "pending")
        self.assertEqual(out["families"]["solo"]["status"], "pending")

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
        return swift_test_pack(self.f, **overrides)

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
        self.assertEqual(result["corpus"], [])
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


PACKS_PENDING_CORPUS_ARRAY_MIGRATION = set()


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
        self.assertEqual(oracles["scripts/style_lint.py"], "01679f040546fa76b6c4b8f6c84244388201ad04f0f449157c5ec634716b5881")
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
                if name not in PACKS_PENDING_CORPUS_ARRAY_MIGRATION:
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

    def test_pending_corpus_array_migration_packs_still_need_the_exemption(self):
        packs_dir = os.path.join(ACCEPTANCE, "packs")
        for name in PACKS_PENDING_CORPUS_ARRAY_MIGRATION:
            with self.subTest(pack=name):
                pack = R.load_json(os.path.join(packs_dir, name))
                self.assertTrue(R.validate_pack(pack, self.schema),
                                f"{name} now validates against the array corpus schema; remove it from "
                                f"PACKS_PENDING_CORPUS_ARRAY_MIGRATION")

    def test_evidence_registry_is_empty_and_pinned(self):
        reg = R.load_json(os.path.join(ACCEPTANCE, "evidence.json"))
        self.assertEqual(reg, {"schemaVersion": 1, "pinnedCommit": "a020125384c0c15b6479e7dc304ec48c899887dc", "entries": []})


class TargetDerivation(unittest.TestCase):
    def measurement(self, family, file, note=None, height=1.6, head=6.4, hips=0.57):
        return {"asset": {"file": file, "path": f"x/{file}", "sha256": "a" * 64,
                          "body_family": family, "note": note,
                          "height_m": height, "vrm_version": "1.0"},
                "proportions": {"head_count": head, "hips_height_ratio": hips,
                                "eye_height_ratio": 0.9, "ipd_m": 0.03,
                                "upper_leg_height_ratio": 0.55, "shoulder_width_ratio": 0.10,
                                "eye_height_in_head": 0.40, "head_width_height_ratio": 0.80,
                                "ipd_head_width_ratio": 0.15, "head_bone_fraction": 0.14,
                                "lower_upper_arm_ratio": 0.89, "lower_upper_leg_ratio": 1.12,
                                "arm_span_height_ratio": 0.72,
                                "rest_pose_arm_horizontal_cos": 1.0, "limb_asymmetry": 0.0}}

    def test_one_asset_per_family_is_its_own_representative(self):
        ms = [self.measurement("solo", "solo.vrm")]
        reps = R.family_representatives(ms)
        self.assertEqual(set(reps), {"solo"})
        self.assertEqual(reps["solo"]["asset"]["file"], "solo.vrm")

    def test_unnoted_asset_beats_a_noted_one(self):
        ms = [self.measurement("f", "noted.vrm", note="VRM 0.x export of the same body"),
              self.measurement("f", "clean.vrm")]
        self.assertEqual(R.family_representatives(ms)["f"]["asset"]["file"], "clean.vrm")

    def test_vrm1_beats_vrm0_when_both_are_unnoted(self):
        old = self.measurement("f", "old.vrm")
        old["asset"]["vrm_version"] = "0.0"
        ms = [old, self.measurement("f", "new.vrm")]
        self.assertEqual(R.family_representatives(ms)["f"]["asset"]["file"], "new.vrm")

    def test_manifest_order_breaks_remaining_ties(self):
        ms = [self.measurement("f", "first.vrm"), self.measurement("f", "second.vrm")]
        self.assertEqual(R.family_representatives(ms)["f"]["asset"]["file"], "first.vrm")

    def test_target_vector_excludes_pose_invariants(self):
        targets = R.family_targets([self.measurement("f", "a.vrm")])["f"]
        self.assertNotIn("proportions.rest_pose_arm_horizontal_cos", targets)
        self.assertNotIn("proportions.limb_asymmetry", targets)
        self.assertEqual(targets["asset.height_m"], 1.6)
        self.assertEqual(targets["proportions.head_count"], 6.4)

    def test_missing_metric_is_omitted_not_defaulted(self):
        m = self.measurement("f", "a.vrm")
        del m["proportions"]["ipd_m"]
        self.assertNotIn("proportions.ipd_m", R.family_targets([m])["f"])


class CorpusArraySchema(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.f = PackFactory()
        cls.schema = R.load_json(SCHEMA_PATH)

    @classmethod
    def tearDownClass(cls):
        cls.f.cleanup()

    def pack(self, entries, pin=True):
        return with_corpus(swift_test_pack(self.f), entries, pin=pin)

    def test_required_corpus_accepts_an_array_of_entries(self):
        pack = self.pack([corpus_entry()])
        self.assertEqual(R.validate_pack(pack, self.schema), [])

    def test_required_corpus_rejects_the_old_object_form(self):
        pack = self.pack([corpus_entry()])
        pack["corpus"] = corpus_entry()
        pack["packHash"] = ""
        pack["packHash"] = R.compute_pack_hash(pack)
        self.assertTrue(R.validate_pack(pack, self.schema))

    def test_required_corpus_rejects_an_empty_array(self):
        pack = self.pack([])
        self.assertIn("evidencePolicy.dimensions.corpus is required but the pack declares no style set",
                      R.validate_pack(pack, self.schema))

    def test_swift_test_entry_requires_a_driver(self):
        e = corpus_entry()
        del e["driver"]
        pack = self.pack([e])
        self.assertIn("corpus[0].driver is required when runner.kind is swift-test",
                      R.validate_pack(pack, self.schema))

    def test_duplicate_style_ids_are_rejected(self):
        pack = self.pack([corpus_entry(), corpus_entry()])
        self.assertIn("corpus styleId values must be unique", R.validate_pack(pack, self.schema))

    def test_every_corpus_path_must_be_pinned_in_oracle_hashes(self):
        pack = self.pack([corpus_entry()], pin=False)
        errors = R.validate_pack(pack, self.schema)
        self.assertTrue(any("must be listed in runner.environment.oracleHashes" in e for e in errors))

    def test_min_eligible_may_not_exceed_expected(self):
        pack = self.pack([corpus_entry(minEligibleFamilies=19)])
        self.assertIn("corpus[0].minEligibleFamilies must not exceed expectedFamilies",
                      R.validate_pack(pack, self.schema))

    def test_tolerance_above_one_is_rejected(self):
        pack = self.pack([corpus_entry(tolerance=1.5)])
        self.assertIn("corpus[0].tolerance must be greater than 0 and at most 1",
                      R.validate_pack(pack, self.schema))

    def test_tolerance_of_zero_is_rejected(self):
        pack = self.pack([corpus_entry(tolerance=0)])
        self.assertIn("corpus[0].tolerance must be greater than 0 and at most 1",
                      R.validate_pack(pack, self.schema))


class CorpusRollup(unittest.TestCase):
    def rollup(self, families, min_eligible):
        return R.corpus_status(families, min_eligible)

    def test_all_eligible_and_passing_is_pass(self):
        fams = {"a": {"status": "pass"}, "b": {"status": "pass"}}
        self.assertEqual(self.rollup(fams, 2), "pass")

    def test_below_the_floor_is_fail_not_pass(self):
        fams = {"a": {"status": "pass"}, "b": {"status": "ineligible"}}
        self.assertEqual(self.rollup(fams, 2), "fail")

    def test_zero_eligible_families_is_fail_never_pass(self):
        fams = {"a": {"status": "ineligible"}, "b": {"status": "ineligible"}}
        self.assertEqual(self.rollup(fams, 1), "fail")

    def test_an_ineligible_family_is_neither_pass_nor_fail_on_its_own(self):
        fams = {"a": {"status": "pass"}, "b": {"status": "ineligible"}}
        self.assertEqual(self.rollup(fams, 1), "pass")

    def test_a_failing_eligible_family_fails_the_dimension(self):
        fams = {"a": {"status": "pass"}, "b": {"status": "fail"}}
        self.assertEqual(self.rollup(fams, 1), "fail")

    def test_a_pending_family_pends_the_dimension(self):
        fams = {"a": {"status": "pass"}, "b": {"status": "pending"}}
        self.assertEqual(self.rollup(fams, 1), "pending")

    def test_fail_outranks_pending(self):
        fams = {"a": {"status": "fail"}, "b": {"status": "pending"}}
        self.assertEqual(self.rollup(fams, 1), "fail")


class CorpusSwiftReplay(unittest.TestCase):
    """run_corpus_swift against a fully synthetic style set, pinned by sha256 like the real
    corpus. Tests that reach replay_family's eligible-family branch stub the binary-existence
    check with binary_absent so they land on the 'vrm-author not built' pending path and never
    invoke the real CLI, regardless of whether this checkout happens to have one built."""

    @staticmethod
    def measurement(family, head_count=6.4, hips=0.57, drop_metric=None):
        proportions = {"head_count": head_count, "hips_height_ratio": hips, "eye_height_ratio": 0.9,
                       "ipd_m": 0.03, "upper_leg_height_ratio": 0.55, "shoulder_width_ratio": 0.10,
                       "eye_height_in_head": 0.40, "head_width_height_ratio": 0.80, "ipd_head_width_ratio": 0.15,
                       "head_bone_fraction": 0.14, "lower_upper_arm_ratio": 0.89, "lower_upper_leg_ratio": 1.12,
                       "arm_span_height_ratio": 0.72}
        if drop_metric:
            del proportions[drop_metric]
        return {"asset": {"file": f"{family}.vrm", "body_family": family, "height_m": 1.6, "vrm_version": "1.0"},
                "proportions": proportions}

    @classmethod
    def setUpClass(cls):
        cls.f = PackFactory()
        cls.dir = tempfile.mkdtemp(prefix="corpus_swift_test_")
        cls.profile_path = os.path.join(cls.dir, "profile.json")
        cls.manifest_path = os.path.join(cls.dir, "manifest.json")
        cls.measurements_path = os.path.join(cls.dir, "measurements.json")
        cls.witnesses_path = os.path.join(cls.dir, "witnesses.json")
        profile_bytes = json.dumps({
            "id": "test-style", "version": "1",
            "rules": [{"id": "r1", "metric": "proportions.head_count", "check": {"type": "range", "min": 5.0, "max": 7.0}},
                      {"id": "r2", "metric": "proportions.hips_height_ratio", "check": {"type": "range", "min": 0.5, "max": 0.6}},
                      {"id": "r3", "metric": "proportions.eye_height_ratio", "check": {"type": "range", "min": 0.82}},
                      {"id": "r4", "metric": "proportions.shoulder_width_ratio", "check": {"type": "enum", "values": ["narrow", "wide"]}}],
        }).encode()
        manifest_bytes = json.dumps({"assets": []}).encode()
        measurements_bytes = json.dumps({"measurements": [
            cls.measurement("fam-a", head_count=6.4),
            cls.measurement("fam-b", head_count=6.0),
            cls.measurement("fam-c", head_count=6.2, drop_metric="ipd_m"),
        ]}).encode()
        witnesses_bytes = json.dumps({
            "corpusManifestSha256": "0" * 64, "templateId": "native-anime-v1", "templateSha256": "1" * 64,
            "profileId": "test-style", "solver": {"budget": 100, "seed": 42, "tolerance": 0.25},
            "generated": "2026-09-11T00:00:00Z",
            "families": {
                "fam-a": {"eligible": True, "controls": {"height": 1.6}, "residuals": {"proportions.head_count": 0.1},
                          "replaySteps": synthetic_replay_steps({"height": 1.6})},
                "fam-b": {"eligible": False, "controls": {},
                          "residuals": {"proportions.head_count": 0.9, "proportions.hips_height_ratio": 0.95}},
            },
        }).encode()
        for path, data in ((cls.profile_path, profile_bytes), (cls.manifest_path, manifest_bytes),
                            (cls.measurements_path, measurements_bytes), (cls.witnesses_path, witnesses_bytes)):
            with open(path, "wb") as fh:
                fh.write(data)
        cls.hashes = {"profile": R.sha256_bytes(profile_bytes), "manifest": R.sha256_bytes(manifest_bytes),
                      "measurements": R.sha256_bytes(measurements_bytes), "witnesses": R.sha256_bytes(witnesses_bytes)}

    @classmethod
    def tearDownClass(cls):
        cls.f.cleanup()
        shutil.rmtree(cls.dir, ignore_errors=True)

    def entry(self, **over):
        e = {"styleId": "test-style", "profile": self.profile_path, "profileSha256": self.hashes["profile"],
             "manifest": self.manifest_path, "manifestSha256": self.hashes["manifest"],
             "measurements": self.measurements_path, "measurementsSha256": self.hashes["measurements"],
             "witnesses": self.witnesses_path, "witnessesSha256": self.hashes["witnesses"],
             "familyKey": "body_family", "driver": "vrm-author-cli",
             "tolerance": 0.25, "expectedFamilies": 3, "minEligibleFamilies": 1}
        e.update(over)
        return e

    def runner(self, entry):
        pack = with_corpus(swift_test_pack(self.f), [entry])
        return R.Runner(pack)

    def test_missing_path_is_pending(self):
        entry = self.entry(witnesses="/no/such/witnesses.json")
        out = self.runner(entry).run_corpus_swift(entry)
        self.assertEqual(out["status"], "pending")
        self.assertIn("absent", out["reason"])

    def test_hash_mismatch_is_fail(self):
        entry = self.entry(profileSha256="f" * 64)
        out = self.runner(entry).run_corpus_swift(entry)
        self.assertEqual(out["status"], "fail")
        self.assertIn("pinned sha256", out["reason"])

    def test_family_without_a_witness_is_pending(self):
        entry = self.entry()
        runner = self.runner(entry)
        with binary_absent(runner.repo_path(".build/debug/vrm-author")):
            out = runner.run_corpus_swift(entry)
        self.assertEqual(out["families"]["fam-c"]["status"], "pending")
        self.assertEqual(out["families"]["fam-c"]["reason"], "no witness for this family")

    def test_ineligible_family_records_the_worst_residual(self):
        entry = self.entry()
        runner = self.runner(entry)
        with binary_absent(runner.repo_path(".build/debug/vrm-author")):
            out = runner.run_corpus_swift(entry)
        fam_b = out["families"]["fam-b"]
        self.assertEqual(fam_b["status"], "ineligible")
        self.assertEqual(fam_b["blockedBy"], "proportions.hips_height_ratio")

    def test_eligible_family_without_a_built_binary_is_pending(self):
        entry = self.entry()
        runner = self.runner(entry)
        with binary_absent(runner.repo_path(".build/debug/vrm-author")):
            out = runner.run_corpus_swift(entry)
        self.assertEqual(out["familiesTotal"], 3)
        self.assertEqual(out["familiesEligible"], 1)
        self.assertEqual(out["familiesPassed"], 0)
        self.assertEqual(out["families"]["fam-a"]["status"], "pending")
        self.assertEqual(out["families"]["fam-a"]["reason"], "vrm-author not built")

    def test_rollup_status_is_pending_when_a_replay_is_pending(self):
        entry = self.entry()
        runner = self.runner(entry)
        with binary_absent(runner.repo_path(".build/debug/vrm-author")):
            out = runner.run_corpus_swift(entry)
        self.assertEqual(out["status"], "pending")

    def test_ragged_target_vectors_across_families_do_not_raise(self):
        entry = self.entry()
        measurements = R.load_json(self.measurements_path)["measurements"]
        targets = R.family_targets(measurements)
        self.assertNotIn("proportions.ipd_m", targets["fam-c"])
        self.assertIn("proportions.ipd_m", targets["fam-a"])
        runner = self.runner(entry)
        with binary_absent(runner.repo_path(".build/debug/vrm-author")):
            out = runner.run_corpus_swift(entry)
        self.assertEqual(set(out["families"]), {"fam-a", "fam-b", "fam-c"})

    def test_corpus_entry_paths_skips_absent_optional_fields(self):
        entry = self.entry()
        del entry["witnesses"]
        paths = self.runner(self.entry()).corpus_entry_paths(entry)
        self.assertEqual(len(paths), 3)
        self.assertNotIn(None, paths)

    def test_profile_rule_widths_only_keeps_range_rules(self):
        entry = self.entry()
        widths = self.runner(entry).profile_rule_widths(entry)
        self.assertEqual(widths["proportions.head_count"], 2.0)
        self.assertAlmostEqual(widths["proportions.hips_height_ratio"], 0.1)
        self.assertNotIn("proportions.eye_height_ratio", widths, "one-sided range (no max) must be excluded")
        self.assertNotIn("proportions.shoulder_width_ratio", widths, "a non-range check must be excluded")

    def run_pass(self, pack):
        bin_dir = os.path.join(self.dir, "bin")
        if not os.path.exists(bin_dir):
            os.makedirs(bin_dir)
            swift = os.path.join(bin_dir, "swift")
            with open(swift, "w", encoding="utf-8") as fh:
                fh.write(FAKE_SWIFT)
            os.chmod(swift, 0o755)
        args_file = os.path.join(self.dir, "swift-args.txt")
        env = dict(os.environ)
        env.update({"PATH": bin_dir + os.pathsep + env.get("PATH", ""), "FAKE_SWIFT_MODE": "pass", "FAKE_SWIFT_ARGS": args_file})
        old = os.environ.copy()
        os.environ.clear()
        os.environ.update(env)
        try:
            return self.f.run(pack)
        finally:
            os.environ.clear()
            os.environ.update(old)

    def test_run_swift_test_wires_the_corpus_dimension(self):
        entry = self.entry()
        pack = with_corpus(swift_test_pack(self.f), [entry])
        with binary_absent(os.path.join(REPO, ".build", "debug", "vrm-author")):
            code, result, err = self.run_pass(pack)
        self.assertIsNotNone(result, err)
        self.assertEqual(len(result["corpus"]), 1)
        self.assertEqual(result["corpus"][0]["styleId"], "test-style")
        self.assertEqual(result["dimensions"]["corpus"], "pending")
        self.assertEqual(result["status"], "pending")
        self.assertEqual(code, 2)

    def stub_cli_repo(self, work):
        """A repo root whose .build/debug/vrm-author is a stub that exits 0 for every step,
        so replay_family's build steps succeed without touching the real CLI."""
        bin_dir = os.path.join(work, ".build", "debug")
        os.makedirs(bin_dir)
        binary = os.path.join(bin_dir, "vrm-author")
        with open(binary, "w", encoding="utf-8") as fh:
            fh.write("#!/bin/sh\nexit 0\n")
        os.chmod(binary, 0o755)

    def recording_cli_repo(self, work):
        """Like stub_cli_repo, but every invocation appends its arguments to calls.log, so a test
        can assert which steps the replayer ran and in what order."""
        bin_dir = os.path.join(work, ".build", "debug")
        os.makedirs(bin_dir)
        binary = os.path.join(bin_dir, "vrm-author")
        with open(binary, "w", encoding="utf-8") as fh:
            fh.write('#!/bin/sh\nprintf \'%s\\n\' "$*" >> "$(dirname "$0")/calls.log"\nexit 0\n')
        os.chmod(binary, 0o755)
        return os.path.join(bin_dir, "calls.log")

    def single_family_style(self, work, style_id, family, replay_steps=True):
        """One style set with a single eligible family, its own profile id/version, pinned by
        sha256 like the real corpus. replay_steps=False writes the witness without the recorded
        steps, as a pre-replaySteps witnesses file would."""
        profile_bytes = json.dumps({"id": style_id, "version": "1", "rules": []}).encode()
        manifest_bytes = json.dumps({"assets": []}).encode()
        measurements_bytes = json.dumps({"measurements": [self.measurement(family, head_count=6.4)]}).encode()
        witnesses_bytes = json.dumps({
            "corpusManifestSha256": "0" * 64, "templateId": "native-anime-v1", "templateSha256": "1" * 64,
            "profileId": style_id, "solver": {"budget": 100, "seed": 42, "tolerance": 0.25},
            "generated": "2026-09-11T00:00:00Z",
            "families": {family: dict({"eligible": True, "controls": {"height": 1.6},
                                        "residuals": {"proportions.head_count": 0.1}},
                                      **({"replaySteps": synthetic_replay_steps({"height": 1.6})} if replay_steps else {}))},
        }).encode()
        paths = {}
        for name, data in (("profile.json", profile_bytes), ("manifest.json", manifest_bytes),
                           ("measurements.json", measurements_bytes), ("witnesses.json", witnesses_bytes)):
            p = os.path.join(work, f"{style_id}-{name}")
            with open(p, "wb") as fh:
                fh.write(data)
            paths[name] = p
        return self.entry(styleId=style_id,
                          profile=paths["profile.json"], profileSha256=R.sha256_bytes(profile_bytes),
                          manifest=paths["manifest.json"], manifestSha256=R.sha256_bytes(manifest_bytes),
                          measurements=paths["measurements.json"], measurementsSha256=R.sha256_bytes(measurements_bytes),
                          witnesses=paths["witnesses.json"], witnessesSha256=R.sha256_bytes(witnesses_bytes),
                          expectedFamilies=1)

    def test_replay_family_reaches_pass_with_a_stubbed_cli_and_a_synthetic_lint_report(self):
        work = tempfile.mkdtemp(prefix="corpus_swift_pass_")
        self.addCleanup(shutil.rmtree, work, ignore_errors=True)
        entry = self.single_family_style(work, "test-style", "fam-a")
        pack = with_corpus(swift_test_pack(self.f), [entry])
        self.stub_cli_repo(work)

        runner = R.Runner(pack, repo=work)
        synthetic_report = {"profile": "test-style", "profile_version": "1", "verdict": "conforming",
                            "summary": {"must": {"fail": 0}}, "results": []}
        synthetic_env = {"report": synthetic_report, "oracleHashes": dict(pack["runner"]["environment"]["oracleHashes"]),
                         "exitCode": 0, "stderr": ""}
        runner.run_lint_with = lambda profile_rel, asset_path: synthetic_env

        out = runner.run_corpus_swift(entry)

        self.assertEqual(out["familiesEligible"], 1)
        self.assertEqual(out["familiesPassed"], 1)
        self.assertEqual(out["families"]["fam-a"]["status"], "pass")
        self.assertEqual(out["families"]["fam-a"]["verdict"], "conforming")
        self.assertEqual(out["status"], "pass")

    def conforming_lint(self, pack, style_id="test-style"):
        return lambda profile_rel, asset_path: {
            "report": {"profile": style_id, "profile_version": "1", "verdict": "conforming",
                       "summary": {"must": {"fail": 0}}, "results": []},
            "oracleHashes": dict(pack["runner"]["environment"]["oracleHashes"]), "exitCode": 0, "stderr": ""}

    def test_replay_executes_the_steps_the_witness_recorded_in_order(self):
        work = tempfile.mkdtemp(prefix="corpus_swift_steps_")
        self.addCleanup(shutil.rmtree, work, ignore_errors=True)
        entry = self.single_family_style(work, "test-style", "fam-a")
        pack = with_corpus(swift_test_pack(self.f), [entry])
        calls_log = self.recording_cli_repo(work)

        runner = R.Runner(pack, repo=work)
        runner.run_lint_with = self.conforming_lint(pack)
        out = runner.run_corpus_swift(entry)
        self.addCleanup(shutil.rmtree, runner.tmp or work, ignore_errors=True)

        self.assertEqual(out["families"]["fam-a"]["status"], "pass")
        calls = [line.split() for line in open(calls_log, encoding="utf-8").read().splitlines()]
        self.assertEqual([command_name(c) for c in calls],
                         ["project init", "object set", "control set", "build"])
        init = calls[0]
        self.assertEqual(init[init.index("--template") + 1], "native-anime-v1")
        self.assertEqual(init[init.index("--seed") + 1], "42")
        garment = R.load_json(calls[1][calls[1].index("--request") + 1])
        self.assertEqual(garment, {"edit": {"id": "outfit.top", "values": {"/enabled": False}}},
                         "the default garment must be disabled exactly as the witness was solved")
        controls = R.load_json(calls[2][calls[2].index("--request") + 1])
        self.assertEqual(controls, {"edit": {"object": "avatar:main", "values": {"height": 1.6}}})

    def test_witness_without_recorded_steps_fails_without_replaying_anything(self):
        work = tempfile.mkdtemp(prefix="corpus_swift_nosteps_")
        self.addCleanup(shutil.rmtree, work, ignore_errors=True)
        entry = self.single_family_style(work, "test-style", "fam-a", replay_steps=False)
        pack = with_corpus(swift_test_pack(self.f), [entry])
        calls_log = self.recording_cli_repo(work)

        runner = R.Runner(pack, repo=work)
        runner.run_lint_with = self.conforming_lint(pack)
        out = runner.run_corpus_swift(entry)

        record = out["families"]["fam-a"]
        self.assertEqual(record["status"], "fail")
        self.assertIn("replaySteps", record["reason"])
        self.assertFalse(os.path.exists(calls_log), "a witness without recorded steps must not fall back to a replay")
        self.assertEqual(out["status"], "fail")

    def test_second_entry_does_not_inherit_the_first_entrys_profile_meta(self):
        work = tempfile.mkdtemp(prefix="corpus_swift_multi_")
        self.addCleanup(shutil.rmtree, work, ignore_errors=True)
        entry_a = self.single_family_style(work, "style-a", "fam-a")
        entry_b = self.single_family_style(work, "style-b", "fam-b")
        pack = with_corpus(swift_test_pack(self.f), [entry_a, entry_b])
        self.stub_cli_repo(work)

        runner = R.Runner(pack, repo=work)

        def stub_run_lint_with(profile_rel, asset_path):
            profile = R.load_json(profile_rel)
            report = {"profile": profile["id"], "profile_version": profile["version"], "verdict": "conforming",
                      "summary": {"must": {"fail": 0}}, "results": []}
            return {"report": report, "oracleHashes": dict(pack["runner"]["environment"]["oracleHashes"]),
                   "exitCode": 0, "stderr": ""}
        runner.run_lint_with = stub_run_lint_with

        out_a = runner.run_corpus_swift(entry_a)
        out_b = runner.run_corpus_swift(entry_b)

        self.assertEqual(out_a["families"]["fam-a"]["status"], "pass")
        self.assertEqual(out_b["families"]["fam-b"]["status"], "pass")


class ReplayStepRecords(unittest.TestCase):
    STEPS = [{"command": "project init", "request": None},
             {"command": "object set", "request": {"edit": {"id": "outfit.top", "values": {"/enabled": False}}}},
             {"command": "control set", "request": {"edit": {"object": "avatar:main", "values": {"body.heightM": 1.6}}}},
             {"command": "build", "request": None}]

    def test_absent_record_is_rejected(self):
        for steps in (None, [], {}, "project init"):
            with self.subTest(steps=steps), self.assertRaises(R.ReplayStepError) as caught:
                R.validated_replay_steps(steps)
            self.assertIn("replaySteps", str(caught.exception))

    def test_unknown_command_is_rejected(self):
        with self.assertRaises(R.ReplayStepError) as caught:
            R.validated_replay_steps([{"command": "deliver", "request": None}])
        self.assertIn("deliver", str(caught.exception))

    def test_a_request_carrying_command_without_a_request_is_rejected(self):
        with self.assertRaises(R.ReplayStepError) as caught:
            R.validated_replay_steps([{"command": "control set", "request": None}])
        self.assertIn("control set", str(caught.exception))

    def test_argv_owns_the_paths_and_writes_each_request_to_its_own_file(self):
        work = tempfile.mkdtemp(prefix="replay_argv_")
        self.addCleanup(shutil.rmtree, work, ignore_errors=True)
        tails = R.replay_argv(R.validated_replay_steps(self.STEPS), work,
                              {"project": "/p/a.vrmauthor", "draft": "/p/draft.vrm",
                               "template": "native-anime-v1", "seed": 7})
        self.assertEqual(tails[0], ["project", "init", "--dir", "/p/a.vrmauthor",
                                    "--template", "native-anime-v1", "--seed", "7"])
        self.assertEqual(tails[3], ["build", "--project", "/p/a.vrmauthor", "--out", "/p/draft.vrm"])
        requests = [t[t.index("--request") + 1] for t in tails[1:3]]
        self.assertEqual(len(set(requests)), 2, "each step's request needs its own file")
        self.assertEqual(R.load_json(requests[0]), self.STEPS[1]["request"])
        self.assertEqual(R.load_json(requests[1]), self.STEPS[2]["request"])


class CorpusAssertions(unittest.TestCase):
    def test_every_corpus_required_operation_has_an_assertion(self):
        for name in ("build", "export vrm", "control set", "recipe apply"):
            self.assertIn(name, R.CORPUS_ASSERTIONS, name)

    def test_material_shading_has_no_corpus_assertion(self):
        self.assertNotIn("material shading", R.CORPUS_ASSERTIONS)

    def test_export_assertion_requires_equal_metric_vectors(self):
        same = {"asset.height_m": 1.6, "proportions.head_count": 6.4}
        self.assertEqual(R.export_metrics_match(same, dict(same)), (True, None))
        drifted = dict(same, **{"asset.height_m": 1.61})
        ok, detail = R.export_metrics_match(same, drifted)
        self.assertFalse(ok)
        self.assertIn("asset.height_m", detail)

    def test_reach_assertion_uses_the_pack_tolerance(self):
        target = {"asset.height_m": 1.60}
        widths = {"asset.height_m": 0.9}
        self.assertTrue(R.reach_holds({"asset.height_m": 1.61}, target, widths, 0.25)[0])
        self.assertFalse(R.reach_holds({"asset.height_m": 1.10}, target, widths, 0.25)[0])


class PrintSummaryCorpusBranch(unittest.TestCase):
    def capture(self, result):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            R.print_summary(result)
        return buf.getvalue()

    def base_result(self):
        return {"pack": {"id": "p", "version": "1", "operation": "op"}, "status": "pass",
                "dimensions": {"fixture": "pass"}, "fixtures": [], "mutants": [], "corpus": []}

    def test_python_style_corpus_record_prints_family_lines(self):
        result = self.base_result()
        result["corpus"] = [{"manifest": "m.json", "familiesPassed": 1, "familiesTotal": 2, "status": "fail",
                             "families": {"fam-a": {"assets": 1, "passed": 1, "status": "pass"}}}]
        out = self.capture(result)
        self.assertIn("corpus  m.json 1/2 families pass: fail", out)
        self.assertIn("fam-a", out)

    def test_swift_style_corpus_record_prints_one_line_per_style_set(self):
        result = self.base_result()
        result["corpus"] = [{"styleId": "vroid-lineage-anime", "familiesPassed": 3, "familiesEligible": 4,
                             "familiesTotal": 18, "status": "pending", "families": {}}]
        out = self.capture(result)
        self.assertIn("corpus  [vroid-lineage-anime] 3/4 eligible pass, 18 families: pending", out)


if __name__ == "__main__":
    unittest.main()
