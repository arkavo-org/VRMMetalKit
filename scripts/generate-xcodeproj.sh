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
               BuildableName = "VRMMetalKitPackageTests.xctest"
               BlueprintName = "VRMMetalKitTests"
               ReferencedContainer = "container:">
            </BuildableReference>
         </TestableReference>
      </Testables>"""

patched, n = re.subn(r"<Testables>\s*</Testables>", testables, src, count=1)
if n != 1:
    raise SystemExit("Did not find empty <Testables/> block to patch")
scheme.write_text(patched)
print("Patched", scheme)
PY
