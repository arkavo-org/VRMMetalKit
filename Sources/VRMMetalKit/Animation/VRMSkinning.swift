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

public class VRMSkinningSystem {
    private let device: MTLDevice
    public var jointMatricesBuffer: MTLBuffer?  // Made public for debugging/validation
    private var totalMatrixCount = 0
    private var lastUpdatedSkinIndex: Int? = nil  // Cache to avoid redundant updates
    private var debugFrameCount = 0

    // Freshness tracking
    private var currentFrameNumber: Int = 0
    private var skinLastUpdatedFrame: [Int: Int] = [:]  // skinIndex -> frameNumber

    // DIFFERENTIAL TRANSFORM ANALYSIS: Clean baseline captures
    private var cleanWorldMatrices: [ObjectIdentifier: float4x4] = [:]  // nodeID -> clean worldMatrix
    private var hasCapturedCleanBaseline = false

    // A/B Testing: Identity palette override
    public var testIdentityPalette: Int? = nil

    public init(device: MTLDevice) {
        self.device = device
    }

    /// Pre-flight check: Capture clean worldMatrix for each joint in isolation
    public func captureCleanBaseline(for skin: VRMSkin, skinIndex: Int) {
        guard !hasCapturedCleanBaseline else { return }

        vrmLog("🔬 [DIFFERENTIAL] Capturing clean baseline for skin \(skinIndex) (\(skin.joints.count) joints)")

        for (index, joint) in skin.joints.enumerated() {
            // Recursively calculate worldMatrix in isolation (from local transforms only)
            let cleanWorld = calculateCleanWorldMatrix(for: joint)
            cleanWorldMatrices[ObjectIdentifier(joint)] = cleanWorld

            if index < 5 {
                vrmLog("   Joint[\(index)] '\(joint.name ?? "?")': clean translation magnitude = \(length(simd_float3(cleanWorld[3][0], cleanWorld[3][1], cleanWorld[3][2])))")
            }
        }

        hasCapturedCleanBaseline = true
        vrmLog("✅ [DIFFERENTIAL] Baseline captured for \(cleanWorldMatrices.count) joints")
    }

    /// Calculate worldMatrix in isolation by walking up parent chain
    private func calculateCleanWorldMatrix(for node: VRMNode) -> float4x4 {
        var current: VRMNode? = node
        var matrices: [float4x4] = []

        // Walk up to root, collecting local matrices
        while let n = current {
            // Build local matrix from TRS components
            let translationMatrix = matrix_float4x4(
                SIMD4<Float>(1, 0, 0, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(0, 0, 1, 0),
                SIMD4<Float>(n.translation.x, n.translation.y, n.translation.z, 1)
            )

            let rotationMatrix = matrix_float4x4(n.rotation)

            let scaleMatrix = matrix_float4x4(
                SIMD4<Float>(n.scale.x, 0, 0, 0),
                SIMD4<Float>(0, n.scale.y, 0, 0),
                SIMD4<Float>(0, 0, n.scale.z, 0),
                SIMD4<Float>(0, 0, 0, 1)
            )

            // Local = T * R * S
            let localMatrix = translationMatrix * rotationMatrix * scaleMatrix
            matrices.insert(localMatrix, at: 0)  // Insert at beginning to maintain order
            current = n.parent
        }

        // Multiply matrices from root to node
        var worldMatrix = matrix_identity_float4x4
        for m in matrices {
            worldMatrix = worldMatrix * m
        }

        return worldMatrix
    }

    // Initialize the buffer system with all skins to calculate offsets
    public func setupForSkins(_ skins: [VRMSkin]) {
        // Calculate total matrix count and assign offsets
        var currentOffset = 0
        var currentByteOffset = 0
        let matrixSize = MemoryLayout<float4x4>.stride

        for (index, skin) in skins.enumerated() {
            skin.matrixOffset = currentOffset
            skin.bufferByteOffset = currentByteOffset

            let skinMatrixCount = skin.joints.count
            currentOffset += skinMatrixCount
            currentByteOffset += skinMatrixCount * matrixSize

            vrmLog("[SKINNING] Skin \(index) '\(skin.name ?? "unnamed")': \(skinMatrixCount) joints, offset=\(skin.matrixOffset), byteOffset=\(skin.bufferByteOffset)")
        }

        totalMatrixCount = currentOffset

        // Allocate the large buffer for all skins
        let totalBufferSize = currentByteOffset
        jointMatricesBuffer = device.makeBuffer(length: totalBufferSize, options: .storageModeShared)
        vrmLog("[SKINNING] Allocated buffer for \(totalMatrixCount) total matrices (\(totalBufferSize) bytes)")

        // Initialize all matrices to identity to prevent garbage
        if let buffer = jointMatricesBuffer {
            let pointer = buffer.contents().bindMemory(to: float4x4.self, capacity: totalMatrixCount)
            for i in 0..<totalMatrixCount {
                pointer[i] = float4x4(1)  // Identity matrix
            }
        }
    }

    public func updateJointMatrices(for skin: VRMSkin, skinIndex: Int) {
        guard let buffer = jointMatricesBuffer else { return }

        // A/B TEST: Use identity matrices if this skin is being tested
        if let testSkin = testIdentityPalette, testSkin == skinIndex {
            vrmLog("🧪 [IDENTITY TEST] Using identity palette for skin \(skinIndex) (A/B test)")

            // Fill palette with identity matrices
            var identityMatrices = [float4x4]()
            for _ in 0..<skin.joints.count {
                identityMatrices.append(matrix_identity_float4x4)
            }

            // Write to buffer
            let pointer = buffer.contents().advanced(by: skin.bufferByteOffset).bindMemory(to: float4x4.self, capacity: skin.joints.count)
            for (i, matrix) in identityMatrices.enumerated() {
                pointer[i] = matrix
            }

            vrmLog("✅ [IDENTITY TEST] Written \(skin.joints.count) identity matrices to GPU buffer at offset \(skin.bufferByteOffset)")
            return
        }

        // Skip if we just updated this skin (optimization)
        // DISABLED: This causes issues when multiple meshes use same skin
        // if let lastIndex = lastUpdatedSkinIndex, lastIndex == skinIndex {
        //     return
        // }
        lastUpdatedSkinIndex = skinIndex

        // Mark this skin as updated for freshness tracking
        markSkinUpdated(skinIndex: skinIndex)

        var matrices = [float4x4]()

        // Debug: Check joints to see if animation is applied
        debugFrameCount += 1
        if debugFrameCount % 10 == 0 {
            vrmLog("[UPDATE ORDER] 3. Skinning.updateJointMatrices() - building palette for skin \(skinIndex)")
            vrmLog("[SKINNING] Updating \(skin.joints.count) joint matrices for skin \(skinIndex) at offset \(skin.matrixOffset)")
        }
        if debugFrameCount == 1 {
            // Log ALL skin joints on first frame to understand mapping
            vrmLog("[SKIN MAPPING] Skin contains \(skin.joints.count) joints:")
            for (i, joint) in skin.joints.enumerated().prefix(10) {
                vrmLog("[SKIN MAPPING] Joint[\(i)]: node \(joint.name ?? "?") rotation=\(joint.rotation)")

                // Trace hierarchy up to root
                var chain = [String]()
                var current: VRMNode? = joint
                while let node = current {
                    chain.append(node.name ?? "node?")
                    current = node.parent
                }
                vrmLog("[HIERARCHY] Joint[\(i)] chain: \(chain.joined(separator: " → "))")
            }
        }
        if debugFrameCount % 60 == 0 && !skin.joints.isEmpty {
            // Check multiple joints
            for i in 0..<min(5, skin.joints.count) {
                let joint = skin.joints[i]
                vrmLog("[Skinning] Frame \(debugFrameCount): Joint \(i) (\(joint.name ?? "unnamed")) rotation: \(joint.rotation)")
            }
        }

        for (index, joint) in skin.joints.enumerated() {
            // Calculate skinning matrix: joint world matrix * inverse bind matrix
            // Standard formula: world * inverseBindPose
            let worldMatrix = joint.worldMatrix
            let inverseBindMatrix = skin.inverseBindMatrices[index]

            // DIFFERENTIAL TRANSFORM ANALYSIS: Compare live vs clean for skin 4
            if skinIndex == 4, let cleanWorld = cleanWorldMatrices[ObjectIdentifier(joint)] {
                // Check for corruption: NaN/Inf or excessive deviation from clean baseline
                let liveTranslation = simd_float3(worldMatrix[3][0], worldMatrix[3][1], worldMatrix[3][2])
                let cleanTranslation = simd_float3(cleanWorld[3][0], cleanWorld[3][1], cleanWorld[3][2])
                let deviation = length(liveTranslation - cleanTranslation)

                let hasNaNLive = !worldMatrix[0][0].isFinite || !worldMatrix[1][1].isFinite || !worldMatrix[2][2].isFinite
                let hasNaNClean = !cleanWorld[0][0].isFinite || !cleanWorld[1][1].isFinite || !cleanWorld[2][2].isFinite

                // Log first few joints to see actual deviation values
                if index < 5 {
                    vrmLog("[DIFFERENTIAL DEBUG] Frame=\(debugFrameCount) Joint[\(index)] '\(joint.name ?? "unnamed")': deviation=\(deviation)")

                    // Also check inverseBindMatrix for corruption
                    let invBindTrans = simd_float3(inverseBindMatrix[3][0], inverseBindMatrix[3][1], inverseBindMatrix[3][2])
                    let invBindMag = length(invBindTrans)
                    let hasNaNInvBind = !inverseBindMatrix[0][0].isFinite || !inverseBindMatrix[1][1].isFinite
                    vrmLog("   InverseBindMatrix translation mag: \(invBindMag), hasNaN: \(hasNaNInvBind)")
                }

                // Tolerate small numerical drift; only warn on larger deviation or NaN
                let deviationThreshold: Float = 0.1
                if hasNaNLive || deviation > deviationThreshold {
                    vrmLog("")
                    vrmLog("🚨 [CORRUPTION DETECTED] Skin[\(skinIndex)] Joint[\(index)] '\(joint.name ?? "unnamed")'")
                    vrmLog("   Live matrix NaN: \(hasNaNLive), Clean matrix NaN: \(hasNaNClean)")
                    vrmLog("   Live translation: \(liveTranslation)")
                    vrmLog("   Clean translation: \(cleanTranslation)")
                    vrmLog("   Deviation: \(deviation)")
                    vrmLog("")

                    // Dump entire parent hierarchy
                    vrmLog("📊 [HIERARCHY DUMP] Tracing corruption source:")
                    var current: VRMNode? = joint
                    var level = 0
                    while let node = current {
                        let indent = String(repeating: "  ", count: level)
                        let nodeName = node.name ?? "unnamed"
                        let localTrans = node.translation
                        let worldTrans = simd_float3(node.worldMatrix[3][0], node.worldMatrix[3][1], node.worldMatrix[3][2])

                        vrmLog("\(indent)Level \(level): '\(nodeName)'")
                        vrmLog("\(indent)  Local: t=\(localTrans) r=\(node.rotation) s=\(node.scale)")
                        vrmLog("\(indent)  World translation: \(worldTrans)")

                        if !node.worldMatrix[0][0].isFinite {
                            vrmLog("\(indent)  ❌ THIS NODE HAS NaN IN WORLD MATRIX!")
                        }

                        current = node.parent
                        level += 1
                    }
                    vrmLog("")

                    // Do not crash in production; log only. If needed, tighten via Strict mode later.
                }
            }

            // TEST: Try manual multiplication to debug
            if debugFrameCount == 1 && skinIndex == 0 && index == 0 {
                // Manual multiplication for debugging
                let w = worldMatrix
                let ib = inverseBindMatrix

                // Matrix multiplication: result[i][j] = sum(w[i][k] * ib[k][j])
                var manual = matrix_identity_float4x4
                for i in 0..<4 {
                    for j in 0..<4 {
                        var sum: Float = 0
                        for k in 0..<4 {
                            sum += w[i][k] * ib[k][j]
                        }
                        manual[i][j] = sum
                    }
                }
                vrmLog("[DEBUG] Manual multiplication result:")
                vrmLog("    [\(manual[0][0]), \(manual[0][1]), \(manual[0][2]), \(manual[0][3])]")
                vrmLog("    [\(manual[1][0]), \(manual[1][1]), \(manual[1][2]), \(manual[1][3])]")
                vrmLog("    [\(manual[2][0]), \(manual[2][1]), \(manual[2][2]), \(manual[2][3])]")
                vrmLog("    [\(manual[3][0]), \(manual[3][1]), \(manual[3][2]), \(manual[3][3])]")
            }

            // Standard skinning formula: worldMatrix * inverseBindMatrix
            // Now that we're not transposing the inverse bind matrices, try the standard order
            let skinMatrix = worldMatrix * inverseBindMatrix

            // CORRUPTION GUARD: Comprehensive validation before adding to palette
            let allComponents = [skinMatrix[0][0], skinMatrix[0][1], skinMatrix[0][2], skinMatrix[0][3],
                                 skinMatrix[1][0], skinMatrix[1][1], skinMatrix[1][2], skinMatrix[1][3],
                                 skinMatrix[2][0], skinMatrix[2][1], skinMatrix[2][2], skinMatrix[2][3],
                                 skinMatrix[3][0], skinMatrix[3][1], skinMatrix[3][2], skinMatrix[3][3]]

            let hasNaN = allComponents.contains { !$0.isFinite }
            let translation = simd_float3(skinMatrix[3][0], skinMatrix[3][1], skinMatrix[3][2])
            let translationMag = length(translation)
            let scale0 = length(simd_float3(skinMatrix[0][0], skinMatrix[0][1], skinMatrix[0][2]))
            let scale1 = length(simd_float3(skinMatrix[1][0], skinMatrix[1][1], skinMatrix[1][2]))
            let scale2 = length(simd_float3(skinMatrix[2][0], skinMatrix[2][1], skinMatrix[2][2]))

            if hasNaN || translationMag > 1000.0 || scale0 < 0.001 || scale0 > 1000.0 || scale1 < 0.001 || scale1 > 1000.0 || scale2 < 0.001 || scale2 > 1000.0 {
                vrmLog("❌ [SKINNING CORRUPTION] Skin[\(skinIndex)] Joint[\(index)] '\(joint.name ?? "unnamed")'")
                vrmLog("   NaN/Inf: \(hasNaN)")
                vrmLog("   Translation magnitude: \(translationMag)")
                vrmLog("   Scale: [\(scale0), \(scale1), \(scale2)]")
                vrmLog("   WorldMatrix diagonal: [\(worldMatrix[0][0]), \(worldMatrix[1][1]), \(worldMatrix[2][2]), \(worldMatrix[3][3])]")
                vrmLog("   InverseBindMatrix diagonal: [\(inverseBindMatrix[0][0]), \(inverseBindMatrix[1][1]), \(inverseBindMatrix[2][2]), \(inverseBindMatrix[3][3])]")

                // Use identity matrix as fallback for this frame
                matrices.append(float4x4(1))
                continue
            }

            // SPECIAL LOGGING FOR SKIN 4 (flonthair) - Log all joints
            if skinIndex == 4 && debugFrameCount <= 2 {
                vrmLog("[SKIN 4 ANALYSIS] Frame=\(debugFrameCount) Joint[\(index)] '\(joint.name ?? "unnamed")'")
                vrmLog("   Translation: \(translation), magnitude: \(translationMag)")
                vrmLog("   Scale: [\(scale0), \(scale1), \(scale2)]")
                if hasNaN || translationMag > 100.0 {
                    vrmLog("   ⚠️  SUSPICIOUS VALUES DETECTED")
                }
            }

            // AGGRESSIVE MATRIX LOGGING - First frame comparison between models
            if debugFrameCount == 1 && index < 3 {  // Log first 3 joints of every skin
                vrmLog("[MATRIX COMPARISON] Skin[\(skinIndex)] Joint[\(index)] (\(joint.name ?? "unnamed"))")

                let w = worldMatrix
                let ib = inverseBindMatrix
                let s = skinMatrix

                // Log input matrices
                vrmLog("  WorldMatrix:")
                vrmLog("    [\(w[0][0]), \(w[0][1]), \(w[0][2]), \(w[0][3])]")
                vrmLog("    [\(w[1][0]), \(w[1][1]), \(w[1][2]), \(w[1][3])]")
                vrmLog("    [\(w[2][0]), \(w[2][1]), \(w[2][2]), \(w[2][3])]")
                vrmLog("    [\(w[3][0]), \(w[3][1]), \(w[3][2]), \(w[3][3])]")

                vrmLog("  InverseBindMatrix:")
                vrmLog("    [\(ib[0][0]), \(ib[0][1]), \(ib[0][2]), \(ib[0][3])]")
                vrmLog("    [\(ib[1][0]), \(ib[1][1]), \(ib[1][2]), \(ib[1][3])]")
                vrmLog("    [\(ib[2][0]), \(ib[2][1]), \(ib[2][2]), \(ib[2][3])]")
                vrmLog("    [\(ib[3][0]), \(ib[3][1]), \(ib[3][2]), \(ib[3][3])]")

                vrmLog("  ResultingSkinMatrix (world * inverseBind):")
                vrmLog("    [\(s[0][0]), \(s[0][1]), \(s[0][2]), \(s[0][3])]")
                vrmLog("    [\(s[1][0]), \(s[1][1]), \(s[1][2]), \(s[1][3])]")
                vrmLog("    [\(s[2][0]), \(s[2][1]), \(s[2][2]), \(s[2][3])]")
                vrmLog("    [\(s[3][0]), \(s[3][1]), \(s[3][2]), \(s[3][3])]")

                // NaN/Inf detection
                let hasNaN = [s[0][0], s[0][1], s[0][2], s[0][3],
                             s[1][0], s[1][1], s[1][2], s[1][3],
                             s[2][0], s[2][1], s[2][2], s[2][3],
                             s[3][0], s[3][1], s[3][2], s[3][3]].contains { !$0.isFinite }

                if hasNaN {
                    vrmLog("  ❌ ERROR: Matrix contains NaN or Inf values!")
                    // Log error instead of crashing - this allows recovery/debugging
                    let error = VRMSkinningError.matrixContainsNaN(
                        skinIndex: skinIndex,
                        jointIndex: index,
                        jointName: joint.name
                    )
                    vrmLog("❌ [VRMSkinning] \(error.localizedDescription)")
                    // Continue to allow investigation of other joints
                }

                // Check if it's roughly identity (for bind pose verification)
                let isIdentity = abs(s[0][0] - 1) < 0.001 && abs(s[1][1] - 1) < 0.001 &&
                                abs(s[2][2] - 1) < 0.001 && abs(s[3][3] - 1) < 0.001 &&
                                abs(s[0][3]) < 0.001 && abs(s[1][3]) < 0.001 && abs(s[2][3]) < 0.001
                vrmLog("  Is Identity? \(isIdentity) (expected for bind pose)")

                // Additional validation
                let translation = simd_float3(s[3][0], s[3][1], s[3][2])
                let scale = simd_float3(length(simd_float3(s[0][0], s[0][1], s[0][2])),
                                       length(simd_float3(s[1][0], s[1][1], s[1][2])),
                                       length(simd_float3(s[2][0], s[2][1], s[2][2])))
                vrmLog("  Translation: \(translation)")
                vrmLog("  Scale: \(scale)")
            }

            // Validate the matrix - check for NaN or infinity
            let isValid = skinMatrix[0][0].isFinite && skinMatrix[1][1].isFinite &&
                         skinMatrix[2][2].isFinite && skinMatrix[3][3].isFinite

            if !isValid {
                vrmLog("[SKINNING ERROR] Invalid matrix for joint \(index) (\(joint.name ?? "?"))")
                vrmLog("  World matrix diagonal: [\(worldMatrix[0][0]), \(worldMatrix[1][1]), \(worldMatrix[2][2]), \(worldMatrix[3][3])]")
                vrmLog("  InverseBind diagonal: [\(inverseBindMatrix[0][0]), \(inverseBindMatrix[1][1]), \(inverseBindMatrix[2][2]), \(inverseBindMatrix[3][3])]")
                // Use identity matrix as fallback
                matrices.append(float4x4(1))
            } else {
                matrices.append(skinMatrix)
            }

            // Debug first joint in detail on first frame
            if debugFrameCount == 1 && index == 0 {
                vrmLog("[SKIN MATRIX DEBUG] Joint 0 (\(joint.name ?? "?")):")
                let w = joint.worldMatrix
                vrmLog("  World Matrix:")
                vrmLog("    [\(w[0][0]), \(w[0][1]), \(w[0][2]), \(w[0][3])]")
                vrmLog("    [\(w[1][0]), \(w[1][1]), \(w[1][2]), \(w[1][3])]")
                vrmLog("    [\(w[2][0]), \(w[2][1]), \(w[2][2]), \(w[2][3])]")
                vrmLog("    [\(w[3][0]), \(w[3][1]), \(w[3][2]), \(w[3][3])]")

                let ib = skin.inverseBindMatrices[index]
                vrmLog("  Inverse Bind Matrix:")
                vrmLog("    [\(ib[0][0]), \(ib[0][1]), \(ib[0][2]), \(ib[0][3])]")
                vrmLog("    [\(ib[1][0]), \(ib[1][1]), \(ib[1][2]), \(ib[1][3])]")
                vrmLog("    [\(ib[2][0]), \(ib[2][1]), \(ib[2][2]), \(ib[2][3])]")
                vrmLog("    [\(ib[3][0]), \(ib[3][1]), \(ib[3][2]), \(ib[3][3])]")

                let s = skinMatrix
                vrmLog("  Skin Matrix (Result):")
                vrmLog("    [\(s[0][0]), \(s[0][1]), \(s[0][2]), \(s[0][3])]")
                vrmLog("    [\(s[1][0]), \(s[1][1]), \(s[1][2]), \(s[1][3])]")
                vrmLog("    [\(s[2][0]), \(s[2][1]), \(s[2][2]), \(s[2][3])]")
                vrmLog("    [\(s[3][0]), \(s[3][1]), \(s[3][2]), \(s[3][3])]")
            }

            // Debug: Check if the palette has non-identity transforms
            if debugFrameCount % 60 == 0 && index < 5 {
                // Check if world matrix is identity (no animation)
                let m = joint.worldMatrix
                let isIdentity = (m[0][0] == 1 && m[1][1] == 1 && m[2][2] == 1 && m[3][3] == 1 &&
                                 m[0][3] == 0 && m[1][3] == 0 && m[2][3] == 0)
                vrmLog("[PALETTE] Joint \(index) (\(joint.name ?? "?")): worldMatrix diagonal=[\(m[0][0]), \(m[1][1]), \(m[2][2])], identity=\(isIdentity)")
            }
        }

        // Update buffer at the correct offset for this skin
        let pointer = buffer.contents().advanced(by: skin.bufferByteOffset).bindMemory(to: float4x4.self, capacity: skin.joints.count)

        // Copy matrices to the correct location
        for (index, matrix) in matrices.enumerated() {
            pointer[index] = matrix
        }
    }

    public func getJointMatricesBuffer() -> MTLBuffer? {
        return jointMatricesBuffer
    }

    public func getBufferOffset(for skin: VRMSkin) -> Int {
        return skin.bufferByteOffset
    }

    public func getTotalMatrixCount() -> Int {
        return totalMatrixCount
    }

    // Reset cache at frame boundary
    public func beginFrame() {
        lastUpdatedSkinIndex = nil
    }

    // Mark all skins as updated for the current frame
    public func markAllSkinsUpdated(frameNumber: Int) {
        currentFrameNumber = frameNumber
        // Clear the tracking dictionary and mark all as fresh
        skinLastUpdatedFrame.removeAll()
    }

    // Mark a specific skin as updated
    public func markSkinUpdated(skinIndex: Int) {
        skinLastUpdatedFrame[skinIndex] = currentFrameNumber
    }

    // Verify that a skin is fresh for the current frame
    public func verifySkinFreshness(skinIndex: Int, frameNumber: Int) {
        // If we updated all skins this frame, they're all fresh
        if currentFrameNumber == frameNumber {
            return  // All good
        }

        // Otherwise check individual skin update
        if let lastUpdate = skinLastUpdatedFrame[skinIndex] {
            if lastUpdate != frameNumber {
                vrmLog("⚠️ [FRESHNESS] WARNING: Skin \(skinIndex) is stale! Last updated frame \(lastUpdate), current frame \(frameNumber)")
                // Log error instead of crashing to allow graceful degradation
                let error = VRMSkinningError.stalePalette(
                    skinIndex: skinIndex,
                    lastFrame: lastUpdate,
                    currentFrame: frameNumber
                )
                vrmLog("❌ [VRMSkinning] \(error.localizedDescription)")
                // Continue with stale data rather than crashing
            }
        } else {
            vrmLog("⚠️ [FRESHNESS] WARNING: Skin \(skinIndex) was never updated!")
            // Log error instead of crashing to allow graceful degradation
            let error = VRMSkinningError.neverUpdatedPalette(skinIndex: skinIndex)
            vrmLog("❌ [VRMSkinning] \(error.localizedDescription)")
            // Continue to allow debugging - may render with bind pose
        }
    }

    // MARK: - Phase 1 Validation: GPU Readback

    /// Validate that joint matrices in GPU buffer are non-identity (animation is active)
    public func validateJointMatricesGPU(for skin: VRMSkin, skinIndex: Int, expectNonIdentity: Bool = true) {
        guard let buffer = jointMatricesBuffer else {
            vrmLog("❌ [VALIDATION] No joint matrices buffer allocated!")
            return
        }

        let pointer = buffer.contents().advanced(by: skin.bufferByteOffset).bindMemory(to: float4x4.self, capacity: skin.joints.count)

        var identityCount = 0
        var nonIdentityCount = 0

        for i in 0..<min(5, skin.joints.count) {
            let matrix = pointer[i]

            // Check if matrix is identity
            let isIdentity = abs(matrix[0][0] - 1) < 0.001 && abs(matrix[1][1] - 1) < 0.001 &&
                            abs(matrix[2][2] - 1) < 0.001 && abs(matrix[3][3] - 1) < 0.001 &&
                            abs(matrix[0][3]) < 0.001 && abs(matrix[1][3]) < 0.001 && abs(matrix[2][3]) < 0.001

            if isIdentity {
                identityCount += 1
            } else {
                nonIdentityCount += 1
            }

            if i == 0 {
                vrmLog("📊 [GPU READBACK] Skin \(skinIndex) Joint 0 matrix:")
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
        guard let vertexBuffer = primitive.vertexBuffer else {
            vrmLog("❌ [VALIDATION] Mesh '\(meshName)': No vertex buffer!")
            return
        }

        guard primitive.hasJoints && primitive.hasWeights else {
            vrmLog("⚠️ [VALIDATION] Mesh '\(meshName)': No skinning attributes")
            return
        }

        let vertexCount = primitive.vertexCount
        let stride = 96 // VRMVertex stride
        let pointer = vertexBuffer.contents()

        var maxJoint: UInt32 = 0
        var minJoint: UInt32 = UInt32.max
        var maxWeightSumDeviation: Float = 0.0
        var outOfRangeCount = 0

        vrmLog("")
        vrmLog("📊 [VERTEX VALIDATION] Mesh '\(meshName)' - Scanning \(min(128, vertexCount)) vertices:")
        vrmLog("   Palette size: \(paletteCount) joints")

        // Scan first 128 vertices (or all if fewer)
        for i in 0..<min(128, vertexCount) {
            let offset = i * stride

            // Joints at offset 64 (ushort4 = 4 * uint16, stored as 8 bytes total)
            let jointsPtr = pointer.advanced(by: offset + 64).assumingMemoryBound(to: UInt16.self)
            let joints = [UInt32(jointsPtr[0]), UInt32(jointsPtr[1]), UInt32(jointsPtr[2]), UInt32(jointsPtr[3])]

            // Weights at offset 80 (float4 = 4 * float32)
            let weightsPtr = pointer.advanced(by: offset + 80).assumingMemoryBound(to: Float.self)
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

public class SkinnedShader {
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

public class VRMAnimationState {
    public var time: Float = 0
    public var bones: [VRMHumanoidBone: BoneTransform] = [:]

    public struct BoneTransform {
        public var rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        public var translation: SIMD3<Float> = [0, 0, 0]
        public var scale: SIMD3<Float> = [1, 1, 1]

        public init() {}
    }

    public init() {
        // Initialize default pose
        resetToTPose()
    }

    public func resetToTPose() {
        bones.removeAll()
        // T-pose is the default bind pose for VRM
    }

    public func setAPose() {
        // A-pose with arms at 45 degrees
        bones[.leftUpperArm] = BoneTransform()
        bones[.leftUpperArm]?.rotation = simd_quatf(angle: -.pi/4, axis: [0, 0, 1])

        bones[.rightUpperArm] = BoneTransform()
        bones[.rightUpperArm]?.rotation = simd_quatf(angle: .pi/4, axis: [0, 0, 1])
    }

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

public class VRMAnimationPresets {

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
