# Starter craft: body basis, garments, face raster and hair

Extends §6 of `2026-09-12-mcp-authoring-loop-design.md` with the two items the
rating exposed that §6 does not cover (limb construction with hands and feet;
proportion fit against the style corpus), fixes one §6 acceptance that could
not hold as written (hair clump count versus a fixed spring chain count), and
adds the skirt clearance defect the stills show. Everything here is template,
wearable, raster and linter work; no control key, control range, camera,
threshold or scenario oracle changes.

## 1. What the rating measured (2026-09-12, female starter, seed 42)

Locked QA cameras, rest pose, against `AvatarSample_A_1.0.vrm.glb` and four
more VRoid bodies (`AvatarSample_U/K/H/O`, `vroid_default_F`). Skeleton
metrics from `scripts/style_lint.py measure`; girth is the mid-segment
silhouette extent of skin-role primitives divided by height.

| Metric (÷ height) | Starter | VRoid references | Read |
|---|---|---|---|
| shoulder_width_ratio | 0.175 | 0.103 – 0.135 | 35 % too wide |
| ipd_m | 0.0557 m | 0.029 – 0.031 m | measured, not comparable: VRoid eye bones sit inside small deep eyeballs behind a wide painted eye; here the globe is the visible eye and its spacing is the anime inner-corner gap, so `eyeSpacingFactor` stays 0.14 |
| arm_span_height_ratio | 0.722 | 0.628 – 0.720 | at the top of the envelope |
| neck girth | 0.080 | 0.039 – 0.060 (skin) | 45 % too thick |
| upper-arm girth (skin) | 0.061 | 0.039 – 0.096 | inside the envelope |
| thigh girth (skin) | 0.081 | 0.074 – 0.124 | inside the envelope |
| hips/leg heights, arm and leg ratios, head width, eye height in head | | | all inside |

So limb thickness is not the lever. What reads as "chunky" and "mannequin" in
the stills is construction, not girth: each limb is three overlapping lofts
whose end caps protrude at the elbow, wrist and knee (the "floating ring" at
the wrist is the forearm cap sitting proud of the palm), the torso's bottom
pole sits 0.025 H below the hips ring so `bottom-v1` shells it into a crotch
spike, the leg has no knee narrowing or calf, the feet are undifferentiated
blobs, and the shoulders and neck are wide. The hand already has four fingers
and a thumb; from the front camera a T-pose hand is an edge-on blade on every
VRoid reference too, so the fix is a continuous forearm→palm loft with a
knuckle line and a fanned finger layout, not a new hand basis.

Garments: the skirt's cone is narrower than the thigh tops at the thigh-root
height, so the thighs poke through as skin patches; `OutfitPresets.clearance`
cannot see it because the thigh and torso lofts overlap and
`BodyComponents.fused` exempts fused parts. The top's crew band rises but
does not lean in, so the neckline shows the shell's dark back faces. Cloth
textures carry a 256-cycle weave that aliases into moiré at the QA camera
distance. The mouth raster paints its cavity out to UV radius 0.30 while the
inner lip ring sits at radius 0.10 at the lip centre, so the lips read as a
dark painted blob at rest; blush is a saturated 16 % disc.

Hair: ring A (22°) and ring B (50°) leave the crown bare above ~60°
elevation; the highlight band is at strip V = 0.3 on every clump regardless
of root height, so it appears as pale streaks at different heights.

## 2. Body basis (new; not in §6)

### 2.1 Continuous limbs

`NativeAnimeBodyBuilder` lofts each arm as one ring table from inside the
torso to the knuckle line and each leg as one ring table from inside the hips
to the ankle. Ring regions keep the existing names (`upperArmL`, `forearmL`,
`handL`, `thighL`, `shinL`, …) so no control mask, weight table, wearable
region or preset changes. The only poles are inside the torso/hips, at the
knuckle line (inside the finger bases), at fingertips, and inside the foot.
The foot stays its own loft along +Z, narrowed and shaped (heel, arch, toe
box). The torso's bottom pole moves to 0.006 H below the hips ring.

Ring radii, as fractions of stature H (left arm, `s` = side sign):

| Arm ring at x | ry | rz | region |
|---|---|---|---|
| upperArm.x − 0.030 H | 0.026 | 0.031 | upperArm |
| upperArm.x + 0.030 H | 0.029 | 0.030 | upperArm |
| lerp(upperArm, lowerArm, 0.55) | 0.027 | 0.027 | upperArm |
| lowerArm.x − 0.012 H | 0.024 | 0.024 | upperArm |
| lowerArm.x + 0.012 H | 0.024 | 0.024 | forearm |
| lerp(lowerArm, hand, 0.40) | 0.023 | 0.024 | forearm |
| lerp(lowerArm, hand, 0.80) | 0.017 | 0.019 | forearm |
| hand.x − 0.006 H | 0.014 | 0.017 | forearm |
| hand.x + 0.10 hl | 0.011 | 0.024 | hand |
| hand.x + 0.30 hl | 0.010 | 0.032 | hand |
| hand.x + 0.48 hl | 0.009 | 0.034 | hand |

Caps: start at upperArm.x − 0.045 H, end at hand.x + 0.52 hl (hl = hand length).

| Leg ring at y | rx | rz | region |
|---|---|---|---|
| upperLeg.y + 0.035 H | 0.045 | 0.049 | thigh |
| upperLeg.y − 0.030 H | 0.046 | 0.050 | thigh |
| lerp(upperLeg, lowerLeg, 0.55) | 0.040 | 0.043 | thigh |
| lowerLeg.y + 0.020 H | 0.034 | 0.036 | thigh |
| lowerLeg.y − 0.020 H | 0.033 | 0.035 | shin |
| lerp(lowerLeg, foot, 0.35) | 0.035 | 0.040 | shin |
| lerp(lowerLeg, foot, 0.75) | 0.026 | 0.028 | shin |
| foot.y + 0.005 H | 0.019 | 0.021 | shin |

Caps: start at upperLeg.y + 0.050 H, end at foot.y − 0.020 H (inside the foot).

Foot rings along z (centre y = ry so the sole touches y = 0):
(−0.030 H: rx 0.022, ry 0.024), (0: 0.026, 0.030), (0.040 H: 0.027, 0.024),
(0.080 H: 0.028, 0.016), (0.115 H: 0.024, 0.010); caps at (0.022 H, −0.040 H)
and (0.008 H, 0.130 H).

Fingers fan in the palm plane: index +8°, middle +3°, ring −3°, little −8°
toward +Z, roots at z = +0.018 / +0.006 / −0.006 / −0.018 H (wide enough that
neighbouring fingers no longer fuse at the base), lengths 0.36 / 0.40 / 0.37 /
0.30 hl from the knuckle line at hand.x + 0.50 hl, radii 0.0055 / 0.0058 /
0.0054 / 0.0047 H with a knuckle
bulge ring (×1.15) 0.04 hl behind the base and joint rings at ×0.92 and
×0.80; tip cap 0.09 hl past the distal joint. The rig's finger joints follow
the same fan (`NativeAnimeLayout`). The thumb roots at hand.x + 0.20 hl,
z = 0.020 H, and points along normalize(s·0.5, −0.15, 1).

Acceptance (geometric, Metal-free): no arm vertex outboard of the shoulder
joint and no leg vertex between the hip joint and 0.01 H above the ankle lies
within 0.003 H of its limb axis (no internal cap poles); the leg's minimum
radius between hip and ankle is at the knee ring and the calf ring is wider
than the knee; the four fingertips' z spread exceeds 0.040 H and adjacent middle joints are further apart in z than the sum of their radii; the foot's
widest ring is under 0.058 H across; `testBodyWeightsFollowRegions`,
`testEveryControlMovesItsRegionsAndNothingElse` and the outfit suites keep
passing; body+head triangles stay within 4000–8000.

### 2.2 Proportion fit

Constants in `NativeAnimeLayout` and `NativeAnimeBodyBuilder` move onto the
corpus medians recorded in the profile's rule provenance (eye spacing is
deliberately left alone, see §1):

| Constant | Was | Now | Target metric |
|---|---|---|---|
| `shoulderHalfWidthFactor` | 0.09 | 0.064 | shoulder_width_ratio 0.128 (median 0.134) |
| neck radius | 0.040 H | 0.030 H | neck girth 0.06 |
| chest rings rx | 0.084 / 0.078 | 0.072 / 0.068 | chest silhouette ≈ 0.145 |
| waist ring rx | 0.073 | 0.064 | |
| arm lengths | unchanged | | arm_span 0.128 + 2 × 0.275 = 0.678 (median 0.673) |

The linter gains skin-role girth metrics (`girth.upper_arm_ratio`,
`girth.lower_arm_ratio`, `girth.thigh_ratio`, `girth.shin_ratio`,
`girth.neck_ratio`: max silhouette extent of skin-role vertices dominated by
the bone, taken over the middle 30 % of the bone segment, divided by height)
and the profile four `should` rules over them with corpus provenance
regenerated by `envelopes --write`. Profile version becomes 0.2.0.

Acceptance: a Swift test computes every `proportions.*` metric the layout can
evaluate from bones (shoulder width, arm span, hips/leg heights, arm and leg
ratios, ipd) for the pack default and both starters and asserts each lies
inside `[min, max]` of the corresponding rule's provenance in the pinned
profile; a python unit test measures the female starter's exported VRM and
asserts every girth metric lies inside its rule's provenance range. The
linter and profile hash pins move (see plan Task 3).

## 3. Garments (extends §6 items 1 and 4)

### 3.1 UV islands and trim islands

Garment shells no longer copy body UVs verbatim. Each cloth image is laid out
as named islands; the shell remaps `(u, v)` of every vertex into its region's
island and trim bands (collar, cuffs, hem, skirt hem) take UVs in a shared
trim strip. Layouts (u0, v0, u1, v1):

| Kind | Islands |
|---|---|
| top | torso (0, 0, 0.5, 0.9) for chest/torso/waist/hips; upperArmL (0.5, 0, 0.75, 0.45); upperArmR (0.75, 0, 1, 0.45); forearmL (0.5, 0.45, 0.75, 0.9); forearmR (0.75, 0.45, 1, 0.9) |
| bottom | waistHips (0, 0, 0.5, 0.45); skirt (0, 0.45, 0.5, 0.9); thighL (0.5, 0, 0.75, 0.45); thighR (0.75, 0, 1, 0.45); shinL (0.5, 0.45, 0.75, 0.9); shinR (0.75, 0.45, 1, 0.9) |
| footwear | footL (0, 0, 0.5, 0.9); footR (0.5, 0, 1, 0.9) |
| all | trim (0, 0.9, 1, 1) |

Region lookup folds `torso` into the torso island for tops and into
`waistHips` for bottoms, because the native host tags every torso-loft vertex
`torso` and the compiler's region map reports that name first.

`GarmentInfo.uvIslands` records the islands a garment used. The cloth raster
is flat base colour with a 3-cycle ±2 % tone drift (no weave), the trim strip
at 0.80 × base with a one-texel-row lighter stitch line at v = 0.92, and a
2 % darker seam line along each island's u = 0 column.

Acceptance: every garment vertex's UV lies inside exactly one of its kind's
islands (trim vertices inside trim); islands of one kind never overlap; the
raster's mean luminance inside the trim strip is below 0.85 × the torso
island's; `visual.threeQuarter` (Metal, skipped without a device) shows a run of
≥ 5 rows darker than the cloth mean above it at the projected hem height (a
0.015 m band is about 8 rows at the locked camera).

### 3.2 Skirt clearance profile

`buildSkirt` uses six rings; ring radius at height y is
`max(cone(t), bodyRadius(y) + offset + 0.010)` where `bodyRadius(y)` is the
largest |x| (and |z|) over waist, hips, thigh and shin vertices within
±0.02 m of y. Skinning is unchanged.

Acceptance: on `NativeAnimeFixture.integrated` with the female starter's
outfit, for every skirt ring the ring's rx and rz exceed the body's silhouette
extent at that height by ≥ `minClearanceM`; the `SyntheticHost` skirt tests
keep passing.

### 3.3 Closed collar (§6 item, unchanged intent)

In `addTrimBands` the collar's outer row leans inward by
`max(gap − 0.002, 0) × frontness` where `gap` is the rim's horizontal radius
minus the neck's radius at rim height. `GarmentInfo.collarGapM` records the
worst remaining front gap. Acceptance: `collarGapM ≤ 0.002` for the default
outfit on the native host and no band vertex inside the neck shell; the
`visual.front` luminance-run check from §6 (Metal, skipped without a device).

## 4. Face raster (§6 item, made concrete)

Mouth: cavity fill only for r < 0.20 (feather 0.05), lip band from r = 0.22
to 0.50 in the lip colour, seam and corner darkening unchanged; lip base
colour sRGB (232, 168, 158). The inner lip ring's UVs move from radius 0.10
to 0.30 at the lip centre and the cavity-front ring from 0.30 to 0.22, so the
visible lip quad samples the band and only the mouth interior samples cavity. Blush strength 0.16 → 0.09, radius 0.040 →
0.050. Iris and pupil sizes are geometric already (the iris UV region is
static by contract); the acceptance is a test that the iris ring polar angle
grows monotonically with `face.iris.{side}.size`. Acceptance for the raster:
the mouth pixel at UV radius 0.28 on the vertical axis is within 12 % of the
lip colour, not the cavity colour; `style.lint` stays conforming.

## 5. Hair (§6 item, contradiction resolved)

§6 asked to raise the clump count while keeping 40 spring chains. Both hold
only if the added clumps are rigid: a scalp-cap set (ring at 66° elevation,
10 clumps; crown ring at 80°, 4 clumps) skinned 100 % to the head bone with
no nodes and no springs, traced with the same strip machinery at
0.45 × lengthM and 1.6 × base width. `HairClumpInfo.isRigid` marks them.
Ring A, ring B and the bangs are unchanged; `hairClumps.count` becomes
40 + 14 for bob and long, ponytail adds none.

Highlight: `hairRaster` becomes eight columns of 128 px; column 0 carries no
highlight and columns 1–7 carry the band at v = 0.08 + 0.84 (k − 1) / 6.
Strip u becomes (column + u_local) / 8. Each clump selects the column whose
band v is nearest the section where the strip's centre line crosses
`headCentre.y + 0.50 × headRadius`, or column 0 when it never does.
`HairClumpInfo.highlightColumn` records the choice.

Acceptance: for scalp samples above 35° elevation the nearest hair surface to
`sample + 0.006 × normal` is within 0.012 m for ≥ 97 % of samples; for every
clump with column > 0 the strip vertex nearest the column's band v lies
within 0.02 m of the target height; spring count and every existing hair test
hold; `visual.front` / `visual.threeQuarter` scalp-hue ratio inside the hair
silhouette < 2 % (Metal, skipped without a device).

## 6. Out of scope

Expression strength (`happy` lid closure, mouth corners) is a morph-basis
change and stays open. Layered accessories (belts, cuffs beyond trim bands,
socks) are not planned. No new control keys; the female and male starter
override tables are unchanged.

## 7. Pins that move

Any geometry change moves `TemplatePackTests.goldenDefaultBuildHash`. The
linter/profile edit moves `QAPins.styleLinterSha256`,
`QAPins.defaultProfileSha256`, `StyleToolchain.pinnedLinterSHA256`,
`StyleToolchain.pinnedProfileSHA256`, the two hash lines in
`docs/proposals/vrm-author-cli/README.md` and `verification.md`, the
`oracleHashes` entries of the six packs that embed them, and
`docs/style/corpus/vroid-lineage-anime.witnesses.native-anime-v1.json`
(regenerated). Every edited test file re-pins its packs through
`scripts/repin_packs.py`.
