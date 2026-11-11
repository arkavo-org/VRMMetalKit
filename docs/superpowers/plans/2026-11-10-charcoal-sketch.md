# Charcoal Sketch Materialization Style Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `VRMMaterializationStyle.charcoal` (raw value 13): one progress value takes an avatar from blank paper, through a charcoal drawing held at 0.6, to its plain MToon render.

**Architecture:** Everything lives in the existing single MToon pass. `mat_resolve` computes two head-down fronts and stores them in `MatState`; a new `mat_sketchSurface` replaces the generic composite for style 13; the inverted hull is widened in the vertex stage and inked in the fragment stage. No new render targets, passes or uniform fields.

**Tech Stack:** Swift 6.2, Metal Shading Language 4.0, XCTest. Shaders are precompiled with `make shaders`.

**Spec:** `docs/superpowers/specs/2026-11-10-charcoal-sketch-design.md`. Issue #471, branch `issue/471-charcoal-sketch`.

**Reference implementation:** `_visuals_charcoal/charcoal-spike.patch` at the repo root (untracked). It is a diff against `main` at 2162dd0 containing working versions of most shader stages. Tasks below name the functions to take from it and the changes to make. Do not `git apply` it onto the branch; copy function bodies by hand. `_visuals_charcoal/CharcoalSpikeTests.swift` is the render test that produced the approved stills.

## Global Constraints

- Style raw value is 13. The hold point is `progress = 0.6`. Draw band 0.35, colour band 0.25, field noise amplitude 0.06.
- Paper is (0.86, 0.83, 0.77); ink is (0.030, 0.028, 0.026); default ember is (1.0, 0.42, 0.10). These are the values the fragment writes. The MToon fragment does no output encoding, so on Creator's and the default target (`.bgra8Unorm`) they are the stored bytes, and on an `_srgb` target the hardware encodes them.
- The reference frames, the harness and all tuning use `.bgra8Unorm`, because that is what Creator captures into and what `RendererConfig` defaults to. One test covers `.rgba8Unorm_srgb`.
- All pixel distances are relative to a 1080-pixel-high output: `px = in.position.xy / max(uniforms.viewportSize.y / 1080.0, 0.25)`.
- The `Uniforms` struct size (496) and field offsets do not change.
- `mat_resolve` and the hull widening both return before any charcoal arithmetic when `progress >= 1` or the style is not 13.
- Renderers with `enableMaterialization == false`, or with no active materialization, render exactly as on `main`. `MToonLegacyGoldenTests` must pass unmodified after every task.
- The twelve existing styles render as on `main` (within 1 per channel). `MaterializationStyleGoldenTests`, captured in Task 2 Step 0, must pass unmodified after every later task.
- Every shader edit: `make shaders` (all five metallibs), update `knownGoodShaderHash` in `Tests/VRMMetalKitTests/MToonShaderGPUTests.swift` to the value printed by `swift test --filter testShaderSourceHashMatchesKnownGood --disable-sandbox`, and commit the metallibs with the source.
- Shaders compile with `-Wall -Wextra -Werror`. New files carry the Apache 2.0 header. No temporary or contextual comments in code.
- Test commands always pass `--disable-sandbox`. Commit after each task; do not push.
- Every "byte-identical" assertion compares two frames from one `CharcoalHarness` (one loaded model, one renderer).

## Review Focus

1. **`heightRange` that does not match the avatar** (host passes the default while the avatar is shorter, taller or crouched): the effect must still end clean at `progress = 1` and hold no colour at 0.6. Test in Task 2.
2. **4x MSAA host** (`sampleCount = 4`, as `VRMRender` and `VisionHost` use): renders without validation errors and holds no colour at 0.6. Test in Task 6.
3. **VRM 0.x avatar** (`AvatarSample_A_0.0.vrm.glb`): inert at 1, no colour at 0.6, drawn at 0.6. Test in Task 4.
4. **Output height far from 1080** (a 256-pixel thumbnail): strokes scale and the frame is still drawn and colour-free at 0.6. Test in Task 4.
5. **Orthographic camera** (`VRMVideoRenderer --ortho`): `mat_viewDir` derives a perspective eye position, so the grazing-angle contour must not flood the surface with ink. Test in Task 3.

---

### Task 1: Relit reference frames (human gate)

The approved stills were lit from below. This task re-renders them under Creator's rig so every later task tunes against the right target. It changes nothing on the branch.

**Files:**
- Create (outside the repo): a detached scratch worktree under the session scratchpad.
- Create: `_visuals_charcoal/relit/` (untracked) holding the new PNGs.

- [ ] **Step 1: Build the spike in a scratch worktree**

```bash
git worktree add --detach <scratch>/charcoal-ref 2162dd0
cd <scratch>/charcoal-ref
git apply <repo>/_visuals_charcoal/charcoal-spike.patch
cp <repo>/_visuals_charcoal/CharcoalSpikeTests.swift Tests/VRMMetalKitTests/
make shaders-macos
```

- [ ] **Step 2: Switch the spike test to Creator's rig**

In the copied `CharcoalSpikeTests.swift`, replace `renderer.setupBrightToonLighting()` with:

```swift
renderer.setLight(0, direction: SIMD3<Float>(-0.62, -0.52, -0.59), color: SIMD3<Float>(1.0, 0.95, 0.88), intensity: 1.1)
renderer.setLight(1, direction: SIMD3<Float>(0.25, -0.12, -0.96), color: SIMD3<Float>(0.75, 0.82, 0.95), intensity: 0.55)
renderer.setLight(2, direction: SIMD3<Float>(0.51, -0.41, 0.76), color: SIMD3<Float>(0.85, 0.92, 1.0), intensity: 0.55)
renderer.setAmbientColor(SIMD3<Float>(0.20, 0.20, 0.22))
renderer.setLightNormalizationMode(.radiometric)
```

Also switch the test to Creator's target format: `config.colorPixelFormat = .bgra8Unorm`, `pixelFormat: .bgra8Unorm` in the `renderFrame` call, and swap B and R when writing the PNG.

- [ ] **Step 3: Render and collect**

Run: `VRM_TEST_VRM1_PATH=<repo>/AvatarSample_A_1.0.vrm.glb CHARCOAL_SPIKE_OUT=<repo>/_visuals_charcoal/relit swift test --filter CharcoalSpikeTests --disable-sandbox`
Expected: 18 PNGs (`body_*`, `bust_*` at nine progress values). Repeat with `AvatarSample_U_1.0.vrm.glb` into `_visuals_charcoal/relit-U/`.

- [ ] **Step 4: Measure the statistics the later tests assert on**

Add a temporary second test in the scratch worktree that prints, for `AvatarSample_A_1.0` at size 512 in body and bust framings: mean ink inside the plain silhouette at progress 0, 0.25 and 0.6; mean ink over the whole frame at progress 0; mean ink over dark (plain luma < 0.05) and pale (plain luma > 0.5) silhouette pixels at 0.6; the count of ink pixels outside the plain silhouette at 0.6; the largest off-line distance at 0.6. Record the numbers in the "Measured baselines" table at the end of this plan and commit the plan. Where a provisional bound in Tasks 3 to 7 is not at least a factor of two inside the measured value, replace it with half the measured value (lower bounds) or double it (upper bounds).

- [ ] **Step 5: Paul reviews `bust_t060.png` and `body_t030/060/080.png`**

The non-sRGB target makes the paper more toned and the ink closer to black than in the 2026-11-10 stills. Record his notes in the PR description draft. These frames replace those stills as the tuning target.

- [ ] **Step 6: Remove the worktree**

Run: `git worktree remove --force <scratch>/charcoal-ref`

---

### Task 2: API, test harness, and the two-front timeline

Deliverable: `.charcoal` exists and sweeps from flat paper to the lit render with no drawing yet.

**Files:**
- Modify: `Sources/VRMMetalKit/Renderer/VRMMaterialization.swift`
- Modify: `Sources/VRMMetalKit/Renderer/VRMRenderer.swift` (materialization upload, near the `uniforms.materializeOrigin_packed` assignment)
- Modify: `Sources/VRMMetalKit/Shaders/MToonShader.metal` (`MatState`, `mat_resolve`, the composite before `if (mat.active)`)
- Modify: `Tests/VRMMetalKitTests/MaterializationTests.swift` (rename `testAllTwelveStylesEnumerated` to `testAllThirteenStylesEnumerated`, expect 13 and `Set(1...13)`)
- Create: `Tests/VRMMetalKitTests/CharcoalTestSupport.swift`
- Create: `Tests/VRMMetalKitTests/CharcoalSketchTests.swift`
- Create: `Tests/VRMMetalKitTests/MaterializationStyleGoldenTests.swift` and `Tests/VRMMetalKitTests/TestData/Materialize/golden_style_<raw>.rgba.zlib` (twelve files)

**Interfaces:**
- Produces (Swift):
  - `VRMMaterializationStyle.charcoal = 13`
  - `VRMMaterialization.boilPhase: UInt32` (new stored property, new trailing `init` parameter `boilPhase: UInt32 = 0`)
  - `VRMMaterialization.charcoalPaperColor: SIMD3<Float>` = (0.86, 0.83, 0.77), `charcoalInkColor: SIMD3<Float>` = (0.030, 0.028, 0.026), `charcoalHoldProgress: Float` = 0.6 (all `public static let`)
  - `VRMMaterializationStyle.requiresHostBackground: Bool` (public; true only for `.charcoal`), so hosts that pick a style from `allCases` can skip styles that need the host to clear to a specific colour
  - `VRMMaterialization.encodedBoilPhase: Float` (internal) = `Float(boilPhase & 0xFFFF)`; the renderer writes it to `materializeOrigin_packed.w`
- Produces (shader): `MatState` fields `float sketch` (1 for style 13), `sketchS` (0..0.6), `sketchReveal`, `sketchRevealSlow`, `sketchFront` (the colour front's local progress `sColour`), `sketchEmberOn` (1 when `materializeColor.xyz` is non-zero); constants `kSketchPaper`, `kSketchInk`; `static float4 mat_sketchSurface(constant Uniforms&, VertexOut, MatState, float3 N, float3 albedo, float alpha, float3 lit, float toonStep, bool isBlend)`, called just before `if (mat.active)` when `mat.sketch > 0.5`.
- Produces (tests):

```swift
@MainActor final class CharcoalHarness {
    enum Framing { case body, bust }
    init(device: MTLDevice, modelPath: String = getTestVRM10ModelPath(), size: Int = 512,
         sampleCount: Int = 1, framing: Framing = .body, orthographic: Bool = false,
         pixelFormat: MTLPixelFormat = .bgra8Unorm, enableMaterialization: Bool = true,
         camera: (eye: SIMD3<Float>, target: SIMD3<Float>)? = nil,
         configure: ((VRMModel, VRMRenderer) -> Void)? = nil) async throws
    let pixelFormat: MTLPixelFormat
    func render(_ materialization: VRMMaterialization?) throws -> [UInt8]   // bytes in R, G, B, A order
    func charcoal(_ progress: Float, color: SIMD3<Float>? = nil, boilPhase: UInt32 = 0,
                  heightRange: ClosedRange<Float> = 0.0...1.62) -> VRMMaterialization   // seed 3
}
enum CharcoalMeasure {
    static func colours(_ rgba: [UInt8], format: MTLPixelFormat) -> [SIMD3<Float>]
        // the values the fragment wrote: bytes / 255, sRGB-decoded only when `format` is an _srgb format
    static func offLineDistance(_ c: SIMD3<Float>) -> Float   // distance to the segment ink...paper
    static func ink(_ c: SIMD3<Float>) -> Float               // 0 at paper, 1 at ink
    static func silhouette(plain: [UInt8]) -> [Bool]          // pixels that differ from the paper clear
    static func meanInk(_ rgba: [UInt8], within mask: [Bool]?) -> Float
}
```

  The harness loads the model once, clears to `charcoalPaperColor`, swaps B and R on readback when the format is a `bgra` one so `render` always returns R, G, B, A order, runs `configure` after `loadModel` (for outline flags on the swatch fixtures), uses `camera` in place of the framing when given, applies the Creator rig values from Task 1 Step 2, and frames body as eye (0, 0.85, 2.6) / target (0, 0.82, 0) and bust as eye (0.15, 1.38, 0.75) / target (0, 1.33, 0), 40° vertical FOV. `sampleCount > 1` goes through `RenderTestSupport.renderFrameMSAA`.

- [ ] **Step 0: Capture goldens of the twelve existing styles before touching any shader**

Write `MaterializationStyleGoldenTests` on the pattern of `MToonLegacyGoldenTests`: for each style with raw value 1 to 12, render `TestData/MToon/finish_swatches_skinned.vrm` (outlined single-sided scene, `enableMaterialization = true`, progress 0.45, seed 3, default colour, `heightRange` spanning the swatches' world Y extent) and compare with `golden_style_<raw>.rgba.zlib`, allowing a per-channel difference of at most 1. With `VMK_WRITE_MATERIALIZE_GOLDENS=<dir>` set it writes the files instead. Capture them now, on the untouched branch, and commit test and goldens together. This test must pass unmodified after every later task.

```bash
VMK_WRITE_MATERIALIZE_GOLDENS=Tests/VRMMetalKitTests/TestData/Materialize swift test --filter MaterializationStyleGoldenTests --disable-sandbox
swift test --filter MaterializationStyleGoldenTests --disable-sandbox   # expected: 12 pass
git add Tests && git commit -m "test(materialize): goldens for the twelve existing styles (#471)"
```

- [ ] **Step 1: Write the failing tests** in `CharcoalSketchTests.swift`

```swift
func testCharcoalConstants()                // style raw 13; hold 0.6; paper/ink/default colour values above;
                                            // requiresHostBackground true for charcoal, false for the other twelve
func testBoilPhaseEncodesAsOrdinaryFloat()  // boilPhase 1 -> 1.0, 65535 -> 65535.0, 65536 -> 0.0
func testInertAtFullProgress()              // render(charcoal(1.0)) == render(nil), byte for byte
func testStrippedWhenDisabled()             // enableMaterialization false: render(charcoal(0.3)) == render(nil)
func testBlankStartIsPaper()                // progress 0: max offLineDistance < 0.03 over every pixel
func testHoldFrameHasNoColour()             // progress 0.3 and 0.6: max offLineDistance < 0.03
func testColourArrivalIsMonotonic()         // for t in 0.6, 0.65 ... 1.0: count of pixels equal to plain,
                                            // restricted to pixels whose plain offLineDistance > 0.04, never drops by
                                            // more than 16 pixels between steps (hull rasterisation slack at size 512);
                                            // exactly 0 matches at 0.6, exactly all match at 1.0
func testDeterministic()                    // two render(charcoal(0.45)) calls are byte-identical
func testMismatchedHeightRangeStillEndsClean()  // heightRange 0.0...0.5: progress 1 == plain; progress 0.6 offLine < 0.03
func testHoldFrameHasNoColourOnSRGBTarget()     // pixelFormat .rgba8Unorm_srgb: progress 0.6 offLine < 0.03; progress 1 == plain
```

"Plain luma" and every colour comparison below use `CharcoalMeasure.colours` with the harness's format.

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter CharcoalSketchTests --disable-sandbox`
Expected: compile failure (`.charcoal` undefined).

- [ ] **Step 3: Implement the Swift API and upload**

Add the case, property, constants and `defaultColor` entry (1.0, 0.42, 0.10). The doc comment on `charcoalPaperColor` says hosts pass its components straight to `MTLClearColor` with no colour-space conversion. In the renderer, write `mat.encodedBoilPhase` into `materializeOrigin_packed.w`. `usesDiscard` stays true for charcoal.

Also make the upload itself conditional on `config.enableMaterialization`: when the flag is off, upload the inert sentinel `(1, 0, 0, 1)` whatever `materialization` holds. Today the uniforms are uploaded regardless, which is harmless only because the fragment is compiled out; Task 6 adds a vertex-stage reader with no function constant, and it must see the sentinel.

- [ ] **Step 4: Implement the timeline and a paper-only composite in the shader**

In `mat_resolve`, add `style == 13`:

```metal
const float drawBand = 0.35, colourBand = 0.25, fieldNoise = 0.06;
float n = (mat_vnoise(in.worldPosition.xz * 9.0 + in.worldPosition.yy * 6.0 + seed) * 2.0 - 1.0) * fieldNoise;
float f = mix(fieldNoise, 1.0 - fieldNoise, 1.0 - hNorm) + n;      // hNorm is already saturated
float tDraw = saturate(t / 0.6);
float tColour = saturate((t - 0.6) / 0.4);
float sDraw = saturate((tDraw * (1.0 + drawBand) - f) / drawBand);
float sColour = saturate((tColour * (1.0 + colourBand) - f) / colourBand);
st.sketch = 1.0;
st.sketchS = 0.6 * sDraw;
st.sketchReveal = smoothstep(0.05, 0.25, sColour);
st.sketchRevealSlow = smoothstep(0.10, 0.70, sColour);
st.sketchFront = sColour;
st.sketchEmberOn = any(uniforms.materializeColor.xyz > 0.0) ? 1.0 : 0.0;
```

Take `mat_vnoise` from the patch. `mat_sketchSurface` for this task returns `float4(mix(kSketchPaper, lit, mat.sketchReveal), alpha)` for opaque and cutout materials and `float4(lit, alpha * mat.sketchReveal)` for blended ones. Hull fragments (`isOutlineInstance`, and `mtoon_outline_fragment`) are discarded while `mat.sketchReveal < 1` in this task. Default-initialise the new `MatState` fields to the inert values (`sketch` 0, `sketchS` 0.6, reveals 1, `sketchFront` 1, `sketchEmberOn` 0).

- [ ] **Step 5: Rebuild shaders, update the hash, run tests**

Run: `make shaders && swift test --filter "CharcoalSketchTests|MaterializationTests|MaterializationStyleGoldenTests|MToonLegacyGoldenTests|MToonShaderGPUTests" --disable-sandbox`
Expected: all pass. `testEveryStyleAtMidProgressChangesFrame` passes for charcoal because the body is paper at 0.45.

- [ ] **Step 6: Commit**

```bash
git add Sources Tests && git commit -m "feat(materialize): charcoal style 13 timeline and paper composite (#471)"
```

---

### Task 3: Deposit model, contours, texture edges, construction dashes

Deliverable: contours and facial detail draw on with the drawing front; undrawn regions show faint dashes.

**Files:**
- Modify: `Sources/VRMMetalKit/Shaders/MToonShader.metal`
- Modify: `Tests/VRMMetalKitTests/CharcoalSketchTests.swift`

**Interfaces:**
- Consumes: `MatState.sketchS`, `mat_sketchSurface`, `CharcoalHarness`, `CharcoalMeasure`.
- Produces (shader): `mat_sketchBlotch(float2 px)`, `mat_sketchTooth(float2 px)`, `mat_sketchDeposit(float pressure, float tooth)`, `mat_sketchContourGate(float2 px, float s, float seed)`, `mat_sketchStrokeSeed(constant Uniforms&)` returning `materializeColor.w` (Task 7 adds the boil term). Every stroke noise takes its seed from `mat_sketchStrokeSeed`; the tooth takes none.

- [ ] **Step 1: Write the failing tests**

```swift
func testContoursDrawByHoldFrame()        // meanInk(render(charcoal(0.6)), within: silhouette) > 0.02
func testConstructionDashesAreFaint()     // progress 0: meanInk over the whole frame < 0.01 and > 0
func testFaceDetailIsDrawn()              // bust framing, progress 0.6, opaque materials only at this stage:
                                          // among silhouette pixels where the plain render's luma differs from a
                                          // 4-neighbour by > 0.25 (texture and shape edges), at least 30% have ink > 0.4
func testOrthographicContourDoesNotFlood() // orthographic body framing, progress 0.6: meanInk within silhouette
                                          // <= 1.5 * the perspective body framing's value at the same progress
```

`testBlankStartIsPaper` from Task 2 is replaced by `testConstructionDashesAreFaint`; keep the off-line assertion at progress 0 inside `testHoldFrameHasNoColour` by adding 0 to its progress list.

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter CharcoalSketchTests --disable-sandbox`
Expected: the four new tests fail (ink is 0 everywhere).

- [ ] **Step 3: Implement**

Take from the patch, unchanged unless noted: `mat_sketchBlotch`, `mat_sketchTooth`, `mat_sketchDeposit`, `mat_sketchLuma`, `mat_sketchContourGate`, and from `mat_sketchSurface` the contour, crease, `lineDropout`, `lineInk`, `gesture`, `texEdge` and `coverage` lines. Changes:
- Construction dashes are 0.19 ink (patch: 0.30).
- Under an orthographic projection (`uniforms.projectionMatrix[3][3] == 1.0`) `V` is the constant direction towards the camera, `normalize(float3(viewMatrix[0].z, viewMatrix[1].z, viewMatrix[2].z))`, not `mat_viewDir`.
- The grazing term is `abs(dot(N, V))`, never `saturate(dot(N, V))`, so the sign of `V` cannot zero it.
- `sketchColor = mix(kSketchPaper, kSketchInk, gesture)`, then `mix(…, kSketchInk, coverage)`, where `coverage = mat_sketchDeposit(max(lineInk, texEdge * drawn * 1.15) * 1.15, tooth)`.

- [ ] **Step 4: Rebuild shaders, update the hash, run tests**

Run: `make shaders && swift test --filter "CharcoalSketchTests|MaterializationTests|MaterializationStyleGoldenTests|MToonLegacyGoldenTests|MToonShaderGPUTests" --disable-sandbox`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests && git commit -m "feat(materialize): charcoal contours, texture edges and deposit model (#471)"
```

---

### Task 4: Tone, hatching, fill and smudge

Deliverable: the hold frame is a shaded drawing.

**Files:**
- Modify: `Sources/VRMMetalKit/Shaders/MToonShader.metal`
- Modify: `Tests/VRMMetalKitTests/CharcoalSketchTests.swift`

**Interfaces:**
- Consumes: Task 3 functions; `toonStep` is passed at the call site as `saturate(mat_sketchLuma(float3(lightingAcc)))`.
- Produces (shader): `mat_sketchHatch(float2 px, float angleDeg, float spacing, float weight, float seed)` returning stroke pressure.

- [ ] **Step 1: Write the failing tests**

```swift
func testHoldFrameIsShaded()         // meanInk(render(charcoal(0.6)), within: silhouette) > 0.20
func testShadingArrivesAfterContour() // body framing: meanInk within silhouette at 0.6 > 1.4 * the value at 0.25
func testDarkSurfacesDrawDarker()    // progress 0.6: mean ink over silhouette pixels whose plain luma < 0.05
                                     // exceeds mean ink over pixels whose plain luma > 0.5 by at least 0.29
func testHoldFrameOnVRM0Avatar()     // modelPath getTestVRM00ModelPath(): progress 1 == plain;
                                     // progress 0.6 offLine < 0.03 and meanInk within silhouette > 0.20
func testThumbnailSize()             // size 256: progress 0.6 offLine < 0.03 and meanInk within silhouette > 0.15
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter CharcoalSketchTests --disable-sandbox`
Expected: the new tests fail on the ink bounds.

- [ ] **Step 3: Implement**

Take `mat_sketchHatch` and, from the patch's `mat_sketchSurface`, the tone, `h1/h2/h3`, `w1/w2/w3`, hatch, smudge and fill lines exactly as the patch ends (spacing 7.0; thresholds 0.62, 0.50, 0.25; `albedoValue = smoothstep(0.15, 0.75, sqrt(albedoLuma))` at weight 0.8; fill `smoothstep(0.40, 1.0, dark) * 0.74`). `inkPressure = max(max(lineInk, texEdge * drawn * 1.15), max(hatch, fill)) * 1.15`. The smudge joins the grain-free layer: `mix(kSketchPaper, kSketchInk, max(smudge, gesture))`.

- [ ] **Step 4: Rebuild shaders, update the hash, run tests**

Run: `make shaders && swift test --filter "CharcoalSketchTests|MaterializationTests|MaterializationStyleGoldenTests|MToonLegacyGoldenTests|MToonShaderGPUTests" --disable-sandbox`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests && git commit -m "feat(materialize): charcoal tone, hatching, fill and smudge (#471)"
```

---

### Task 5: Blended overlays

Deliverable: lashes and brows are ink, eye highlights cut back to paper, blush waits for colour.

**Files:**
- Modify: `Sources/VRMMetalKit/Shaders/MToonShader.metal` (`mat_sketchSurface`, `isBlend` branch)
- Modify: `Tests/VRMMetalKitTests/CharcoalSketchTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func testBlendedDarkOverlaysDrawAsInk()
// bust framing. `eyeBand` is a pixel rectangle chosen once by inspecting the plain bust render so that it
// contains both eyes and no hair; record it as a constant with a comment naming the fixture.
// Inside eyeBand at progress 0.6: at least 60% of pixels whose plain linear luma < 0.05 have ink > 0.6.
// Inside eyeBand at progress 0.6: max offLineDistance < 0.03 (no blush tint).
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter testBlendedDarkOverlaysDrawAsInk --disable-sandbox`
Expected: FAIL on the 60% bound (Task 2 left blended overlays transparent).

- [ ] **Step 3: Implement the `isBlend` branch**

As in the patch: `highlight = albedoLuma > 0.75 && chroma < 0.12`; dark ink `smoothstep(0.30, 0.10, albedoLuma) * drawn`; highlight colour is paper at `alpha * drawn`; dark colour is ink at `alpha * mix(mat_sketchDeposit(darkInk, tooth), darkInk, 0.8)`; anything else has sketch alpha 0 and sketch colour `lit`, so only its alpha ramps and a tinted overlay never passes through grey or paper on the way in. Colour and alpha cross to `lit` and `alpha` with `mat.sketchReveal`.

- [ ] **Step 4: Rebuild shaders, update the hash, run tests**

Run: `make shaders && swift test --filter "CharcoalSketchTests|MaterializationTests|MaterializationStyleGoldenTests|MToonLegacyGoldenTests|MToonShaderGPUTests" --disable-sandbox`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests && git commit -m "feat(materialize): charcoal handling of blended overlays (#471)"
```

---

### Task 6: Outline hull on all three paths

Deliverable: contours carry charcoal weight; nothing changes for other styles or with the effect off.

**Files:**
- Modify: `Sources/VRMMetalKit/Shaders/MToonShared.h` (new `mtoonSketchHullBoost`, called from `applyMToonOutlineExtrusion`)
- Modify: `Sources/VRMMetalKit/Shaders/MToonShader.metal` (`mtoon_outline_vertex`, hull branch of `mat_resolve`, both outline colour sites)
- Modify: `Tests/VRMMetalKitTests/CharcoalSketchTests.swift`

**Interfaces:**
- Produces (shader): `static inline void mtoonSketchHullBoost(thread float4& clipPos, float3 worldPos, float3 worldNormal, float widthMask, constant Uniforms& uniforms)` in `MToonShared.h`; `mat_sketchOutlineColor(MatState, float3 outlineColor)` in `MToonShader.metal`.

- [ ] **Step 1: Write the failing tests**

```swift
func testHullWidensBeyondSilhouette()
// progress 0.6: count of pixels outside silhouette(plain) with ink > 0.5 is > 200 at size 512;
// progress 1.0: that count is 0.
func testHullRunsUnderMSAA()
// sampleCount 4: render(charcoal(0.6)) succeeds, offLine < 0.03, and the outside-silhouette ink count is > 0.
func testRigidOutlinedFixtureInks()
// TestData/MToon/finish_swatches.vrm through CharcoalHarness, passing the camera and a `configure` closure
// that reproduce MToonLegacyGoldenTests' outlined double-sided scene (dedicated hull): progress 0.6 has ink > 0.5 outside the plain silhouette;
// progress 1.0 is byte-identical to plain. Repeat with the single-sided scene (merged hull) and
// finish_swatches_skinned.vrm (skinned hull).
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter CharcoalSketchTests --disable-sandbox`
Expected: the three tests fail (Task 2 discards the hull during the sketch).

- [ ] **Step 3: Implement the vertex widening**

Take `mtoonSketchHullBoost` from the patch (2.0 to 6.5 px extra, growing in with `smoothstep(0.0, 0.3, sD)`, easing out with `1 - smoothstep(0.1, 0.7, sC)`), with these changes: compute `hNorm` with an explicit `saturate`; recompute `f` with the same `mix(0.06, 0.94, 1 - hNorm)` form as Task 2 (no noise term); retract the extra width earlier, with `1 - smoothstep(0.05, 0.45, sC)`, so the widened hull has left a surface before that surface settles to colour; return first when the style is not 13 or `progress >= 1`. Call it from both exits of `applyMToonOutlineExtrusion` (only when `outlineWidthFactor > 0`) and from `mtoon_outline_vertex` on its final clip position with that function's own `widthMask`.

- [ ] **Step 4: Implement the fragment side**

Replace Task 2's hull discard with the patch's hull branch of `mat_resolve` (coherent dashes ahead of the front via `mat_sketchBlotch`, tooth breakup once drawn, dropout fading with `sketchRevealSlow`), and return `mat_sketchOutlineColor(mat, outlineColor)` at both outline colour sites.

- [ ] **Step 5: Rebuild shaders, update the hash, run tests**

Run: `make shaders && swift test --filter "CharcoalSketchTests|MaterializationTests|MaterializationStyleGoldenTests|MToonLegacyGoldenTests|MToonShaderGPUTests|MToonMaterialLayoutReflectionTests" --disable-sandbox`
Expected: all pass, including the six unmodified legacy goldens.

- [ ] **Step 6: Commit**

```bash
git add Sources Tests && git commit -m "feat(materialize): charcoal-weight outline hull on all hull paths (#471)"
```

---

### Task 7: Colour arrival, ember ramp, settling lines, and line boil

Deliverable: the full effect.

**Files:**
- Modify: `Sources/VRMMetalKit/Shaders/MToonShader.metal`
- Modify: `Tests/VRMMetalKitTests/CharcoalSketchTests.swift`

**Interfaces:**
- Consumes: `MatState.sketchFront`, `sketchEmberOn`, `sketchReveal`, `sketchRevealSlow`, `mat_sketchStrokeSeed`.

- [ ] **Step 1: Write the failing tests**

```swift
func testEmberGlowsAtColourFront()   // progress 0.8: the default-colour frame differs from the color .zero frame
                                     // at > 100 pixels, and at those pixels its mean (R - B) is higher by > 0.2
func testEmberOffIsMonochrome()      // progress 0.8, color .zero: no pixel has (R - B) more than 0.05 above
                                     // both the paper's (R - B) and the plain render's (R - B) at that pixel
func testHeldSketchDoesNotGlow()     // progress 0.6: the default-colour frame is byte-identical to the
                                     // color .zero frame
func testBoilPhaseChangesStrokes()   // progress 0.6: render(boilPhase 1) != render(boilPhase 0);
                                     // two renders at boilPhase 1 are byte-identical
func testBoilStaysStableAtHighPhase() // progress 0.6: meanInk within silhouette at boilPhase 200 is within 10%
                                     // of the value at boilPhase 0
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter CharcoalSketchTests --disable-sandbox`
Expected: ember and boil tests fail.

- [ ] **Step 3: Implement the ember ramp and settling lines**

In `mat_sketchSurface`, with `sColour = mat.sketchFront`, after `mix(sketchColor, lit, reveal)`. The char rim, hot core and coal tail sit inside `if (mat.sketchEmberOn > 0.5 && sColour > 0.0)`, so the noise warp on the band edges cannot fire the char rim at the hold frame, where `sColour` is exactly 0:
- lines linger: `mix(c, kSketchInk, mat_sketchDeposit(lineInk, tooth) * 0.55 * reveal * (1 - settle))`;
- char rim over `sColour` 0.02 to 0.06 darkens towards (0.02, 0.015, 0.01);
- hot core over `sColour` 0.06 to 0.10 is `emberColor` pushed towards yellow-gold (default result (1.0, 0.80, 0.30)), coal tail over 0.10 to 0.18 is `emberColor` pulled to red-orange (default result (0.95, 0.25, 0.04)) fading into `lit`; band edges are warped by `mat_vnoise(px / 14.0)`.

Every stop is 0 at `sColour = 0` and at `sColour = 1`, so the hold frame and the finished frame carry no ember. Output stays `saturate`d.

- [ ] **Step 4: Implement boil**

`mat_sketchStrokeSeed` returns `materializeColor.w + float(uint(materializeOrigin.w + 0.5) & 63u) * 1.37`. The phase is wrapped to 64 steps so the value fed to `mat_hash21` stays small enough to keep its fractional bits; strokes therefore repeat every 64 steps (6.4 s at 10 steps a second). Confirm the tooth, blotch and field noise do not use it.

- [ ] **Step 5: Rebuild shaders, update the hash, run the whole suite**

Run: `make shaders && swift test --parallel --num-workers 14 -j 16 --disable-sandbox`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources Tests && git commit -m "feat(materialize): charcoal colour arrival, ember ramp and line boil (#471)"
```

---

### Task 8: Tuning against the relit reference, sanity renders, and wrap-up

Deliverable: a branch ready for Paul's eye and a PR.

**Files:**
- Modify: `Sources/VRMMetalKit/Shaders/MToonShader.metal` (constants only)
- Modify: `Tests/VRMMetalKitTests/CharcoalSketchTests.swift` (add the reference writer below)
- Modify: `AvatarSample_U.png`

- [ ] **Step 1: Add an env-gated reference writer**

```swift
func testWriteReferenceFrames()
// Skips unless CHARCOAL_REFERENCE_OUT is set. For each of AvatarSample_A_1.0, AvatarSample_A_0.0 and
// AvatarSample_U_1.0 that exists at the repo root, writes body and bust PNGs at size 1080 for
// progress 0, 0.15, 0.30, 0.45, 0.60, 0.70, 0.80, 0.90, 1.0 through CharcoalHarness.
```

- [ ] **Step 2: Tune three items against `_visuals_charcoal/relit/`**

Run: `CHARCOAL_REFERENCE_OUT=_visuals_charcoal/final swift test --filter testWriteReferenceFrames --disable-sandbox`, compare, adjust, repeat.
- Pale-fabric form-shadow smudge: target 24 to 26% with blotch modulation near the shadow edge; lit skin stays free of hatching.
- Ember: a crisp edge with a readable char rim, not a soft patch.
- Construction dashes: read as light layout lines.

Each adjustment is followed by `make shaders`, a hash update and the Task 7 Step 5 suite run.

- [ ] **Step 3: Run-once checks**

Render `AvatarSample_A_0.0.vrm.glb` and one avatar under 4x MSAA through the reference writer, and render 60 frames of `VRMA_01.vrma` on `AvatarSample_A_1.0` with `progress` ramping 0 to 1 and `boilPhase = frame / 6`. Expected: no Metal validation errors, no crashes, no frame with colour before 0.6. Note anything odd in the PR description.

- [ ] **Step 4: Sanity render**

Run: `swift run VRMRender AvatarSample_U_1.0.vrm.glb AvatarSample_U.png`
Expected: visually unchanged from the committed image (the effect is off in `VRMRender`).

- [ ] **Step 5: Commit and hand over**

```bash
git add Sources Tests AvatarSample_U.png && git commit -m "feat(materialize): tune charcoal against Creator's light rig (#471)"
```

Show Paul `_visuals_charcoal/final/` (`bust_t060`, `body_t030/060/080`). Push and open the PR ("Closes #471" on its own line) only when he asks.

---

## Measured baselines

Filled in by Task 1 Step 4 from the relit spike frames (`AvatarSample_A_1.0`, size 512, `.bgra8Unorm`).

| Statistic | Body | Bust |
| --- | --- | --- |
| Mean ink in silhouette, progress 0 | 0.0383 | 0.0092 |
| Mean ink in silhouette, progress 0.25 | 0.3067 | 0.4793 |
| Mean ink in silhouette, progress 0.6 | 0.6390 | 0.4899 |
| Mean ink over frame, progress 0 | 0.00484 | 0.00486 |
| Mean ink, dark plain pixels, progress 0.6 | 0.9351 | 0.9255 |
| Mean ink, pale plain pixels, progress 0.6 | 0.3470 | 0.2118 |
| Ink pixels outside silhouette, progress 0.6 | 3452 | 1644 |
| Largest off-line distance, progress 0.6 | 0.0037 | 0.0040 |
