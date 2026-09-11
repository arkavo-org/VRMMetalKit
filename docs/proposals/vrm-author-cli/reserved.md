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

# Reserved VRMAuthor command designs

These advanced command designs are coordinated through the primary
[verification contract](verification.md). They are outside the initial v1 release
allowlist, not postponed because of implementation staffing. Before assigning a handler,
Stage A registers its concrete schema and independently reviewed executable acceptance
pack. No command is implemented by this proposal.

Every spelling below is relative to the **`reserved` namespace**: `mesh subdivide`
means `reserved mesh subdivide`, RPC `reserved.mesh.subdivide`. Registered definitions
appear under `describe --namespace reserved` with availability, evidence level/scope
and runnable state. Schema-only entries are coordination data, not callable tools.
Implemented candidates need admitted evidence before production use; isolated evaluators
can test unqualified candidates. Promotion requires its own versioned contract and
acceptance evidence. [commands.md](commands.md) and [parameters.md](parameters.md)
take precedence for overlapping v1 operations; advanced payload sketches are in
[reserved-parameters.md](reserved-parameters.md). No reserved command blocks unrelated
v1 qualification, and ready advanced work may proceed concurrently.

## Invocation and argument rules

```text
vrm-author <command> [--project PATH] [--request JSON_PATH|-] [named arguments]
```

Argument tables use `name:Type!` for required fields, `name:Type=value` for defaults,
and `name:Type?` for omitted optional fields. Names in tables are JSON request keys;
their CLI spelling is kebab-case (`maxErrorM` → `--max-error-m`). Nested objects and
arrays can always be supplied through `--request`; a CLI alias is not required for
each nested leaf. Typed `object set`/`control set` and `document patch` provide leaf
access. A field cannot be supplied simultaneously through JSON and a named flag.

`--request -` reads one JSON object from stdin. No shell expressions, templates or
embedded Python are evaluated. Unknown keys, nonfinite numbers, unknown IDs, empty
required selections and unsupported flags are errors. `--help` and `describe COMMAND`
always show the complete request/result schemas and one valid example.

Common arguments available to all applicable commands:

| Argument | Type/default | Meaning |
|---|---|---|
| `project` | path, required for project operations | Project directory; no implicit global “current avatar” |
| `format` | `json` default; `text` or `ndjson` | JSON result or job events; text is only presentation |
| `requestId` | string, optional for reads; generated if absent on writes | Idempotency key returned to caller |
| `expectedRevision` | integer, optional | Compare-and-swap revision; required for mutating RPC calls |
| `transaction` | ID, optional | Stage changes under a transaction |
| `dryRun` | bool=false | Plan mutation without committing or producing final outputs |
| `seed` | uint64, inherits project seed | Required resolved seed for stochastic operations |
| `threads` | integer≥1, runtime default | Does not alter deterministic backend output |
| `device` | `auto`, `cpu`, or GPU ID; default `auto` | Backend selector; capability errors never silently skip QA |
| `timeoutSeconds` | number>0=300 | Job deadline; resumption rules depend on command |
| `maxMemoryMb` | integer>0=4096 | Working-memory budget; fail/resume rather than corrupt output |
| `async` | bool=false | Return a persistent job ID immediately |
| `out` | path, required where listed | Output artifact/directory; absent otherwise returns metadata |
| `replace` | bool=false | Atomically replace an existing output; never deletes project history |
| `logLevel` | `error`, `warn`, `info`, `debug`; default `warn` | Stderr logging |

Defaults from a project/template are resolved and returned before execution; “inherit”
never means an undocumented heuristic. Output paths are not overwritten without
`replace`. Failed writes keep the previous file. Async commands snapshot inputs and
publish outputs only after success; cancellation has no partial project mutation.

Common result fields: `protocol`, `requestId`, `status`, `revisionBefore`,
`revisionAfter`, `objectsCreated`, `objectsChanged`, `invalidated`, `artifacts`,
`metrics`, `warnings`, `errors`, `jobId` when applicable. Status is one of
`succeeded`, `failed`, `incomplete`, `queued`, `running`, `cancelled`. `pending` is an
`evidenceStatus` value (`current | stale | failed | pending`), never a job status.

Exit codes `0`–`5` are the v1 codes defined in [commands.md](commands.md): `0`
completed; `1` failed required gate; `2` invalid request; `3` missing
capability/input/credential; `4` revision/idempotency/plan conflict; `5` internal
error. Reserved commands add `6` resource limit/cancellation and `7` incompatible
export/loss policy. A skipped required check produces `incomplete` and nonzero exit,
not success. Individual failed style `should` rules are warnings unless the selected
QA policy promotes them.

## Discovery, schemas and internal coverage

| Command | Additional arguments | Result |
|---|---|---|
| `version` | none | CLI/library/backend versions and build IDs |
| `describe` | `command:string?`, `schema:bool=true`, `examples:bool=true` | Complete command tree or one operation contract |
| `capabilities` | `target:Target?` | Non-evidence fields (`targets`, `templateHashes`, `supportedImports`, `backends`, `renderers`, `signerAvailable`) plus the per-operation evidence fields defined in [verification.md](verification.md) |
| `doctor` | `checks:string[]=all` | Toolchain, Metal, assets, schema lock and backend health |
| `schema list` | `kind:string?` | Registered object and upstream schemas |
| `schema show` | `id:ID!`, `resolveRefs:bool=true` | Complete resolved schema |
| `schema install` | `source:path!`, `sha256:string!` | Register a local, pinned schema bundle |
| `schema coverage` | `target:Target!`, `out:path?` | Every upstream leaf mapped to read/write/validate/export tests |
| `control list` | `object:ID?`, `domain:string?`, `changedOnly:bool=false` | Available controls, values and capability states |
| `control describe` | `key:string!`, `object:ID?` | Units, bounds, response, provenance, dependencies, symmetry, examples |
| `control set` | `object:ID!`, `values:ControlValues!`, `rangePolicy:error\|extrapolate=error` | Atomic typed control changes |
| `control reset` | `object:ID!`, `keys:string[]!`, `to:template\|revision=template`, `revision:int?` | Restore selected values |
| `control register` | `descriptor:ControlDescriptor!`, `binding:ControlBinding!` | Add a versioned native/template control; test it before activation |
| `control probe` | `object:ID!`, `key:string!`, `samples:number[]!`, `views:ID[]?` | Response curves, parameter-to-measurement sensitivity and renders |

`ControlBinding` is declarative (morph, landmark solve, bone transform, procedural
parameter, texture layer, material field or composite graph). Custom algorithms come
from explicitly installed backend packages, not executable code embedded in a model.
The default install operates offline; acquisition of external assets happens outside
the authoring loop and is recorded through `asset import`.

## Projects, transactions, jobs and recipes

| Command | Additional arguments | Result |
|---|---|---|
| `project init` | `dir:path!`, `template:ID?`, `target:Target=portable-vrm1`, `seed:uint64=0` | Empty or template-based project |
| `project inspect` | `include:string[]=summary` | Revision, asset tree, dependencies, stale objects and budgets |
| `project validate` | `level:schema\|references\|all=all` | Source-project integrity report |
| `project clone` | `dir:path!`, `revision:int?`, `includeBuilds:bool=false` | Independent project sharing content hashes |
| `project migrate` | `version:string!`, `lossPolicy:error\|report=error` | Planned/applied project format migration |
| `project pack` | `out:path!`, `includeBuilds:bool=false`, `includeReports:bool=true` | Portable project archive |
| `project unpack` | `file:path!`, `dir:path!` | Validate hashes/references then unpack |
| `project gc` | `keepRevisions:int=20`, `includeUnreferenced:bool=false` | Plan/remove unreferenced cache blobs only |
| `history list` | `limit:int=50` | Revision IDs and operations |
| `history diff` | `from:int!`, `to:int!`, `geometry:bool=false` | Semantic and optional geometric diff |
| `history restore` | `revision:int!` | New revision restoring selected snapshot |
| `transaction begin` | `label:string?` | Transaction ID and base revision |
| `transaction inspect` | `id:ID!` | Staged edits and invalidations |
| `transaction commit` | `id:ID!`, `validate:bool=true` | Atomic revision or conflict |
| `transaction abort` | `id:ID!` | Discard uncommitted edits |
| `job list` | `status:string?` | Job IDs and progress |
| `job status` | `id:ID!` | Progress, resource usage and artifacts |
| `job wait` | `id:ID!`, `waitSeconds:number=10` | Result or still-running status |
| `job cancel` | `id:ID!` | Cancel at next safe boundary |
| `job resume` | `id:ID!` | Resume checkpoint if inputs/backend match |
| `recipe inspect` | `file:path?` | Resolved recipe and defaults |
| `recipe apply` | request body `Recipe!` | Create/update full procedural graph |
| `recipe export` | `out:path!`, `resolved:bool=true` | Recipe with locked inputs |
| `recipe vary` | `variables:VariableRange[]!`, `count:int!`, `method:grid\|latin-hypercube\|random=random`, `out:path!` | Child recipes, no changes to parent |
| `recipe fit` | `targets:Goal[]!`, `variables:VariableRange[]!`, `search:SearchConfig!` | Candidate revision and residuals; explicit apply required |
| `serve` | `stdio:bool!`, `protocol:string=vrmauthor/1` | JSON RPC service; no GUI dependency |

## Universal object and asset editing

Every resource supports these commands, so every field in the parameter catalog is
readable, editable, duplicable and removable even if no specialized command mentions it.
Resource kinds: `avatar`, `node`, `mesh`, `selection`, `landmark`, `cage`, `modifier`,
`skin`, `bone`, `morph`, `expression`, `constraint`, `material`, `image`, `sampler`,
`texture`, `texture-layer`, `decal`, `hair-scalp`, `hair-guide`, `hair-group`,
`hair-clump`, `hair-bone-group`, `garment`, `pattern`, `seam`, `accessory`, `spring`,
`spring-joint`, `collider`, `collider-group`, `camera`, `light`, `environment`, `pose`,
`animation`, `scenario`, `qa-policy`, `style-binding`, `reference`, `template`.

| Command | Additional arguments | Result |
|---|---|---|
| `object list` | `kind:string?`, `selector:Selector?`, `fields:string[]?` | IDs and selected fields |
| `object get` | `id:ID!`, `path:JsonPointer?` | Typed object or field |
| `object create` | `kind:string!`, `id:ID?`, `data:ObjectData!` | Create object using its full schema |
| `object set` | `id:ID!`, `values:PointerValueMap!` | Set arbitrary writable fields without dropping siblings |
| `object unset` | `id:ID!`, `paths:JsonPointer[]!` | Remove optional values, restore specified inheritance |
| `object clone` | `id:ID!`, `newId:ID?`, `dependencies:share\|copy=share` | Clone with explicit shared-resource semantics |
| `object remove` | `ids:ID[]!`, `dependents:error\|cascade=error` | Delete or return dependency blockers |
| `object reorder` | `parent:ID!`, `field:JsonPointer!`, `order:ID[]!` | Explicit layer/chain/modifier ordering |
| `object transform` | `ids:ID[]!`, `transform:Transform!`, `space:Space=local`, `pivot:V3?`, `bake:bool=false` | Transform with dependency updates |
| `object mirror` | `ids:ID[]!`, `plane:Plane!`, `mode:copy\|replace=copy`, `bindings:mirror\|preserve=mirror` | Mirror geometry, side labels, rig and curves coherently |
| `asset import` | `file:path!`, `kind:string!`, `sha256:string?`, `provenance:Provenance!`, `options:ImportConfig={}` | Content-hashed asset and mapping/loss report |
| `asset export` | `id:ID!`, `format:string!`, `out:path!`, `options:ExportConfig={}` | Native item, mesh, curve or image artifact |
| `asset inspect` | `id:ID!`, `includeDependencies:bool=true` | Dimensions, schema, hash, origin and usage |
| `asset relink` | `id:ID!`, `file:path!`, `expectedSha256:string!` | Restore missing input without changing identity |
| `template list` | `category:string?` | Installed template IDs, versions and controls |
| `template instantiate` | `id:ID!`, `parent:ID?`, `values:ControlValues={}` | Expand a reusable native item |
| `template capture` | `objects:ID[]!`, `id:ID!`, `expose:string[]!`, `out:path!` | Save editable custom item with selected controls |
| `template install` | `file:path!`, `sha256:string!` | Install pinned native pack and schemas |
| `document inspect` | `build:ID?`, `pointer:JsonPointer=/` | Logical glTF/VRM object or compiled JSON |
| `document patch` | `operations:JsonPatch[]!`, `namespace:string!` | Schema-validated low-level spec edits using stable references |

Supported import baseline: VRM 1.0/0.x, GLB/glTF, OBJ, PNG/JPEG, SVG decal source,
OpenEXR authoring textures, JSON curves/weights/geometry/poses and native project/items.
Additional DCC/proprietary formats require named adapters in `capabilities`. Direct
edits of compiled byte offsets/array indices are not allowed: logical edits rebuild
references. Unknown extension payloads can be preserved opaquely, but cannot be called
validated/render-supported; export policy identifies unresolved index-bearing data.

## Selection, landmarks and mesh authoring

| Command | Additional arguments | Result |
|---|---|---|
| `select` | `mesh:ID!`, `query:Selector!`, `saveAs:ID?` | Stable vertex/edge/face selection and preview |
| `inspect pick` | `render:path!`, `pixel:int[2]!`, `layer:front\|all=front` | Object, triangle, barycentric location, UV and depth from an ID render |
| `geometry measure` | `config:GeometryMeasureConfig!`, `out:path?` | Arbitrary dimensions, distances, angles, areas and clearance maps |
| `selection combine` | `inputs:ID[]!`, `operation:union\|intersect\|subtract!`, `saveAs:ID!` | Combined selection |
| `selection grow` | `id:ID!`, `rings:int=1`, `distanceM:number?`, `barriers:string[]=seam,crease,material` | Expanded selection |
| `landmark fit` | `mesh:ID!`, `landmarks:ID[]!`, `targets:LandmarkTarget[]!`, `solver:DeformConfig!` | Deformation residuals and correspondence |
| `mesh primitive` | `id:ID?`, `shape:Primitive!` | Editable primitive mesh |
| `mesh generate` | `generator:body\|head\|eye\|mouth\|implicit!`, `config:GeneratorConfig!` | Procedural mesh with semantic regions |
| `mesh edit` | `mesh:ID!`, `edits:GeometryPatch!` | Explicit vertex/edge/face/per-corner attribute edits |
| `mesh extrude` | `selection:ID!`, `distanceM:number!`, `direction:V3?`, `segments:int=1`, `individual:bool=false`, `cap:bool=true` | Extruded topology and remap |
| `mesh inset` | `selection:ID!`, `distanceM:number!`, `individual:bool=false` | Inset faces |
| `mesh bevel` | `selection:ID!`, `widthM:number!`, `segments:int=2`, `profile:number=0.5`, `clampOverlap:bool=true` | Beveled edges |
| `mesh bridge` | `loops:ID[2]!`, `segments:int=1`, `twist:int=0` | Bridge ordered boundary loops |
| `mesh cut` | `mesh:ID!`, `path:SurfacePath!`, `split:bool=true`, `cap:bool=false` | Cut topology and new boundary IDs |
| `mesh weld` | `selection:ID!`, `distanceM:number=0.00001`, `preserveSeams:bool=true` | Weld map and rejected pairs |
| `mesh separate` | `mesh:ID!`, `by:selection\|island\|material!`, `selection:ID?` | Child meshes, preserving attributes |
| `mesh merge` | `meshes:ID[]!`, `weldDistanceM:number=0`, `preserveMaterials:bool=true` | Merged mesh and ID remap |
| `mesh boolean` | `left:ID!`, `right:ID!`, `operation:union\|difference\|intersect!`, `solver:exact\|sdf=exact`, `voxelM:number?` | Result, tolerance and transfer errors |
| `mesh subdivide` | `mesh:ID!`, `scheme:catmull-clark\|loop\|linear=catmull-clark`, `levels:int=1`, `boundary:preserve\|smooth=preserve`, `creaseSelection:ID?`, `crease:number=0` | Subdivision modifier or baked result |
| `mesh remesh` | `mesh:ID!`, `config:RemeshConfig!` | Remesh, attribute transfer and error report |
| `mesh retopologize` | `mesh:ID!`, `config:RetopologyConfig!` | Quad source cage and correspondence |
| `mesh decimate` | `mesh:ID!`, `config:DecimateConfig!` | Simplified topology with measured losses |
| `mesh deform` | `mesh:ID!`, `selection:ID?`, `config:DeformConfig!` | Deformed source mesh |
| `mesh sculpt` | `mesh:ID!`, `strokes:SculptStroke[]!` | Deterministic brush replay |
| `mesh project` | `mesh:ID!`, `target:ID!`, `config:ProjectionConfig!` | Shrinkwrap/conform projection |
| `mesh normals` | `mesh:ID!`, `config:NormalConfig!` | Normals/tangents, splits and diagnostics |
| `mesh repair` | `mesh:ID!`, `actions:RepairAction[]!`, `protected:ID[]=[]` | Explicit repairs; intended open boundaries preserved |
| `mesh transfer` | `source:ID!`, `target:ID!`, `attributes:string[]!`, `config:TransferConfig!` | UV/colour/normal/weight/morph transfer and error map |
| `mesh lod` | `mesh:ID!`, `levels:DecimateConfig[]!` | Independently exportable LOD meshes/avatars |
| `modifier evaluate` | `mesh:ID!`, `through:ID?`, `bake:bool=false` | Evaluate/bake ordered modifier stack |
| `mesh inspect` | `mesh:ID!`, `checks:string[]=all`, `out:path?` | Topology, regions, clearance, silhouette, attribute diagnostics |

## UVs, textures and materials

| Command | Additional arguments | Result |
|---|---|---|
| `uv seam` | `mesh:ID!`, `edges:ID[]!`, `mark:bool=true`, `set:int=0` | Seam edits |
| `uv unwrap` | `mesh:ID!`, `config:UvConfig!` | UV islands, distortion and overlap report |
| `uv edit` | `mesh:ID!`, `set:int=0`, `corners:CornerUv[]!` | Direct UV edits |
| `uv transform` | `mesh:ID!`, `islands:ID[]!`, `transform:UvTransform!`, `set:int=0` | Island transform |
| `uv pack` | `meshes:ID[]!`, `config:AtlasConfig!` | Packed UVs and image/material remaps |
| `uv export` | `mesh:ID!`, `set:int=0`, `width:int=2048`, `height:int=2048`, `out:path!` | PNG/SVG UV painting guide, region masks |
| `texture generate` | `generator:TextureGenerator!`, `config:TextureConfig!`, `material:ID?` | Layered procedural texture, seed and masks |
| `texture paint` | `layer:ID!`, `strokes:PaintStroke[]!` | UV/surface-space brush replay |
| `texture decal` | `layer:ID!`, `config:DecalConfig!` | Project/transform an image or vector decal |
| `texture fill` | `layer:ID!`, `selection:ID?`, `colour:Colour!`, `tolerance:U=0` | Fill region/layer |
| `texture filter` | `layer:ID!`, `config:FilterConfig!` | Nondestructive image filter |
| `texture bake` | `sources:ID[]!`, `target:ID!`, `config:BakeConfig!` | Bake material/maps without changing source layers |
| `texture flatten` | `image:ID!`, `colourSpace:linear\|srgb!`, `out:path?` | Composite layers to export texture |
| `texture resize` | `image:ID!`, `width:int!`, `height:int!`, `filter:lanczos\|box\|nearest=lanczos`, `alphaCoverage:bool=true` | Resized texture and mip policy |
| `texture inspect` | `image:ID!`, `channels:string[]=rgba`, `histogram:bool=true` | Colour/alpha/size/coverage measurements |
| `material assign` | `material:ID!`, `selection:ID!` | Primitive/material assignment |
| `material role` | `material:ID!`, `role:MaterialRole!` | Explicit style role binding |
| `material shading` | `material:ID!`, `shadowEnd:number!`, `terminatorWidth:number!` | Solve explicit MToon toony/shift; retain target metadata |
| `material convert` | `material:ID!`, `to:mtoon\|pbr\|unlit!`, `lossPolicy:error\|report=error` | Converted material plus loss report |
| `material atlas` | `materials:ID[]!`, `config:AtlasConfig!`, `mergePolicy:compatible\|keep-separate=compatible` | Atlas compatible textures; preserve roles/queues |

Materials, samplers, texture slots, layers and their order use universal object commands
for creation and all parameter edits; no shader field is hidden behind a preset.

## Skeleton, weights, morphs and expression authoring

| Command | Additional arguments | Result |
|---|---|---|
| `rig generate` | `avatar:ID!`, `config:RigConfig!` | Full humanoid, optional fingers/toes and auxiliary bones |
| `rig map` | `avatar:ID!`, `bones:HumanoidMap!` | Explicit humanoid mapping |
| `rig fit` | `avatar:ID!`, `landmarks:ID[]!`, `constraints:Goal[]= []`, `maxIterations:int=100` | Fit joints and report residuals |
| `rig normalize` | `avatar:ID!`, `pose:ID!`, `bakeTransforms:bool=true`, `rebind:bool=true` | Normalize coordinates/rest pose with full remap |
| `rig inspect` | `avatar:ID!`, `checks:string[]=all` | Hierarchy, mapping, T-pose and bind checks |
| `skin bind` | `mesh:ID!`, `rig:ID!`, `config:SkinConfig!` | Weights, inverse binds and quality maps |
| `skin edit` | `skin:ID!`, `weights:WeightPatch!`, `normalize:bool=true` | Explicit per-vertex influences |
| `skin smooth` | `skin:ID!`, `selection:ID?`, `iterations:int=5`, `strength:U=0.5`, `lockedBones:ID[]=[]` | Smoothed weights respecting regions |
| `skin normalize` | `skin:ID!`, `maxInfluences:int=4`, `minimumWeight:U=0.0001`, `lockedBones:ID[]=[]` | Normalize/prune with discarded-weight report |
| `skin transfer` | `source:ID!`, `target:ID!`, `config:TransferConfig!` | Garment/accessory weight transfer |
| `skin rebind` | `skin:ID!`, `restPose:ID!`, `preserveShape:bool=true` | Recomputed inverse binds and dependent shape data |
| `morph generate` | `mesh:ID!`, `config:MorphGeneratorConfig!` | Actual target deltas and semantic names |
| `morph capture` | `base:ID!`, `deformed:ID!`, `name:string!`, `correspondence:ID?`, `attributes:string[]=position,normal` | Target deltas from two meshes |
| `morph edit` | `morph:ID!`, `deltas:MorphPatch!` | Direct sparse/full delta edits |
| `morph transfer` | `source:ID!`, `target:ID!`, `config:TransferConfig!` | Corresponding targets and residuals |
| `morph combine` | `mesh:ID!`, `terms:MorphTerm[]!`, `name:string!`, `clamp:bool=false` | Explicit composite target |
| `morph corrective` | `mesh:ID!`, `pose:ID!`, `target:ID!`, `driver:CorrectiveDriver!` | Pose corrective; portability report |
| `expression generate` | `avatar:ID!`, `presets:string[]!`, `config:ExpressionGeneratorConfig!` | Morphs and working VRM preset/custom bindings |
| `expression bind` | `expression:ID!`, `config:ExpressionConfig!` | Set morph/material/UV binds and overrides |
| `expression sample` | `values:ExpressionWeights!`, `pose:ID?`, `out:path?` | Evaluated preview and active-target counts |
| `expression optimize` | `avatar:ID!`, `combinations:ExpressionWeights[]!`, `maxActivePerPrimitive:int=8`, `maxErrorM:number=0.0005` | Bounded basis proposal; never silently drops channels |
| `lookat configure` | `avatar:ID!`, `config:LookAtConfig!` | Gaze model and range maps |
| `lookat sample` | `target:V3!`, `space:Space=world`, `out:path?` | Bone/expression gaze result and clipping report |
| `firstperson configure` | `avatar:ID!`, `annotations:FirstPersonAnnotation[]!` | VRM visibility bindings |
| `constraint create` | `node:ID!`, `config:ConstraintConfig!` | Aim/roll/rotation constraint, checked for cycles |
| `pose apply` | `pose:ID!`, `as:preview\|rest=preview`, `rebind:bool=false` | Preview or explicit rest-pose update |
| `animation retarget` | `animation:ID!`, `avatar:ID!`, `animRest:ID!`, `modelRest:ID!`, `options:RetargetConfig={}` | Retargeted preview animation with immutable rest sources |

## Hair and wearable construction

| Command | Additional arguments | Result |
|---|---|---|
| `hair scalp` | `head:ID!`, `config:ScalpConfig!` | Scalp mask, UV domain and root attachment surface |
| `hair guide` | `scalp:ID!`, `config:HairGuideConfig!` | Editable guide surface/field |
| `hair generate` | `guide:ID!`, `config:HairGroupConfig!` | Seeded clump curves with stable root/tip IDs |
| `hair draw` | `group:ID!`, `strokes:HairStroke[]!` | Freehand clumps projected onto guide |
| `hair retouch` | `group:ID!`, `strokes:HairStroke[]!`, `influenceM:number=0.02`, `strength:U=0.5` | Locally edited guides/clumps |
| `hair resample` | `clumps:ID[]!`, `maxSegmentM:number=0.01`, `maxAngleDeg:number=5`, `maxPoints:int=128` | Curvature-aware samples |
| `hair smooth` | `clumps:ID[]!`, `toleranceM:number=0.001`, `preserveEnds:bool=true` | Reduced control points with deviation report |
| `hair convert` | `group:ID!`, `to:freehand!`, `retainGenerator:bool=true` | Editable clumps plus retained procedural history |
| `hair braid` | `guide:ID!`, `config:BraidConfig!` | Braid/bun/rope carrier and clump curves |
| `hair avoid` | `clumps:ID[]!`, `obstacles:ID[]!`, `config:HairAvoidConfig!` | Collision-aware rest curves and residuals |
| `hair mesh` | `group:ID!`, `config:HairMeshConfig!` | Mesh, UVs, source-to-vertex mapping |
| `hair atlas` | `groups:ID[]!`, `config:HairTextureConfig!`, `atlas:AtlasConfig!` | Root/tip/highlight textures and UV allocation |
| `hair rig` | `groups:ID[]!`, `config:HairRigConfig!` | Bone groups, skin weights and optional springs |
| `hair regroup` | `clumps:ID[]!`, `boneGroup:ID!`, `mode:move\|remove=move` | Membership edit and invalidations |
| `hair axis` | `boneGroup:ID!`, `mode:center\|clump\|curve!`, `source:ID?` | Refit group axis after hair edits |
| `hair inspect` | `groups:ID[]!`, `checks:string[]=all`, `out:path?` | Scalp coverage, clearance, flips, UVs and complexity |
| `garment generate` | `avatar:ID!`, `config:GarmentConfig!` | Template/parametric wearable with editable regions |
| `garment pattern` | `garment:ID!`, `config:PatternConfig!` | 2D panels, seam graph and initial 3D placement |
| `garment fit` | `garment:ID!`, `body:ID!`, `config:GarmentFitConfig!` | Fit/shrinkwrap and clearance report |
| `garment drape` | `garment:ID!`, `scenario:ID!`, `config:ClothConfig!` | Offline draped source shape; optional pose samples |
| `garment layer` | `garments:ID[]!`, `order:ID[]!`, `clearanceM:number=0.002` | Layer constraints and body-coverage masks |
| `garment mask` | `garment:ID!`, `body:ID!`, `config:CoverageMaskConfig!` | Reversible skin mask; pose-tested before export |
| `garment rig` | `garment:ID!`, `config:GarmentRigConfig!` | Transferred body weights and optional spring strips |
| `accessory generate` | `avatar:ID!`, `config:AccessoryConfig!` | Glasses/ears/jewellery/ribbon/tail/custom mesh |
| `accessory attach` | `accessory:ID!`, `node:ID!`, `transform:Transform!`, `mode:rigid\|skinned=rigid` | Attachment and local frame |

Visibility, per-clump edits, group/material assignment, duplicate, flip, rename and
delete are universal object operations. Hair geometry groups, bone groups and material
groups are separate objects: changing one grouping does not implicitly overwrite others.

## Springs, colliders and motion fitting

| Command | Additional arguments | Result |
|---|---|---|
| `spring generate` | `source:ID!`, `config:SpringGeneratorConfig!` | Ordered chains, tails, joints and groups |
| `spring configure` | `spring:ID!`, `config:SpringConfig!` | All chain and per-joint values |
| `spring profile` | `springs:ID[]!`, `values:SpringProfiles!` | Sample root-to-tip parameter curves |
| `spring split` | `spring:ID!`, `atJoint:ID!`, `attachment:ID!` | Valid nonoverlapping chains; remap skin if required |
| `spring fit` | `springs:ID[]!`, `scenarios:ID[]!`, `targets:MotionGoal[]!`, `search:SearchConfig!` | Calibrated candidates, residuals and compatibility report |
| `collider generate` | `meshes:ID[]!`, `rig:ID!`, `config:ColliderFitConfig!` | Authored sphere/capsule approximation and error map |
| `collider configure` | `collider:ID!`, `config:ColliderConfig!` | Node-local collider shape and fallback |
| `collider assign` | `groups:ID[]!`, `springs:ID[]!`, `mode:replace\|append\|remove=append` | Explicit collision membership |
| `physics configure` | `config:PhysicsPreviewConfig!` | Preview-only solver settings, separate from VRM fields |
| `physics simulate` | `scenario:ID!`, `config:SimulationConfig!`, `out:path!` | Trajectories, penetration metrics, optional clip |
| `physics reset` | `scenario:ID?` | Discard preview state, restore authored rest state |
| `physics bake` | `simulation:ID!`, `mode:rest-shape\|animation\|morph-sequence!`, `out:path?` | Explicit bake; runtime/export loss report |

No `ccd=all` operation exists. `PhysicsPreviewConfig` permits `ccd=off` or
`synthetic-only`, enforcing the authored-collider invariant from the main proposal.

## Style, inspection, repair and output

| Command | Additional arguments | Result |
|---|---|---|
| `style attach` | `profile:path!`, `sha256:string?`, `roleMap:RoleMap!` | Pinned profile binding |
| `style apply` | `binding:ID!`, `rules:string[]?`, `variables:string[]?`, `policy:goals\|fit=goals` | Install goals or propose measured fitting edits |
| `style measure` | `file:path?`, `binding:ID?`, `out:path?` | Raw measurements, definitions and coverage |
| `style lint` | `binding:ID!`, `file:path?`, `out:path?` | Rule-level results and separate completeness verdict |
| `style explain` | `rule:string!`, `binding:ID!` | Provenance, metric definition, contributing subjects and controls |
| `render image` | `config:RenderConfig!`, `out:path!` | PNG/EXR image and ID/depth/normal overlays |
| `render views` | `config:RenderConfig!`, `views:ViewSpec[]!`, `out:path!` | Contact sheet and individual images |
| `render turntable` | `config:RenderConfig!`, `durationSeconds:number=4`, `fps:int=30`, `out:path!` | Video and camera path |
| `render expressions` | `config:RenderConfig!`, `combinations:ExpressionWeights[]!`, `out:path!` | Face sheets and active-target diagnostics |
| `qa plan` | `suite:QaSuite!`, `target:Target?`, `policy:ID?`, `out:path!` | Resolved plan with checks, views, motions and thresholds |
| `qa run` | request body `QaPlan!`, `out:path!` | All required checks and evidence, no skipped-success |
| `qa geometry` | `objects:ID[]?`, `config:GeometryQaConfig!`, `out:path?` | Mesh/rig/UV/clearance checks |
| `qa expressions` | `config:ExpressionQaConfig!`, `out:path!` | Binding effectiveness, combinations, clipping, basis limits |
| `qa motion` | `scenarios:ID[]!`, `config:MotionQaConfig!`, `out:path!` | Pose/motion clearance and stability results |
| `qa compare` | `baseline:path!`, `candidate:path!`, `config:CompareConfig!`, `out:path!` | Numeric and aligned image differences |
| `qa coverage` | `target:Target!`, `policy:ID?` | Fields, roles, controls and required checks missing evidence |
| `repair propose` | `report:path!`, `allowed:string[]?`, `maxEdits:int=20`, `out:path!` | Version-bound, constrained repair plan |
| `repair apply` | request body `RepairPlan!` | Atomic edits with explicit preconditions and post-checks |
| `repair search` | `plan:path!`, `search:SearchConfig!`, `out:path!` | Candidate revisions ranked by declared objective |
| `build` | `target:Target!`, `out:path!`, `config:BuildConfig={}` | Reproducible draft VRM, index map and compilation report |
| `export vrm` | `target:Target!`, `out:path!`, `config:ExportConfig={}` | Gated final VRM 1.0 or explicit legacy conversion |
| `export gltf` | `out:path!`, `binary:bool=true`, `config:ExportConfig={}` | GLB or glTF debug/interchange output |
| `export item` | `objects:ID[]!`, `out:path!`, `includeSources:bool=true` | Native reusable custom item |
| `export verify` | `file:path!`, `suite:QaSuite!`, `out:path?` | Fresh reimport, spec and requested visual/motion tests |
| `deliver` | `file:path!`, `out:path!`, `includeProject:bool=true`, `includeReports:bool=true` | VRM, project, previews, source/asset manifest and evidence |

`Target` = `portable-vrm1`, `extended-vrm1`, `vrmmetalkit`, `legacy-vrm0`.
`spec+style` and `authoring-v1` are the v1 suite names defined in
[commands.md](commands.md). Reserved `QaSuite` values are additional suites: `spec`,
`style`, `geometry`, `expressions`, `motion`, `visual`, `authoring-full`. Suites are
versioned configurations, not permanently hard-coded test lists. `authoring-full`
includes all six other reserved suites and export round-trip.
Final export requires metadata and all policy-required evidence at the same input
revision. Draft builds may be incomplete but must still be structurally readable.

## Reserved verification requirements (Stage C)

The requirements below are Stage C prerequisites for promoting the reserved commands
they name. None gates the v1 release; v1 evidence levels, the v1 visual gate and the
v1 evaluator are defined in [verification.md](verification.md).

### Operation oracles

| Operation class | Required evidence beyond return status |
|---|---|
| Retopology (`mesh retopologize`, `mesh remesh`) | Eyelid/lip loops and openings retained; blink closure and viseme combinations; silhouette/morph transfer error; deliberately wrong but manifold mesh rejected by semantic and visual checks |
| Boolean (`mesh boolean`) | Disjoint/contained/touching/coplanar/near-degenerate inputs; winding/volume/region preservation; scale tests; analytic cases plus independent differential checks; differences adjudicated, not blindly copied |
| Subdivision (`mesh subdivide`) | Known stencils/limit positions, boundary and crease cases, extraordinary vertices, UV seams and topology counts; independent reference comparisons |

The Garment fit and Hair/springs oracle rows stay in
[verification.md](verification.md): v1 reaches those operation classes through
`control set`, `recipe apply` and `build` on hair and outfit items, and their checks
live inside the control-set and build packs.

### Wrap versus own: verification cost per operation

Each geometry backend decision for `mesh boolean`, `mesh subdivide` and the other
reserved mesh operations records candidate implementation/source/license hashes,
supported input domain, independent references, failure corpus,
robustness/determinism requirements, integration cost and ongoing
verification/maintenance cost. Prefer the candidate with the lowest justified total
cost at the same acceptance standard. Cheap code generation does not establish cheap
numerical correctness.

Manifold and OpenSubdiv are candidate wrappers and differential references, not
mandatory implementations. An owned kernel is viable when its oracle is strong enough;
otherwise use a tested wrapper or leave qualification pending. Neither candidate may
serve as its own sole oracle. Owned booleans need analytic truth cases and a
substantial near-degenerate/adversarial corpus as well as differential tests. Record
reasons for any disagreement. Wrapping retains dependency licensing obligations;
owning requires source/ingredient provenance and does not automatically remove
derivation questions.

### Renderer worker fleet and evidence scheduling

Prerequisite for `async`, the `job *` commands and fleet-scheduled `render *`, `qa *`
and `physics simulate` evidence. Renderer workers advertise device/driver/backend
versions, memory, supported scenarios and queue capacity. Jobs are hash-addressed;
identical input/scenario/backend hashes deduplicate, artifacts are preserved,
per-project quotas apply, and final qualification outranks speculative repair
variants. Cache reuse requires an exact evidence key; a changed implementation or
renderer cannot reuse stale traces. Render frames, motion samples, judge calls and
GPU minutes are budgeted separately from code-generation work. Inflight work and
retries are bounded; saturation returns job status `queued` and evidence status
`pending`, not pass.

The coordinator may schedule multiple Mac workers behind the same artifact contract.
Fleet size follows measured acceptance-pack cost and required turnaround; a single
Mac Studio is not assumed to serve arbitrary swarm throughput. Worker receipts are
recorded and a sample of jobs is rerun across devices to detect hardware-specific
errors. Persisted scheduling lives in an external evaluation service before the
reserved async job commands graduate.

### Sealed holdout cohort, evaluation budget and evaluation service

Prerequisite for every reserved command whose required level is corpus-validated or
visually-validated. A sealed holdout cohort disjoint from the development corpus, a
per-release evaluation budget, and an isolated evaluation/admission service that
holds the cohort and spends the budget replace the v1 evaluator. These are not v1
gates because no evaluation service exists; v1 corpus validation runs across the
development corpus families with per-family reporting.

### Judge calibration with confidence intervals

Prerequisite for every reserved command with a visual dimension. Judge accuracy is
reported with confidence intervals over a calibration set sized for them, a second
adjudicator samples disagreements, and an audit set is re-judged per release. These
are not v1 gates because they depend on the evaluation service above; v1 uses the
frozen calibration set with zero false accepts defined in
[verification.md](verification.md).

### Linux CPU workers, software rasterizer and CPU spring reference

Prerequisite for CPU screening of reserved mesh, garment and `qa geometry` work and
for numerical fixtures of `physics simulate`, `spring fit` and `physics bake`. Geometry
validity, semantic landmarks, skin/morph evaluation, analytic collision queries and
sampled penetration sweeps run on Linux CPU workers; a pinned scalar software
rasterizer provides deterministic depth, silhouette, normals and mask probes; a CPU
spring reference is compared to the Metal implementation within declared tolerances.
Reference results never certify Metal MToon, transparency, outlines or GPU spring
behaviour, and Linux-only work cannot report a completed visual gate. These are not
v1 gates because GLTFCore imports Metal and SpringBone is compute-only, so no CPU
path exists to reference.
