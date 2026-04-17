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
import simd
import VRMMetalKit

// MARK: - CLI

struct BenchmarkOptions {
    var inputPath: String = ""
    var frames: Int = 500
    var warmup: Int = 30
    var width: Int = 1024
    var height: Int = 1024
    var sampleCount: Int = 1
    var label: String = "baseline"
}

func usage() {
    print("""
    Usage: VRMBenchmark <path-to-vrm> [options]

    Runs N frames of drawOffscreenHeadless against a VRM model and reports
    CPU frame-time percentiles plus renderer counters.

    Options:
      --frames N       Number of measured frames (default 500)
      --warmup N       Warm-up frames (default 30)
      --width W        Render width  (default 1024)
      --height H       Render height (default 1024)
      --sample-count N MSAA sample count (default 1)
      --label NAME     Tag printed in the report header (default "baseline")

    Recommended invocation:
      swift run -c release VRMBenchmark <path> --frames 500

    Env fallback: if no <path> argument is given, AVATAR_SAMPLE_A is used.
    """)
}

func parseArguments() -> BenchmarkOptions? {
    var opts = BenchmarkOptions()
    let args = Array(CommandLine.arguments.dropFirst())

    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "-h", "--help":
            usage(); return nil
        case "--frames":
            i += 1; opts.frames = Int(args[i]) ?? opts.frames
        case "--warmup":
            i += 1; opts.warmup = Int(args[i]) ?? opts.warmup
        case "--width":
            i += 1; opts.width = Int(args[i]) ?? opts.width
        case "--height":
            i += 1; opts.height = Int(args[i]) ?? opts.height
        case "--sample-count":
            i += 1; opts.sampleCount = Int(args[i]) ?? opts.sampleCount
        case "--label":
            i += 1; opts.label = args[i]
        default:
            if opts.inputPath.isEmpty && !a.hasPrefix("--") {
                opts.inputPath = a
            }
        }
        i += 1
    }

    if opts.inputPath.isEmpty {
        if let envPath = ProcessInfo.processInfo.environment["AVATAR_SAMPLE_A"] {
            opts.inputPath = envPath
        } else {
            usage(); return nil
        }
    }
    return opts
}

// MARK: - Math helpers (duplicated from VRMRender/main.swift to keep target standalone)

func lookAtMatrix(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> matrix_float4x4 {
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

func perspectiveMatrix(fovRadians: Float, aspect: Float, near: Float, far: Float) -> matrix_float4x4 {
    let t = tan(fovRadians / 2)
    var r = matrix_float4x4()
    r.columns.0 = SIMD4<Float>(1 / (aspect * t), 0, 0, 0)
    r.columns.1 = SIMD4<Float>(0, 1 / t, 0, 0)
    r.columns.2 = SIMD4<Float>(0, 0, -(far + near) / (far - near), -1)
    r.columns.3 = SIMD4<Float>(0, 0, -(2 * far * near) / (far - near), 0)
    return r
}

// MARK: - Statistics

struct FrameStats {
    let count: Int
    let minMs: Double
    let maxMs: Double
    let meanMs: Double
    let medianMs: Double
    let p95Ms: Double
    let p99Ms: Double
    let stddevMs: Double

    static func compute(_ samples: [Double]) -> FrameStats {
        precondition(!samples.isEmpty)
        let sorted = samples.sorted()
        let n = sorted.count
        let mean = sorted.reduce(0, +) / Double(n)
        let variance = sorted.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n)
        func pct(_ p: Double) -> Double {
            let idx = min(n - 1, max(0, Int((p * Double(n - 1)).rounded())))
            return sorted[idx]
        }
        return FrameStats(
            count: n,
            minMs: sorted.first!,
            maxMs: sorted.last!,
            meanMs: mean,
            medianMs: pct(0.50),
            p95Ms: pct(0.95),
            p99Ms: pct(0.99),
            stddevMs: sqrt(variance)
        )
    }
}

// MARK: - Main

@main
struct VRMBenchmarkCLI {
    @MainActor
    static func main() async {
        guard let opts = parseArguments() else { exit(0) }

        guard FileManager.default.fileExists(atPath: opts.inputPath) else {
            print("ERROR: file not found: \(opts.inputPath)")
            exit(1)
        }

        guard let device = MTLCreateSystemDefaultDevice() else {
            print("ERROR: Metal device not available")
            exit(1)
        }
        guard let commandQueue = device.makeCommandQueue() else {
            print("ERROR: failed to create command queue")
            exit(1)
        }

        // Load model
        let url = URL(fileURLWithPath: opts.inputPath)
        let loadStart = CFAbsoluteTimeGetCurrent()
        let model: VRMModel
        do {
            model = try await VRMModel.load(from: url, device: device)
        } catch {
            print("ERROR: failed to load VRM: \(error)")
            exit(1)
        }
        let loadMs = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000.0

        // Configure renderer
        var config = RendererConfig()
        config.sampleCount = opts.sampleCount
        config.strict = .off
        let renderer = VRMRenderer(device: device, config: config)
        renderer.performanceTracker = PerformanceTracker()
        renderer.loadModel(model)
        renderer.setLight(0, direction: SIMD3<Float>(-0.2, 0.5, -0.85),
                          color: SIMD3<Float>(1, 1, 1), intensity: 1.0)
        renderer.disableLight(1)
        renderer.setLight(2, direction: SIMD3<Float>(0, 0.2, 1),
                          color: SIMD3<Float>(1, 1, 1), intensity: 0.3)
        renderer.setAmbientColor(SIMD3<Float>(0.04, 0.04, 0.04))

        let aspect = Float(opts.width) / Float(opts.height)
        renderer.projectionMatrix = perspectiveMatrix(
            fovRadians: 45.0 * .pi / 180.0, aspect: aspect, near: 0.01, far: 100.0)
        renderer.viewMatrix = lookAtMatrix(
            eye: SIMD3<Float>(0, 1.3, 1.8),
            center: SIMD3<Float>(0, 1.3, 0),
            up: SIMD3<Float>(0, 1, 0))

        // Offscreen targets (reused every frame)
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: opts.width, height: opts.height, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .private
        guard let colorTex = device.makeTexture(descriptor: colorDesc) else {
            print("ERROR: failed to create color texture"); exit(1)
        }

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: opts.width, height: opts.height, mipmapped: false)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private
        guard let depthTex = device.makeTexture(descriptor: depthDesc) else {
            print("ERROR: failed to create depth texture"); exit(1)
        }

        func renderOnce(_ cpuTimeMs: inout Double) {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = colorTex
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1)
            rpd.depthAttachment.texture = depthTex
            rpd.depthAttachment.loadAction = .clear
            rpd.depthAttachment.storeAction = .dontCare
            rpd.depthAttachment.clearDepth = 1.0

            guard let cb = commandQueue.makeCommandBuffer() else { return }

            let t0 = CACurrentMediaTime()
            renderer.drawOffscreenHeadless(
                to: colorTex, depth: depthTex,
                commandBuffer: cb, renderPassDescriptor: rpd)
            cb.commit()
            cb.waitUntilCompleted()
            cpuTimeMs = (CACurrentMediaTime() - t0) * 1000.0
        }

        // Warm-up
        var discard = 0.0
        for _ in 0..<opts.warmup {
            renderOnce(&discard)
        }
        renderer.resetPerformanceMetrics()

        // Measure
        var samples: [Double] = []
        samples.reserveCapacity(opts.frames)
        let benchStart = CACurrentMediaTime()
        for _ in 0..<opts.frames {
            var ms = 0.0
            renderOnce(&ms)
            samples.append(ms)
        }
        let wallMs = (CACurrentMediaTime() - benchStart) * 1000.0

        // Report
        let stats = FrameStats.compute(samples)
        let rendererMetrics = renderer.getPerformanceMetrics()

        print("""

        ======================================================================
        VRMMetalKit Render Benchmark — \(opts.label)
        ======================================================================
        Model          : \(url.lastPathComponent)
        Load time      : \(String(format: "%.1f ms", loadMs))
        Resolution     : \(opts.width)x\(opts.height) (MSAA \(opts.sampleCount)x)
        Warmup frames  : \(opts.warmup)
        Measured frames: \(opts.frames)
        Total wall time: \(String(format: "%.1f ms", wallMs))

        Per-frame CPU time (drawOffscreenHeadless + commit + wait)
        ----------------------------------------------------------------------
          min    : \(String(format: "%7.3f ms", stats.minMs))
          median : \(String(format: "%7.3f ms", stats.medianMs))
          mean   : \(String(format: "%7.3f ms", stats.meanMs))   (±\(String(format: "%.3f", stats.stddevMs)) stddev)
          p95    : \(String(format: "%7.3f ms", stats.p95Ms))
          p99    : \(String(format: "%7.3f ms", stats.p99Ms))
          max    : \(String(format: "%7.3f ms", stats.maxMs))
          eff FPS: \(String(format: "%.1f", 1000.0 / max(stats.meanMs, 0.0001)))
        """)

        if let m = rendererMetrics {
            // PerformanceTracker counters are cumulative across measured frames.
            let frames = max(stats.count, 1)
            let perFrame: (Int) -> String = { total in
                String(format: "%.1f", Double(total) / Double(frames))
            }
            print("""

            Renderer counters (per frame, averaged)
            ----------------------------------------------------------------------
              draw calls        : \(perFrame(m.drawCalls))
              pipeline changes  : \(perFrame(m.pipelineChanges))
              state changes     : \(perFrame(m.stateChanges))
              texture bindings  : \(perFrame(m.textureBindings))
              buffer bindings   : \(perFrame(m.bufferBindings))
              morph computes    : \(perFrame(m.morphComputes))
              triangles         : \(perFrame(m.triangleCount))
              vertices          : \(perFrame(m.vertexCount))
            """)
        }
        print("======================================================================\n")
    }
}
