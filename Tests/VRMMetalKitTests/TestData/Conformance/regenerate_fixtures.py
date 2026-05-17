#!/usr/bin/env python3
"""
Regenerate the bundled vrm-conformance fixtures used by the in-repo tests.

Most fixtures here are direct CC0 outputs of `vrm-asset-generator` from
https://github.com/arkavo-org/vrm-conformance. A few are *synthesised*
(injected base+extension shapes etc.) — those need an explicit script,
which lives here so future maintainers can re-derive them deterministically.

Usage:
    # 1. Build vrm-conformance locally:
    git clone https://github.com/arkavo-org/vrm-conformance
    cd vrm-conformance
    cargo build --release -p vrm-asset-generator

    # 2. Emit upstream sweeps:
    ./target/release/vrm-asset-generator emit-sweep --output-dir /tmp/mtoon
    ./target/release/vrm-asset-generator emit-springbone-swing-sweep --output-dir /tmp/spring
    ./target/release/vrm-asset-generator emit-springbone-collider-sweep --output-dir /tmp/collider
    ./target/release/vrm-asset-generator emit-springbone-extended-sweep --output-dir /tmp/extended
    ./target/release/vrm-asset-generator emit-springbone --id smoke_spring --output-dir /tmp/baseline

    # 3. From this directory, run the script to copy the subset we bundle
    # and synthesise the base+extension fixtures:
    python3 regenerate_fixtures.py /tmp

The script is idempotent: re-running overwrites the bundled .vrm files
with the same bytes (assuming vrm-asset-generator's output is stable).
"""

import json
import struct
import sys
from pathlib import Path


# Mapping from upstream source dir → list of fixture stems to copy verbatim.
DIRECT_COPIES = {
    "mtoon": [
        "mtoon_default",
        "mtoon_rimLightingMix_0",
        "mtoon_rimLightingMix_0p5",
        "mtoon_rimLightingMix_1",
        "mtoon_shadingShift_1",
        "mtoon_shadingShift_neg1",
        "mtoon_shadingToony_0",
        "mtoon_shadingToony_1",
    ],
    "spring": [
        "swing_springbone_stiffness_0",
        "swing_springbone_stiffness_0p2",
        "swing_springbone_stiffness_0p8",
        "swing_springbone_stiffness_1",
    ],
    "collider": [
        "springbone_collider_sphere_x0p02_r0p05",
        "springbone_collider_sphere_x0p02_r0p1",
        "springbone_collider_capsule_x0p02_r0p05",
        "springbone_collider_capsule_x0p02_r0p1",
    ],
    "extended": [
        "springbone_extended_plane_pmed",
        "springbone_extended_isphere_pmed",
        "springbone_extended_icaps_pmed",
        "springbone_extended_isphere_anglelimit_60",
    ],
    "baseline": [
        "smoke_spring",
    ],
}


def synthesize_base_plus_extension(src_dir: Path, dst_dir: Path) -> None:
    """
    Generate `springbone_extended_plane_with_base_sphere.vrm` from the
    plane-only fixture by injecting an inert base sphere (the spec's
    `radius: 0` filler at `[0, -10000, 0]`). Locks in the precedence test:
    a spec-aware loader picks the extension's plane; a legacy loader picks
    the inert sphere far away from the model.
    """
    src = src_dir / "extended" / "springbone_extended_plane_pmed.vrm"
    dst = dst_dir / "springbone_extended_plane_with_base_sphere.vrm"
    with open(src, "rb") as f:
        data = f.read()

    chunk0_len = struct.unpack("<I", data[12:16])[0]
    json_bytes = data[20 : 20 + chunk0_len]
    rest = data[20 + chunk0_len :]

    doc = json.loads(json_bytes)
    coll = doc["extensions"]["VRMC_springBone"]["colliders"][0]
    coll["shape"] = {
        "sphere": {"offset": [0.0, -10000.0, 0.0], "radius": 0.0}
    }

    new_json = json.dumps(doc).encode("utf-8")
    pad = (4 - len(new_json) % 4) % 4
    new_json += b" " * pad

    new_chunk0_len = len(new_json)
    new_total = 12 + 8 + new_chunk0_len + len(rest)

    out = bytearray()
    out += b"glTF"
    out += struct.pack("<I", 2)
    out += struct.pack("<I", new_total)
    out += struct.pack("<I", new_chunk0_len)
    out += b"JSON"
    out += new_json
    out += rest

    with open(dst, "wb") as f:
        f.write(out)
    print(f"  synthesised {dst.name}")


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: regenerate_fixtures.py <generator-output-root>", file=sys.stderr)
        print("Example: python3 regenerate_fixtures.py /tmp", file=sys.stderr)
        return 1

    src_root = Path(sys.argv[1]).resolve()
    dst_dir = Path(__file__).parent.resolve()

    for subdir, stems in DIRECT_COPIES.items():
        src_subdir = src_root / subdir
        if not src_subdir.is_dir():
            # Allow flat layout fallback: source has the same name at root.
            src_subdir = src_root
        for stem in stems:
            src = src_subdir / f"{stem}.vrm"
            if not src.is_file():
                # Try a `conformance-`-prefixed dir per the docstring's convention.
                alt = src_root / f"conformance-{subdir}" / f"{stem}.vrm"
                if alt.is_file():
                    src = alt
                else:
                    print(f"  SKIP {stem} (not found under {src_root})")
                    continue
            (dst_dir / f"{stem}.vrm").write_bytes(src.read_bytes())
            print(f"  copied  {stem}")

    print("Synthesising base+extension fixtures:")
    synthesize_base_plus_extension(src_root, dst_dir)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
