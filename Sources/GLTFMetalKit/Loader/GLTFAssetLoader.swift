//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation
@preconcurrency import Metal
import simd
@_exported import GLTFCore

/// A loaded glTF 2.0 asset, ready for ``GLTFRenderer/encodeOpaqueDrawCalls(_:scene:pipelineState:depthState:encoder:)``.
///
/// Phase 3a step 4b ships static-mesh + scene-graph + PBR. Skinning, morph
/// targets, and animation playback come in Phase 3b. KHR_lights_punctual
/// parsing is step 4c; the `lights` array is wired here but always empty
/// for now.
public struct GLTFAsset {
    /// Flattened draw list at the rest pose — one entry per primitive of
    /// every mesh visible in the default scene, with world transform
    /// pre-multiplied. To animate, call ``drawCalls(animationIndex:time:)``
    /// which re-evaluates with sampled node transforms.
    public let drawCalls: [GLTFDrawCall]

    /// All `MTLTexture` instances referenced by materials. Held to keep
    /// them alive until the asset goes out of scope.
    public let textures: [MTLTexture]

    /// Axis-aligned bounding box in world space, computed from per-primitive
    /// position bounds. Useful for auto-framing a camera.
    public let worldBounds: (min: SIMD3<Float>, max: SIMD3<Float>)

    /// `KHR_lights_punctual` lights at the rest pose. Pass to
    /// ``GLTFSceneState/lights`` to drive the shader's punctual-light
    /// array. (Lights on animated nodes will need refresh — out of scope
    /// for this phase.)
    public let lights: [GLTFPunctualLightUniform]

    /// Parsed animation clips. Empty when the document has no animations.
    /// Pass the index to ``drawCalls(animationIndex:time:)``.
    public let animations: [GLTFAnimationClip]

    // MARK: - Internal state for re-evaluation
    //
    // GLTFAsset stays a value type, but we retain the parsed document and
    // the per-primitive/material lookups so animation playback can rebuild
    // draw calls at arbitrary times without re-decoding buffers.

    internal let _document: GLTFDocument
    internal let _runtimePrimitives: [[GLTFAssetLoader.PrimitiveBuildResult?]]
    internal let _runtimeMaterials: [GLTFRenderableMaterial]
    internal let _defaultMaterial: GLTFRenderableMaterial
    internal let _skinDefinitions: [GLTFAssetLoader.SkinDefinition]
    /// Metal device retained so animated rebuilds can allocate fresh
    /// vertex buffers when morph weights change.
    internal let _device: MTLDevice
    /// Default per-mesh morph weights authored on the glTF mesh
    /// (`mesh.weights`), parallel to `_document.meshes`. Used as the
    /// starting point for any per-frame `.weights` channel samples.
    internal let _defaultMeshWeights: [[Float]]
    /// Triple-buffered MTLBuffer ring for morphed-primitive vertex output.
    /// Class instance — shared by reference across `GLTFAsset` value copies
    /// so animation playback keeps a stable ring even after passing the
    /// asset through function boundaries. See issue #247.
    internal let _morphPool: GLTFMorphBufferPool

    /// Re-evaluates the scene at a given animation time and returns a
    /// fresh draw list. The asset itself is unchanged — pass the result
    /// to the renderer's encode method.
    ///
    /// ## Performance
    ///
    /// Morphed primitives route through a triple-buffered ``GLTFMorphBufferPool``
    /// keyed by `(meshIndex, primitiveIndex)` — no per-frame `MTLBuffer`
    /// allocation. When the effective morph weights are unchanged from the
    /// last call, the pool returns the previously-blended slot without
    /// re-running the CPU blend. The remaining cost is the per-call CPU blend
    /// itself; a GPU compute kernel (issue #244) is the next axis of work.
    ///
    /// Non-morphed primitives don't blend or allocate — the same cached
    /// `MTLBuffer` is reused across frames; only the model matrix and skin
    /// palette change.
    ///
    /// - Parameters:
    ///   - animationIndex: Index into ``animations``. Out-of-range returns ``drawCalls`` unchanged.
    ///   - time: Time in seconds. Clamped to `[0, clip.duration]`; callers wanting loop semantics should `fmod` first.
    public func drawCalls(animationIndex: Int, time: Float) -> [GLTFDrawCall] {
        guard animationIndex >= 0, animationIndex < animations.count else {
            return drawCalls
        }
        let clip = animations[animationIndex]

        // 1. Copy rest-pose TRS for every node.
        let nodes = _document.nodes ?? []
        var translations = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: nodes.count)
        var rotations = [simd_quatf](repeating: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), count: nodes.count)
        var scales = [SIMD3<Float>](repeating: SIMD3<Float>(1, 1, 1), count: nodes.count)
        for (i, node) in nodes.enumerated() {
            if let t = node.translation, t.count >= 3 {
                translations[i] = SIMD3<Float>(t[0], t[1], t[2])
            }
            if let r = node.rotation, r.count >= 4 {
                rotations[i] = simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3])
            }
            if let s = node.scale, s.count >= 3 {
                scales[i] = SIMD3<Float>(s[0], s[1], s[2])
            }
        }

        // Per-mesh weights — start from the default per-mesh `weights`,
        // overwrite from any `.weights` animation channel hitting a node
        // whose mesh ends up here.
        var meshWeights: [Int: [Float]] = [:]

        // 2. Sample each channel at `time` and overwrite the relevant TRS
        //    or per-node morph weights. Each property uses the typed
        //    sampler entry-point so rotation gets true `simd_slerp` and
        //    translation/scale stay on the lerp path.
        for channel in clip.channels {
            let n = channel.targetNode
            guard n >= 0, n < nodes.count else { continue }
            switch channel.property {
            case .translation:
                translations[n] = channel.sampler.sampleAsVector3(at: time)
            case .rotation:
                rotations[n] = channel.sampler.sampleAsQuaternion(at: time)
            case .scale:
                scales[n] = channel.sampler.sampleAsVector3(at: time)
            case .weights:
                // glTF spec: `weights` animates the mesh attached to this node.
                // The sampler emits one float per morph target per keyframe.
                if let meshIdx = nodes[n].mesh {
                    meshWeights[meshIdx] = channel.sampler.sample(at: time)
                }
            }
        }

        // 3. Recompute world matrices from the sampled TRS.
        var nodeWorldMatrices = [simd_float4x4](repeating: matrix_identity_float4x4, count: nodes.count)
        let sceneIndex = _document.scene ?? 0
        let scenes = _document.scenes ?? []
        guard sceneIndex < scenes.count else { return drawCalls }

        func walk(_ nodeIndex: Int, parent: simd_float4x4) {
            guard nodeIndex < nodes.count else { return }
            let t = simd_float4x4(translation: translations[nodeIndex])
            let r = simd_float4x4(rotations[nodeIndex])
            let s = simd_float4x4(scale: scales[nodeIndex])
            let local = t * r * s
            let world = parent * local
            nodeWorldMatrices[nodeIndex] = world
            for child in nodes[nodeIndex].children ?? [] {
                walk(child, parent: world)
            }
        }
        for root in scenes[sceneIndex].nodes ?? [] {
            walk(root, parent: matrix_identity_float4x4)
        }

        // 4. Rebuild draw calls. Reuses the same runtime meshes/materials —
        //    only the model matrices + skin palettes change.
        var rebuilt: [GLTFDrawCall] = []
        for (nodeIndex, node) in nodes.enumerated() {
            guard let meshIndex = node.mesh, meshIndex < _runtimePrimitives.count else { continue }
            let worldMatrix = nodeWorldMatrices[nodeIndex]

            let skinPalette: [simd_float4x4]? = {
                guard let skinIndex = node.skin, skinIndex < _skinDefinitions.count else { return nil }
                let skin = _skinDefinitions[skinIndex]
                return zip(skin.jointNodeIndices, skin.inverseBindMatrices).map { jointNode, ibm in
                    let jointWorld = jointNode < nodeWorldMatrices.count ? nodeWorldMatrices[jointNode] : matrix_identity_float4x4
                    return jointWorld * ibm
                }
            }()

            // Effective weights for this mesh, defaulting to whatever was
            // authored on the glTF mesh itself.
            let effectiveWeights = meshWeights[meshIndex]
                ?? (meshIndex < _defaultMeshWeights.count ? _defaultMeshWeights[meshIndex] : [])

            for (primitiveIndex, entry) in _runtimePrimitives[meshIndex].enumerated() {
                guard let entry = entry else { continue }
                let mesh = entry.mesh
                let materialIndex = entry.materialIndex
                let material: GLTFRenderableMaterial = {
                    if let idx = materialIndex, idx < _runtimeMaterials.count {
                        return _runtimeMaterials[idx]
                    }
                    return _defaultMaterial
                }()
                let model = (mesh.isSkinned && skinPalette != nil) ? matrix_identity_float4x4 : worldMatrix

                // Morph pre-pass — if this primitive has morph data and any
                // weight is non-zero, route the blend through `_morphPool`.
                // The pool keeps a 3-deep ring per primitive so per-frame
                // `MTLBuffer` allocation is eliminated (issue #247) and
                // unchanged weights reuse the cached slot without re-blend.
                //
                // For skinned + morphed primitives, the pool emits
                // GLTFSkinnedRenderableVertex stride so the skinned vertex
                // shader still gets per-vertex JOINTS_0/WEIGHTS_0 — the skin
                // attrs aren't animated by morphs; they're pulled from the
                // load-time arrays unchanged.
                let drawMesh: GLTFRenderableMesh
                if let morph = entry.morphData,
                   !effectiveWeights.isEmpty,
                   effectiveWeights.contains(where: { $0 != 0 }) {
                    let primitiveID = (meshIndex << 16) | primitiveIndex
                    let skinned = mesh.isSkinned && entry.skinJoints != nil && entry.skinWeights != nil
                    if let newBuffer = _morphPool.buffer(
                        primitiveID: primitiveID,
                        morph: morph,
                        weights: effectiveWeights,
                        joints: entry.skinJoints,
                        skinWeights: entry.skinWeights,
                        skinned: skinned
                    ) {
                        drawMesh = GLTFRenderableMesh(
                            vertexBuffer: newBuffer,
                            vertexCount: morph.basePositions.count,
                            indexBuffer: mesh.indexBuffer,
                            indexCount: mesh.indexCount,
                            indexType: mesh.indexType,
                            primitiveType: mesh.primitiveType,
                            isSkinned: skinned
                        )
                    } else {
                        drawMesh = mesh
                    }
                } else {
                    drawMesh = mesh
                }

                rebuilt.append(GLTFDrawCall(mesh: drawMesh, material: material, modelMatrix: model, skinPalette: skinPalette))
            }
        }
        return rebuilt
    }
}

/// Loads a glTF 2.0 asset from a `.glb` or `.gltf` file into a
/// ``GLTFAsset`` consumable by ``GLTFRenderer``.
///
/// Owns nothing past the call — pure transform from URL to value. The
/// asset retains GPU buffers + textures, so the loader itself can be
/// discarded after `load(from:device:)` returns.
public final class GLTFAssetLoader {

    public init() {}

    /// Loads a glTF asset from disk.
    ///
    /// Currently supports the binary container (`.glb`). JSON-based `.gltf`
    /// with external buffers/images would need separate handling not yet
    /// wired up.
    ///
    /// - Parameters:
    ///   - url: Source `.glb` file.
    ///   - device: Metal device for buffer + texture allocation.
    /// - Throws: ``GLTFError`` for parse / buffer / image failures.
    public func load(from url: URL, device: MTLDevice) async throws -> GLTFAsset {
        let data = try Data(contentsOf: url)
        let parser = GLTFParser()
        let parsed = try parser.parse(data: data, filePath: url.path)
        return try await build(
            document: parsed.document,
            binaryData: parsed.binaryData,
            baseURL: url.deletingLastPathComponent(),
            device: device
        )
    }

    /// Build path used by ``load(from:device:)`` and the (test-only) in-memory
    /// path that constructs a `GLTFDocument` directly.
    public func build(
        document: GLTFDocument,
        binaryData: Data?,
        baseURL: URL?,
        device: MTLDevice
    ) async throws -> GLTFAsset {
        let bufferLoader = BufferLoader(
            document: document,
            binaryData: binaryData,
            baseURL: baseURL
        )

        // --- Texture color-space classification --------------------------------
        //
        // glTF spec: baseColor + emissive are sRGB, normal + MR + AO are linear.
        // Walk the materials once to classify each referenced texture index.
        var linearTextureIndices: Set<Int> = []
        var allTextureIndices: Set<Int> = []
        for material in document.materials ?? [] {
            if let index = material.pbrMetallicRoughness?.baseColorTexture?.index {
                allTextureIndices.insert(index)
            }
            if let index = material.pbrMetallicRoughness?.metallicRoughnessTexture?.index {
                allTextureIndices.insert(index); linearTextureIndices.insert(index)
            }
            if let index = material.normalTexture?.index {
                allTextureIndices.insert(index); linearTextureIndices.insert(index)
            }
            if let index = material.occlusionTexture?.index {
                allTextureIndices.insert(index); linearTextureIndices.insert(index)
            }
            if let index = material.emissiveTexture?.index {
                allTextureIndices.insert(index)
            }
        }

        // --- Texture loading ---------------------------------------------------

        let textureLoader = ParallelTextureLoader(
            device: device,
            bufferLoader: bufferLoader,
            document: document,
            baseURL: baseURL
        )
        let textureMap = await textureLoader.loadTexturesParallel(
            indices: Array(allTextureIndices).sorted(),
            linearTextureIndices: linearTextureIndices
        )

        // --- Material decoding -------------------------------------------------

        let runtimeMaterials = (document.materials ?? []).map { gltfMaterial in
            Self.makeMaterial(from: gltfMaterial, textures: textureMap)
        }
        let defaultMaterial = GLTFRenderableMaterial(uniforms: GLTFMaterialUniforms())

        // --- Mesh decoding -----------------------------------------------------
        //
        // Each glTF mesh produces an array of (renderableMesh, materialIndex)
        // tuples, one per primitive. Skipped primitives (non-triangle mode,
        // missing POSITION) emit `nil`.
        let runtimePrimitives: [[GLTFAssetLoader.PrimitiveBuildResult?]] = (document.meshes ?? []).map { gltfMesh in
            gltfMesh.primitives.map { gltfPrimitive in
                Self.makePrimitive(from: gltfPrimitive, bufferLoader: bufferLoader, document: document, device: device)
            }
        }

        // --- Scene traversal ---------------------------------------------------
        //
        // glTF's `scene` is the default scene index; walk every root, accumulate
        // local→world transforms via TRS multiplication, and flatten into draw
        // calls. World bounds are unioned across primitives.

        // KHR_lights_punctual — root document extension carries the light
        // definitions; nodes attach lights via `extensions.KHR_lights_punctual.light`.
        let lightDefinitions = Self.parseLightDefinitions(from: document)

        // Pre-decode skin definitions — joint node indices + IBMs. Used at
        // traversal time to build per-frame skin palettes.
        let skinDefinitions = try Self.parseSkinDefinitions(from: document, bufferLoader: bufferLoader)

        // Compute the world matrix of every node once (rest pose), then
        // traverse to emit draw calls + light placement.
        let nodeCount = document.nodes?.count ?? 0
        var nodeWorldMatrices = [simd_float4x4](repeating: matrix_identity_float4x4, count: nodeCount)
        GLTFSceneGraph.computeWorldMatrices(document: document, into: &nodeWorldMatrices)

        var drawCalls: [GLTFDrawCall] = []
        var lights: [GLTFPunctualLightUniform] = []
        var worldMin = SIMD3<Float>(repeating: Float.infinity)
        var worldMax = SIMD3<Float>(repeating: -Float.infinity)
        var foundBounds = false

        let sceneIndex = document.scene ?? 0
        let scenes = document.scenes ?? []
        if sceneIndex < scenes.count {
            let scene = scenes[sceneIndex]
            for rootNodeIndex in scene.nodes ?? [] {
                Self.traverse(
                    nodeIndex: rootNodeIndex,
                    document: document,
                    runtimePrimitives: runtimePrimitives,
                    runtimeMaterials: runtimeMaterials,
                    defaultMaterial: defaultMaterial,
                    lightDefinitions: lightDefinitions,
                    skinDefinitions: skinDefinitions,
                    nodeWorldMatrices: nodeWorldMatrices,
                    drawCalls: &drawCalls,
                    lights: &lights,
                    worldMin: &worldMin,
                    worldMax: &worldMax,
                    foundBounds: &foundBounds
                )
            }
        }

        if !foundBounds {
            worldMin = SIMD3<Float>(-1, -1, -1)
            worldMax = SIMD3<Float>( 1,  1,  1)
        }

        // Materialize the texture-retention list (deterministic order = sorted by index).
        let retainedTextures = textureMap.keys.sorted().compactMap { textureMap[$0] }

        // Parse animation clips, if any.
        let animations = try Self.parseAnimations(from: document, bufferLoader: bufferLoader)

        // Default per-mesh morph weights from `mesh.weights` — used when no
        // animation channel overrides them. Each entry is parallel to the
        // primitive's morph target count (per glTF spec, all primitives in
        // one mesh share the same target count).
        let defaultMeshWeights: [[Float]] = (document.meshes ?? []).map { mesh in
            mesh.weights ?? []
        }

        return GLTFAsset(
            drawCalls: drawCalls,
            textures: retainedTextures,
            worldBounds: (min: worldMin, max: worldMax),
            lights: lights,
            animations: animations,
            _document: document,
            _runtimePrimitives: runtimePrimitives,
            _runtimeMaterials: runtimeMaterials,
            _defaultMaterial: defaultMaterial,
            _skinDefinitions: skinDefinitions,
            _device: device,
            _defaultMeshWeights: defaultMeshWeights,
            _morphPool: GLTFMorphBufferPool(device: device)
        )
    }

    // MARK: - Animation parsing

    private static func parseAnimations(
        from document: GLTFDocument,
        bufferLoader: BufferLoader
    ) throws -> [GLTFAnimationClip] {
        guard let docAnimations = document.animations else { return [] }

        var clips: [GLTFAnimationClip] = []
        clips.reserveCapacity(docAnimations.count)
        for docAnim in docAnimations {
            // Parse each sampler.
            var runtimeSamplers: [GLTFRuntimeSampler] = []
            runtimeSamplers.reserveCapacity(docAnim.samplers.count)
            for docSampler in docAnim.samplers {
                let interpolation = GLTFAnimationInterpolation(rawString: docSampler.interpolation)
                guard let times = try? bufferLoader.loadAccessorAsFloat(docSampler.input) else {
                    vrmLog("[GLTFAssetLoader] Failed to load animation sampler input accessor \(docSampler.input)")
                    continue
                }
                guard let values = try? bufferLoader.loadAccessorAsFloat(docSampler.output) else {
                    vrmLog("[GLTFAssetLoader] Failed to load animation sampler output accessor \(docSampler.output)")
                    continue
                }
                // Components per keyframe = values.count / times.count (for non-cubic-spline).
                // For cubic-spline, values.count = 3 * times.count * components.
                let totalKeyframes = max(times.count, 1)
                var componentsPerKeyframe: Int
                if interpolation == .cubicSpline {
                    componentsPerKeyframe = values.count / (3 * totalKeyframes)
                } else {
                    componentsPerKeyframe = values.count / totalKeyframes
                }
                if componentsPerKeyframe <= 0 { componentsPerKeyframe = 1 }
                runtimeSamplers.append(GLTFRuntimeSampler(
                    times: times,
                    values: values,
                    interpolation: interpolation,
                    componentsPerKeyframe: componentsPerKeyframe
                ))
            }

            // Parse each channel — bind sampler index → runtime sampler.
            var runtimeChannels: [GLTFRuntimeChannel] = []
            var duration: Float = 0
            for docChannel in docAnim.channels {
                guard docChannel.sampler < runtimeSamplers.count else { continue }
                let sampler = runtimeSamplers[docChannel.sampler]
                if let last = sampler.times.last { duration = max(duration, last) }

                guard let targetNode = docChannel.target.node else { continue }
                let property: GLTFAnimationProperty
                switch docChannel.target.path {
                case "translation": property = .translation
                case "rotation":    property = .rotation
                case "scale":       property = .scale
                case "weights":     property = .weights
                default: continue
                }
                runtimeChannels.append(GLTFRuntimeChannel(
                    targetNode: targetNode,
                    property: property,
                    sampler: sampler
                ))
            }

            clips.append(GLTFAnimationClip(
                name: docAnim.name,
                channels: runtimeChannels,
                duration: duration
            ))
        }
        return clips
    }

    // MARK: - KHR_lights_punctual

    /// Light definition decoded from `document.extensions.KHR_lights_punctual.lights`.
    /// Type is canonicalised; transforms come from the referencing node.
    private struct LightDefinition {
        let type: GLTFLightType
        let color: SIMD3<Float>
        let intensity: Float
        let range: Float
        let innerConeAngle: Float
        let outerConeAngle: Float
    }

    /// Parses the root-level `KHR_lights_punctual` extension into typed
    /// definitions, indexed parallel to the JSON `lights` array.
    private static func parseLightDefinitions(from document: GLTFDocument) -> [LightDefinition] {
        guard let extensions = document.extensions,
              let khr = extensions["KHR_lights_punctual"] as? [String: Any],
              let lightsArray = khr["lights"] as? [Any] else {
            return []
        }

        var result: [LightDefinition] = []
        result.reserveCapacity(lightsArray.count)
        for raw in lightsArray {
            guard let dict = raw as? [String: Any] else { continue }

            let typeString = (dict["type"] as? String) ?? "directional"
            let type: GLTFLightType
            switch typeString {
            case "point":       type = .point
            case "spot":        type = .spot
            default:            type = .directional
            }

            let color: SIMD3<Float>
            if let rgb = dict["color"] as? [Any], rgb.count >= 3 {
                color = SIMD3<Float>(asFloat(rgb[0]), asFloat(rgb[1]), asFloat(rgb[2]))
            } else {
                color = SIMD3<Float>(1, 1, 1)
            }
            let intensity = asFloat(dict["intensity"] ?? 1.0, defaultValue: 1)
            let range = asFloat(dict["range"] ?? 0.0, defaultValue: 0)

            // Spot-specific cone angles live under `spot: { innerConeAngle, outerConeAngle }`.
            var innerCone: Float = 0
            var outerCone: Float = .pi / 4
            if type == .spot, let spotDict = dict["spot"] as? [String: Any] {
                innerCone = asFloat(spotDict["innerConeAngle"] ?? 0.0, defaultValue: 0)
                outerCone = asFloat(spotDict["outerConeAngle"] ?? Double.pi / 4, defaultValue: .pi / 4)
            }

            result.append(LightDefinition(
                type: type,
                color: color,
                intensity: intensity,
                range: range,
                innerConeAngle: innerCone,
                outerConeAngle: outerCone
            ))
        }
        return result
    }

    /// Builds a per-frame ``GLTFPunctualLightUniform`` for a light attached to a
    /// node, baking the world transform into position/direction.
    private static func makeLightUniform(
        definition: LightDefinition,
        worldMatrix: simd_float4x4
    ) -> GLTFPunctualLightUniform {
        // glTF: a light at a node points down -Z in the node's local space.
        // World position is the node's translation column.
        let origin = worldMatrix.columns.3
        let position = SIMD3<Float>(origin.x, origin.y, origin.z)

        // Direction vectors transform by the inverse-transpose of the upper
        // 3×3 (the "normal matrix"). For rotation + diagonal-scale TRS
        // parents this gives the same direction after normalization as
        // `worldMatrix * v`; for non-orthogonal explicit-matrix parents it
        // avoids skewing the axis. Fall back to direct transform when the
        // 3×3 is singular (degenerate scale).
        let upper3 = simd_float3x3(
            SIMD3<Float>(worldMatrix.columns.0.x, worldMatrix.columns.0.y, worldMatrix.columns.0.z),
            SIMD3<Float>(worldMatrix.columns.1.x, worldMatrix.columns.1.y, worldMatrix.columns.1.z),
            SIMD3<Float>(worldMatrix.columns.2.x, worldMatrix.columns.2.y, worldMatrix.columns.2.z)
        )
        let localForward = SIMD3<Float>(0, 0, -1)
        let det = upper3.determinant
        let rawDirection: SIMD3<Float>
        if abs(det) > 1e-6 {
            rawDirection = upper3.inverse.transpose * localForward
        } else {
            rawDirection = upper3 * localForward
        }
        let direction = normalize(rawDirection)

        return GLTFPunctualLightUniform(
            type: definition.type,
            color: definition.color,
            intensity: definition.intensity,
            position: position,
            direction: direction,
            range: definition.range,
            innerConeAngle: definition.innerConeAngle,
            outerConeAngle: definition.outerConeAngle
        )
    }

    private static func asFloat(_ value: Any, defaultValue: Float = 0) -> Float {
        if let d = value as? Double { return Float(d) }
        if let i = value as? Int { return Float(i) }
        if let f = value as? Float { return f }
        return defaultValue
    }

    // MARK: - Material decoding

    private static func makeMaterial(
        from gltf: GLTFMaterial,
        textures: [Int: MTLTexture]
    ) -> GLTFRenderableMaterial {
        let pbr = gltf.pbrMetallicRoughness

        var flags: GLTFMaterialFlags = []

        // KHR_materials_unlit — bypass shading entirely.
        if let extensions = gltf.extensions, extensions["KHR_materials_unlit"] != nil {
            flags.insert(.unlit)
        }

        // Alpha mode.
        switch gltf.alphaMode {
        case "MASK":  flags.insert(.alphaMask)
        case "BLEND": flags.insert(.alphaBlend)
        default: break  // OPAQUE
        }

        let baseColorFactor: SIMD4<Float>
        if let f = pbr?.baseColorFactor, f.count >= 4 {
            baseColorFactor = SIMD4<Float>(f[0], f[1], f[2], f[3])
        } else {
            baseColorFactor = SIMD4<Float>(1, 1, 1, 1)
        }

        let emissiveFactor: SIMD3<Float>
        if let f = gltf.emissiveFactor, f.count >= 3 {
            emissiveFactor = SIMD3<Float>(f[0], f[1], f[2])
        } else {
            emissiveFactor = SIMD3<Float>(0, 0, 0)
        }

        var baseColorTexture: MTLTexture?
        if let index = pbr?.baseColorTexture?.index, let texture = textures[index] {
            baseColorTexture = texture
            flags.insert(.hasBaseColorTexture)
        }
        var mrTexture: MTLTexture?
        if let index = pbr?.metallicRoughnessTexture?.index, let texture = textures[index] {
            mrTexture = texture
            flags.insert(.hasMetallicRoughnessTexture)
        }
        var normalTexture: MTLTexture?
        if let index = gltf.normalTexture?.index, let texture = textures[index] {
            normalTexture = texture
            flags.insert(.hasNormalTexture)
        }
        var occlusionTexture: MTLTexture?
        if let index = gltf.occlusionTexture?.index, let texture = textures[index] {
            occlusionTexture = texture
            flags.insert(.hasOcclusionTexture)
        }
        var emissiveTexture: MTLTexture?
        if let index = gltf.emissiveTexture?.index, let texture = textures[index] {
            emissiveTexture = texture
            flags.insert(.hasEmissiveTexture)
        }

        let uniforms = GLTFMaterialUniforms(
            baseColorFactor: baseColorFactor,
            emissiveFactor: emissiveFactor,
            metallicFactor: pbr?.metallicFactor ?? 1.0,
            roughnessFactor: pbr?.roughnessFactor ?? 1.0,
            normalScale: gltf.normalTexture?.scale ?? 1.0,
            occlusionStrength: gltf.occlusionTexture?.strength ?? 1.0,
            alphaCutoff: gltf.alphaCutoff ?? 0.5,
            flags: flags
        )

        return GLTFRenderableMaterial(
            uniforms: uniforms,
            baseColorTexture: baseColorTexture,
            metallicRoughnessTexture: mrTexture,
            normalTexture: normalTexture,
            occlusionTexture: occlusionTexture,
            emissiveTexture: emissiveTexture
        )
    }

    // MARK: - Primitive decoding

    /// Per-vertex skinning data parsed from `JOINTS_0` + `WEIGHTS_0`. Only
    /// returned by `makePrimitive` when both attributes are present.
    private struct PrimitiveSkinningData {
        let joints: [SIMD4<UInt16>]
        let weights: [SIMD4<Float>]
    }

    /// Per-primitive bookkeeping that survives load time so animation
    /// rebuild has everything it needs to blend morph weights on CPU.
    internal struct PrimitiveBuildResult {
        let mesh: GLTFRenderableMesh
        let materialIndex: Int?
        let morphData: GLTFPrimitiveMorphData?  // nil when the primitive has no morph targets
        /// Per-vertex JOINTS_0, parallel to the vertex order. Captured when
        /// the primitive is skinned + has morph targets so the rebuild path
        /// can re-emit a skinned-morphed vertex buffer (the skin attrs are
        /// not themselves animated by morphs).
        let skinJoints: [SIMD4<UInt16>]?
        /// Per-vertex WEIGHTS_0. Same conditions as `skinJoints`.
        let skinWeights: [SIMD4<Float>]?
        /// Object-space AABB over POSITION. Used by scene traversal to
        /// build the asset's world-space bounds (camera auto-framing reads
        /// these).
        let localMin: SIMD3<Float>
        let localMax: SIMD3<Float>
    }

    /// Returns the primitive build result or `nil` if the primitive should be skipped
    /// (non-triangle mode, missing POSITION, accessor decode failure).
    ///
    /// `document` is threaded through so we can inspect the material slot
    /// when warning about MikkTSpace fallbacks.
    private static func makePrimitive(
        from gltf: GLTFPrimitive,
        bufferLoader: BufferLoader,
        document: GLTFDocument,
        device: MTLDevice
    ) -> PrimitiveBuildResult? {
        // Only triangle primitives are supported in step 4b. The mesh modes
        // POINTS/LINES/* would need different pipeline states; deferred.
        let mode = gltf.mode ?? 4
        guard mode == 4 else { return nil }

        guard let positionAccessor = gltf.attributes["POSITION"] else { return nil }

        let positions: [Float]
        do {
            positions = try bufferLoader.loadAccessorAsFloat(positionAccessor)
        } catch {
            vrmLog("[GLTFAssetLoader] Failed to load POSITION accessor \(positionAccessor): \(error)")
            return nil
        }
        let vertexCount = positions.count / 3
        guard vertexCount > 0 else { return nil }

        // Object-space AABB sweep — used downstream for camera auto-framing.
        var localMin = SIMD3<Float>(positions[0], positions[1], positions[2])
        var localMax = localMin
        for v in 1..<vertexCount {
            let p = SIMD3<Float>(positions[v*3 + 0], positions[v*3 + 1], positions[v*3 + 2])
            localMin = simd_min(localMin, p)
            localMax = simd_max(localMax, p)
        }

        // Optional attributes — synthesise reasonable defaults when absent.
        let normals: [Float]
        if let normalAccessor = gltf.attributes["NORMAL"],
           let loaded = try? bufferLoader.loadAccessorAsFloat(normalAccessor),
           loaded.count == vertexCount * 3 {
            normals = loaded
        } else {
            normals = Array(repeating: 0, count: vertexCount * 3).enumerated().map { i, _ in
                // Default to (0, 1, 0) — better than zero, which would blow up lighting math.
                return (i % 3 == 1) ? 1.0 : 0.0
            }
        }

        let uvs: [Float]
        if let uvAccessor = gltf.attributes["TEXCOORD_0"],
           let loaded = try? bufferLoader.loadAccessorAsFloat(uvAccessor),
           loaded.count == vertexCount * 2 {
            uvs = loaded
        } else {
            uvs = Array(repeating: 0, count: vertexCount * 2)
        }

        // Tangents: when missing, default to (1, 0, 0, 1). This is good enough
        // for untextured / normal-map-less assets; a full MikkTSpace generator
        // is tracked as issue #243 for assets where the material references a
        // normal map but TANGENT is absent (glTF 2.0 §3.7.2.1.1 requires
        // generation in that case).
        let tangents: [Float]
        let tangentsSynthesised: Bool
        if let tangentAccessor = gltf.attributes["TANGENT"],
           let loaded = try? bufferLoader.loadAccessorAsFloat(tangentAccessor),
           loaded.count == vertexCount * 4 {
            tangents = loaded
            tangentsSynthesised = false
        } else {
            var generated = [Float](repeating: 0, count: vertexCount * 4)
            for i in 0..<vertexCount {
                generated[i * 4 + 0] = 1
                generated[i * 4 + 3] = 1
            }
            tangents = generated
            tangentsSynthesised = true
        }

        // Warn when the material wants a normal map but the mesh lacks
        // authored tangents — that combination needs MikkTSpace generation
        // (see issue #243) and the `(1, 0, 0, 1)` fallback will produce
        // visibly wrong shading.
        if tangentsSynthesised, let materialIndex = gltf.material,
           let materials = document.materials,
           materialIndex < materials.count,
           materials[materialIndex].normalTexture != nil {
            vrmLog("[GLTFAssetLoader] Synthesised (1,0,0,1) tangents for a primitive whose material '" +
                   (materials[materialIndex].name ?? "<unnamed>") +
                   "' uses a normal map. Shading will be incorrect on this mesh until MikkTSpace tangent generation lands (issue #243).")
        }

        // Optional skinning attributes (JOINTS_0 + WEIGHTS_0). Both must be
        // present for the mesh to ride the skinned pipeline.
        let skinningData: PrimitiveSkinningData? = {
            guard let jointsAccessor = gltf.attributes["JOINTS_0"],
                  let weightsAccessor = gltf.attributes["WEIGHTS_0"] else {
                return nil
            }
            // glTF JOINTS_0 is UInt8 or UInt16; promote to UInt16. We
            // route through UInt32 because BufferLoader exposes that as
            // the lowest-common denominator typed accessor reader.
            guard let jointsRaw = try? bufferLoader.loadAccessorAsUInt32(jointsAccessor),
                  jointsRaw.count == vertexCount * 4 else {
                return nil
            }
            guard let weightsRaw = try? bufferLoader.loadAccessorAsFloat(weightsAccessor),
                  weightsRaw.count == vertexCount * 4 else {
                return nil
            }
            var jointsOut: [SIMD4<UInt16>] = []
            var weightsOut: [SIMD4<Float>] = []
            jointsOut.reserveCapacity(vertexCount)
            weightsOut.reserveCapacity(vertexCount)
            for i in 0..<vertexCount {
                jointsOut.append(SIMD4<UInt16>(
                    UInt16(truncatingIfNeeded: jointsRaw[i*4 + 0]),
                    UInt16(truncatingIfNeeded: jointsRaw[i*4 + 1]),
                    UInt16(truncatingIfNeeded: jointsRaw[i*4 + 2]),
                    UInt16(truncatingIfNeeded: jointsRaw[i*4 + 3])
                ))
                weightsOut.append(SIMD4<Float>(
                    weightsRaw[i*4 + 0], weightsRaw[i*4 + 1],
                    weightsRaw[i*4 + 2], weightsRaw[i*4 + 3]
                ))
            }
            return PrimitiveSkinningData(joints: jointsOut, weights: weightsOut)
        }()

        // Build interleaved vertex array (skinned or non-skinned layout).
        let vertexBuffer: MTLBuffer
        let isSkinned: Bool

        if let skin = skinningData {
            var skinnedVertices = [GLTFSkinnedRenderableVertex]()
            skinnedVertices.reserveCapacity(vertexCount)
            for i in 0..<vertexCount {
                let p = SIMD3<Float>(positions[i*3+0], positions[i*3+1], positions[i*3+2])
                let n = SIMD3<Float>(normals[i*3+0], normals[i*3+1], normals[i*3+2])
                let t = SIMD4<Float>(tangents[i*4+0], tangents[i*4+1], tangents[i*4+2], tangents[i*4+3])
                let uv = SIMD2<Float>(uvs[i*2+0], uvs[i*2+1])
                skinnedVertices.append(GLTFSkinnedRenderableVertex(
                    position: p, normal: n, tangent: t, uv0: uv,
                    joints: skin.joints[i], weights: skin.weights[i]
                ))
            }
            let stride = MemoryLayout<GLTFSkinnedRenderableVertex>.stride
            guard let vbuf = skinnedVertices.withUnsafeBufferPointer({ ptr in
                device.makeBuffer(bytes: ptr.baseAddress!, length: skinnedVertices.count * stride, options: [])
            }) else { return nil }
            vertexBuffer = vbuf
            isSkinned = true
        } else {
            var vertices = [GLTFRenderableVertex]()
            vertices.reserveCapacity(vertexCount)
            for i in 0..<vertexCount {
                let p = SIMD3<Float>(positions[i*3+0], positions[i*3+1], positions[i*3+2])
                let n = SIMD3<Float>(normals[i*3+0], normals[i*3+1], normals[i*3+2])
                let t = SIMD4<Float>(tangents[i*4+0], tangents[i*4+1], tangents[i*4+2], tangents[i*4+3])
                let uv = SIMD2<Float>(uvs[i*2+0], uvs[i*2+1])
                vertices.append(GLTFRenderableVertex(position: p, normal: n, tangent: t, uv0: uv))
            }
            let stride = MemoryLayout<GLTFRenderableVertex>.stride
            guard let vbuf = vertices.withUnsafeBufferPointer({ ptr in
                device.makeBuffer(bytes: ptr.baseAddress!, length: vertices.count * stride, options: [])
            }) else { return nil }
            vertexBuffer = vbuf
            isSkinned = false
        }

        // Index buffer.
        var indexBuffer: MTLBuffer?
        var indexCount = 0
        var indexType: MTLIndexType = .uint16

        if let indicesAccessor = gltf.indices {
            // glTF allows UInt8, UInt16, UInt32. Metal needs UInt16 or UInt32.
            // Promote UInt8 → UInt16 (rare and small enough that the copy is cheap).
            do {
                let asUInt32 = try bufferLoader.loadAccessorAsUInt32(indicesAccessor)
                let maxIndex = asUInt32.max() ?? 0
                if maxIndex < 0x1_0000 {
                    let asUInt16 = asUInt32.map { UInt16($0) }
                    indexBuffer = asUInt16.withUnsafeBufferPointer { ptr in
                        device.makeBuffer(bytes: ptr.baseAddress!, length: asUInt16.count * 2, options: [])
                    }
                    indexType = .uint16
                } else {
                    indexBuffer = asUInt32.withUnsafeBufferPointer { ptr in
                        device.makeBuffer(bytes: ptr.baseAddress!, length: asUInt32.count * 4, options: [])
                    }
                    indexType = .uint32
                }
                indexCount = asUInt32.count
            } catch {
                vrmLog("[GLTFAssetLoader] Failed to load indices accessor \(indicesAccessor): \(error)")
                return nil
            }
        }

        let mesh = GLTFRenderableMesh(
            vertexBuffer: vertexBuffer,
            vertexCount: vertexCount,
            indexBuffer: indexBuffer,
            indexCount: indexCount,
            indexType: indexType,
            primitiveType: .triangle,
            isSkinned: isSkinned
        )

        // Optional morph-target data — extracted for both skinned and
        // non-skinned primitives. The asset's rebuild path uses
        // `morphedVertices(weights:)` for the unskinned layout and
        // `skinnedMorphedVertices(weights:joints:skinWeights:)` for the
        // skinned layout (it re-fetches per-vertex JOINTS_0/WEIGHTS_0
        // because the skin attrs aren't animated by morphs).
        let morphData: GLTFPrimitiveMorphData? = {
            guard let targets = gltf.targets, !targets.isEmpty else { return nil }

            // Pack base attributes into typed arrays in the same order the
            // vertex buffer was built.
            var basePositions = [SIMD3<Float>](); basePositions.reserveCapacity(vertexCount)
            var baseNormals   = [SIMD3<Float>](); baseNormals.reserveCapacity(vertexCount)
            var baseTangents  = [SIMD4<Float>](); baseTangents.reserveCapacity(vertexCount)
            var baseUVs       = [SIMD2<Float>](); baseUVs.reserveCapacity(vertexCount)
            for i in 0..<vertexCount {
                basePositions.append(SIMD3<Float>(positions[i*3+0], positions[i*3+1], positions[i*3+2]))
                baseNormals.append(SIMD3<Float>(normals[i*3+0], normals[i*3+1], normals[i*3+2]))
                baseTangents.append(SIMD4<Float>(tangents[i*4+0], tangents[i*4+1], tangents[i*4+2], tangents[i*4+3]))
                baseUVs.append(SIMD2<Float>(uvs[i*2+0], uvs[i*2+1]))
            }

            var positionDeltas: [[SIMD3<Float>]] = []
            var normalDeltas:   [[SIMD3<Float>]] = []
            var tangentDeltas:  [[SIMD3<Float>]] = []
            positionDeltas.reserveCapacity(targets.count)
            normalDeltas.reserveCapacity(targets.count)
            tangentDeltas.reserveCapacity(targets.count)

            for target in targets {
                positionDeltas.append(Self.readVec3Accessor(target.position, count: vertexCount, bufferLoader: bufferLoader))
                normalDeltas.append(Self.readVec3Accessor(target.normal,   count: vertexCount, bufferLoader: bufferLoader))
                tangentDeltas.append(Self.readVec3Accessor(target.tangent, count: vertexCount, bufferLoader: bufferLoader))
            }

            return GLTFPrimitiveMorphData(
                basePositions: basePositions,
                baseNormals: baseNormals,
                baseTangents: baseTangents,
                baseUVs: baseUVs,
                positionDeltas: positionDeltas,
                normalDeltas: normalDeltas,
                tangentDeltas: tangentDeltas
            )
        }()

        // Capture the skinning arrays alongside morph data so the rebuild
        // path can re-emit a skinned-morphed vertex buffer. The skin
        // attrs are not themselves animated by glTF morph targets — only
        // POSITION/NORMAL/TANGENT — so we just hold the constant per-
        // vertex JOINTS_0/WEIGHTS_0 from load time.
        let skinJoints: [SIMD4<UInt16>]? = (isSkinned && morphData != nil) ? skinningData?.joints : nil
        let skinWeights: [SIMD4<Float>]? = (isSkinned && morphData != nil) ? skinningData?.weights : nil

        return PrimitiveBuildResult(
            mesh: mesh,
            materialIndex: gltf.material,
            morphData: morphData,
            skinJoints: skinJoints,
            skinWeights: skinWeights,
            localMin: localMin,
            localMax: localMax
        )
    }

    /// Decodes a Vec3 accessor as `[SIMD3<Float>]`, or returns an empty
    /// array when the accessor index is `nil` or decoding fails.
    private static func readVec3Accessor(
        _ index: Int?,
        count: Int,
        bufferLoader: BufferLoader
    ) -> [SIMD3<Float>] {
        guard let index = index else { return [] }
        guard let raw = try? bufferLoader.loadAccessorAsFloat(index), raw.count == count * 3 else { return [] }
        var out = [SIMD3<Float>](); out.reserveCapacity(count)
        for v in 0..<count {
            out.append(SIMD3<Float>(raw[v*3+0], raw[v*3+1], raw[v*3+2]))
        }
        return out
    }

    // MARK: - Scene traversal

    private static func traverse(
        nodeIndex: Int,
        document: GLTFDocument,
        runtimePrimitives: [[GLTFAssetLoader.PrimitiveBuildResult?]],
        runtimeMaterials: [GLTFRenderableMaterial],
        defaultMaterial: GLTFRenderableMaterial,
        lightDefinitions: [LightDefinition],
        skinDefinitions: [SkinDefinition],
        nodeWorldMatrices: [simd_float4x4],
        drawCalls: inout [GLTFDrawCall],
        lights: inout [GLTFPunctualLightUniform],
        worldMin: inout SIMD3<Float>,
        worldMax: inout SIMD3<Float>,
        foundBounds: inout Bool
    ) {
        guard let nodes = document.nodes, nodeIndex < nodes.count else { return }
        let node = nodes[nodeIndex]
        let worldMatrix = nodeWorldMatrices[nodeIndex]

        if let meshIndex = node.mesh,
           meshIndex < runtimePrimitives.count {
            // Skin palette (skinned primitives only). Same palette for every
            // primitive in this mesh because the skin attaches to the node,
            // not the primitive.
            let skinPalette: [simd_float4x4]? = {
                guard let skinIndex = node.skin,
                      skinIndex < skinDefinitions.count else { return nil }
                let skin = skinDefinitions[skinIndex]
                return zip(skin.jointNodeIndices, skin.inverseBindMatrices).map { jointNode, ibm in
                    let jointWorld = jointNode < nodeWorldMatrices.count ? nodeWorldMatrices[jointNode] : matrix_identity_float4x4
                    return jointWorld * ibm
                }
            }()

            for entry in runtimePrimitives[meshIndex] {
                guard let entry = entry else { continue }
                let mesh = entry.mesh
                let materialIndex = entry.materialIndex
                let material: GLTFRenderableMaterial = {
                    if let idx = materialIndex, idx < runtimeMaterials.count {
                        return runtimeMaterials[idx]
                    }
                    return defaultMaterial
                }()
                // For skinned meshes, joint matrices already encode world
                // transform — use identity as the model matrix so we don't
                // double-transform. Non-skinned uses the node's world matrix.
                let model = (mesh.isSkinned && skinPalette != nil) ? matrix_identity_float4x4 : worldMatrix
                drawCalls.append(GLTFDrawCall(
                    mesh: mesh,
                    material: material,
                    modelMatrix: model,
                    skinPalette: skinPalette
                ))

                // World-space AABB. Two paths because the POSITION attribute
                // means different things for skinned vs non-skinned meshes:
                //
                // - Non-skinned: POSITION is in mesh-local space; transform
                //   the local AABB by the node's world matrix.
                // - Skinned: POSITION is in joint-local space (per glTF spec),
                //   and the joint matrices encode the world transform. The
                //   *vertex* AABB at bind pose equals the local POSITION AABB,
                //   but in a coordinate system that's only meaningful after
                //   skinning. For camera framing we want the bounds of where
                //   the figure actually appears in world space — that's the
                //   bounds of the joint world positions (the skeleton extent).
                //   Approximation: union of joint translations from the bind-
                //   pose skin palette, padded slightly to account for vertices
                //   extending beyond the skeleton (fingertips past wrists, etc.).
                if mesh.isSkinned, let nodeSkin = node.skin, nodeSkin < skinDefinitions.count {
                    let skin = skinDefinitions[nodeSkin]
                    for jointNode in skin.jointNodeIndices where jointNode < nodeWorldMatrices.count {
                        let t = nodeWorldMatrices[jointNode].columns.3
                        let p = SIMD3<Float>(t.x, t.y, t.z)
                        worldMin = simd_min(worldMin, p)
                        worldMax = simd_max(worldMax, p)
                    }
                } else {
                    let (transformedMin, transformedMax) = Self.transformAABB(
                        min: entry.localMin, max: entry.localMax, by: worldMatrix
                    )
                    worldMin = simd_min(worldMin, transformedMin)
                    worldMax = simd_max(worldMax, transformedMax)
                }
                foundBounds = true
            }
        }

        // KHR_lights_punctual — `node.extensions.KHR_lights_punctual.light` references the doc light array.
        if let nodeExtensions = node.extensions,
           let khrWrapper = nodeExtensions["KHR_lights_punctual"],
           let khrDict = khrWrapper.value as? [String: Any],
           let lightIndex = khrDict["light"] as? Int,
           lightIndex < lightDefinitions.count {
            lights.append(makeLightUniform(
                definition: lightDefinitions[lightIndex],
                worldMatrix: worldMatrix
            ))
        }

        for child in node.children ?? [] {
            traverse(
                nodeIndex: child,
                document: document,
                runtimePrimitives: runtimePrimitives,
                runtimeMaterials: runtimeMaterials,
                defaultMaterial: defaultMaterial,
                lightDefinitions: lightDefinitions,
                skinDefinitions: skinDefinitions,
                nodeWorldMatrices: nodeWorldMatrices,
                drawCalls: &drawCalls,
                lights: &lights,
                worldMin: &worldMin,
                worldMax: &worldMax,
                foundBounds: &foundBounds
            )
        }
    }

    // MARK: - Skin parsing

    /// Parsed glTF skin: joint node indices + IBMs. Bake per-frame via
    /// `nodeWorldMatrix * inverseBindMatrix`.
    internal struct SkinDefinition {
        let jointNodeIndices: [Int]
        let inverseBindMatrices: [simd_float4x4]
    }

    internal static func parseSkinDefinitions(
        from document: GLTFDocument,
        bufferLoader: BufferLoader
    ) throws -> [SkinDefinition] {
        guard let skins = document.skins else { return [] }
        return skins.map { skin in
            let joints = skin.joints
            // glTF: inverseBindMatrices accessor is optional. If absent
            // every IBM is identity (joints are already in their bind pose).
            var ibms: [simd_float4x4]
            if let ibmAccessor = skin.inverseBindMatrices,
               let mats = try? bufferLoader.loadAccessorAsMatrix4x4(ibmAccessor),
               mats.count == joints.count {
                ibms = mats
            } else {
                ibms = Array(repeating: matrix_identity_float4x4, count: joints.count)
            }
            return SkinDefinition(jointNodeIndices: joints, inverseBindMatrices: ibms)
        }
    }

    // MARK: - Bounds helper

    /// Transform an object-space AABB by a 4×4 matrix, returning the
    /// world-space AABB. Transforms all 8 corners and recomputes min/max
    /// — exact for affine matrices, conservative for projective ones.
    internal static func transformAABB(
        min lmin: SIMD3<Float>,
        max lmax: SIMD3<Float>,
        by matrix: simd_float4x4
    ) -> (SIMD3<Float>, SIMD3<Float>) {
        let corners: [SIMD3<Float>] = [
            SIMD3(lmin.x, lmin.y, lmin.z),
            SIMD3(lmax.x, lmin.y, lmin.z),
            SIMD3(lmin.x, lmax.y, lmin.z),
            SIMD3(lmax.x, lmax.y, lmin.z),
            SIMD3(lmin.x, lmin.y, lmax.z),
            SIMD3(lmax.x, lmin.y, lmax.z),
            SIMD3(lmin.x, lmax.y, lmax.z),
            SIMD3(lmax.x, lmax.y, lmax.z),
        ]
        var wmin = SIMD3<Float>(repeating: Float.infinity)
        var wmax = SIMD3<Float>(repeating: -Float.infinity)
        for c in corners {
            let p4 = matrix * SIMD4<Float>(c.x, c.y, c.z, 1)
            let p = SIMD3<Float>(p4.x, p4.y, p4.z)
            wmin = simd_min(wmin, p)
            wmax = simd_max(wmax, p)
        }
        return (wmin, wmax)
    }
}
