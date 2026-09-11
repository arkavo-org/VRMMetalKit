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
                   "body.proportion.hipWidth", "face.eye.left.spacing", "face.eye.right.spacing",
                   "face.head.width", "face.chin.length"]


def run_checked(cmd, cwd):
    """Run a subprocess and raise a diagnosable error naming the command and its stderr on failure."""
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"command failed ({proc.returncode}): {' '.join(cmd)}\n{proc.stderr}")
    return proc


def write_document(path, document):
    """Write the witnesses document, overwriting any earlier partial write at the same path."""
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(document, indent=2, sort_keys=True, ensure_ascii=True) + "\n")


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


def cli_evaluator(binary, template, seed, linter, workdir, metrics):
    """Build an avatar at the given controls and return its measured metric vector."""

    def evaluate(controls):
        project = os.path.join(workdir, "a.vrmauthor")
        out = os.path.join(workdir, "draft.vrm")
        shutil.rmtree(project, ignore_errors=True)
        if os.path.exists(out):
            os.remove(out)
        run_checked([binary, "project", "init", "--dir", project, "--template", template,
                    "--seed", str(seed)], REPO)
        request = os.path.join(workdir, "edit.json")
        with open(request, "w", encoding="utf-8") as fh:
            json.dump({"edit": {"object": "avatar:main", "values": controls}}, fh)
        run_checked([binary, "control", "set", "--project", project, "--request", request], REPO)
        run_checked([binary, "build", "--project", project, "--out", out], REPO)
        proc = run_checked([sys.executable, linter, "measure", out, "--json"], REPO)
        record = json.loads(proc.stdout)[0]
        return {m: metric_value(record, m) for m in metrics if metric_value(record, m) is not None}

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
    out_path = os.path.join(REPO, args.out)
    document = {
        "corpusManifestSha256": sha256_file(os.path.join(REPO, args.manifest)),
        "templateId": args.template,
        "templateSha256": template_sha,
        "profileId": profile["id"],
        "solver": {"budget": args.budget, "seed": args.seed, "tolerance": args.tolerance},
        "generated": {"styleLintSha256": sha256_file(os.path.join(REPO, args.linter)),
                      "measurementsSha256": sha256_file(os.path.join(REPO, args.measurements))},
        "families": {},
    }
    with tempfile.TemporaryDirectory(prefix="corpus_witness_") as workdir:
        evaluate = cli_evaluator(binary, args.template, args.seed, os.path.join(REPO, args.linter),
                                 workdir, list(widths))
        for family in sorted(targets):
            witness = solve(family, targets[family], evaluate, widths,
                            args.tolerance, args.budget, args.seed)
            document["families"][family] = {k: witness[k] for k in ("eligible", "controls", "residuals")}
            write_document(out_path, document)
            print(f"{family}: {'eligible' if witness['eligible'] else 'INELIGIBLE'}", file=sys.stderr)

    families = document["families"]
    eligible_count = sum(1 for f in families.values() if f["eligible"])
    print(f"{eligible_count}/{len(families)} families eligible -> {args.out}", file=sys.stderr)
    return 0


def template_hash(binary, template_id):
    proc = run_checked([binary, "template", "list"], REPO)
    packs = json.loads(proc.stdout)["result"]["packs"]
    for pack in packs:
        if pack["id"] == template_id:
            return pack["sha256"]
    raise SystemExit(f"template {template_id!r} is not installed")


if __name__ == "__main__":
    raise SystemExit(main())
