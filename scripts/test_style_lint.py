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
"""Regression tests for scripts/style_lint.py.

    python3 -m unittest scripts/test_style_lint.py

Synthetic cases run everywhere. Mutation cases open a repo-root fixture
(AvatarSample_U_1.0.vrm.glb, gitignored) and are skipped when it is absent.
"""
import copy
import json
import os
import struct
import sys
import unittest

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import style_lint as L  # noqa: E402
from style_lint import load_json  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROFILE = os.path.join(REPO, "docs", "style", "profiles", "vroid-lineage-anime.json")
FIXTURE = os.path.join(REPO, "AvatarSample_U_1.0.vrm.glb")


def pack_glb(js, bin_):
    jb = json.dumps(js).encode()
    jb += b" " * (-len(jb) % 4)
    bin_ += b"\0" * (-len(bin_) % 4)
    body = struct.pack("<II", len(jb), L.JSON_CHUNK) + jb + struct.pack("<II", len(bin_), L.BIN_CHUNK) + bin_
    return struct.pack("<III", 0x46546C67, 2, 12 + len(body)) + body


class AccessorTests(unittest.TestCase):
    def test_interleaved_accessor_with_offset_at_buffer_end(self):
        # two VEC3 floats interleaved with a VEC3 of padding: stride 24, accessor offset 12, 48-byte buffer
        buf = struct.pack("<12f", 9, 9, 9, 1, 2, 3, 9, 9, 9, 4, 5, 6)
        js = {"accessors": [{"bufferView": 0, "byteOffset": 12, "componentType": 5126, "count": 2, "type": "VEC3"}],
              "bufferViews": [{"buffer": 0, "byteLength": 48, "byteStride": 24}]}
        arr = L.accessor_array(js, buf, 0)
        np.testing.assert_array_equal(arr, [[1, 2, 3], [4, 5, 6]])

    def test_tightly_packed_accessor(self):
        buf = struct.pack("<6f", 1, 2, 3, 4, 5, 6)
        js = {"accessors": [{"bufferView": 0, "componentType": 5126, "count": 2, "type": "VEC3"}],
              "bufferViews": [{"buffer": 0, "byteLength": 24}]}
        np.testing.assert_array_equal(L.accessor_array(js, buf, 0), [[1, 2, 3], [4, 5, 6]])


class SparseAccessorTests(unittest.TestCase):
    def _js(self, with_base):
        acc = {"componentType": 5126, "count": 2, "type": "VEC3",
               "sparse": {"count": 1, "indices": {"bufferView": 1, "componentType": 5123}, "values": {"bufferView": 2}}}
        if with_base:
            acc["bufferView"] = 0
        js = {"accessors": [acc], "bufferViews": [{"buffer": 0, "byteLength": 24}, {"buffer": 0, "byteOffset": 24, "byteLength": 2},
                                                  {"buffer": 0, "byteOffset": 28, "byteLength": 12}]}
        buf = struct.pack("<6f", 1, 2, 3, 4, 5, 6) + struct.pack("<H", 1) + b"\0\0" + struct.pack("<3f", 7, 8, 9)
        return js, buf

    def test_sparse_replacement_applied(self):
        js, buf = self._js(True)
        np.testing.assert_array_equal(L.accessor_array(js, buf, 0), [[1, 2, 3], [7, 8, 9]])

    def test_sparse_without_base_view_is_zero_initialised(self):
        js, buf = self._js(False)
        np.testing.assert_array_equal(L.accessor_array(js, buf, 0), [[0, 0, 0], [7, 8, 9]])


def minimal_vrm(bones, children_cycle=False):
    """A spec-minimal VRM 1.0 GLB: one triangle, the given humanoid bones, no materials."""
    names = list(bones)
    nodes = [{"name": n, "translation": [0.0, 0.1 * i, 0.0]} for i, n in enumerate(names)]
    nodes.append({"name": "mesh", "mesh": 0})
    if children_cycle:
        nodes[0]["children"] = [1]
        nodes[1]["children"] = [0]
    buf = struct.pack("<9f", 0, 0, 0, 1, 0, 0, 0, 1.6, 0) + struct.pack("<3H", 0, 1, 2) + b"\0\0"
    js = {"asset": {"version": "2.0"}, "nodes": nodes, "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1}]}],
          "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"},
                        {"bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"}],
          "bufferViews": [{"buffer": 0, "byteLength": 36}, {"buffer": 0, "byteOffset": 36, "byteLength": 6}],
          "buffers": [{"byteLength": len(buf)}], "materials": [],
          "extensions": {"VRMC_vrm": {"specVersion": "1.0", "humanoid": {"humanBones": {n: {"node": i} for i, n in enumerate(names)}},
                                      "meta": {"name": "min", "authors": ["t"], "licenseUrl": "https://vrm.dev/licenses/1.0/"},
                                      "expressions": {"preset": {}}, "lookAt": {"type": "bone"}}}}
    return js, buf


class RobustnessTests(unittest.TestCase):
    REQUIRED = ["hips", "spine", "head", "leftUpperArm", "rightUpperArm", "leftUpperLeg", "rightUpperLeg"]

    def setUp(self):
        import tempfile
        self.tmp = tempfile.NamedTemporaryFile(suffix=".vrm", delete=False).name

    def measure(self, js, buf):
        with open(self.tmp, "wb") as fh:
            fh.write(pack_glb(js, buf))
        return L.measure(self.tmp)

    def test_optional_bones_missing_yields_none_not_crash(self):
        M = self.measure(*minimal_vrm(self.REQUIRED))
        P = M["proportions"]
        self.assertIsNotNone(P["hips_height_ratio"])
        for k in ("lower_arm_m", "lower_upper_arm_ratio", "arm_span_height_ratio", "rest_pose_arm_horizontal_cos", "limb_asymmetry", "eye_height_ratio"):
            self.assertIsNone(P[k], k)
        with open(PROFILE) as fh:
            rep = L.evaluate(M, json.load(fh))
        self.assertEqual(rep["verdict"], "nonconforming")

    def test_required_bone_missing_is_a_clear_error(self):
        with self.assertRaises(ValueError):
            self.measure(*minimal_vrm(["hips", "spine"]))

    def test_node_cycle_terminates(self):
        self.measure(*minimal_vrm(self.REQUIRED, children_cycle=True))

    def test_jpeg_zero_length_segment_terminates(self):
        data = b"\xff\xd8\xff\xe0\x00\x00" + b"\x00" * 16
        self.assertIsNone(L.image_size(data))


class CorpusTests(unittest.TestCase):
    def test_missing_asset_fails_unless_allowed(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            man = os.path.join(d, "m.json")
            with open(man, "w") as fh:
                json.dump({"assets": [{"path": "nope.vrm"}]}, fh)
            with self.assertRaises(FileNotFoundError):
                L.measure_corpus(man, {})
            out = L.measure_corpus(man, {}, allow_missing=True)
            self.assertEqual((out["measured"], out["expected"], out["missing"]), (0, 1, ["nope.vrm"]))

    def test_median_is_statistical_median(self):
        self.assertEqual(L.summarize_values([1, 2, 3, 10])["median"], 2.5)

    def test_effective_n_counts_contributing_families_only(self):
        ms = [{"asset": {"file": "a", "vrm_version": "1.0", "body_family": "A"}, "materials": []},
              {"asset": {"file": "b", "vrm_version": "0.x", "body_family": "B"}, "materials": []}]
        rule = {"id": "x.y", "class": "interop", "severity": "must", "vrm_versions": ["1.0"], "metric": "asset.file",
                "check": {"type": "present"}, "provenance": {}}
        rep = L.envelopes({"rules": [rule], "corpus": {}}, {"measurements": ms})
        self.assertEqual(rep["rules"]["x.y"]["effective_n"], 1)


class MaterialMetricTests(unittest.TestCase):
    def test_black_base_colour_does_not_crash(self):
        p = dict(L.MTOON_DEFAULTS, baseColorFactor=[0, 0, 0, 1], shadeColorFactor=[0, 0, 0], emissiveFactor=[0, 0, 0])
        d = L.derive_material_metrics(p)
        self.assertIsInstance(d["shade_warmth"], float)
        self.assertIsInstance(d["shade_luminance_ratio"], float)

    def test_vrm0_colours_are_gamma_decoded(self):
        mp = {"shader": "VRM/MToon", "vectorProperties": {"_OutlineColor": [0.2745098, 0.0901960656, 0.125490159, 1]},
              "floatProperties": {}, "textureProperties": {}}
        p = L.mtoon_from_vrm0(mp)
        # AvatarSample_A: VRoid's own 1.0 export of the same material stores (0.0612, 0.0086, 0.0144)
        self.assertAlmostEqual(p["outlineColorFactor"][0], 0.0612, places=3)
        self.assertAlmostEqual(p["outlineColorFactor"][1], 0.0086, places=3)
        self.assertAlmostEqual(p["outlineColorFactor"][2], 0.0144, places=3)

    def test_vrm0_render_queue_and_uv_animation_survive_migration(self):
        mats = [{"shader": "VRM/MToon", "keywordMap": {"_ALPHABLEND_ON": True}, "renderQueue": 3000, "floatProperties": {"_BlendMode": 2, "_UvAnimScrollY": 0.5}, "vectorProperties": {}, "textureProperties": {}},
                {"shader": "VRM/MToon", "keywordMap": {"_ALPHABLEND_ON": True}, "renderQueue": 2999, "floatProperties": {"_BlendMode": 2}, "vectorProperties": {}, "textureProperties": {}}]
        qm = L.vrm0_render_queue_map(mats)
        p0 = L.mtoon_from_vrm0(mats[0], qm)
        p1 = L.mtoon_from_vrm0(mats[1], qm)
        self.assertEqual((p1["renderQueueOffsetNumber"], p0["renderQueueOffsetNumber"]), (-1, 0))
        self.assertTrue(p0["uvAnimated"])
        self.assertAlmostEqual(p0["giEqualizationFactor"], 0.9)

    def test_shadow_end_matches_mtoon_linearstep(self):
        d = L.derive_material_metrics(dict(L.MTOON_DEFAULTS, baseColorFactor=[1, 1, 1, 1], emissiveFactor=[0, 0, 0],
                                           shadingToonyFactor=0.91, shadingShiftFactor=0.71))
        self.assertAlmostEqual(d["shadow_end"], -0.8)
        self.assertAlmostEqual(d["lit_start"], -0.62)


class EvaluatorTests(unittest.TestCase):
    def setUp(self):
        self.profile = load_json(PROFILE)

    def measurement(self, roles=("body_skin",)):
        mats = [dict(index=i, name=f"m{i}", role=r, mtoon=True, vertices=1, outlineWidthMode="none", shadow_end=0.0, alphaMode="BLEND")
                for i, r in enumerate(roles)]
        return {"asset": {"file": "x", "vrm_version": "1.0"}, "materials": mats, "meta": {}, "expressions": {"presets": []}, "lookat": {}, "springs": {}, "proportions": {}}

    def test_profile_role_groups_override_builtin(self):
        profile = {"id": "t", "version": "0.0.1", "title": "t",
                   "material_roles": {"roles": ["custom"], "groups": {"mine": ["custom"]}},
                   "rules": [{"id": "x.y", "class": "aesthetic", "severity": "must", "scope": "material", "roles": ["mine"],
                              "metric": "shadow_end", "check": {"type": "range", "max": -0.6}, "provenance": {}}]}
        rep = L.evaluate(self.measurement(roles=("custom",)), profile)
        self.assertEqual(rep["results"][0]["status"], "fail")
        self.assertEqual(rep["verdict"], "nonconforming")

    def test_unknown_role_override_is_rejected(self):
        with self.assertRaises(ValueError):
            L.validate_roles({"foo": "not_a_role"}, self.profile)

    def test_meta_defaults_apply(self):
        js = {"asset": {"version": "2.0"}, "nodes": [{"name": "root"}], "materials": [], "meshes": [], "skins": [], "images": [],
              "extensions": {"VRMC_vrm": {"humanoid": {"humanBones": {}}, "meta": {"name": "n", "authors": ["a"], "licenseUrl": "https://vrm.dev/licenses/1.0/"}}}}
        meta = dict(L.VRM1_META_DEFAULTS)
        meta.update(js["extensions"]["VRMC_vrm"]["meta"])
        for rule in self.profile["rules"]:
            if rule["id"].startswith("meta.") and rule["severity"] == "must" and rule.get("vrm_versions") == ["1.0"]:
                ok, why = L.check_value(rule["check"], meta.get(rule["metric"].split(".", 1)[1]))
                self.assertTrue(ok, f"{rule['id']}: {why}")


FIXTURE_A1 = os.path.join(REPO, "AvatarSample_A_1.0.vrm.glb")
FIXTURE_A0 = os.path.join(REPO, "AvatarSample_A_0.0.vrm.glb")


@unittest.skipUnless(os.path.exists(FIXTURE_A1) and os.path.exists(FIXTURE_A0), "AvatarSample_A fixtures not present")
class CrossVersionTests(unittest.TestCase):
    """AvatarSample_A 0.0 and 1.0 are one body; measurements must agree across VRM generations."""

    @classmethod
    def setUpClass(cls):
        cls.m0, cls.m1 = L.measure(FIXTURE_A0), L.measure(FIXTURE_A1)

    def test_head_metrics_agree_across_forward_axis(self):
        for k in ("head_count", "eye_height_in_head", "head_bone_fraction"):
            self.assertAlmostEqual(self.m0["proportions"][k], self.m1["proportions"][k], delta=0.02, msg=k)

    def test_outline_colour_agrees_after_srgb_decode(self):
        o0 = [m for m in self.m0["materials"] if m["role"] == "face_skin"][0]["outline_luminance"]
        o1 = [m for m in self.m1["materials"] if m["role"] == "face_skin"][0]["outline_luminance"]
        self.assertAlmostEqual(o0, o1, places=3)

    def test_vertex_counts_distinguish_storage_from_references(self):
        self.assertEqual(self.m1["asset"]["vertices"], 20459)
        self.assertEqual(self.m1["asset"]["vertex_references"], 94016)


class SchemaContractTests(unittest.TestCase):
    def setUp(self):
        try:
            import jsonschema  # noqa: F401
        except ImportError:
            self.skipTest("jsonschema not installed")
        self.schema = load_json(os.path.join(REPO, "docs", "style", "vrm-anime-style-profile.schema.json"))
        self.profile = load_json(PROFILE)

    def test_profile_validates(self):
        import jsonschema
        jsonschema.Draft202012Validator(self.schema).validate(self.profile)

    def test_fingerprint_rule_cannot_be_must(self):
        import jsonschema
        p = copy.deepcopy(self.profile)
        fp = next(r for r in p["rules"] if r["class"] == "fingerprint")
        fp["severity"] = "must"
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.Draft202012Validator(self.schema).validate(p)

    def test_rule_without_provenance_is_rejected(self):
        import jsonschema
        p = copy.deepcopy(self.profile)
        p["rules"][0].pop("provenance")
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.Draft202012Validator(self.schema).validate(p)


@unittest.skipUnless(os.path.exists(FIXTURE), "AvatarSample_U_1.0.vrm.glb not present")
class MutationTests(unittest.TestCase):
    """Controlled edits to a conforming fixture must trip exactly the rules that describe them."""

    @classmethod
    def setUpClass(cls):
        cls.js, cls.bin = L.load_glb(FIXTURE)
        cls.profile = load_json(PROFILE)
        cls.tmp = os.path.join(os.environ.get("TMPDIR", "/tmp"), "style_lint_mutation.glb")

    def lint(self, js):
        with open(self.tmp, "wb") as fh:
            fh.write(pack_glb(js, self.bin))
        rep = L.evaluate(L.measure(self.tmp), self.profile)
        return rep, {r["id"]: r["status"] for r in rep["results"]}

    def mutate_mtoon(self, predicate, **changes):
        js = copy.deepcopy(self.js)
        for m in js["materials"]:
            if predicate(m["name"]):
                m["extensions"]["VRMC_materials_mtoon"].update(changes)
        return js

    def test_baseline_conforms(self):
        rep, st = self.lint(self.js)
        self.assertNotEqual(rep["verdict"], "nonconforming")
        self.assertEqual(st["shade.face_never_deep_shadowed"], "pass")

    def test_toon_face_trips_face_rule_only(self):
        rep, st = self.lint(self.mutate_mtoon(lambda n: "Face_00_SKIN" in n, shadingShiftFactor=-0.05, shadingToonyFactor=0.95))
        self.assertEqual(st["shade.face_never_deep_shadowed"], "fail")
        self.assertEqual(st["shade.body_two_tone"], "pass")

    def test_removing_outlines_trips_outline_rule(self):
        rep, st = self.lint(self.mutate_mtoon(lambda n: "SKIN" in n or "CLOTH" in n, outlineWidthMode="none"))
        self.assertEqual(st["outline.surface_present"], "fail")
        self.assertEqual(st["shade.face_never_deep_shadowed"], "pass")

    def test_lambert_body_trips_two_tone_rule(self):
        rep, st = self.lint(self.mutate_mtoon(lambda n: "Body_00_SKIN" in n or "CLOTH" in n, shadingToonyFactor=0.2))
        self.assertEqual(st["shade.body_two_tone"], "fail")

    def test_dropping_optional_meta_keeps_must_rules_green(self):
        js = copy.deepcopy(self.js)
        for k in ("avatarPermission", "commercialUsage", "modification", "creditNotation", "allowRedistribution"):
            js["extensions"]["VRMC_vrm"]["meta"].pop(k, None)
        rep, st = self.lint(js)
        self.assertEqual(rep["summary"]["must"]["fail"], 0)

    def test_vrm0_materials_matched_by_index(self):
        js = copy.deepcopy(self.js)
        # a name-less glTF material must still find its VRM 0.x properties by position
        props = [{"shader": "VRM/MToon", "floatProperties": {}, "vectorProperties": {}, "textureProperties": {}, "name": "x"}
                 for _ in js["materials"]]
        js["extensions"] = {"VRM": {"humanoid": {"humanBones": [{"bone": k, "node": v["node"]} for k, v in self.js["extensions"]["VRMC_vrm"]["humanoid"]["humanBones"].items()]},
                                    "meta": {}, "materialProperties": props, "blendShapeMaster": {"blendShapeGroups": []}, "firstPerson": {}, "secondaryAnimation": {}}}
        for m in js["materials"]:
            m.pop("name", None)
        with open(self.tmp, "wb") as fh:
            fh.write(pack_glb(js, self.bin))
        M = L.measure(self.tmp)
        self.assertEqual(M["asset"]["non_mtoon_materials"], 0)

    def test_dropping_blink_trips_core_presets(self):
        js = copy.deepcopy(self.js)
        js["extensions"]["VRMC_vrm"]["expressions"]["preset"].pop("blink")
        rep, st = self.lint(js)
        self.assertEqual(st["expr.core_presets"], "fail")


if __name__ == "__main__":
    unittest.main()
