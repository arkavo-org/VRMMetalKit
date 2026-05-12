# Migrating from VRM 0.x

VRMMetalKit loads VRM 0.x files transparently; this article explains the automatic conversions and the known divergences from a pristine VRM 1.0 file.

## Overview

VRM 0.x and VRM 1.0 are different on-disk formats. They use different extension names, different material parameter conventions, and different conformance expectations. VRMMetalKit handles both — your loading code is identical regardless of the source version, and the in-memory model exposes the VRM 1.0 shape to consumers.

This article documents what happens automatically when you load a 0.x file, so you can predict any visual differences from the original authoring tool and decide whether to re-export your source asset as VRM 1.0.

## Automatic detection

``VRMExtensionParser`` decides per file. The decision is based on the `specVersion` vs `version` field precedence: if `specVersion` is present, that wins; otherwise `version` is parsed through ``VRMSpecVersion``. Unrecognised version strings fall back to VRM 0.0. There is no flag and no opt-in — the same load call handles both versions.

## Material conversion

VRM 0.x MToon parameters are converted into the VRM 1.0 parameter space, matching the conversion used by three-vrm. Most consumers see no visual difference between a VRM 0.x file rendered by VRMMetalKit and the same file in a reference 0.x viewer.

A handful of conversions have observable side effects in edge cases. See "Known divergences" below, and the materials Topics group for the underlying surface — ``VRMMToonMaterial`` always exposes the post-conversion VRM 1.0 parameters.

## Known divergences

- **MASK is demoted to OPAQUE for body/skin materials.** When a material's name matches "body" or "skin", its alpha mode is forced to OPAQUE. VRM 0.x skin textures frequently include alpha=0 padding regions; with MASK mode active those regions would punch holes through the avatar's skin. OPAQUE is the safer default.
- **Shade-texture index deduplication.** VRM 0.x assets often set `_ShadeTexture == _MainTex` — the shade texture entry points at the same slot as the main color texture. The loader skips this duplicate bind to avoid blue padding artifacts that would otherwise appear on faces and limbs.
- **`shadeColorFactor` white default.** VRM 0.x defaults `shadeColorFactor` to `[0, 0, 0]` (black) when the field is omitted; VRM 1.0 specifies `[1, 1, 1]` (white). The loader explicitly sets the factor to white when the source field is missing so 0.x models match VRM 1.0 spec semantics.

## What VRMMetalKit cannot load

- Pre-0.0 prototypes that predate the VRM 0.0 schema.
- Non-conformant files that fail ``VRMExtensionParser`` validation.
- Files where the glTF base layer is malformed.

These produce a ``VRMError`` at load time. See <doc:LoadingVRMModels> for error handling guidance.

## Upgrading source files

Where possible, re-export your model from UniVRM or the Blender VRM Add-on as VRM 1.0. This avoids the automatic conversions entirely and gives you full authorial control over alpha modes, shade textures, and outline parameters. The conversions documented above are conservative defaults aimed at preserving the look of the original; an explicit 1.0 export almost always produces a closer match to the artist's intent.

## Topics

### Detection

- ``VRMExtensionParser``
- ``VRMSpecVersion``

### Loading

- ``VRMLoadingOptions``
- <doc:LoadingVRMModels>

### Materials

- ``VRMMToonMaterial``
- ``VRM0MaterialProperty``
