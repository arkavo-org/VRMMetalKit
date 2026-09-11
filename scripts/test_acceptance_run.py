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

    def test_evidence_registry_is_empty_and_pinned(self):
        reg = R.load_json(os.path.join(ACCEPTANCE, "evidence.json"))
        self.assertEqual(reg, {"schemaVersion": 1, "pinnedCommit": "a020125384c0c15b6479e7dc304ec48c899887dc", "entries": []})


if __name__ == "__main__":
    unittest.main()
