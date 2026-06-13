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
import QuartzCore

/// Snapshot of rendering performance metrics aggregated over recent frames.
///
/// Holds frame-timing percentiles, GPU-time percentiles, per-frame averages of draw-call
/// and state-change counters, and basic memory stats. Produced by
/// ``PerformanceTracker/generateMetrics()`` after the tracker has recorded a window of
/// frames (the tracker keeps the last 600 frame samples — 10 s at 60 Hz).
///
/// Encoded as JSON with custom infinity handling: non-finite values are coerced to `0`
/// on encode so the result is interchangeable with strict JSON consumers.
public struct PerformanceMetrics: Codable {

    private enum CodingKeys: String, CodingKey {
        case fps
        case gpuTimeP95Ms
        case cpuTimeMs
        case drawCalls
        case culledDraws
        case stateChanges
        case morphComputes
        case triangleCount
        case vertexCount
        case textureBindings
        case bufferBindings
        case pipelineChanges
        case timestamp
        case frameTimeAvgMs
        case frameTimeMinMs
        case frameTimeMaxMs
        case frameTimeP50Ms
        case frameTimeP95Ms
        case frameTimeP99Ms
        case morphSetupMs
        case springBoneMs
        case renderItemBuildMs
        case commandEncodeMs
        case cpuFrameMs
        case allocatedMemoryMB
        case peakMemoryMB
    }

    /// Creates a zero-initialized metrics snapshot.
    public init() {}

    /// Encodes the snapshot, coercing any non-finite floating-point fields to `0`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        // Encode all values, converting infinity to 0 for JSON compatibility
        try container.encode(fps.isFinite ? fps : 0, forKey: .fps)
        try container.encode(gpuTimeP95Ms.isFinite ? gpuTimeP95Ms : 0, forKey: .gpuTimeP95Ms)
        try container.encode(cpuTimeMs.isFinite ? cpuTimeMs : 0, forKey: .cpuTimeMs)
        try container.encode(drawCalls, forKey: .drawCalls)
        try container.encode(culledDraws, forKey: .culledDraws)
        try container.encode(stateChanges, forKey: .stateChanges)
        try container.encode(morphComputes, forKey: .morphComputes)
        try container.encode(triangleCount, forKey: .triangleCount)
        try container.encode(vertexCount, forKey: .vertexCount)
        try container.encode(textureBindings, forKey: .textureBindings)
        try container.encode(bufferBindings, forKey: .bufferBindings)
        try container.encode(pipelineChanges, forKey: .pipelineChanges)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(frameTimeAvgMs.isFinite ? frameTimeAvgMs : 0, forKey: .frameTimeAvgMs)
        try container.encode(frameTimeMinMs.isFinite ? frameTimeMinMs : 0, forKey: .frameTimeMinMs)
        try container.encode(frameTimeMaxMs.isFinite ? frameTimeMaxMs : 0, forKey: .frameTimeMaxMs)
        try container.encode(frameTimeP50Ms.isFinite ? frameTimeP50Ms : 0, forKey: .frameTimeP50Ms)
        try container.encode(frameTimeP95Ms.isFinite ? frameTimeP95Ms : 0, forKey: .frameTimeP95Ms)
        try container.encode(frameTimeP99Ms.isFinite ? frameTimeP99Ms : 0, forKey: .frameTimeP99Ms)
        try container.encode(morphSetupMs.isFinite ? morphSetupMs : 0, forKey: .morphSetupMs)
        try container.encode(springBoneMs.isFinite ? springBoneMs : 0, forKey: .springBoneMs)
        try container.encode(renderItemBuildMs.isFinite ? renderItemBuildMs : 0, forKey: .renderItemBuildMs)
        try container.encode(commandEncodeMs.isFinite ? commandEncodeMs : 0, forKey: .commandEncodeMs)
        try container.encode(cpuFrameMs.isFinite ? cpuFrameMs : 0, forKey: .cpuFrameMs)
        try container.encode(allocatedMemoryMB.isFinite ? allocatedMemoryMB : 0, forKey: .allocatedMemoryMB)
        try container.encode(peakMemoryMB.isFinite ? peakMemoryMB : 0, forKey: .peakMemoryMB)
    }

    /// Decodes a snapshot, tolerating older payloads that lack the `culledDraws` field.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        fps = try container.decode(Double.self, forKey: .fps)
        gpuTimeP95Ms = try container.decode(Double.self, forKey: .gpuTimeP95Ms)
        cpuTimeMs = try container.decode(Double.self, forKey: .cpuTimeMs)
        drawCalls = try container.decode(Int.self, forKey: .drawCalls)
        culledDraws = (try? container.decode(Int.self, forKey: .culledDraws)) ?? 0
        stateChanges = try container.decode(Int.self, forKey: .stateChanges)
        morphComputes = try container.decode(Int.self, forKey: .morphComputes)
        triangleCount = try container.decode(Int.self, forKey: .triangleCount)
        vertexCount = try container.decode(Int.self, forKey: .vertexCount)
        textureBindings = try container.decode(Int.self, forKey: .textureBindings)
        bufferBindings = try container.decode(Int.self, forKey: .bufferBindings)
        pipelineChanges = try container.decode(Int.self, forKey: .pipelineChanges)
        timestamp = try container.decode(String.self, forKey: .timestamp)
        frameTimeAvgMs = try container.decode(Double.self, forKey: .frameTimeAvgMs)
        frameTimeMinMs = try container.decode(Double.self, forKey: .frameTimeMinMs)
        frameTimeMaxMs = try container.decode(Double.self, forKey: .frameTimeMaxMs)
        frameTimeP50Ms = try container.decode(Double.self, forKey: .frameTimeP50Ms)
        frameTimeP95Ms = try container.decode(Double.self, forKey: .frameTimeP95Ms)
        frameTimeP99Ms = try container.decode(Double.self, forKey: .frameTimeP99Ms)
        morphSetupMs = (try? container.decode(Double.self, forKey: .morphSetupMs)) ?? 0
        springBoneMs = (try? container.decode(Double.self, forKey: .springBoneMs)) ?? 0
        renderItemBuildMs = (try? container.decode(Double.self, forKey: .renderItemBuildMs)) ?? 0
        commandEncodeMs = (try? container.decode(Double.self, forKey: .commandEncodeMs)) ?? 0
        cpuFrameMs = (try? container.decode(Double.self, forKey: .cpuFrameMs)) ?? 0
        allocatedMemoryMB = try container.decode(Double.self, forKey: .allocatedMemoryMB)
        peakMemoryMB = try container.decode(Double.self, forKey: .peakMemoryMB)
    }

    /// Average frames per second, derived from the recent frame-time window.
    public var fps: Double = 0
    /// 95th-percentile GPU time per frame in milliseconds.
    public var gpuTimeP95Ms: Double = 0
    /// CPU time per frame in milliseconds (reserved; not populated by the default tracker).
    public var cpuTimeMs: Double = 0
    /// Average draw calls per frame across the recorded window.
    public var drawCalls: Int = 0
    /// Average primitives skipped by frustum culling per frame.
    public var culledDraws: Int = 0
    /// Average pipeline/texture/buffer state changes per frame.
    public var stateChanges: Int = 0
    /// Average morph-target compute dispatches per frame.
    public var morphComputes: Int = 0
    /// Average triangles submitted per frame.
    public var triangleCount: Int = 0
    /// Average vertices submitted per frame.
    public var vertexCount: Int = 0
    /// Average texture bindings per frame.
    public var textureBindings: Int = 0
    /// Average buffer bindings per frame.
    public var bufferBindings: Int = 0
    /// Average pipeline state changes per frame.
    public var pipelineChanges: Int = 0
    /// ISO-8601 timestamp recorded when the snapshot was generated.
    public var timestamp: String = ""

    // Frame time statistics

    /// Mean frame time in milliseconds across the recorded window.
    public var frameTimeAvgMs: Double = 0
    /// Minimum frame time in milliseconds.
    public var frameTimeMinMs: Double = 0
    /// Maximum frame time in milliseconds.
    public var frameTimeMaxMs: Double = 0
    /// Median (50th percentile) frame time in milliseconds.
    public var frameTimeP50Ms: Double = 0
    /// 95th-percentile frame time in milliseconds.
    public var frameTimeP95Ms: Double = 0
    /// 99th-percentile frame time in milliseconds.
    public var frameTimeP99Ms: Double = 0

    // Sub-phase CPU timings (averaged over the recorded window)

    /// Average morph-setup CPU time in milliseconds.
    public var morphSetupMs: Double = 0
    /// Average spring-bone CPU time in milliseconds.
    public var springBoneMs: Double = 0
    /// Average render-item-build CPU time in milliseconds.
    public var renderItemBuildMs: Double = 0
    /// Average command-encode CPU time in milliseconds.
    public var commandEncodeMs: Double = 0
    /// Average total per-frame CPU time in milliseconds.
    public var cpuFrameMs: Double = 0

    // Memory stats

    /// Currently allocated memory in megabytes (reserved; not populated by the default tracker).
    public var allocatedMemoryMB: Double = 0
    /// Peak memory observed during the recorded window, in megabytes (reserved).
    public var peakMemoryMB: Double = 0
}

/// Tracks performance metrics across frames
public class PerformanceTracker {
    private var frameTimes: [Double] = []
    private var gpuTimes: [Double] = []
    private var sortedFrameTimes: [Double] = []
    private var sortedGPUTimes: [Double] = []
    private var lastFrameTime: CFTimeInterval = 0
    private var frameStartTime: CFTimeInterval = 0
    private var frameCount: Int = 0

    // Total frame CPU time window
    private var cpuFrameTimes: [Double] = []
    private var sortedCpuFrameTimes: [Double] = []

    // Sub-phase CPU timers
    public enum Phase {
        case morphSetup
        case springBone
        case renderItemBuild
        case commandEncode
        case total
    }
    private var phaseTimers: [Phase: CFTimeInterval] = [:]
    private var phaseAccumulators: [Phase: (totalMs: Double, count: Int)] = [:]

    // Per-frame counters
    private var currentFrameMetrics = FrameMetrics()

    // Accumulated metrics
    private var totalDrawCalls: Int = 0
    private var totalCulledDraws: Int = 0
    private var totalStateChanges: Int = 0
    private var totalMorphComputes: Int = 0
    private var totalTriangles: Int = 0
    private var totalVertices: Int = 0
    private var totalTextureBindings: Int = 0
    private var totalBufferBindings: Int = 0
    private var totalPipelineChanges: Int = 0

    private let maxFrameSamples = 600 // 10 seconds at 60fps

    struct FrameMetrics {
        var drawCalls: Int = 0
        var culledDraws: Int = 0
        var stateChanges: Int = 0
        var morphComputes: Int = 0
        var triangles: Int = 0
        var vertices: Int = 0
        var textureBindings: Int = 0
        var bufferBindings: Int = 0
        var pipelineChanges: Int = 0
    }

    /// Creates a tracker with empty windows.
    public init() {}

    /// Start tracking a new frame
    public func beginFrame() {
        let currentTime = CACurrentMediaTime()
        if lastFrameTime > 0 {
            let frameTime = (currentTime - lastFrameTime) * 1000.0 // Convert to ms
            appendFrameTime(frameTime)
        }
        lastFrameTime = currentTime
        frameStartTime = currentTime

        // Reset per-frame counters
        currentFrameMetrics = FrameMetrics()
    }

    /// End the current frame and update accumulated metrics
    public func endFrame() {
        let currentTime = CACurrentMediaTime()
        let cpuFrameTime = (currentTime - frameStartTime) * 1000.0
        appendCpuFrameTime(cpuFrameTime)
        accumulatePhase(.total, ms: cpuFrameTime)

        frameCount += 1
        totalDrawCalls += currentFrameMetrics.drawCalls
        totalCulledDraws += currentFrameMetrics.culledDraws
        totalStateChanges += currentFrameMetrics.stateChanges
        totalMorphComputes += currentFrameMetrics.morphComputes
        totalTriangles += currentFrameMetrics.triangles
        totalVertices += currentFrameMetrics.vertices
        totalTextureBindings += currentFrameMetrics.textureBindings
        totalBufferBindings += currentFrameMetrics.bufferBindings
        totalPipelineChanges += currentFrameMetrics.pipelineChanges
    }

    /// Track a primitive culled by frustum (counts toward culledDraws, not drawCalls).
    public func recordCulledDraw() {
        currentFrameMetrics.culledDraws += 1
    }

    /// Record a GPU timestamp (in seconds)
    public func recordGPUTime(_ time: Double) {
        let timeMs = time * 1000.0
        appendGPUTime(timeMs)
    }

    /// Track a draw call
    public func recordDrawCall(triangles: Int, vertices: Int) {
        currentFrameMetrics.drawCalls += 1
        currentFrameMetrics.triangles += triangles
        currentFrameMetrics.vertices += vertices
    }

    /// Track a state change
    public func recordStateChange(type: StateChangeType) {
        currentFrameMetrics.stateChanges += 1
        switch type {
        case .pipeline:
            currentFrameMetrics.pipelineChanges += 1
        case .texture:
            currentFrameMetrics.textureBindings += 1
        case .buffer:
            currentFrameMetrics.bufferBindings += 1
        case .other:
            break
        }
    }

    /// Track a morph compute dispatch
    public func recordMorphCompute() {
        currentFrameMetrics.morphComputes += 1
    }

    /// Classification of state-change events recorded by ``PerformanceTracker/recordStateChange(type:)``.
    public enum StateChangeType {
        /// A render-pipeline state change.
        case pipeline
        /// A texture binding change.
        case texture
        /// A buffer binding change.
        case buffer
        /// Any other state mutation, counted toward `stateChanges` but not a sub-bucket.
        case other
    }

    /// Generate performance metrics report
    public func generateMetrics() -> PerformanceMetrics {
        var metrics = PerformanceMetrics()

        // Calculate FPS
        if !frameTimes.isEmpty {
            let avgFrameTime = frameTimes.reduce(0, +) / Double(frameTimes.count)
            metrics.fps = avgFrameTime > 0 ? 1000.0 / avgFrameTime : 0

            metrics.frameTimeAvgMs = avgFrameTime
            metrics.frameTimeMinMs = sortedFrameTimes.first ?? 0
            metrics.frameTimeMaxMs = sortedFrameTimes.last ?? 0
            metrics.frameTimeP50Ms = percentile(sortedFrameTimes, 0.5)
            metrics.frameTimeP95Ms = percentile(sortedFrameTimes, 0.95)
            metrics.frameTimeP99Ms = percentile(sortedFrameTimes, 0.99)
        }

        // GPU time statistics
        if !sortedGPUTimes.isEmpty {
            metrics.gpuTimeP95Ms = percentile(sortedGPUTimes, 0.95)
        }

        // CPU frame time
        if !cpuFrameTimes.isEmpty {
            metrics.cpuTimeMs = cpuFrameTimes.reduce(0, +) / Double(cpuFrameTimes.count)
        }

        // Per-phase CPU averages
        metrics.morphSetupMs = averagePhase(.morphSetup)
        metrics.springBoneMs = averagePhase(.springBone)
        metrics.renderItemBuildMs = averagePhase(.renderItemBuild)
        metrics.commandEncodeMs = averagePhase(.commandEncode)
        metrics.cpuFrameMs = averagePhase(.total)

        // Average per-frame metrics
        if frameCount > 0 {
            metrics.drawCalls = totalDrawCalls / frameCount
            metrics.culledDraws = totalCulledDraws / frameCount
            metrics.stateChanges = totalStateChanges / frameCount
            metrics.morphComputes = totalMorphComputes / frameCount
            metrics.triangleCount = totalTriangles / frameCount
            metrics.vertexCount = totalVertices / frameCount
            metrics.textureBindings = totalTextureBindings / frameCount
            metrics.bufferBindings = totalBufferBindings / frameCount
            metrics.pipelineChanges = totalPipelineChanges / frameCount
        }

        // Timestamp
        let formatter = ISO8601DateFormatter()
        metrics.timestamp = formatter.string(from: Date())

        // Reset phase accumulators so the next report reflects recent work
        phaseAccumulators.removeAll()
        phaseTimers.removeAll()

        return metrics
    }

    /// Reset all metrics
    public func reset() {
        frameTimes.removeAll()
        gpuTimes.removeAll()
        sortedFrameTimes.removeAll()
        sortedGPUTimes.removeAll()
        cpuFrameTimes.removeAll()
        sortedCpuFrameTimes.removeAll()
        lastFrameTime = 0
        frameStartTime = 0
        frameCount = 0
        totalDrawCalls = 0
        totalCulledDraws = 0
        totalStateChanges = 0
        totalMorphComputes = 0
        totalTriangles = 0
        totalVertices = 0
        totalTextureBindings = 0
        totalBufferBindings = 0
        totalPipelineChanges = 0
        phaseTimers.removeAll()
        phaseAccumulators.removeAll()
    }

    private func percentile(_ sortedArray: [Double], _ percentile: Double) -> Double {
        guard !sortedArray.isEmpty else { return 0 }
        let count = sortedArray.count
        if count == 1 { return sortedArray[0] }
        let position = Double(count - 1) * percentile
        let lower = Int(position)
        let upper = lower + 1
        if upper >= count { return sortedArray[count - 1] }
        let fraction = position - Double(lower)
        return sortedArray[lower] * (1.0 - fraction) + sortedArray[upper] * fraction
    }

    // MARK: - Sorted window maintenance

    private func appendFrameTime(_ time: Double) {
        if frameTimes.count >= maxFrameSamples, let oldest = frameTimes.first {
            frameTimes.removeFirst()
            removeSorted(value: oldest, from: &sortedFrameTimes)
        }
        frameTimes.append(time)
        insertSorted(value: time, into: &sortedFrameTimes)
    }

    private func appendGPUTime(_ time: Double) {
        if gpuTimes.count >= maxFrameSamples, let oldest = gpuTimes.first {
            gpuTimes.removeFirst()
            removeSorted(value: oldest, from: &sortedGPUTimes)
        }
        gpuTimes.append(time)
        insertSorted(value: time, into: &sortedGPUTimes)
    }

    private func appendCpuFrameTime(_ time: Double) {
        if cpuFrameTimes.count >= maxFrameSamples, let oldest = cpuFrameTimes.first {
            cpuFrameTimes.removeFirst()
            removeSorted(value: oldest, from: &sortedCpuFrameTimes)
        }
        cpuFrameTimes.append(time)
        insertSorted(value: time, into: &sortedCpuFrameTimes)
    }

    private func insertSorted(value: Double, into array: inout [Double]) {
        let index = array.firstIndex(where: { $0 >= value }) ?? array.count
        array.insert(value, at: index)
    }

    private func removeSorted(value: Double, from array: inout [Double]) {
        if let index = array.firstIndex(of: value) {
            array.remove(at: index)
        }
    }

    // MARK: - Phase helpers

    public func beginPhase(_ phase: Phase) {
        phaseTimers[phase] = CACurrentMediaTime()
    }

    public func endPhase(_ phase: Phase) {
        guard let startTime = phaseTimers[phase] else { return }
        let elapsedMs = (CACurrentMediaTime() - startTime) * 1000.0
        accumulatePhase(phase, ms: elapsedMs)
        phaseTimers.removeValue(forKey: phase)
    }

    private func accumulatePhase(_ phase: Phase, ms: Double) {
        var acc = phaseAccumulators[phase] ?? (totalMs: 0, count: 0)
        acc.totalMs += ms
        acc.count += 1
        phaseAccumulators[phase] = acc
    }

    private func averagePhase(_ phase: Phase) -> Double {
        guard let acc = phaseAccumulators[phase], acc.count > 0 else { return 0 }
        return acc.totalMs / Double(acc.count)
    }
}
