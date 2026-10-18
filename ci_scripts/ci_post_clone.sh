#!/bin/sh
# Xcode Cloud post-clone hook.
# Rebuilds VRMMetalKitShaders.metallib from source so the binary blob
# checked into Resources/ is never the trust boundary on CI.

set -euo pipefail

cd "$CI_PRIMARY_REPOSITORY_PATH"
make shaders

# The test host's working directory is /private/tmp and it cannot see this
# checkout. Copy the committed avatars into the test resources so
# Bundle.module has them. The copies are gitignored.
fixture_dir="Tests/VRMMetalKitTests/TestData"
mkdir -p "$fixture_dir"
for name in AvatarSample_A_0.0.vrm.glb AvatarSample_A_1.0.vrm.glb AvatarSample_U_1.0.vrm.glb; do
  if [ -f "$name" ]; then
    cp -f "$name" "$fixture_dir/$name"
  fi
done
