<!--
Copyright 2026 Arkavo
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at https://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software distributed
under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied. See the License for the
specific language governing permissions and limitations under the License.
-->

# Reserved VRMAuthor parameter designs

Design sketches for [reserved commands](reserved.md), retained for future advanced
mesh, strand, garment and adapter work. These are not the native v1 contract or a
promise of exact VRoid slider parity. [parameters.md](parameters.md) is the v1
allowlist and overrides overlapping definitions here. “Complete,” “guaranteed,”
and “must” below apply only to a future capability that adopts the corresponding
sketch, never to the v1 release. Release-specific VRoid comparisons remain internal and are tracked by agents per
release. Every adopted operation must first satisfy [verification.md](verification.md).

## 1. Types, defaults and extension completeness

`!` means required; `?` means optional and absent unless supplied. `=x` is a proposed
native default. Any required/default field shown here must appear in the runtime
schema, including its physical unit and export disposition. Nested object defaults
apply recursively. IDs always reference project objects; the compiler resolves
indices only when writing glTF/VRM.

| Type | Definition |
|---|---|
| `B` | Native bipolar blend control, finite [-1,1], default 0; endpoints are the template's calibrated shapes |
| `U` | Finite normalized scalar [0,1]; default must be given by field or rule below |
| `M` / `M+` | Metres, finite / strictly positive; `M0` allows zero |
| `Deg` | Finite degrees; no implicit radians |
| `Rad` | Finite radians; standard fields whose units are radians retain this unit |
| `Scale` | Finite positive scale, default 1 |
| `V2`, `V3`, `V4` | Finite number arrays of exactly 2, 3, 4 components; field declares units |
| `Quat` | Unit quaternion `[x,y,z,w]`, default `[0,0,0,1]` |
| `ID` / `ID[]` | Stable object reference / ordered list of references; not a display name |
| `Colour` | `{rgba:V4!, space:linear\|srgb=linear}`; values [0,1], alpha unpremultiplied; HDR fields explicitly permit RGB>1 |
| `Curve<T>` | `{knots:[{t:U,value:T}]!, interpolation:linear\|monotone-cubic=linear}`; increasing knots including 0 and 1 |
| `Transform` | `{translation:V3=[0,0,0], rotation:Quat=identity, scale:V3=[1,1,1]}`; metres, positive scale |
| `Space` | `world`, `avatar`, `local`, or `{node:ID}`; UV/surface coordinates use dedicated types |
| `Plane` | `{origin:V3!, normal:V3!}`; metres and unit normal |
| `SurfacePoint` | `{mesh:ID!, triangle:ID!, barycentric:V3!, normalOffsetM:M=0}`; barycentric sum=1, each [0,1] |
| `SurfacePath` | `{points:SurfacePoint[]!, closed:bool=false}` |
| `JsonPointer` | Escaped RFC 6901 path; writable paths restricted to registered schema |
| `PointerValueMap` | Map of JSON pointers to typed JSON values |
| `JsonPatch` | RFC 6902 operation; IDs/references validated after the complete atomic patch |
| `ControlValues` | Map of registered control keys to typed values, usually numeric or curves |
| `ExpressionWeights` | Map of expression IDs/preset names to U values |
| `MaterialRole` | `face_skin`, `body_skin`, `hair`, `cloth`, `accessory`, `iris`, `eye_white`, `eye_highlight`, `eyeline`, `eyelash`, `brow`, `mouth`, `other` |

Object base fields are `id:ID!`, `name:string=""`, `tags:string[]=[]`,
`enabled:bool=true`, `visibleInEditor:bool=true`, `exportEnabled:bool=true`,
`provenance:Provenance?`, `extras:object={}`. Visibility and export inclusion are
separate, so hiding a debugging object does not accidentally change an export.
Nodes additionally have `parent:ID?`, `transform:Transform=identity`, `children:ID[]=[]`.
Topological and binary data travel as `Blob={path:string!, sha256:string!,
encoding:json|f32le|u16le|u32le|png|jpeg|exr!, shape:int[]?}`.

Defaults designated `template` are **required explicit values in the pinned template
pack**, returned by `recipe inspect --resolved`. The engine must reject a template
missing them. They are not inferred afresh during a build. Hard validity ranges,
recommended template ranges and empirical style ranges are distinct fields.

### Guaranteed low-level coverage

For pinned glTF 2.0, `VRMC_vrm`, `VRMC_materials_mtoon`, `VRMC_springBone`,
`VRMC_node_constraint` and opted-in extensions, every schema property at every nesting
level is addressable through `document patch`, including `extensions` and `extras`.
`schema coverage` must enumerate the resolved leaf paths, type/default/bounds,
reference handling and serialization tests; an omitted semantic control cannot make
a standard field unwritable. Binary buffer/accessor edits use typed `Blob` and
`GeometryPatch` data and rebuild offsets/alignment rather than exposing unsafe byte
patches. Standard required/optional semantics are preserved.

glTF coverage includes asset/version, scenes/default scene, nodes/TRS or matrices,
meshes/primitives/modes/materials/morph weights, all attributes and indices, skins/joints/
inverse binds, buffers/views/accessors/normalized/sparse data, images/textures/samplers,
materials, cameras and animation channels/samplers. `extensionsUsed` and
`extensionsRequired` are compiled from actual payloads and target policy. Local node
matrices and TRS cannot coexist. Standard material defaults and valid names are
defined by [glTF 2.0](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html).

## 2. Recipes, controls and reusable items

`Recipe` contains:

```text
recipeVersion:string="1.0"
name:string!
target:Target=portable-vrm1
seed:uint64=0
template:{id:ID!,version:string!,sha256:string!}!
profile:{path:string!,sha256:string!}?
metadata:MetaConfig!
body:ControlValues={}
face:ControlValues={}
rig:RigConfig=template
hair:HairRecipe[]=[]
garments:GarmentConfig[]=[]
accessories:AccessoryConfig[]=[]
materials:MaterialConfig[]=template
textures:TextureConfig[]=template
expressions:ExpressionGeneratorConfig=template
lookAt:LookAtConfig=template
firstPerson:FirstPersonAnnotation[]=template
physics:PhysicsPreviewConfig=template
quality:QaPlan=template
constraints:Goal[]=[]
budgets:ResourceBudget=template
```

`HairRecipe={id:ID!, scalp:ScalpConfig!, guide:HairGuideConfig!,
group:HairGroupConfig!, mesh:HairMeshConfig!, texture:HairTextureConfig!,
rig:HairRigConfig?}`. Cross-references may point forward within a recipe; validate
and resolve the entire graph before creating anything. `recipe apply` merges by ID,
leaving manually edited objects intact unless their replacement is explicit.

`ControlDescriptor` fields: `key`, `label`, `description`, `domain`, `type`, `unit`,
`default`, `hardMin`, `hardMax`, `recommendedMin`, `recommendedMax`, `step`,
`allowExtrapolation`, `side`, `mirrorKey`, `mirrorSign`, `coordinateSpace`,
`affects`, `invalidates`, `requires`, `exportDisposition`, `source`, `sourceVersion`,
`evidence`, `mappingStatus`. The first six plus `default`, `affects`, `invalidates`,
`exportDisposition`, `source`, `mappingStatus` are required; others are conditional.
`exportDisposition` is `baked`, `vrm-field`, `gltf-field`, `extension`, `preview-only`.

`ControlBinding={type:morph|landmark|bone|generator|texture|material|composite!,
targets:ID[]!, response:Curve<number>?, field:JsonPointer?, basis:Blob?,
dependencies:string[]=[], constraints:Goal[]=[]}`. The descriptor's unit determines
the curve's output unit. Control probes must demonstrate a nonzero intended effect.
Unsupported or unmapped controls return errors instead of accepting inert values.

Control maps use fully qualified keys, even inside `Recipe.body` or `Recipe.face`:
for example `{"body.heightM":1.65}`. `rangePolicy=extrapolate` may exceed a recommended
range only when the descriptor permits it and the value remains within hard bounds.

### Universal object payloads

`ObjectData` is a discriminated union selected by `object create.kind`. Base fields
apply everywhere. References to a `Config` mean exactly the fields listed in its
table, not an additional freeform parameter bag. The following fills in the stored
object shapes not already specified by dedicated payloads elsewhere in this catalog.
Stored IDs are required; creation can omit the ID to request a generated one, or
supply it once in the outer command. All references resolve to the assigned ID.

| Kind | Data in addition to base fields |
|---|---|
| avatar | `root:ID!`, `bodyMeshes:ID[]=[]`, `humanBones:HumanoidMap={}`, `metadata:MetaConfig?`, `lookAt:LookAtConfig?`, `firstPerson:FirstPersonAnnotation[]=[]`, `controls:ControlValues={}` |
| node | Node fields from section 1; `mesh:ID?`, `skin:ID?`, `camera:ID?`, `weights:number[]=[]` |
| mesh | `geometry:GeometryPatch!`, `regions:{name:ID}={}`, `materials:ID[]=[]`, `modifiers:ID[]=[]`, `morphs:ID[]=[]`, `skin:ID?` |
| selection / landmark | Selection: `mesh:ID!`, `query:Selector!`, `topologyRevision:int!`, `resolvedIds:ID[]!`; landmark: `attachment:SurfacePoint?`, `position:V3!`, `space:Space=avatar`, `semantic:string!` |
| cage | `mesh:ID!`, `targets:ID[]!`, `coordinates:Blob!`, `method:harmonic\|mean-value=harmonic` |
| skin | `mesh:ID!`, `joints:ID[]!`, `inverseBinds:Blob!`, `weights:Blob!`, `bindPose:ID!`, `config:SkinConfig!` |
| morph | `mesh:ID!`, `deltas:MorphPatch!`, `defaultWeight:number=0`, `semantic:string?` |
| image | `source:Blob?`, `width:int>0!`, `height:int>0!`, `colourSpace:linear\|srgb!`, `layers:ID[]=[]`, `channelFormat:rgba8\|rgba16f\|rgba32f=rgba8` |
| texture | `image:ID!`, `sampler:ID?` |
| hair-bone-group | `clumps:ID[]!`, `axis:ID!`, `bones:ID[]!`, `config:HairRigConfig!`, `spring:ID?` |
| collider-group | `colliders:ID[]!`; node links belong to individual colliders |
| pose | `space:local\|world=local`, `nodes:{id:Transform}!`, `expressions:ExpressionWeights={}`, `timeSeconds:number>=0=0` |
| animation | `samplers:[{id:ID,input:Blob,output:Blob,interpolation:LINEAR\|STEP\|CUBICSPLINE}]!`, `channels:[{sampler:ID,node:ID,path:translation\|rotation\|scale\|weights}]!`, `sourceRest:ID!` |
| style-binding | `profilePath:string!`, `profileSha256:string!`, `roles:RoleMap!`, `goals:Goal[]=[]` |
| reference | `source:Blob!`, `type:image\|mesh\|measurements!`, `view:ViewSpec?`, `landmarks:LandmarkTarget[]=[]`, `purpose:string!`, `weight:number>=0=1` |
| template | `version:string!`, `objects:ID[]!`, `controls:ControlDescriptor[]!`, `bindings:ControlBinding[]!`, `defaults:object!`, `dependencies:{id,version,sha256}[]=[]`, `tests:ID[]!` |

Bone, modifier, expression, constraint, material, sampler, texture-layer, decal,
hair-scalp/guide/group/clump, garment, accessory, spring/joint/collider, camera,
light, environment, scenario and QA policy use their corresponding config/object
definitions. A `pattern` stores `PatternConfig`; a `seam` stores one seam record.
`qa-policy` stores `QaPlan` and its concrete thresholds. For mutation, required fields
may be omitted only if the stored object already has them.

Native templates expose the following complete semantic control groups. Every leaf
in the lists marked `B` is an independent B control, default 0. For paired anatomy,
`{L,R}` expands to `.left` and `.right`; an optional symmetry link initially ties
the two and can be disabled. Each pack must supply calibrated endpoint geometry.

## 3. Body, head and face shape controls

### Body controls

| Prefix | Fields and types |
|---|---|
| `body` | `heightM:M+=1.65`, `headCount:number>0=6.3`, `symmetry:bool=true`, `headScale:Scale=1` |
| `body.proportion` | B: `torsoLength`, `legLength`, `armLength`, `shoulderWidth`, `hipWidth`, `waistHeight`, `crotchHeight`, `neckLength`, `neckWidth`, `neckDepth` |
| `body.torso` | B: `chestWidth`, `chestDepth`, `ribcageWidth`, `ribcageDepth`, `waistWidth`, `waistDepth`, `abdomenDepth`, `abdomenWidth`, `backWidth`, `backCurve`, `shoulderSlope`, `trapeziusVolume`, `clavicleProminence` |
| `body.chest.{L,R}` | B: `volume`, `height`, `lateralOffset`, `projection`, `baseWidth`, `baseHeight`, `upperFullness`, `lowerFullness`, `separation` |
| `body.pelvis` | B: `width`, `depth`, `height`, `gluteVolume`, `gluteHeight`, `gluteSeparation`, `crotchWidth` |
| `body.arm.{L,R}` | B: `upperLength`, `lowerLength`, `upperWidth`, `upperDepth`, `forearmWidth`, `forearmDepth`, `elbowWidth`, `wristWidth`, `wristDepth`, `muscleDefinition` |
| `body.leg.{L,R}` | B: `thighLength`, `shinLength`, `thighWidth`, `thighDepth`, `kneeWidth`, `kneeHeight`, `calfWidth`, `calfDepth`, `calfHeight`, `ankleWidth`, `ankleDepth`, `legGap`, `bow` |
| `body.hand.{L,R}` | B: `length`, `width`, `depth`, `palmLength`, `knuckleVolume`; `finger.{thumb,index,middle,ring,little}.{length,width,taper,spread}:B=0` |
| `body.foot.{L,R}` | B: `length`, `width`, `height`, `heelWidth`, `archHeight`, `toeLength`, `toeSpread`, `bigToeLength` |
| `body.surface` | B: `muscleDefinition`, `bodyBulk`, `fatDistribution`, `clavicleSmooth`, `chestSmooth`, `navelDepth`, `torsoSmooth`, `gluteSmooth`, `thighGapSmooth` |

Height and head count are physical targets solved after normalized controls. If they
conflict with locked limb lengths or other exact constraints, return an unsatisfiable
constraint report. A pose parameter cannot be used to fake a required T-pose ratio.

### Head and face controls

| Prefix | Fields and types |
|---|---|
| `head` | B: `width`, `height`, `depth`, `craniumWidth`, `craniumHeight`, `craniumDepth`, `faceHeight`, `foreheadHeight`, `foreheadSlope`, `templeWidth`, `occiputVolume` |
| `face` | `symmetry:bool=true`; B: `width`, `depth`, `verticalPosition`, `upperFaceLength`, `midFaceLength`, `lowerFaceLength`, `flatness` |
| `face.jaw` | B: `width`, `angle`, `height`, `depth`, `cornerHeight`, `cornerRoundness` |
| `face.chin` | B: `width`, `height`, `projection`, `pointedness`, `cleft`, `roundness` |
| `face.cheek.{L,R}` | B: `boneHeight`, `boneWidth`, `projection`, `fullness`, `lowerVolume`, `nasolabialDepth` |
| `face.ear.{L,R}` | B: `size`, `height`, `horizontalPosition`, `depth`, `outwardAngle`, `tilt`, `lobeSize`, `tipLength`, `tipPointedness` |
| `face.eye.{L,R}` | B: `width`, `height`, `spacing`, `verticalPosition`, `depth`, `tilt`, `innerCornerHeight`, `outerCornerHeight`, `innerCornerSharpness`, `outerCornerSharpness`, `upperLidCurve`, `lowerLidCurve`, `foldHeight`, `foldDepth`, `socketDepth`, `bulge` |
| `face.eyeball.{L,R}` | `radiusM:M+=template`, `depthScale:Scale=1`, `pivotOffsetM:V3=[0,0,0]`, `corneaBulgeM:M0=0`, `lidClearanceM:M0=0.0005` |
| `face.iris.{L,R}` | B: `size`, `width`, `height`, `horizontalPosition`, `verticalPosition`; `rotationDeg:Deg=0`, `pupilRatio:U=0.35`, `pupilAspect:Scale=1` |
| `face.highlight.{L,R}` | `enabled:bool=true`, `count:int>=0=1`, `size:Scale=1`, `position:V2=[0,0]`, `rotationDeg:Deg=0`, `shape:round\|star\|heart\|custom=round`, `texture:ID?` |
| `face.sclera.{L,R}` | B: `exposure`, `upperShadow`, `lowerShadow`; `tint:Colour=white`, `veinOpacity:U=0` |
| `face.brow.{L,R}` | B: `height`, `spacing`, `length`, `thickness`, `tilt`, `arch`, `innerHeight`, `outerHeight`, `depth`, `taper` |
| `face.eyeline.{L,R}` | B: `upperThickness`, `lowerThickness`, `innerExtension`, `outerExtension`, `wingLength`, `wingAngle`, `depthOffset` |
| `face.lash.{L,R}` | B: `length`, `thickness`, `curl`, `fan`, `upperDensity`, `lowerDensity`; `count:int>=0=template` |
| `face.nose` | B: `height`, `width`, `projection`, `bridgeHeight`, `bridgeWidth`, `bridgeCurve`, `tipSize`, `tipHeight`, `tipAngle`, `nostrilWidth`, `nostrilHeight`, `nostrilFlare`, `rootDepth` |
| `face.mouth` | B: `width`, `height`, `verticalPosition`, `projection`, `cornerHeight`, `cornerDepth`, `upperCurve`, `lowerCurve`, `philtrumLength`, `philtrumDepth`, `restOpen` |
| `face.lip` | B: `upperThickness`, `lowerThickness`, `cupidBow`, `cornerWidth`, `projection`, `edgeSharpness` |
| `face.teeth` | `enabled:bool=true`; B: `upperLength`, `lowerLength`, `width`, `spacing`, `canineLength`, `canineSharpness`, `fangLeft`, `fangRight`; `upperCount:int>=0=template`, `lowerCount:int>=0=template` |
| `face.tongue` | `enabled:bool=true`; B: `width`, `length`, `thickness`, `restHeight`, `tipShape` |
| `face.mouthInterior` | `enabled:bool=true`; B: `cavityDepth`, `cavityWidth`, `throatOpening`, `gumHeight` |

Face/eye sets are reusable item collections referencing the above geometry and texture
objects. Skin, cheek cosmetics, lips and face paint use texture layers, not hidden
mesh-only sliders. Every eye/brow/lash/mouth layer has its own explicit material role.
This matches the functional categories documented in [VRoid's face editor](https://vroid.pixiv.help/hc/en-us/articles/4406164546969);
the native anatomy controls above are proposed independently.

## 4. Mesh, selection and deformation payloads

`Selector` is a declarative expression with `kind:vertex|edge|face|object!` and one
or more of `ids`, `region`, `material`, `role`, `tags`, `boneWeight:{bone,min,max}`,
`box:{min,max,space}`, `sphere:{center,radiusM,space}`, `normalCone:{axis,angleDeg}`,
`uvBox`, `boundary:bool`, `connectedTo:ID`, `geodesic:{seed,distanceM}`,
`union`, `intersect`, `subtract`, `invert`. Selection results include a topology
revision and fail if used after an unmapped topology edit.

| Payload | Complete fields |
|---|---|
| `Primitive` | `type:plane\|box\|uv-sphere\|icosphere\|cylinder\|cone\|capsule\|torus\|grid!`, `sizeM:V3=[1,1,1]`, `radiusM:M+=0.5`, `depthM:M+=1`, `majorRadiusM:M+=0.5`, `minorRadiusM:M+=0.1`, `segments:int>=3=16`, `rings:int>=2=8`, `subdivisions:int>=0=2`, `cap:bool=true`, `transform:Transform=identity` |
| `GeneratorConfig` | `template:ID?`, `controls:ControlValues={}`, `regions:string[]=all`, `topology:quads\|triangles=quads`, `resolution:int>=1=1`, `landmarks:LandmarkTarget[]=[]`, `implicit:ImplicitGraph?` |
| `ImplicitGraph` | `nodes:[{id,operation:sphere\|capsule\|box\|union\|subtract\|intersect\|smooth-union,inputs:ID[],transform,parameters:{radiusM?,sizeM?,lengthM?,blendRadiusM?}}]!`, `output:ID!`, `bounds:{min:V3,max:V3}!`, `voxelM:M+=0.005`, `isoValue:number=0` |
| `GeometryPatch` | `topologyRevision:int!`, `positions:Blob?`, `verticesAdd:Blob?`, `verticesRemove:ID[]=[]`, `facesAdd:Blob?`, `facesRemove:ID[]=[]`, `edgeSplits:Blob?`, `cornerAttributes:{semantic:Blob}={}`, `attributeSets:{semantic:Blob}={}`, `referenceRemap:Blob?` |
| `LandmarkTarget` | `id:ID!`, `position:V3!`, `space:Space=avatar`, `weight:number>=0=1`, `toleranceM:M0=0.001`, `lock:bool=false` |
| `GeometryMeasureConfig` | `metric:distance\|angle\|length\|area\|volume\|bounds\|clearance!`, `subjects:ID[]!`, `against:ID[]=[]`, `space:Space=avatar`, `signed:bool=false`, `sampleSpacingM:M+=0.005`, `pose:ID?`; results report metres, degrees, m² or m³ as appropriate |
| `RemeshConfig` | `method:isotropic\|adaptive\|voxel=isotropic`, `edgeLengthM:M+=0.005`, `voxelM:M+=0.005`, `iterations:int=5`, `preserveBoundaries:bool=true`, `preserveSeams:bool=true`, `preserveRegions:bool=true`, `curvatureWeight:number>=0=1`, `transfer:TransferConfig=default` |
| `RetopologyConfig` | `targetQuads:int>0!`, `guides:ID[]=[]`, `requiredLoops:ID[]=[]`, `symmetry:bool=true`, `featureAngleDeg:Deg=45`, `maxSurfaceErrorM:M0=0.001`, `poleExclusionRegions:string[]=eyelid,lip`, `transfer:TransferConfig=default` |
| `DecimateConfig` | exactly one of `targetTriangles:int>0`, `ratio:U`; `maxSurfaceErrorM:M0=0.001`, `maxNormalErrorDeg:Deg=10`, `maxUvError:U=0.01`, `maxWeightError:U=0.02`, `maxMorphErrorM:M0=0.001`, `lockBoundaries:bool=true`, `lockSeams:bool=true`, `lockRegions:string[]=eyelid,lip`, `preserveSilhouetteViews:ID[]=[]` |
| `DeformConfig` | `method:arap\|laplacian\|cage\|lattice\|bend\|twist\|taper\|displace!`, `handles:LandmarkTarget[]=[]`, `cage:ID?`, `latticeResolution:int[3]=[4,4,4]`, `axis:V3=[0,1,0]`, `origin:V3=[0,0,0]`, `angleDeg:Deg=0`, `scale:Curve<number>?`, `displacement:ID?`, `amplitudeM:M=0`, `iterations:int=20`, `preserveVolume:bool=true`, `fixed:ID[]=[]` |
| `SculptStroke` | `brush:grab\|smooth\|inflate\|deflate\|crease\|flatten\|pinch!`, `path:SurfacePath!`, `radiusM:M+!`, `strength:number!`, `falloff:Curve<U>=linear`, `direction:V3?`, `symmetry:bool=true`, `preserveBoundaries:bool=true`, `pressure:Curve<U>=one` |
| `ProjectionConfig` | `method:nearest\|normal-ray\|axis-ray=nearest`, `axis:V3=[0,-1,0]`, `offsetM:M=0`, `maxDistanceM:M+=0.05`, `bidirectional:bool=true`, `preserveThickness:bool=true`, `excludeRegions:string[]=[]` |
| `NormalConfig` | `method:angle-weighted\|area-weighted\|flat\|transfer=angle-weighted`, `splitAngleDeg:Deg=60`, `source:ID?`, `faceSmoothing:U=0`, `smoothingCage:ID?`, `preserveSeams:bool=true`, `tangents:mikktspace\|none=mikktspace`, `uvSet:int=0` |
| `TransferConfig` | `method:barycentric\|cage\|nearest=barycentric`, `correspondence:ID?`, `maxDistanceM:M+=0.02`, `maxNormalAngleDeg:Deg=60`, `regionMap:object={}`, `preserveSeams:bool=true`, `unmatched:error\|report=error`, `normalizeWeights:bool=true` |
| `RepairAction` | `type:remove-degenerate\|remove-duplicate\|orient\|weld\|fill-hole\|split-nonmanifold!`, `selection:ID!`, `toleranceM:M0=0.00001`, `maxHolePerimeterM:M0=0.01`, `preserveAttributes:bool=true` |

Primitive-specific fields are rejected when irrelevant to the chosen primitive;
schemas use discriminated unions rather than silently accepting unused values.
All modifier objects store `type`, the matching payload above, `enabled`, `order`,
`inputRevision`, `outputCorrespondence` and `baked`. Per-corner UVs/normals must survive
export vertex splitting; counts distinguish source vertices, exported vertices and
per-primitive references.

## 5. Hair geometry, guides, textures and rigs

| Payload | Complete fields |
|---|---|
| `ScalpConfig` | `region:ID!`, `mask:ID?`, `hairline:SurfacePath?`, `offsetM:M0=0.001`, `density:Curve<U>=one`, `densityTexture:ID?`, `parting:SurfacePath[]=[]`, `exclude:ID[]=[]` |
| `HairGuideConfig` | `type:surface\|curves\|field=surface`, `category:front\|back\|side\|crown\|nape\|extension\|ahoge\|ponytail\|bun\|braid\|custom!`, `controlPoints:Blob!`, `basis:bezier\|bspline\|catmull-rom=bspline`, `degree:int=3`, `uSegments:int=8`, `vSegments:int=8`, `transform:Transform=identity`, `flowDirections:Blob?`, `headOffsetM:M0=0.005` |
| `HairGroupConfig` | `id:ID?`, `mode:procedural\|freehand=procedural`, `count:int>=1=12`, `seed:uint64=inherit`, `rootDistribution:uniform\|poisson\|explicit=poisson`, `roots:SurfacePoint[]?`, `minRootSpacingM:M0=0.003`, `rootJitterM:M0=0.001`, `lengthM:M+=0.2`, `lengthVariation:U=0.1`, `lengthProfile:Curve<number>=one`, `widthM:M+=0.012`, `widthProfile:Curve<U>=taper`, `thicknessM:M0=0.003`, `thicknessProfile:Curve<U>=taper`, `taperExponent:number>0=1`, `rootLiftM:M0=0.005`, `rootDirection:V3?`, `tipDirection:V3?`, `tipBendDeg:Deg=0`, `clumpStrength:U=0.5`, `clumpScaleM:M+=0.03`, `clumpProfile:Curve<U>=one`, `fanDeg:Deg=0`, `crossSection:flat\|folded\|lenticular\|ellipse=lenticular`, `curl:CurlConfig=default`, `twist:Curve<Deg>=zero`, `noise:HairNoiseConfig=default`, `material:ID!`, `mirror:bool=false` |
| `CurlConfig` | `type:none\|wave\|helix=none`, `radiusM:M0=0`, `pitchM:M+=0.03`, `phaseDeg:Deg=0`, `handedness:left\|right=right`, `amplitude:Curve<U>=one`, `frequencyVariation:U=0`, `flatten:U=0` |
| `HairNoiseConfig` | `amplitudeM:M0=0`, `frequencyPerM:number>=0=10`, `octaves:int>=1=1`, `roughness:U=0.5`, `rootFade:U=0.2`, `tipFade:U=0`, `seed:uint64=inherit` |
| `HairStroke` | `points:SurfacePoint[]!`, `pressure:U[]?`, `widthM:M+?`, `thicknessM:M0?`, `smoothing:U=0.3`, `rootAt:first\|last=first` |
| `HairClump` | `root:SurfacePoint!`, `guide:ID!`, `points:Blob!`, `width:Curve<M+>!`, `thickness:Curve<M0>!`, `twist:Curve<Deg>=zero`, `material:ID!`, `uv:UvTransform=identity`, `boneGroup:ID?`; all base object fields |
| `BraidConfig` | `style:braid\|rope\|bun!`, `carrier:ID!`, `strandCount:int>=2=3`, `radiusM:M+=0.025`, `pitchM:M+=0.06`, `phaseDeg:Deg=0`, `crossingOrder:int[]=template`, `strandRadiusM:M+=0.008`, `taper:Curve<U>=one`, `looseness:U=0.1`, `turns:number>0=2`, `flatten:U=0`, `endTie:ID?`, `clump:HairGroupConfig!` |
| `HairAvoidConfig` | `clearanceM:M0=0.003`, `selfClearanceM:M0=0.001`, `preserveRoots:bool=true`, `preserveTips:bool=false`, `preserveLength:bool=true`, `maxDisplacementM:M0=0.03`, `iterations:int=50`, `sdfVoxelM:M+=0.002`, `protectedViews:ID[]=[]` |
| `HairMeshConfig` | `representation:card\|folded-card\|solid-clump\|tube=solid-clump`, `longitudinalSegments:int>=1=12`, `crossSegments:int>=1=4`, `maxSegmentM:M+=0.015`, `maxCurvatureErrorM:M0=0.0005`, `frame:parallel-transport=parallel-transport`, `upHint:V3=[0,0,1]`, `capRoot:bool=false`, `capTip:bool=true`, `foldAngleDeg:Deg=30`, `tipMode:point\|round\|flat=point`, `uvMode:arc-length\|normalized=arc-length`, `uvTileM:M+=0.2`, `normals:NormalConfig=default`, `doubleSided:bool=false` |
| `HairTextureConfig` | `width:int>0=2048`, `height:int>0=2048`, `baseColour:Colour!`, `shadeColour:Colour!`, `rootColour:Colour!`, `tipColour:Colour!`, `rootBlend:U=0.15`, `tipBlend:U=0.2`, `highlightColour:Colour=white`, `highlightPosition:U=0.35`, `highlightWidth:U=0.15`, `highlightSoftness:U=0.25`, `highlightOpacity:U=0.5`, `streakCount:int>=0=20`, `streakContrast:U=0.1`, `streakWidth:U=0.01`, `strandNoise:U=0.05`, `uvWidth:Scale=1`, `uvOffset:V2=[0,0]`, `normalStrength:U=0`, `alphaEdgeSoftness:U=0.05`, `seed:uint64=inherit` |
| `HairRigConfig` | `mode:auto\|manual=auto`, `groupCount:int>=1=12`, `groupMethod:spatial\|guide\|explicit=guide`, `members:ID[][]?`, `axisSource:center\|clump\|curve=center`, `axis:ID?`, `segments:int>=1=4`, `fixedRootFraction:U=0.1`, `jointSpacing:uniform\|curvature=curvature`, `tipNode:bool=true`, `rootParent:ID!`, `center:ID?`, `skin:SkinConfig=default`, `spring:SpringProfiles?`, `colliderGroups:ID[]=[]` |

`Curve` defaults: `zero` has two knots with value 0; `one` has value 1;
`linear` falls from 1 to 0; `taper` is `(0,1),(0.7,0.7),(1,0.02)`.
Root/tip profiles are over arc length, not point index. Explicit point editing takes
priority over a generator only after `hair convert` or a stored post-generator
modifier. `groupCount` is a native unbounded positive integer constrained by budgets;
it is not misrepresented as VRoid's documented UI range.

The bone-group operations and fixed-root, stiffness, gravity and radius concepts
correspond to [VRoid hair bounce](https://vroid.pixiv.help/hc/en-us/articles/900006910023).
The guide frame, curl, avoidance and tessellation controls are native extensions.

## 6. Garments, patterns, layers and accessories

`GarmentConfig={id:ID?, template:ID!, category:inner-top|inner-bottom|top|bottom|
dress|coat|bodysuit|socks|shoes|custom!, controls:ControlValues={}, material:ID!,
layer:int=0, fit:GarmentFitConfig=default, mask:CoverageMaskConfig?,
rig:GarmentRigConfig?}`. Multiple templates can coexist within a category.

| Garment control prefix | Independent parameters |
|---|---|
| `garment.overall` | B: `length`, `width`, `depth`, `volume`, `bodyBulk`, `shoulderWidth`, `waistWidth`, `hipWidth`, `hemWidth`, `hemTightness`, `hemFlare`; `thicknessM:M0=0.001`, `offsetM:M0=0.002` |
| `garment.neck` | B: `openingWidth`, `openingDepth`, `height`, `collarWidth`, `collarHeight`, `collarSpread`, `collarRoundness`, `flattenNeck` |
| `garment.sleeve.{L,R}` | B: `length`, `width`, `thickness`, `upperPuff`, `lowerPuff`, `shoulderPuff`, `armholeHeight`, `armholeWidth`, `cuffWidth`, `cuffLength`, `rollup`, `crease`, `flare` |
| `garment.torso` | B: `chestEase`, `waistEase`, `backEase`, `bustFlatten`, `clavicleFlatten`, `upperChestFlatten`, `pectoralFlatten`, `navelFlatten`, `torsoFlatten`, `frontLength`, `backLength` |
| `garment.skirt` | B: `length`, `waistHeight`, `volume`, `flare`, `frontLift`, `backLift`, `hemTightness`, `pleatDepth`, `pleatWidth`, `waistGather`; `pleatCount:int>=0=0` |
| `garment.trouser.{L,R}` | B: `length`, `rise`, `seat`, `crotchTightness`, `thighWidth`, `thighPuff`, `kneeWidth`, `calfWidth`, `ankleWidth`, `cuffWidth`, `flare`, `crease`, `rollup` |
| `garment.bodysuit` | B: `expand`, `bulk`, `flattenClavicle`, `flattenUpperChest`, `flattenPectorals`, `flattenNavel`, `flattenTorso`, `flattenGlutes`, `flattenThighGap`, `tightenCrotch`, `neckWidth`, `neckDepth` |
| `garment.shoe.{L,R}` | B: `length`, `width`, `toeRoundness`, `toePoint`, `instep`, `heelWidth`, `shaftHeight`, `shaftWidth`, `ankleTightness`; `heelHeightM:M0=0`, `soleThicknessM:M0=0.01`, `toeLiftM:M0=0` |
| `garment.sock.{L,R}` | B: `length`, `cuffHeight`, `cuffWidth`, `legEase`, `footEase` |

Templates declare applicable controls; setting a skirt control on a shoe is an error.
Any template-specific addition uses `control register` and appears in discovery.
Original native templates provide the functions described by
[VRoid outfit layering](https://vroid.pixiv.help/hc/en-us/articles/4405497325721),
without redistributing pixiv template meshes by assumption.

| Payload | Complete fields |
|---|---|
| `PatternConfig` | `panels:[{id,outline:V2[],holes:V2[][],grainDirection:V2,placement:Transform}]!`, `seams:[{id,edgeA:ID,edgeB:ID,reverse:bool,easeRatio:Scale,allowanceM:M0}]!`, `darts:[{panel:ID,legs:ID[2],depthM:M0}]=[]`, `sampleEdgeM:M+=0.01` |
| `GarmentFitConfig` | `method:transfer\|shrinkwrap\|cage=transfer`, `minClearanceM:M0=0.002`, `maxStretch:Scale=1.2`, `preserveSeams:bool=true`, `preserveVolume:bool=true`, `lockedRegions:ID[]=[]`, `poseSet:ID[]=template`, `iterations:int=50`, `layerObstacles:ID[]=[]` |
| `CoverageMaskConfig` | `mode:alpha\|geometry=alpha`, `source:ID?`, `marginM:M0=0.003`, `poseSet:ID[]=template`, `keepRegions:string[]=face,hands`, `minCoverage:U=0.99`, `reversible:bool=true` |
| `GarmentRigConfig` | `bodySkin:ID!`, `transfer:TransferConfig=default`, `secondaryRegions:ID[]=[]`, `chainSpacingM:M+=0.05`, `segments:int>=1=4`, `spring:SpringProfiles?`, `colliderGroups:ID[]=[]`, `correctivePoses:ID[]=[]` |
| `ClothConfig` | `solver:xpbd=xpbd`, `densityKgM2:number>0=0.2`, `thicknessM:M+=0.001`, `stretchCompliance:number>=0=0.000001`, `shearCompliance:number>=0=0.00001`, `bendCompliance:number>=0=0.0001`, `damping:U=0.05`, `friction:U=0.3`, `selfCollision:bool=true`, `collisionMarginM:M0=0.002`, `pinVertices:ID[]=[]`, `pinCompliance:number>=0=0`, `gravityMps2:V3=[0,-9.81,0]`, `windVelocityMps:V3=[0,0,0]`, `dragCoefficient:number>=0=0.5`, `liftCoefficient:number>=0=0`, `stepHz:int>0=120`, `substeps:int>=1=4`, `iterations:int>=1=10`, `durationSeconds:number>0=5` |
| `AccessoryConfig` | `id:ID?`, `type:glasses\|ears\|earrings\|ribbon\|horns\|tail\|hat\|custom!`, `template:ID?`, `mesh:ID?`, `attachNode:ID!`, `transform:Transform=identity`, `controls:ControlValues={}`, `materials:ID[]!`, `spring:SpringGeneratorConfig?` |

Accessory control vocabulary:

| Type | Parameters |
|---|---|
| glasses | `lensWidthM`, `lensHeightM`, `lensDepthM`, `bridgeWidthM`, `frameThicknessM`, `templeLengthM`, `templeWidthM`: M0, defaults template; `lensRoundness:U=0.5`, `lensTiltDeg:Deg=0`, `lensOpacity:U=0.2`, `frameColour:Colour=template`, `lensColour:Colour=template` |
| animal ears/horns | `lengthM`, `widthM`, `thicknessM`, `spacingM`: M0=template; `tipPoint:U=0.5`, `bend:Curve<Deg>=zero`, `twist:Curve<Deg>=zero`, `innerColour`, `outerColour`: Colour=template |
| earrings | `lengthM`, `radiusM`, `wireRadiusM`: M0=template; `segments:int>=3=12`, `pendant:ID?`, `material:ID!` |
| ribbon | `loopWidthM`, `loopHeightM`, `tailLengthM`, `widthM`, `thicknessM`, `knotRadiusM`: M0=template; `curl:Curve<Deg>=zero`, `material:ID!` |
| tail | `lengthM:M+=template`, `radius:Curve<M+>=template`, `curve:ID!`, `tuftGroup:ID?`, `material:ID!` |
| hat | `crownHeightM`, `crownRadiusM`, `brimWidthM`, `thicknessM`: M0=template; `brimCurl:Curve<Deg>=zero`, `material:ID!` |
| custom | All mesh, curve, transform, material and skin fields; registered template controls |

Accessory position, rotation, scale, colour and item-specific parameter editing follow
the documented [accessories workflow](https://vroid.pixiv.help/hc/en-us/articles/900006965863).
Offline cloth coefficients above are solver parameters with backend-declared units;
they are not substitutes for VRM spring stiffness/drag fields.

## 7. UV, image, layer and paint controls

| Payload | Complete fields |
|---|---|
| `UvConfig` | `set:int>=0=0`, `method:lscm\|arap\|angle-based\|project=lscm`, `seams:ID[]=[]`, `pins:CornerUv[]=[]`, `texelDensityPxM:number>0=1024`, `preserveIslands:bool=false`, `symmetry:bool=false`, `maxStretch:number>=1=2` |
| `CornerUv` | `face:ID!`, `corner:int>=0!`, `uv:V2!` |
| `UvTransform` | `offset:V2=[0,0]`, `scale:V2=[1,1]`, `rotationRad:Rad=0`, `pivot:V2=[0,0]` |
| `AtlasConfig` | `width:int>0=2048`, `height:int>0=2048`, `maxPages:int>=1=4`, `paddingPx:int>=0=8`, `dilationPx:int>=0=8`, `allowRotate:bool=true`, `allowMirror:bool=false`, `preserveTexelDensity:bool=true`, `roleGroups:string[][]=[]`, `channels:string[]=base,shade,normal`, `keepAlphaModesSeparate:bool=true`, `keepQueuesSeparate:bool=true` |
| `TextureConfig` | `id:ID?`, `generator:TextureGenerator!`, `width:int>0=2048`, `height:int>0=2048`, `colourSpace:linear\|srgb=srgb`, `seed:uint64=inherit`, `palette:Colour[]!`, `parameters:TextureGeneratorParameters!`, `layers:TextureLayer[]=[]`, `regionMasks:{name:ID}={}` |
| `TextureLayer` | `id:ID!`, `name:string=""`, `source:ID?`, `generator:TextureGenerator?`, `colour:Colour?`, `opacity:U=1`, `blend:normal\|multiply\|screen\|overlay\|add\|subtract\|erase=normal`, `mask:ID?`, `clipping:bool=false`, `locked:bool=false`, `visible:bool=true`, `transform:UvTransform=identity`, `channelMask:string=rgba`, `order:int=0` |
| `PaintStroke` | `space:uv\|surface!`, `points:V2[]\|SurfacePoint[]!`, `brush:paint\|erase\|blur\|smudge\|clone!`, `colour:Colour!`, `radius:number>0!`, `radiusUnit:px\|m!`, `hardness:U=0.5`, `opacity:U=1`, `flow:U=1`, `spacing:U=0.1`, `pressure:U[]?`, `symmetry:bool=false`, `seed:uint64=inherit`, `cloneSource:ID?` |
| `DecalConfig` | `source:ID!`, `projection:uv\|planar\|surface!`, `transform:Transform\|UvTransform!`, `surface:SurfacePoint?`, `sizeM:V2?`, `opacity:U=1`, `blend:normal\|multiply\|add=normal`, `wrapAngleDeg:Deg=45`, `mask:ID?`, `mirror:bool=false` |
| `FilterConfig` | `type:blur\|sharpen\|levels\|hsv\|gradient-map\|normal-from-height\|dilate!`, `radiusPx:number>=0=0`, `amount:number=1`, `inputBlack:U=0`, `inputWhite:U=1`, `gamma:number>0=1`, `hueDeg:Deg=0`, `saturation:number>=0=1`, `value:number>=0=1`, `gradient:Curve<Colour>?`, `mask:ID?` |
| `BakeConfig` | `maps:string[]=base,shade,normal,ao`, `width:int=2048`, `height:int=2048`, `samples:int>=1=64`, `cage:ID?`, `rayDistanceM:M+=0.01`, `paddingPx:int=8`, `normalSpace:tangent\|object=tangent`, `aoDistanceM:M+=0.1`, `includeLighting:bool=false`, `alphaCoverage:bool=true`, `colourSpace:linear\|srgb=srgb` |

`TextureGenerator` = `solid`, `gradient`, `skin`, `iris`, `sclera`, `eyeline`, `brow`,
`lash`, `lip`, `mouth`, `hair`, `fabric`, `makeup`, `decal`, `noise`, `custom-layer-stack`.
`TextureGeneratorParameters` is the matching discriminated union:

| Generator | Parameters beyond common image/layer fields |
|---|---|
| solid/gradient | `colour:Colour!` / `gradient:Curve<Colour>!`, `direction:V2=[0,1]`, `offset:V2=[0,0]` |
| skin | `baseColour`, `shadowColour`, `blushColour`: Colour!; `blush:U=0.1`, `freckleDensity:U=0`, `freckleSizePx:number>=0=2`, `poreStrength:U=0`, `noseAccent:U=0.1`, `earAccent:U=0.1`, `underEye:U=0`, `bodyDetail:U=0.1`, `shadeCalibration:Curve<Colour>?` |
| iris | `baseColour`, `rimColour`, `pupilColour`: Colour!; `pupilRatio:U=0.35`, `pupilShape:round\|slit\|custom=round`, `limbalWidth:U=0.08`, `radialStreaks:int>=0=32`, `radialContrast:U=0.2`, `gradient:Curve<Colour>?`, `highlightMask:ID?`, `rotationDeg:Deg=0` |
| sclera | `baseColour:Colour=white`, `shadowColour:Colour!`, `upperShade:U=0.2`, `veinOpacity:U=0`, `veinScale:number>0=1` |
| eyeline/brow/lash | `colour:Colour!`, `shape:ID!`, `thicknessPx:number>0=4`, `taper:Curve<U>=taper`, `edgeSoftness:U=0.1`, `strandCount:int>=0=0`, `spacingPx:number>=0=0` |
| lip/mouth | `baseColour:Colour!`, `edgeColour:Colour!`, `gradient:Curve<Colour>?`, `gloss:U=0`, `creaseStrength:U=0.1`, `mask:ID?` |
| hair | `HairTextureConfig` |
| fabric | `pattern:solid\|weave\|knit\|stripe\|plaid\|dot\|custom=solid`, `scaleM:M+=0.01`, `rotationDeg:Deg=0`, `colours:Colour[]!`, `weaveNormalStrength:U=0.1`, `seamMask:ID?`, `stitchSpacingM:M+=0.003`, `wear:U=0`, `roughness:U=0.8` |
| makeup | `region:ID!`, `colour:Colour!`, `opacity:U=0.2`, `gradient:Curve<U>=linear`, `symmetry:bool=true`, `decal:ID?` |
| decal | `DecalConfig` |
| noise | `type:white\|value\|gradient\|cellular=value`, `frequency:number>0=8`, `octaves:int>=1=3`, `roughness:U=0.5`, `tileable:bool=true` |
| custom-layer-stack | `layers:TextureLayer[]!` |

Brush/layer controls correspond to functions documented in
[VRoid's texture editor](https://vroid.pixiv.help/hc/en-us/articles/4405430561817).
The agent can import externally generated artwork as another layer, but no network
model invocation is required to complete a deterministic native avatar.

## 8. Material and texture-slot fields

`MaterialConfig` combines base object fields, `role:MaterialRole!`,
`shader:mtoon|pbr|unlit=mtoon`, the standard fields below and extension payloads.
Colours are stored in linear space internally; image sampling uses each slot's
specified colour-space interpretation. The compiler writes native defaults explicitly
where upstream prose/schema disagree, notably MToon shade colour.

| Group | Fields; native defaults |
|---|---|
| glTF surface | `baseColorFactor:V4=[1,1,1,1]`, `metallicFactor:U=0`, `roughnessFactor:U=1`, `emissiveFactor:V3=[0,0,0]`, `alphaMode:OPAQUE\|MASK\|BLEND=OPAQUE`, `alphaCutoff:U=0.5`, `doubleSided:bool=false` |
| glTF slots | `baseColorTexture`, `metallicRoughnessTexture`, `normalTexture`, `occlusionTexture`, `emissiveTexture`: TextureSlot?; `normalTexture.scale:number=1`, `occlusionTexture.strength:U=1` |
| MToon colour | `shadeColorFactor:V3=[1,1,1]`, `shadeMultiplyTexture:TextureSlot?` |
| MToon shading | `shadingShiftFactor:number=0`, `shadingShiftTexture:TextureSlot?`, `shadingShiftTexture.scale:number=1`, `shadingToonyFactor:U=0.9`, `giEqualizationFactor:U=0.9` |
| MToon matcap | `matcapFactor:V3=[1,1,1]`, `matcapTexture:TextureSlot?` |
| MToon rim | `parametricRimColorFactor:V3=[0,0,0]`, `parametricRimFresnelPowerFactor:number>=0=5`, `parametricRimLiftFactor:number=0`, `rimMultiplyTexture:TextureSlot?`, `rimLightingMixFactor:U=1` |
| MToon outlines | `outlineWidthMode:none\|worldCoordinates\|screenCoordinates=none`, `outlineWidthFactor:number>=0=0`, `outlineWidthMultiplyTexture:TextureSlot?`, `outlineColorFactor:V3=[0,0,0]`, `outlineLightingMixFactor:U=1` |
| MToon alpha/order | `transparentWithZWrite:bool=false`, `renderQueueOffsetNumber:int[-9,9]=0` |
| MToon UV motion | `uvAnimationMaskTexture:TextureSlot?`, `uvAnimationScrollXSpeedFactor:number=0`, `uvAnimationScrollYSpeedFactor:number=0`, `uvAnimationRotationSpeedFactor:number=0` |
| Authoring targets | `shadowEnd:number?`, `terminatorWidth:number[0,2]?`, `shadeWarmth:number?`, `outlineWidthM:M0?`; derived targets compile to standard fields, never extra standard properties |

MToon field names are taken from its [schema](https://raw.githubusercontent.com/vrm-c/vrm-specification/master/specification/VRMC_materials_mtoon-1.0/schema/VRMC_materials_mtoon.schema.json).
The profile role presets override the neutral defaults above. Only world-coordinate
outline widths are metres; screen-coordinate widths follow the extension definition.
UV animation speed units follow the pinned MToon spec and are returned by discovery.

`TextureSlot={image:ID!, sampler:ID?, texCoord:int>=0=0,
transform:{offset:V2=[0,0],scale:V2=[1,1],rotation:Rad=0,texCoord:int?},
scale:number?,strength:U?}`; only slot-valid `scale`/`strength` keys are accepted.
`Sampler={magFilter:9728|9729=9729,minFilter:9728|9729|9984|9985|9986|9987=9987,
wrapS:33071|33648|10497=10497,wrapT:33071|33648|10497=10497}`.

`KHR_texture_transform`, `KHR_materials_unlit` and `KHR_materials_emissive_strength`
are explicit capability entries, with their complete pinned schemas available.
Other glTF material extensions use the same typed schema mechanism; unsupported
rendering/export combinations fail or follow an explicit fallback policy.
No material merger may collapse different role, alpha, queue, outline or expression
bindings merely because the current pixel colours happen to match.

## 9. Humanoid, skinning, morph and expression fields

`HumanoidMap` contains every VRM 1.0 humanoid bone name as an optional key whose
requiredness follows the pinned humanoid schema. Native complete humanoid templates
provide required bones and fingers, toes, eyes and jaw where geometry supports them:

```text
hips spine chest upperChest neck head jaw leftEye rightEye
{left,right}Shoulder {left,right}UpperArm {left,right}LowerArm {left,right}Hand
{left,right}UpperLeg {left,right}LowerLeg {left,right}Foot {left,right}Toes
{left,right}ThumbMetacarpal {left,right}ThumbProximal {left,right}ThumbDistal
{left,right}{Index,Middle,Ring,Little}{Proximal,Intermediate,Distal}
```

Each map entry is `{node:ID!}`. Braces expand to literal camel-case VRM names, e.g.
`leftIndexProximal`. A hierarchy validator enforces ancestry and uniqueness; merely
having the names is insufficient. Mapping fields are defined in the
[humanoid specification](https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm-1.0/humanoid.md).

| Payload | Complete fields |
|---|---|
| `RigConfig` | `template:ID!`, `humanBones:HumanoidMap?`, `fingers:bool=true`, `toes:bool=true`, `eyes:bool=true`, `jaw:bool=true`, `twistBonesPerLimb:int>=0=0`, `restPose:t-pose=t-pose`, `landmarks:ID[]=[]`, `jointOffsets:{bone:V3}={}`, `jointOrientations:{bone:Quat}={}`, `auxiliaryBones:BoneConfig[]=[]` |
| `BoneConfig` | `id:ID!`, `parent:ID?`, `transform:Transform!`, `humanoidName:string?`, `deform:bool=true`, `tail:V3?`, `limits:JointLimits?` |
| `JointLimits` | `swingXDeg:V2=[-180,180]`, `swingZDeg:V2=[-180,180]`, `twistDeg:V2=[-180,180]`; authoring/preview only unless a declared extension carries them |
| `SkinConfig` | `method:heat\|bounded-biharmonic\|distance\|manual=heat`, `maxInfluences:int>=1=4`, `minWeight:U=0.0001`, `falloff:number>0=2`, `smoothIterations:int>=0=5`, `lockedBones:ID[]=[]`, `regionConstraints:object={}`, `inverseBindMode:compute\|supplied=compute`, `inverseBinds:Blob?`, `bindPose:ID?` |
| `WeightPatch` | `topologyRevision:int!`, `mode:replace\|add\|scale!`, `entries:[{vertex:ID!,influences:[{bone:ID!,weight:U!}]!}]!`, `locked:ID[]=[]` |
| `MorphGeneratorConfig` | `basis:ID!`, `channels:string[]!`, `amplitudes:{channel:number}={}`, `preserveRegions:string[]=teeth`, `lidSurface:ID?`, `maxContactErrorM:M0=0.0005` |
| `MorphPatch` | `topologyRevision:int!`, `positions:Blob!`, `normals:Blob?`, `tangents:Blob?`, `sparseIndices:Blob?` |
| `MorphTerm` | `morph:ID!`, `weight:number!` |
| `CorrectiveDriver` | `type:pose\|expression-combination!`, `bones:ID[]=[]`, `poses:ID[]=[]`, `expressions:ExpressionWeights={}`, `interpolation:rbf\|linear=rbf`, `radius:number>0=1`, `exportPolicy:bake\|extension\|error=error` |
| `ExpressionGeneratorConfig` | `presets:string[]=aa,ih,ou,ee,oh,blink,blinkLeft,blinkRight,happy,angry,sad,relaxed,surprised,neutral`, `basis:ID!`, `controls:{expression:ControlValues}={}`, `strengths:{expression:U}={}`, `custom:string[]=[]`, `arkit52:bool=false`, `maxActivePerPrimitive:int>=1=8`, `fitLids:bool=true`, `fitLips:bool=true` |
| `ExpressionConfig` | `preset:string?`, `customName:string?` (exactly one), `isBinary:bool=false`, `overrideBlink:none\|block\|blend=none`, `overrideLookAt:none\|block\|blend=none`, `overrideMouth:none\|block\|blend=none`, `morphTargetBinds:MorphBind[]=[]`, `materialColorBinds:MaterialColourBind[]=[]`, `textureTransformBinds:TextureTransformBind[]=[]` |
| `MorphBind` | `node:ID!`, `morph:ID!`, `weight:U!`; compiler resolves mesh target index |
| `MaterialColourBind` | `material:ID!`, `type:color\|emissionColor\|shadeColor\|matcapColor\|rimColor\|outlineColor!`, `targetValue:V4!` |
| `TextureTransformBind` | `material:ID!`, `scale:V2=[1,1]`, `offset:V2=[0,0]` |
| `RetargetConfig` | `rootMotion:preserve\|in-place=preserve`, `translationScale:number>0=1`, `mapping:{source:ID}={}`, `sampleHz:int>0=60`, `footLock:bool=false` |

Standard presets: `happy`, `angry`, `sad`, `relaxed`, `surprised`, `aa`, `ih`, `ou`,
`ee`, `oh`, `blink`, `blinkLeft`, `blinkRight`, `lookUp`, `lookDown`, `lookLeft`,
`lookRight`, `neutral`. The [expression schema](https://raw.githubusercontent.com/vrm-c/vrm-specification/master/specification/VRMC_vrm-1.0/schema/VRMC_vrm.expressions.expression.schema.json)
defines the binding/override fields; the author's policy determines which optional
presets must actually work. Neutral identity is baked into the base mesh deliberately;
a separate neutral expression is not silently applied twice.

Expression basis controls, all U=0 unless signed below, independently selectable per
side where applicable: `browInnerUp`, `browOuterUp.{L,R}`, `browDown.{L,R}`,
`eyeBlink.{L,R}`, `eyeWide.{L,R}`, `eyeSquint.{L,R}`, `eyeLookUp.{L,R}`,
`eyeLookDown.{L,R}`, `eyeLookIn.{L,R}`, `eyeLookOut.{L,R}`, `cheekPuff`,
`cheekSquint.{L,R}`, `noseSneer.{L,R}`, `jawOpen`, `jawForward`, `jawLeft`,
`jawRight`, `mouthClose`, `mouthFunnel`, `mouthPucker`, `mouthLeft`, `mouthRight`,
`mouthSmile.{L,R}`, `mouthFrown.{L,R}`, `mouthDimple.{L,R}`, `mouthStretch.{L,R}`,
`mouthRollLower`, `mouthRollUpper`, `mouthShrugLower`, `mouthShrugUpper`,
`mouthPress.{L,R}`, `mouthLowerDown.{L,R}`, `mouthUpperUp.{L,R}`, `tongueOut`.
Additional native controls: `tongueUp`, `tongueDown`, `tongueLeft`, `tongueRight`,
`teethUpperShow`, `teethLowerShow`, `fangShow.{L,R}`, `lipSeal`, `lidFollow.{L,R}`.
Channel names resembling tracking APIs are native basis identifiers; the ARKit adapter
must validate its actual channel mapping and mixture support separately.

## 10. Gaze, first person and constraints

| Payload | Complete fields |
|---|---|
| `LookAtConfig` | `type:bone\|expression=bone`, `offsetFromHeadBone:V3=[0,0.06,0]`, `rangeMapHorizontalInner:RangeMap!`, `rangeMapHorizontalOuter:RangeMap!`, `rangeMapVerticalDown:RangeMap!`, `rangeMapVerticalUp:RangeMap!` |
| `RangeMap` | `inputMaxValue:number>0=90` in degrees, `outputScale:number>=0!`; bone output is degrees, expression output is weight |
| `FirstPersonAnnotation` | `node:ID!`, `type:auto\|both\|thirdPersonOnly\|firstPersonOnly!` |
| `ConstraintConfig` | exactly one of `roll:{source:ID!,rollAxis:X\|Y\|Z!,weight:U=1}`, `aim:{source:ID!,aimAxis:PositiveX\|NegativeX\|PositiveY\|NegativeY\|PositiveZ\|NegativeZ!,weight:U=1}`, `rotation:{source:ID!,weight:U=1}` |

The native anime template sets bone range-map outputs to 8, 12, 10 and 10 degrees
respectively as an authoring starting point, not a compulsory VRoid fingerprint.
Expression look-at uses explicitly supplied weights and does not reuse these degree
values. Standard fields follow the [range-map schema](https://raw.githubusercontent.com/vrm-c/vrm-specification/master/specification/VRMC_vrm-1.0/schema/VRMC_vrm.lookAt.rangeMap.schema.json)
and [node constraint specification](https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_node_constraint-1.0/README.md).
IK targets, aim offsets and pose solver limits are source/preview helpers; standard
node constraints are compiled using the specified rest-space relationships.

## 11. Spring, collider and simulation parameters

| Payload | Complete fields |
|---|---|
| `SpringConfig` | `name:string=""`, `center:ID?`, `joints:SpringJointConfig[]!`, `colliderGroups:ID[]=[]` |
| `SpringJointConfig` | `node:ID!`, `hitRadius:M0=0`, `stiffness:number>=0=1`, `gravityPower:number>=0=0`, `gravityDir:V3=[0,-1,0]`, `dragForce:U=0.5`, `compatibility:JointCompatibility?` |
| `SpringProfiles` | `stiffness:Curve<number>=one`, `dragForce:Curve<U>=constant(0.5)`, `gravityPower:Curve<number>=zero`, `gravityDir:V3=[0,-1,0]`, `hitRadiusM:Curve<M0>=constant(0.01)` |
| `SpringGeneratorConfig` | `root:ID!`, `sourceCurve:ID?`, `regions:ID[]=[]`, `segments:int>=1=4`, `fixedRootFraction:U=0.1`, `spacing:uniform\|curvature=curvature`, `addTail:bool=true`, `center:ID?`, `profiles:SpringProfiles=default`, `colliderGroups:ID[]=[]`, `branchPolicy:split\|error=error` |
| `ColliderConfig` | `node:ID!`, `shape:sphere\|capsule\|inside-sphere\|inside-capsule\|plane!`, `offset:V3=[0,0,0]`, `radius:M0=0`, `tail:V3=[0,0,0]`, `normal:V3=[0,0,1]`, `fallback:ColliderFallback?` |
| `ColliderFallback` | `policy:inert\|approximate\|error=error`, `shape:sphere\|capsule?`, `offset:V3?`, `radius:M0?`, `tail:V3?`, `maxApproximationErrorM:M0?` |
| `ColliderFitConfig` | `shapes:string[]=sphere,capsule`, `maxColliders:int>=1=24`, `marginM:M0=0.002`, `maxErrorM:M0=0.01`, `boneRegions:{bone:ID}={}`, `poseSet:ID[]=template`, `excludeRegions:ID[]=[]`, `groupBy:bone\|region=bone` |
| `JointCompatibility` | `adapter:string!`, `version:string!`, `angleLimitDeg:Deg>=0=0`; 0 disables this local convention; portable export rejects or removes only under explicit loss policy |
| `PhysicsPreviewConfig` | `backend:vrmmetalkit\|reference=vrmmetalkit`, `stepHz:int>0=120`, `solverIterations:int>=1=8`, `maxSubsteps:int>=1=8`, `ccd:off\|synthetic-only=synthetic-only`, `augmentation:off\|body=body`, `augmentationMarginM:M0=0.002`, `sleep:bool=false`, `windVelocityMps:V3=[0,0,0]`, `windGust:U=0`, `seed:uint64=inherit` |
| `SimulationConfig` | `durationSeconds:number>0=5`, `warmupSeconds:number>=0=1`, `sampleHz:int>0=120`, `reset:true=true`, `recordNodes:ID[]=all-spring-nodes`, `recordMeshes:ID[]=[]`, `render:RenderConfig?`, `backends:string[]=vrmmetalkit`, `portableBaseline:bool=true` |
| `MotionGoal` | `metric:tip-lag\|settling-time\|overshoot\|penetration\|length-error\|jitter!`, `subjects:ID[]!`, `min:number?`, `max:number?`, `unit:string!`, `weight:number>=0=1`, `required:bool=true` |

Native joint defaults above follow the pinned spring schema, not inconsistent defaults
in individual host APIs. Values are serialized at spec scale; a calibrated profile
may override them explicitly. `gravityPower` is a VRM coefficient, not kg or m/s².
`gravityDir` must be finite and normalized when nonzero gravity is used. Collider
offset/tail/normal are node-local; hit radius and collider radii are metres.
Spring chains/group membership use the [standard extension](https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_springBone-1.0/README.md).

`inside` shapes compile through `VRMC_springBone_extended_collider` with
`specVersion:"1.0"` and `inside:true`; planes store their normal. Standard fallback
shapes remain in `VRMC_springBone.colliders[*].shape`. The
[extended shape schema](https://raw.githubusercontent.com/vrm-c/vrm-specification/master/specification/VRMC_springBone_extended_collider-1.0/schema/VRMC_springBone_extended_collider.shape.schema.json)
does not define per-joint swing/twist limits. Collision sweeps are never enabled on
authored groups; the runtime's reserved synthetic group is not user-assignable.

`Scenario` fields: `name:string!`, `durationSeconds:number>0!`, `rootTrajectory:Blob?`,
`animation:ID?`, `poses:[{timeSeconds:number,pose:ID}]`,
`expressions:[{timeSeconds:number,values:ExpressionWeights}]`,
`gaze:[{timeSeconds:number,target:V3}]`, `wind:[{timeSeconds:number,velocityMps:V3}]`,
`impulses:[{timeSeconds:number,node:ID,deltaVelocityMps:V3}]`, `seed:uint64=inherit`.
Missing arrays are empty. Full QA includes head yaw/pitch/roll, quick turns, stop/start,
walking, jump/landing, arms-down, arm crossing, squat and garment-specific stress cases.

## 12. Metadata and asset provenance

`MetaConfig` uses exact VRM 1.0 keys. Required caller values: `name:string`,
`authors:nonempty string[]`, `licenseUrl:string`. Native VRM 1.0 export uses
`licenseUrl="https://vrm.dev/licenses/1.0/"` with explicit user/asset-derived terms.

| Field | Type / default |
|---|---|
| `version` | string, optional |
| `copyrightInformation`, `contactInformation`, `thirdPartyLicenses`, `otherLicenseUrl` | string, optional |
| `references` | string[], omitted if empty |
| `thumbnailImage` | image ID, optional; resolved to glTF image index |
| `avatarPermission` | `onlyAuthor` default, `onlySeparatelyLicensedPerson`, `everyone` |
| `commercialUsage` | `personalNonProfit` default, `personalProfit`, `corporation` |
| `creditNotation` | `required` default, `unnecessary` |
| `allowRedistribution` | bool=false |
| `modification` | `prohibited` default, `allowModification`, `allowModificationRedistribution` |
| `allowExcessivelyViolentUsage`, `allowExcessivelySexualUsage`, `allowPoliticalOrReligiousUsage`, `allowAntisocialOrHateUsage` | bool=false |

These fields/defaults come from the [VRM metadata schema](https://raw.githubusercontent.com/vrm-c/vrm-specification/master/specification/VRMC_vrm-1.0/schema/VRMC_vrm.meta.schema.json).
Metadata permissions are not style controls and cannot be changed by an optimization
pass. Required values cannot be invented to make a check pass.

`Provenance={sourceUri:string?, sourceSha256:string!, creator:string?,
licenseIdentifier:string?, licenseText:ID?, attribution:string?,
generator:{name,version,seed}?, derivation:ID[]=[], permissions:object?}`.
Track each imported model/template/image separately. Native template packs need
explicit redistributable source data; a corpus model's availability does not imply
permission to use its mesh as the default generator. Delivery includes attribution
and source manifests according to supplied metadata, without changing terms.

## 13. Rendering, QA, fitting and repair

| Payload | Complete fields |
|---|---|
| `RenderConfig` | `camera:ID?`, `view:ViewSpec?`, `width:int>0=1024`, `height:int>0=1024`, `samples:int=4`, `background:Colour=transparent`, `environment:ID?`, `lights:ID[]=template`, `exposureEv:number=0`, `toneMap:none\|aces=none`, `pose:ID?`, `expressions:ExpressionWeights={}`, `timeSeconds:number>=0=0`, `physics:bool=false`, `overlays:string[]=none`, `outputs:string[]=colour`, `colourSpace:linear\|srgb=srgb` |
| `ViewSpec` | `name:string!`, `projection:perspective\|orthographic=orthographic`, `azimuthDeg:Deg=0`, `elevationDeg:Deg=0`, `target:V3?`, `distanceM:M+=3`, `verticalFovDeg:Deg=35`, `orthoHeightM:M+=2`, `nearM:M+=0.01`, `farM:M+=100`, `crop:body\|face\|selection=body`, `selection:ID?`, `margin:U=0.1` |
| `Camera` | `transform:Transform!`, `projection:perspective\|orthographic!`, `yfovRad:Rad?`, `aspectRatio:number>0?`, `xmag:number>0?`, `ymag:number>0?`, `znear:M+!`, `zfar:M+?` |
| `Light` | `type:directional\|point\|spot!`, `colour:V3=[1,1,1]`, `intensity:number>=0=1`, `rangeM:M+?`, `innerConeRad:Rad=0`, `outerConeRad:Rad=0.785398`, `transform:Transform=identity`, `castShadows:bool=true` |
| `Environment` | `image:ID?`, `intensity:number>=0=1`, `rotationDeg:Deg=0`, `ambientColour:V3=[0.2,0.2,0.2]`, `background:Colour?`; preview settings unless export target supports their extension |
| `QaPlan` | `suite:QaSuite!`, `suiteVersion:string!`, `target:Target!`, `checks:string[]!`, `policy:ID?`, `views:ViewSpec[]!`, `scenarios:ID[]!`, `geometry:GeometryQaConfig=default`, `expressions:ExpressionQaConfig=default`, `motion:MotionQaConfig=default`, `budgets:ResourceBudget!`, `requireVisualInspection:bool=true`, `requireReimport:bool=true` |
| `GeometryQaConfig` | `maxDegenerateTriangles:int=0`, `maxUnmappedVertices:int=0`, `maxWeightSumError:number>=0=0.0001`, `minRestClearanceM:M0=0.001`, `maxSelfIntersectionAreaM2:number>=0=0`, `maxUvOverlap:U=0`, `allowedOverlapRegions:ID[]=[]`, `allowedOpenBoundaries:ID[]=[]`, `minTriangleAreaM2:number>=0=0.000000000001`, `maxBindErrorM:M0=0.0001` |
| `ExpressionQaConfig` | `requiredPresets:string[]=template`, `combinations:ExpressionWeights[]=template`, `minimumEffectM:M0=0.0001`, `maximumLeakageM:M0=0.0005`, `maxLidGapM:M0=0.001`, `maxLipGapM:M0=0.001`, `maxPenetrationM:M0=0.0005`, `maxActivePerPrimitive:int=8`, `allowDroppedTargets:bool=false` |
| `MotionQaConfig` | `maxPenetrationM:M0=0.002`, `maxPenetrationFrames:int>=0=2`, `maxLengthErrorRatio:U=0.01`, `maxJitterM:M0=0.002`, `maxSettleSeconds:number>0=3`, `maxNanCount:int=0`, `portableBaseline:bool=true`, `physics:PhysicsPreviewConfig=default` |
| `CompareConfig` | `align:camera\|landmarks\|none=camera`, `metrics:string[]=silhouette,landmark,colour,depth`, `masks:ID[]=[]`, `maxSilhouetteError:U=0.02`, `maxLandmarkErrorM:M0=0.002`, `maxColourRmse:number>=0=0.02`, `ignoreBackground:bool=true` |
| `ResourceBudget` | `triangles:int>0=80000`, `storedVertices:int>0=80000`, `materials:int>0=32`, `skinJoints:int>0=300`, `springJoints:int>=0=300`, `colliders:int>=0=32`, `textureMaxDimension:int>0=2048`, `decodedTextureMb:number>0=256`, `fileMb:number>0=30`, `maxActiveMorphsPerPrimitive:int>0=8`, `buildSeconds:number>0=300`, `qaSeconds:number>0=900` |
| `Goal` | `metric:string!`, `subjects:ID[]=[]`, `unit:string!`, at least one of `min:number?`, `max:number?`, `target:number?`; `tolerance:number>=0=0`, `weight:number>=0=1`, `required:bool=true`, `source:string=native` |
| `VariableRange` | `object:ID!`, `key:string!`, `min:number!`, `max:number!`, `step:number>0?`, `locked:bool=false` |
| `SearchConfig` | `algorithm:coordinate\|cma-es\|grid=coordinate`, `variables:VariableRange[]!`, `goals:Goal[]!`, `maxIterations:int>=1=20`, `maxCandidates:int>=1=100`, `maxSeconds:number>0=600`, `seed:uint64=inherit`, `maxParallelJobs:int>=1=1`, `keepBest:int>=1=3`, `stopWhenSatisfied:bool=true` |
| `RepairPlan` | `projectRevision:int!`, `reportSha256:string!`, `allowedVariables:VariableRange[]!`, `preserve:Goal[]!`, `operations:[{command:string!,request:object!}]!`, `postChecks:QaPlan!`, `maxRegression:number>=0=0` |
| `RoleMap` | `{materialId:MaterialRole}`; exporter emits a stable-ID/index sidecar for the existing linter |

QA thresholds and resource defaults are proposed starting policies; they are not VRM
format limits. Every metric defines how it handles transparency, hair cards, deliberate
contacts and empty selections. Geometry/visual rules can override defaults per region
with explicit rationale. `minimumEffectM` applies to geometric expressions; material
and UV expressions instead test their intended colour/UV effect in the report.

## 14. Import, build and export controls

| Payload | Complete fields |
|---|---|
| `ImportConfig` | `sourceUnits:m\|cm\|mm=m`, `sourceUp:X\|Y\|Z=Y`, `sourceForward:PositiveX\|NegativeX\|PositiveZ\|NegativeZ=PositiveZ`, `sourceColourSpace:auto\|linear\|srgb=auto`, `preserveUnknownExtensions:bool=true`, `missingAssets:error\|placeholder=error`, `mergeInto:ID?`, `roleMap:RoleMap={}`, `adapter:ID?` |
| `BuildConfig` | `evaluateModifiers:bool=true`, `triangulation:stable=stable`, `normalPolicy:preserve\|recompute=preserve`, `indexComponent:auto\|u16\|u32=auto`, `sparseMorphs:bool=true`, `interleave:bool=false`, `maxInfluences:int=4`, `deterministic:bool=true`, `validateSpec:bool=true`, `requireCompleteQa:bool=false`, `keepDebugMap:bool=true` |
| `ExportConfig` | `vrmVersion:1.0\|0.x=target`, `embedImages:bool=true`, `embedBuffers:bool=true`, `imageFormat:png\|jpeg=png`, `jpegQuality:int[1,100]=95`, `textureMaxDimension:int>0=2048`, `alphaPreservation:bool=true`, `normalizeRest:bool=false`, `removeUnused:bool=true`, `deduplicate:bool=true`, `mergeMeshes:bool=false`, `mergeMaterials:bool=false`, `meshReduction:DecimateConfig?`, `atlas:AtlasConfig?`, `expressionSelection:string[]=all`, `retainAuxiliaryBones:bool=true`, `retainUpperChest:bool=true`, `firstPersonPolicy:preserve\|explicit=preserve`, `thumbnail:ID?`, `extensionPolicy:preserve-supported\|portable-only=portable-only`, `lossPolicy:error\|report=error`, `acceptedLossReportSha256:string?`, `requireCompleteQa:bool=true`, `build:BuildConfig=default`, `adapter:ID?` |

For VRM sources, coordinate/version metadata overrides generic import defaults;
conflicting explicit settings require an error. Auto colour handling uses format/
slot semantics, not visual guessing. `placeholder` import is draft-only and cannot
pass final QA. Source recipes keep high-resolution images even when export downsizes.

Loss policy `report` produces an explicit draft/loss report; final export requires
the caller to provide the accepted loss-report hash through the request before applying
lossy structural conversions. Ordinary chosen texture compression/decimation is governed
by its own error budget. Legacy conversion reports dropped/approximated constraints,
materials, collider shapes, expression overrides and unmappable metadata; unsupported
losses are never hidden behind a successful “portable” verdict.

Base glTF LOD and full cloth/curve/IK representations are not assumed to exist in VRM.
LOD authoring emits separate self-contained avatars unless a target explicitly supports
a named extension. GLB serialization embeds required resources, preserves alignment,
computes accurate accessor bounds, remaps every expression/skin/constraint reference,
and writes the build's ID map and hashes alongside the VRM.

## 15. Completeness and verification requirements

The runtime registry must generate JSON Schemas and CLI help from this contract, then
generate a coverage report linking each operation and field to tests. Template packs
must add descriptors for every item-specific control they expose. No “advanced” freeform
dictionary may become a hiding place for undocumented parameters: its schema is exposed
by name and version through discovery.

Required regression dimensions: all scalar endpoints and invalid ranges; symmetry and
independent sides; profile-target versus physical-target conflicts; all texture slots;
all expression bind types; every bone mapping; all base/extended collider shapes;
hair group/clump/bone-group edits; topology correspondence invalidation; complete
source/export round-trip; sparse/normalized/interleaved geometry; VRM 0.x conversion;
missing-file atomicity; deterministic recipes; and all documented VRoid workflow rows.

The raw schema interface provides complete standard field access. The semantic catalogs
provide agent-usable native controls. Release-specific comparisons, if useful, remain an internal coverage tracker;
no public slider-parity certification or per-release audit is required.
