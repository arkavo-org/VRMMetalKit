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

/// Offscreen stereo bench on whatever Metal device the host was given
/// (the xrsimulator GPU when launched under the visionOS Simulator).
///
/// Enabled with `VRM_VISIONOS_BENCH=1|both|preferred|host`.
enum VisionOSGPUBench {
    static var isRequested: Bool {
        let raw = ProcessInfo.processInfo.environment["VRM_VISIONOS_BENCH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return raw == "1" || raw == "true" || raw == "both"
            || raw == "preferred" || raw == "host"
    }

    static func run(device: MTLDevice, model: VRMModel) {
        let raw = (ProcessInfo.processInfo.environment["VRM_VISIONOS_BENCH"] ?? "both")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let modes: [String]
        switch raw {
        case "preferred": modes = ["preferred"]
        case "host": modes = ["host"]
        default: modes = ["preferred", "host"]
        }
        let frames = Int(ProcessInfo.processInfo.environment["VRM_VISIONOS_BENCH_FRAMES"] ?? "") ?? 80
        let warmup = Int(ProcessInfo.processInfo.environment["VRM_VISIONOS_BENCH_WARMUP"] ?? "") ?? 15

        var player: AnimationPlayer?
        if let url = Bundle.main.url(forResource: "VRMA_01", withExtension: "vrma")
            ?? Bundle.main.url(forResource: "VRMA_01.vrma", withExtension: nil) {
            do {
                let clip = try VRMAnimationLoader.loadVRMA(from: url, model: model)
                let p = AnimationPlayer()
                p.load(clip)
                p.play()
                player = p
                NSLog("[VisionOSGPUBench] loaded VRMA_01 (%.2fs)", Double(clip.duration))
            } catch {
                NSLog("[VisionOSGPUBench] VRMA load failed: \(error)")
            }
        } else {
            NSLog("[VisionOSGPUBench] VRMA_01.vrma not in bundle — static pose")
        }

        var reports: [[String: Any]] = []
        for mode in modes {
            let report = runSubmit(
                device: device,
                model: model,
                player: player,
                submit: mode,
                frames: frames,
                warmup: warmup)
            reports.append(report)
        }

        let payload: [String: Any] = [
            "device": device.name,
            "registryID": String(device.registryID),
            "platform": "xrsimulator",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "runs": reports,
        ]
        writeJSON(payload)
    }

    private static func runSubmit(
        device: MTLDevice,
        model: VRMModel,
        player: AnimationPlayer?,
        submit: String,
        frames: Int,
        warmup: Int
    ) -> [String: Any] {
        guard let commandQueue = device.makeCommandQueue() else {
            NSLog("[VisionOSGPUBench] no command queue")
            return ["submit": submit, "error": "no command queue"]
        }

        let width = VisionOSStereoLayout.defaultWidth
        let height = VisionOSStereoLayout.defaultHeight
        let viewCount = VisionOSStereoLayout.defaultViewCount
        let dt = Float(1.0 / VisionOSStereoLayout.cadenceHz)

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        config.colorPixelFormat = .bgra8Unorm_srgb
        let renderer = VRMRenderer(device: device, config: config)
        renderer.performanceTracker = PerformanceTracker()
        renderer.useReverseZ = true
        renderer.enableSpringBone = true
        renderer.loadModel(model)
        renderer.simulationDeltaTime = 1.0 / VisionOSStereoLayout.cadenceHz
        renderer.setLight(0, direction: SIMD3<Float>(-0.2, 0.5, -0.85),
                          color: SIMD3<Float>(1, 1, 1), intensity: 1.0)
        renderer.disableLight(1)
        renderer.setLight(2, direction: SIMD3<Float>(0, 0.2, 1),
                          color: SIMD3<Float>(1, 1, 1), intensity: 0.3)
        renderer.setAmbientColor(SIMD3<Float>(0.04, 0.04, 0.04))
        renderer.setLightNormalizationMode(.radiometric)

        let aspect = Float(width) / Float(height)
        let projection = perspectiveMatrix(fovRadians: 45 * .pi / 180, aspect: aspect, near: 0.01, far: 100)
        let centerView = lookAtMatrix(
            eye: SIMD3<Float>(0, 1.3, 1.8),
            center: SIMD3<Float>(0, 1.3, 0),
            up: SIMD3<Float>(0, 1, 0))
        let pair = VisionOSStereoLayout.viewMatrices(center: centerView)
        let viewMatrices = [pair.left, pair.right]

        let colors: [any MTLTexture] = (0..<viewCount).map { i in
            makeColor(device: device, width: width, height: height, label: "bench.color.\(i)")
        }
        let depths: [any MTLTexture] = (0..<viewCount).map { i in
            makeDepth(device: device, width: width, height: height, label: "bench.depth.\(i)")
        }
        let passes = (0..<viewCount).map { i in
            makePass(color: colors[i], depth: depths[i])
        }

        let inflightCount = VRMConstants.Rendering.maxBufferedFrames
        var inflight: [MTLCommandBuffer?] = Array(repeating: nil, count: inflightCount)
        var slot = 0
        let gpuBox = GPUTimeBox()
        var encodeSamples: [Double] = []
        var stallSamples: [Double] = []
        var animSamples: [Double] = []
        encodeSamples.reserveCapacity(frames)
        stallSamples.reserveCapacity(frames)
        animSamples.reserveCapacity(frames)

        func encodeFrame(collect: Bool) {
            let tAnim = CACurrentMediaTime()
            player?.update(deltaTime: dt, model: model)
            let animMs = (CACurrentMediaTime() - tAnim) * 1000

            let i = slot
            slot = (slot + 1) % inflightCount
            var stallMs = 0.0
            if let previous = inflight[i], previous.status != .completed {
                let tStall = CACurrentMediaTime()
                previous.waitUntilCompleted()
                stallMs = (CACurrentMediaTime() - tStall) * 1000
            }

            guard let cb = commandQueue.makeCommandBuffer() else { return }
            if collect {
                cb.addCompletedHandler { buffer in
                    let gpu = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
                    if buffer.gpuStartTime.isFinite, buffer.gpuEndTime.isFinite, gpu >= 0, gpu < 10_000 {
                        gpuBox.append(gpu)
                    }
                }
            }
            let tEnc = CACurrentMediaTime()
            if submit == "preferred" {
                var views: [CompositorViewTarget] = []
                views.reserveCapacity(viewCount)
                for v in 0..<viewCount {
                    views.append(CompositorViewTarget(
                        colorTexture: colors[v],
                        depthTexture: depths[v],
                        renderPassDescriptor: passes[v],
                        viewMatrix: viewMatrices[v],
                        projectionMatrix: projection))
                }
                renderer.encodeCompositorViews(commandBuffer: cb, views: views)
            } else {
                for v in 0..<viewCount {
                    renderer.viewMatrix = viewMatrices[v]
                    renderer.projectionMatrix = projection
                    renderer.drawOffscreen(
                        to: colors[v],
                        depth: depths[v],
                        commandBuffer: cb,
                        renderPassDescriptor: passes[v])
                }
            }
            let encodeMs = (CACurrentMediaTime() - tEnc) * 1000
            cb.commit()
            inflight[i] = cb
            if collect {
                encodeSamples.append(encodeMs)
                stallSamples.append(stallMs)
                animSamples.append(animMs)
            }
        }

        for _ in 0..<warmup { encodeFrame(collect: false) }
        for cb in inflight { cb?.waitUntilCompleted() }
        inflight = Array(repeating: nil, count: inflightCount)
        gpuBox.reset()
        renderer.resetPerformanceMetrics()

        let wall0 = CACurrentMediaTime()
        for _ in 0..<frames { encodeFrame(collect: true) }
        for cb in inflight { cb?.waitUntilCompleted() }
        let wallMs = (CACurrentMediaTime() - wall0) * 1000

        let gpu = stats(gpuBox.snapshot())
        let encode = stats(encodeSamples)
        let stall = stats(stallSamples)
        let anim = stats(animSamples)
        let cpuSamples = zip(zip(encodeSamples, stallSamples), animSamples).map {
            $0.0.0 + $0.0.1 + $0.1
        }
        let cpu = stats(cpuSamples)
        let budget = VisionOSStereoLayout.frameBudgetMs
        let misses = cpuSamples.filter { $0 > budget }.count
        let metrics = renderer.getPerformanceMetrics()

        NSLog("""

        ======================================================================
        VisionOS GPU bench — \(submit) — \(device.name)
        ======================================================================
        Resolution     : \(width)x\(height) × \(viewCount) (offscreen stand-in)
        Spring bone    : on
        Animation      : \(player == nil ? "none" : "VRMA_01")
        Warmup/frames  : \(warmup) / \(frames)
        Wall           : \(String(format: "%.1f", wallMs)) ms
        CPU median     : \(fmt(cpu.median)) ms  (\(String(format: "%.1f", cpu.median / budget * 100))%% of \(String(format: "%.2f", budget)) ms)
        encode median  : \(fmt(encode.median)) ms
        gpu median     : \(fmt(gpu.median)) ms   p95 \(fmt(gpu.p95)) ms
        cadence misses : \(misses)/\(frames)
        draws/tri/verts: \(metrics?.drawCalls ?? -1) / \(metrics?.triangleCount ?? -1) / \(metrics?.vertexCount ?? -1)
        ======================================================================
        """)

        return [
            "submit": submit,
            "device": device.name,
            "width": width,
            "height": height,
            "views": viewCount,
            "frames": frames,
            "warmup": warmup,
            "wallMs": wallMs,
            "cpuMedianMs": cpu.median,
            "cpuP95Ms": cpu.p95,
            "encodeMedianMs": encode.median,
            "encodeP95Ms": encode.p95,
            "gpuMedianMs": gpu.median,
            "gpuP95Ms": gpu.p95,
            "stallMedianMs": stall.median,
            "animMedianMs": anim.median,
            "cadenceMisses": misses,
            "drawCalls": metrics?.drawCalls ?? 0,
            "triangles": metrics?.triangleCount ?? 0,
            "vertices": metrics?.vertexCount ?? 0,
        ]
    }

    // MARK: - Textures

    private static func makeColor(device: MTLDevice, width: Int, height: Int, label: String) -> any MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        let t = device.makeTexture(descriptor: d)!
        t.label = label
        return t
    }

    private static func makeDepth(device: MTLDevice, width: Int, height: Int, label: String) -> any MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        d.usage = .renderTarget
        d.storageMode = .private
        let t = device.makeTexture(descriptor: d)!
        t.label = label
        return t
    }

    private static func makePass(color: any MTLTexture, depth: any MTLTexture) -> MTLRenderPassDescriptor {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = color
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.depthAttachment.texture = depth
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.storeAction = .store
        rpd.depthAttachment.clearDepth = 0
        return rpd
    }

    // MARK: - Stats / IO

    private struct Stats {
        var median: Double
        var p95: Double
        var mean: Double
    }

    private static func stats(_ samples: [Double]) -> Stats {
        guard !samples.isEmpty else { return Stats(median: 0, p95: 0, mean: 0) }
        let s = samples.sorted()
        let n = s.count
        return Stats(
            median: s[n / 2],
            p95: s[min(n - 1, Int((Double(n) * 0.95).rounded(.down)))],
            mean: s.reduce(0, +) / Double(n))
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.3f", v) }

    private static func writeJSON(_ payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        else {
            NSLog("[VisionOSGPUBench] failed to encode JSON")
            return
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let url = docs?.appendingPathComponent("bench-visionos-xrsimulator.json")
        if let url {
            do {
                try data.write(to: url)
                NSLog("[VisionOSGPUBench] wrote \(url.path)")
            } catch {
                NSLog("[VisionOSGPUBench] write failed: \(error)")
            }
        }
        if let text = String(data: data, encoding: .utf8) {
            NSLog("[VisionOSGPUBench] JSON\n\(text)")
        }
    }

    private static func lookAtMatrix(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> matrix_float4x4 {
        let f = simd_normalize(center - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        var r = matrix_float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1))
        r.columns.0 = SIMD4<Float>(s.x, u.x, -f.x, 0)
        r.columns.1 = SIMD4<Float>(s.y, u.y, -f.y, 0)
        r.columns.2 = SIMD4<Float>(s.z, u.z, -f.z, 0)
        r.columns.3 = SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
        return r
    }

    private static func perspectiveMatrix(fovRadians: Float, aspect: Float, near: Float, far: Float) -> matrix_float4x4 {
        let t = tan(fovRadians / 2)
        var r = matrix_float4x4()
        r.columns.0 = SIMD4<Float>(1 / (aspect * t), 0, 0, 0)
        r.columns.1 = SIMD4<Float>(0, 1 / t, 0, 0)
        r.columns.2 = SIMD4<Float>(0, 0, -(far + near) / (far - near), -1)
        r.columns.3 = SIMD4<Float>(0, 0, -(2 * far * near) / (far - near), 0)
        return r
    }
}

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
