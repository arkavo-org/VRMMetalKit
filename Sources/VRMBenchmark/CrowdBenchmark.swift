//
// Copyright 2026 Arkavo
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
import simd
import VRMMetalKit

private enum CrowdBenchmarkError: LocalizedError {
    case resource(String)
    var errorDescription: String? {
        switch self {
        case .resource(let name): return "Crowd benchmark could not create \(name). Check available Metal memory and benchmark arguments."
        }
    }
}

@MainActor
func runCrowdBenchmark(opts: BenchmarkOptions, device: MTLDevice,
                       commandQueue: MTLCommandQueue) async throws -> BenchmarkReport {
    guard device.supportsTextureSampleCount(opts.sampleCount) else {
        throw CrowdBenchmarkError.resource("targets with MSAA \(opts.sampleCount)")
    }
    let quality: VRMConstants.SpringBoneQuality
    switch opts.springBoneQuality {
    case "off": quality = .off
    case "low": quality = .low
    case "medium": quality = .medium
    case "high": quality = .high
    case "ultra": quality = .ultra
    default: throw CrowdBenchmarkError.resource("spring-bone quality '\(opts.springBoneQuality)' (use off/low/medium/high/ultra)")
    }
    var config = RendererConfig()
    config.colorPixelFormat = .rgba8Unorm
    config.sampleCount = opts.sampleCount
    config.enableDepthPrepass = opts.depthPrepass
    let columns = Int(ceil(sqrt(Double(opts.avatarCount))))
    let rows = (opts.avatarCount + columns - 1) / columns
    let span = Float(columns) * opts.avatarSpacing
    let aspect = Float(opts.width) / Float(opts.height)
    let view = lookAtMatrix(
        eye: SIMD3<Float>(0, 1.3 + span * 0.4 + opts.cameraOffsetY, (1.8 + span * 0.9) / min(1, aspect)),
        center: SIMD3<Float>(0, 1 + opts.cameraOffsetY, -Float(rows) * opts.avatarSpacing * 0.5),
        up: SIMD3<Float>(0, 1, 0))
    let projection = perspectiveMatrix(fovRadians: 50 * .pi / 180, aspect: aspect, near: 0.05, far: max(200, span * 10))
    let loadStart = CACurrentMediaTime()
    var avatars: [VRMCrowdRenderer.Avatar] = []
    for i in 0..<opts.avatarCount {
        let model = try await VRMModel.load(from: URL(fileURLWithPath: opts.inputPath), device: device,
                                           options: loadingOptions(for: opts.loadingPreset))
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.performanceTracker = PerformanceTracker()
        // Placement is in the camera matrix; AnimationPlayer owns all node-transform updates.
        renderer.skipPreDrawTransformUpdate = true
        renderer.outlineWidth = opts.outlineWidth
        renderer.enableSpringBone = opts.enableSpringBone
        renderer.springBoneQuality = quality
        renderer.debugWireframe = opts.wireframe
        renderer.debugUVs = opts.debugUVs
        renderer.setLight(0, direction: SIMD3<Float>(-0.2, 0.5, -0.85), color: SIMD3<Float>(repeating: 1), intensity: 0.3183)
        renderer.disableLight(1)
        renderer.setLight(2, direction: SIMD3<Float>(0, 0.2, 1), color: SIMD3<Float>(repeating: 1), intensity: 0.0955)
        if opts.lighting == "single" || opts.lighting == "ambient" { renderer.disableLight(2) }
        if opts.lighting == "ambient" { renderer.disableLight(0) }
        renderer.setAmbientColor(SIMD3<Float>(repeating: 0.04))
        renderer.setLightNormalizationMode(.radiometric)
        var placement = matrix_identity_float4x4
        placement.columns.3 = SIMD4<Float>((Float(i % columns) - Float(columns - 1) / 2) * opts.avatarSpacing,
                                           0, -Float(i / columns) * opts.avatarSpacing, 1)
        if opts.crowdLayout == "stack" { placement.columns.3 = SIMD4<Float>(0, 0, -Float(i) * 0.02, 1) }
        renderer.viewMatrix = view * placement
        renderer.projectionMatrix = projection
        let player: AnimationPlayer?
        if let path = opts.vrmaPath {
            let animation = AnimationPlayer()
            animation.load(try VRMAnimationLoader.loadVRMA(from: URL(fileURLWithPath: path), model: model))
            animation.play()
            animation.seek(to: Float(i) * 0.3)
            animation.lookAtController = renderer.lookAtController
            player = animation
        } else {
            player = nil
        }
        avatars.append(.init(renderer: renderer, player: player))
    }
    let loadMs = (CACurrentMediaTime() - loadStart) * 1000
    let scene = VRMCrowdRenderer(avatars: avatars, policy: opts.crowdPolicy == "balanced" ? .balanced : .full)
    let submission: VRMCrowdRenderer.Submission = opts.crowdSubmit == "individual" ? .individualPasses : .sharedPass

    func texture(_ format: MTLPixelFormat, samples: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: opts.width, height: opts.height, mipmapped: false)
        descriptor.sampleCount = samples
        descriptor.textureType = samples > 1 ? .type2DMultisample : .type2D
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw CrowdBenchmarkError.resource("\(format) render target")
        }
        return texture
    }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = try texture(.rgba8Unorm, samples: opts.sampleCount)
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = opts.sampleCount > 1 ? .multisampleResolve : .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1)
    if opts.sampleCount > 1 { pass.colorAttachments[0].resolveTexture = try texture(.rgba8Unorm, samples: 1) }
    pass.depthAttachment.texture = try texture(.depth32Float, samples: opts.sampleCount)
    pass.depthAttachment.loadAction = .clear
    pass.depthAttachment.storeAction = .dontCare
    pass.depthAttachment.clearDepth = 1

    var pending: [(buffer: MTLCommandBuffer, measuredIndex: Int?)] = []
    var samples: [String: [Double]] = [:]
    var gpuSamples = Array(repeating: 0.0, count: opts.frames)
    var totals = Dictionary(uniqueKeysWithValues:
        ["drawCalls", "culledDraws", "triangles", "vertices", "morphDispatches",
         "visibleAvatars", "fullQualityAvatars", "animationUpdates"].map { ($0, 0.0) })
    var lastSequence = Array(repeating: 0, count: avatars.count)
    func retireFirst() throws {
        let item = pending.removeFirst()
        item.buffer.waitUntilCompleted()
        if let error = item.buffer.error { throw error }
        if let index = item.measuredIndex {
            gpuSamples[index] = max(0, item.buffer.gpuEndTime - item.buffer.gpuStartTime) * 1000
        }
    }
    func frame(measuredIndex: Int?) throws {
        let start = CACurrentMediaTime()
        if pending.count == opts.framesInFlight { try retireFirst() }
        let ready = CACurrentMediaTime()
        guard let buffer = commandQueue.makeCommandBuffer() else { throw CrowdBenchmarkError.resource("command buffer") }
        buffer.label = "Crowd Frame"
        scene.draw(deltaTime: Float(1 / opts.fps), viewportSize: CGSize(width: opts.width, height: opts.height),
                   commandBuffer: buffer, renderPassDescriptor: pass, submission: submission)
        buffer.commit()
        let encoded = CACurrentMediaTime()
        pending.append((buffer, measuredIndex))
        if opts.framesInFlight == 1 { try retireFirst() }
        let end = CACurrentMediaTime()
        guard measuredIndex != nil else { return }
        samples["render", default: []].append((end - start) * 1000)
        samples["cpuBudget", default: []].append((encoded - ready) * 1000)
        samples["wait", default: []].append((ready - start + end - encoded) * 1000)
        var phases: [PerformanceTracker.Phase: Double] = [:]
        for (i, avatar) in avatars.enumerated() {
            guard let sample = avatar.renderer.performanceTracker?.latestFrame,
                  sample.sequence != lastSequence[i] else { continue }
            lastSequence[i] = sample.sequence
            for (phase, value) in sample.phases { phases[phase, default: 0] += value }
            totals["drawCalls", default: 0] += Double(sample.drawCalls)
            totals["culledDraws", default: 0] += Double(sample.culledDraws)
            totals["triangles", default: 0] += Double(sample.triangles)
            totals["vertices", default: 0] += Double(sample.vertices)
            totals["morphDispatches", default: 0] += Double(sample.morphComputes)
        }
        for phase in PerformanceTracker.Phase.allCases where phase != .total {
            samples["\(phase)", default: []].append(phases[phase, default: 0])
        }
        totals["visibleAvatars", default: 0] += Double(scene.visibleAvatarCount)
        totals["fullQualityAvatars", default: 0] += Double(scene.fullQualityAvatarCount)
        totals["animationUpdates", default: 0] += Double(scene.animationUpdates)
    }
    for _ in 0..<opts.warmup { try autoreleasepool { try frame(measuredIndex: nil) } }
    while !pending.isEmpty { try retireFirst() }
    for avatar in avatars { avatar.renderer.resetPerformanceMetrics() }
    let start = CACurrentMediaTime()
    for index in 0..<opts.frames { try autoreleasepool { try frame(measuredIndex: index) } }
    while !pending.isEmpty { try retireFirst() }
    let wallMs = (CACurrentMediaTime() - start) * 1000
    samples["gpu"] = gpuSamples
    let counters = totals.mapValues { $0 / Double(opts.frames) }
    let legacyBytes = avatars.reduce(0) { total, avatar in
        total + (avatar.renderer.model?.meshes.reduce(0) { $0 + $1.primitives.reduce(0) { $0 + $1.legacyMorphBufferBytes } } ?? 0)
    }
    let crowd = BenchmarkReport.Crowd(
        workload: .init(avatarCount: opts.avatarCount, spacing: opts.avatarSpacing, layout: opts.crowdLayout,
                        policy: opts.crowdPolicy, submission: opts.crowdSubmit, framesInFlight: opts.framesInFlight,
                        fps: opts.fps, springBoneEnabled: opts.enableSpringBone, outlineWidth: opts.outlineWidth,
                        cameraOffsetY: opts.cameraOffsetY, depthPrepass: opts.depthPrepass,
                        wireframe: opts.wireframe, debugUVs: opts.debugUVs),
        device: device.name, osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        metalAllocatedBytes: device.currentAllocatedSize, legacyMorphBufferBytes: legacyBytes,
        loadMilliseconds: loadMs, wallMilliseconds: wallMs, counters: counters)
    print("\nCrowd benchmark — \(opts.label): \(device.name), \(opts.avatarCount) independent avatars")
    print("\(opts.crowdLayout), \(opts.crowdPolicy) quality, \(opts.crowdSubmit) pass, \(opts.framesInFlight) frames in flight, fixed \(opts.fps) Hz")
    print("\(opts.width)x\(opts.height), MSAA \(opts.sampleCount), physics \(opts.enableSpringBone ? opts.springBoneQuality : "disabled"), animation \(opts.vrmaPath ?? "none")")
    for key in ["render", "cpuBudget", "gpu", "wait"] { printCompactStats(label: key, samples: samples[key]!) }
    print("Drained throughput: \(String(format: "%.1f", Double(opts.frames) * 1000 / wallMs)) FPS")
    print("Mean scene counters: \(counters)")
    print("Metal allocated: \(device.currentAllocatedSize) bytes; legacy morph buffers: \(legacyBytes) bytes")
    return makeReport(opts: opts, stats: samples.mapValues { snapshot(FrameStats.compute($0)) }, crowd: crowd)
}
