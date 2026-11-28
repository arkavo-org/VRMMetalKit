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
import Metal
import simd

// MARK: - Skinning Implementation

/// Builds and updates the GPU joint palettes used by skinned draws.
///
/// ## Discussion
/// `VRMSkinningSystem` allocates a ring of `MTLBuffer` palettes, one per
/// renderer in-flight slot. Each palette covers every ``VRMSkin`` in the model.
/// Each skin records its own offset (``VRMSkin/matrixOffset`` and
/// ``VRMSkin/bufferByteOffset``) so per-skin draws bind a view onto the
/// selected frame buffer rather than allocating per-skin buffers. The renderer
/// selects a slot only after acquiring it and retains it across compositor views.
/// Slots with an older pose copy the latest skin palette when its joints are idle.
///
/// ### Joint cap and padding
/// Draws bind the buffer at their own skin's slice base, so the shader's
/// last-resort joint-index clamp (`maxJointCount - 1`) resolves relative to
/// that offset, not to 0. The buffer therefore carries a tail of
/// ``VRMConstants/Animation/maxJointCount`` identity matrices *after* the
/// live matrices, keeping `anySkinOffset + maxJointCount - 1` in-bounds for
/// malformed meshes referencing joints beyond their declared palette.
/// Per-skin counts may exceed 256 (VRoid cloth).
///
/// ### Rigid fallback
/// ``identityJointMatricesBuffer`` is a separate read-only buffer of
/// identity matrices, bound at the joint-matrices slot when the skinned
/// pipeline draws a non-skinned primitive (issue #161). It is allocated
/// once and never written, so live joint updates cannot corrupt it.
///
/// ### Freshness tracking
/// To catch stale palettes, the system tracks per-skin update frame
/// numbers. Callers must call ``beginFrame()`` and then either
/// ``markAllSkinsUpdated(frameNumber:)`` or per-skin ``markSkinUpdated(skinIndex:)``
/// each frame; ``verifySkinFreshness(skinIndex:frameNumber:)`` logs a
/// warning if a draw references a palette that wasn't refreshed for the
/// current frame.
public final class VRMSkinningSystem {
    private struct SkinSlot {
        var matrixOffset: Int
        var bufferByteOffset: Int
        var jointCount: Int
        var version: UInt64
        var latestPaletteSlot: Int
        var lastJointGeneration: UInt64?
        var dirty: Bool
        var lastUpdatedFrame: Int?
        var paletteVersions: [UInt64]
    }

    private let device: MTLDevice
    /// The current frame's joint-matrices buffer. Exposed for debugging and renderer-side validation; callers should bind via ``getJointMatricesBuffer()`` and offset by ``getBufferOffset(for:)``.
    public var jointMatricesBuffer: MTLBuffer?
    // Each renderer in-flight slot owns its palette until GPU completion.
    private var paletteBuffers: [MTLBuffer] = []
    private var paletteSlot = 0
    private var skinSlots: [ObjectIdentifier: SkinSlot] = [:]
    private var orderedSkinIDs: [ObjectIdentifier] = []
    private var lastLayoutRevision: UInt64? = nil
    private var lastContentRevision: UInt64? = nil
    private var lastSyncedJointCounts: [Int] = []
    /// Dedicated read-only buffer of identity matrices. Bound at the joint
    /// matrices slot when the skinned pipeline draws a primitive whose owning
    /// node has `skin == nil` (issue #161). Distinct from `jointMatricesBuffer`
    /// so live updates cannot corrupt the identities.
    public private(set) var identityJointMatricesBuffer: MTLBuffer?
    private var totalMatrixCount = 0
    private var lastUpdatedSkinID: ObjectIdentifier? = nil
    private var debugFrameCount = 0

    // Freshness tracking
    private var currentFrameNumber: Int = 0
    private var allSkinsUpdatedFrame: Int? = nil

    /// A/B test hook: when set to a skin index, ``updateJointMatrices(for:)`` writes identity matrices for that skin instead of the computed palette.
    public var testIdentityPalette: Int? = nil {
        didSet { markAllSkinsDirty() }
    }

    /// Creates a skinning system bound to `device`. Call ``syncForSkins(_:layoutRevision:contentRevision:)`` or ``setupForSkins(_:)`` before issuing updates.
    public init(device: MTLDevice) {
        self.device = device
    }

    /// Allocates the shared joint-matrices buffer covering all skins and computes per-skin offsets.
    ///
    /// Writes each skin's ``VRMSkin/matrixOffset`` and
    /// ``VRMSkin/bufferByteOffset`` and pre-fills the entire buffer with
    /// identity matrices so any uninitialised slot returns a safe value.
    /// Also ensures ``identityJointMatricesBuffer`` covers at least the same padded size.
    public func setupForSkins(_ skins: [VRMSkin]) {
        lastLayoutRevision = nil
        lastContentRevision = nil
        rebuildLayout(for: skins)
    }

    /// Incrementally synchronizes skin slots and GPU palette rings against a dynamic skin list.
    ///
    /// Reallocates the `maxBufferedFrames` ring whenever `layoutRevision` changes or the set/size of skins
    /// changes (in-flight command buffers retain references to the previous buffers until GPU completion),
    /// grows ``identityJointMatricesBuffer`` when needed, and marks all skins dirty on `contentRevision` changes.
    public func syncForSkins(_ skins: [VRMSkin], layoutRevision: UInt64, contentRevision: UInt64) {
        let skinIDs = skins.map { ObjectIdentifier($0) }
        let jointCounts = skins.map { $0.joints.count }

        let layoutChanged = lastLayoutRevision != layoutRevision
            || skinIDs != orderedSkinIDs
            || jointCounts != lastSyncedJointCounts
            || (!skins.isEmpty && paletteBuffers.isEmpty)

        if layoutChanged {
            rebuildLayout(for: skins)
            lastLayoutRevision = layoutRevision
            lastContentRevision = contentRevision
            return
        }

        if lastContentRevision != contentRevision {
            markAllSkinsDirty()
            for id in orderedSkinIDs {
                skinSlots[id]?.lastJointGeneration = nil
            }
            lastContentRevision = contentRevision
        }
    }

    private func rebuildLayout(for skins: [VRMSkin]) {
        let matrixSize = MemoryLayout<float4x4>.stride
        let frameCount = VRMConstants.Rendering.maxBufferedFrames

        skinSlots.removeAll(keepingCapacity: true)
        orderedSkinIDs.removeAll(keepingCapacity: true)
        lastSyncedJointCounts.removeAll(keepingCapacity: true)
        orderedSkinIDs.reserveCapacity(skins.count)
        lastSyncedJointCounts.reserveCapacity(skins.count)

        var currentOffset = 0
        var currentByteOffset = 0

        for (index, skin) in skins.enumerated() {
            let id = ObjectIdentifier(skin)
            let skinMatrixCount = skin.joints.count
            skin.matrixOffset = currentOffset
            skin.bufferByteOffset = currentByteOffset

            skinSlots[id] = SkinSlot(
                matrixOffset: currentOffset,
                bufferByteOffset: currentByteOffset,
                jointCount: skinMatrixCount,
                version: 0,
                latestPaletteSlot: paletteSlot,
                lastJointGeneration: nil,
                dirty: true,
                lastUpdatedFrame: nil,
                paletteVersions: Array(repeating: 0, count: frameCount)
            )
            orderedSkinIDs.append(id)
            lastSyncedJointCounts.append(skinMatrixCount)

            currentOffset += skinMatrixCount
            currentByteOffset += skinMatrixCount * matrixSize

            vrmLog("[SKINNING] Skin \(index) '\(skin.name ?? "unnamed")': \(skinMatrixCount) joints, offset=\(skin.matrixOffset), byteOffset=\(skin.bufferByteOffset)")
        }

        totalMatrixCount = currentOffset
        allSkinsUpdatedFrame = nil

        let paddedMatrixCount = totalMatrixCount + VRMConstants.Animation.maxJointCount
        ensureIdentityJointMatricesBuffer(matrixCount: paddedMatrixCount, matrixSize: matrixSize)

        let totalBufferSize = paddedMatrixCount * matrixSize
        let newBuffers = (0..<frameCount).compactMap { slot -> MTLBuffer? in
            let buffer = device.makeBuffer(length: totalBufferSize, options: .storageModeShared)
            buffer?.label = "Skin palettes frame \(slot)"
            return buffer
        }
        guard newBuffers.count == frameCount else {
            paletteBuffers.removeAll()
            jointMatricesBuffer = nil
            return
        }
        for buffer in newBuffers {
            let pointer = buffer.contents().bindMemory(to: float4x4.self, capacity: paddedMatrixCount)
            for i in 0..<paddedMatrixCount {
                pointer[i] = matrix_identity_float4x4
            }
        }
        paletteBuffers = newBuffers
        if paletteSlot >= paletteBuffers.count {
            paletteSlot = 0
        }
        jointMatricesBuffer = paletteBuffers[paletteSlot]
        vrmLog("[SKINNING] Allocated \(paletteBuffers.count) palettes for \(totalMatrixCount) matrices (\(totalBufferSize) bytes each, including padding)")
    }

    /// Ensures the dedicated identity-matrix buffer is allocated and covers at least `matrixCount` matrices.
    /// Grows atomically by replacing the reference (in-flight command buffers retain the previous buffer).
    private func ensureIdentityJointMatricesBuffer(matrixCount: Int, matrixSize: Int) {
        let requiredLength = matrixCount * matrixSize
        if let existing = identityJointMatricesBuffer, existing.length >= requiredLength {
            return
        }
        guard let buffer = device.makeBuffer(length: requiredLength, options: .storageModeShared) else { return }
        buffer.label = "Identity Joint Matrices (\(matrixCount))"
        let pointer = buffer.contents().bindMemory(to: float4x4.self, capacity: matrixCount)
        for i in 0..<matrixCount {
            pointer[i] = matrix_identity_float4x4
        }
        identityJointMatricesBuffer = buffer
    }

    /// Recomputes and uploads the joint palette for `skin` from current node world matrices.
    ///
    /// Multiplies `joint.worldMatrix * inverseBindMatrix` for every joint
    /// and writes the result into the shared buffer at `skin`'s byte
    /// offset. Per-joint NaN/Inf checks on the diagonal substitute identity
    /// for invalid matrices so a single bad bone cannot poison neighbouring
    /// vertices.
    ///
    /// Marks the skin as updated for the current frame via
    /// ``markSkinUpdated(for:)``.
    public func updateJointMatrices(for skin: VRMSkin) {
        let id = ObjectIdentifier(skin)
        guard let buffer = jointMatricesBuffer,
              var slot = skinSlots[id] else { return }

        guard slot.dirty else {
            if slot.paletteVersions[paletteSlot] != slot.version {
                let source = paletteBuffers[slot.latestPaletteSlot]
                let copyCount = min(slot.jointCount, skin.joints.count)
                if copyCount > 0 {
                    buffer.contents().advanced(by: slot.bufferByteOffset).copyMemory(
                        from: source.contents().advanced(by: slot.bufferByteOffset),
                        byteCount: copyCount * MemoryLayout<float4x4>.stride)
                }
                slot.paletteVersions[paletteSlot] = slot.version
            }
            slot.lastUpdatedFrame = currentFrameNumber
            skinSlots[id] = slot
            return
        }

        let count = min(slot.jointCount, skin.joints.count, skin.inverseBindMatrices.count)
        let pointer = buffer.contents()
            .advanced(by: slot.bufferByteOffset)
            .bindMemory(to: float4x4.self, capacity: max(1, slot.jointCount))

        slot.version &+= 1
        slot.paletteVersions[paletteSlot] = slot.version
        slot.latestPaletteSlot = paletteSlot
        slot.lastUpdatedFrame = currentFrameNumber
        slot.dirty = false
        skinSlots[id] = slot

        if let testSkinIndex = testIdentityPalette,
           testSkinIndex >= 0,
           testSkinIndex < orderedSkinIDs.count,
           orderedSkinIDs[testSkinIndex] == id {
            for i in 0..<slot.jointCount {
                pointer[i] = matrix_identity_float4x4
            }
            return
        }

        lastUpdatedSkinID = id
        debugFrameCount += 1

        skin.joints.withUnsafeBufferPointer { joints in
            skin.inverseBindMatrices.withUnsafeBufferPointer { ibms in
                for index in 0..<count {
                    let skinMatrix = joints[index].worldMatrix * ibms[index]
                    let diagValid = skinMatrix[0][0].isFinite
                        && skinMatrix[1][1].isFinite
                        && skinMatrix[2][2].isFinite
                        && skinMatrix[3][3].isFinite
                    pointer[index] = diagValid ? skinMatrix : matrix_identity_float4x4
                }
            }
        }
        if count < slot.jointCount {
            for index in count..<slot.jointCount {
                pointer[index] = matrix_identity_float4x4
            }
        }
    }

    /// Returns the selected frame's palette, or `nil` if setup did not allocate the ring.
    /// Fetch this each frame; a previously returned buffer still belongs to that frame.
    public func getJointMatricesBuffer() -> MTLBuffer? {
        return jointMatricesBuffer
    }

    /// Returns the byte offset within ``getJointMatricesBuffer()`` where `skin`'s palette begins.
    public func getBufferOffset(for skin: VRMSkin) -> Int {
        return skinSlots[ObjectIdentifier(skin)]?.bufferByteOffset ?? skin.bufferByteOffset
    }

    /// Returns the total joint count across all configured skins (unpadded).
    public func getTotalMatrixCount() -> Int {
        return totalMatrixCount
    }

    /// Clears the per-frame "last updated skin" cache. Call once per frame before issuing palette updates.
    public func beginFrame() {
        lastUpdatedSkinID = nil
    }

    /// Select a palette after the renderer has acquired this in-flight slot.
    /// All views of a compositor frame keep the same slot until completion.
    func beginFrame(bufferIndex: Int) {
        precondition((0..<VRMConstants.Rendering.maxBufferedFrames).contains(bufferIndex))
        paletteSlot = bufferIndex
        jointMatricesBuffer = paletteBuffers.isEmpty ? nil : paletteBuffers[bufferIndex]
        beginFrame()
    }

    /// Stamps every skin as fresh for `frameNumber` (used when the caller updates all skins in one pass).
    public func markAllSkinsUpdated(frameNumber: Int) {
        currentFrameNumber = frameNumber
        allSkinsUpdatedFrame = frameNumber
        for id in orderedSkinIDs {
            skinSlots[id]?.lastUpdatedFrame = frameNumber
        }
    }

    /// Stamps a single skin as fresh for the current frame.
    public func markSkinUpdated(for skin: VRMSkin) {
        let id = ObjectIdentifier(skin)
        skinSlots[id]?.lastUpdatedFrame = currentFrameNumber
    }

    /// Marks a single skin as needing joint-matrix recomputation.
    public func markSkinDirty(for skin: VRMSkin) {
        skinSlots[ObjectIdentifier(skin)]?.dirty = true
    }

    /// Clears the dirty flag for a single skin after it has been recomputed.
    public func clearSkinDirty(for skin: VRMSkin) {
        skinSlots[ObjectIdentifier(skin)]?.dirty = false
    }

    /// Returns `true` if the skin should have its joint matrices recomputed this frame.
    public func isSkinDirty(for skin: VRMSkin) -> Bool {
        return skinSlots[ObjectIdentifier(skin)]?.dirty ?? true
    }

    /// Marks every configured skin as needing joint-matrix recomputation.
    public func markAllSkinsDirty() {
        for id in orderedSkinIDs {
            skinSlots[id]?.dirty = true
        }
    }

    /// Marks a skin dirty only when one of its joints published a new world matrix.
    ///
    /// Call once per frame instead of ``markAllSkinsDirty()`` so idle or
    /// half-animated avatars skip the `world × IBM` upload for skins that
    /// did not move.
    public func markSkinsDirtyIfJointsMoved(_ skins: [VRMSkin]) {
        for skin in skins {
            let id = ObjectIdentifier(skin)
            guard var slot = skinSlots[id] else { continue }
            var generation: UInt64 = 0
            skin.joints.withUnsafeBufferPointer { joints in
                for joint in joints {
                    generation = generation &* 16_777_619 &+ joint.worldGeneration
                }
            }
            if slot.lastJointGeneration != generation {
                slot.dirty = true
                slot.lastJointGeneration = generation
                skinSlots[id] = slot
            }
        }
    }

    /// Logs a warning if `skin` was not updated for `frameNumber`.
    ///
    /// Does not throw; intended as a diagnostic gate before a draw call.
    /// Continues with stale data rather than aborting so the renderer
    /// degrades gracefully (typically falling back to bind pose).
    public func verifySkinFreshness(for skin: VRMSkin, frameNumber: Int) {
        if allSkinsUpdatedFrame == frameNumber {
            return
        }

        let id = ObjectIdentifier(skin)
        let diagnosticIndex = orderedSkinIDs.firstIndex(of: id) ?? -1
        if let lastUpdate = skinSlots[id]?.lastUpdatedFrame {
            if lastUpdate != frameNumber {
                vrmLog("⚠️ [FRESHNESS] WARNING: Skin \(diagnosticIndex) is stale! Last updated frame \(lastUpdate), current frame \(frameNumber)")
                let error = VRMSkinningError.stalePalette(
                    skinIndex: diagnosticIndex,
                    lastFrame: lastUpdate,
                    currentFrame: frameNumber
                )
                vrmLog("❌ [VRMSkinning] \(error.localizedDescription)")
            }
        } else {
            vrmLog("⚠️ [FRESHNESS] WARNING: Skin \(diagnosticIndex) was never updated!")
            let error = VRMSkinningError.neverUpdatedPalette(skinIndex: diagnosticIndex)
            vrmLog("❌ [VRMSkinning] \(error.localizedDescription)")
        }
    }

    // MARK: - Phase 1 Validation: GPU Readback

    /// Validate that joint matrices in GPU buffer are non-identity (animation is active)
    public func validateJointMatricesGPU(for skin: VRMSkin, expectNonIdentity: Bool = true) {
        guard let buffer = jointMatricesBuffer else {
            vrmLog("❌ [VALIDATION] No joint matrices buffer allocated!")
            return
        }

        let offset = getBufferOffset(for: skin)
        let pointer = buffer.contents().advanced(by: offset).bindMemory(to: float4x4.self, capacity: max(1, skin.joints.count))

        var identityCount = 0
        var nonIdentityCount = 0

        for i in 0..<min(5, skin.joints.count) {
            let matrix = pointer[i]

            let isIdentity = abs(matrix[0][0] - 1) < 0.001 && abs(matrix[1][1] - 1) < 0.001 &&
                            abs(matrix[2][2] - 1) < 0.001 && abs(matrix[3][3] - 1) < 0.001 &&
                            abs(matrix[0][3]) < 0.001 && abs(matrix[1][3]) < 0.001 && abs(matrix[2][3]) < 0.001

            if isIdentity {
                identityCount += 1
            } else {
                nonIdentityCount += 1
            }

            if i == 0 {
                vrmLog("📊 [GPU READBACK] Skin '\(skin.name ?? "unnamed")' Joint 0 matrix:")
                vrmLog("    [\(matrix[0][0]), \(matrix[0][1]), \(matrix[0][2]), \(matrix[0][3])]")
                vrmLog("    [\(matrix[1][0]), \(matrix[1][1]), \(matrix[1][2]), \(matrix[1][3])]")
                vrmLog("    [\(matrix[2][0]), \(matrix[2][1]), \(matrix[2][2]), \(matrix[2][3])]")
                vrmLog("    [\(matrix[3][0]), \(matrix[3][1]), \(matrix[3][2]), \(matrix[3][3])]")
                vrmLog("    Is Identity: \(isIdentity)")
            }
        }

        if expectNonIdentity && nonIdentityCount == 0 {
            vrmLog("⚠️ [VALIDATION] WARNING: All checked matrices are identity! Animation may not be applied.")
        } else if expectNonIdentity {
            vrmLog("✅ [VALIDATION] Found \(nonIdentityCount)/5 non-identity matrices (animation active)")
        } else {
            vrmLog("✅ [VALIDATION] Found \(identityCount)/5 identity matrices (bind pose correct)")
        }
    }

    /// Read back and validate vertex skinning attributes
    public func validateVertexAttributes(primitive: VRMPrimitive, meshName: String, paletteCount: Int) {
        guard let attributeBuffer = primitive.attributeBuffer else {
            vrmLog("❌ [VALIDATION] Mesh '\(meshName)': No attribute buffer!")
            return
        }

        guard primitive.hasJoints && primitive.hasWeights else {
            vrmLog("⚠️ [VALIDATION] Mesh '\(meshName)': No skinning attributes")
            return
        }

        let vertexCount = primitive.vertexCount
        let stride = MemoryLayout<VRMAttributeVertex>.stride
        let pointer = attributeBuffer.contents()

        var maxJoint: UInt32 = 0
        var minJoint: UInt32 = UInt32.max
        var maxWeightSumDeviation: Float = 0.0
        var outOfRangeCount = 0

        vrmLog("")
        vrmLog("📊 [VERTEX VALIDATION] Mesh '\(meshName)' - Scanning \(min(128, vertexCount)) vertices:")
        vrmLog("   Palette size: \(paletteCount) joints")

        let jointsOffset = MemoryLayout<VRMAttributeVertex>.offset(of: \.joints)!
        let weightsOffset = MemoryLayout<VRMAttributeVertex>.offset(of: \.weights)!

        vrmLog("📐 [VERTEX LAYOUT] joints offset: \(jointsOffset), weights offset: \(weightsOffset), stride: \(stride)")

        for i in 0..<min(128, vertexCount) {
            let offset = i * stride

            let jointsPtr = pointer.advanced(by: offset + jointsOffset).assumingMemoryBound(to: UInt32.self)
            let joints = [jointsPtr[0], jointsPtr[1], jointsPtr[2], jointsPtr[3]]

            let weightsPtr = pointer.advanced(by: offset + weightsOffset).assumingMemoryBound(to: Float.self)
            let weights = [weightsPtr[0], weightsPtr[1], weightsPtr[2], weightsPtr[3]]

            // Track statistics
            for joint in joints {
                if joint < minJoint { minJoint = joint }
                if joint > maxJoint { maxJoint = joint }

                // Check for out-of-range
                if Int(joint) >= paletteCount {
                    outOfRangeCount += 1
                    if outOfRangeCount <= 5 {  // Log first 5 violations
                        vrmLog("   ❌ V[\(i)]: Joint index \(joint) >= palette size \(paletteCount)!")
                    }
                }
            }

            let weightSum = weights.reduce(0, +)
            let deviation = abs(weightSum - 1.0)
            if deviation > maxWeightSumDeviation {
                maxWeightSumDeviation = deviation
            }

            // Log first few vertices
            if i < 5 {
                vrmLog("   V[\(i)]: joints=\(joints) weights=\(weights.map { String(format: "%.3f", $0) }) sum=\(String(format: "%.3f", weightSum))")
            }
        }

        vrmLog("")
        vrmLog("📈 [STATISTICS]")
        vrmLog("   Min joint index: \(minJoint)")
        vrmLog("   Max joint index: \(maxJoint)")
        vrmLog("   Palette size: \(paletteCount)")
        vrmLog("   Max weight sum deviation: \(String(format: "%.6f", maxWeightSumDeviation))")
        vrmLog("   Out-of-range joint count: \(outOfRangeCount)")

        // Assert max joint < palette size
        if maxJoint >= paletteCount {
            vrmLog("")
            vrmLog("❌ [CRITICAL] Max joint index (\(maxJoint)) >= palette size (\(paletteCount))")
            vrmLog("   This WILL cause the wedge artifact!")
            vrmLog("   The GPU shader will read garbage matrices beyond the palette.")
            vrmLog("   🐛 BUG CONFIRMED: This is the root cause of the wedge artifact.")
        } else {
            vrmLog("✅ [VALIDATION] All joint indices within valid range")
        }

        if maxWeightSumDeviation > 0.01 {
            vrmLog("⚠️  [WARNING] Some vertices have weight sums deviating from 1.0 by \(maxWeightSumDeviation)")
        }
        vrmLog("")
    }
}

// MARK: - Skinned Vertex Shader

/// Reference Metal source for the skinned vertex/fragment pipeline. Used as a JIT fallback when no precompiled `.metallib` is available.
public class SkinnedShader {
    /// Concatenated Metal shader source covering the skinned vertex stage and two fragment variants (lit, debug).
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct SkinnedVertex {
        float3 position [[attribute(0)]];
        float3 normal [[attribute(1)]];
        float2 texCoord [[attribute(2)]];
        float4 color [[attribute(3)]];
        uint4 joints [[attribute(4)]];    // Changed to uint4 for proper indexing
        float4 weights [[attribute(5)]];
    };

    struct Uniforms {
        float4x4 modelMatrix;
        float4x4 viewMatrix;
        float4x4 projectionMatrix;
        float4x4 normalMatrix;
    };

    struct VertexOut {
        float4 position [[position]];
        float3 worldPosition;
        float3 worldNormal;
        float2 texCoord;
        float2 animatedTexCoord;  // Required by MToon fragment shader
        float4 color;
        float3 viewDirection;
        float3 viewNormal;
    };

    vertex VertexOut skinned_vertex(SkinnedVertex in [[stage_in]],
                                    constant Uniforms& uniforms [[buffer(1)]],
                                    constant float4x4* jointMatrices [[buffer(3)]],
                                    constant uint& jointCount [[buffer(4)]],
                                    uint vertexID [[vertex_id]]) {
        // Apply skinning with proper weight normalization and bounds checking
        float4 weights = in.weights;
        float weightSum = max(dot(weights, 1.0), 1e-6);
        weights = weights / weightSum;  // Defensive renormalization

        uint4 joints = in.joints;

        // Clamp joint indices to valid range to prevent out-of-bounds access
        joints.x = min(joints.x, jointCount - 1);
        joints.y = min(joints.y, jointCount - 1);
        joints.z = min(joints.z, jointCount - 1);
        joints.w = min(joints.w, jointCount - 1);

        // Use joint indices directly - they're already skin-relative
        // The jointMatrices pointer is already offset by the encoder.setVertexBuffer call
        float4x4 skinMatrix = jointMatrices[joints.x] * weights.x +
                             jointMatrices[joints.y] * weights.y +
                             jointMatrices[joints.z] * weights.z +
                             jointMatrices[joints.w] * weights.w;

        // Transform position
        float4 skinnedPosition = skinMatrix * float4(in.position, 1.0);
        float4 worldPosition = uniforms.modelMatrix * skinnedPosition;

        // Transform normal
        float3 skinnedNormal = (skinMatrix * float4(in.normal, 0.0)).xyz;
        float3 worldNormal = (uniforms.normalMatrix * float4(skinnedNormal, 0.0)).xyz;

        VertexOut out;
        out.position = uniforms.projectionMatrix * uniforms.viewMatrix * worldPosition;
        out.worldPosition = worldPosition.xyz;
        out.worldNormal = normalize(worldNormal);
        out.texCoord = in.texCoord;
        out.animatedTexCoord = in.texCoord;  // No UV animation in skinned shader for now
        out.color = in.color;

        // Calculate view direction (for MToon shading)
        float3 cameraPos = -uniforms.viewMatrix[3].xyz;
        out.viewDirection = normalize(cameraPos - out.worldPosition);

        // Transform normal to view space for MatCap
        out.viewNormal = normalize((uniforms.viewMatrix * uniforms.normalMatrix * float4(skinnedNormal, 0.0)).xyz);

        return out;
    }

    // DEBUG Fragment shader - shows skinning visualization
    fragment float4 skinned_debug_fragment(VertexOut in [[stage_in]]) {
        // Color based on world position for debug visualization
        return float4(fract(in.worldPosition.x), fract(in.worldPosition.y), fract(in.worldPosition.z), 1.0);
    }

    // Fragment shader remains the same as regular rendering
    fragment float4 skinned_fragment(VertexOut in [[stage_in]]) {
        // Simple lit shading
        float3 lightDir = normalize(float3(0.5, 1.0, 0.5));
        float3 normal = normalize(in.worldNormal);
        float NdotL = max(dot(normal, lightDir), 0.0);

        float3 ambient = float3(0.3, 0.3, 0.3);
        float3 diffuse = float3(1.0, 1.0, 1.0) * NdotL;
        float3 color = (ambient + diffuse) * in.color.rgb;

        return float4(color, in.color.a);
    }
    """
}

// MARK: - Animation State

/// Snapshot of humanoid bone transforms at a given time, used by simple in-memory animations and ``VRMLookAtController/applyToAnimationState(_:)``.
///
/// Unlike ``AnimationClip``, which lazily samples closures, `VRMAnimationState`
/// is a flat dictionary of bone → transform applied wholesale via
/// ``applyToModel(_:)``. Useful for hand-authored poses and test harnesses.
public final class VRMAnimationState {
    /// Current time in seconds for this state (informational; not used by ``applyToModel(_:)``).
    public var time: Float = 0
    /// Sparse bone-to-transform map. Bones not present are left at their current values when applied.
    public var bones: [VRMHumanoidBone: BoneTransform] = [:]

    /// Local TRS triplet describing a single bone's pose.
    public struct BoneTransform {
        /// Local rotation; identity quaternion by default.
        public var rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        /// Local translation; zero by default.
        public var translation: SIMD3<Float> = [0, 0, 0]
        /// Local scale; unit scale by default.
        public var scale: SIMD3<Float> = [1, 1, 1]

        /// Creates an identity bone transform.
        public init() {}
    }

    /// Creates an empty animation state pre-configured to T-pose.
    public init() {
        // Initialize default pose
        resetToTPose()
    }

    /// Clears all per-bone overrides, returning to the model's T-pose bind values.
    public func resetToTPose() {
        bones.removeAll()
        // T-pose is the default bind pose for VRM
    }

    /// Writes the stored bone transforms onto `model.nodes` and propagates world transforms from each root.
    public func applyToModel(_ model: VRMModel) {
        guard let humanoid = model.humanoid else { return }

        for (bone, transform) in bones {
            guard let nodeIndex = humanoid.getBoneNode(bone),
                  nodeIndex < model.nodes.count else { continue }

            let node = model.nodes[nodeIndex]
            node.rotation = transform.rotation
            node.translation = transform.translation
            node.scale = transform.scale
            node.updateLocalMatrix()
        }

        // Update world transforms
        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }
    }
}

// MARK: - Simple Animation Presets

/// Procedural ``VRMAnimationState`` factories for simple time-driven motions (wave, idle, walk).
///
/// Each factory returns a closure mapping a time in seconds to a fresh
/// ``VRMAnimationState`` snapshot, suitable for driving test scenes without
/// loading an authored animation file.
public final class VRMAnimationPresets {

    /// Returns a closure that builds a hand-waving pose over `duration` seconds.
    public static func createWaveAnimation(duration: Float = 2.0) -> (Float) -> VRMAnimationState {
        return { time in
            let state = VRMAnimationState()

            // Wave with right hand
            let waveAngle = sin(time * 2 * .pi / duration) * 0.3

            state.bones[.rightUpperArm] = VRMAnimationState.BoneTransform()
            state.bones[.rightUpperArm]?.rotation = simd_quatf(angle: .pi/3, axis: [0, 0, 1]) *
                                                    simd_quatf(angle: waveAngle, axis: [1, 0, 0])

            state.bones[.rightLowerArm] = VRMAnimationState.BoneTransform()
            state.bones[.rightLowerArm]?.rotation = simd_quatf(angle: .pi/4, axis: [0, 1, 0])

            state.bones[.rightHand] = VRMAnimationState.BoneTransform()
            state.bones[.rightHand]?.rotation = simd_quatf(angle: sin(time * 4 * .pi / duration) * 0.5, axis: [0, 0, 1])

            return state
        }
    }

    /// Returns a closure that builds a gentle breathing-and-sway idle pose over `duration` seconds.
    public static func createIdleAnimation(duration: Float = 4.0) -> (Float) -> VRMAnimationState {
        return { time in
            let state = VRMAnimationState()

            // Subtle breathing motion
            let breathAmount = sin(time * 2 * .pi / duration) * 0.02
            state.bones[.chest] = VRMAnimationState.BoneTransform()
            state.bones[.chest]?.scale = [1, 1 + breathAmount, 1]

            // Slight head movement
            let headSway = sin(time * .pi / duration) * 0.05
            state.bones[.head] = VRMAnimationState.BoneTransform()
            state.bones[.head]?.rotation = simd_quatf(angle: headSway, axis: [0, 1, 0])

            return state
        }
    }

    /// Returns a closure that builds a simple cyclic walk pose (legs swing, arms swing, hips bob) over `duration` seconds.
    public static func createWalkAnimation(duration: Float = 1.0) -> (Float) -> VRMAnimationState {
        return { time in
            let state = VRMAnimationState()
            let phase = (time / duration).truncatingRemainder(dividingBy: 1.0)

            // Leg movement
            let legAngle = sin(phase * 2 * .pi) * 0.5

            state.bones[.leftUpperLeg] = VRMAnimationState.BoneTransform()
            state.bones[.leftUpperLeg]?.rotation = simd_quatf(angle: legAngle, axis: [1, 0, 0])

            state.bones[.rightUpperLeg] = VRMAnimationState.BoneTransform()
            state.bones[.rightUpperLeg]?.rotation = simd_quatf(angle: -legAngle, axis: [1, 0, 0])

            // Knee bend
            state.bones[.leftLowerLeg] = VRMAnimationState.BoneTransform()
            state.bones[.leftLowerLeg]?.rotation = simd_quatf(angle: max(0, -legAngle * 0.8), axis: [1, 0, 0])

            state.bones[.rightLowerLeg] = VRMAnimationState.BoneTransform()
            state.bones[.rightLowerLeg]?.rotation = simd_quatf(angle: max(0, legAngle * 0.8), axis: [1, 0, 0])

            // Arm swing
            let armSwing = sin(phase * 2 * .pi) * 0.3

            state.bones[.leftUpperArm] = VRMAnimationState.BoneTransform()
            state.bones[.leftUpperArm]?.rotation = simd_quatf(angle: -armSwing, axis: [1, 0, 0])

            state.bones[.rightUpperArm] = VRMAnimationState.BoneTransform()
            state.bones[.rightUpperArm]?.rotation = simd_quatf(angle: armSwing, axis: [1, 0, 0])

            // Hip sway
            state.bones[.hips] = VRMAnimationState.BoneTransform()
            state.bones[.hips]?.translation = [0, sin(phase * 4 * .pi) * 0.02, 0]

            return state
        }
    }
}
