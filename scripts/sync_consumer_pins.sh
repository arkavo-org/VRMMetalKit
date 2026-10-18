#!/usr/bin/env bash
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
# Move every consumer's exact VRMMetalKit pin to a released version.
#
# The GameOfMods app pins VRMMetalKit directly and pulls MuseCore as a remote
# package, and a MuseCore release pins VRMMetalKit itself. A bump therefore
# takes two stages with a MuseCore release between them:
#
#   1. scripts/sync_consumer_pins.sh 1.2.0
#        Pins MuseCore, SynthNPCKit and VRMAuthorKit (Package.swift) to 1.2.0
#        and re-resolves each. Then release MuseCore with that pin.
#   2. scripts/sync_consumer_pins.sh 1.2.0 --musecore 0.42.0
#        Also pins GameOfMods.xcodeproj to VRMMetalKit 1.2.0 and MuseCore
#        0.42.0, and re-resolves the project.
#
# Every check runs before any file is edited: the VRMMetalKit tag must exist
# on origin, every pin must be found, and in stage 2 the MuseCore tag must
# exist on its origin and pin this VRMMetalKit version. --dry-run stops after
# the checks and prints the planned edits; it still fetches the MuseCore tag
# (stage 2), because the check reads that tag's Package.swift.
#
# Usage:
#   scripts/sync_consumer_pins.sh <version> [--musecore <version>]
#                                 [--projects-root <dir>] [--dry-run]

set -euo pipefail

usage() {
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

VERSION=""
MUSECORE_VERSION=""
DRY_RUN=0
VMK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECTS_ROOT="$(cd "${VMK_ROOT}/.." && pwd)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --musecore) MUSECORE_VERSION="${2:-}"; shift 2 ;;
        --projects-root) PROJECTS_ROOT="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage ;;
        -*) echo "error: unknown option $1" >&2; usage ;;
        *) [[ -z "$VERSION" ]] || usage; VERSION="$1"; shift ;;
    esac
done
[[ -n "$VERSION" ]] || usage

fail() { echo "error: $*" >&2; exit 1; }

remote_has_tag() {
    git -C "$1" ls-remote --exit-code --tags origin "refs/tags/$2" >/dev/null 2>&1
}

# --- Checks (nothing is edited until all of them pass) -----------------------

remote_has_tag "$VMK_ROOT" "$VERSION" \
    || fail "VRMMetalKit tag '${VERSION}' is not on origin. Tag and push the release first."

PACKAGES=(
    "${PROJECTS_ROOT}/MuseCore/Package.swift"
    "${PROJECTS_ROOT}/GameOfMods/SynthNPCKit/Package.swift"
    "${PROJECTS_ROOT}/GameOfMods/VRMAuthorKit/Package.swift"
)
PBXPROJ="${PROJECTS_ROOT}/GameOfMods/GameOfMods.xcodeproj/project.pbxproj"

PIN_TOOL="$(mktemp -t vmk_pins.XXXXXX)"
trap 'rm -f "$PIN_TOOL"' EXIT
cat >"$PIN_TOOL" <<'PY'
import re
import sys
from pathlib import Path

SWIFT_PIN = re.compile(
    r'(\.package\(url:\s*"https://github\.com/arkavo-org/VRMMetalKit",\s*exact:\s*")([^"]+)(")')

def xcode_pin(name):
    return re.compile(
        r'(XCRemoteSwiftPackageReference "' + re.escape(name) + r'" \*/ = \{[^}]*?'
        r'kind = exactVersion;\s*version = )([^;]+)(;)',
        re.S)

# argv: check|apply  swift|xcode  path  version [musecore-version]
action, kind, path = sys.argv[1], sys.argv[2], sys.argv[3]
if kind == "swift":
    edits = [("VRMMetalKit", SWIFT_PIN, sys.argv[4])]
else:
    edits = [("VRMMetalKit", xcode_pin("VRMMetalKit"), sys.argv[4]),
             ("MuseCore", xcode_pin("MuseCore"), sys.argv[5])]

text = Path(path).read_text()
for name, pattern, version in edits:
    matches = pattern.findall(text)
    if len(matches) != 1:
        raise SystemExit(f"error: expected one exact {name} pin in {path}, found {len(matches)}")
    print(f"  {path}: {name} {matches[0][1]} -> {version}")
    text = pattern.sub(lambda m: m.group(1) + version + m.group(3), text)
if action == "apply":
    Path(path).write_text(text)
PY

for manifest in "${PACKAGES[@]}"; do
    [[ -f "$manifest" ]] || fail "missing ${manifest}"
    python3 "$PIN_TOOL" check swift "$manifest" "$VERSION"
done

if [[ -n "$MUSECORE_VERSION" ]]; then
    MUSECORE_ROOT="${PROJECTS_ROOT}/MuseCore"
    [[ -f "$PBXPROJ" ]] || fail "missing ${PBXPROJ}"
    remote_has_tag "$MUSECORE_ROOT" "$MUSECORE_VERSION" \
        || fail "MuseCore tag '${MUSECORE_VERSION}' is not on origin. Release MuseCore first (stage 1)."
    git -C "$MUSECORE_ROOT" fetch --quiet origin "refs/tags/${MUSECORE_VERSION}:refs/tags/${MUSECORE_VERSION}"
    released_pin="$(git -C "$MUSECORE_ROOT" show "${MUSECORE_VERSION}:Package.swift" \
        | sed -n 's#.*arkavo-org/VRMMetalKit", *exact: *"\([^"]*\)".*#\1#p')"
    [[ "$released_pin" == "$VERSION" ]] \
        || fail "MuseCore ${MUSECORE_VERSION} pins VRMMetalKit '${released_pin}', not '${VERSION}'."
    python3 "$PIN_TOOL" check xcode "$PBXPROJ" "$VERSION" "$MUSECORE_VERSION"
fi

if [[ "$DRY_RUN" == 1 ]]; then
    echo "Checks passed; dry run, nothing edited."
    exit 0
fi

# --- Edits --------------------------------------------------------------------

for manifest in "${PACKAGES[@]}"; do
    python3 "$PIN_TOOL" apply swift "$manifest" "$VERSION" >/dev/null
done
for manifest in "${PACKAGES[@]}"; do
    package="$(dirname "$manifest")"
    echo "resolving ${package}..."
    (cd "$package" && swift package update VRMMetalKit)
done

if [[ -z "$MUSECORE_VERSION" ]]; then
    echo "Stage 1 done. Release MuseCore with VRMMetalKit ${VERSION}, then run:"
    echo "  $0 ${VERSION} --musecore <new MuseCore version>"
    exit 0
fi

python3 "$PIN_TOOL" apply xcode "$PBXPROJ" "$VERSION" "$MUSECORE_VERSION" >/dev/null
echo "resolving ${PROJECTS_ROOT}/GameOfMods/GameOfMods.xcodeproj..."
(cd "${PROJECTS_ROOT}/GameOfMods" && xcodebuild -resolvePackageDependencies -project GameOfMods.xcodeproj)
echo "VRMMetalKit ${VERSION} and MuseCore ${MUSECORE_VERSION} are pinned across every consumer."
