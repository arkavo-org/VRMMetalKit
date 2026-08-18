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

/// Compositor-shaped stereo bench: reverse-Z, stored depth, N views,
/// no per-frame `waitUntilCompleted`.
///
/// `preferred` is ``VRMRenderer/encodeCompositorViews`` (one simulation,
/// one raster per eye). `host` is the older VisionHost submit: one
/// ``VRMRenderer/drawOffscreen`` per eye, which double-steps physics.
func runVisionOSBenchmark(
    opts: BenchmarkOptions,
    device: MTLDevice,
    commandQueue: MTLCommandQueue,
    model: VRMModel,
    player: AnimationPlayer?,
    loadMs: Double,
    animDurationSec: Double
) {
    let submit = opts.visionOSSubmit
    guard submit == "preferred" || submit == "host" else {
        print("ERROR: --visionos-submit must be preferred or host")
        exit(1)
    }
    let viewCount = max(1, opts.visionOSViews)
    let width = (opts.width == 1024 && opts.height == 1024)
        ? VisionOSStereoLayout.defaultWidth : opts.width
    let height = (opts.width == 1024 && opts.height == 1024)
        ? VisionOSStereoLayout.defaultHeight : opts.height

    var config = RendererConfig()
    config.sampleCount = 1
    config.strict = .off
    config.enableDepthPrepass = opts.depthPrepass
    config.colorPixelFormat = .bgra8Unorm_srgb

    let renderer = VRMRenderer(device: device, config: config)
    renderer.performanceTracker = PerformanceTracker()
    renderer.useReverseZ = true
    renderer.loadModel(model)
    renderer.outlineWidth = opts.outlineWidth
    renderer.enableSpringBone = opts.enableSpringBone
    renderer.skipPreDrawTransformUpdate = opts.skipPreDrawTransform
    switch opts.springBoneQuality {
    case "off":    renderer.springBoneQuality = .off
    case "low":    renderer.springBoneQuality = .low
    case "medium": renderer.springBoneQuality = .medium
    case "high":   renderer.springBoneQuality = .high
    default:       renderer.springBoneQuality = .ultra
    }
    // Match VisionHost: key + rim, no fill.
    renderer.setLight(0, direction: SIMD3<Float>(-0.2, 0.5, -0.85),
                      color: SIMD3<Float>(1, 1, 1), intensity: 1.0)
    renderer.disableLight(1)
    renderer.setLight(2, direction: SIMD3<Float>(0, 0.2, 1),
                      color: SIMD3<Float>(1, 1, 1), intensity: 0.3)
    renderer.setAmbientColor(SIMD3<Float>(0.04, 0.04, 0.04))
    renderer.setLightNormalizationMode(.radiometric)
    // Pace SpringBone at compositor cadence, not wall-clock — the bench
    // submits as fast as the inflight ring allows.
    renderer.simulationDeltaTime = 1.0 / VisionOSStereoLayout.cadenceHz

    let aspect = Float(width) / Float(height)
    let projection = perspectiveMatrix(
        fovRadians: 45.0 * .pi / 180.0, aspect: aspect, near: 0.01, far: 100.0)
    let centerView = lookAtMatrix(
        eye: SIMD3<Float>(0, 1.3, 1.8),
        center: SIMD3<Float>(0, 1.3, 0),
        up: SIMD3<Float>(0, 1, 0))
    let pair = VisionOSStereoLayout.viewMatrices(center: centerView)
    let viewMatrices: [simd_float4x4] = viewCount == 1
        ? [centerView]
        : (0..<viewCount).map { $0 % 2 == 0 ? pair.left : pair.right }

    func makeTarget(label: String) -> (color: MTLTexture, depth: MTLTexture) {
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .private
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private
        guard let color = device.makeTexture(descriptor: colorDesc),
              let depth = device.makeTexture(descriptor: depthDesc) else {
            print("ERROR: failed to allocate visionOS bench targets")
            exit(1)
        }
        color.label = label + "-color"
        depth.label = label + "-depth"
        return (color, depth)
    }

    let allocated = (0..<viewCount).map { makeTarget(label: "visionos-view\($0)") }
    let colorTextures: [any MTLTexture] = allocated.map(\.color)
    let depthTextures: [any MTLTexture] = allocated.map(\.depth)

    func passDescriptor(color: any MTLTexture, depth: any MTLTexture) -> MTLRenderPassDescriptor {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = color
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.depthAttachment.texture = depth
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.storeAction = .store
        rpd.depthAttachment.clearDepth = 0.0
        return rpd
    }
    let passDescriptors = (0..<viewCount).map {
        passDescriptor(color: colorTextures[$0], depth: depthTextures[$0])
    }

    // Animation + physics step at compositor cadence (90 Hz), not the Mac
    // 60 Hz `--fps` default.
    let dt = Float(1.0 / VisionOSStereoLayout.cadenceHz)
    let inflightCount = VRMConstants.Rendering.maxBufferedFrames
    var inflight: [MTLCommandBuffer?] = Array(repeating: nil, count: inflightCount)
    var inflightSlot = 0
    final class GPUTimeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [Double] = []
        func append(_ t: Double) {
            lock.lock(); times.append(t); lock.unlock()
        }
        func snapshot() -> [Double] {
            lock.lock(); defer { lock.unlock() }
            return times
        }
        func reset() {
            lock.lock(); times.removeAll(keepingCapacity: true); lock.unlock()
        }
    }
    let gpuBox = GPUTimeBox()

    struct Sample {
        var animationMs: Double
        var encodeMs: Double
        var stallMs: Double
        var cpuMs: Double
    }

    func encodeFrame() -> Sample {
        let t0 = CACurrentMediaTime()
        player?.update(deltaTime: dt, model: model)
        let animationMs = (CACurrentMediaTime() - t0) * 1000.0

        let slot = inflightSlot
        inflightSlot = (inflightSlot + 1) % inflightCount
        var stallMs = 0.0
        if let previous = inflight[slot], previous.status != .completed {
            let stallStart = CACurrentMediaTime()
            previous.waitUntilCompleted()
            stallMs = (CACurrentMediaTime() - stallStart) * 1000.0
        }

        guard let cb = commandQueue.makeCommandBuffer() else {
            return Sample(animationMs: animationMs, encodeMs: 0, stallMs: stallMs,
                          cpuMs: animationMs + stallMs)
        }
        cb.addCompletedHandler { buffer in
            let gpu = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000.0
            gpuBox.append(gpu)
        }

        let encodeStart = CACurrentMediaTime()
        if submit == "preferred" {
            var views: [CompositorViewTarget] = []
            views.reserveCapacity(viewCount)
            for i in 0..<viewCount {
                views.append(CompositorViewTarget(
                    colorTexture: colorTextures[i],
                    depthTexture: depthTextures[i],
                    renderPassDescriptor: passDescriptors[i],
                    viewMatrix: viewMatrices[i],
                    projectionMatrix: projection))
            }
            renderer.encodeCompositorViews(commandBuffer: cb, views: views)
        } else {
            for i in 0..<viewCount {
                renderer.viewMatrix = viewMatrices[i]
                renderer.projectionMatrix = projection
                renderer.drawOffscreen(
                    to: colorTextures[i],
                    depth: depthTextures[i],
                    commandBuffer: cb,
                    renderPassDescriptor: passDescriptors[i])
            }
        }
        let encodeMs = (CACurrentMediaTime() - encodeStart) * 1000.0
        cb.commit()
        inflight[slot] = cb
        return Sample(
            animationMs: animationMs,
            encodeMs: encodeMs,
            stallMs: stallMs,
            cpuMs: animationMs + encodeMs + stallMs)
    }

    for _ in 0..<opts.warmup {
        _ = encodeFrame()
    }
    for slot in inflight {
        slot?.waitUntilCompleted()
    }
    inflight = Array(repeating: nil, count: inflightCount)
    gpuBox.reset()
    renderer.resetPerformanceMetrics()

    var samples: [Sample] = []
    samples.reserveCapacity(opts.frames)
    let benchStart = CACurrentMediaTime()
    for _ in 0..<opts.frames {
        samples.append(encodeFrame())
    }
    for slot in inflight {
        slot?.waitUntilCompleted()
    }
    let wallMs = (CACurrentMediaTime() - benchStart) * 1000.0

    let gpuCopy = gpuBox.snapshot()

    let cpuStats = FrameStats.compute(samples.map(\.cpuMs))
    let encodeStats = FrameStats.compute(samples.map(\.encodeMs))
    let stallStats = FrameStats.compute(samples.map(\.stallMs))
    let animStats = FrameStats.compute(samples.map(\.animationMs))
    let gpuStats = FrameStats.compute(gpuCopy)
    let budget = VisionOSStereoLayout.frameBudgetMs
    let cpuPct = cpuStats.medianMs / budget * 100.0
    let missCount = samples.filter { $0.cpuMs > budget }.count

    print("""

    ======================================================================
    VRMMetalKit visionOS Benchmark — \(opts.label)
    ======================================================================
    Model          : \(opts.inputPath.split(separator: "/").last ?? "")
    Animation      : \(opts.vrmaPath.map { ($0 as NSString).lastPathComponent } ?? "none") (\(String(format: "%.2f", animDurationSec))s)
    Load time      : \(String(format: "%.1f ms", loadMs))
    Resolution     : \(width)x\(height) × \(viewCount) view(s), reverse-Z, depth stored
    Submit         : \(submit)\(submit == "preferred" ? " (simulate once, raster per eye)" : " (drawOffscreen per eye)")
    Spring bone    : \(opts.enableSpringBone ? "enabled" : "disabled")
    Cadence        : \(String(format: "%.0f", VisionOSStereoLayout.cadenceHz)) Hz (\(String(format: "%.2f", budget)) ms)
    Warmup / frames: \(opts.warmup) / \(opts.frames)
    Wall time      : \(String(format: "%.1f ms", wallMs))

    CPU (animation + encode + inflight stall) — not waitUntilCompleted
    ----------------------------------------------------------------------
      median : \(String(format: "%7.3f ms", cpuStats.medianMs))  (\(String(format: "%.1f", cpuPct))% of \(String(format: "%.2f", budget))ms)
      mean   : \(String(format: "%7.3f ms", cpuStats.meanMs))
      p95    : \(String(format: "%7.3f ms", cpuStats.p95Ms))
      cadence misses (CPU > budget): \(missCount)/\(opts.frames)
    """)

    printCompactStats(label: "animation", samples: samples.map(\.animationMs))
    printCompactStats(label: "encode", samples: samples.map(\.encodeMs))
    printCompactStats(label: "inflight stall", samples: samples.map(\.stallMs))
    printCompactStats(label: "gpu", samples: gpuCopy)

    if let m = renderer.getPerformanceMetrics() {
        print("""

        Renderer counters (\(submit == "preferred" ? "per compositor frame, both views" : "per drawOffscreen, one view"))
        ----------------------------------------------------------------------
          draw calls        : \(m.drawCalls)
          pipeline changes  : \(m.pipelineChanges)
          triangles         : \(m.triangleCount)
          vertices          : \(m.vertexCount)
          morph computes    : \(m.morphComputes)
          gpu p95 (tracker) : \(String(format: "%.3f ms", m.gpuTimeP95Ms))
        """)
    }
    print("======================================================================\n")

    var optsForReport = opts
    optsForReport.width = width
    optsForReport.height = height
    optsForReport.mode = "visionos"
    let report = makeReport(opts: optsForReport, stats: [
        "cpuBudget": snapshot(cpuStats),
        "encode": snapshot(encodeStats),
        "stall": snapshot(stallStats),
        "animation": snapshot(animStats),
        "gpu": snapshot(gpuStats),
        "render": snapshot(cpuStats),
    ])
    exit(finalizeReport(opts: opts, report: report))
}
