#!/usr/bin/env python3
#
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
#
"""Derive the skinned swatch and floor fixtures from finish_swatches.vrm.

finish_swatches_skinned.vrm carries the same three spheres, materials and
camera-facing layout as finish_swatches.vrm, but each sphere is skinned to a
single joint (identity inverse bind matrix, weight 1). The skinned and rigid
fixtures therefore describe identical geometry, which lets the tests compare
the skinned and rigid shader paths pixel-for-pixel.

floor_plane.vrm is an 8 m square, outline-free ground quad at y = -0.5 (the
bottom of the swatch spheres), used to test the contact shadow against a floor
the host draws into the same depth buffer.

Usage:
    python3 scripts/make_mtoon_swatch_variants.py
"""

import json
import struct
from pathlib import Path

FIXTURES = Path(__file__).resolve().parent.parent / "Tests/VRMMetalKitTests/TestData/MToon"
SOURCE = FIXTURES / "finish_swatches.vrm"
TARGET = FIXTURES / "finish_swatches_skinned.vrm"
FLOOR = FIXTURES / "floor_plane.vrm"

GLB_MAGIC = 0x46546C67
CHUNK_JSON = 0x4E4F534A
CHUNK_BIN = 0x004E4942


def read_glb(path):
    data = path.read_bytes()
    magic, _, _ = struct.unpack_from("<III", data, 0)
    if magic != GLB_MAGIC:
        raise SystemExit(f"{path} is not a GLB file")
    offset = 12
    document, binary = None, b""
    while offset < len(data):
        length, kind = struct.unpack_from("<II", data, offset)
        chunk = data[offset + 8: offset + 8 + length]
        if kind == CHUNK_JSON:
            document = json.loads(chunk)
        elif kind == CHUNK_BIN:
            binary = bytes(chunk)
        offset += 8 + length
    return document, binary


def write_glb(path, document, binary):
    payload = json.dumps(document, separators=(",", ":")).encode()
    payload += b" " * (-len(payload) % 4)
    binary += b"\0" * (-len(binary) % 4)
    total = 12 + 8 + len(payload) + 8 + len(binary)
    out = struct.pack("<III", GLB_MAGIC, 2, total)
    out += struct.pack("<II", len(payload), CHUNK_JSON) + payload
    out += struct.pack("<II", len(binary), CHUNK_BIN) + binary
    path.write_bytes(out)


def append_view(document, binary, blob):
    binary += b"\0" * (-len(binary) % 4)
    document["bufferViews"].append({
        "buffer": 0,
        "byteOffset": len(binary),
        "byteLength": len(blob),
    })
    return binary + blob, len(document["bufferViews"]) - 1


def make_skinned():
    document, binary = read_glb(SOURCE)
    mesh_nodes = [i for i, node in enumerate(document["nodes"]) if "mesh" in node]
    position_accessor = document["meshes"][0]["primitives"][0]["attributes"]["POSITION"]
    vertex_count = document["accessors"][position_accessor]["count"]

    joints = struct.pack("<4H", 0, 0, 0, 0) * vertex_count
    weights = struct.pack("<4f", 1.0, 0.0, 0.0, 0.0) * vertex_count
    identity = struct.pack("<16f", *[1.0 if r == c else 0.0 for c in range(4) for r in range(4)])

    binary, joints_view = append_view(document, binary, joints)
    binary, weights_view = append_view(document, binary, weights)
    binary, ibm_view = append_view(document, binary, identity)

    accessors = document["accessors"]
    accessors.append({"bufferView": joints_view, "componentType": 5123, "count": vertex_count, "type": "VEC4"})
    joints_accessor = len(accessors) - 1
    accessors.append({"bufferView": weights_view, "componentType": 5126, "count": vertex_count, "type": "VEC4"})
    weights_accessor = len(accessors) - 1
    accessors.append({"bufferView": ibm_view, "componentType": 5126, "count": 1, "type": "MAT4"})
    ibm_accessor = len(accessors) - 1

    for mesh in document["meshes"]:
        for primitive in mesh["primitives"]:
            primitive["attributes"]["JOINTS_0"] = joints_accessor
            primitive["attributes"]["WEIGHTS_0"] = weights_accessor

    document.setdefault("skins", [])
    for node_index in mesh_nodes:
        node = document["nodes"][node_index]
        joint = {"name": node["name"] + "Joint"}
        if "translation" in node:
            joint["translation"] = node.pop("translation")
        document["nodes"].append(joint)
        joint_index = len(document["nodes"]) - 1
        document["scenes"][document.get("scene", 0)]["nodes"].append(joint_index)
        document["skins"].append({"joints": [joint_index], "inverseBindMatrices": ibm_accessor})
        node["skin"] = len(document["skins"]) - 1

    document["buffers"][0]["byteLength"] = len(binary) + (-len(binary) % 4)
    document["asset"]["generator"] = "VRMMetalKit finish fixture (skinned variant)"
    write_glb(TARGET, document, binary)
    print(f"wrote {TARGET.name}")


def make_floor():
    document, _ = read_glb(SOURCE)
    half, y = 4.0, -0.5
    positions = struct.pack("<12f", -half, y, -half, half, y, -half, half, y, half, -half, y, half)
    normals = struct.pack("<3f", 0.0, 1.0, 0.0) * 4
    uvs = struct.pack("<8f", 0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 0.0, 1.0)
    indices = struct.pack("<6H", 0, 2, 1, 0, 3, 2)

    binary = b""
    document["bufferViews"] = []
    views = []
    for blob in (positions, normals, uvs, indices):
        binary, view = append_view(document, binary, blob)
        views.append(view)
    document["accessors"] = [
        {"bufferView": views[0], "componentType": 5126, "count": 4, "type": "VEC3",
         "min": [-half, y, -half], "max": [half, y, half]},
        {"bufferView": views[1], "componentType": 5126, "count": 4, "type": "VEC3"},
        {"bufferView": views[2], "componentType": 5126, "count": 4, "type": "VEC2"},
        {"bufferView": views[3], "componentType": 5123, "count": 6, "type": "SCALAR"},
    ]
    material = document["materials"][0]
    material["name"] = "Floor"
    material["pbrMetallicRoughness"]["baseColorFactor"] = [0.85, 0.85, 0.85, 1.0]
    mtoon = material["extensions"]["VRMC_materials_mtoon"]
    mtoon["shadeColorFactor"] = [0.85, 0.85, 0.85]
    mtoon["outlineWidthMode"] = "none"
    mtoon["outlineWidthFactor"] = 0.0
    document["materials"] = [material]
    document["meshes"] = [{
        "name": "Floor",
        "primitives": [{
            "attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2},
            "indices": 3,
            "material": 0,
        }],
    }]
    mesh_nodes = [i for i, node in enumerate(document["nodes"]) if "mesh" in node]
    for index in mesh_nodes[1:]:
        del document["nodes"][index]["mesh"]
    first = document["nodes"][mesh_nodes[0]]
    first["name"] = "Floor"
    first["mesh"] = 0
    first.pop("translation", None)
    document["buffers"][0]["byteLength"] = len(binary) + (-len(binary) % 4)
    document["asset"]["generator"] = "VRMMetalKit finish fixture (floor)"
    document["extensions"]["VRMC_vrm"]["meta"]["name"] = "MToon Floor Plane"
    write_glb(FLOOR, document, binary)
    print(f"wrote {FLOOR.name}")


def main():
    make_skinned()
    make_floor()


if __name__ == "__main__":
    main()
