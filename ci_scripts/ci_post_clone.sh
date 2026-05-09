#!/bin/sh
# Xcode Cloud post-clone hook.
# Rebuilds VRMMetalKitShaders.metallib from source so the binary blob
# checked into Resources/ is never the trust boundary on CI.

set -euo pipefail

cd "$CI_PRIMARY_REPOSITORY_PATH"
make shaders
