# Swift-test corpus evidence path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the corpus evidence dimension executable for `swift-test` acceptance packs, against any number of style sets rather than one hardcoded aesthetic.

**Architecture:** A body family becomes the *target*, not the output. Per-family target vectors are derived in the runner from the measurements file the pinned linter already writes. A generator solves control values per family once and pins them in a witnesses file; packs replay a witness instead of solving. The runner gains a corpus path for `swift-test` packs that loops over an array of style-set entries.

**Tech Stack:** Python 3 (`scripts/acceptance_run.py`, `scripts/style_lint.py`, `scripts/test_acceptance_run.py`, stdlib `unittest` only), Swift 6.2 / XCTest, the shipped `vrm-author` CLI.

**Spec:** `docs/superpowers/specs/2026-09-11-swift-test-corpus-path-design.md`

## Global Constraints

- Python: standard library only. No new dependencies. `scripts/acceptance_run.py` and `scripts/style_lint.py` must stay runnable as `python3 <script>` with no install step.
- Swift: 6.2, macOS 26+. New Swift files carry the Apache 2.0 header used by every file in `Sources/` and `Tests/`.
- No temporary or explanatory comments in code or in `CLAUDE.md` (project rule).
- Determinism: every generated artifact must reproduce byte for byte from its pinned inputs. Fixed seeds, fixed iteration budgets, no wall-clock or thread-count dependence.
- Any edit to a file listed in a pack's `runner.environment.oracleHashes` requires re-pinning that pack: recompute each oracle hash, then recompute `packHash` as the sha256 of the pack JSON with `packHash` set to `""`, serialised as `json.dumps(obj, sort_keys=True, separators=(",",":"), ensure_ascii=True)`.
- Tests run with `--disable-sandbox`: `swift test --filter VRMAuthorKitTests --disable-sandbox`.
- Commit after every task. Do not push.
- The pinned style profile is frozen. Never run `style_lint.py envelopes --write` against it.

## Deviation from the spec, decided during planning

The spec's §5 defines `corpus.driver` as "XCTest suite that replays witnesses". Planning verified the entire replay works on shipped CLI surface instead:

```
vrm-author project init --dir P --template native-anime-v1 --seed 42   # 0.2s
vrm-author control set --project P --request edit.json                 # 0.16s
vrm-author build --project P --out draft.vrm                           # 0.86s
python3 scripts/style_lint.py measure draft.vrm --json                 # 0.07s
```

This plan therefore defines `driver` as a **replay driver identifier** with the value `vrm-author-cli`, not an XCTest suite name. Two reasons: the corpus dimension then exercises the shipped binary rather than in-process test code, which is stronger evidence; and no new Swift is needed for either the generator or the replay. The `driver` field stays a string, so reverting to an XCTest driver later needs no schema change.

**If the reviewer rejects this, Tasks 3, 5 and 6 change and the plan must be revised before execution.**

---

### Task 1: Per-family target derivation

Derives one target vector per body family from the measurements file the pinned linter already writes. Pure function, no I/O beyond reading JSON.

**Files:**
- Modify: `scripts/acceptance_run.py` (add functions after `load_json`, around line 87)
- Test: `scripts/test_acceptance_run.py`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `TARGET_METRICS` — a `list[str]` of dotted metric paths forming the target vector.
  - `family_representatives(measurements) -> dict[str, dict]` — family id to the chosen measurement record.
  - `family_targets(measurements) -> dict[str, dict[str, float]]` — family id to `{metric_path: value}`.
  - `metric_value(record, dotted)` — reads a dotted path such as `asset.height_m` or `proportions.head_count` out of one measurement record.

- [ ] **Step 1: Write the failing test**

Append to `scripts/test_acceptance_run.py`, inside a new `class TargetDerivation(unittest.TestCase)`:

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 scripts/test_acceptance_run.py TargetDerivation -v`
Expected: FAIL with `AttributeError: module 'acceptance_run' has no attribute 'family_representatives'`

- [ ] **Step 3: Write minimal implementation**

Insert into `scripts/acceptance_run.py` after `load_json`:

```python
# --------------------------------------------------------------------------- corpus targets

TARGET_METRICS = [
    "asset.height_m",
    "proportions.head_count",
    "proportions.eye_height_ratio",
    "proportions.hips_height_ratio",
    "proportions.upper_leg_height_ratio",
    "proportions.shoulder_width_ratio",
    "proportions.ipd_m",
    "proportions.eye_height_in_head",
    "proportions.head_width_height_ratio",
    "proportions.ipd_head_width_ratio",
    "proportions.head_bone_fraction",
    "proportions.lower_upper_arm_ratio",
    "proportions.lower_upper_leg_ratio",
    "proportions.arm_span_height_ratio",
]


def metric_value(record, dotted):
    section, _, leaf = dotted.partition(".")
    return (record.get(section) or {}).get(leaf)


def family_representatives(measurements):
    """One record per body family: unnoted before noted, VRM 1.0 before 0.x, then manifest order."""
    chosen = {}
    for index, m in enumerate(measurements):
        asset = m["asset"]
        family = asset["body_family"]
        rank = (0 if not asset.get("note") else 1,
                0 if str(asset.get("vrm_version", "")).startswith("1") else 1,
                index)
        if family not in chosen or rank < chosen[family][0]:
            chosen[family] = (rank, m)
    return {f: m for f, (_, m) in chosen.items()}


def family_targets(measurements):
    """Per family, the target coordinates the control space must reach."""
    out = {}
    for family, record in family_representatives(measurements).items():
        vector = {}
        for metric in TARGET_METRICS:
            value = metric_value(record, metric)
            if value is not None:
                vector[metric] = value
        out[family] = vector
    return out
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 scripts/test_acceptance_run.py TargetDerivation -v`
Expected: PASS, 6 tests

- [ ] **Step 5: Check it against the real corpus**

Run:
```bash
python3 -c "
import json, sys; sys.path.insert(0, 'scripts')
import acceptance_run as R
ms = json.load(open('docs/style/corpus/vroid-lineage-anime.measurements.json'))['measurements']
t = R.family_targets(ms)
print(len(t), 'families')
print(sorted(t)[:3])
print(t['sample-A'])"
```
Expected: `18 families`, and `sample-A` carrying `asset.height_m` 1.5581 with 13 further metrics.

- [ ] **Step 6: Run the whole harness suite and commit**

```bash
python3 scripts/test_acceptance_run.py
git add scripts/acceptance_run.py scripts/test_acceptance_run.py
git commit -m "acceptance: derive per-family corpus targets from the pinned measurements"
```

---

### Task 2: Corpus block becomes an array of style-set entries

**Files:**
- Modify: `docs/proposals/vrm-author-cli/acceptance/pack.schema.json` (the `corpus` property)
- Modify: `scripts/acceptance_run.py:230` (the corpus validation rule in `validate_pack`)
- Modify: `docs/proposals/vrm-author-cli/acceptance/packs/style-lint.json` (migrate to an array of one)
- Test: `scripts/test_acceptance_run.py`

**Interfaces:**
- Consumes: `TARGET_METRICS` from Task 1 (validation checks tolerance against known metrics).
- Produces: the `corpus` array contract every later task reads —
  each entry has `styleId`, `profile`, `profileSha256`, `manifest`, `manifestSha256`, `measurements`, `measurementsSha256`, `witnesses`, `witnessesSha256`, `familyKey`, `driver`, `tolerance`, `expectedFamilies`, `minEligibleFamilies`.
  `witnesses`, `witnessesSha256` and `driver` are omitted on `python` packs.

- [ ] **Step 1: Write the failing test**

Append to `scripts/test_acceptance_run.py`:

```python
class CorpusArraySchema(unittest.TestCase):
    def entry(self, **over):
        e = {"styleId": "vroid-lineage-anime",
             "profile": "docs/style/profiles/vroid-lineage-anime.json", "profileSha256": "b" * 64,
             "manifest": "docs/style/corpus/vroid-lineage-anime.manifest.json", "manifestSha256": "c" * 64,
             "measurements": "docs/style/corpus/vroid-lineage-anime.measurements.json", "measurementsSha256": "d" * 64,
             "witnesses": "docs/style/corpus/vroid-lineage-anime.witnesses.native-anime-v1.json", "witnessesSha256": "e" * 64,
             "familyKey": "body_family", "driver": "vrm-author-cli",
             "tolerance": 0.25, "expectedFamilies": 18, "minEligibleFamilies": 4}
        e.update(over)
        return e

    def test_required_corpus_accepts_an_array_of_entries(self):
        pack = make_pack(corpus=[self.entry()], corpus_required=True, runner_kind="swift-test")
        self.assertEqual(R.validate_pack(pack, self.schema), [])

    def test_required_corpus_rejects_the_old_object_form(self):
        pack = make_pack(corpus=self.entry(), corpus_required=True, runner_kind="swift-test")
        self.assertTrue(R.validate_pack(pack, self.schema))

    def test_required_corpus_rejects_an_empty_array(self):
        pack = make_pack(corpus=[], corpus_required=True, runner_kind="swift-test")
        self.assertIn("evidencePolicy.dimensions.corpus is required but the pack declares no style set",
                      R.validate_pack(pack, self.schema))

    def test_swift_test_entry_requires_a_driver(self):
        e = self.entry(); del e["driver"]
        pack = make_pack(corpus=[e], corpus_required=True, runner_kind="swift-test")
        self.assertIn("corpus[0].driver is required when runner.kind is swift-test",
                      R.validate_pack(pack, self.schema))

    def test_duplicate_style_ids_are_rejected(self):
        pack = make_pack(corpus=[self.entry(), self.entry()], corpus_required=True, runner_kind="swift-test")
        self.assertIn("corpus styleId values must be unique", R.validate_pack(pack, self.schema))

    def test_every_corpus_path_must_be_pinned_in_oracle_hashes(self):
        pack = make_pack(corpus=[self.entry()], corpus_required=True, runner_kind="swift-test", pin_corpus=False)
        errors = R.validate_pack(pack, self.schema)
        self.assertTrue(any("must be listed in runner.environment.oracleHashes" in e for e in errors))

    def test_min_eligible_may_not_exceed_expected(self):
        pack = make_pack(corpus=[self.entry(minEligibleFamilies=19)], corpus_required=True, runner_kind="swift-test")
        self.assertIn("corpus[0].minEligibleFamilies must not exceed expectedFamilies",
                      R.validate_pack(pack, self.schema))
```

Add the `make_pack` helper to the same file, next to the existing fixture builders, so every test above builds a schema-valid pack:

```python
def make_pack(corpus=None, corpus_required=False, runner_kind="swift-test", pin_corpus=True):
    """A minimal schema-valid pack, with the corpus block and pinning under test."""
    pack = json.loads(json.dumps(MINIMAL_PACK))
    pack["runner"]["kind"] = runner_kind
    pack["runner"]["entryPoint"] = "SomePackTests" if runner_kind == "swift-test" else "scripts/style_lint.py"
    if runner_kind == "python":
        pack["runner"]["profile"] = "docs/style/profiles/vroid-lineage-anime.json"
        pack["runner"]["environment"]["oracleHashes"]["docs/style/profiles/vroid-lineage-anime.json"] = "b" * 64
    if corpus_required:
        pack["evidencePolicy"]["dimensions"]["corpus"] = "required"
    if corpus is not None:
        pack["corpus"] = corpus
    if pin_corpus and isinstance(corpus, list):
        for e in corpus:
            for path_key, hash_key in (("profile", "profileSha256"), ("manifest", "manifestSha256"),
                                       ("measurements", "measurementsSha256"), ("witnesses", "witnessesSha256")):
                if path_key in e:
                    pack["runner"]["environment"]["oracleHashes"][e[path_key]] = e[hash_key]
    pack["packHash"] = ""
    pack["packHash"] = R.compute_pack_hash(pack)
    return pack
```

`MINIMAL_PACK` is the existing in-file minimal pack fixture; if the file has none, build it by reading `docs/proposals/vrm-author-cli/acceptance/packs/version.json` and stripping its `corpus` key.

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 scripts/test_acceptance_run.py CorpusArraySchema -v`
Expected: FAIL — the schema still declares `corpus` as an object, so the array form is rejected and the new error strings do not exist.

- [ ] **Step 3: Update the JSON schema**

In `docs/proposals/vrm-author-cli/acceptance/pack.schema.json`, replace the `corpus` property with:

```json
"corpus": {
  "type": "array",
  "minItems": 1,
  "description": "Present when evidencePolicy.dimensions.corpus is required: one entry per style set the pack measures. The dimension passes only if every entry passes.",
  "items": {
    "type": "object",
    "additionalProperties": false,
    "required": ["styleId", "profile", "profileSha256", "manifest", "manifestSha256",
                 "measurements", "measurementsSha256", "familyKey", "tolerance",
                 "expectedFamilies", "minEligibleFamilies"],
    "properties": {
      "styleId": { "type": "string", "description": "The profile's id, e.g. vroid-lineage-anime." },
      "profile": { "type": "string" },
      "profileSha256": { "$ref": "#/$defs/sha256" },
      "manifest": { "type": "string" },
      "manifestSha256": { "$ref": "#/$defs/sha256" },
      "measurements": { "type": "string", "description": "Written by style_lint.py corpus; supplies the per-family target vectors." },
      "measurementsSha256": { "$ref": "#/$defs/sha256" },
      "witnesses": { "type": "string", "description": "swift-test packs: solved controls per family, keyed by the corpus and template hashes." },
      "witnessesSha256": { "$ref": "#/$defs/sha256" },
      "familyKey": { "type": "string" },
      "driver": { "type": "string", "description": "swift-test packs: the replay driver. vrm-author-cli replays each witness through the shipped executable." },
      "tolerance": { "type": "number", "exclusiveMinimum": 0, "maximum": 1,
                     "description": "Fraction of each target metric's own rule range width in this style's profile inside which a residual counts as reached." },
      "expectedFamilies": { "type": "integer", "minimum": 1 },
      "minEligibleFamilies": { "type": "integer", "minimum": 1,
                               "description": "Floor below which the dimension is fail, never pass. Closes the vacuous pass at zero eligible families." }
    }
  }
}
```

- [ ] **Step 4: Update `validate_pack`**

In `scripts/acceptance_run.py`, replace the single line at 230 with:

```python
    if pack["evidencePolicy"]["dimensions"]["corpus"] == "required":
        entries = pack.get("corpus")
        if not isinstance(entries, list) or not entries:
            errors.append("evidencePolicy.dimensions.corpus is required but the pack declares no style set")
        else:
            pinned = pack["runner"]["environment"]["oracleHashes"]
            style_ids = [e.get("styleId") for e in entries]
            if len(set(style_ids)) != len(style_ids):
                errors.append("corpus styleId values must be unique")
            for i, e in enumerate(entries):
                if pack["runner"]["kind"] == "swift-test":
                    for field in ("driver", "witnesses", "witnessesSha256"):
                        if not e.get(field):
                            errors.append(f"corpus[{i}].{field} is required when runner.kind is swift-test")
                if e.get("minEligibleFamilies", 0) > e.get("expectedFamilies", 0):
                    errors.append(f"corpus[{i}].minEligibleFamilies must not exceed expectedFamilies")
                for path_key, hash_key in (("profile", "profileSha256"), ("manifest", "manifestSha256"),
                                           ("measurements", "measurementsSha256"), ("witnesses", "witnessesSha256")):
                    path = e.get(path_key)
                    if path and pinned.get(path) != e.get(hash_key):
                        errors.append(f"corpus[{i}].{path_key} must be listed in runner.environment.oracleHashes with the same sha256")
```

- [ ] **Step 5: Run test to verify it passes**

Run: `python3 scripts/test_acceptance_run.py CorpusArraySchema -v`
Expected: PASS, 7 tests

- [ ] **Step 6: Migrate style-lint.json to the array form and re-pin**

`style-lint.json` is the one existing pack whose corpus dimension actually runs; it must keep passing. Run:

```bash
python3 - <<'PY'
import json, hashlib
p = 'docs/proposals/vrm-author-cli/acceptance/packs/style-lint.json'
d = json.load(open(p, encoding='utf-8'))
old = d['corpus']
def sha(path):
    return hashlib.sha256(open(path, 'rb').read()).hexdigest()
measurements = 'docs/style/corpus/vroid-lineage-anime.measurements.json'
d['corpus'] = [{
    "styleId": "vroid-lineage-anime",
    "profile": d['runner']['profile'], "profileSha256": sha(d['runner']['profile']),
    "manifest": old['manifest'], "manifestSha256": old['sha256'],
    "measurements": measurements, "measurementsSha256": sha(measurements),
    "familyKey": old['familyKey'],
    "tolerance": 0.25,
    "expectedFamilies": old['expectedFamilies'],
    "minEligibleFamilies": old['expectedFamilies'],
}]
d['runner']['environment']['oracleHashes'][measurements] = sha(measurements)
d['packHash'] = ''
d['packHash'] = hashlib.sha256(json.dumps(d, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()).hexdigest()
open(p, 'w', encoding='utf-8').write(json.dumps(d, indent=2, ensure_ascii=True) + "\n")
print(d['packHash'])
PY
```

`minEligibleFamilies` equals `expectedFamilies` here because `style lint` measures the corpus directly; every family is eligible by construction, so the floor is the full count.

- [ ] **Step 7: Update `run_corpus` to read entry zero**

`run_corpus` currently reads `self.pack["corpus"]` as an object. Change its first line from `c = self.pack["corpus"]` to `c = self.pack["corpus"][0]`, and change its two uses of `c["sha256"]` to `c["manifestSha256"]`. The python path measures exactly one style set today; Task 5 generalises the loop for `swift-test` packs only.

- [ ] **Step 8: Verify both runner kinds and commit**

```bash
python3 scripts/test_acceptance_run.py
python3 scripts/acceptance_run.py docs/proposals/vrm-author-cli/acceptance/packs/style-lint.json
python3 scripts/acceptance_run.py docs/proposals/vrm-author-cli/acceptance/packs/version.json
git add docs/proposals/vrm-author-cli/acceptance scripts
git commit -m "acceptance: corpus becomes an array of style-set entries"
```
Expected: harness tests pass; `style-lint` PASS; `version` PASS.

---

### Task 3: Witness generator

Solves control values per family by driving the shipped CLI, and writes the witnesses file. Runs once per (corpus, template) pair, off the critical path.

**Files:**
- Create: `scripts/corpus_witness.py`
- Test: `scripts/test_corpus_witness.py`

**Interfaces:**
- Consumes: `family_targets` and `TARGET_METRICS` from Task 1, imported from `acceptance_run`.
- Produces:
  - `rule_widths(profile) -> dict[str, float]` — metric path to its rule range width in that profile.
  - `residuals(observed, target, widths) -> dict[str, float]` — per-metric absolute residual divided by that metric's width.
  - `eligible(res, tolerance) -> bool`.
  - `solve(family, target, evaluate, budget, seed) -> dict` — one witness record.
  - The witnesses file format every later task reads:
    ```json
    {"corpusManifestSha256": "...", "templateId": "native-anime-v1", "templateSha256": "...",
     "profileId": "vroid-lineage-anime", "solver": {"budget": 200, "seed": 42},
     "generated": {"command": "...", "styleLintSha256": "...", "measurementsSha256": "..."},
     "families": {"sample-A": {"eligible": true, "controls": {"body.heightM": 1.5581},
                               "residuals": {"asset.height_m": 0.0}}}}
    ```

- [ ] **Step 1: Write the failing test**

Create `scripts/test_corpus_witness.py`:

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 scripts/test_corpus_witness.py`
Expected: FAIL with `ModuleNotFoundError: No module named 'corpus_witness'`

- [ ] **Step 3: Write the generator**

Create `scripts/corpus_witness.py`:

```python
#!/usr/bin/env python3
"""Solve per-family control values for one (corpus, template) pair and write a witnesses file.

Drives the shipped vrm-author CLI: project init, control set, build, then
style_lint.py measure on the built avatar. Runs once per pair, off the critical
path of any acceptance pack.

    python3 scripts/corpus_witness.py \
        --measurements docs/style/corpus/vroid-lineage-anime.measurements.json \
        --manifest docs/style/corpus/vroid-lineage-anime.manifest.json \
        --profile docs/style/profiles/vroid-lineage-anime.json \
        --template native-anime-v1 \
        --out docs/style/corpus/vroid-lineage-anime.witnesses.native-anime-v1.json
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from acceptance_run import family_targets, metric_value

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DIRECT_CONTROLS = {"asset.height_m": "body.heightM", "proportions.head_count": "body.headCount"}
SEARCH_CONTROLS = ["body.proportion.shoulderWidth", "body.proportion.torsoLength",
                   "body.proportion.armLength", "body.proportion.legLength",
                   "body.proportion.hipWidth", "body.shape.chest", "body.shape.waist",
                   "body.shape.hip", "body.shape.muscle"]


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def rule_widths(profile):
    """Metric path to the width of its two-sided rule range; one-sided rules have no scale."""
    widths = {}
    for rule in profile["rules"]:
        check = rule.get("check") or {}
        if check.get("type") == "range" and "min" in check and "max" in check:
            widths[rule["metric"]] = float(check["max"]) - float(check["min"])
    return widths


def residuals(observed, target, widths):
    """Per-metric absolute error as a fraction of that metric's rule range width."""
    out = {}
    for metric, want in target.items():
        width = widths.get(metric)
        got = observed.get(metric)
        if width is None or width == 0 or got is None:
            continue
        out[metric] = abs(float(got) - float(want)) / width
    return out


def eligible(res, tolerance):
    return bool(res) and all(v <= tolerance for v in res.values())


def solve(family, target, evaluate, widths, tolerance, budget, seed):
    """Set the directly invertible controls exactly, then search the rest deterministically."""
    rng = random.Random(f"{seed}:{family}")
    controls = {}
    for metric, key in DIRECT_CONTROLS.items():
        if metric in target:
            controls[key] = float(target[metric])
    for key in SEARCH_CONTROLS:
        controls[key] = 0.0

    best = dict(controls)
    best_res = residuals(evaluate(best), target, widths)
    best_score = max(best_res.values()) if best_res else float("inf")

    step = 0.5
    for i in range(budget):
        if best_score <= tolerance:
            break
        candidate = dict(best)
        key = SEARCH_CONTROLS[i % len(SEARCH_CONTROLS)]
        delta = step * (1 if rng.random() < 0.5 else -1)
        candidate[key] = max(-1.0, min(1.0, candidate[key] + delta))
        res = residuals(evaluate(candidate), target, widths)
        score = max(res.values()) if res else float("inf")
        if score < best_score:
            best, best_res, best_score = candidate, res, score
        else:
            step = max(step * 0.75, 0.01)

    return {"family": family, "eligible": eligible(best_res, tolerance),
            "controls": {k: round(v, 6) for k, v in sorted(best.items())},
            "residuals": {k: round(v, 6) for k, v in sorted(best_res.items())}}


def cli_evaluator(binary, template, seed, linter, workdir):
    """Build an avatar at the given controls and return its measured metric vector."""

    def evaluate(controls):
        project = os.path.join(workdir, "a.vrmauthor")
        out = os.path.join(workdir, "draft.vrm")
        shutil.rmtree(project, ignore_errors=True)
        if os.path.exists(out):
            os.remove(out)
        subprocess.run([binary, "project", "init", "--dir", project, "--template", template,
                        "--seed", str(seed)], cwd=REPO, check=True, capture_output=True)
        request = os.path.join(workdir, "edit.json")
        with open(request, "w", encoding="utf-8") as fh:
            json.dump({"edit": {"object": "avatar:main", "values": controls}}, fh)
        subprocess.run([binary, "control", "set", "--project", project, "--request", request],
                       cwd=REPO, check=True, capture_output=True)
        subprocess.run([binary, "build", "--project", project, "--out", out],
                       cwd=REPO, check=True, capture_output=True)
        proc = subprocess.run([sys.executable, linter, "measure", out, "--json"],
                              cwd=REPO, check=True, capture_output=True, text=True)
        record = json.loads(proc.stdout)[0]
        return {m: metric_value(record, m) for m in list(DIRECT_CONTROLS) + [
            r for r in rule_widths_cache] if metric_value(record, m) is not None}

    return evaluate


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--measurements", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--profile", required=True)
    ap.add_argument("--template", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--binary", default=".build/debug/vrm-author")
    ap.add_argument("--linter", default="scripts/style_lint.py")
    ap.add_argument("--tolerance", type=float, default=0.25)
    ap.add_argument("--budget", type=int, default=200)
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args(argv)

    profile = json.load(open(os.path.join(REPO, args.profile), encoding="utf-8"))
    widths = rule_widths(profile)
    measurements = json.load(open(os.path.join(REPO, args.measurements), encoding="utf-8"))["measurements"]
    targets = family_targets(measurements)

    binary = os.path.join(REPO, args.binary)
    if not os.path.exists(binary):
        print(f"vrm-author not found at {args.binary}; run swift build first", file=sys.stderr)
        return 2

    template_sha = template_hash(binary, args.template)
    families = {}
    with tempfile.TemporaryDirectory(prefix="corpus_witness_") as workdir:
        evaluate = cli_evaluator(binary, args.template, args.seed, os.path.join(REPO, args.linter), workdir)
        for family in sorted(targets):
            witness = solve(family, targets[family], evaluate, widths,
                            args.tolerance, args.budget, args.seed)
            families[family] = {k: witness[k] for k in ("eligible", "controls", "residuals")}
            print(f"{family}: {'eligible' if witness['eligible'] else 'INELIGIBLE'}", file=sys.stderr)

    document = {
        "corpusManifestSha256": sha256_file(os.path.join(REPO, args.manifest)),
        "templateId": args.template,
        "templateSha256": template_sha,
        "profileId": profile["id"],
        "solver": {"budget": args.budget, "seed": args.seed, "tolerance": args.tolerance},
        "generated": {"styleLintSha256": sha256_file(os.path.join(REPO, args.linter)),
                      "measurementsSha256": sha256_file(os.path.join(REPO, args.measurements))},
        "families": families,
    }
    with open(os.path.join(REPO, args.out), "w", encoding="utf-8") as fh:
        fh.write(json.dumps(document, indent=2, sort_keys=True, ensure_ascii=True) + "\n")
    eligible_count = sum(1 for f in families.values() if f["eligible"])
    print(f"{eligible_count}/{len(families)} families eligible -> {args.out}", file=sys.stderr)
    return 0


def template_hash(binary, template_id):
    proc = subprocess.run([binary, "template", "list"], cwd=REPO, check=True,
                          capture_output=True, text=True)
    packs = json.loads(proc.stdout)["result"]["packs"]
    for pack in packs:
        if pack["id"] == template_id:
            return pack["sha256"]
    raise SystemExit(f"template {template_id!r} is not installed")


if __name__ == "__main__":
    raise SystemExit(main())
```

Then fix the one placeholder in `cli_evaluator`: replace the `rule_widths_cache` reference by passing the metric list in. Change the signature to `cli_evaluator(binary, template, seed, linter, workdir, metrics)` and the return line to:

```python
        return {m: metric_value(record, m) for m in metrics if metric_value(record, m) is not None}
```

and the call site in `main` to `cli_evaluator(binary, args.template, args.seed, os.path.join(REPO, args.linter), workdir, list(widths))`.

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 scripts/test_corpus_witness.py`
Expected: PASS, 8 tests

- [ ] **Step 5: Commit**

```bash
git add scripts/corpus_witness.py scripts/test_corpus_witness.py
git commit -m "acceptance: witness generator for per-family control solutions"
```

---

### Task 4: Generate and pin the vroid witnesses file

Produces the first real reach measurement. Its eligible count is the input to the deferred approach-A decision in the spec.

**Files:**
- Create: `docs/style/corpus/vroid-lineage-anime.witnesses.native-anime-v1.json`

**Interfaces:**
- Consumes: `scripts/corpus_witness.py` from Task 3.
- Produces: the witnesses file Tasks 5 and 6 pin and replay.

- [ ] **Step 1: Build the CLI**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 2: Run the generator**

```bash
python3 scripts/corpus_witness.py \
  --measurements docs/style/corpus/vroid-lineage-anime.measurements.json \
  --manifest docs/style/corpus/vroid-lineage-anime.manifest.json \
  --profile docs/style/profiles/vroid-lineage-anime.json \
  --template native-anime-v1 \
  --out docs/style/corpus/vroid-lineage-anime.witnesses.native-anime-v1.json
```

Expect roughly 18 families × up to 200 iterations × 1.1s per iteration, so up to an hour. It prints each family's verdict as it goes and a final `N/18 families eligible`.

- [ ] **Step 3: Verify determinism**

```bash
cp docs/style/corpus/vroid-lineage-anime.witnesses.native-anime-v1.json /tmp/w1.json
python3 scripts/corpus_witness.py --measurements docs/style/corpus/vroid-lineage-anime.measurements.json \
  --manifest docs/style/corpus/vroid-lineage-anime.manifest.json \
  --profile docs/style/profiles/vroid-lineage-anime.json --template native-anime-v1 \
  --out /tmp/w2.json
diff /tmp/w1.json /tmp/w2.json && echo IDENTICAL
```
Expected: `IDENTICAL`. If it differs, the solver has a nondeterminism bug; fix it before continuing, because the file cannot be a pin otherwise.

- [ ] **Step 4: Record the reach count and commit**

```bash
python3 -c "
import json
d = json.load(open('docs/style/corpus/vroid-lineage-anime.witnesses.native-anime-v1.json'))
fams = d['families']
ok = [f for f, v in fams.items() if v['eligible']]
print(f'{len(ok)}/{len(fams)} eligible:', sorted(ok))
for f, v in sorted(fams.items()):
    if not v['eligible']:
        worst = max(v['residuals'].items(), key=lambda kv: kv[1])
        print(f'  {f} blocked by {worst[0]} at {worst[1]}')"
git add docs/style/corpus/vroid-lineage-anime.witnesses.native-anime-v1.json
git commit -m "corpus: pin native-anime-v1 witnesses for the vroid-lineage-anime families"
```

Report the eligible count to the reviewer. It sets `minEligibleFamilies` in Task 6 and decides whether the spec's deferred approach A is worth revisiting.

---

### Task 5: Runner corpus path for swift-test packs

**Files:**
- Modify: `scripts/acceptance_run.py` (add `run_corpus_swift`, extend `run_swift_test` around line 698, extend `worst` handling)
- Test: `scripts/test_acceptance_run.py`

**Interfaces:**
- Consumes: `family_targets` (Task 1), the corpus array contract (Task 2), the witnesses format (Task 3).
- Produces: `Runner.run_corpus_swift(entry) -> dict` with keys `styleId`, `families`, `familiesTotal`, `familiesEligible`, `familiesPassed`, `status`; and `result["corpus"]` as a list of those records.

- [ ] **Step 1: Write the failing test**

Append to `scripts/test_acceptance_run.py`:

```python
class CorpusRollup(unittest.TestCase):
    def rollup(self, families, min_eligible, expected=4):
        return R.corpus_status(families, min_eligible, expected)

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 scripts/test_acceptance_run.py CorpusRollup -v`
Expected: FAIL with `AttributeError: module 'acceptance_run' has no attribute 'corpus_status'`

- [ ] **Step 3: Add the roll-up function**

Insert into `scripts/acceptance_run.py` next to `worst`:

```python
def corpus_status(families, min_eligible, expected):
    """Roll one style set's per-family records up to a dimension status.

    Ineligible families are neither a pass nor a fail, but the eligible count
    must clear the floor or the dimension fails: "every eligible family passed"
    is vacuously true at zero eligible families.
    """
    statuses = [f["status"] for f in families.values()]
    if "fail" in statuses:
        return "fail"
    if sum(1 for s in statuses if s != "ineligible") < min_eligible:
        return "fail"
    if "pending" in statuses:
        return "pending"
    return "pass"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 scripts/test_acceptance_run.py CorpusRollup -v`
Expected: PASS, 7 tests

- [ ] **Step 5: Add the swift-test corpus path**

Insert into the `Runner` class, after `run_corpus`:

```python
    def corpus_entry_paths(self, entry):
        return [entry[k] for k in ("profile", "manifest", "measurements", "witnesses") if entry.get(k)]

    def run_corpus_swift(self, entry):
        """Replay the pinned witnesses for one style set and lint each emitted artifact."""
        out = {"styleId": entry["styleId"], "families": {}, "familiesTotal": 0,
               "familiesEligible": 0, "familiesPassed": 0}
        for rel in self.corpus_entry_paths(entry):
            path = self.repo_path(rel)
            if not os.path.exists(path):
                out.update(status="pending", reason=f"{rel} is absent")
                return out
        for path_key, hash_key in (("profile", "profileSha256"), ("manifest", "manifestSha256"),
                                   ("measurements", "measurementsSha256"), ("witnesses", "witnessesSha256")):
            if entry.get(path_key) and sha256_file(self.repo_path(entry[path_key])) != entry[hash_key]:
                out.update(status="fail", reason=f"{entry[path_key]} does not match its pinned sha256")
                return out

        witnesses = load_json(self.repo_path(entry["witnesses"]))
        measurements = load_json(self.repo_path(entry["measurements"]))["measurements"]
        targets = family_targets(measurements)
        widths = self.profile_rule_widths(entry)
        out["familiesTotal"] = len(targets)

        for family in sorted(targets):
            witness = witnesses["families"].get(family)
            if witness is None:
                out["families"][family] = {"status": "pending", "reason": "no witness for this family"}
                continue
            if not witness["eligible"]:
                worst_metric = max(witness["residuals"].items(), key=lambda kv: kv[1], default=(None, None))
                out["families"][family] = {"status": "ineligible", "residuals": witness["residuals"],
                                           "blockedBy": worst_metric[0]}
                continue
            out["familiesEligible"] += 1
            record = self.replay_family(entry, family, witness, targets[family], widths)
            out["families"][family] = record
            if record["status"] == "pass":
                out["familiesPassed"] += 1

        out["status"] = corpus_status(out["families"], entry["minEligibleFamilies"], entry["expectedFamilies"])
        return out

    def profile_rule_widths(self, entry):
        profile = load_json(self.repo_path(entry["profile"]))
        widths = {}
        for rule in profile["rules"]:
            check = rule.get("check") or {}
            if check.get("type") == "range" and "min" in check and "max" in check:
                widths[rule["metric"]] = float(check["max"]) - float(check["min"])
        return widths
```

`replay_family` is defined in Task 6, which supplies the per-pack assertions. For this task, add a placeholder that only builds and lints, so the path is testable end to end:

```python
    def replay_family(self, entry, family, witness, target, widths):
        """Replay one witness through the shipped CLI and lint the result."""
        binary = self.repo_path(".build/debug/vrm-author")
        if not os.path.exists(binary):
            return {"status": "pending", "reason": "vrm-author not built"}
        if self.tmp is None:
            self.tmp = tempfile.mkdtemp(prefix="acceptance_run_")
        work = os.path.join(self.tmp, f"corpus-{entry['styleId']}-{family}")
        os.makedirs(work, exist_ok=True)
        project = os.path.join(work, "a.vrmauthor")
        draft = os.path.join(work, "draft.vrm")
        request = os.path.join(work, "edit.json")
        with open(request, "w", encoding="utf-8") as fh:
            json.dump({"edit": {"object": "avatar:main", "values": witness["controls"]}}, fh)
        deadline = self.pack["resources"]["deadlineSeconds"]
        steps = [[binary, "project", "init", "--dir", project, "--template", witness_template(entry, self), "--seed", "42"],
                 [binary, "control", "set", "--project", project, "--request", request],
                 [binary, "build", "--project", project, "--out", draft]]
        for cmd in steps:
            proc = subprocess.run(cmd, cwd=self.repo, capture_output=True, text=True, timeout=deadline)
            if proc.returncode != 0:
                return {"status": "fail", "reason": f"{cmd[1]} {cmd[2]} exited {proc.returncode}: {proc.stderr[-400:]}"}
        env = self.run_lint_with(entry["profile"], draft)
        ok, why = self.accept_envelope(env)
        if not ok or env["report"] is None:
            return {"status": "fail", "reason": why or "no lint report"}
        return {"status": "fail" if env["report"]["summary"]["must"]["fail"] else "pass",
                "verdict": env["report"]["verdict"], "artifact": draft}
```

`run_lint` currently hardcodes `runner.profile`. Add a sibling that takes the profile explicitly, and make `run_lint` call it:

```python
    def run_lint_with(self, profile_rel, asset_path):
        r = self.pack["runner"]
        entry_point = r["entryPoint"] if r["kind"] == "python" else "scripts/style_lint.py"
        cmd = [sys.executable, self.repo_path(entry_point), "lint",
               "--profile", self.repo_path(profile_rel), "--json", asset_path]
        deadline = self.pack["resources"]["deadlineSeconds"]
        try:
            proc = subprocess.run(cmd, cwd=self.repo, capture_output=True, text=True, timeout=deadline)
        except subprocess.TimeoutExpired:
            return {"report": None, "oracleHashes": dict(self.oracle_hashes), "exitCode": None,
                    "stderr": f"timeout after {deadline}s"}
        return self._lint_envelope(proc)

    def run_lint(self, asset_path):
        return self.run_lint_with(self.pack["runner"]["profile"], asset_path)
```

Move the body of the existing `run_lint` after the `subprocess.run` call into `_lint_envelope(proc)` unchanged, so the python path behaves identically.

Add the small helper `witness_template` at module scope:

```python
def witness_template(entry, runner):
    return load_json(runner.repo_path(entry["witnesses"]))["templateId"]
```

- [ ] **Step 6: Wire it into the swift-test rollup**

In `run_swift_test`, immediately after `result["swiftTest"] = env["report"]`, insert:

```python
        if self.pack["evidencePolicy"]["dimensions"]["corpus"] == "required":
            result["corpus"] = [self.run_corpus_swift(e) for e in self.pack["corpus"]]
            result["dimensions"]["corpus"] = worst([c["status"] for c in result["corpus"]])
```

`run` initialises `result["corpus"]` to `None`; change that initialiser to `[]` and make the python path append its single record so both kinds carry a list. In `print_summary`, replace the single-corpus branch with a loop that prints one line per style set:

```python
    for c in result.get("corpus") or []:
        print(f"  corpus  [{c['styleId']}] {c.get('familiesPassed', 0)}/{c.get('familiesEligible', 0)} eligible pass, "
              f"{c.get('familiesTotal', 0)} families: {c['status']}")
```

- [ ] **Step 7: Verify the harness and the python path still pass**

```bash
python3 scripts/test_acceptance_run.py
python3 scripts/acceptance_run.py docs/proposals/vrm-author-cli/acceptance/packs/style-lint.json
```
Expected: harness tests pass; `style-lint` still PASS with its corpus line printed per style set.

- [ ] **Step 8: Commit**

```bash
git add scripts/acceptance_run.py scripts/test_acceptance_run.py
git commit -m "acceptance: corpus path for swift-test packs, per style set"
```

---

### Task 6: Per-pack assertions and pack migration

**Files:**
- Modify: `scripts/acceptance_run.py` (`replay_family` gains the per-operation assertions)
- Modify: `docs/proposals/vrm-author-cli/acceptance/packs/build.json`, `control-set.json`, `export-vrm.json`, `recipe-apply.json`
- Test: `scripts/test_acceptance_run.py`

**Interfaces:**
- Consumes: `run_corpus_swift` and `replay_family` from Task 5.
- Produces: `CORPUS_ASSERTIONS` — a `dict[str, callable]` keyed by the pack's `operation`, each taking `(runner, entry, work, draft, target, widths)` and returning `(status, detail)`.

- [ ] **Step 1: Write the failing test**

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 scripts/test_acceptance_run.py CorpusAssertions -v`
Expected: FAIL with `AttributeError: module 'acceptance_run' has no attribute 'CORPUS_ASSERTIONS'`

- [ ] **Step 3: Implement the assertions**

```python
def measured_vector(runner, asset_path, metrics):
    """The pinned linter's metric vector for one asset, profile-independent."""
    proc = subprocess.run([sys.executable, runner.repo_path("scripts/style_lint.py"), "measure", asset_path, "--json"],
                          cwd=runner.repo, capture_output=True, text=True,
                          timeout=runner.pack["resources"]["deadlineSeconds"])
    if proc.returncode != 0:
        return None
    record = json.loads(proc.stdout)[0]
    return {m: metric_value(record, m) for m in metrics if metric_value(record, m) is not None}


def reach_holds(observed, target, widths, tolerance):
    """Every target metric within tolerance of its corpus-derived value."""
    over = {m: round(abs(observed[m] - target[m]) / widths[m], 6)
            for m in target
            if m in observed and widths.get(m) and abs(observed[m] - target[m]) / widths[m] > tolerance}
    return (not over, None if not over else f"outside tolerance: {over}")


def export_metrics_match(draft_vector, export_vector):
    """Export must preserve the draft's measured geometry exactly; both are GLB and byte-deterministic."""
    differing = {m: (draft_vector.get(m), export_vector.get(m))
                 for m in set(draft_vector) | set(export_vector)
                 if draft_vector.get(m) != export_vector.get(m)}
    return (not differing, None if not differing else f"metric drift through export: {differing}")


CORPUS_ASSERTIONS = {
    "control set": "reach",
    "recipe apply": "reach",
    "build": "conforming",
    "export vrm": "export",
}
```

Then extend `replay_family` to dispatch on `self.pack["operation"]` after the draft is built:

```python
        mode = CORPUS_ASSERTIONS.get(self.pack["operation"], "conforming")
        vector = measured_vector(self, draft, list(widths))
        if vector is None:
            return {"status": "fail", "reason": "style_lint measure failed on the draft"}
        if mode == "reach":
            ok, detail = reach_holds(vector, target, widths, entry["tolerance"])
            if not ok:
                return {"status": "fail", "reason": detail, "observed": vector}
        if mode == "export":
            final = os.path.join(work, "final.vrm")
            proc = subprocess.run([binary, "export", "vrm", "--project", project, "--out", final],
                                  cwd=self.repo, capture_output=True, text=True, timeout=deadline)
            if proc.returncode != 0:
                return {"status": "fail", "reason": f"export vrm exited {proc.returncode}: {proc.stderr[-400:]}"}
            ok, detail = export_metrics_match(vector, measured_vector(self, final, list(widths)) or {})
            if not ok:
                return {"status": "fail", "reason": detail}
            draft = final
        env = self.run_lint_with(entry["profile"], draft)
```

The existing lint block after this point is unchanged. `recipe apply` uses the same `reach` mode as `control set`; the difference is that its witness is applied through a recipe rather than a control edit, which the CLI does by the same `control set` call in this replay. Record that limitation in the pack's `scope.excluded` rather than pretending otherwise:
add `"recipe-path reach is replayed through control set; the recipe path itself is fixture-covered"` to `recipe-apply.json`'s `scope.excluded`.

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 scripts/test_acceptance_run.py CorpusAssertions -v`
Expected: PASS, 4 tests

- [ ] **Step 5: Migrate the four packs**

For each of `build.json`, `control-set.json`, `export-vrm.json`, `recipe-apply.json`: replace the `corpus` object with a one-entry array, using the witnesses file from Task 4 and the eligible count it reported. Set `minEligibleFamilies` to the eligible count reported in Task 4, so the floor records the reach actually achieved and any later regression fails.

```bash
python3 - <<'PY'
import json, hashlib, os
W = 'docs/style/corpus/vroid-lineage-anime.witnesses.native-anime-v1.json'
M = 'docs/style/corpus/vroid-lineage-anime.measurements.json'
MAN = 'docs/style/corpus/vroid-lineage-anime.manifest.json'
PROF = 'docs/style/profiles/vroid-lineage-anime.json'
def sha(p): return hashlib.sha256(open(p, 'rb').read()).hexdigest()
eligible = sum(1 for v in json.load(open(W))['families'].values() if v['eligible'])
for name in ('build', 'control-set', 'export-vrm', 'recipe-apply'):
    p = f'docs/proposals/vrm-author-cli/acceptance/packs/{name}.json'
    d = json.load(open(p, encoding='utf-8'))
    old = d['corpus']
    d['corpus'] = [{
        "styleId": "vroid-lineage-anime",
        "profile": PROF, "profileSha256": sha(PROF),
        "manifest": MAN, "manifestSha256": sha(MAN),
        "measurements": M, "measurementsSha256": sha(M),
        "witnesses": W, "witnessesSha256": sha(W),
        "familyKey": old['familyKey'], "driver": "vrm-author-cli",
        "tolerance": 0.25,
        "expectedFamilies": old['expectedFamilies'],
        "minEligibleFamilies": eligible,
    }]
    for path in (PROF, MAN, M, W):
        d['runner']['environment']['oracleHashes'][path] = sha(path)
    if name == 'build':
        d['scope']['excluded'] = [x for x in d['scope']['excluded'] if x != 'corpus-wide builds']
    if name == 'recipe-apply':
        d['scope']['excluded'].append('recipe-path reach is replayed through control set; the recipe path itself is fixture-covered')
    d['packHash'] = ''
    d['packHash'] = hashlib.sha256(json.dumps(d, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()).hexdigest()
    open(p, 'w', encoding='utf-8').write(json.dumps(d, indent=2, ensure_ascii=True) + "\n")
    print(name, d['packHash'])
PY
```

- [ ] **Step 6: Run the four packs**

```bash
swift build
for p in build control-set export-vrm recipe-apply; do
  python3 scripts/acceptance_run.py docs/proposals/vrm-author-cli/acceptance/packs/$p.json | head -20
done
```
Expected: each reports `corpus [vroid-lineage-anime] N/N eligible pass`. `visual` stays `pending`, so overall status stays PENDING for the visually-validated packs; that is correct and unchanged.

- [ ] **Step 7: Commit**

```bash
python3 scripts/test_acceptance_run.py
git add scripts docs/proposals/vrm-author-cli/acceptance
git commit -m "acceptance: corpus assertions per operation and the four pack migrations"
```

---

### Task 7: Material shading carve-out

**Files:**
- Modify: `docs/proposals/vrm-author-cli/acceptance/packs/material-shading.json`
- Modify: `Tests/VRMAuthorKitTests/Materials/MaterialsPackTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: nothing later tasks read.

- [ ] **Step 1: Write the failing test**

Append to `Tests/VRMAuthorKitTests/Materials/MaterialsPackTests.swift`:

```swift
    func testShadingSolvesAtParameterExtremesForEveryRole() throws {
        let extremes: [(shadowEnd: Double, terminatorWidth: Double)] = [
            (-1.0, 0.0), (-1.0, 2.0), (0.0, 0.0), (0.0, 2.0), (-1.0, 0.0),
        ]
        for role in MaterialRole.allCases {
            for point in extremes {
                let solved = try MToonShadingSolver.solve(shadowEnd: point.shadowEnd, terminatorWidth: point.terminatorWidth)
                XCTAssertTrue((-1.0...1.0).contains(solved.shift), "\(role) shift out of range at \(point)")
                XCTAssertTrue((0.0...1.0).contains(solved.toony), "\(role) toony out of range at \(point)")
            }
        }
    }
```

Replace `MToonShadingSolver.solve` with whatever the existing suite already calls to solve shading; grep `MaterialsPackTests.swift` for the current call and reuse that exact symbol.

- [ ] **Step 2: Run test to verify it fails or passes**

Run: `swift test --filter MaterialsPackTests --disable-sandbox`
If it passes immediately the solver already covers the extremes; keep the test as the pinned record of that and continue.

- [ ] **Step 3: Amend the pack**

```bash
python3 - <<'PY'
import json, hashlib
p = 'docs/proposals/vrm-author-cli/acceptance/packs/material-shading.json'
d = json.load(open(p, encoding='utf-8'))
d.pop('corpus', None)
d['evidencePolicy']['dimensions']['corpus'] = 'inapplicable'
d['evidencePolicy']['corpusApplicabilityRecord'] = (
    "material shading is body-independent: its input class is a project material object with MToon "
    "fields, so partitioning by body family is pseudo-precision for any style. The parameter space is "
    "covered instead by a fixture sweep over shadowEnd and terminatorWidth extremes across every "
    "material role the attached profile declares. Recorded by the acceptance author; the independent "
    "reviewer confirms or overturns this in reviewReceipt.")
d['scope']['invariants'].append(
    "shadowEnd and terminatorWidth at their range extremes and the (-1, 0) edge solve to legal "
    "toony/shift for every material role")
d['packHash'] = ''
d['packHash'] = hashlib.sha256(json.dumps(d, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()).hexdigest()
open(p, 'w', encoding='utf-8').write(json.dumps(d, indent=2, ensure_ascii=True) + "\n")
print(d['packHash'])
PY
```

Add `corpusApplicabilityRecord` as an optional string property of `evidencePolicy` in `pack.schema.json`, alongside the existing `heldOutPolicy`.

- [ ] **Step 4: Re-pin the oracle hash for the edited test file and run the pack**

```bash
python3 - <<'PY'
import json, hashlib
p = 'docs/proposals/vrm-author-cli/acceptance/packs/material-shading.json'
d = json.load(open(p, encoding='utf-8'))
for k in d['runner']['environment']['oracleHashes']:
    d['runner']['environment']['oracleHashes'][k] = hashlib.sha256(open(k, 'rb').read()).hexdigest()
d['packHash'] = ''
d['packHash'] = hashlib.sha256(json.dumps(d, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()).hexdigest()
open(p, 'w', encoding='utf-8').write(json.dumps(d, indent=2, ensure_ascii=True) + "\n")
PY
python3 scripts/acceptance_run.py docs/proposals/vrm-author-cli/acceptance/packs/material-shading.json | head -12
```
Expected: `corpus=inapplicable` in the dimensions line.

- [ ] **Step 5: Commit**

```bash
git add docs/proposals/vrm-author-cli/acceptance Tests/VRMAuthorKitTests/Materials/MaterialsPackTests.swift
git commit -m "acceptance: material shading takes a reviewed corpus inapplicability and a parameter sweep"
```

---

### Task 8: Remove the hardcoded profile from Swift

**Files:**
- Modify: `Sources/VRMAuthorKit/Materials/StyleToolchain.swift:24-25`
- Modify: `Sources/VRMAuthorKit/QA/QASuite.swift:21-22`
- Test: `Tests/VRMAuthorKitTests/Materials/StyleLintTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `StyleToolchain.locate(context:profile:)` taking an explicit profile blob, defaulting to the project's attached style.

- [ ] **Step 1: Write the failing test**

Append to `Tests/VRMAuthorKitTests/Materials/StyleLintTests.swift`:

```swift
    func testToolchainResolvesTheProjectsAttachedProfileNotAModuleConstant() throws {
        let alternate = try fx.write("{\"id\":\"other-style\",\"version\":\"0.1.0\",\"rules\":[]}", "profiles/other-style.json")
        let blob = Blob(path: alternate.path, sha256: SHA256Hex.hex(try Data(contentsOf: alternate)))
        let located = StyleToolchain.locate(context: MaterialsTestSupport.context(), profile: blob)
        XCTAssertEqual(located.profile?.lastPathComponent, "other-style.json")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StyleLintTests --disable-sandbox`
Expected: FAIL — `locate` has no `profile:` parameter.

- [ ] **Step 3: Add the explicit-profile overload**

In `StyleToolchain.swift`, add a `profile: Blob?` parameter to `locate`, defaulting to `nil`. When non-nil, resolve that path and verify its sha256 against the blob rather than against `pinnedProfileSHA256`. When nil, keep today's behaviour exactly, so every existing caller is unchanged.

Leave `NativeAnimeV1Pack.styleProfilePath` and `styleProfileSha256` in place: a template pack binding its own style is the mechanism a second style uses.

For `QASuite.defaultProfilePath` and `defaultProfileSha256`, add a doc comment recording that they are the fallback when a project has no attached style, and leave the values.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter StyleLintTests --disable-sandbox`
Expected: PASS

- [ ] **Step 5: Run the full suite, re-pin affected packs and commit**

```bash
swift test --filter VRMAuthorKitTests --disable-sandbox
python3 - <<'PY'
import json, glob, hashlib, os
for p in sorted(glob.glob('docs/proposals/vrm-author-cli/acceptance/packs/*.json')):
    d = json.load(open(p, encoding='utf-8'))
    hs = d['runner']['environment']['oracleHashes']
    dirty = False
    for k, v in list(hs.items()):
        if os.path.exists(k):
            cur = hashlib.sha256(open(k, 'rb').read()).hexdigest()
            if cur != v:
                hs[k] = cur; dirty = True
    if dirty:
        d['packHash'] = ''
        d['packHash'] = hashlib.sha256(json.dumps(d, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()).hexdigest()
        open(p, 'w', encoding='utf-8').write(json.dumps(d, indent=2, ensure_ascii=True) + "\n")
        print('re-pinned', os.path.basename(p))
PY
git add Sources Tests docs/proposals/vrm-author-cli/acceptance
git commit -m "vrm-author: resolve the style profile from the caller rather than a module constant"
```

---

### Task 9: Verification contract edits

**Files:**
- Modify: `docs/proposals/vrm-author-cli/verification.md` (§1 around line 57, §2 around line 69, §3 around line 96, §4 around line 111, §6 around line 190)

**Interfaces:**
- Consumes: the artifact names and hashes produced by Tasks 3, 4 and 6.
- Produces: nothing later tasks read.

- [ ] **Step 1: Amend §1 with the body-independent class**

After the sentence beginning "A discovery or CRUD pack may declare the visual and corpus dimensions inapplicable", add:

```markdown
A **body-independent** pack may declare the corpus dimension inapplicable on the same
terms. A pack is body-independent when its input class contains no body geometry, so
partitioning its inputs by body family carries no information; `material shading`, whose
input is a project material object, is the v1 example. The record names the parameter
sweep that covers its input space instead.
```

- [ ] **Step 2: Amend §2's oracle table**

Replace the paragraph beginning "Three in-tree files are the v1 oracles" with a sentence saying the style linter is a single global oracle and the remaining oracles are grouped per style set, then restructure the table:

```markdown
| Oracle | Path | sha256 |
|---|---|---|
| Style linter (global) | [`scripts/style_lint.py`](../../../scripts/style_lint.py) | `01679f040546fa76b6c4b8f6c84244388201ad04f0f449157c5ec634716b5881` |

**Style set `vroid-lineage-anime`:**

| Oracle | Path | sha256 |
|---|---|---|
| Profile v0.1.0 | [`docs/style/profiles/vroid-lineage-anime.json`](../../style/profiles/vroid-lineage-anime.json) | `7eeb1f41bada650d39b7c32a31c273bbd889cca22d390164b8a7dd9b1f9c1f35` |
| Corpus manifest | [`docs/style/corpus/vroid-lineage-anime.manifest.json`](../../style/corpus/vroid-lineage-anime.manifest.json) | `b393eb0c8c49050caab772f8bdd6ad884d6dd027ad310249ae9805a22b1a8cb6` |
| Measurements | `docs/style/corpus/vroid-lineage-anime.measurements.json` | *(fill from `shasum -a 256`)* |
| Witnesses, `native-anime-v1` | `docs/style/corpus/vroid-lineage-anime.witnesses.native-anime-v1.json` | *(fill from `shasum -a 256`)* |

A second style adds a group of its own. Family counts, tolerances and eligibility floors
are per style set, never global.
```

Fill both hashes with `shasum -a 256 <path>` output before committing; do not leave the parenthetical.

- [ ] **Step 3: Amend §3 with the eligibility definition**

After the levels table, add:

```markdown
A body family is **eligible** for a generative command when the template's directly
invertible controls are set exactly to that family's corresponding measured metrics, and
every remaining target metric's residual is within the pack's `tolerance` multiplied by
that metric's rule range width in the style set's profile. On `native-anime-v1` the
direct pairs are `body.heightM` to `asset.height_m` and `body.headCount` to
`proportions.head_count`; another template declares its own. An ineligible family is
reported with a residual per metric and is neither a pass nor a fail, but a pack's
`minEligibleFamilies` floor must still be met or the dimension fails: "every eligible
family passed" is vacuously true at zero eligible families.
```

- [ ] **Step 4: Amend §4 and §6**

In §4's table, change the `corpus` cell for `control set`, `recipe apply`, `build` and
`export vrm` from `required` to `required (reach)`, and for `material shading` from
`required` to `n/a (body-independent, reviewed)`. In §6, change "v1 `corpus-validated`
means the pack's corpus dimension passes on all 18 development families" to name the
count as the `vroid-lineage-anime` figure and state that counts are per style set.

- [ ] **Step 5: Verify no pack pins verification.md, then commit**

```bash
python3 -c "
import json, glob
for p in glob.glob('docs/proposals/vrm-author-cli/acceptance/packs/*.json'):
    hs = json.load(open(p))['runner']['environment']['oracleHashes']
    assert not any(k.endswith('verification.md') for k in hs), p
print('no pack pins verification.md')"
git add docs/proposals/vrm-author-cli/verification.md
git commit -m "docs: contract edits for the swift-test corpus path and style sets"
```

---

### Task 10: Full verification sweep

**Files:** none modified.

**Interfaces:**
- Consumes: everything above.
- Produces: the evidence that the change is complete.

- [ ] **Step 1: Build and run every Swift test**

```bash
swift build
swift test --filter VRMAuthorKitTests --disable-sandbox 2>&1 | grep -E "xctest' (passed|failed)|Executed [0-9]+ tests"
```
Expected: the suite passes with at least the 300 tests it had before, plus the tests added in Tasks 7 and 8.

- [ ] **Step 2: Run both harness suites**

```bash
python3 scripts/test_acceptance_run.py
python3 scripts/test_corpus_witness.py
```
Expected: both report OK.

- [ ] **Step 3: Run every pack and compare against the pre-change baseline**

```bash
for p in docs/proposals/vrm-author-cli/acceptance/packs/*.json; do
  python3 scripts/acceptance_run.py "$p" 2>&1 | head -1
done | awk '{print $NF}' | sort | uniq -c
```
Baseline before this work: 28 PASS, 7 PENDING, 0 FAIL. Expected after: no FAIL, and the
five corpus packs no longer pending *on the corpus dimension*; `build`, `control-set`,
`export-vrm` and `recipe-apply` stay PENDING overall only because `visual` is still
pending, which is out of scope. `material-shading` should move to PASS.

- [ ] **Step 4: Confirm the multi-style claim concretely**

```bash
python3 -c "
import json
d = json.load(open('docs/proposals/vrm-author-cli/acceptance/packs/build.json'))
e = d['corpus'][0]
print('corpus is an array of', len(d['corpus']), 'style set(s)')
print('styleId', e['styleId'], 'families', e['expectedFamilies'], 'floor', e['minEligibleFamilies'])
print('adding a second style needs only another entry with its own profile, manifest, measurements and witnesses')"
```

- [ ] **Step 5: Report**

State the eligible-family count from Task 4, the pack tally from Step 3, and whether the
spec's deferred approach A is worth revisiting given the reach actually achieved.

## Self-Review

**Spec coverage.** §1 problem is addressed by Tasks 5 and 6; §2's claim by Tasks 1, 3 and 6; §3 style sets by Tasks 2, 5 and 9; §4.1 targets by Task 1; §4.2 witnesses by Tasks 3 and 4; §5 pack schema by Task 2; §6 runner by Task 5; §7 eligibility by Tasks 3 and 9; §8 per-pack assertions by Task 6; §9 material shading by Task 7; §10 Swift de-hardcoding by Task 8; §11 contract edits by Task 9; §12 sequencing is honoured by deferring approach A and reporting reach in Task 4; §13 testing by Tasks 1, 2, 3, 5, 6 and 10.

**Known gap, deliberate.** The spec's §13 asks for "a synthetic second style set in the harness fixtures". Task 2 covers the schema and validation for multiple entries and Task 5 loops over them, but no test drives two style sets through a real replay, because that needs a second profile and corpus that do not exist. `test_duplicate_style_ids_are_rejected` and the array loop are the coverage available without inventing a second aesthetic.

**Type consistency.** `family_targets`, `metric_value` and `TARGET_METRICS` are defined in Task 1 and used unchanged in Tasks 3, 5 and 6. `corpus_status` is defined in Task 5 Step 3 and called in Task 5 Step 5. `run_lint_with` is introduced in Task 5 and used in Task 6. `rule_widths` exists in both `corpus_witness.py` (Task 3) and as `Runner.profile_rule_widths` (Task 5); they are deliberately separate because the generator runs standalone and the runner runs inside a pack, and both are covered by their own tests.
