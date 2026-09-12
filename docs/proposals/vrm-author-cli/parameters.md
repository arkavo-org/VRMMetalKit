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

# V1 parameter contract

Part of the [proposal](README.md); [commands.md](commands.md) is the v1 allowlist.
[Reserved parameters](reserved-parameters.md) preserve the broader design without
making advanced geometry/solver coverage a release requirement. These are native
controls, not pixiv slider mappings. The internal workflow tracker records exclusions.

## Types, defaults and schema rules

`!` means required; `?` means absent unless supplied. All numbers must be finite.
`ID` is a stable project identifier; `Hash` is lowercase SHA-256 hex; `Blob` is
`{path:string!, sha256:Hash!}`. Inputs are verified before use. `B` is [-1,1], default
0; `U` is [0,1]. `V2/V3/V4` have exactly 2/3/4 numeric elements. Metres, degrees,
radians and normalized values are distinct descriptor units. `Colour` is
`{rgba:V4!, space:linear|srgb=linear}` with components [0,1].
`Transform` is translation metres `[0,0,0]`, unit quaternion `[0,0,0,1]` and positive
scale `[1,1,1]`. IDs and names are never interchangeable.

Every pack default is an explicit value in its hashed manifest, returned by
`recipe export --resolved`; a missing value rejects the pack. Pack defaults cannot
widen contract validity bounds. Descriptors distinguish validity limits, recommended
calibrated range and empirical style target. Endpoints outside a pack's calibrated
range are rejected, not clamped silently. Unknown keys are errors. No unconstrained
`extras` object permits undeclared functionality.

`ControlEdit={object:ID!, values:map<controlKey,typedValue>!}`.
`ObjectEdit={id:ID!, values:map<RFC6901Pointer,typedValue>!}`.
An edit validates the complete object and its dependencies atomically. Every result
identifies invalidated geometry, rig, morph, fit, texture and QA nodes as applicable.
`ObjectKind` is avatar, mesh, material, image, texture-layer, hair, garment, accessory,
node, humanoid, expression, lookat, firstperson, spring, collider or collider-group.
Source meshes/nodes may be read-only; `object list/get` returns writable pointers.

## Recipe and production template

`Recipe` fields are `schemaVersion:"1.0"!`, `name:string!`,
`template:{id:ID!,sha256:Hash!}!`, `target:portable-vrm1=portable-vrm1`, `seed:uint53=0`,
`body:ControlValues!`, `face:ControlValues!`, `hair:HairItem[]!`,
`outfits:OutfitItem[]!`, `accessories:AccessoryItem[]=[]`, `textures:Layer[]!`,
`materials:Material[]!`, `expressions:Expression[]!`, `lookAt:LookAt!`,
`springs:Spring[]!`, `colliders:Collider[]!`, `colliderGroups:ColliderGroup[]!`,
`style:Blob!`, `rights:RightsDeclaration!`. Template fields resolve from the pack;
callers normally modify an exported resolved recipe. A partial control edit uses
`control set`, not an ambiguously merged partial recipe.

`native-anime-v1` supplies an original quad mesh, UVs, semantic regions, calibrated
shape basis, humanoid bind/weights, sculpted globe eyes, eyelid/lip morphs, inner mouth,
MToon roles, a bob, top/bottom/footwear, glasses/earrings and QA scenarios. It includes
real blink, blinkLeft, blinkRight, aa/ih/ou/ee/oh and happy/angry/sad/relaxed/surprised
morphs; neutral represents the rest state. Pack constructors must record provenance and budget/validate these
assets as specified in README §6 and [verification.md](verification.md). Pack constants and endpoint fixture hashes are
inspectable but not editable controls. No field below implies a retopology solver.

## Native body and face controls

The following is the complete v1 native shape-key allowlist. `B` endpoints are
provenance-recorded, independently qualified deformations whose exact responses belong to the pinned pack.
All bilateral keys replace `{side}` with `left` or `right`; omitted mirror behaviour
is independent sides. Global controls update associated bind/fit/morph data together.

| Keys | Unit / default | Required response |
|---|---|---|
| `body.heightM` | metres [1.2,2.0], 1.65 | Overall stature; preserve relative shape |
| `body.headCount` | ratio [4.5,8], 6.6 | Head/body proportion; reconcile with fixed total height |
| `body.proportion.shoulderWidth`, `torsoLength`, `armLength`, `legLength`, `hipWidth` | B; each uses `body.proportion.` prefix | Calibrated regional proportions and dependent fit |
| `body.shape.chest`, `waist`, `hip`, `muscle` | B; each uses `body.shape.` prefix | Original body basis, including fitted outfit response |
| `face.head.width`, `face.head.depth`, `face.jaw.width`, `face.chin.length`, `face.chin.pointedness` | B | Head silhouette while preserving mouth/eye loops |
| `face.eye.{side}.height`, `width`, `spacing`, `tilt` | B; each uses side-specific eye prefix | Eyelid/globe/pivot response; tilt is a blend, not degrees |
| `face.iris.{side}.size`, `face.pupil.{side}.size` | U, defaults from pack | Static iris/pupil geometry/texture region scale |
| `face.brow.{side}.height`, `angle`, `thickness` | B; each uses side-specific brow prefix | Brow shape/layer calibration |
| `face.nose.height`, `face.nose.width`, `face.nose.projection` | B | Nose basis |
| `face.mouth.width`, `face.mouth.height`, `face.lip.fullness` | B | Lip basis with viseme preservation |
| `face.ear.{side}.size`, `face.ear.{side}.angle` | B | Ear basis and accessory attachment |

Combined endpoint fixtures test dependencies, including extreme height/headCount,
eye size/blink and shoulder width/outfit fit. A numerical control change must have a
measurable effect or return an explicit no-op finding. Additional shape controls in
the reserved catalog are not accepted until promoted with a qualified construction basis.

## Hair, outfits and accessories

`HairItem={id:ID!, preset:"bob-v1"!, controls:HairControls!, texture:HairTexture!}`.

| HairControls field | Type / default | Effect |
|---|---|---|
| `lengthM` | metres [0.12,0.30]=0.18 | Calibrated guide extension and regenerated bone positions |
| `widthScale` | [0.75,1.25]=1 | Clump width deformation |
| `tipBendDeg` | degrees [-20,30]=12 | Template tip bend |
| `bangClearanceM` | metres [0.002,0.02]=0.005 | Forehead/eye clearance within calibrated guide basis |

`HairTexture={baseColour:Colour!,rootColour:Colour!,tipColour:Colour!,
highlightOpacity:U=0.25,highlightWidth:U=0.12}`. Longitudinal UVs, clump/root count,
scalp attachment correspondences, bone layout and tessellation are pack constants.
Hair material fields and every generated standard spring joint remain editable.
Freehand guides, arbitrary clump additions, braids and SDF avoidance are reserved.

`OutfitItem={id:ID!,preset:ID!,enabled:bool=true,layer:int[0,8]=0,
controls:{length:B=0,fit:B=0}!,materialIds:ID[]!}`. Installed top, bottom and footwear
presets declare their permitted layer combinations, own masks and supported control
keys (footwear may expose fit only). Fit uses precomputed body correspondences;
unsupported combinations or collision failures block the QA gate. No XPBD draping
or arbitrary clothing patterns are implied.

`AccessoryItem={id:ID!,preset:glasses-v1|earring-v1|cat-ears-v1!,attachment:ID!,
transform:Transform=identity,materialIds:ID[]!,enabled:bool=true}`. The attachment is
a declared rig node; earring pairs are separate items. Scale/transform permits
placement and size edits without topology changes. Spring earrings are reserved.

## Textures and MToon

`Layer={id:ID!,targetImage:ID!,kind:solid|image!,colour:Colour?,image:ID?,
mask:ID?,opacity:U=1,blend:normal|multiply|screen=normal,
uvOffset:V2=[0,0],uvScale:V2=[1,1],uvRotationDeg:number=0,enabled:bool=true}`.
Solid layers require colour; image layers require image. Array order determines
compositing. Masks are installed UV masks or imported images; v1 has no brush/SVG
execution. Images specify `width,height:int[1,4096]`, `colourSpace:srgb|linear`,
`usage:colour|normal|mask`; pack defaults resolve actual size. Bake in linear,
unpremultiplied colour with specified normal-map handling and pinned PNG encoder.
Texture slots declare UV set, sampler/wrap and KHR_texture_transform explicitly.

`Material={id:ID!,role:MaterialRole!,gltf:object!,mtoon:object!}` uses the complete
supported glTF metallic-roughness and stable VRMC_materials_mtoon 1.0 field schemas,
with texture references replaced by stable IDs. This includes base/shade colour and
textures, transparency/cutoff/culling, normals and scale, emissive, matcap, rim,
shading shift/toony/GI equalization, outline mode/width/colour/lighting, render queue
and UV animation speeds. Texture transforms use the pinned KHR schema. Runtime
`schema show Material` must enumerate every leaf; field coverage tests prevent
silently omitted factors. Reject other material extensions unless explicitly added
and tested. See the [MToon schema and semantics](https://github.com/vrm-c/vrm-specification/tree/master/specification/VRMC_materials_mtoon-1.0).

`MaterialRole` is face_skin, body_skin, hair, cloth, accessory, iris, eye_white,
eye_highlight, eyeline, eyelash, brow, mouth or other. Unknown role coverage blocks
required style checks. `material shading` computes toony=`1-width/2`,
shift=`toony-1-shadowEnd`; reject illegal factors rather than clamp. These are direct
lighting factor goals, not guaranteed pixel appearance. UV animation remains a
material field, but v1 native globe gaze does not depend on it.

## Rig, expression, gaze, spring and first-person fields

Standard payloads use the pinned VRM 1.0 and glTF schemas with stable IDs replacing
export array indices. Public `schema show` returns the fully expanded projection;
all standard fields listed below must be enumerated and tested, never arbitrary JSON.
Schema pins and hashes are recorded in Stage A; export qualification follows the
frozen operation acceptance pack before release admission.

| Object | Editable v1 fields and constraints |
|---|---|
| Humanoid | Full standard humanBones map to node IDs; required/optional bones validated. Native pack mapping is fixed; imported mapping may be corrected without inventing a new rig |
| Expression | `id`, `preset` or custom name; `isBinary`; overrideBlink/LookAt/Mouth; morphTargetBinds (mesh, target, weight); materialColorBinds; textureTransformBinds. Use exact standard enums/ranges. References must target existing actual geometry/materials |
| LookAt | offsetFromHeadBone and four inputMaxValue/outputScale range maps; native type=bone. Preserve imported expression mode and bindings; native expression-mode gaze generation reserved |
| FirstPerson | meshAnnotations (mesh ID and auto/both/thirdPersonOnly/firstPersonOnly) |
| Spring | id/name, optional center node, ordered joints and collider-group IDs. Joints expose node, hitRadius, stiffness, gravityPower, gravityDir and dragForce with standard defaults/ranges |
| Collider | node ID and exactly sphere(offset,radius) or capsule(offset,radius,tail); radii nonnegative metres; offsets node-local metres |
| ColliderGroup | id/name, collider ID list |

Spring stiffness and gravityPower are nonnegative with no invented upper cap of 1;
dragForce is [0,1], gravityDir has explicit vector units/standard validation, and zero
gravity is preserved. Standard defaults come from the pinned schema, not guessed
physical mass mappings. Native spring bone topology is pack-owned; agents can edit
joint values and collider membership/shape without introducing overlapping chains.
Terminal tail nodes are required. Authored colliders never enable synthetic-only CCD.
Extended colliders, angle limits, offline cloth and auto-calibration remain reserved.

Skin weights, bind matrices, native expression deltas, node rest transforms and
humanoid generation are template-derived and inspectable but read-only in v1.
Imported morph/skin data is preserved; arbitrary weight painting, sculpted new morphs,
constraints and skin transfer remain reserved. The full generated avatar therefore
works without implementing general rigging or sculpting tools.

## Assets, rights and credentials

`AssetImport={path:string!,kind:vrm|gltf|png|jpeg!,manifestPath:string?,
sourceUri:string?,generation:Generation?,declaration:RightsDeclaration?}`.
Import copies hashed bytes and validates embedded/external credentials if present.
`Generation={tool:string!,model:string?,version:string!,inputHashes:Hash[]=[],
action:string!,digitalSourceType:string?,record:Blob?}` records known facts only;
private prompts are not required. Generation by the importer is distinct from
previous generation claims. Unknown source history remains unknown.

`RightsDeclaration={id:string!,declarant:string!,evidence:Blob[]!,
authors:string[]!,meta:VRMMeta!,training:TrainingClaims?}`. `VRMMeta` covers all fields
of the pinned VRMC_vrm 1.0 meta schema, including name/version/authors/licenseUrl,
copyright/contact/references/thumbnail and all avatar/commercial/violent/sexual/
political/religious/antisocial/credit/redistribution/modification/license URL fields.
References use image IDs where upstream uses indices. Actual required fields and
legal enum values are governed by that schema. The declaration authors must match its resolved meta authors or fail validation.
Evidence may include a locally
provided rights statement; author identity is not inferred from the signer.

`TrainingClaims` maps the four CAWG entries (`cawg.data_mining`, `cawg.ai_inference`,
`cawg.ai_training`, `cawg.ai_generative_training`) to
`{use:allowed|notAllowed|constrained!,constraint_info:string?}`. Omission remains
absence, not permission. This native payload serializes through the pinned CAWG
assertion schema, not a hand-built claim with invented labels. AI origin is separately
recorded through generation actions. No training field sets VRM usage rights.

`provenance resolve` emits field-by-field attribution/conflict results. Metadata edits
must update the declaration through this command or Recipe; object editing cannot
bypass the rights ledger. C2PA signatures, trust validation and generation claims
remain separate evidence. Signer/trust policies are configured resources; signer
references are strings, never private keys in the project. See README §9 for delivery
binding, ingredient preservation, missing-source and unknown-rights treatment.

## QA and inspection

`QARequest` is exactly one of `{file:path!,suite:spec+style|authoring-v1!}`,
`{plan:Blob!}`, or `{acceptance:{pack:Blob!,candidateBuild:Hash!}!}`. The acceptance
form is available only in an isolated evaluator session, using an installed candidate
build and reviewed executable pack; an imported asset cannot install executable code. A plan binds file hash, project revision, profile/threshold hashes,
required scenario IDs, renderer configuration and consumer pins. Users may select
additional checks; removing required scenarios cannot yield authoring-v1 completion.
Stage A fixes the suite/acceptance contracts. Stage B exercises `spec+style` as an
integration scenario and requires the full `authoring-v1` suite for delivery. See
verification.md for judge-family separation, corpus policy and scoped evidence
admission, and reserved.md for CPU/Metal work allocation (Stage C); an inspection
record alone cannot elevate command qualification.

Render plans expose camera position/target/up in metres, projection perspective or
orthographic, fovDegrees or orthographicHeightM, dimensions, background RGBA,
exposureEV, light type/direction/colour/intensity, pose and expression weights,
frame times and renderer/device identity. Canonical defaults live in a hashed QA
scenario pack. These fields are discoverable for extra views; required scenario
values stay locked across candidates. Motion plans include fixed timestep/duration,
input animation hashes, collider overlay, tip/penetration metrics and thresholds.
Missing renderer capability returns incomplete. A configured remote worker takes
hashed inputs and returns hashed artifacts, without changing revision semantics.

`Inspection={artifactHash:Hash!,buildHash:Hash!,revision:int!,scenarioId:string!,
actor:string!,actorVersion:string!,rubricHash:Hash!,timestamp:string!,
findings:string[]!,verdict:pass|fail|uncertain!,
scoring:{inputHashes:Hash[]!,response:Blob!,thresholds:Blob!}?}`.
The report lists all required artifacts and their accepted records; an empty record
list cannot pass visual QA. Changed hashes invalidate records. Logged automated
scoring and human/agent attestations are labeled distinctly, with their limitations.

The v1 repair loop belongs to the calling agent: inspect, edit bounded supported
controls with exact dry-run plans, rebuild and rerun checks under its attempt budget.
No general optimizer, retopology repair or solver is needed to call v1 complete.
