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
"""VRM style-profile linter.

Measures a VRM (0.x or 1.0) and evaluates it against a machine-readable
style profile (see docs/style/vrm-anime-style-profile.schema.json).

    style_lint.py describe                          # operation catalog (JSON)
    style_lint.py measure  [--json] A.vrm ...       # metrics only
    style_lint.py lint --profile P.json [--json] [--roles R.json] A.vrm ...

Exit status for `lint`: 0 if no `must` rule failed on any asset, 1 otherwise.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import statistics
import struct
import sys

import numpy as np

# --------------------------------------------------------------------------- glTF

JSON_CHUNK = 0x4E4F534A
BIN_CHUNK = 0x004E4942


def load_glb(path):
    b = open(path, "rb").read()
    magic, _ver, length = struct.unpack_from("<III", b, 0)
    if magic != 0x46546C67:
        raise ValueError(f"{path}: not a GLB container")
    off, js, bin_ = 12, None, None
    while off < length:
        clen, ctype = struct.unpack_from("<II", b, off)
        off += 8
        data = b[off:off + clen]
        off += clen
        if ctype == JSON_CHUNK:
            js = json.loads(data)
        elif ctype == BIN_CHUNK:
            bin_ = data
    return js, bin_


def quat_to_mat(q):
    x, y, z, w = q
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ])


def local_mat(n):
    if "matrix" in n:
        return np.array(n["matrix"]).reshape(4, 4).T
    t = np.array(n.get("translation", [0, 0, 0]), dtype=float)
    r = quat_to_mat(n.get("rotation", [0, 0, 0, 1]))
    s = np.array(n.get("scale", [1, 1, 1]), dtype=float)
    m = np.eye(4)
    m[:3, :3] = r * s
    m[:3, 3] = t
    return m


def world_mats(js):
    nodes = js["nodes"]
    parent = {}
    for i, n in enumerate(nodes):
        for c in n.get("children", []):
            parent[c] = i
    cache = {}

    def w(i):
        if i in cache:
            return cache[i]
        m = local_mat(nodes[i])
        if i in parent:
            m = w(parent[i]) @ m
        cache[i] = m
        return m

    for i in range(len(nodes)):
        w(i)
    return cache, parent


COMPONENT_FORMAT = {5120: "b", 5121: "B", 5122: "h", 5123: "H", 5125: "I", 5126: "f"}
TYPE_COMPONENTS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def _read_view(js, bin_, view_index, byte_offset, count, comp, ncomp):
    bv = js["bufferViews"][view_index]
    off = bv.get("byteOffset", 0) + byte_offset
    stride = bv.get("byteStride", 0)
    itemsize = struct.calcsize(comp) * ncomp
    if stride and stride != itemsize:
        raw = np.frombuffer(bin_, dtype=np.uint8, count=stride * (count - 1) + itemsize, offset=off)
        rows = np.lib.stride_tricks.as_strided(raw, shape=(count, itemsize), strides=(stride, 1))
        return rows.copy().view(np.dtype("<" + comp)).reshape(count, ncomp)
    return np.frombuffer(bin_, dtype=np.dtype("<" + comp), count=count * ncomp, offset=off).reshape(count, ncomp).copy()


def accessor_array(js, bin_, ai):
    """Decode an accessor, including sparse accessors and accessors without a bufferView (all zeros)."""
    a = js["accessors"][ai]
    comp = COMPONENT_FORMAT[a["componentType"]]
    ncomp = TYPE_COMPONENTS[a["type"]]
    if "bufferView" in a:
        arr = _read_view(js, bin_, a["bufferView"], a.get("byteOffset", 0), a["count"], comp, ncomp)
    else:
        arr = np.zeros((a["count"], ncomp), dtype=np.dtype("<" + comp))
    sp = a.get("sparse")
    if sp:
        idx = _read_view(js, bin_, sp["indices"]["bufferView"], sp["indices"].get("byteOffset", 0), sp["count"],
                         COMPONENT_FORMAT[sp["indices"]["componentType"]], 1)[:, 0].astype(np.int64)
        vals = _read_view(js, bin_, sp["values"]["bufferView"], sp["values"].get("byteOffset", 0), sp["count"], comp, ncomp)
        arr[idx] = vals
    return arr


def image_size(data):
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        w, h = struct.unpack_from(">II", data, 16)
        return int(w), int(h)
    i = 2
    while i + 4 < len(data):
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker in (0xC0, 0xC1, 0xC2):
            h, w = struct.unpack_from(">HH", data, i + 5)
            return int(w), int(h)
        i += 2 + struct.unpack_from(">H", data, i + 2)[0]
    return None


def descendants(nodes, root):
    out, stack = set(), [root]
    while stack:
        n = stack.pop()
        out.add(n)
        stack.extend(nodes[n].get("children", []))
    return out


def lum(c):
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


# --------------------------------------------------------------------------- roles

# Default material-role heuristic. VRoid Studio's naming tags are the de facto
# convention; the plain English words cover most hand-authored assets. Override
# with --roles {"<material name>": "<role>"}.
ROLE_PATTERNS = [
    (r"eyeiris|_iris|\biris", "iris"),
    (r"eyehighlight|highlight", "eye_highlight"),
    (r"eyewhite|sclera", "eye_white"),
    (r"eyeline|eyelid", "eyeline"),
    (r"eyelash|lash", "eyelash"),
    (r"brow", "brow"),
    (r"facemouth|mouth|teeth|tongue", "mouth"),
    (r"face|head", "face_skin"),
    (r"hair", "hair"),
    (r"body|skin", "body_skin"),
    (r"accessory|glasses|catear|tail|ribbon|earring|hat\b|badge", "accessory"),
    (r"cloth|tops|bottoms|shoes|onepiece|dress|skirt|shirt|jacket|sock|boot", "cloth"),
    (r"\beye", "iris"),
]

ROLE_GROUPS = {
    "face_region": ["face_skin", "iris", "eye_white", "eye_highlight", "eyeline", "eyelash", "brow", "mouth"],
    "facial_feature": ["iris", "eye_white", "eye_highlight", "eyeline", "eyelash", "brow", "mouth"],
    "surface": ["face_skin", "body_skin", "cloth", "accessory"],
    "skin": ["face_skin", "body_skin"],
    "lit_cutout": ["body_skin", "cloth", "hair", "accessory"],
}


def assign_role(name, overrides):
    if name in overrides:
        return overrides[name]
    if "*" in overrides:
        return overrides["*"]
    n = (name or "").lower()
    for pat, role in ROLE_PATTERNS:
        if re.search(pat, n):
            return role
    return "other"


# --------------------------------------------------------------------------- MToon

MTOON_DEFAULTS = dict(
    shadeColorFactor=[1, 1, 1], shadingToonyFactor=0.9, shadingShiftFactor=0.0, giEqualizationFactor=0.9,
    parametricRimColorFactor=[0, 0, 0], parametricRimFresnelPowerFactor=5.0, parametricRimLiftFactor=0.0,
    rimLightingMixFactor=1.0, matcapFactor=[1, 1, 1], outlineWidthMode="none", outlineWidthFactor=0.0,
    outlineColorFactor=[0, 0, 0], outlineLightingMixFactor=1.0, renderQueueOffsetNumber=0, transparentWithZWrite=False,
)


def mtoon_from_vrm1(m):
    mt = m.get("extensions", {}).get("VRMC_materials_mtoon")
    if mt is None:
        return None
    pbr = m.get("pbrMetallicRoughness", {})
    p = dict(MTOON_DEFAULTS)
    p.update({k: v for k, v in mt.items() if k in MTOON_DEFAULTS})
    p.update(
        baseColorFactor=pbr.get("baseColorFactor", [1, 1, 1, 1]),
        hasBaseTexture="baseColorTexture" in pbr,
        hasShadeTexture="shadeMultiplyTexture" in mt,
        hasShadingShiftTexture="shadingShiftTexture" in mt,
        hasMatcapTexture="matcapTexture" in mt,
        hasRimTexture="rimMultiplyTexture" in mt,
        emissiveFactor=m.get("emissiveFactor", [0, 0, 0]),
        alphaMode=m.get("alphaMode", "OPAQUE"),
        alphaCutoff=m.get("alphaCutoff", 0.5) if m.get("alphaMode") == "MASK" else None,
        doubleSided=bool(m.get("doubleSided", False)),
        uvAnimated=any(mt.get(k, 0) != 0 for k in ("uvAnimationScrollXSpeedFactor", "uvAnimationScrollYSpeedFactor", "uvAnimationRotationSpeedFactor")),
    )
    return p


def gamma_eotf(c):
    """VRM 0.x colour factors are sRGB-encoded; MToon 1.0 factors are linear.

    Uses the exact sRGB EOTF, which is what UniVRM's migration (Unity Color.linear) and VRoid
    Studio's own 1.0 exporter apply, and what VRMMToonMaterial.toMToonMaterial() uses.
    three-vrm approximates it with pow 2.2 (about 5% darker in the low range)."""
    return [float(x) / 12.92 if x <= 0.04045 else ((float(x) + 0.055) / 1.055) ** 2.4 for x in c]


def vrm0_is_transparent(mp):
    f = mp.get("floatProperties", {})
    shader = mp.get("shader")
    zwrite = shader == "VRM/UnlitTransparentZWrite" or f.get("_ZWrite") == 1
    transparent = "_ALPHABLEND_ON" in mp.get("keywordMap", {}) or shader in ("VRM/UnlitTransparent", "VRM/UnlitTransparentZWrite")
    return transparent, zwrite


def vrm0_render_queue_map(material_properties):
    """three-vrm's _populateRenderQueueMap: every transparent render queue in use, in order, maps to offsets −9…0."""
    queues = {False: set(), True: set()}
    for mp in material_properties:
        transparent, zwrite = vrm0_is_transparent(mp)
        if transparent and mp.get("renderQueue") is not None:
            queues[zwrite].add(mp["renderQueue"])
    out = {}
    for zwrite, qs in queues.items():
        qs = sorted(qs)
        for i, q in enumerate(qs):
            out[(zwrite, q)] = min(max(i - len(qs) + 1, -9), 0)
    return out


def mtoon_from_vrm0(mp, queue_map=None):
    """VRM 0.x materialProperties -> MToon 1.0 parameter space.

    Follows three-vrm's VRMMaterialsV0CompatPlugin (the migration used by pixiv and UniVRM):
    colour factors are sRGB-decoded to linear, toony/shift are remapped, _IndirectLightIntensity becomes
    1 − giEqualization, transparent render queues map to offsets, UV scroll Y flips sign.
    VRMMToonMaterial.toMToonMaterial() in Sources/VRMMetalKit/Core/VRMTypes.swift uses the same
    toony/shift formulas."""
    if mp.get("shader") != "VRM/MToon":
        return None
    f, v, t = mp.get("floatProperties", {}), mp.get("vectorProperties", {}), mp.get("textureProperties", {})
    shade_toony = f.get("_ShadeToony", 0.9)
    shade_shift = f.get("_ShadeShift", 0.0)
    lerp = 0.5 + 0.5 * shade_shift
    toony = shade_toony * (1 - lerp) + lerp
    shift = -shade_shift - (1 - toony)
    blend = int(f.get("_BlendMode", 0))
    alpha = {0: "OPAQUE", 1: "MASK", 2: "BLEND", 3: "BLEND"}.get(blend, "OPAQUE")
    mode = {0: "none", 1: "worldCoordinates", 2: "screenCoordinates"}.get(int(f.get("_OutlineWidthMode", 0)), "none")
    outline_mix = f.get("_OutlineLightingMix", 1.0) if int(f.get("_OutlineColorMode", 0)) == 1 else 0.0
    base = v.get("_Color", [1, 1, 1, 1])
    gi = f.get("_IndirectLightIntensity", 0.1)
    transparent, zwrite = vrm0_is_transparent(mp)
    rq = 0
    if transparent and mp.get("renderQueue") is not None and queue_map is not None:
        rq = queue_map.get((zwrite, mp["renderQueue"]), 0)
    scroll_x, scroll_y, rot = f.get("_UvAnimScrollX", 0.0), -f.get("_UvAnimScrollY", 0.0), f.get("_UvAnimRotation", 0.0)
    return dict(
        MTOON_DEFAULTS,
        baseColorFactor=gamma_eotf(base[:3]) + [base[3] if len(base) > 3 else 1.0], hasBaseTexture="_MainTex" in t,
        shadeColorFactor=gamma_eotf(v.get("_ShadeColor", [0.97, 0.81, 0.86, 1])[:3]), hasShadeTexture="_ShadeTexture" in t,
        shadingToonyFactor=toony, shadingShiftFactor=shift, hasShadingShiftTexture=False,
        giEqualizationFactor=(1.0 - gi) if gi else MTOON_DEFAULTS["giEqualizationFactor"],
        parametricRimColorFactor=gamma_eotf(v.get("_RimColor", [0, 0, 0, 1])[:3]), parametricRimFresnelPowerFactor=f.get("_RimFresnelPower", 1.0),
        parametricRimLiftFactor=f.get("_RimLift", 0.0), rimLightingMixFactor=f.get("_RimLightingMix", 0.0), hasRimTexture="_RimTexture" in t,
        hasMatcapTexture="_SphereAdd" in t,
        outlineWidthMode=mode, outlineWidthFactor=f.get("_OutlineWidth", 0.0) * 0.01,
        outlineColorFactor=gamma_eotf(v.get("_OutlineColor", [0, 0, 0, 1])[:3]), outlineLightingMixFactor=outline_mix,
        renderQueueOffsetNumber=rq, transparentWithZWrite=blend == 3 or (transparent and zwrite),
        emissiveFactor=gamma_eotf(v.get("_EmissionColor", [0, 0, 0, 1])[:3]),
        alphaMode=alpha, alphaCutoff=f.get("_Cutoff", 0.5) if alpha == "MASK" else None,
        doubleSided=int(f.get("_CullMode", 2)) == 0, uvAnimated=any(x != 0 for x in (scroll_x, scroll_y, rot)),
    )


def derive_material_metrics(p):
    """Derived, render-meaningful quantities in MToon 1.0 space.

    MToon 1.0 shading = linearstep(-1 + toony, 1 - toony, NdotL + shift):
      shadow_end  = NdotL below which the surface is fully in shade colour
      lit_start   = NdotL above which the surface is fully lit
      terminator_width = lit_start - shadow_end = 2 * (1 - toony)
    """
    toony, shift = p["shadingToonyFactor"], p["shadingShiftFactor"]
    base, shade = p["baseColorFactor"][:3], p["shadeColorFactor"][:3]
    base_l, shade_l = max(lum(base), 1e-6), lum(shade)
    rim, ol = p["parametricRimColorFactor"], p["outlineColorFactor"]
    return dict(
        shadow_end=round(-1 + toony - shift, 4),
        lit_start=round(1 - toony - shift, 4),
        terminator_width=round(2 * (1 - toony), 4),
        shade_luminance_ratio=round(shade_l / base_l, 4),
        shade_warmth=round((shade[0] / max(shade[1], 1e-6)) / max(base[0] / max(base[1], 1e-6), 1e-6), 4),
        rim_luminance=round(lum(rim), 4),
        outline_luminance=round(lum(ol), 4),
        outline_warm=bool(ol[0] >= ol[2]),
        emissive_luminance=round(lum(p["emissiveFactor"]), 4),
        outline_width_m=round(p["outlineWidthFactor"], 6) if p["outlineWidthMode"] == "worldCoordinates" else None,
    )


# --------------------------------------------------------------------------- measure

# VRMC_vrm.meta.schema.json defaults; name, authors and licenseUrl are required and have none.
VRM1_META_DEFAULTS = dict(avatarPermission="onlyAuthor", allowExcessivelyViolentUsage=False, allowExcessivelySexualUsage=False,
                          commercialUsage="personalNonProfit", allowPoliticalOrReligiousUsage=False, allowAntisocialOrHateUsage=False,
                          creditNotation="required", allowRedistribution=False, modification="prohibited")

VRM1_PRESETS = ["aa", "ih", "ou", "ee", "oh", "blink", "blinkLeft", "blinkRight", "happy", "angry", "sad", "relaxed",
                "surprised", "neutral", "lookUp", "lookDown", "lookLeft", "lookRight"]
VRM0_PRESET_MAP = {"a": "aa", "i": "ih", "u": "ou", "e": "ee", "o": "oh", "blink": "blink", "blink_l": "blinkLeft",
                   "blink_r": "blinkRight", "joy": "happy", "angry": "angry", "sorrow": "sad", "fun": "relaxed",
                   "neutral": "neutral", "lookup": "lookUp", "lookdown": "lookDown", "lookleft": "lookLeft", "lookright": "lookRight"}


def measure(path, role_overrides=None):
    role_overrides = role_overrides or {}
    js, bin_ = load_glb(path)
    ext = js.get("extensions", {})
    nodes = js["nodes"]
    W, parent = world_mats(js)
    M = {"asset": {"file": os.path.basename(path), "file_mb": round(os.path.getsize(path) / 1e6, 2)}}
    A = M["asset"]

    # ---- humanoid / meta / expressions / lookAt / springs (version-specific)
    if "VRMC_vrm" in ext:
        v = ext["VRMC_vrm"]
        A["vrm_version"] = "1.0"
        bones = {k: b["node"] for k, b in v["humanoid"]["humanBones"].items()}
        meta = dict(VRM1_META_DEFAULTS)
        meta.update(v.get("meta", {}))
        M["meta"] = {k: meta.get(k) for k in ("name", "version", "authors", "licenseUrl", "avatarPermission", "allowExcessivelyViolentUsage",
                                            "allowExcessivelySexualUsage", "commercialUsage", "allowPoliticalOrReligiousUsage",
                                            "allowAntisocialOrHateUsage", "creditNotation", "allowRedistribution", "modification")}
        M["meta"]["thumbnail_present"] = "thumbnailImage" in meta
        ex = v.get("expressions", {})
        M["expressions"] = {"presets": sorted(ex.get("preset", {}).keys()), "custom_count": len(ex.get("custom", {}))}
        la = v.get("lookAt", {})
        M["lookat"] = {"type": la.get("type"), "offset_from_head_bone": la.get("offsetFromHeadBone"),
                       "output_scales": [la.get(k, {}).get("outputScale") for k in ("rangeMapHorizontalInner", "rangeMapHorizontalOuter", "rangeMapVerticalDown", "rangeMapVerticalUp")]}
        sb = ext.get("VRMC_springBone", {})
        springs = [{"name": s.get("name", ""), "joints": [j["node"] for j in s["joints"]],
                    "stiffness": [j.get("stiffness", 1.0) for j in s["joints"]], "drag": [j.get("dragForce", 0.5) for j in s["joints"]],
                    "gravity": [j.get("gravityPower", 0.0) for j in s["joints"]], "hit_radius": [j.get("hitRadius", 0.0) for j in s["joints"]]}
                   for s in sb.get("springs", [])]
        colliders = [{"node": c["node"], "shape": next(iter(c["shape"])), "radius": next(iter(c["shape"].values())).get("radius", 0.0)} for c in sb.get("colliders", [])]
        collider_groups = len(sb.get("colliderGroups", []))
        mats = []
        for m in js.get("materials", []):
            p = mtoon_from_vrm1(m)
            mats.append((m.get("name", ""), p))
    elif "VRM" in ext:
        v = ext["VRM"]
        A["vrm_version"] = "0.x"
        bones = {b["bone"]: b["node"] for b in v["humanoid"]["humanBones"]}
        meta = v.get("meta", {})
        M["meta"] = {k: meta.get(k) for k in ("title", "version", "author", "licenseName", "allowedUserName", "violentUssageName",
                                            "sexualUssageName", "commercialUssageName", "otherPermissionUrl", "otherLicenseUrl")}
        M["meta"]["thumbnail_present"] = "texture" in meta
        groups = v.get("blendShapeMaster", {}).get("blendShapeGroups", [])
        M["expressions"] = {"presets": sorted({VRM0_PRESET_MAP[g["presetName"].lower()] for g in groups if g.get("presetName", "unknown").lower() in VRM0_PRESET_MAP}),
                            "custom_count": sum(1 for g in groups if g.get("presetName", "unknown").lower() not in VRM0_PRESET_MAP)}
        fp = v.get("firstPerson", {})
        M["lookat"] = {"type": "bone" if fp.get("lookAtTypeName", "Bone") == "Bone" else "expression",
                       "offset_from_head_bone": [fp.get("firstPersonBoneOffset", {}).get(k, 0) for k in "xyz"],
                       "output_scales": [fp.get(k, {}).get("yRange") for k in ("lookAtHorizontalInner", "lookAtHorizontalOuter", "lookAtVerticalDown", "lookAtVerticalUp")]}
        sa = v.get("secondaryAnimation", {})
        springs = []
        for bg in sa.get("boneGroups", []):
            for root in bg.get("bones", []):
                chain, n = [], root
                while True:
                    chain.append(n)
                    ch = nodes[n].get("children", [])
                    if not ch:
                        break
                    n = ch[0]
                springs.append({"name": bg.get("comment", ""), "joints": chain, "stiffness": [bg.get("stiffiness", bg.get("stiffness", 1.0))] * len(chain),
                                "drag": [bg.get("dragForce", 0.4)] * len(chain), "gravity": [bg.get("gravityPower", 0.0)] * len(chain), "hit_radius": [bg.get("hitRadius", 0.02)] * len(chain)})
        colliders = [{"node": cg["node"], "shape": "sphere", "radius": c["radius"]} for cg in sa.get("colliderGroups", []) for c in cg.get("colliders", [])]
        collider_groups = len(sa.get("colliderGroups", []))
        # VRM 0.x materialProperties[i] describes glTF materials[i] (UniVRM writes and reads them by index).
        props = v.get("materialProperties", [])
        queue_map = vrm0_render_queue_map(props)
        mats = []
        for i, m in enumerate(js.get("materials", [])):
            mp = props[i] if i < len(props) else None
            mats.append((m.get("name", ""), mtoon_from_vrm0(mp, queue_map) if mp else None))
    else:
        raise ValueError(f"{path}: no VRM extension (VRMC_vrm or VRM) present")

    # ---- geometry
    pos = {k: W[n][:3, 3] for k, n in bones.items()}
    head_set = {bones[k] for k in ("head", "leftEye", "rightEye", "jaw") if k in bones}
    head_pos = pos["head"]
    tri = vert_refs = 0
    position_accessors = set()
    allmin, allmax = np.full(3, np.inf), np.full(3, -np.inf)
    head_pts, skinned_meshes, max_morphs = [], 0, 0
    mat_vertex_counts = {}
    for ni, n in enumerate(nodes):
        if "mesh" not in n:
            continue
        mesh = js["meshes"][n["mesh"]]
        skinned = "skin" in n
        skinned_meshes += int(skinned)
        joints = js["skins"][n["skin"]]["joints"] if skinned else None
        Mw = np.eye(4) if skinned else W[ni]
        for prim in mesh["primitives"]:
            P = accessor_array(js, bin_, prim["attributes"]["POSITION"]).astype(np.float64)
            Pw = (Mw[:3, :3] @ P.T).T + Mw[:3, 3]
            vert_refs += len(P)
            position_accessors.add(prim["attributes"]["POSITION"])
            tri += js["accessors"][prim["indices"]]["count"] // 3 if "indices" in prim else len(P) // 3
            max_morphs = max(max_morphs, len(prim.get("targets", [])))
            allmin, allmax = np.minimum(allmin, Pw.min(0)), np.maximum(allmax, Pw.max(0))
            mid = prim.get("material")
            mat_vertex_counts[mid] = mat_vertex_counts.get(mid, 0) + len(P)
            if skinned and "JOINTS_0" in prim["attributes"]:
                J = accessor_array(js, bin_, prim["attributes"]["JOINTS_0"]).astype(np.int64)
                Wt = accessor_array(js, bin_, prim["attributes"]["WEIGHTS_0"]).astype(np.float64)
                dom = np.asarray(joints)[J[np.arange(len(J)), Wt.argmax(1)]]
                head_pts.append(Pw[np.isin(dom, list(head_set))])
    H = float(allmax[1] - min(allmin[1], 0.0))
    verts = sum(js["accessors"][i]["count"] for i in position_accessors)
    A.update(triangles=int(tri), vertices=int(verts), vertex_references=int(vert_refs), skinned_meshes=skinned_meshes, morph_targets_max=int(max_morphs),
             material_slots=len(js.get("materials", [])), node_count=len(nodes), humanoid_bone_count=len(bones),
             joint_count_max=max((len(s["joints"]) for s in js.get("skins", [])), default=0),
             height_m=round(H, 4), bbox_min=[round(float(x), 4) for x in allmin], bbox_max=[round(float(x), 4) for x in allmax])

    # ---- proportions (humanoid bones; spec-mandated)
    def dist(a, b):
        return float(np.linalg.norm(pos[a] - pos[b]))

    P_ = {}
    P_["eye_height_ratio"] = round(float((pos["leftEye"][1] + pos["rightEye"][1]) / 2 / H), 4) if "leftEye" in pos and "rightEye" in pos else None
    P_["ipd_m"] = round(dist("leftEye", "rightEye"), 4) if "leftEye" in pos and "rightEye" in pos else None
    P_["hips_height_ratio"] = round(float(pos["hips"][1] / H), 4)
    P_["head_bone_height_ratio"] = round(float(head_pos[1] / H), 4)
    P_["upper_leg_height_ratio"] = round(float(pos["leftUpperLeg"][1] / H), 4)
    P_["shoulder_width_ratio"] = round(dist("leftUpperArm", "rightUpperArm") / H, 4)
    P_["upper_arm_m"] = round(dist("leftUpperArm", "leftLowerArm"), 4)
    P_["lower_arm_m"] = round(dist("leftLowerArm", "leftHand"), 4)
    P_["upper_leg_m"] = round(dist("leftUpperLeg", "leftLowerLeg"), 4)
    P_["lower_leg_m"] = round(dist("leftLowerLeg", "leftFoot"), 4)
    P_["lower_upper_arm_ratio"] = round(P_["lower_arm_m"] / P_["upper_arm_m"], 4)
    P_["lower_upper_leg_ratio"] = round(P_["lower_leg_m"] / P_["upper_leg_m"], 4)
    P_["arm_span_height_ratio"] = round(dist("leftHand", "rightHand") / H, 4)
    arm = pos["leftHand"] - pos["leftUpperArm"]
    P_["rest_pose_arm_horizontal_cos"] = round(abs(float(arm[0])) / max(float(np.linalg.norm(arm)), 1e-9), 4)
    sym = [(dist("leftUpperArm", "leftHand"), dist("rightUpperArm", "rightHand")), (dist("leftUpperLeg", "leftFoot"), dist("rightUpperLeg", "rightFoot"))]
    P_["limb_asymmetry"] = round(max(abs(a - b) / max(a, b) for a, b in sym), 4)

    # head height: vertices dominated by head-region joints, centre column (|x - head.x| < 15 mm);
    # chin = lowest such vertex in front of the head bone, crown = highest. Includes crown hair.
    hp = np.concatenate(head_pts) if head_pts else np.zeros((0, 3))
    # VRM 1.0 models face +Z; VRM 0.x models face −Z in glTF space (specification/0.0/README.md).
    forward = 1.0 if A["vrm_version"] == "1.0" else -1.0
    col = hp[np.abs(hp[:, 0] - head_pos[0]) < 0.015] if len(hp) else hp
    front = col[(col[:, 2] - head_pos[2]) * forward > 0] if len(col) else col
    if len(front) and len(col):
        chin, crown = float(front[:, 1].min()), float(col[:, 1].max())
        head_h = crown - chin
        eye_y = (pos["leftEye"][1] + pos["rightEye"][1]) / 2 if P_["eye_height_ratio"] is not None else None
        band = hp[np.abs(hp[:, 1] - eye_y) < 0.01] if eye_y is not None else hp[:0]
        head_w = float(band[:, 0].max() - band[:, 0].min()) if len(band) else None
        P_.update(head_height_m=round(head_h, 4), head_count=round(H / head_h, 3),
                  head_bone_fraction=round(float(head_pos[1] - chin) / head_h, 4),
                  eye_height_in_head=round(float(eye_y - chin) / head_h, 4) if eye_y is not None else None,
                  head_width_m=round(head_w, 4) if head_w else None,
                  ipd_head_width_ratio=round(P_["ipd_m"] / head_w, 4) if (head_w and P_["ipd_m"]) else None,
                  head_width_height_ratio=round(head_w / head_h, 4) if head_w else None)
    else:
        P_.update(head_height_m=None, head_count=None, head_bone_fraction=None, eye_height_in_head=None, head_width_m=None,
                  ipd_head_width_ratio=None, head_width_height_ratio=None)
    M["proportions"] = P_

    # ---- textures
    imgs = []
    for im in js.get("images", []):
        if "bufferView" in im:
            bv = js["bufferViews"][im["bufferView"]]
            data = bin_[bv.get("byteOffset", 0):bv.get("byteOffset", 0) + bv["byteLength"]]
            imgs.append({"size": image_size(data), "bytes": bv["byteLength"], "mime": im.get("mimeType")})
    sized = [i for i in imgs if i["size"]]
    A.update(texture_count=len(imgs), texture_max_dim=max((max(i["size"]) for i in sized), default=0),
             texture_encoded_mb=round(sum(i["bytes"] for i in imgs) / 1e6, 2),
             texture_decoded_mb=round(sum(i["size"][0] * i["size"][1] * 4 for i in sized) / 1e6, 1),
             texture_non_pow2=sum(1 for i in sized if any(d & (d - 1) for d in i["size"])))

    # ---- springs / colliders
    head_desc = descendants(nodes, bones["head"])
    hair_chains = [s for s in springs if s["joints"] and s["joints"][0] in head_desc]
    allj = lambda k: [x for s in springs for x in s[k]]
    S = {"chains": len(springs), "joints": sum(len(s["joints"]) for s in springs), "hair_chains": len(hair_chains),
         "hair_joints_per_chain": sorted(len(s["joints"]) for s in hair_chains),
         "joints_per_chain_max": max((len(s["joints"]) for s in springs), default=0),
         "stiffness_min": min(allj("stiffness"), default=None), "stiffness_max": max(allj("stiffness"), default=None),
         "drag_min": min(allj("drag"), default=None), "drag_max": max(allj("drag"), default=None),
         "gravity_power_max": max(allj("gravity"), default=None), "hit_radius_max": max(allj("hit_radius"), default=None),
         "colliders": len(colliders), "collider_groups": collider_groups,
         "collider_shapes": sorted({c["shape"] for c in colliders}),
         "head_colliders": sum(1 for c in colliders if c["node"] in head_desc),
         "collider_radius_min": min((c["radius"] for c in colliders), default=None),
         "collider_radius_max": max((c["radius"] for c in colliders), default=None)}
    M["springs"] = S
    A["generator"] = js.get("asset", {}).get("generator")
    off = M["lookat"].get("offset_from_head_bone") or [0, 0, 0]
    M["lookat"]["offset_y"] = off[1] if len(off) > 1 else None

    # ---- materials
    out = []
    for i, (name, p) in enumerate(mats):
        role = assign_role(name, role_overrides)
        entry = {"index": i, "name": name, "role": role, "mtoon": p is not None, "vertices": mat_vertex_counts.get(i, 0)}
        if p is not None:
            entry.update({k: p[k] for k in p})
            entry.update(derive_material_metrics(p))
        out.append(entry)
    M["materials"] = out
    A["unclassified_materials"] = sum(1 for m in out if m["role"] == "other")
    A["non_mtoon_materials"] = sum(1 for m in out if not m["mtoon"])
    return M


# --------------------------------------------------------------------------- evaluate

def get_path(obj, dotted):
    cur = obj
    for part in dotted.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return None
    return cur


def check_value(check, value):
    """Return (ok, reason). value None => metric unavailable => fail."""
    if value is None:
        return False, "metric unavailable"
    t = check["type"]
    if t == "range":
        lo, hi = check.get("min"), check.get("max")
        if isinstance(value, list):
            return all(check_value(check, x)[0] for x in value), None
        if lo is not None and value < lo:
            return False, f"{value} < {lo}"
        if hi is not None and value > hi:
            return False, f"{value} > {hi}"
        return True, None
    if t == "equals":
        return value == check["value"], f"{value!r} != {check['value']!r}"
    if t == "enum":
        return value in check["values"], f"{value!r} not in {check['values']}"
    if t == "superset_of":
        missing = [x for x in check["values"] if x not in value]
        return not missing, f"missing {missing}"
    if t == "subset_of":
        extra = [x for x in value if x not in check["values"]]
        return not extra, f"unexpected {extra}"
    if t == "present":
        return value not in (None, "", []), "absent"
    raise ValueError(f"unknown check type {t}")


def profile_role_groups(profile):
    groups = dict(ROLE_GROUPS)
    groups.update(profile.get("material_roles", {}).get("groups", {}))
    return groups


def validate_roles(overrides, profile):
    known = set(profile.get("material_roles", {}).get("roles", [])) or {r for _, r in ROLE_PATTERNS} | {"other"}
    bad = {k: v for k, v in overrides.items() if v not in known}
    if bad:
        raise ValueError(f"--roles assigns roles outside the profile vocabulary {sorted(known)}: {bad}")


def evaluate(M, profile):
    groups = profile_role_groups(profile)
    results = []
    for rule in profile["rules"]:
        scope = rule.get("scope", "asset")
        r = {"id": rule["id"], "severity": rule["severity"], "class": rule["class"], "title": rule.get("title", ""),
             "metric": rule["metric"], "check": rule["check"], "status": "pass", "subjects": []}
        if rule.get("vrm_versions") and M["asset"]["vrm_version"] not in rule["vrm_versions"]:
            r["status"] = "skip"
            r["reason"] = f"rule applies to VRM {rule['vrm_versions']}"
            results.append(r)
            continue
        if scope == "asset":
            value = get_path(M, rule["metric"])
            ok, why = check_value(rule["check"], value)
            r["observed"] = value
            if not ok:
                r["status"] = "fail"
                r["reason"] = why
        elif scope == "material":
            roles = set()
            for x in rule.get("roles", []):
                roles.update(groups.get(x, [x]))
            flt = rule.get("filter", {})
            subjects = [m for m in M["materials"] if (not roles or m["role"] in roles) and (m["mtoon"] or not rule.get("mtoon_only", True))
                        and all(m.get(k) == v for k, v in flt.items())]
            if not subjects:
                r["status"] = "skip"
                r["reason"] = "no materials in scope"
            failed = []
            for m in subjects:
                value = m.get(rule["metric"])
                ok, why = check_value(rule["check"], value)
                if not ok:
                    failed.append({"material": m["name"], "role": m["role"], "observed": value, "reason": why})
            if failed:
                r["status"] = "fail"
                r["subjects"] = failed
            r["n_subjects"] = len(subjects)
        else:
            raise ValueError(f"unknown scope {scope}")
        results.append(r)
    by = {s: {"pass": 0, "fail": 0, "skip": 0} for s in ("must", "should", "may", "info")}
    for r in results:
        by[r["severity"]][r["status"]] += 1
    verdict = "nonconforming" if by["must"]["fail"] else ("conforming-with-warnings" if by["should"]["fail"] else "conforming")
    return {"asset": M["asset"]["file"], "profile": profile["id"], "profile_version": profile["version"], "verdict": verdict,
            "summary": by, "results": results}


# --------------------------------------------------------------------------- corpus / envelopes

def sha256_file(path):
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def measure_corpus(manifest_path, role_overrides, allow_missing=False):
    """Measure every asset in a manifest {root?, assets:[{path, body_family?, note?}]} and return
    the measurements with content hashes, so envelopes can be regenerated and audited.
    A missing asset is an error unless allow_missing is set, so a partial checkout cannot
    silently replace the reference corpus."""
    man = json.load(open(manifest_path))
    root = os.path.join(os.path.dirname(os.path.abspath(manifest_path)), man.get("root", "."))
    missing = [e["path"] for e in man["assets"] if not os.path.exists(os.path.normpath(os.path.join(root, e["path"])))]
    if missing and not allow_missing:
        raise FileNotFoundError(f"corpus: {len(missing)} of {len(man['assets'])} manifest assets missing "
                                f"(pass --allow-missing to measure a partial corpus): {missing}")
    out = []
    for entry in man["assets"]:
        path = os.path.normpath(os.path.join(root, entry["path"]))
        if not os.path.exists(path):
            print(f"corpus: missing {entry['path']}", file=sys.stderr)
            continue
        M = measure(path, role_overrides)
        M["asset"].update(path=entry["path"], sha256=sha256_file(path), body_family=entry.get("body_family"),
                          note=entry.get("note"))
        out.append(M)
    return {"manifest": os.path.basename(manifest_path), "measured": len(out), "expected": len(man["assets"]),
            "missing": missing, "measurements": out}


def rule_observations(rule, measurements, groups):
    """Collect (body_family, value) pairs a rule sees across a set of measurements."""
    obs = []
    for M in measurements:
        if rule.get("vrm_versions") and M["asset"]["vrm_version"] not in rule["vrm_versions"]:
            continue
        fam = M["asset"].get("body_family") or M["asset"]["file"]
        if rule.get("scope", "asset") == "asset":
            obs.append((fam, get_path(M, rule["metric"])))
        else:
            roles = set()
            for x in rule.get("roles", []):
                roles.update(groups.get(x, [x]))
            flt = rule.get("filter", {})
            obs.extend((fam, m.get(rule["metric"])) for m in M["materials"]
                       if (not roles or m["role"] in roles) and (m["mtoon"] or not rule.get("mtoon_only", True))
                       and all(m.get(k) == v for k, v in flt.items()))
    return obs


def summarize_values(vals):
    present = [v for v in vals if v is not None]
    summ = {"n": len(vals), "n_unavailable": len(vals) - len(present)}
    nums = [v for v in present if isinstance(v, (int, float)) and not isinstance(v, bool)]
    if nums and len(nums) == len(present):
        summ.update(min=min(nums), median=statistics.median(nums), max=max(nums))
    else:
        counts = {}
        for v in present:
            counts[json.dumps(v, sort_keys=True)] = counts.get(json.dumps(v, sort_keys=True), 0) + 1
        summ["observed"] = counts
    return summ


def envelopes(profile, corpus, write_path=None):
    """Recompute each rule's provenance statistics from a corpus measurement file. With write_path,
    rewrite the profile's provenance n/min/median/max/observed in place (notes and source are kept)."""
    ms = corpus["measurements"]
    groups = profile_role_groups(profile)
    families = {M["asset"].get("body_family") or M["asset"]["file"] for M in ms}
    report = {"corpus": corpus.get("manifest"), "n_assets": len(ms), "effective_n": len(families), "rules": {}}
    for rule in profile["rules"]:
        obs = rule_observations(rule, ms, groups)
        summ = summarize_values([v for _, v in obs])
        summ["conforming"] = sum(1 for _, v in obs if check_value(rule["check"], v)[0])
        summ["effective_n"] = len({fam for fam, v in obs if v is not None})
        report["rules"][rule["id"]] = summ
        if write_path:
            prov = rule.setdefault("provenance", {})
            for k in ("n", "min", "median", "max", "observed"):
                prov.pop(k, None)
            prov["n"] = summ["n"]
            prov["effective_n"] = summ["effective_n"]
            for k in ("min", "median", "max", "observed"):
                if k in summ:
                    prov[k] = round(summ[k], 4) if isinstance(summ[k], float) else summ[k]
            prov["conforming"] = f"{summ['conforming']}/{summ['n']}"
    if write_path:
        profile.setdefault("corpus", {})
        profile["corpus"].update(n=len(ms), effective_n=len(families), manifest=corpus.get("manifest"),
                                 assets=[M["asset"]["path"] for M in ms],
                                 sha256={M["asset"]["file"]: M["asset"]["sha256"] for M in ms})
        json.dump(profile, open(write_path, "w"), indent=2, ensure_ascii=False)
        open(write_path, "a").write("\n")
    return report


# --------------------------------------------------------------------------- CLI

def describe():
    return {
        "tool": "style_lint", "version": "0.1.0",
        "operations": {
            "measure": {"input": {"assets": ["path"], "roles": "path?"}, "output": {"measurements": ["Measurement"]}},
            "lint": {"input": {"profile": "path", "assets": ["path"], "roles": "path?"}, "output": {"reports": ["Report"]},
                     "exit_status": {"0": "no must-rule failed", "1": "at least one must-rule failed"}},
            "corpus": {"input": {"manifest": "path", "out": "path", "roles": "path?", "allow_missing": "bool"}, "output": {"measurements_file": "path"},
                       "errors": {"FileNotFoundError": "a manifest asset is missing and allow_missing is not set"}},
            "envelopes": {"input": {"profile": "path", "measurements": "path", "write": "bool"}, "output": {"rules": {"<id>": "summary"}}},
        },
        "role_groups": ROLE_GROUPS,
        "role_heuristic": [{"pattern": p, "role": r} for p, r in ROLE_PATTERNS],
        "report_verdicts": ["conforming", "conforming-with-warnings", "nonconforming"],
    }


def print_report(rep):
    print(f"{rep['asset']}: {rep['verdict']}  (profile {rep['profile']} v{rep['profile_version']})")
    for r in rep["results"]:
        if r["status"] == "pass":
            continue
        if r["severity"] == "info":
            if r["status"] == "fail":
                print(f"  [info] {r['id']}: not matched ({r.get('title','')})")
            continue
        tag = {"fail": "FAIL", "skip": "skip"}[r["status"]]
        line = f"  [{tag}] {r['severity']:6s} {r['id']}: {r.get('title','')}"
        if r.get("reason"):
            line += f" — {r['reason']}"
        if "observed" in r and r["status"] == "fail":
            line += f" (observed {r['observed']})"
        print(line)
        for s in r.get("subjects", [])[:6]:
            print(f"         {s['material']} [{s['role']}]: {s['reason']} (observed {s['observed']})")
        if len(r.get("subjects", [])) > 6:
            print(f"         … {len(r['subjects']) - 6} more")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("describe")
    for name in ("measure", "lint"):
        p = sub.add_parser(name)
        p.add_argument("assets", nargs="+")
        p.add_argument("--json", action="store_true")
        p.add_argument("--roles", help="JSON file mapping material name -> role ('*' sets a default)")
        if name == "lint":
            p.add_argument("--profile", required=True)
    p = sub.add_parser("corpus", help="measure a manifest of assets into a measurements file")
    p.add_argument("manifest")
    p.add_argument("--out", required=True)
    p.add_argument("--roles")
    p.add_argument("--allow-missing", action="store_true", help="measure whatever exists instead of failing on a missing asset")
    p = sub.add_parser("envelopes", help="recompute per-rule provenance from a measurements file")
    p.add_argument("--profile", required=True)
    p.add_argument("--measurements", required=True)
    p.add_argument("--write", action="store_true", help="rewrite the profile's provenance statistics in place")
    args = ap.parse_args(argv)
    if args.cmd == "describe":
        print(json.dumps(describe(), indent=2))
        return 0
    if args.cmd == "envelopes":
        profile = json.load(open(args.profile))
        rep = envelopes(profile, json.load(open(args.measurements)), args.profile if args.write else None)
        print(json.dumps(rep, indent=1))
        return 0
    overrides = json.load(open(args.roles)) if args.roles else {}
    if args.cmd == "corpus":
        corpus = measure_corpus(args.manifest, overrides, args.allow_missing)
        json.dump(corpus, open(args.out, "w"), indent=1)
        if corpus["missing"]:
            print(f"corpus: partial ({corpus['measured']}/{corpus['expected']} assets)", file=sys.stderr)
        return 0
    if args.cmd == "measure":
        ms = [measure(a, overrides) for a in args.assets]
        if args.json:
            print(json.dumps(ms, indent=1))
        else:
            for m in ms:
                print(json.dumps({"asset": m["asset"], "proportions": m["proportions"], "springs": m["springs"]}, indent=1))
        return 0
    profile = json.load(open(args.profile))
    validate_roles(overrides, profile)
    reports = [evaluate(measure(a, overrides), profile) for a in args.assets]
    if args.json:
        print(json.dumps(reports, indent=1))
    else:
        for rep in reports:
            print_report(rep)
    return 1 if any(rep["summary"]["must"]["fail"] for rep in reports) else 0


if __name__ == "__main__":
    sys.exit(main())
