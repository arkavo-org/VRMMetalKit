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
"""Re-pin the acceptance pack set to a commit that carries every pack's oracles.

    python3 scripts/repin_packs.py --check
    python3 scripts/repin_packs.py
    python3 scripts/repin_packs.py --commit <sha> --all

A pack's runner.environment.pinnedCommit is the commit an independent evaluator
reproduces the pack from, so it must be reachable from HEAD and every path in
runner.environment.oracleHashes must exist there and hash to the recorded value.
A pin that fails either test is repaired by moving the whole pack set onto the
target commit (HEAD unless --commit says otherwise) and recomputing packHash;
the registry in evidence.json follows the same pin. Pins that already hold are
left alone unless --all forces the move.

Every `provenance.sources` entry naming a commit is restated at the pack's pin,
because a pack that cites a file at one commit while pinning its hash at another
cites evidence it is not reproducing. A cited source that is also an oracle must
carry its pinned hash at the target; one that is not an oracle must at least
exist there, or the script refuses and writes nothing.

The oracles themselves are never touched: if the target commit does not carry a
pack's recorded oracle hashes, nothing is written and every offending pack and
path is named, because a pin that does not carry its oracles is the defect this
script exists to remove.

Exit codes: 0 nothing to do or written, 2 refused, 3 changes pending (--check).
"""
import argparse
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from acceptance_run import compute_pack_hash, sha256_bytes  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACKS_DIR = os.path.join("docs", "proposals", "vrm-author-cli", "acceptance", "packs")
EVIDENCE = os.path.join("docs", "proposals", "vrm-author-cli", "acceptance", "evidence.json")

EXIT = {"ok": 0, "refused": 2, "pending": 3}

_BLOBS = {}


def blob_sha256(repo, commit, rel):
    """sha256 of a path's blob at a commit, or None when the path is absent there."""
    key = (os.path.abspath(repo), commit, rel)
    if key not in _BLOBS:
        proc = subprocess.run(["git", "-C", repo, "cat-file", "blob", f"{commit}:{rel}"],
                              capture_output=True, timeout=30)
        _BLOBS[key] = sha256_bytes(proc.stdout) if proc.returncode == 0 else None
    return _BLOBS[key]


def rev_parse(repo, ref):
    proc = subprocess.run(["git", "-C", repo, "rev-parse", ref], capture_output=True, text=True, timeout=30)
    if proc.returncode != 0:
        return None
    return proc.stdout.strip() or None


def is_ancestor(repo, commit, ref="HEAD"):
    proc = subprocess.run(["git", "-C", repo, "merge-base", "--is-ancestor", commit, ref],
                          capture_output=True, timeout=30)
    return proc.returncode == 0


def read_json(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def write_json(path, obj):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(obj, indent=2, ensure_ascii=True) + "\n")


SOURCE_CITATION = re.compile(r"^(?P<head>(?P<path>\S+).*) @ (?P<commit>[0-9a-f]{7,40})(?P<tail>.*)$")


def cited_sources(pack):
    """Every provenance.sources entry that names a commit, as (index, path, commit).

    A citation is `<path>[ extra text] @ <commit>[ (note)]`. Entries with no commit are prose
    references and are left alone.
    """
    out = []
    for i, source in enumerate(pack["provenance"]["sources"]):
        m = SOURCE_CITATION.match(source) if isinstance(source, str) else None
        if m:
            out.append((i, m.group("path"), m.group("commit")))
    return out


def recite_sources(pack, commit):
    """The pack's sources with every cited commit moved to `commit`, the rest untouched."""
    sources = list(pack["provenance"]["sources"])
    for i, _, _ in cited_sources(pack):
        m = SOURCE_CITATION.match(sources[i])
        sources[i] = f"{m.group('head')} @ {commit}{m.group('tail')}"
    return sources


def citation_failures(repo, commit, pack):
    """Every cited source with no pinned hash that commit does not carry.

    A citation that is also an oracle must carry the hash the pack pins there, which is the
    rule oracle_failures already applies to it; a citation that is not an oracle has no pinned
    hash, so the weaker requirement is that the path exists at that commit. Either way the
    script never writes a citation naming a commit that does not carry the cited file.
    """
    oracles = pack["runner"]["environment"]["oracleHashes"]
    return [(rel, None, None) for _, rel, _ in cited_sources(pack)
            if rel not in oracles and blob_sha256(repo, commit, rel) is None]


def oracle_failures(repo, commit, pack):
    """Every (path, expected, actual) in a pack whose oracle does not resolve at commit."""
    out = []
    for rel, want in sorted(pack["runner"]["environment"]["oracleHashes"].items()):
        got = blob_sha256(repo, commit, rel)
        if got != want:
            out.append((rel, want, got))
    return out


def pin_holds(repo, pack, head):
    pin = pack["runner"]["environment"]["pinnedCommit"]
    return is_ancestor(repo, pin, head) and not oracle_failures(repo, pin, pack)


def pack_paths(packs_dir):
    return [os.path.join(packs_dir, n) for n in sorted(os.listdir(packs_dir)) if n.endswith(".json")]


def plan(repo, packs_dir, evidence_path, target, retarget_all, head):
    """Decide the pin every pack should carry and which files that changes.

    Re-pinning is all-or-nothing across the set: one broken pin moves every pack,
    so the registry and the packs never disagree about the commit they name.
    """
    packs = [(p, read_json(p)) for p in pack_paths(packs_dir)]
    pins = {pack["runner"]["environment"]["pinnedCommit"] for _, pack in packs}
    retarget = retarget_all or len(pins) != 1 or any(not pin_holds(repo, pack, head) for _, pack in packs)
    changes, refusals = [], []
    desired = {}
    for path, pack in packs:
        pin = target if retarget else pack["runner"]["environment"]["pinnedCommit"]
        for rel, want, got in oracle_failures(repo, pin, pack) + citation_failures(repo, pin, pack):
            refusals.append((os.path.basename(path), pin, rel, want, got))
        updated = json.loads(json.dumps(pack))
        updated["runner"]["environment"]["pinnedCommit"] = pin
        updated["provenance"]["sources"] = recite_sources(pack, pin)
        updated["packHash"] = ""
        updated["packHash"] = compute_pack_hash(updated)
        desired[path] = updated
        if updated != pack:
            why = []
            if pack["runner"]["environment"]["pinnedCommit"] != pin:
                why.append(f"pinnedCommit {pack['runner']['environment']['pinnedCommit'][:12]} -> {pin[:12]}")
            restated = sum(1 for old, new in zip(pack["provenance"]["sources"], updated["provenance"]["sources"])
                           if old != new)
            if restated:
                why.append(f"{restated} source citation(s) -> {pin[:12]}")
            if pack["packHash"] != updated["packHash"]:
                why.append(f"packHash {(pack['packHash'] or '(empty)')[:12]} -> {updated['packHash'][:12]}")
            changes.append((path, ", ".join(why)))
    evidence = read_json(evidence_path)
    registry_pin = next(iter({p["runner"]["environment"]["pinnedCommit"] for p in desired.values()}))
    if evidence.get("pinnedCommit") != registry_pin:
        changes.append((evidence_path, f"pinnedCommit {(evidence.get('pinnedCommit') or '(none)')[:12]} -> {registry_pin[:12]}"))
        evidence["pinnedCommit"] = registry_pin
    return desired, evidence, changes, refusals


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--commit", help="commit to pin (default: the current branch head)")
    ap.add_argument("--repo", default=REPO, help="repository the oracles are read out of")
    ap.add_argument("--packs", help="pack directory (default: the acceptance packs of --repo)")
    ap.add_argument("--evidence", help="evidence registry (default: the acceptance registry of --repo)")
    ap.add_argument("--check", action="store_true", help="report what would change and write nothing")
    ap.add_argument("--all", action="store_true", help="re-pin every pack even where the recorded pin still holds")
    args = ap.parse_args(argv)

    repo = args.repo
    packs_dir = args.packs or os.path.join(repo, PACKS_DIR)
    evidence_path = args.evidence or os.path.join(repo, EVIDENCE)
    head = rev_parse(repo, "HEAD")
    if head is None:
        print(f"refused: {repo} has no HEAD to pin against", file=sys.stderr)
        return EXIT["refused"]
    target = rev_parse(repo, args.commit) if args.commit else head
    if target is None:
        print(f"refused: {args.commit!r} does not resolve to a commit in {repo}", file=sys.stderr)
        return EXIT["refused"]
    if not is_ancestor(repo, target, head):
        print(f"refused: {target} is not reachable from HEAD, so a pin naming it would not hold", file=sys.stderr)
        return EXIT["refused"]
    if not os.path.isdir(packs_dir) or not pack_paths(packs_dir):
        print(f"refused: {packs_dir} holds no packs to pin", file=sys.stderr)
        return EXIT["refused"]

    desired, evidence, changes, refusals = plan(repo, packs_dir, evidence_path, target, args.all, head)
    if refusals:
        print("refused: the target commit does not carry these oracles and cited sources", file=sys.stderr)
        for name, pin, rel, want, got in refusals:
            detail = (f"is {got or 'absent'}, not the pinned {want}" if want
                      else "is absent there, so no citation may name that commit")
            print(f"  {name} @ {pin[:12]}: {rel} {detail}", file=sys.stderr)
        print(f"{len(refusals)} reference(s) unresolved; nothing written", file=sys.stderr)
        return EXIT["refused"]
    held = next(iter({p["runner"]["environment"]["pinnedCommit"] for p in desired.values()}))
    if not changes:
        print(f"no changes needed: {len(desired)} packs and the registry pin {held[:12]}, which carries every oracle")
        return EXIT["ok"]
    changed = {path for path, _ in changes}
    for path, why in changes:
        print(f"{os.path.basename(path)}: {why}")
    if args.check:
        print(f"{len(changes)} file(s) would change; nothing written")
        return EXIT["pending"]
    for path, pack in desired.items():
        if path in changed:
            write_json(path, pack)
    if evidence_path in changed:
        write_json(evidence_path, evidence)
    print(f"{len(changes)} file(s) written, pinned at {held[:12]}")
    return EXIT["ok"]


if __name__ == "__main__":
    sys.exit(main())
