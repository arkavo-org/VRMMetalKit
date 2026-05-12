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
    private var lastFrameTime: CFTimeInterval = 0
    private var frameCount: Int = 0

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
            frameTimes.append(frameTime)
            if frameTimes.count > maxFrameSamples {
                frameTimes.removeFirst()
            }
        }
        lastFrameTime = currentTime

        // Reset per-frame counters
        currentFrameMetrics = FrameMetrics()
    }

    /// End the current frame and update accumulated metrics
    public func endFrame() {
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
        gpuTimes.append(timeMs)
        if gpuTimes.count > maxFrameSamples {
            gpuTimes.removeFirst()
        }
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

            // Frame time statistics
            let sortedFrameTimes = frameTimes.sorted()
            metrics.frameTimeAvgMs = avgFrameTime
            metrics.frameTimeMinMs = sortedFrameTimes.first ?? 0
            metrics.frameTimeMaxMs = sortedFrameTimes.last ?? 0
            metrics.frameTimeP50Ms = percentile(sortedFrameTimes, 0.5)
            metrics.frameTimeP95Ms = percentile(sortedFrameTimes, 0.95)
            metrics.frameTimeP99Ms = percentile(sortedFrameTimes, 0.99)
        }

        // GPU time statistics
        if !gpuTimes.isEmpty {
            let sortedGPUTimes = gpuTimes.sorted()
            metrics.gpuTimeP95Ms = percentile(sortedGPUTimes, 0.95)
        }

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

        return metrics
    }

    /// Reset all metrics
    public func reset() {
        frameTimes.removeAll()
        gpuTimes.removeAll()
        lastFrameTime = 0
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
    }

    private func percentile(_ sortedArray: [Double], _ percentile: Double) -> Double {
        guard !sortedArray.isEmpty else { return 0 }
        let index = Int(Double(sortedArray.count - 1) * percentile)
        return sortedArray[index]
    }
}