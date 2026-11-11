<!-- Copyright 2026 Arkavo. Licensed under the Apache License, Version 2.0. -->

# VRM loading audit — 2026-11-11

Audited `dbda183` against the local `../vrm-conformance` checkout, with release
measurements on an Apple M4 Max. This is a focused loading audit, not a claim of
complete file-format validation or a full cross-renderer conformance gate.
Related performance work: [#223](https://github.com/arkavo-org/VRMMetalKit/issues/223).

## Confirmed and corrected

| Priority | Finding | Reproduction and correction |
|---|---|---|
| P1 | Accessor counts/ranges can crash or cross buffer-view boundaries | A count of `-1` traps; a two-element accessor over a one-element view reads the next view's bytes. Validate counts, allocation arithmetic, view ranges, strides and sparse ranges before allocation or reads. Keep packed FLOAT/UINT bulk-copy paths. |
| P1 | External-resource directory containment is incomplete | A base directory named `base` accepts `../base-other/buffer.bin`; preload and parallel texture paths also fail to resolve symlinks. All four loaders now resolve symlinks and require a directory boundary. This is essential before accessor reads reuse preloaded buffers. |
| P2 | Integer-to-float decoding ignores `normalized` | `[0,128,255]` with `normalized:false` decodes as `[0,0.5019608,1]`. Signed normalized BYTE minimum yields `-1.007874`. Respect the flag, including its false default and sparse overrides, and clamp signed minima to `-1`. |
| P2 | Occlusion textures upload as sRGB | The conformance occlusion fixtures use Metal format 71 (`rgba8Unorm_srgb`) instead of 70 (`rgba8Unorm`). Upload AO as linear data. If the same texture is also used for color, keep separate color/data mip chains and the same sampler. Detect both VRM 1.0 and legacy VRM 0.x color slots. Linear data must not use base-color alpha coverage weighting. |
| P2 | Accessor reads bypass preloaded buffers | A document whose only buffer source is `preloadedData` fails with `missingBuffer`; ordinary external/data-URI accessor reads can repeat work after preloading. Route buffer-view reads through `getBufferData`. |

Normalization and occlusion expectations follow the
[glTF specification](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html),
particularly `accessor.normalized` and `material.occlusionTexture`.

Regression coverage is in `AccessorDecodingTests`, `BufferLoaderCacheTests`,
`LoaderSecurityTests`, and `VRMTextureSamplerTests`. The new assertions were
observed failing before their corrections. Existing mip-filtering tests cover
linear-light averaging, straight alpha, and preservation of data channels.

## Cross-check with vrm-conformance

The sibling adapter pins VRMMetalKit `2162dd0` (1.2.1), so running its pinned
package would not test this checkout. A temporary copy of its adapter sources
was built against the local package, retaining the same camera, lighting,
radiometric normalization, 4x MSAA and render operations. Rendering was serial.

Used 24 plans from `goldens-cache-1.2.0-rc.1`:
`_assets_pbrtex`, `_assets_outlinetex`, `_assets_uvxform`, and `_assets_matcap`.
All loaded and rendered before and after the patch. **21 PNGs were
byte-identical; only `mtoon_pbrtex_combined`, `mtoon_pbrtex_occlusion_default`,
and `mtoon_pbrtex_occlusion_strength_half` changed.** AO texture formats also
changed from sRGB to linear as expected. No shader sources or binaries changed.

An initial run using `goldens-cache` was discarded as evidence of texture
correctness. Its older PBR texture fixtures have outlines enabled, engulfing
the sphere in black and masking AO differences; its cached UniVRM image has
the same problem. The sibling `docs/findings.md` documents this stale-corpus
hazard in the 2026-06-14/19 entries. Use the later outlines-off fixtures.

These checks establish loading/render stability and isolate the intended AO
changes. They do not establish all-renderer SSIM pass rates or coverage of
malformed files: vrm-conformance explicitly delegates file validation elsewhere.

## Loading measurements

Release build, independent processes, warm filesystem cache, one warm-up per
configuration excluded, seven measured runs each, alternating configuration
order. Timed `VRMModel.load(from:device:options:)`, including resource loading
and model physics setup; excluded `VRMRenderer` construction and renderer
warmup. Memory is process peak RSS from `/usr/bin/time -l`.

| Asset / configuration | Median load | Median peak RSS |
|---|---:|---:|
| AvatarSample_A, baseline default | 651.3 ms | 601.6 MiB |
| AvatarSample_A, corrected default | 651.2 ms | 601.7 MiB |
| AvatarSample_A, corrected + parallel texture loading | 448.2 ms | 627.0 MiB |
| Aisling, baseline default | 12.5 ms | 53.8 MiB |
| Aisling, corrected default | 12.0 ms | 53.7 MiB |
| Aisling, corrected + parallel texture loading | 11.6 ms | 54.0 MiB |

The correctness changes do not materially change AvatarSample_A default load
time. Existing `.parallelTextureLoading` reduces its median by approximately
31%, at approximately 25 MiB higher process peak RSS. The smaller asset gains
less. This is a same-machine configuration comparison, not a benchmark against
other platforms. Measurements preceded the final URI and VRM 0.x review fixes;
those fixes do not change the measured embedded-resource decoding algorithms.

## Next optimization work and remaining bugs

1. **Bound texture concurrency before enabling parallel loading by default.**
   `ParallelTextureLoader.maxConcurrentLoads` is stored but unused; the task
   group schedules every texture. Use a rolling task window or an async limiter
   with a memory budget. The default preset's `.parallelTextureDecoding` flag
   is currently a no-op. Parallel loading already provides a measured gain;
   the next step is controlling its memory cost.
2. **Preserve errors in the parallel loader.** Its `try?` converts failures to
   missing textures. Replacing one PNG with invalid bytes in the two-texture
   combined fixture makes default loading throw `invalidImageData`, while
   parallel loading returns a model with an empty texture slot. Define an
   explicit strict/best-effort policy before changing the default.
3. **Complete malformed-image and allocation validation.** Both texture
   loaders check `sourceIndex < images.count` without checking that it is
   nonnegative. Image buffer-view range checks also need the same overflow-safe
   treatment as accessor ranges. These are code-inspection findings, not fixed
   by the accessor patch. Allocation quotas remain a separate requirement in
   [#179](https://github.com/arkavo-org/VRMMetalKit/issues/179).
4. **Initialize the resource base URL before resource loading.** The URL entry
   point assigns `model.baseURL` after the inner load has already consumed
   resources. This affects externally referenced resources rather than ordinary
   self-contained VRMs. Move initialization earlier with tests for both URL
   and in-memory entry-point semantics.
5. **Profile native texture work before replacing it.** CPU mip generation and
   load-time BC7 encoding remain candidates for Metal compute or a persistent
   GPU-ready cache. Preserve straight alpha, coverage weighting, linear-light
   filtering and odd-dimension area weights. BC7 trades load CPU for runtime
   bandwidth; `.maximumPerformance` is not automatically the shortest load.
6. **Evaluate mapped GLB data and fewer temporary copies.** The URL path reads
   `Data(contentsOf:)`; the parser copies JSON/BIN chunks with `subdata`.
   Measure lifetime/peak memory on large files before adopting mapping or
   slices. Do not expose pointers after their backing data dies.

Retain ImageIO/Accelerate decoding, unified-memory-aware Metal resources,
accessor memoization, bulk copies, GPU morph/physics paths, and compiled shader
and pipeline caches. A blanket change from `.shared` to staging plus `.private`
can add work on Apple silicon; benchmark load latency and steady-state GPU
cost together. The patch preserves these native paths and introduces no
portable rendering abstraction or CPU rendering fallback.

## Verification commands

Final reviewed patch: build succeeded; the full 2,350-test scheduled suite
exited successfully, focused regressions passed, and `git diff --check` passed.
The final release adapter reproduced the 21 unchanged / 3 AO-changed result.

```sh
swift build
swift test --parallel --num-workers 14 -j 16 --disable-sandbox
swift test --filter 'AccessorDecodingTests|VRMTextureSamplerTests|LoaderSecurityTests|BufferLoaderCacheTests|TextureMipUploaderTests' --disable-sandbox
git diff --check
```

Temporary harnesses, raw measurements, adapter outputs and logs are under
`/tmp/vrm-loading-audit/` and `/tmp/vrm-audit-*.log` on the audit machine.
The sibling repository was read without modifications.
