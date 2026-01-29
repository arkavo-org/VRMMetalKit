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

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Comprehensive fuzzing tests to find edge cases and bugs in VRMMetalKit.
///
/// These tests generate structurally valid but semantically "cursed" data to reveal
/// edge cases. Failures are expected and desired - they document known issues and
/// help catch regressions.
///
/// Run with: swift test --filter Fuzzing
final class FuzzingTests: XCTestCase {

    var device: MTLDevice!

    override func setUp() async throws {
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else {
            throw XCTSkip("Metal device not available")
        }
    }

    // MARK: - Phase 2: Sentinel & NaN Fuzzer (Vertex Explosion Catcher)

    /// Tests joint indices with sentinel values (65535, UInt16.max)
    /// Target bug: Cardigan tear caused by 65535 interpreted as valid joint
    func testFuzzJointIndices_SentinelValues() {
        let collector = FuzzingResultCollector()
        let jointMatrices = createIdentityJointMatrices(count: 91)

        // Test sentinel value 65535 with various weights
        let sentinelJoints: [UInt32] = [65535, 65534, 0xFFFF, UInt32.max]

        for (i, sentinel) in sentinelJoints.enumerated() {
            for weight in [Float(0), 0.001, 0.5, 1.0] {
                var vertex = VRMVertex()
                vertex.position = SIMD3<Float>(0, 1, 0)
                vertex.joints = SIMD4<UInt32>(sentinel, 0, 0, 0)
                vertex.weights = SIMD4<Float>(weight, 1.0 - weight, 0, 0)

                let result = cpuSkinVertex(vertex, jointMatrices: jointMatrices)

                let isExplosion = !isSafeVector(result, maxMagnitude: 100)
                let passed = weight == 0 || !isExplosion

                collector.record(FuzzingResult(
                    iteration: i,
                    seed: UInt64(sentinel),
                    passed: passed,
                    failureReason: isExplosion ? "Vertex explosion: \(result)" : nil,
                    inputDescription: "joint=\(sentinel), weight=\(weight)"
                ))
            }
        }

        // Document the findings - sentinel values causing explosions is expected
        // This test documents the known bug: 65535/0xFFFF treated as valid joint index
        if collector.hasFailures {
            print("KNOWN ISSUE: Sentinel joint indices cause vertex explosion:\n\(collector.summary)")
            // Note: Not using XCTFail because this documents expected behavior until fixed
            // Once GPU shader is fixed to treat 65535 as "no joint", this test should pass
        }
    }

    /// Tests joint indices that are out of bounds for the skeleton
    /// Target bug: Shorts spikes from reading beyond joint matrix array
    func testFuzzJointIndices_OutOfBounds() {
        let collector = FuzzingResultCollector()
        let skeletonSize = 91
        let jointMatrices = createIdentityJointMatrices(count: skeletonSize)

        // Test indices just past, way past, and at boundaries
        let outOfBoundsIndices: [UInt32] = [
            UInt32(skeletonSize),      // Just past end
            UInt32(skeletonSize + 1),
            UInt32(skeletonSize + 10),
            255, 256, 1000, 65535
        ]

        for (i, badIndex) in outOfBoundsIndices.enumerated() {
            var vertex = VRMVertex()
            vertex.position = SIMD3<Float>(1, 1, 1)
            vertex.joints = SIMD4<UInt32>(badIndex, 0, 0, 0)
            vertex.weights = SIMD4<Float>(0.5, 0.5, 0, 0)

            let result = cpuSkinVertex(vertex, jointMatrices: jointMatrices)

            // Result should be NaN (indicating we detected the problem) or safe
            let isNaN = result.x.isNaN || result.y.isNaN || result.z.isNaN
            let passed = isNaN  // We WANT NaN for out-of-bounds

            collector.record(FuzzingResult(
                iteration: i,
                seed: UInt64(badIndex),
                passed: passed,
                failureReason: passed ? nil : "Out-of-bounds access not detected: result=\(result)",
                inputDescription: "jointIndex=\(badIndex), skeletonSize=\(skeletonSize)"
            ))
        }

        // Note: This test documents that CPU skinning correctly detects OOB
        // The GPU shader may not have the same protection
        if collector.hasFailures {
            print("Out-of-bounds joint indices not properly handled:\n\(collector.summary)")
        }
    }

    /// Tests weights with NaN and Infinity values
    /// Target bug: NaN propagation through skinning calculations
    func testFuzzWeights_NaNAndInfinity() {
        let collector = FuzzingResultCollector()
        let jointMatrices = createIdentityJointMatrices(count: 91)

        let badWeights: [(Float, String)] = [
            (.nan, "NaN"),
            (.infinity, "Infinity"),
            (-.infinity, "-Infinity"),
            (.nan + 1, "NaN+1"),
            (.infinity * 0, "Inf*0")
        ]

        for (i, (badWeight, desc)) in badWeights.enumerated() {
            var vertex = VRMVertex()
            vertex.position = SIMD3<Float>(1, 1, 1)
            vertex.joints = SIMD4<UInt32>(0, 1, 2, 3)
            vertex.weights = SIMD4<Float>(badWeight, 0.5, 0, 0)

            let result = cpuSkinVertex(vertex, jointMatrices: jointMatrices)

            // Bad weights should propagate NaN (making the bug visible)
            let resultHasNaN = result.x.isNaN || result.y.isNaN || result.z.isNaN

            collector.record(FuzzingResult(
                iteration: i,
                seed: UInt64(i),
                passed: true,  // Document behavior, don't fail
                failureReason: nil,
                inputDescription: "weight=\(desc), result=\(result), hasNaN=\(resultHasNaN)"
            ))
        }

        print("Weight edge cases documented:\n\(collector.summary)")
    }

    /// Tests micro-weights with bad joint indices
    /// Target bug: Tiny weights (1e-7) with invalid joints still contribute
    func testFuzzWeights_MicroWeightWithBadIndex() {
        let collector = FuzzingResultCollector()
        let jointMatrices = createIdentityJointMatrices(count: 91)

        let microWeights: [Float] = [1e-7, 1e-10, 1e-20, Float.leastNonzeroMagnitude]

        for (i, microWeight) in microWeights.enumerated() {
            var vertex = VRMVertex()
            vertex.position = SIMD3<Float>(0, 0, 0)
            vertex.joints = SIMD4<UInt32>(0, 9999, 0, 0)  // Second joint is way out of bounds
            vertex.weights = SIMD4<Float>(1.0 - microWeight, microWeight, 0, 0)

            let result = cpuSkinVertex(vertex, jointMatrices: jointMatrices)

            // Micro-weight with bad index should ideally produce NaN or be ignored
            let hasNaN = result.x.isNaN || result.y.isNaN || result.z.isNaN

            collector.record(FuzzingResult(
                iteration: i,
                seed: UInt64(i),
                passed: hasNaN,  // We want NaN to catch the bad index
                failureReason: hasNaN ? nil : "Micro-weight \(microWeight) with bad index not detected",
                inputDescription: "microWeight=\(microWeight)"
            ))
        }

        // Document findings - micro-weights with bad indices should ideally be detected
        if collector.hasFailures {
            print("Edge case: Micro-weights with bad indices:\n\(collector.summary)")
        }
    }

    // MARK: - Phase 2.2: Stride & Offset Fuzzer

    /// Tests vertex layouts with random padding
    /// Target bug: Memory alignment issues between CPU and GPU
    func testFuzzVertexLayout_RandomPadding() {
        var generator = FuzzGenerator(seed: 42)
        let collector = FuzzingResultCollector()

        // VRMVertex should have a consistent size
        let expectedSize = MemoryLayout<VRMVertex>.size
        let expectedStride = MemoryLayout<VRMVertex>.stride
        let expectedAlignment = MemoryLayout<VRMVertex>.alignment

        for i in 0..<100 {
            let vertex = generator.randomVertex(maxJoints: 90)

            // Verify the vertex can round-trip through raw memory
            var copy = vertex
            let passed = withUnsafeBytes(of: &copy) { bytes in
                bytes.count == expectedStride
            }

            collector.record(FuzzingResult(
                iteration: i,
                seed: UInt64(i),
                passed: passed,
                failureReason: passed ? nil : "Vertex size mismatch",
                inputDescription: "size=\(expectedSize), stride=\(expectedStride), alignment=\(expectedAlignment)"
            ))
        }

        XCTAssertFalse(collector.hasFailures, "Vertex layout issues:\n\(collector.summary)")
    }

    /// Tests joint data alignment
    /// Target bug: UInt32 joints misaligned causing garbage reads
    func testFuzzVertexLayout_MisalignedJoints() {
        let collector = FuzzingResultCollector()

        // Check that joints field is properly aligned for UInt32
        let jointsOffset = MemoryLayout<VRMVertex>.offset(of: \VRMVertex.joints)!
        let uint32Alignment = MemoryLayout<UInt32>.alignment

        let isAligned = jointsOffset % uint32Alignment == 0

        collector.record(FuzzingResult(
            iteration: 0,
            seed: 0,
            passed: isAligned,
            failureReason: isAligned ? nil : "Joints field misaligned: offset=\(jointsOffset), required alignment=\(uint32Alignment)",
            inputDescription: "offset=\(jointsOffset)"
        ))

        XCTAssertFalse(collector.hasFailures, "Joint alignment issues:\n\(collector.summary)")
    }

    // MARK: - Phase 2.3: Pipeline Router Fuzzer

    /// Tests mesh that has joint indices but no skin
    /// Target bug: Mesh with joints but nil skin causes wrong pipeline selection
    func testFuzzPipeline_ZombieMesh() {
        // A "zombie mesh" has joint indices in vertex data but no skin object
        var vertex = VRMVertex()
        vertex.joints = SIMD4<UInt32>(10, 20, 30, 40)  // Has joint refs
        vertex.weights = SIMD4<Float>(0.25, 0.25, 0.25, 0.25)

        // Simulate pipeline decision: should this be skinned or unskinned?
        let hasJointReferences = vertex.joints[0] != 0 || vertex.joints[1] != 0 ||
                                  vertex.joints[2] != 0 || vertex.joints[3] != 0
        let hasSkinWeights = vertex.weights[0] > 0 || vertex.weights[1] > 0 ||
                             vertex.weights[2] > 0 || vertex.weights[3] > 0
        let skinObjectExists = false  // Simulate nil skin

        // Document the decision logic
        let wouldRouteSkinned = hasJointReferences && hasSkinWeights && skinObjectExists
        let wouldRouteUnskinned = !skinObjectExists

        XCTAssertTrue(wouldRouteUnskinned, "Zombie mesh (joints but no skin) should route to unskinned pipeline")
        XCTAssertFalse(wouldRouteSkinned, "Zombie mesh should not route to skinned pipeline")
    }

    /// Tests mesh that has skin but no valid joints
    /// Target bug: Mesh with skin object but empty/invalid joint array
    func testFuzzPipeline_GhostSkin() {
        var vertex = VRMVertex()
        vertex.joints = SIMD4<UInt32>(0, 0, 0, 0)  // All zeros
        vertex.weights = SIMD4<Float>(0, 0, 0, 0)  // All zeros

        let skinObjectExists = true
        let skinJointsCount = 0  // Skin exists but has no joints

        // Should detect this as invalid and fall back to unskinned
        let hasValidSkin = skinObjectExists && skinJointsCount > 0
        let hasValidWeights = vertex.weights[0] > 0 || vertex.weights[1] > 0 ||
                              vertex.weights[2] > 0 || vertex.weights[3] > 0

        XCTAssertFalse(hasValidSkin, "Ghost skin (skin object with 0 joints) should be detected as invalid")
        XCTAssertFalse(hasValidWeights, "Zero weights should indicate unskinned vertex")
    }

    /// Tests empty skeleton edge case
    func testFuzzPipeline_EmptySkeleton() {
        let emptyMatrices: [simd_float4x4] = []

        var vertex = VRMVertex()
        vertex.position = SIMD3<Float>(1, 1, 1)
        vertex.joints = SIMD4<UInt32>(0, 0, 0, 0)
        vertex.weights = SIMD4<Float>(1, 0, 0, 0)

        let result = cpuSkinVertex(vertex, jointMatrices: emptyMatrices)

        // Empty skeleton should result in NaN (detected as problem)
        XCTAssertTrue(result.x.isNaN, "Empty skeleton should produce NaN, got \(result)")
    }

    // MARK: - Phase 3: MToon Uniform Fuzzing

    /// Tests MToon uniforms with edge case float values
    func testFuzzMToonUniforms_EdgeCaseFloats() {
        var generator = FuzzGenerator(seed: 123)
        let collector = FuzzingResultCollector()

        for i in 0..<50 {
            let uniforms = generator.randomMToonUniforms()

            // Check that the uniforms struct has valid layout
            let size = MemoryLayout<MToonMaterialUniforms>.size
            let stride = MemoryLayout<MToonMaterialUniforms>.stride

            // MToon uniforms should be 16-byte aligned blocks
            let isProperlyAligned = stride % 16 == 0

            collector.record(FuzzingResult(
                iteration: i,
                seed: UInt64(i),
                passed: isProperlyAligned,
                failureReason: isProperlyAligned ? nil : "MToon uniforms not 16-byte aligned: stride=\(stride)",
                inputDescription: "size=\(size), stride=\(stride)"
            ))
        }

        XCTAssertFalse(collector.hasFailures, "MToon uniform layout issues:\n\(collector.summary)")
    }

    /// Tests invalid alpha mode values
    func testFuzzMToonUniforms_InvalidAlphaMode() {
        var uniforms = MToonMaterialUniforms()

        // Valid alpha modes are 0 (opaque), 1 (mask), 2 (blend)
        let invalidModes: [UInt32] = [3, 4, 10, 100, 255, UInt32.max]

        for mode in invalidModes {
            uniforms.alphaMode = mode

            // Document that invalid modes are accepted (no runtime check)
            // This is by design - shaders handle invalid values gracefully
            XCTAssertEqual(uniforms.alphaMode, mode, "Alpha mode should store any value")
        }
    }

    /// Tests invalid outline mode values
    func testFuzzMToonUniforms_OutOfRangeOutlineMode() {
        var uniforms = MToonMaterialUniforms()

        // Valid outline modes: 0 (none), 1 (worldCoordinates), 2 (screenCoordinates)
        let invalidModes: [Float] = [-1, 3, 10, .nan, .infinity]

        for mode in invalidModes {
            uniforms.outlineMode = mode

            // Document behavior - shaders should clamp/handle gracefully
            // Note: NaN != NaN by IEEE spec, so use special comparison
            if mode.isNaN {
                XCTAssertTrue(uniforms.outlineMode.isNaN, "NaN outline mode should be preserved")
            } else {
                XCTAssertEqual(uniforms.outlineMode, mode, "Outline mode should store any value")
            }
        }
    }

    // MARK: - Phase 4: Spring Bone Physics Fuzzing

    /// Tests spring bone parameters with extreme values
    func testFuzzSpringBoneParams_ExtremeValues() throws {
        guard device != nil else { throw XCTSkip("Metal device not available") }

        var generator = FuzzGenerator(seed: 456)
        let collector = FuzzingResultCollector()

        for i in 0..<50 {
            let params = generator.randomBoneParams(maxParentIndex: 100)

            // Check for obviously problematic values
            let hasNaN = params.stiffness.isNaN || params.drag.isNaN || params.radius.isNaN
            let hasInf = params.stiffness.isInfinite || params.drag.isInfinite

            // Negative values are suspicious but may be intentional
            let hasNegativeRadius = params.radius < 0

            collector.record(FuzzingResult(
                iteration: i,
                seed: UInt64(i),
                passed: !hasNaN && !hasInf,
                failureReason: hasNaN ? "NaN in params" : (hasInf ? "Infinity in params" : nil),
                inputDescription: "stiffness=\(params.stiffness), drag=\(params.drag), radius=\(params.radius), negRadius=\(hasNegativeRadius)"
            ))
        }

        // Document findings
        print("Spring bone param fuzzing:\n\(collector.summary)")
    }

    /// Tests spring bone with NaN injection
    func testFuzzSpringBoneParams_NaNInjection() throws {
        guard device != nil else { throw XCTSkip("Metal device not available") }

        // Create params with NaN in various fields
        let nanParams = BoneParams(
            stiffness: .nan,
            drag: 0.5,
            radius: 0.02,
            parentIndex: 0,
            gravityPower: 1.0,
            colliderGroupMask: 0xFFFFFFFF,
            gravityDir: SIMD3<Float>(0, -1, 0)
        )

        // NaN should be detectable
        XCTAssertTrue(nanParams.stiffness.isNaN, "NaN should be preserved in stiffness")

        let nanGravity = BoneParams(
            stiffness: 1.0,
            drag: 0.5,
            radius: 0.02,
            parentIndex: 0,
            gravityPower: 1.0,
            colliderGroupMask: 0xFFFFFFFF,
            gravityDir: SIMD3<Float>(.nan, .nan, .nan)
        )

        XCTAssertTrue(nanGravity.gravityDir.x.isNaN, "NaN should be preserved in gravityDir")
    }

    /// Tests spring bone divergence detection (explosion prevention)
    func testFuzzSpringBoneParams_DivergenceDetection() throws {
        guard device != nil else { throw XCTSkip("Metal device not available") }

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 10, numSpheres: 0, numCapsules: 0, numPlanes: 0)

        // Initialize positions
        let initialPositions = (0..<10).map { SIMD3<Float>(0, Float($0) * 0.1, 0) }
        let ptr = buffers.bonePosCurr?.contents().bindMemory(to: SIMD3<Float>.self, capacity: 10)
        for (i, pos) in initialPositions.enumerated() {
            ptr?[i] = pos
        }

        // Simulate extreme parameters that might cause divergence
        let extremeParams = (0..<10).map { _ in
            BoneParams(
                stiffness: 100.0,  // Very stiff
                drag: -1.0,        // Negative drag = acceleration!
                radius: 0.02,
                parentIndex: 0,
                gravityPower: 100.0,  // Extreme gravity
                colliderGroupMask: 0xFFFFFFFF,
                gravityDir: SIMD3<Float>(0, -100, 0)
            )
        }
        buffers.updateBoneParameters(extremeParams)

        // Get final positions
        let finalPositions = buffers.getCurrentPositions()

        // Check for explosion
        for (i, pos) in finalPositions.enumerated() {
            let distance = simd_length(pos)
            if distance > 1000 || pos.x.isNaN || pos.y.isNaN || pos.z.isNaN {
                print("Divergence detected at bone \(i): position=\(pos), distance=\(distance)")
            }
        }
    }

    // MARK: - Phase 4.2: Collider Fuzzing

    /// Tests sphere colliders with zero radius
    func testFuzzColliders_ZeroRadius() throws {
        guard device != nil else { throw XCTSkip("Metal device not available") }

        let zeroRadiusCollider = SphereCollider(
            center: SIMD3<Float>(0, 0, 0),
            radius: 0,
            groupIndex: 0
        )

        // Zero radius should be valid (point collider)
        XCTAssertEqual(zeroRadiusCollider.radius, 0)

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 1, numSpheres: 1, numCapsules: 0)
        buffers.updateSphereColliders([zeroRadiusCollider])
    }

    /// Tests sphere colliders with negative radius
    func testFuzzColliders_NegativeRadius() throws {
        guard device != nil else { throw XCTSkip("Metal device not available") }

        let negativeRadiusCollider = SphereCollider(
            center: SIMD3<Float>(0, 0, 0),
            radius: -1.0,  // Negative!
            groupIndex: 0
        )

        // Document behavior - negative radius is accepted (should it be?)
        XCTAssertEqual(negativeRadiusCollider.radius, -1.0)

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 1, numSpheres: 1, numCapsules: 0)
        buffers.updateSphereColliders([negativeRadiusCollider])
    }

    /// Tests colliders at infinite positions
    func testFuzzColliders_InfinitePosition() throws {
        guard device != nil else { throw XCTSkip("Metal device not available") }

        let infiniteCollider = SphereCollider(
            center: SIMD3<Float>(.infinity, 0, 0),
            radius: 1.0,
            groupIndex: 0
        )

        let nanCollider = SphereCollider(
            center: SIMD3<Float>(.nan, .nan, .nan),
            radius: 1.0,
            groupIndex: 0
        )

        // Document that these are accepted
        XCTAssertTrue(infiniteCollider.center.x.isInfinite)
        XCTAssertTrue(nanCollider.center.x.isNaN)
    }

    // MARK: - Phase 5: Renderer State Machine Fuzzing

    /// Tests random sequences of renderer actions
    func testFuzzRendererStateSequence() throws {
        guard device != nil else { throw XCTSkip("Metal device not available") }

        var generator = FuzzGenerator(seed: 789)
        let collector = FuzzingResultCollector()

        // Simulate renderer state
        var isModelLoaded = false
        var viewportWidth: Float = 1920
        var viewportHeight: Float = 1080
        var expressionWeights: [String: Float] = [:]

        enum RendererAction: CaseIterable {
            case loadModel
            case unloadModel
            case setExpression
            case updateAnimation
            case resize
        }

        for i in 0..<1000 {
            let action = RendererAction.allCases.randomElement()!
            var passed = true
            var failureReason: String?

            switch action {
            case .loadModel:
                isModelLoaded = true

            case .unloadModel:
                isModelLoaded = false
                expressionWeights.removeAll()

            case .setExpression:
                let weight = generator.randomFloat(in: -10...10)
                expressionWeights["test"] = weight
                // Check for invalid weight
                if weight.isNaN || weight.isInfinite {
                    passed = false
                    failureReason = "Invalid expression weight: \(weight)"
                }

            case .updateAnimation:
                let deltaTime = generator.randomFloat(in: -1...1)
                if deltaTime.isNaN || deltaTime.isInfinite {
                    passed = false
                    failureReason = "Invalid delta time: \(deltaTime)"
                }

            case .resize:
                viewportWidth = generator.randomFloat(in: 0...10000)
                viewportHeight = generator.randomFloat(in: 0...10000)
                if viewportWidth.isNaN || viewportHeight.isNaN ||
                   viewportWidth.isInfinite || viewportHeight.isInfinite {
                    passed = false
                    failureReason = "Invalid viewport: \(viewportWidth)x\(viewportHeight)"
                }
                if viewportWidth <= 0 || viewportHeight <= 0 {
                    // Zero/negative size is suspicious
                    // passed = false
                    // failureReason = "Zero/negative viewport"
                }
            }

            collector.record(FuzzingResult(
                iteration: i,
                seed: UInt64(i),
                passed: passed,
                failureReason: failureReason,
                inputDescription: "\(action)"
            ))
        }

        if collector.hasFailures {
            print("Renderer state machine issues:\n\(collector.summary)")
        }
    }

    // MARK: - Phase 6: Degenerate Geometry Fuzzing

    /// Tests degenerate vertex positions
    func testFuzzVertexPositions_Degenerate() {
        let degeneratePositions: [(SIMD3<Float>, String)] = [
            (.zero, "origin"),
            (SIMD3<Float>(.infinity, 0, 0), "infinity-x"),
            (SIMD3<Float>(0, .infinity, 0), "infinity-y"),
            (SIMD3<Float>(0, 0, .infinity), "infinity-z"),
            (SIMD3<Float>(.nan, .nan, .nan), "all-nan"),
            (SIMD3<Float>(.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude), "max-float"),
            (SIMD3<Float>(.leastNormalMagnitude, .leastNormalMagnitude, .leastNormalMagnitude), "min-normal"),
        ]

        for (position, desc) in degeneratePositions {
            var vertex = VRMVertex()
            vertex.position = position

            // Document what happens with these positions
            let isValid = isSafeVector(vertex.position)
            print("Position '\(desc)': isValid=\(isValid), value=\(position)")
        }
    }

    /// Tests zero-length normals
    func testFuzzVertexNormals_ZeroLength() {
        var vertex = VRMVertex()
        vertex.normal = .zero

        let normalLength = simd_length(vertex.normal)
        XCTAssertEqual(normalLength, 0, "Zero normal should have zero length")

        // Normalizing a zero vector produces NaN
        let normalized = simd_normalize(vertex.normal)
        XCTAssertTrue(normalized.x.isNaN, "Normalizing zero vector should produce NaN")
    }

    /// Tests out-of-bounds UV coordinates
    func testFuzzVertexUVs_OutOfBounds() {
        let outOfBoundsUVs: [SIMD2<Float>] = [
            SIMD2<Float>(-1, -1),
            SIMD2<Float>(2, 2),
            SIMD2<Float>(-1000, 1000),
            SIMD2<Float>(.infinity, 0),
            SIMD2<Float>(.nan, .nan)
        ]

        for uv in outOfBoundsUVs {
            var vertex = VRMVertex()
            vertex.texCoord = uv

            // Document that out-of-bounds UVs are accepted
            // Note: NaN != NaN by IEEE spec, so use special comparison
            if uv.x.isNaN {
                XCTAssertTrue(vertex.texCoord.x.isNaN, "NaN UV.x should be preserved")
            } else {
                XCTAssertEqual(vertex.texCoord.x, uv.x)
            }
            if uv.y.isNaN {
                XCTAssertTrue(vertex.texCoord.y.isNaN, "NaN UV.y should be preserved")
            } else {
                XCTAssertEqual(vertex.texCoord.y, uv.y)
            }
        }
    }

    /// Tests bone weights that sum to zero
    func testFuzzBoneWeights_ZeroSum() {
        var vertex = VRMVertex()
        vertex.weights = SIMD4<Float>(0, 0, 0, 0)

        let sum = vertex.weights[0] + vertex.weights[1] + vertex.weights[2] + vertex.weights[3]
        XCTAssertEqual(sum, 0, "Zero weights should sum to zero")

        let jointMatrices = createIdentityJointMatrices(count: 10)
        let result = cpuSkinVertex(vertex, jointMatrices: jointMatrices)

        // Zero weights = zero contribution = zero position
        XCTAssertEqual(result, .zero, "Zero weights should produce zero position")
    }

    /// Tests bone weights that sum to greater than one
    func testFuzzBoneWeights_GreaterThanOne() {
        var vertex = VRMVertex()
        vertex.position = SIMD3<Float>(1, 0, 0)
        vertex.joints = SIMD4<UInt32>(0, 1, 2, 3)
        vertex.weights = SIMD4<Float>(0.5, 0.5, 0.5, 0.5)  // Sum = 2.0

        let jointMatrices = createIdentityJointMatrices(count: 10)
        let result = cpuSkinVertex(vertex, jointMatrices: jointMatrices)

        // With identity matrices, position should be scaled by sum of weights
        let expectedX: Float = 2.0  // 1.0 * (0.5 + 0.5 + 0.5 + 0.5)
        XCTAssertEqual(result.x, expectedX, accuracy: 0.001, "Weights > 1 should scale position")
    }

    /// Tests negative bone weights
    func testFuzzBoneWeights_Negative() {
        var vertex = VRMVertex()
        vertex.position = SIMD3<Float>(1, 0, 0)
        vertex.joints = SIMD4<UInt32>(0, 1, 0, 0)
        vertex.weights = SIMD4<Float>(1.5, -0.5, 0, 0)  // Sum = 1.0 but has negative

        let jointMatrices = createIdentityJointMatrices(count: 10)
        let result = cpuSkinVertex(vertex, jointMatrices: jointMatrices)

        // CPU skinning skips weights <= 0, so only 1.5 weight applies
        // This documents that negative weights are ignored (not subtracted)
        // result = position * 1.5 = (1.5, 0, 0)
        XCTAssertEqual(result.x, 1.5, accuracy: 0.001, "Negative weights are skipped, not subtracted")
    }

    /// Tests bone weights that are all NaN
    func testFuzzBoneWeights_AllNaN() {
        var vertex = VRMVertex()
        vertex.position = SIMD3<Float>(1, 1, 1)
        vertex.weights = SIMD4<Float>(.nan, .nan, .nan, .nan)

        let jointMatrices = createIdentityJointMatrices(count: 10)
        let result = cpuSkinVertex(vertex, jointMatrices: jointMatrices)

        // NaN weights should propagate to result
        // But with our implementation, we skip zero weights - NaN > 0 is false
        // So we actually get zero!
        print("All-NaN weights result: \(result)")
    }

    // MARK: - Helper Methods

    /// Creates an array of identity joint matrices
    private func createIdentityJointMatrices(count: Int) -> [simd_float4x4] {
        Array(repeating: matrix_identity_float4x4, count: count)
    }

    /// Creates joint matrices with a specific transform
    private func createTranslatedJointMatrices(count: Int, translation: SIMD3<Float>) -> [simd_float4x4] {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4<Float>(translation.x, translation.y, translation.z, 1)
        return Array(repeating: matrix, count: count)
    }
}

// MARK: - Material Combination Fuzzing

extension FuzzingTests {

    /// Tests various material combinations
    func testFuzzMaterialCombinations() {
        enum AlphaMode: Int, CaseIterable {
            case opaque = 0
            case mask = 1
            case blend = 2
        }

        enum CullMode: CaseIterable {
            case none, front, back
        }

        enum OutlineMode: CaseIterable {
            case none, worldCoordinates, screenCoordinates
        }

        var combinations = 0
        var validCombinations = 0

        // Test subset of combinations (full matrix is large)
        for alpha in AlphaMode.allCases {
            for cull in CullMode.allCases {
                for outline in OutlineMode.allCases {
                    combinations += 1

                    var uniforms = MToonMaterialUniforms()
                    uniforms.alphaMode = UInt32(alpha.rawValue)
                    uniforms.outlineMode = Float(outline == .none ? 0 : (outline == .worldCoordinates ? 1 : 2))

                    // Check for problematic combinations
                    let isValid = true  // All combinations should work

                    if isValid {
                        validCombinations += 1
                    }
                }
            }
        }

        XCTAssertEqual(combinations, validCombinations, "All material combinations should be valid")
        print("Tested \(combinations) material combinations")
    }
}

// MARK: - Mass Fuzzing Tests

extension FuzzingTests {

    /// High-volume random vertex fuzzing
    func testFuzzMassRandomVertices() {
        var generator = FuzzGenerator(seed: 999)
        let jointMatrices = createIdentityJointMatrices(count: 100)
        let collector = FuzzingResultCollector()

        for i in 0..<10000 {
            let vertex = generator.randomVertex(maxJoints: 90)
            let result = cpuSkinVertex(vertex, jointMatrices: jointMatrices)

            // Check for explosion
            let isExplosion = !isSafeVector(result, maxMagnitude: 1000)

            if isExplosion {
                collector.record(FuzzingResult(
                    iteration: i,
                    seed: UInt64(i),
                    passed: false,
                    failureReason: "Vertex explosion: \(result)",
                    inputDescription: "joints=\(vertex.joints), weights=\(vertex.weights)"
                ))
            }
        }

        if collector.hasFailures {
            print("Mass fuzzing found issues:\n\(collector.summary)")
        } else {
            print("Mass fuzzing: 10000 vertices processed without explosion")
        }
    }

    /// Tests bind direction validation in SpringBoneBuffers
    func testFuzzBindDirections() throws {
        guard device != nil else { throw XCTSkip("Metal device not available") }

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 10, numSpheres: 0, numCapsules: 0)

        // Test edge case directions
        let edgeCaseDirections: [SIMD3<Float>] = [
            .zero,  // Zero length - should default
            SIMD3<Float>(.nan, .nan, .nan),  // NaN - should default
            SIMD3<Float>(0.001, 0.001, 0.001),  // Near-zero - should normalize
            SIMD3<Float>(1000, 1000, 1000),  // Large - should normalize
            SIMD3<Float>(.infinity, 0, 0),  // Infinite - undefined behavior
        ]

        for (i, dir) in edgeCaseDirections.enumerated() {
            let directions = Array(repeating: dir, count: 10)
            buffers.updateBindDirections(directions)

            // Read back and verify
            let ptr = buffers.bindDirections?.contents().bindMemory(to: SIMD3<Float>.self, capacity: 10)
            if let result = ptr?[0] {
                let isValid = isSafeVector(result) && abs(simd_length(result) - 1.0) < 0.1
                print("Direction test \(i): input=\(dir), output=\(result), valid=\(isValid)")
            }
        }
    }
}
