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
"""Acceptance-pack runner for Python-oracle and swift-test packs (docs/proposals/vrm-author-cli/acceptance).

    acceptance_run.py PACK.json [--json] [--fixtures DIR] [--out RESULT.json] [--schema SCHEMA.json]

Checks, in order: the pack validates against pack.schema.json; packHash matches the
canonical JSON; the runner entry point exists; every oracle hash matches the working
tree; each fixture hashes as pinned and grades as expected; each mutant is rejected;
the corpus dimension passes per body family when the pack declares one.

`runner.kind == "swift-test"` packs name an XCTest suite as their entry point. The runner
executes `swift test --disable-sandbox --filter <suite>` from the repository root under the
pack's deadline (adding a `--filter` for every mutant `suite` override), grades the fixture
dimension from the suite's test-case results, requires each `swift-test` mutant's named test
to run and pass, and reports missing-handler when no test case of the entry-point suite ran.
Fixtures marked `synthetic` are built in-process by the suite and carry no bytes to hash.

Exit status: 0 pass, 1 fail, 2 pending (a fixture or corpus asset is absent),
3 missing-handler (entry point absent), 4 pack invalid.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

RESULT_SCHEMA_VERSION = 1
EXIT = {"pass": 0, "fail": 1, "pending": 2, "missing-handler": 3, "invalid": 4}
STATUS_RANK = {"pass": 0, "pending": 1, "fail": 2, "missing-handler": 3}

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SCHEMA = os.path.join(REPO, "docs", "proposals", "vrm-author-cli", "acceptance", "pack.schema.json")

GLB_MAGIC = 0x46546C67
JSON_CHUNK = 0x4E4F534A
BIN_CHUNK = 0x004E4942


class PackInvalid(Exception):
    pass


# --------------------------------------------------------------------------- hashing

def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def canonical_json(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def compute_pack_hash(pack):
    p = dict(pack)
    p["packHash"] = ""
    return sha256_bytes(canonical_json(p).encode("utf-8"))


def load_json(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


# --------------------------------------------------------------------------- schema subset

def _type_ok(value, t):
    if t == "object":
        return isinstance(value, dict)
    if t == "array":
        return isinstance(value, list)
    if t == "string":
        return isinstance(value, str)
    if t == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if t == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if t == "boolean":
        return isinstance(value, bool)
    if t == "null":
        return value is None
    return True


def validate_schema(instance, schema, root=None, path="$"):
    """Validate the JSON Schema subset used by pack.schema.json: $ref (local), type, enum, const,
    required, properties, additionalProperties, items, minItems, minProperties, minimum, pattern."""
    root = schema if root is None else root
    errors = []
    if "$ref" in schema:
        ref = schema["$ref"]
        if not ref.startswith("#/"):
            return [f"{path}: unsupported $ref {ref}"]
        target = root
        for part in ref[2:].split("/"):
            target = target[part]
        merged = dict(target)
        merged.update({k: v for k, v in schema.items() if k != "$ref"})
        return validate_schema(instance, merged, root, path)
    t = schema.get("type")
    if t is not None:
        types = t if isinstance(t, list) else [t]
        if not any(_type_ok(instance, x) for x in types):
            return [f"{path}: expected type {t}, got {type(instance).__name__}"]
    if "enum" in schema and instance not in schema["enum"]:
        errors.append(f"{path}: {instance!r} not in {schema['enum']}")
    if "const" in schema and instance != schema["const"]:
        errors.append(f"{path}: {instance!r} != {schema['const']!r}")
    if isinstance(instance, str) and "pattern" in schema and not re.search(schema["pattern"], instance):
        errors.append(f"{path}: {instance!r} does not match {schema['pattern']}")
    if isinstance(instance, (int, float)) and not isinstance(instance, bool) and "minimum" in schema and instance < schema["minimum"]:
        errors.append(f"{path}: {instance} < minimum {schema['minimum']}")
    if isinstance(instance, dict):
        for key in schema.get("required", []):
            if key not in instance:
                errors.append(f"{path}: missing required property {key!r}")
        props = schema.get("properties", {})
        for key, sub in props.items():
            if key in instance:
                errors.extend(validate_schema(instance[key], sub, root, f"{path}.{key}"))
        extra = schema.get("additionalProperties", True)
        for key in instance:
            if key in props:
                continue
            if extra is False:
                errors.append(f"{path}: unknown property {key!r}")
            elif isinstance(extra, dict):
                errors.extend(validate_schema(instance[key], extra, root, f"{path}.{key}"))
        if "minProperties" in schema and len(instance) < schema["minProperties"]:
            errors.append(f"{path}: fewer than {schema['minProperties']} properties")
    if isinstance(instance, list):
        if "minItems" in schema and len(instance) < schema["minItems"]:
            errors.append(f"{path}: fewer than {schema['minItems']} items")
        if "items" in schema:
            for i, item in enumerate(instance):
                errors.extend(validate_schema(item, schema["items"], root, f"{path}[{i}]"))
    return errors


def validate_pack(pack, schema):
    """Structural validation (schema subset, or jsonschema when importable) plus cross-references."""
    errors = validate_schema(pack, schema)
    try:
        import jsonschema  # noqa: F401
        from jsonschema import Draft202012Validator
        errors += [f"{'$.' + '.'.join(str(p) for p in e.absolute_path) if e.absolute_path else '$'}: {e.message}"
                   for e in Draft202012Validator(schema).iter_errors(pack)]
    except ImportError:
        pass
    if errors:
        return sorted(set(errors))
    assertion_ids = {a["id"] for a in pack["assertions"]}
    fixture_ids = {f["id"] for f in pack["fixtures"]}
    for f in pack["fixtures"]:
        for k in f["expected"]:
            if k not in assertion_ids:
                errors.append(f"fixture {f['id']}: expected key {k!r} names no assertion")
        if f.get("synthetic"):
            if f.get("sha256"):
                errors.append(f"fixture {f['id']}: synthetic fixtures have no bytes to pin; omit sha256")
            if pack["runner"]["kind"] != "swift-test":
                errors.append(f"fixture {f['id']}: synthetic fixtures require runner.kind swift-test")
        elif not f.get("sha256"):
            errors.append(f"fixture {f['id']}: sha256 is required unless synthetic is true")
    for m in pack["mutants"]:
        tr = m["transform"]
        kind = tr["kind"]
        if kind in ("metadata-noop",) or kind.startswith("style-mutation:"):
            if tr.get("fixture") not in fixture_ids:
                errors.append(f"mutant {m['id']}: transform.fixture must name a fixture")
        if kind == "metadata-noop" and ("field" not in tr or "value" not in tr):
            errors.append(f"mutant {m['id']}: metadata-noop needs field and value")
        if kind.startswith("style-mutation:"):
            if kind not in ("style-mutation:mtoon", "style-mutation:delete-path"):
                errors.append(f"mutant {m['id']}: unsupported transform {kind}")
            if not tr.get("expectFlip"):
                errors.append(f"mutant {m['id']}: style mutation needs a non-empty expectFlip")
        if kind == "report-fabricated" and "envelope" not in tr:
            errors.append(f"mutant {m['id']}: report-fabricated needs an envelope")
    if pack["runner"]["kind"] == "python":
        prof = pack["runner"].get("profile")
        if not prof:
            errors.append("runner.profile is required for python packs")
        elif prof not in pack["runner"]["environment"]["oracleHashes"]:
            errors.append("runner.profile must be listed in runner.environment.oracleHashes")
        if pack["runner"]["entryPoint"] not in pack["runner"]["environment"]["oracleHashes"]:
            errors.append("runner.entryPoint must be listed in runner.environment.oracleHashes")
    if pack["runner"]["kind"] == "swift-test":
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)?", pack["runner"]["entryPoint"]):
            errors.append("runner.entryPoint must be an XCTest suite name for swift-test packs")
        for m in pack["mutants"]:
            tr = m["transform"]
            if tr["kind"] == "swift-test" and not tr.get("test"):
                errors.append(f"mutant {m['id']}: swift-test mutants need a test name")
            elif tr["kind"] != "swift-test" and tr["kind"] != "report-fabricated":
                errors.append(f"mutant {m['id']}: swift-test packs only support swift-test and report-fabricated mutants")
    elif any(m["transform"]["kind"] == "swift-test" for m in pack["mutants"]):
        errors.append("swift-test mutants require runner.kind swift-test")
    for m in pack["mutants"]:
        if "suite" in m["transform"] and m["transform"]["kind"] != "swift-test":
            errors.append(f"mutant {m['id']}: transform.suite applies only to swift-test mutants")
    if pack["evidencePolicy"]["dimensions"]["corpus"] == "required" and "corpus" not in pack:
        errors.append("evidencePolicy.dimensions.corpus is required but the pack has no corpus block")
    if not pack["visual"]["applicable"] and not pack["visual"].get("applicabilityRecord"):
        errors.append("visual.applicabilityRecord is required when visual.applicable is false")
    if len(fixture_ids) != len(pack["fixtures"]):
        errors.append("fixture ids must be unique")
    return errors


# --------------------------------------------------------------------------- glb helpers

def load_glb(data):
    magic, _ver, length = struct.unpack_from("<III", data, 0)
    if magic != GLB_MAGIC:
        raise ValueError("not a GLB container")
    off, js, bin_ = 12, None, b""
    while off < length:
        clen, ctype = struct.unpack_from("<II", data, off)
        off += 8
        chunk = data[off:off + clen]
        off += clen
        if ctype == JSON_CHUNK:
            js = json.loads(chunk)
        elif ctype == BIN_CHUNK:
            bin_ = chunk
    return js, bin_


def pack_glb(js, bin_):
    jb = json.dumps(js).encode()
    jb += b" " * (-len(jb) % 4)
    bin_ += b"\0" * (-len(bin_) % 4)
    body = struct.pack("<II", len(jb), JSON_CHUNK) + jb + struct.pack("<II", len(bin_), BIN_CHUNK) + bin_
    return struct.pack("<III", GLB_MAGIC, 2, 12 + len(body)) + body


def get_path(obj, dotted):
    cur = obj
    for part in dotted.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        elif isinstance(cur, list) and part.isdigit() and int(part) < len(cur):
            cur = cur[int(part)]
        else:
            return None
    return cur


def set_path(obj, dotted, value):
    parts = dotted.split(".")
    cur = obj
    for part in parts[:-1]:
        cur = cur.setdefault(part, {})
    cur[parts[-1]] = value


def delete_path(obj, dotted):
    parts = dotted.split(".")
    cur = obj
    for part in parts[:-1]:
        if not isinstance(cur, dict) or part not in cur:
            return False
        cur = cur[part]
    if isinstance(cur, dict) and parts[-1] in cur:
        del cur[parts[-1]]
        return True
    return False


# --------------------------------------------------------------------------- runner

class Runner:
    def __init__(self, pack, pack_path, fixtures_dir=None, repo=REPO):
        self.pack = pack
        self.pack_path = pack_path
        self.fixtures_dir = fixtures_dir
        self.repo = repo
        self.oracle_hashes = {}
        self.profile_meta = {}
        self.baselines = {}
        self.tmp = None

    # ---- resolution

    def repo_path(self, rel):
        return os.path.join(self.repo, rel)

    def resolve_fixture(self, f):
        if self.fixtures_dir:
            return os.path.join(self.fixtures_dir, f["path"])
        env = f.get("pathEnv")
        if env and os.environ.get(env):
            return os.path.join(os.environ[env], f["path"])
        return self.repo_path(f["path"])

    def verify_oracles(self):
        mismatches = []
        for rel, want in self.pack["runner"]["environment"]["oracleHashes"].items():
            path = self.repo_path(rel)
            if not os.path.exists(path):
                mismatches.append({"path": rel, "expected": want, "actual": None})
                continue
            got = sha256_file(path)
            self.oracle_hashes[rel] = got
            if got != want:
                mismatches.append({"path": rel, "expected": want, "actual": got})
        return mismatches

    # ---- oracle invocation

    def run_lint(self, asset_path):
        """Run the pinned linter on one asset and wrap its report in a provenance envelope."""
        r = self.pack["runner"]
        cmd = [sys.executable, self.repo_path(r["entryPoint"]), "lint", "--profile", self.repo_path(r["profile"]), "--json", asset_path]
        deadline = self.pack["resources"]["deadlineSeconds"]
        try:
            proc = subprocess.run(cmd, cwd=self.repo, capture_output=True, text=True, timeout=deadline)
        except subprocess.TimeoutExpired:
            return {"report": None, "oracleHashes": dict(self.oracle_hashes), "exitCode": None, "stderr": f"timeout after {deadline}s"}
        report = None
        try:
            parsed = json.loads(proc.stdout)
            if isinstance(parsed, list) and parsed:
                report = parsed[0]
        except ValueError:
            report = None
        return {"report": report, "oracleHashes": dict(self.oracle_hashes), "exitCode": proc.returncode, "stderr": proc.stderr[-2000:]}

    def accept_envelope(self, env):
        """The single acceptance path for every report, genuine or claimed: the envelope's oracle
        hashes must equal the pinned ones and the report must name the pinned profile."""
        pinned = self.pack["runner"]["environment"]["oracleHashes"]
        claimed = env.get("oracleHashes") or {}
        for rel, want in pinned.items():
            if claimed.get(rel) != want:
                return False, f"oracle hash for {rel} is {claimed.get(rel)!r}, pinned {want}"
        rep = env.get("report")
        if rep is not None:
            if rep.get("profile") != self.profile_meta.get("id") or rep.get("profile_version") != self.profile_meta.get("version"):
                return False, f"report names profile {rep.get('profile')!r} v{rep.get('profile_version')!r}, pinned {self.profile_meta.get('id')!r} v{self.profile_meta.get('version')!r}"
        return True, None

    # ---- assertions

    def check_assertions(self, fixture, env):
        checks = []
        for a in self.pack["assertions"]:
            expected = fixture["expected"][a["id"]] if a["id"] in fixture["expected"] else a["expected"]
            c = {"id": a["id"], "kind": a["kind"], "expected": expected}
            if expected is None:
                c["status"] = "skip"
                checks.append(c)
                continue
            if a["kind"] == "exit-code":
                observed = env["exitCode"]
                ok = observed == expected
            elif a["kind"] == "error-class":
                observed = env.get("stderr", "")
                ok = env["report"] is None and str(expected) in observed
                observed = observed.strip().splitlines()[-1] if observed.strip() else ""
            elif a["kind"] == "report-field":
                if env["report"] is None:
                    c.update(status="fail", observed=None, reason="no report produced")
                    checks.append(c)
                    continue
                observed = get_path(env["report"], a["target"])
                tol = a.get("tolerance")
                if tol is not None and isinstance(observed, (int, float)) and isinstance(expected, (int, float)):
                    ok = abs(observed - expected) <= tol
                else:
                    ok = observed == expected
            else:
                observed, ok = None, False
            c["observed"] = observed
            c["status"] = "pass" if ok else "fail"
            checks.append(c)
        return checks

    def run_fixture(self, f):
        out = {"id": f["id"], "class": f["class"], "path": f["path"], "sha256": f["sha256"]}
        path = self.resolve_fixture(f)
        out["resolvedPath"] = path
        if not os.path.exists(path):
            out.update(status="pending", reason=f"fixture file absent: {path}")
            return out
        got = sha256_file(path)
        if got != f["sha256"]:
            out.update(status="fail", reason=f"fixture sha256 {got} differs from pinned {f['sha256']}")
            return out
        env = self.run_lint(path)
        ok, why = self.accept_envelope(env)
        if not ok:
            out.update(status="fail", reason=f"report rejected: {why}")
            return out
        checks = self.check_assertions(f, env)
        out["assertions"] = checks
        out["verdict"] = env["report"].get("verdict") if env["report"] else None
        out["exitCode"] = env["exitCode"]
        out["status"] = "fail" if any(c["status"] == "fail" for c in checks) else "pass"
        if out["status"] == "fail":
            out["reason"] = "; ".join(f"{c['id']}: expected {c['expected']!r}, observed {c.get('observed')!r}" for c in checks if c["status"] == "fail")
        self.baselines[f["id"]] = env
        return out

    # ---- mutants

    def _mutated_file(self, fixture, mutate):
        src = self.resolve_fixture(fixture)
        with open(src, "rb") as fh:
            data = fh.read()
        js, bin_ = load_glb(data)
        mutate(js)
        if self.tmp is None:
            self.tmp = tempfile.mkdtemp(prefix="acceptance_run_")
        dst = os.path.join(self.tmp, f"{fixture['id']}.mutant.bin")
        with open(dst, "wb") as fh:
            fh.write(pack_glb(js, bin_))
        return dst

    def run_mutant(self, m):
        tr = m["transform"]
        kind = tr["kind"]
        out = {"id": m["id"], "kind": kind, "expectedClassification": m["expectedClassification"]}
        fixture = next((f for f in self.pack["fixtures"] if f["id"] == tr.get("fixture")), None)
        if kind != "report-fabricated":
            base = self.baselines.get(fixture["id"]) if fixture else None
            if base is None or base["report"] is None:
                out.update(status="pending", reason=f"baseline for fixture {tr.get('fixture')!r} unavailable")
                return out
        if kind == "report-fabricated":
            ok, why = self.accept_envelope(tr["envelope"])
            if ok:
                out.update(status="fail", classification="accepted", reason="fabricated report envelope was accepted")
            else:
                out.update(status="pass", classification="reject", reason=why)
            return out
        if kind == "metadata-noop":
            before = {}

            def edit(js):
                before["value"] = get_path(js, tr["field"])
                set_path(js, tr["field"], tr["value"])
            path = self._mutated_file(fixture, edit)
            if before.get("value") == tr["value"]:
                out.update(status="fail", classification="control-broken", reason=f"{tr['field']} already held the mutant value; nothing was edited")
                return out
            integrity = sha256_file(path) != fixture["sha256"]
            env = self.run_lint(path)
            same = env["report"] is not None and env["report"].get("verdict") == base["report"].get("verdict") \
                and rule_statuses(env["report"]) == rule_statuses(base["report"])
            out["integrityRejected"] = integrity
            out["gradeUnchanged"] = same
            if integrity and same:
                out.update(status="pass", classification="reject", reason="mutated bytes refused by fixture sha256; every rule status identical to baseline")
            elif not same:
                out.update(status="fail", classification="control-broken", reason="metadata-only edit changed the grade")
            else:
                out.update(status="fail", classification="accepted", reason="mutated bytes hash as the pinned fixture")
            return out
        if kind == "style-mutation:mtoon":
            needles = tr.get("materialNameContains", [])
            changes = tr.get("changes", {})

            def mutate(js):
                for mat in js.get("materials", []):
                    if any(n in mat.get("name", "") for n in needles):
                        mat.setdefault("extensions", {}).setdefault("VRMC_materials_mtoon", {}).update(changes)
            path = self._mutated_file(fixture, mutate)
        elif kind == "style-mutation:delete-path":
            path = self._mutated_file(fixture, lambda js: delete_path(js, tr["path"]))
        else:
            out.update(status="fail", classification="unsupported", reason=f"unsupported transform {kind}")
            return out
        env = self.run_lint(path)
        if env["report"] is None:
            out.update(status="fail", classification="no-report", reason=f"mutant run produced no report: {env.get('stderr', '')[-200:]}")
            return out
        base_st = rule_statuses(base["report"])
        mut_st = rule_statuses(env["report"])
        flips = []
        rejected = True
        for rule, want in tr["expectFlip"].items():
            got = mut_st.get(rule)
            flipped = got == want and got != base_st.get(rule)
            flips.append({"rule": rule, "baseline": base_st.get(rule), "mutant": got, "expected": want, "flipped": flipped})
            rejected = rejected and flipped
        unchanged = []
        for rule in tr.get("expectUnchanged", []):
            same = mut_st.get(rule) == base_st.get(rule)
            unchanged.append({"rule": rule, "baseline": base_st.get(rule), "mutant": mut_st.get(rule), "unchanged": same})
            rejected = rejected and same
        out.update(flips=flips, unchanged=unchanged, baselineVerdict=base["report"]["verdict"], mutantVerdict=env["report"]["verdict"])
        if rejected:
            out.update(status="pass", classification="reject")
        else:
            out.update(status="fail", classification="not-rejected", reason="mutant did not flip the declared rules relative to the baseline")
        return out

    # ---- corpus

    def run_corpus(self):
        c = self.pack["corpus"]
        out = {"manifest": c["manifest"], "families": {}, "assets": []}
        mpath = self.repo_path(c["manifest"])
        if not os.path.exists(mpath) or sha256_file(mpath) != c["sha256"]:
            out.update(status="fail", reason="corpus manifest absent or differs from pinned sha256")
            return out
        manifest = load_json(mpath)
        root = os.path.normpath(os.path.join(os.path.dirname(mpath), manifest.get("root", ".")))
        known_hashes = self.profile_meta.get("corpusHashes", {})
        fams = {}
        for a in manifest["assets"]:
            fam = a.get(c["familyKey"], os.path.basename(a["path"]))
            path = os.path.join(root, a["path"])
            rec = {"path": a["path"], "family": fam}
            if not os.path.exists(path):
                rec.update(status="pending", reason="absent")
            else:
                want = known_hashes.get(os.path.basename(a["path"]))
                got = sha256_file(path)
                if want and got != want:
                    rec.update(status="fail", reason=f"sha256 {got} differs from the profile's calibration copy {want}")
                else:
                    env = self.run_lint(path)
                    ok, why = self.accept_envelope(env)
                    rep = env["report"]
                    if not ok or rep is None:
                        rec.update(status="fail", reason=why or f"no report: {env.get('stderr', '')[-200:]}")
                    else:
                        rec["verdict"] = rep["verdict"]
                        rec["mustFail"] = rep["summary"]["must"]["fail"]
                        rec["status"] = "fail" if rep["summary"]["must"]["fail"] else "pass"
            out["assets"].append(rec)
            fams.setdefault(fam, []).append(rec)
        for fam, recs in sorted(fams.items()):
            statuses = [r["status"] for r in recs]
            st = "fail" if "fail" in statuses else ("pending" if "pending" in statuses else "pass")
            out["families"][fam] = {"assets": len(recs), "measured": sum(s != "pending" for s in statuses),
                                    "passed": statuses.count("pass"), "status": st}
        expected = c.get("expectedFamilies")
        if expected is not None and len(fams) != expected:
            out.update(status="fail", reason=f"manifest has {len(fams)} families, pack expects {expected}")
            return out
        fam_st = [v["status"] for v in out["families"].values()]
        out["status"] = "fail" if "fail" in fam_st else ("pending" if "pending" in fam_st else "pass")
        out["familiesPassed"] = fam_st.count("pass")
        out["familiesTotal"] = len(fam_st)
        return out

    # ---- swift-test

    SWIFT_TEST_CASE = re.compile(r"Test Case '-\[(?P<module>[^ .\]]+)\.(?P<suite>[^ \]]+) (?P<test>[^\]]+)\]' (?P<status>passed|failed)")

    @staticmethod
    def parse_swift_test_output(text):
        """Per-test final status from XCTest output; the last status line for a test wins."""
        tests = {}
        for m in Runner.SWIFT_TEST_CASE.finditer(text):
            tests[f"{m.group('suite')}.{m.group('test')}"] = m.group("status")
        return tests

    def swift_suites(self):
        """The entry-point suite followed by every distinct mutant `suite` override, in pack order."""
        suites = [self.pack["runner"]["entryPoint"]]
        for m in self.pack["mutants"]:
            s = m["transform"].get("suite")
            if s and s not in suites:
                suites.append(s)
        return suites

    def run_swift_suite(self):
        """Run the suite once and wrap the parsed results in a report envelope."""
        suite = self.pack["runner"]["entryPoint"]
        swift = shutil.which("swift")
        if swift is None:
            return {"report": None, "oracleHashes": dict(self.oracle_hashes), "exitCode": None, "stderr": "swift toolchain not found on PATH", "tests": {}, "command": None}
        cmd = [swift, "test", "--disable-sandbox"]
        for s in self.swift_suites():
            cmd += ["--filter", s]
        deadline = self.pack["resources"]["deadlineSeconds"]
        env = dict(os.environ)
        if self.fixtures_dir:
            for f in self.pack["fixtures"]:
                if f.get("pathEnv") and not f.get("synthetic"):
                    env[f["pathEnv"]] = self.fixtures_dir
        try:
            proc = subprocess.run(cmd, cwd=self.repo, capture_output=True, text=True, timeout=deadline, env=env)
        except subprocess.TimeoutExpired:
            return {"report": None, "oracleHashes": dict(self.oracle_hashes), "exitCode": None, "stderr": f"timeout after {deadline}s", "tests": {}, "command": cmd}
        combined = proc.stdout + "\n" + proc.stderr
        tests = self.parse_swift_test_output(combined)
        failing = sorted(t for t, st in tests.items() if st == "failed")
        report = None
        if tests:
            report = {"suite": suite, "executed": len(tests), "passed": len(tests) - len(failing), "failed": len(failing),
                      "failingTests": failing, "exitCode": proc.returncode}
        tail = "\n".join(line for line in combined.splitlines() if "error:" in line or "warning: No matching" in line)[-2000:]
        return {"report": report, "oracleHashes": dict(self.oracle_hashes), "exitCode": proc.returncode, "stderr": tail or proc.stderr[-2000:],
                "tests": tests, "command": cmd}

    def run_swift_test(self, result):
        env = self.run_swift_suite()
        result["runner"]["command"] = env.get("command")
        result["runner"]["exitCode"] = env["exitCode"]
        if env["command"] is None:
            result.update(status="pending", reason=env["stderr"])
            return result
        if env["exitCode"] is None:
            result.update(status="fail", reason=env["stderr"])
            result["dimensions"]["fixture"] = "fail"
            return result
        entry = self.pack["runner"]["entryPoint"]
        entry_tests = {t for t in env["tests"] if t.split(".", 1)[0] == entry}
        if not entry_tests:
            if env["exitCode"] == 0:
                result.update(status="missing-handler", reason=f"no test case matched suite {entry!r}")
            else:
                result.update(status="fail", reason=f"swift test did not run any test case (exit {env['exitCode']}): {env['stderr'][-500:]}")
                result["dimensions"]["fixture"] = "fail"
            return result
        ok, why = self.accept_envelope(env)
        if not ok:
            result.update(status="fail", reason=f"report rejected: {why}")
            result["dimensions"]["provenance"] = "fail"
            return result
        failing = env["report"]["failingTests"]
        for f in self.pack["fixtures"]:
            out = {"id": f["id"], "class": f["class"], "path": f["path"], "sha256": f.get("sha256", "")}
            synthetic = bool(f.get("synthetic"))
            if synthetic:
                out["synthetic"] = True
                path = None
            else:
                path = self.resolve_fixture(f)
                out["resolvedPath"] = path
            if not synthetic and not os.path.exists(path):
                out.update(status="pending", reason=f"fixture file absent: {path}")
            elif not synthetic and sha256_file(path) != f["sha256"]:
                out.update(status="fail", reason=f"fixture sha256 {sha256_file(path)} differs from pinned {f['sha256']}")
            else:
                checks = self.check_assertions(f, env)
                out["assertions"] = checks
                out["exitCode"] = env["exitCode"]
                failed_checks = [c for c in checks if c["status"] == "fail"]
                if failing:
                    out.update(status="fail", reason="failing tests: " + ", ".join(failing))
                elif failed_checks:
                    out.update(status="fail", reason="; ".join(f"{c['id']}: expected {c['expected']!r}, observed {c.get('observed')!r}" for c in failed_checks))
                else:
                    out["status"] = "pass"
            result["fixtures"].append(out)
        for m in self.pack["mutants"]:
            tr = m["transform"]
            out = {"id": m["id"], "kind": tr["kind"], "expectedClassification": m["expectedClassification"]}
            if tr["kind"] == "report-fabricated":
                ok, why = self.accept_envelope(tr["envelope"])
                out.update(status="fail", classification="accepted", reason="fabricated report envelope was accepted") if ok else \
                    out.update(status="pass", classification="reject", reason=why)
            else:
                name = f"{tr.get('suite') or entry}.{tr['test']}"
                status = env["tests"].get(name)
                if status == "passed":
                    out.update(status="pass", classification="reject", test=name)
                elif status == "failed":
                    out.update(status="fail", classification="not-rejected", test=name, reason=f"mutant test {name} failed")
                else:
                    out.update(status="fail", classification="not-executed", test=name, reason=f"mutant test {name} was not executed by the suite")
            result["mutants"].append(out)
        result["swiftTest"] = env["report"]
        fx = [f["status"] for f in result["fixtures"]]
        mt = [m["status"] for m in result["mutants"]]
        result["dimensions"]["fixture"] = worst(fx + mt)
        integrity_fail = any(f["status"] == "fail" and "sha256" in f.get("reason", "") for f in result["fixtures"]) or \
            any(m["status"] == "fail" for m in result["mutants"] if m["kind"] == "report-fabricated")
        result["dimensions"]["provenance"] = "fail" if integrity_fail else worst(fx + mt)
        applicable = [v for v in result["dimensions"].values() if v != "inapplicable"]
        result["status"] = worst(applicable)
        if result["status"] == "fail" and failing:
            result["reason"] = "failing tests: " + ", ".join(failing)
        return result

    # ---- orchestration

    def run(self):
        pack = self.pack
        result = {"schemaVersion": RESULT_SCHEMA_VERSION,
                  "pack": {k: pack[k] for k in ("id", "version", "operation", "operationVersion", "packHash")},
                  "runner": {"kind": pack["runner"]["kind"], "entryPoint": pack["runner"]["entryPoint"],
                             "pinnedCommit": pack["runner"]["environment"]["pinnedCommit"], "headCommit": git_head(self.repo),
                             "python": sys.version.split()[0], "oracleHashes": {}},
                  "review": {"reviewReceipt": "present" if pack["provenance"]["reviewReceipt"] else "pending",
                             "reviewer": pack["provenance"]["reviewer"]},
                  "dimensions": {}, "fixtures": [], "mutants": [], "corpus": None}
        dims = pack["evidencePolicy"]["dimensions"]
        for k, v in dims.items():
            result["dimensions"][k] = "inapplicable" if v == "inapplicable" else "pending"
        entry = self.repo_path(pack["runner"]["entryPoint"])
        kind = pack["runner"]["kind"]
        if kind not in ("python", "swift-test"):
            result.update(status="missing-handler", reason=f"runner kind {kind!r} is not executed by this runner")
            return result
        if kind == "python" and not os.path.exists(entry):
            result.update(status="missing-handler", reason=f"entry point not found: {pack['runner']['entryPoint']}")
            return result
        mismatches = self.verify_oracles()
        result["runner"]["oracleHashes"] = dict(self.oracle_hashes)
        if mismatches:
            result["oracleMismatches"] = mismatches
            result.update(status="fail", reason="oracle hash mismatch: " + "; ".join(
                f"{m['path']} expected {m['expected'][:12]}… got {(m['actual'] or 'absent')[:12]}" for m in mismatches))
            result["dimensions"]["provenance"] = "fail"
            return result
        if kind == "swift-test":
            return self.run_swift_test(result)
        profile = load_json(self.repo_path(pack["runner"]["profile"]))
        self.profile_meta = {"id": profile.get("id"), "version": profile.get("version"),
                             "corpusHashes": profile.get("corpus", {}).get("sha256", {})}
        try:
            for f in pack["fixtures"]:
                result["fixtures"].append(self.run_fixture(f))
            for m in pack["mutants"]:
                result["mutants"].append(self.run_mutant(m))
            if dims["corpus"] == "required":
                result["corpus"] = self.run_corpus()
        finally:
            if self.tmp:
                shutil.rmtree(self.tmp, ignore_errors=True)
        fx = [f["status"] for f in result["fixtures"]]
        mt = [m["status"] for m in result["mutants"]]
        result["dimensions"]["fixture"] = worst(fx + mt)
        if result["corpus"] is not None:
            result["dimensions"]["corpus"] = result["corpus"]["status"]
        integrity_fail = any(f["status"] == "fail" and "sha256" in f.get("reason", "") for f in result["fixtures"]) or \
            any(m["status"] == "fail" for m in result["mutants"] if m["kind"] in ("report-fabricated", "metadata-noop"))
        result["dimensions"]["provenance"] = "fail" if integrity_fail else worst(fx + mt)
        applicable = [v for v in result["dimensions"].values() if v != "inapplicable"]
        result["status"] = worst(applicable)
        return result


def rule_statuses(report):
    return {r["id"]: r["status"] for r in report.get("results", [])}


def worst(statuses):
    if not statuses:
        return "pass"
    return max(statuses, key=lambda s: STATUS_RANK.get(s, 2))


def git_head(repo):
    try:
        return subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"], capture_output=True, text=True, timeout=10).stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


def print_summary(result):
    print(f"pack {result['pack']['id']} v{result['pack']['version']} ({result['pack']['operation']}): {result['status'].upper()}")
    if result.get("reason"):
        print(f"  {result['reason']}")
    for f in result.get("fixtures", []):
        line = f"  fixture {f['id']:32s} [{f['class']:10s}] {f['status']}"
        if f.get("verdict"):
            line += f"  verdict={f['verdict']}"
        if f.get("reason"):
            line += f"  — {f['reason']}"
        print(line)
    for m in result.get("mutants", []):
        line = f"  mutant  {m['id']:32s} [{m['kind']}] {m['status']} ({m.get('classification', '-')})"
        if m.get("reason") and m["status"] != "pass":
            line += f"  — {m['reason']}"
        print(line)
    c = result.get("corpus")
    if c:
        print(f"  corpus  {c.get('familiesPassed', 0)}/{c.get('familiesTotal', 0)} families pass: {c['status']}")
        for fam, v in c.get("families", {}).items():
            print(f"          {fam:24s} {v['passed']}/{v['assets']} {v['status']}")
    print("  dimensions: " + ", ".join(f"{k}={v}" for k, v in result["dimensions"].items()))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pack")
    ap.add_argument("--json", action="store_true", help="print the result manifest instead of a summary")
    ap.add_argument("--fixtures", help="directory holding pathEnv fixtures (overrides the environment variable)")
    ap.add_argument("--out", help="also write the result manifest to this path")
    ap.add_argument("--schema", default=DEFAULT_SCHEMA)
    args = ap.parse_args(argv)

    try:
        pack = load_json(args.pack)
        schema = load_json(args.schema)
    except (OSError, ValueError) as e:
        print(f"pack invalid: {e}", file=sys.stderr)
        return EXIT["invalid"]
    errors = validate_pack(pack, schema)
    if errors:
        print("pack invalid:", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        return EXIT["invalid"]
    want = compute_pack_hash(pack)
    if pack["packHash"] != want:
        print(f"pack invalid: packHash {pack['packHash'] or '(empty)'} does not match canonical content hash {want}", file=sys.stderr)
        return EXIT["invalid"]

    result = Runner(pack, os.path.abspath(args.pack), args.fixtures).run()
    result["resultHash"] = sha256_bytes(canonical_json(result).encode("utf-8"))
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            json.dump(result, fh, indent=1)
    if args.json:
        print(json.dumps(result, indent=1))
    else:
        print_summary(result)
    return EXIT[result["status"]]


if __name__ == "__main__":
    sys.exit(main())
