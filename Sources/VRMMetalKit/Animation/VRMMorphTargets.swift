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


@preconcurrency import Foundation
import Metal
import simd
import QuartzCore

// MARK: - Morph Target Errors

public enum VRMMorphTargetError: Error, LocalizedError {
    case failedToCreateCommandQueue
    case failedToCreateComputePipeline(String)
    case missingShaderFunction(String)
    case activeSetBufferNotInitialized

    public var errorDescription: String? {
        switch self {
        case .failedToCreateCommandQueue:
            return "❌ [VRMMorphTargetSystem] Failed to create Metal command queue"
        case .failedToCreateComputePipeline(let reason):
            return "❌ [VRMMorphTargetSystem] Failed to create morph compute pipeline: \(reason)"
        case .missingShaderFunction(let name):
            return "❌ [VRMMorphTargetSystem] Failed to find shader function '\(name)'"
        case .activeSetBufferNotInitialized:
            return "❌ [VRMMorphTargetSystem] Active set buffer not initialized"
        }
    }
}

// MARK: - Morph Target System

// Active morph structure for GPU
public struct ActiveMorph {
    public var index: UInt32
    public var weight: Float

    public init(index: UInt32, weight: Float) {
        self.index = index
        self.weight = weight
    }
}

public class VRMMorphTargetSystem {
    private let device: MTLDevice
    private var morphWeightsBuffer: MTLBuffer?
    private let maxMorphTargets = VRMConstants.Rendering.maxMorphTargets

    // Active set management
    public static let maxActiveMorphs = VRMConstants.Rendering.maxActiveMorphs
    public static let morphEpsilon = VRMConstants.Physics.morphEpsilon
    private var activeSet: [ActiveMorph] = []
    private var activeSetBuffer: MTLBuffer?

    // Morphed output buffers (per primitive)
    private var morphedPositionBuffers: [Int: MTLBuffer] = [:] // primitiveID -> buffer
    private var morphedNormalBuffers: [Int: MTLBuffer] = [:]   // Phase B

    // Compute pipeline for GPU morphing (mandatory)
    public var morphAccumulatePipelineState: MTLComputePipelineState!
    private let commandQueue: MTLCommandQueue

    public init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw VRMMorphTargetError.failedToCreateCommandQueue
        }
        self.commandQueue = queue
        setupBuffers()
        try setupComputePipeline()
    }

    private func setupBuffers() {
        // Pre-allocate buffer for morph weights
        let bufferSize = MemoryLayout<Float>.stride * maxMorphTargets
        morphWeightsBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)

        // Pre-allocate active set buffer
        let activeSetSize = MemoryLayout<ActiveMorph>.stride * VRMMorphTargetSystem.maxActiveMorphs
        activeSetBuffer = device.makeBuffer(length: activeSetSize, options: .storageModeShared)
    }

    private func setupComputePipeline() throws {
        // Try to load compute pipeline from compiled Metal library
        // First try default library, then fall back to package resources
        var library: MTLLibrary?

        if let defaultLib = device.makeDefaultLibrary() {
            library = defaultLib
            vrmLog("[VRMMorphTargetSystem] Using default Metal library")
        } else if let url = Bundle.module.url(forResource: "VRMMetalKitShaders", withExtension: "metallib"),
                  let packageLib = try? device.makeLibrary(URL: url) {
            library = packageLib
            vrmLog("[VRMMorphTargetSystem] Using package Metal library (Bundle.module)")
        }

        if let library = library,
           let function = library.makeFunction(name: "morph_accumulate_positions") {
            // Found function in library
            do {
                morphAccumulatePipelineState = try device.makeComputePipelineState(function: function)
                vrmLog("[VRMMorphTargetSystem] Morph accumulate compute pipeline created from library")
                return
            } catch {
                vrmLog("[VRMMorphTargetSystem] Failed to create pipeline from library: \(error)")
            }
        }

        // Fallback to inline shader source if no default library or function not found
        let morphAccumulateSource = """
#include <metal_stdlib>
using namespace metal;

struct ActiveMorph {
    uint index;
    float weight;
};

kernel void morph_accumulate_positions(
    device const float3* basePos [[buffer(0)]],
    device const float3* deltaPos [[buffer(1)]],
    device const ActiveMorph* activeSet [[buffer(2)]],
    constant uint& vertexCount [[buffer(3)]],
    constant uint& morphCount [[buffer(4)]],
    constant uint& activeCount [[buffer(5)]],
    device float3* outPos [[buffer(6)]],
    uint vid [[thread_position_in_grid]]
) {
    if (vid >= vertexCount) return;
    float3 pos = basePos[vid];
    for (uint k = 0; k < activeCount; ++k) {
        uint morphIdx = activeSet[k].index;
        float weight = activeSet[k].weight;
        uint deltaIdx = morphIdx * vertexCount + vid;
        pos += deltaPos[deltaIdx] * weight;
    }
    outPos[vid] = pos;
}
"""
        do {
            let inlineLibrary = try device.makeLibrary(source: morphAccumulateSource, options: nil)
            guard let inlineFunction = inlineLibrary.makeFunction(name: "morph_accumulate_positions") else {
                throw VRMMorphTargetError.missingShaderFunction("morph_accumulate_positions")
            }
            morphAccumulatePipelineState = try device.makeComputePipelineState(function: inlineFunction)
            vrmLog("[VRMMorphTargetSystem] Morph accumulate compute pipeline created from inline source")
        } catch let error as VRMMorphTargetError {
            throw error
        } catch {
            throw VRMMorphTargetError.failedToCreateComputePipeline(error.localizedDescription)
        }
    }

    public func updateMorphWeights(_ weights: [Float]) {
        guard let buffer = morphWeightsBuffer else { return }

        let count = min(weights.count, maxMorphTargets)
        let pointer = buffer.contents().bindMemory(to: Float.self, capacity: count)
        for i in 0..<count {
            pointer[i] = weights[i]
        }
    }

    public func getMorphWeightsBuffer() -> MTLBuffer? {
        return morphWeightsBuffer
    }

    // MARK: - Active Set Management

    public func buildActiveSet(weights: [Float]) -> [ActiveMorph] {
        // Collect non-zero weights above epsilon
        var candidates: [ActiveMorph] = []
        for (index, weight) in weights.enumerated() {
            if abs(weight) > VRMMorphTargetSystem.morphEpsilon {
                candidates.append(ActiveMorph(index: UInt32(index), weight: weight))
            }
        }

        // Sort by absolute weight descending
        candidates.sort { abs($0.weight) > abs($1.weight) }

        // Take top K morphs
        let activeCount = min(candidates.count, VRMMorphTargetSystem.maxActiveMorphs)
        activeSet = Array(candidates.prefix(activeCount))

        // Update active set buffer
        if let buffer = activeSetBuffer, !activeSet.isEmpty {
            let pointer = buffer.contents().bindMemory(to: ActiveMorph.self, capacity: activeCount)
            for (i, morph) in activeSet.enumerated() {
                pointer[i] = morph
            }
        }

        return activeSet
    }

    public func getActiveSet() -> [ActiveMorph] {
        return activeSet
    }

    public func getActiveSetBuffer() -> MTLBuffer? {
        return activeSetBuffer
    }

    public func getActiveCount() -> Int {
        return activeSet.count
    }

    // GPU compute is always used - no heuristics
    public func hasMorphsToApply() -> Bool {
        return !activeSet.isEmpty
    }

    public func getOrCreateMorphedPositionBuffer(primitiveID: Int, vertexCount: Int) -> MTLBuffer? {
        if let buffer = morphedPositionBuffers[primitiveID] {
            return buffer
        }

        // Create new buffer for morphed positions
        let bufferSize = vertexCount * MemoryLayout<SIMD3<Float>>.stride
        let buffer = device.makeBuffer(length: bufferSize, options: .storageModePrivate)
        morphedPositionBuffers[primitiveID] = buffer
        return buffer
    }

    public func getOrCreateMorphedNormalBuffer(primitiveID: Int, vertexCount: Int) -> MTLBuffer? {
        if let buffer = morphedNormalBuffers[primitiveID] {
            return buffer
        }

        // Create new buffer for morphed normals
        let bufferSize = vertexCount * MemoryLayout<SIMD3<Float>>.stride
        let buffer = device.makeBuffer(length: bufferSize, options: .storageModePrivate)
        morphedNormalBuffers[primitiveID] = buffer
        return buffer
    }

    // MARK: - SoA Morph Accumulation with Active Set

    public func applyMorphsCompute(
        basePositions: MTLBuffer,
        deltaPositions: MTLBuffer,  // SoA layout: [morph0[v0..vN], morph1[v0..vN], ...]
        outputPositions: MTLBuffer,
        vertexCount: Int,
        morphCount: Int,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        if activeSet.count == 0 {
            // No active morphs - just copy base positions to output
            // This ensures output buffer is always valid even with no morphs
            guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
                vrmLog("[VRMMorphTargetSystem] Failed to create blit encoder for copy")
                return false
            }

            let copySize = vertexCount * MemoryLayout<SIMD3<Float>>.stride
            blitEncoder.copy(from: basePositions, sourceOffset: 0,
                           to: outputPositions, destinationOffset: 0,
                           size: copySize)
            blitEncoder.endEncoding()

            vrmLog("[VRMMorphTargetSystem] Copied base positions (no active morphs) for \(vertexCount) vertices")
            return true
        }

        guard let activeSetBuffer = activeSetBuffer else {
            vrmLog("⚠️ [VRMMorphTargetSystem] Active set buffer not initialized, skipping morph compute")
            return false
        }

        // Verify delta buffer size matches expected T*V (in DEBUG only)
        #if DEBUG
        let expectedDeltaSize = morphCount * vertexCount * MemoryLayout<SIMD3<Float>>.stride
        assert(deltaPositions.length >= expectedDeltaSize,
               "[VRMMorphTargetSystem] DeltaPos buffer size mismatch: got \(deltaPositions.length), expected \(expectedDeltaSize) for T=\(morphCount) V=\(vertexCount)")
        #endif

        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return false
        }

        computeEncoder.setComputePipelineState(morphAccumulatePipelineState)

        // Set buffers
        computeEncoder.setBuffer(basePositions, offset: 0, index: 0)
        computeEncoder.setBuffer(deltaPositions, offset: 0, index: 1)
        computeEncoder.setBuffer(activeSetBuffer, offset: 0, index: 2)

        // Set constants
        var vCount = UInt32(vertexCount)
        var mCount = UInt32(morphCount)
        var aCount = UInt32(activeSet.count)

        computeEncoder.setBytes(&vCount, length: MemoryLayout<UInt32>.size, index: 3)
        computeEncoder.setBytes(&mCount, length: MemoryLayout<UInt32>.size, index: 4)
        computeEncoder.setBytes(&aCount, length: MemoryLayout<UInt32>.size, index: 5)
        computeEncoder.setBuffer(outputPositions, offset: 0, index: 6)

        // Dispatch threads
        let threadsPerThreadgroup = MTLSize(width: 256, height: 1, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (vertexCount + 255) / 256,
            height: 1,
            depth: 1
        )

        computeEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        computeEncoder.endEncoding()

        return true
    }

    // Removed legacy GPU morph application - only compute path exists
}

// MARK: - Morph Target Data

public struct VRMMorphTarget {
    public let name: String
    public var positionDeltas: [SIMD3<Float>]?
    public var normalDeltas: [SIMD3<Float>]?
    public var tangentDeltas: [SIMD3<Float>]?

    public init(name: String) {
        self.name = name
    }
}

// MARK: - Expression Controller

public class VRMExpressionController: @unchecked Sendable {
    private var expressions: [VRMExpressionPreset: VRMExpression] = [:]
    private var customExpressions: [String: VRMExpression] = [:]
    private var currentWeights: [VRMExpressionPreset: Float] = [:]
    private var morphTargetSystem: VRMMorphTargetSystem?

    // Track morph weights per mesh
    private var meshMorphWeights: [Int: [Float]] = [:]  // meshIndex -> morph weights for that mesh

    public init() {
        // Initialize all preset weights to 0
        for preset in VRMExpressionPreset.allCases {
            currentWeights[preset] = 0
        }
    }

    public func setMorphTargetSystem(_ system: VRMMorphTargetSystem) {
        self.morphTargetSystem = system
    }

    public func registerExpression(_ expression: VRMExpression, for preset: VRMExpressionPreset) {
        expressions[preset] = expression
    }

    public func registerCustomExpression(_ expression: VRMExpression, name: String) {
        customExpressions[name] = expression
    }

    // MARK: - Expression Weight Control

    public func setExpressionWeight(_ preset: VRMExpressionPreset, weight: Float) {
        let clampedWeight = clamp(weight, min: 0, max: 1)
        vrmLog("[VRMExpressionController] Setting expression \(preset) weight to \(clampedWeight)")
        currentWeights[preset] = clampedWeight
        updateMorphTargets()
    }

    public func setCustomExpressionWeight(_ name: String, weight: Float) {
        // Handle custom expressions
        if let expression = customExpressions[name] {
            applyExpression(expression, weight: clamp(weight, min: 0, max: 1))
        }
    }

    // MARK: - Preset Animations

    public func blink(duration: Float = 0.15, completion: (@Sendable () -> Void)? = nil) {
        animateExpression(.blink, to: 1.0, duration: duration) { [weak self] in
            self?.animateExpression(.blink, to: 0.0, duration: duration, completion: completion)
        }
    }

    public func setMood(_ mood: VRMExpressionPreset, intensity: Float = 1.0) {
        // Reset other mood expressions
        let moodExpressions: [VRMExpressionPreset] = [.happy, .angry, .sad, .relaxed, .surprised]
        for expr in moodExpressions {
            if expr != mood {
                setExpressionWeight(expr, weight: 0)
            }
        }
        setExpressionWeight(mood, weight: intensity)
    }

    public func speak(duration: Float = 2.0) {
        // Simple lip sync animation - to be improved with proper async handling
        // For now, just animate one vowel
        animateExpression(.aa, to: 0.8, duration: duration * 0.5) { [weak self] in
            self?.animateExpression(.aa, to: 0, duration: duration * 0.5)
        }
    }

    // MARK: - Animation

    private func animateExpression(_ preset: VRMExpressionPreset,
                                  to targetWeight: Float,
                                  duration: Float,
                                  completion: (@Sendable () -> Void)? = nil) {
        let startWeight = currentWeights[preset] ?? 0
        let startTime = CACurrentMediaTime()

        Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] timer in
            // Compute progress off-actor to avoid sending non-Sendable values
            let elapsed = Float(CACurrentMediaTime() - startTime)
            let progress = min(elapsed / duration, 1.0)
            let weight = lerp(startWeight, targetWeight, progress)

            // Hop to main actor to safely touch controller state
            Task { @MainActor [weak self] in
                self?.setExpressionWeight(preset, weight: weight)
                if progress >= 1.0 {
                    completion?()
                }
            }

            if progress >= 1.0 {
                timer.invalidate()
            }
        }
    }

    // MARK: - Private Methods

    private func updateMorphTargets() {
        // Rebuild per-mesh weights dynamically from active expressions
        meshMorphWeights.removeAll()

        var activeCount = 0
        for (preset, weight) in currentWeights where weight > 0 {
            if let expression = expressions[preset] {
                applyExpressionToMeshWeights(expression, weight: weight)
                activeCount += 1
            }
        }

        if activeCount > 0 {
            vrmLog("[VRMExpressionController] Updated morph weights for \(activeCount) active expressions across \(meshMorphWeights.keys.count) meshes")
        }
        // Note: Renderer will push per-primitive weights; no global push here
    }

    private func applyExpressionToMeshWeights(_ expression: VRMExpression, weight: Float) {
        // Apply morph target binds per mesh
        for bind in expression.morphTargetBinds {
            let meshIndex = bind.node  // 'node' is actually mesh index in VRM 0.0
            let morphIndex = bind.index

            // Grow weights array to accommodate morphIndex
            var arr = meshMorphWeights[meshIndex] ?? []
            if arr.count <= morphIndex {
                arr.append(contentsOf: repeatElement(0.0, count: morphIndex + 1 - arr.count))
            }
            arr[morphIndex] += bind.weight * weight
            meshMorphWeights[meshIndex] = arr
        }
    }

    private func applyExpression(_ expression: VRMExpression, weight: Float) {
        // Clear and apply single expression
        meshMorphWeights.removeAll()
        applyExpressionToMeshWeights(expression, weight: weight)
    }

    // Expose per-mesh weights for renderer; pads/truncates to morphCount
    public func weightsForMesh(_ meshIndex: Int, morphCount: Int) -> [Float] {
        let arr = meshMorphWeights[meshIndex] ?? []
        if arr.count >= morphCount { return Array(arr.prefix(morphCount)) }
        return arr + Array(repeating: 0.0, count: morphCount - arr.count)
    }



    private let maxMorphTargets = 64
}

// MARK: - Morph Target Shader

public class MorphTargetShader {
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct MorphVertex {
        float3 position [[attribute(0)]];
        float3 normal [[attribute(1)]];
        float2 texCoord [[attribute(2)]];
        float4 color [[attribute(3)]];
        // Morph target attributes
        float3 positionDelta1 [[attribute(4)]];
        float3 normalDelta1 [[attribute(5)]];
        float3 positionDelta2 [[attribute(6)]];
        float3 normalDelta2 [[attribute(7)]];
        float3 positionDelta3 [[attribute(8)]];
        float3 normalDelta3 [[attribute(9)]];
        float3 positionDelta4 [[attribute(10)]];
        float3 normalDelta4 [[attribute(11)]];
    };

    struct Uniforms {
        float4x4 modelMatrix;
        float4x4 viewMatrix;
        float4x4 projectionMatrix;
        float4x4 normalMatrix;
    };

    struct VertexOut {
        float4 position [[position]];
        float3 worldNormal;
        float2 texCoord;
        float4 color;
    };

    vertex VertexOut morph_vertex(MorphVertex in [[stage_in]],
                                  constant Uniforms& uniforms [[buffer(1)]],
                                  constant float* morphWeights [[buffer(2)]]) {
        // Apply morph targets
        float3 morphedPosition = in.position;
        float3 morphedNormal = in.normal;

        // Apply up to 4 morph targets (can be extended)
        morphedPosition += in.positionDelta1 * morphWeights[0];
        morphedNormal += in.normalDelta1 * morphWeights[0];

        morphedPosition += in.positionDelta2 * morphWeights[1];
        morphedNormal += in.normalDelta2 * morphWeights[1];

        morphedPosition += in.positionDelta3 * morphWeights[2];
        morphedNormal += in.normalDelta3 * morphWeights[2];

        morphedPosition += in.positionDelta4 * morphWeights[3];
        morphedNormal += in.normalDelta4 * morphWeights[3];

        // Transform to clip space
        float4 worldPosition = uniforms.modelMatrix * float4(morphedPosition, 1.0);
        float3 worldNormal = normalize((uniforms.normalMatrix * float4(morphedNormal, 0.0)).xyz);

        VertexOut out;
        out.position = uniforms.projectionMatrix * uniforms.viewMatrix * worldPosition;
        out.worldNormal = worldNormal;
        out.texCoord = in.texCoord;
        out.color = in.color;

        return out;
    }

    fragment float4 morph_fragment(VertexOut in [[stage_in]]) {
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

// MARK: - Helper Functions

private func clamp(_ value: Float, min: Float, max: Float) -> Float {
    return Swift.max(min, Swift.min(max, value))
}

private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
    return a + (b - a) * t
}

// MARK: - Expression Mixer

public class VRMExpressionMixer: @unchecked Sendable {
    private var controller: VRMExpressionController
    private var autoBlinkEnabled = true
    private var blinkTimer: Timer?
    private var lastBlinkTime: TimeInterval = 0

    public init(controller: VRMExpressionController) {
        self.controller = controller
        startAutoBlink()
    }

    public func setAutoBlinkEnabled(_ enabled: Bool) {
        autoBlinkEnabled = enabled
        if enabled {
            startAutoBlink()
        } else {
            stopAutoBlink()
        }
    }

    private func startAutoBlink() {
        guard autoBlinkEnabled else { return }

        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }

                let currentTime = CACurrentMediaTime()
                let timeSinceLastBlink = currentTime - self.lastBlinkTime

                // Blink every 3-5 seconds randomly
                let blinkInterval = Double.random(in: 3.0...5.0)

                if timeSinceLastBlink > blinkInterval {
                    self.controller.blink()
                    self.lastBlinkTime = currentTime
                }
            }
        }
    }

    private func stopAutoBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
    }

    // MARK: - Lip Sync

    public func performLipSync(with audioData: [Float], sampleRate: Int = 44100) {
        // Simple lip sync based on audio amplitude
        // In a real implementation, this would analyze phonemes

        let amplitude = audioData.reduce(0) { $0 + abs($1) } / Float(audioData.count)
        let normalizedAmplitude = min(amplitude * 10, 1.0)

        // Map amplitude to mouth shapes
        if normalizedAmplitude > 0.7 {
            controller.setExpressionWeight(.aa, weight: normalizedAmplitude)
        } else if normalizedAmplitude > 0.5 {
            controller.setExpressionWeight(.oh, weight: normalizedAmplitude)
        } else if normalizedAmplitude > 0.3 {
            controller.setExpressionWeight(.ih, weight: normalizedAmplitude)
        } else {
            controller.setExpressionWeight(.neutral, weight: 1.0)
        }
    }

    deinit {
        stopAutoBlink()
    }
}
