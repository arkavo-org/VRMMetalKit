#!/usr/bin/env python3
"""Solve per-family control values for one (corpus, template) pair and write a witnesses file.

Drives the shipped vrm-author CLI: project init, object set (disabling the template's
default garment), control set, build, then style_lint.py measure on the built avatar.
Runs once per pair, off the critical path of any acceptance pack.

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


class InfeasibleCandidate(Exception):
    """The template rejected this specific candidate (ExitCode.gateFailed or .invalidRequest,
    per Sources/VRMAuthorKit/Core/ExitCode.swift and AuthorErrorCode.exitCode) - a domain
    rejection, not an infrastructure failure."""


DEFAULT_GARMENT_ID = "outfit.top"


def disable_default_garment_request():
    """The object set request that takes the template's default garment out of the build."""
    return {"edit": {"id": DEFAULT_GARMENT_ID, "values": {"/enabled": False}}}


def replay_steps(controls):
    """The ordered vrm-author steps that reproduce a solved build, garment disable included in
    position. Paths belong to the replayer; the template id and seed are already on the document."""
    return [{"command": "project init", "request": None},
            {"command": "object set", "request": disable_default_garment_request()},
            {"command": "control set", "request": {"edit": {"object": "avatar:main", "values": controls}}},
            {"command": "build", "request": None}]


def run_checked(cmd, cwd, stdin_text=None):
    """Run a subprocess and raise a diagnosable error naming the command and its stderr on failure."""
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, input=stdin_text)
    if proc.returncode != 0:
        raise RuntimeError(f"command failed ({proc.returncode}): {' '.join(cmd)}\n{proc.stderr}")
    return proc


def run_cli(cmd, cwd):
    """Run a vrm-author subprocess whose failure may describe this candidate rather than the
    process: exit 1 (gate failed) and exit 2 (invalid request) mean the template refused this
    candidate and raise InfeasibleCandidate; any other non-zero exit (3 missing capability, 4
    conflict, 5 internal error) or a failure to launch the binary at all is infrastructure and
    raises RuntimeError with the command and stderr surfaced, exactly like run_checked."""
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if proc.returncode in (1, 2):
        raise InfeasibleCandidate(proc.stderr.strip())
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
    """Set the directly invertible controls exactly, then search the rest deterministically.

    Each search coordinate keeps its own step size: a rejected move shrinks only that
    coordinate's step, and an accepted move resets it to the initial size. A shared step
    would let a bad sign guess on one coordinate collapse the exploration radius for every
    other coordinate too, well before the budget is spent.

    A candidate the template refuses to build (InfeasibleCandidate) is scored as worse than
    any feasible candidate and rejected exactly like any other rejected candidate, consuming
    its iteration and its RNG draw identically either way. If the initial candidate itself -
    direct controls at target, every search control at zero - is infeasible, the family has
    no feasible baseline: it is recorded ineligible with the rejection reason and the search
    never runs, rather than spending the whole budget on candidates that can never be scored."""
    rng = random.Random(f"{seed}:{family}")
    controls = {}
    for metric, key in DIRECT_CONTROLS.items():
        if metric in target:
            controls[key] = float(target[metric])
    for key in SEARCH_CONTROLS:
        controls[key] = 0.0

    best = dict(controls)
    try:
        best_res = residuals(evaluate(best), target, widths)
    except InfeasibleCandidate as exc:
        return {"family": family, "eligible": False,
                "controls": {k: round(v, 6) for k, v in sorted(best.items())},
                "residuals": {}, "infeasible": str(exc)}
    best_score = max(best_res.values()) if best_res else float("inf")

    initial_step = 0.5
    steps = {key: initial_step for key in SEARCH_CONTROLS}
    for i in range(budget):
        if best_score <= tolerance:
            break
        candidate = dict(best)
        key = SEARCH_CONTROLS[i % len(SEARCH_CONTROLS)]
        delta = steps[key] * (1 if rng.random() < 0.5 else -1)
        candidate[key] = max(-1.0, min(1.0, candidate[key] + delta))
        try:
            res = residuals(evaluate(candidate), target, widths)
            score = max(res.values()) if res else float("inf")
        except InfeasibleCandidate:
            res, score = {}, float("inf")
        if score < best_score:
            best, best_res, best_score = candidate, res, score
            steps[key] = initial_step
        else:
            steps[key] = max(steps[key] * 0.75, 0.01)

    return {"family": family, "eligible": eligible(best_res, tolerance),
            "controls": {k: round(v, 6) for k, v in sorted(best.items())},
            "residuals": {k: round(v, 6) for k, v in sorted(best_res.items())},
            "infeasible": None}


def out_of_range_witness(family, target, control_ranges, widths):
    """An ineligible witness for a family whose target needs a direct control outside the
    template's declared validRange, or None if every direct control is in range. The CLI
    rejects out-of-range values rather than clamping them, so this is knowable without a
    single CLI call: any violation makes the family ineligible regardless of magnitude."""
    residuals_out = {}
    reasons = []
    for metric, key in DIRECT_CONTROLS.items():
        if metric not in target:
            continue
        bounds = control_ranges.get(key)
        if not bounds or len(bounds) != 2:
            continue
        lo, hi = bounds
        value = float(target[metric])
        if lo <= value <= hi:
            continue
        distance = (lo - value) if value < lo else (value - hi)
        width = widths.get(metric)
        residuals_out[key] = distance / width if width else distance
        reasons.append(f"{key} = {value} is outside its valid range [{lo}, {hi}]")
    if not residuals_out:
        return None
    controls = {key: round(float(target[metric]), 6) for metric, key in DIRECT_CONTROLS.items() if metric in target}
    return {"family": family, "eligible": False, "controls": controls,
            "residuals": {k: round(v, 6) for k, v in sorted(residuals_out.items())},
            "infeasible": "; ".join(sorted(reasons))}


def garment_fit(verify, controls):
    """Build once more at the solved controls with the default garment left enabled. A garment
    rejection is a statement about that garment's clearance, not about the body control space,
    so it is recorded as a fit failure and never as ineligibility; an infrastructure failure on
    this build aborts the run exactly as it does anywhere else."""
    try:
        verify(controls)
    except InfeasibleCandidate:
        return "fail"
    return "pass"


def solve_family(family, target, control_ranges, widths, evaluate, tolerance, budget, seed, verify=None):
    """Reject a family before touching the CLI if a direct control falls outside the
    template's valid range; otherwise solve it exactly as before, and record on a solved
    family the steps that replay it and, when a verifying evaluator is given, whether the
    default garment still fits the solved body."""
    witness = out_of_range_witness(family, target, control_ranges, widths)
    if witness is not None:
        return witness
    witness = solve(family, target, evaluate, widths, tolerance, budget, seed)
    if not witness["eligible"]:
        return witness
    witness["replaySteps"] = replay_steps(witness["controls"])
    if verify is not None:
        witness["garmentFit"] = garment_fit(verify, witness["controls"])
    return witness


def cli_evaluator(binary, template, seed, linter, workdir, metrics, disable_default_garment=True):
    """Build an avatar at the given controls and return its measured metric vector.

    The template's default garment is disabled before any control is set, so that the garment's
    clearance margins cannot decide whether a body-control target is reachable. The disable is
    candidate-independent and runs on a freshly initialised project, so it goes through
    run_checked: a non-zero exit there is a generator fault, not a rejection of this candidate.
    Pass disable_default_garment=False for an evaluator that builds the same controls with the
    garment in place."""

    def evaluate(controls):
        project = os.path.join(workdir, "a.vrmauthor")
        out = os.path.join(workdir, "draft.vrm")
        shutil.rmtree(project, ignore_errors=True)
        if os.path.exists(out):
            os.remove(out)
        run_checked([binary, "project", "init", "--dir", project, "--template", template,
                    "--seed", str(seed)], REPO)
        if disable_default_garment:
            run_checked([binary, "object", "set", "--project", project, "--request", "-"], REPO,
                        stdin_text=json.dumps(disable_default_garment_request()))
        request = os.path.join(workdir, "edit.json")
        with open(request, "w", encoding="utf-8") as fh:
            json.dump({"edit": {"object": "avatar:main", "values": controls}}, fh)
        run_cli([binary, "control", "set", "--project", project, "--request", request], REPO)
        run_cli([binary, "build", "--project", project, "--out", out], REPO)
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

    template_sha, control_ranges = template_info(binary, args.template)
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
    write_document(out_path, document)
    with tempfile.TemporaryDirectory(prefix="corpus_witness_") as workdir:
        linter = os.path.join(REPO, args.linter)
        evaluate = cli_evaluator(binary, args.template, args.seed, linter, workdir, list(widths))
        verify = cli_evaluator(binary, args.template, args.seed, linter, workdir, list(widths),
                               disable_default_garment=False)
        for family in sorted(targets):
            witness = solve_family(family, targets[family], control_ranges, widths, evaluate,
                                   args.tolerance, args.budget, args.seed, verify=verify)
            document["families"][family] = {k: v for k, v in witness.items() if k != "family"}
            write_document(out_path, document)
            tag = "eligible" if witness["eligible"] else ("INFEASIBLE" if witness.get("infeasible") else "INELIGIBLE")
            fit = witness.get("garmentFit")
            print(f"{family}: {tag}" + (f", garment {fit}" if fit else ""), file=sys.stderr)

    families = document["families"]
    eligible_count = sum(1 for f in families.values() if f["eligible"])
    print(f"{eligible_count}/{len(families)} families eligible -> {args.out}", file=sys.stderr)
    return 0


def template_info(binary, template_id):
    """A template's sha256 and each control's [min, max] validRange, from one `template list` call."""
    proc = run_checked([binary, "template", "list"], REPO)
    packs = json.loads(proc.stdout)["result"]["packs"]
    for pack in packs:
        if pack["id"] == template_id:
            ranges = {c["key"]: (c["validRange"][0], c["validRange"][1])
                     for c in pack.get("controls", []) if len(c.get("validRange", [])) == 2}
            return pack["sha256"], ranges
    raise SystemExit(f"template {template_id!r} is not installed")


if __name__ == "__main__":
    raise SystemExit(main())
