#!/bin/sh
# Regenerates VRMMetalKitCI.xcodeproj from project.yml and re-applies the
# test-target wiring that XcodeGen 2.45 cannot express. Run this whenever
# project.yml changes.
#
# XcodeGen does not support referencing a Swift Package's test product as
# a Testable in a scheme; it leaves <Testables> empty. We patch the
# scheme XML in place after generation.

set -euo pipefail

cd "$(dirname "$0")/.."

xcodegen generate

SCHEME="VRMMetalKitCI.xcodeproj/xcshareddata/xcschemes/VRMMetalKitHost.xcscheme"

python3 <<'PY'
import re
from pathlib import Path

scheme = Path("VRMMetalKitCI.xcodeproj/xcshareddata/xcschemes/VRMMetalKitHost.xcscheme")
src = scheme.read_text()

testables = """      <Testables>
         <TestableReference
            skipped = "NO"
            parallelizable = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "VRMMetalKitTests"
               BuildableName = "VRMMetalKitTests"
               BlueprintName = "VRMMetalKitTests"
               ReferencedContainer = "container:">
            </BuildableReference>
         </TestableReference>
      </Testables>"""

src, n = re.subn(r"<Testables>\s*</Testables>", testables, src, count=1)
if n != 1:
    raise SystemExit("Did not find empty <Testables/> block to patch")

# Match Xcode's normalized scheme format so opening the project does not
# dirty the working tree on every run.
src = src.replace('version = "1.7"', 'version = "1.3"')
src = re.sub(r'\n\s+runPostActionsOnFailure = "NO">', ">", src)
src = re.sub(r'\n\s+onlyGenerateCoverageForSpecifiedTargets = "NO">', ">", src)
src = re.sub(r"\n\s+<CommandLineArguments>\s*</CommandLineArguments>", "", src)

scheme.write_text(src)
print("Patched", scheme)
PY
