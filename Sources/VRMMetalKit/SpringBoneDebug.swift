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


import Metal
import QuartzCore  // For CACurrentMediaTime
import simd

struct SpringBoneTestScenarios {
    let computeSystem: SpringBoneComputeSystem
    let skinningSystem: SpringBoneSkinningSystem

    init(device: MTLDevice) throws {
        self.computeSystem = try SpringBoneComputeSystem(device: device)
        self.skinningSystem = SpringBoneSkinningSystem(device: device)
    }

    func runAllTests(model: VRMModel) {
        vrmLog("Running SpringBone GPU tests...")

        testDeterminism(model: model)
        testGravityFlip(model: model)
        testWindEffects(model: model)
        testColliderResponse(model: model)
        testPerformance(model: model)

        vrmLog("All SpringBone tests completed!")
    }

    func testDeterminism(model: VRMModel) {
        vrmLog("🧪 Test 1: Determinism Validation")

        // Reset to initial state
        resetSpringBoneState(model: model)

        // Run simulation for fixed number of steps
        for _ in 0..<100 {
            computeSystem.update(model: model, deltaTime: 1.0 / 60.0)
        }

        let positions1 = model.springBoneBuffers?.getCurrentPositions() ?? []

        // Reset and run again
        resetSpringBoneState(model: model)

        for _ in 0..<100 {
            computeSystem.update(model: model, deltaTime: 1.0 / 60.0)
        }

        let positions2 = model.springBoneBuffers?.getCurrentPositions() ?? []

        // Compare results
        var maxError: Float = 0
        for i in 0..<min(positions1.count, positions2.count) {
            let error = simd_distance(positions1[i], positions2[i])
            maxError = max(maxError, error)
        }

        if maxError < 1e-6 {
            vrmLog("✅ Deterministic: Max error = \(maxError) (PASS)")
        } else {
            vrmLog("❌ Non-deterministic: Max error = \(maxError) (FAIL)")
        }
    }

    func testGravityFlip(model: VRMModel) {
        vrmLog("🧪 Test 2: Gravity Flip Response")

        resetSpringBoneState(model: model)

        // Run with normal gravity
        var params = model.springBoneGlobalParams!
        params.gravity = SIMD3<Float>(0, -9.8, 0)
        model.springBoneGlobalParams = params

        for _ in 0..<50 {
            computeSystem.update(model: model, deltaTime: 1.0 / 60.0)
        }

        let downPositions = model.springBoneBuffers?.getCurrentPositions() ?? []

        // Flip gravity
        resetSpringBoneState(model: model)
        params.gravity = SIMD3<Float>(0, 9.8, 0) // Upward gravity
        model.springBoneGlobalParams = params

        for _ in 0..<50 {
            computeSystem.update(model: model, deltaTime: 1.0 / 60.0)
        }

        let upPositions = model.springBoneBuffers?.getCurrentPositions() ?? []

        // Check that bones move in opposite directions
        var passed = true
        for i in 0..<min(downPositions.count, upPositions.count) {
            if downPositions[i].y > upPositions[i].y {
                // Should be lower with normal gravity
                passed = false
                break
            }
        }

        vrmLog(passed ? "✅ Gravity flip response: PASS" : "❌ Gravity flip response: FAIL")
    }

    func testWindEffects(model: VRMModel) {
        vrmLog("🧪 Test 3: Wind Effects")

        resetSpringBoneState(model: model)

        // Test with wind
        var params = model.springBoneGlobalParams!
        params.windAmplitude = 5.0
        params.windDirection = SIMD3<Float>(1, 0, 0) // Wind from left
        model.springBoneGlobalParams = params

        for _ in 0..<100 {
            computeSystem.update(model: model, deltaTime: 1.0 / 60.0)
        }

        let windPositions = model.springBoneBuffers?.getCurrentPositions() ?? []

        // Test without wind
        resetSpringBoneState(model: model)
        params.windAmplitude = 0.0
        model.springBoneGlobalParams = params

        for _ in 0..<100 {
            computeSystem.update(model: model, deltaTime: 1.0 / 60.0)
        }

        let noWindPositions = model.springBoneBuffers?.getCurrentPositions() ?? []

        // Check wind effect
        var windEffectDetected = false
        for i in 0..<min(windPositions.count, noWindPositions.count) {
            if abs(windPositions[i].x - noWindPositions[i].x) > 0.1 {
                windEffectDetected = true
                break
            }
        }

        vrmLog(windEffectDetected ? "✅ Wind effects: PASS" : "❌ Wind effects: FAIL")
    }

    func testColliderResponse(model: VRMModel) {
        vrmLog("🧪 Test 4: Collider Response")

        // This test requires manual verification through visualization
        // We'll just check that the system runs without crashing

        resetSpringBoneState(model: model)

        // Add a test collider near the bones
        if var params = model.springBoneGlobalParams {
            params.numSpheres += 1
            model.springBoneGlobalParams = params

            // Add a sphere collider
            let testCollider = SphereCollider(center: SIMD3<Float>(0, 1, 0), radius: 0.2)
            model.springBoneBuffers?.updateSphereColliders([testCollider])
        }

        // Run simulation
        for _ in 0..<50 {
            computeSystem.update(model: model, deltaTime: 1.0 / 60.0)
        }

        vrmLog("⚠️  Collider test: Manual visualization required")
    }

    func testPerformance(model: VRMModel) {
        vrmLog("🧪 Test 5: Performance Benchmark")

        resetSpringBoneState(model: model)

        let startTime = CACurrentMediaTime()
        let frameCount = 100

        for _ in 0..<frameCount {
            computeSystem.update(model: model, deltaTime: 1.0 / 60.0)
        }

        let totalTime = CACurrentMediaTime() - startTime
        let avgFrameTime = totalTime / Double(frameCount) * 1000 // ms per frame

        let numBones = model.springBoneBuffers?.numBones ?? 0
        vrmLog("📊 Performance: \(numBones) bones, \(avgFrameTime) ms/frame")

        if avgFrameTime < 1.0 {
            vrmLog("✅ Performance: PASS (<1ms/frame)")
        } else {
            vrmLog("⚠️  Performance: \(avgFrameTime) ms/frame (monitor)")
        }
    }

    private func resetSpringBoneState(model: VRMModel) {
        // Re-populate initial bone data
        try? computeSystem.populateSpringBoneData(model: model)

        // Reset global params
        if var params = model.springBoneGlobalParams {
            params.windPhase = 0
            model.springBoneGlobalParams = params
        }
    }

    func enableDebugVisualization(model: VRMModel, enabled: Bool) {
        // This would connect to your renderer's debug system
        vrmLog("Debug visualization: \(enabled ? "ENABLED" : "DISABLED")")
    }

    func setWindParameters(model: VRMModel, amplitude: Float, frequency: Float, direction: SIMD3<Float>) {
        if var params = model.springBoneGlobalParams {
            params.windAmplitude = amplitude
            params.windFrequency = frequency
            params.windDirection = simd_normalize(direction)
            model.springBoneGlobalParams = params
        }
    }

    func setGravity(model: VRMModel, gravity: SIMD3<Float>) {
        if var params = model.springBoneGlobalParams {
            params.gravity = gravity
            model.springBoneGlobalParams = params
        }
    }

    func setSubsteps(model: VRMModel, substeps: UInt32) {
        if var params = model.springBoneGlobalParams {
            params.substeps = substeps
            model.springBoneGlobalParams = params
        }
    }
}