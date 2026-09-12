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

# Worked v1 authoring session

This is the Stage B acceptance scenario; every command it invokes is runnable.
Every invocation belongs to the [v1 catalog](commands.md); payloads are defined in
[parameters.md](parameters.md). Reserved solvers are not needed to finish the avatar.

Brief: a 1.65 m anime avatar, compact face, short brown bob, blue irises, a fitted
layered outfit, working speech/blinks/emotions and stable hair motion. The installed
original pack supplies globe eyes and bone gaze. Produce portable VRM 1.0, editable
source, signed credentials and inspected QA evidence.

## Resolve the installed pack and rights

```bash
vrm-author capabilities --evidence-policy production-policy.json
vrm-author template list --category avatar
vrm-author project init --dir avatar.vrmauthor --template native-anime-v1 --seed 42
vrm-author recipe export --project avatar.vrmauthor --resolved true --out base.recipe.json
vrm-author control list --project avatar.vrmauthor --object avatar:main
```

The configured `production-policy.json` imposes command-specific evidence requirements
from the release policy. The agent checks current qualification and tested input scope,
not merely handler availability, then obtains actual IDs/hashes/defaults from the results. The pack must ship
body/face, one complete bob, fitted outfit layers, texture masks, real expression
geometry and canonical scenarios. A prototype pack cannot qualify for v1 delivery.

Before applying the final recipe, supply `rights.json` as a RightsDeclaration with
creator attribution, ingredient-compatible usage terms and evidence. Do not infer
permissions from an avatar brief or reuse the template artist as the final avatar's
sole author. Missing terms remain an actionable blocker; draft generation can continue.
This example assumes that declaration and a signing credential are already configured.

```bash
python3 - <<'PYCODE'
import json
from pathlib import Path
r = json.loads(Path('base.recipe.json').read_text())
r['name'] = 'Bob-haired anime avatar'
r['seed'] = 42
r['rights'] = json.loads(Path('rights.json').read_text())
r['body'].update({
    'body.heightM': 1.65, 'body.headCount': 6.3,
    'body.proportion.shoulderWidth': -0.1,
    'body.proportion.legLength': 0.1
})
r['face'].update({
    'face.jaw.width': -0.2, 'face.chin.pointedness': 0.15,
    'face.eye.left.height': 0.15, 'face.eye.right.height': 0.15,
    'face.nose.projection': -0.15
})
h = r['hair'][0]
h['controls'].update({'lengthM': 0.18, 'tipBendDeg': 12, 'bangClearanceM': 0.005})
h['texture']['baseColour'] = {'rgba': [0.24, 0.10, 0.045, 1], 'space': 'linear'}
# The installed acceptance pack declares this semantic texture-layer ID.
iris = next(x for x in r['textures'] if x['id'] == 'texture-layer:iris-colour')
iris['colour'] = {'rgba': [0.04, 0.20, 0.42, 1], 'space': 'linear'}
Path('brief.json').write_text(json.dumps(r, indent=2) + '\n')
PYCODE
vrm-author recipe apply --project avatar.vrmauthor --request brief.json --request-id recipe-001 --dry-run
vrm-author recipe apply --project avatar.vrmauthor --request brief.json --request-id recipe-001
vrm-author material shading --project avatar.vrmauthor --material material:face --shadow-end -0.8 --terminator-width 0.18
vrm-author material shading --project avatar.vrmauthor --material material:hair --shadow-end 0 --terminator-width 0.4
vrm-author build --project avatar.vrmauthor --out draft.vrm
vrm-author qa run --project avatar.vrmauthor --file draft.vrm --suite spec+style --out qa-slice
vrm-author qa run --project avatar.vrmauthor --file draft.vrm --suite authoring-v1 --out qa-initial
```

Mutations in automation should also supply the revision returned by the preceding
mutation; RPC requires it. When approving a dry-run plan, pass its `expectedPlanHash`
and base `expectedRevision` on apply. Dry-run does not consume `requestId`.

## Inspect and make a bounded correction

The agent opens the report's numeric findings and actual image/clip artifacts. Assume
its head-down scenario shows bangs crossing the eyelid. Use the report's actual hair
object ID and the discovered calibrated control range to prepare `bang-fix.json`:

```json
{
  "object": "hair:bob",
  "values": {"bangClearanceM": 0.008}
}
```

The ID is an example, to be replaced by the installed object's ID. This changes a
calibrated preset control; arbitrary curve editing or SDF avoidance is unnecessary.

```bash
vrm-author control set --project avatar.vrmauthor --request bang-fix.json --dry-run
vrm-author control set --project avatar.vrmauthor --request bang-fix.json
vrm-author build --project avatar.vrmauthor --out draft-fixed.vrm
vrm-author qa run --project avatar.vrmauthor --file draft-fixed.vrm --suite authoring-v1 --out qa-fixed
```

The build regenerates affected hair geometry, joint positions and weights. It cannot
reuse stale spring data. If the allowed controls cannot satisfy the brief and checks
within the agent's iteration budget, return an incomplete draft and the blockers.
Do not widen the profile or invoke unimplemented reserved operations.

## Verify the final bytes, record inspection and sign

```bash
vrm-author export vrm --project avatar.vrmauthor --out avatar.vrm
vrm-author export verify --project avatar.vrmauthor --file avatar.vrm --out qa-export
```

`qa-export/report.json` supplies the final build hash, revision, required artifact
hashes, scenario IDs and rubric hashes. For **each required artifact**, the agent
actually examines it and prepares an Inspection payload with those identifiers,
its actor/model version, timestamp, concrete findings and verdict. An automated
scorer can supply a logged pass with its hashed inputs, response and thresholds.
Writing a blanket “inspected” marker without per-artifact records cannot pass. Final
qualification also requires an admitted judge outside the implementer model family,
calibration evidence and the isolated release evaluation defined in verification.md;
the authoring agent cannot self-certify its own handler implementation.

```bash
vrm-author inspection record --project avatar.vrmauthor --request inspection-front.json
```

Repeat for every required artifact, then validate the complete set. Evidence records
are append-only report artifacts; they do not mutate the authoring graph revision.
The delivery request below includes a Blob reference to the configured trust policy;
`local-author` is a preconfigured signer credential reference, not key material.

```bash
vrm-author inspection verify --project avatar.vrmauthor --report qa-export/report.json
vrm-author deliver --project avatar.vrmauthor --file avatar.vrm --report qa-export/report.json --signer local-author --request delivery-policy.json --out delivery
```

`delivery-policy.json` contains `{ "trustPolicy": { "path": "...", "sha256": "..." } }`
with real values from configuration; it must not duplicate other supplied flags.
A missing signer, unresolved rights, stale inspection or required failed check blocks
completed delivery. Signing does not alter `avatar.vrm`; its full-byte hash is bound
by the adjacent C2PA manifest. Retry with the same persisted request ID returns the
original completed bundle.

Acceptance: independent consumers load the exact VRM; required expressions visibly
work; gaze uses the declared eye bones; prescribed pose/hair motion checks pass with
runtime augmentation disabled; inspection records cover final evidence; Linux CPU
builds reproduce the unsigned artifacts; and delivery contains source, locks, VRM,
C2PA/ingredient manifests, trust results, metadata attribution and complete QA evidence.
