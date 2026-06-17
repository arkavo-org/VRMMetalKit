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
    var mode: String = "render"
    var inputPath: String = ""
    var vrmaPath: String? = nil
    var frames: Int = 500
    var warmup: Int = 30
    var width: Int = 1024
    var height: Int = 1024
    var sampleCount: Int = 1
    var fps: Double = 60
    var label: String = "baseline"
    var loadingPreset: String = "default"
    var outlineWidth: Float = 0.02
    var enableSpringBone: Bool = false
    var wireframe: Bool = false
    var depthPrepass: Bool = false
    var lighting: String = "standard"
    var debugUVs: Int32 = 0
    var cameraOffsetY: Float = 0  // Shift camera target/eye in Y to push avatar off-screen for cull tests
    var springBoneQuality: String = "ultra"  // off, low, medium, high, ultra
    var skipPreDrawTransform: Bool = false   // opt out of renderer's safety-net root transform pass
    var jsonOutPath: String? = nil           // --json [PATH]; nil = no JSON, "-" = stdout
    var baselinePath: String? = nil          // --baseline FILE
    var thresholdMedianPct: Double = 10.0    // --threshold MEDIAN:P95
    var thresholdP95Pct: Double = 15.0
    var archiveDir: String? = nil            // --archive-dir DIR (pipeline mode)
}

func usage() {
    print("""
    Usage: VRMBenchmark <path-to-vrm> [options]

    Runs N frames of drawOffscreenHeadless against a VRM model and reports
    CPU frame-time percentiles plus renderer counters.

    Options:
      --vrma PATH      Optional VRMA animation file; enables per-frame
                       animation playback so skinning and spring physics
                       do real work each frame (recommended).
      --mode NAME      Benchmark mode: render, animation, transforms, load,
                       pipeline (default render). 'pipeline' needs no input
                       model — it times cold vs warm pipeline-state builds.
      --loading NAME   Loading options preset: default, safe, or max
                       (default default).
      --frames N       Number of measured frames (default 500)
      --warmup N       Warm-up frames (default 30)
      --fps N          Animation playback rate in frames/sec (default 60)
      --width W        Render width  (default 1024)
      --height H       Render height (default 1024)
      --sample-count N MSAA sample count (default 1)
      --outline-width N Global MToon outline width (default 0.02, use 0 to disable)
      --spring-bone    Enable GPU spring-bone physics during render mode
      --spring-bone-quality NAME  off|low|medium|high|ultra (default ultra)
      --skip-pre-draw  Set renderer.skipPreDrawTransformUpdate=true (opts out of safety-net hierarchy walk)
      --wireframe      Enable wireframe rendering during render mode
      --lighting MODE  Lighting mode: standard, single, ambient (default standard)
      --debug-uvs N    Set renderer debugUVs mode for fragment isolation (default 0)
      --label NAME     Tag printed in the report header (default "baseline")
      --json [PATH]    Emit a machine-readable JSON report. With a path, writes
                       to that file; without (or "-"), writes to stdout after
                       the human report.
      --baseline FILE  Compare the current run against a previously-emitted
                       JSON report. Prints a delta table; exits 1 if any gated
                       metric regresses past --threshold.
      --threshold M:P  Regression thresholds as "MEDIAN:P95" percent
                       (default 10:15 → median +10 %, p95 +15 %).
      --archive-dir D  (pipeline mode) Persist compiled pipelines to an on-disk
                       binary archive in D. Run twice with the same D to compare
                       a cold first launch against a warm archive-loaded relaunch.

    Recommended invocation:
      swift run -c release VRMBenchmark <vrm-path> --vrma <vrma-path> --frames 500

    Env fallback: if no <path> argument is given, AVATAR_SAMPLE_A is used.
    """)
}

func parseArguments() -> BenchmarkOptions? {
    var opts = BenchmarkOptions()
    let args = Array(CommandLine.arguments.dropFirst())

    var i = 0
    // Reads the value following a value-flag, returns nil if the flag was
    // the last token so we fail cleanly instead of index-out-of-range.
    func nextValue(for flag: String) -> String? {
        i += 1
        guard i < args.count else {
            print("ERROR: missing value for \(flag)")
            return nil
        }
        return args[i]
    }

    while i < args.count {
        let a = args[i]
        switch a {
        case "-h", "--help":
            usage(); return nil
        case "--frames":
            guard let v = nextValue(for: a) else { return nil }
            opts.frames = Int(v) ?? opts.frames
        case "--mode":
            guard let v = nextValue(for: a) else { return nil }
            opts.mode = v.lowercased()
        case "--warmup":
            guard let v = nextValue(for: a) else { return nil }
            opts.warmup = Int(v) ?? opts.warmup
        case "--width":
            guard let v = nextValue(for: a) else { return nil }
            opts.width = Int(v) ?? opts.width
        case "--height":
            guard let v = nextValue(for: a) else { return nil }
            opts.height = Int(v) ?? opts.height
        case "--sample-count":
            guard let v = nextValue(for: a) else { return nil }
            opts.sampleCount = Int(v) ?? opts.sampleCount
        case "--outline-width":
            guard let v = nextValue(for: a) else { return nil }
            opts.outlineWidth = Float(v) ?? opts.outlineWidth
        case "--spring-bone":
            opts.enableSpringBone = true
        case "--wireframe":
            opts.wireframe = true
        case "--depth-prepass":
            opts.depthPrepass = true
        case "--lighting":
            guard let v = nextValue(for: a) else { return nil }
            opts.lighting = v.lowercased()
        case "--debug-uvs":
            guard let v = nextValue(for: a) else { return nil }
            opts.debugUVs = Int32(v) ?? opts.debugUVs
        case "--camera-offset-y":
            guard let v = nextValue(for: a) else { return nil }
            opts.cameraOffsetY = Float(v) ?? opts.cameraOffsetY
        case "--spring-bone-quality":
            guard let v = nextValue(for: a) else { return nil }
            opts.springBoneQuality = v.lowercased()
        case "--skip-pre-draw":
            opts.skipPreDrawTransform = true
        case "--vrma":
            guard let v = nextValue(for: a) else { return nil }
            opts.vrmaPath = v
        case "--fps":
            guard let v = nextValue(for: a) else { return nil }
            opts.fps = Double(v) ?? opts.fps
        case "--label":
            guard let v = nextValue(for: a) else { return nil }
            opts.label = v
        case "--loading":
            guard let v = nextValue(for: a) else { return nil }
            opts.loadingPreset = v.lowercased()
        case "--json":
            // Optional path argument: present and not another flag → file path.
            // Absent or "-" → stdout.
            if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                i += 1
                opts.jsonOutPath = args[i]
            } else {
                opts.jsonOutPath = "-"
            }
        case "--baseline":
            guard let v = nextValue(for: a) else { return nil }
            opts.baselinePath = v
        case "--archive-dir":
            guard let v = nextValue(for: a) else { return nil }
            opts.archiveDir = v
        case "--threshold":
            guard let v = nextValue(for: a) else { return nil }
            let parts = v.split(separator: ":").map(String.init)
            guard parts.count == 2,
                  let m = Double(parts[0]), let p = Double(parts[1]) else {
                FileHandle.standardError.write(Data("ERROR: --threshold expects MEDIAN:P95, got '\(v)'\n".utf8))
                return nil
            }
            opts.thresholdMedianPct = m
            opts.thresholdP95Pct = p
        default:
            if opts.inputPath.isEmpty && !a.hasPrefix("--") {
                opts.inputPath = a
            }
        }
        i += 1
    }

    if opts.inputPath.isEmpty && opts.mode != "pipeline" {
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

struct RenderFrameSample {
    let animationMs: Double
    let encodeMs: Double
    let waitMs: Double
    let totalMs: Double
}

func printStats(title: String, label: String, unit: String, stats: FrameStats, wallMs: Double) {
    print("""

    ======================================================================
    \(title) — \(label)
    ======================================================================
    Samples        : \(stats.count)
    Total wall time: \(String(format: "%.1f ms", wallMs))

    Per-sample time (\(unit))
    ----------------------------------------------------------------------
      min    : \(String(format: "%7.3f ms", stats.minMs))
      median : \(String(format: "%7.3f ms", stats.medianMs))
      mean   : \(String(format: "%7.3f ms", stats.meanMs))   (±\(String(format: "%.3f", stats.stddevMs)) stddev)
      p95    : \(String(format: "%7.3f ms", stats.p95Ms))
      p99    : \(String(format: "%7.3f ms", stats.p99Ms))
      max    : \(String(format: "%7.3f ms", stats.maxMs))
    ======================================================================

    """)
}

func printCompactStats(label: String, samples: [Double]) {
    let stats = FrameStats.compute(samples)
    print("  \(label.padding(toLength: 10, withPad: " ", startingAt: 0)): mean \(String(format: "%7.3f ms", stats.meanMs))  median \(String(format: "%7.3f ms", stats.medianMs))  p95 \(String(format: "%7.3f ms", stats.p95Ms))")
}

// MARK: - JSON report helpers

private func snapshot(_ s: FrameStats) -> BenchmarkReport.FrameStatsSnapshot {
    BenchmarkReport.FrameStatsSnapshot(
        count: s.count,
        minMs: s.minMs,
        medianMs: s.medianMs,
        meanMs: s.meanMs,
        p95Ms: s.p95Ms,
        p99Ms: s.p99Ms,
        maxMs: s.maxMs,
        stddevMs: s.stddevMs)
}

private func systemDescriptor() -> BenchmarkReport.System {
    let osName: String
    #if os(macOS)
    osName = "macOS"
    #elseif os(iOS)
    osName = "iOS"
    #else
    osName = "unknown"
    #endif
    return BenchmarkReport.System(
        os: osName,
        host: ProcessInfo.processInfo.hostName)
}

private func makeReport(
    opts: BenchmarkOptions,
    stats: [String: BenchmarkReport.FrameStatsSnapshot]
) -> BenchmarkReport {
    BenchmarkReport(
        timestamp: Date(),
        label: opts.label,
        input: .init(
            vrm: opts.inputPath.isEmpty ? nil : opts.inputPath,
            vrma: opts.vrmaPath,
            frames: opts.frames,
            warmup: opts.warmup),
        config: .init(
            mode: opts.mode,
            width: opts.width,
            height: opts.height,
            sampleCount: opts.sampleCount,
            loading: opts.loadingPreset,
            springBoneQuality: opts.mode == "render" ? opts.springBoneQuality : nil,
            lighting: opts.mode == "render" ? opts.lighting : nil),
        system: systemDescriptor(),
        stats: stats)
}

/// Writes the JSON report to `--json` destination (file path or stdout) and,
/// if `--baseline` was supplied, loads the baseline and compares. Returns the
/// process exit code (0 = pass, 1 = regression).
private func finalizeReport(opts: BenchmarkOptions, report: BenchmarkReport) -> Int32 {
    // 1. Emit JSON (file or stdout) if requested.
    if let dest = opts.jsonOutPath {
        do {
            let data = try report.encodeJSON()
            if dest == "-" {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                try data.write(to: URL(fileURLWithPath: dest))
            }
        } catch {
            FileHandle.standardError.write(Data("ERROR: failed to write JSON report: \(error)\n".utf8))
            return 1
        }
    }

    // 2. Compare against baseline if requested.
    guard let basePath = opts.baselinePath else { return 0 }
    do {
        let baseData = try Data(contentsOf: URL(fileURLWithPath: basePath))
        let baseline = try BenchmarkReport.decode(from: baseData)
        let threshold = BenchmarkComparison.Threshold(
            medianPercent: opts.thresholdMedianPct,
            p95Percent: opts.thresholdP95Pct)
        let comparison = BenchmarkComparison.compare(
            baseline: baseline, current: report, threshold: threshold)
        print("\nBaseline comparison (\(basePath))")
        print(comparison.renderTable())
        if comparison.passed {
            print("\nResult: PASS — all gated metrics within threshold.")
            return 0
        } else {
            print("\nResult: FAIL — one or more gated metrics regressed past threshold.")
            return 1
        }
    } catch {
        FileHandle.standardError.write(Data("ERROR: failed to load baseline '\(basePath)': \(error.localizedDescription)\n".utf8))
        return 1
    }
}

func loadingOptions(for preset: String) -> VRMLoadingOptions {
    switch preset {
    case "default":
        return .default
    case "safe", "parallel":
        return VRMLoadingOptions(optimizations: [
            .skipVerboseLogging,
            .parallelTextureDecoding,
            .parallelTextureLoading,
            .parallelMeshLoading,
            .preloadBuffers,
            .parallelMaterialLoading
        ])
    case "max", "maximum", "maximumperformance":
        return VRMLoadingOptions(optimizations: .maximumPerformance)
    default:
        FileHandle.standardError.write(Data("ERROR: unknown --loading preset '\(preset)'. Expected default, safe, or max.\n".utf8))
        exit(1)
    }
}

// MARK: - Main

/// Measures the cost the on-disk pipeline binary archive is meant to remove:
/// building every MToon render-pipeline variant from a cold cache in a fresh
/// process. Reports the cold build (first renderer, cache empty) against a warm
/// build (second renderer, in-memory cache hit) so the compile component is
/// isolated from fixed renderer-construction overhead.
@MainActor
func runPipelineBaseline(device: MTLDevice, label: String, archiveDir: String?) {
    var config = RendererConfig()
    config.colorPixelFormat = .bgra8Unorm
    config.sampleCount = 1
    config.strict = .off

    // When an archive directory is supplied, route builds through the on-disk
    // archive. Run the same command twice with one --archive-dir to compare a
    // cold first launch (writes the archive) against a warm relaunch (loads it).
    var archivePreloaded = false
    if let dir = archiveDir {
        let dirURL = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let shaderHash = VRMPipelineCache.bundledShaderHash() ?? "bench"
        let archiveURL = PipelineBinaryArchive.cacheURL(
            in: dirURL, deviceName: device.name, shaderHash: shaderHash)
        archivePreloaded = FileManager.default.fileExists(atPath: archiveURL.path)
        do {
            try VRMPipelineCache.shared.enablePersistentArchive(
                device: device, directory: dirURL, shaderHash: shaderHash)
        } catch {
            print("WARNING: failed to enable persistent archive: \(error)")
        }
    }

    VRMPipelineCache.shared.clearCache()

    let coldStart = CACurrentMediaTime()
    _ = VRMRenderer(device: device, config: config)
    let coldMs = (CACurrentMediaTime() - coldStart) * 1000.0
    let coldStats = VRMPipelineCache.shared.getStatistics()

    let warmStart = CACurrentMediaTime()
    _ = VRMRenderer(device: device, config: config)
    let warmMs = (CACurrentMediaTime() - warmStart) * 1000.0

    if archiveDir != nil {
        _ = try? VRMPipelineCache.shared.flushPersistentArchive()
    }

    let archiveLine: String
    if archiveDir == nil {
        archiveLine = "      archive:            (disabled)\n"
    } else if archivePreloaded {
        archiveLine = "      archive:            LOADED from disk (warm relaunch)\n"
    } else {
        archiveLine = "      archive:            written this run (cold first launch)\n"
    }

    print("""

    VRMMetalKit Pipeline Compile Baseline
      label:            \(label)
      device:           \(device.name)
      pipeline variants: \(coldStats.pipelineStateCount)
    \(archiveLine)  cold build (cache empty):   \(String(format: "%8.2f ms", coldMs))
      warm build (in-memory hit): \(String(format: "%8.2f ms", warmMs))
      compile component:          \(String(format: "%8.2f ms", coldMs - warmMs))
    """)
}

struct VRMBenchmarkCLI {
    @MainActor
    static func main() async {
        guard let opts = parseArguments() else { exit(0) }

        // The pipeline-compile baseline measures only shader/pipeline build cost,
        // so it needs no input model.
        if opts.mode != "pipeline" {
            guard FileManager.default.fileExists(atPath: opts.inputPath) else {
                print("ERROR: file not found: \(opts.inputPath)")
                exit(1)
            }
        }

        guard let device = MTLCreateSystemDefaultDevice() else {
            print("ERROR: Metal device not available")
            exit(1)
        }

        if opts.mode == "pipeline" {
            runPipelineBaseline(device: device, label: opts.label, archiveDir: opts.archiveDir)
            exit(0)
        }

        guard let commandQueue = device.makeCommandQueue() else {
            print("ERROR: failed to create command queue")
            exit(1)
        }

        if opts.mode == "load" {
            let loadOptions = loadingOptions(for: opts.loadingPreset)
            var samples: [Double] = []
            samples.reserveCapacity(opts.frames)
            let benchStart = CACurrentMediaTime()
            for _ in 0..<opts.frames {
                let t0 = CACurrentMediaTime()
                do {
                    _ = try await VRMModel.load(
                        from: URL(fileURLWithPath: opts.inputPath),
                        device: device,
                        options: loadOptions)
                } catch {
                    print("ERROR: failed to load VRM: \(error)")
                    exit(1)
                }
                let elapsedMs = (CACurrentMediaTime() - t0) * 1000.0
                autoreleasepool {
                    // Per-iteration drain so CG/Foundation autoreleased objects
                    // from texture decode and glTF parse don't accumulate across
                    // long sample runs.
                    samples.append(elapsedMs)
                }
            }
            let wallMs = (CACurrentMediaTime() - benchStart) * 1000.0
            let stats = FrameStats.compute(samples)
            printStats(
                title: "VRMMetalKit Load Benchmark",
                label: opts.label,
                unit: "VRMModel.load",
                stats: stats,
                wallMs: wallMs)
            let report = makeReport(opts: opts, stats: ["load": snapshot(stats)])
            exit(finalizeReport(opts: opts, report: report))
        }

        // Load model
        let url = URL(fileURLWithPath: opts.inputPath)
        let loadStart = CFAbsoluteTimeGetCurrent()
        let model: VRMModel
        do {
            model = try await VRMModel.load(from: url, device: device, options: loadingOptions(for: opts.loadingPreset))
        } catch {
            print("ERROR: failed to load VRM: \(error)")
            exit(1)
        }
        let loadMs = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000.0

        // Optional VRMA animation. When supplied, we run the animation player
        // every frame so skinning, spring physics, and morph paths do real
        // work (a static pose skips most of the per-frame CPU cost).
        let player: AnimationPlayer?
        let animDurationSec: Double
        if let vrmaPath = opts.vrmaPath {
            guard FileManager.default.fileExists(atPath: vrmaPath) else {
                print("ERROR: VRMA file not found: \(vrmaPath)"); exit(1)
            }
            do {
                let clip = try VRMAnimationLoader.loadVRMA(
                    from: URL(fileURLWithPath: vrmaPath), model: model)
                let p = AnimationPlayer()
                p.load(clip)
                p.play()
                player = p
                animDurationSec = Double(clip.duration)
            } catch {
                print("ERROR: failed to load VRMA: \(error)"); exit(1)
            }
        } else {
            player = nil
            animDurationSec = 0
        }

        if opts.mode == "animation" {
            guard let player = player else {
                print("ERROR: --mode animation requires --vrma PATH")
                exit(1)
            }
            let dt = Float(1.0 / opts.fps)
            for _ in 0..<opts.warmup {
                player.update(deltaTime: dt, model: model)
            }
            var samples: [Double] = []
            samples.reserveCapacity(opts.frames)
            let benchStart = CACurrentMediaTime()
            for _ in 0..<opts.frames {
                let t0 = CACurrentMediaTime()
                player.update(deltaTime: dt, model: model)
                samples.append((CACurrentMediaTime() - t0) * 1000.0)
            }
            let wallMs = (CACurrentMediaTime() - benchStart) * 1000.0
            let stats = FrameStats.compute(samples)
            printStats(
                title: "VRMMetalKit Animation Benchmark",
                label: opts.label,
                unit: "AnimationPlayer.update",
                stats: stats,
                wallMs: wallMs)
            let report = makeReport(opts: opts, stats: ["animation": snapshot(stats)])
            exit(finalizeReport(opts: opts, report: report))
        }

        if opts.mode == "transforms" {
            for _ in 0..<opts.warmup {
                model.updateNodeTransforms()
            }
            var samples: [Double] = []
            samples.reserveCapacity(opts.frames)
            let benchStart = CACurrentMediaTime()
            for _ in 0..<opts.frames {
                let t0 = CACurrentMediaTime()
                model.updateNodeTransforms()
                samples.append((CACurrentMediaTime() - t0) * 1000.0)
            }
            let wallMs = (CACurrentMediaTime() - benchStart) * 1000.0
            let stats = FrameStats.compute(samples)
            printStats(
                title: "VRMMetalKit Transform Propagation Benchmark",
                label: opts.label,
                unit: "VRMModel.updateNodeTransforms",
                stats: stats,
                wallMs: wallMs)
            let report = makeReport(opts: opts, stats: ["transforms": snapshot(stats)])
            exit(finalizeReport(opts: opts, report: report))
        }

        guard opts.mode == "render" else {
            print("ERROR: unknown --mode \(opts.mode). Expected render, animation, transforms, or load.")
            exit(1)
        }

        // Configure renderer
        var config = RendererConfig()
        config.sampleCount = opts.sampleCount
        config.strict = .off
        config.enableDepthPrepass = opts.depthPrepass
        let renderer = VRMRenderer(device: device, config: config)
        renderer.performanceTracker = PerformanceTracker()
        renderer.loadModel(model)
        renderer.outlineWidth = opts.outlineWidth
        renderer.enableSpringBone = opts.enableSpringBone
        renderer.skipPreDrawTransformUpdate = opts.skipPreDrawTransform
        switch opts.springBoneQuality {
        case "off":    renderer.springBoneQuality = .off
        case "low":    renderer.springBoneQuality = .low
        case "medium": renderer.springBoneQuality = .medium
        case "high":   renderer.springBoneQuality = .high
        case "ultra":  renderer.springBoneQuality = .ultra
        default:
            FileHandle.standardError.write(Data("ERROR: unknown --spring-bone-quality '\(opts.springBoneQuality)'. Expected off/low/medium/high/ultra.\n".utf8))
            exit(1)
        }
        renderer.debugWireframe = opts.wireframe
        renderer.debugUVs = opts.debugUVs
        // Intensities rescaled by 1/π under .radiometric to preserve the prior
        // .automatic behaviour (vrm-conformance #213).
        switch opts.lighting {
        case "ambient":
            renderer.disableLight(0)
            renderer.disableLight(1)
            renderer.disableLight(2)
        case "single":
            renderer.setLight(0, direction: SIMD3<Float>(-0.2, 0.5, -0.85),
                              color: SIMD3<Float>(1, 1, 1), intensity: 0.3183)
            renderer.disableLight(1)
            renderer.disableLight(2)
        default:
            renderer.setLight(0, direction: SIMD3<Float>(-0.2, 0.5, -0.85),
                              color: SIMD3<Float>(1, 1, 1), intensity: 0.3183)
            renderer.disableLight(1)
            renderer.setLight(2, direction: SIMD3<Float>(0, 0.2, 1),
                              color: SIMD3<Float>(1, 1, 1), intensity: 0.0955)
        }
        renderer.setAmbientColor(SIMD3<Float>(0.04, 0.04, 0.04))
        renderer.setLightNormalizationMode(.radiometric)

        let aspect = Float(opts.width) / Float(opts.height)
        renderer.projectionMatrix = perspectiveMatrix(
            fovRadians: 45.0 * .pi / 180.0, aspect: aspect, near: 0.01, far: 100.0)
        renderer.viewMatrix = lookAtMatrix(
            eye: SIMD3<Float>(0, 1.3 + opts.cameraOffsetY, 1.8),
            center: SIMD3<Float>(0, 1.3 + opts.cameraOffsetY, 0),
            up: SIMD3<Float>(0, 1, 0))

        // Offscreen targets (reused every frame)
        let useMSAA = opts.sampleCount > 1
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: opts.width, height: opts.height, mipmapped: false)
        colorDesc.textureType = useMSAA ? .type2DMultisample : .type2D
        colorDesc.sampleCount = max(1, opts.sampleCount)
        // Multisample textures aren't sampleable; only the resolve target needs .shaderRead.
        colorDesc.usage = useMSAA ? .renderTarget : [.renderTarget, .shaderRead]
        colorDesc.storageMode = .private
        guard let colorTex = device.makeTexture(descriptor: colorDesc) else {
            print("ERROR: failed to create color texture"); exit(1)
        }

        let resolveTex: MTLTexture?
        if useMSAA {
            let resolveDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: opts.width, height: opts.height, mipmapped: false)
            resolveDesc.usage = [.renderTarget, .shaderRead]
            resolveDesc.storageMode = .private
            guard let texture = device.makeTexture(descriptor: resolveDesc) else {
                print("ERROR: failed to create resolve texture"); exit(1)
            }
            resolveTex = texture
        } else {
            resolveTex = nil
        }

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: opts.width, height: opts.height, mipmapped: false)
        depthDesc.textureType = useMSAA ? .type2DMultisample : .type2D
        depthDesc.sampleCount = max(1, opts.sampleCount)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private
        guard let depthTex = device.makeTexture(descriptor: depthDesc) else {
            print("ERROR: failed to create depth texture"); exit(1)
        }

        let dt = Float(1.0 / opts.fps)

        func renderOnce(_ sample: inout RenderFrameSample) {
            // Wrap in autoreleasepool so Metal objects (command buffers, render
            // pass descriptors, encoders) are released every frame instead of
            // accumulating until the outer pool drains. Without this, running
            // 500+ frames in a tight loop leaks driver threads and can trigger
            // a system watchdog panic.
            var animationMs = 0.0
            var encodeMs = 0.0
            var waitMs = 0.0
            var totalMs = 0.0
            autoreleasepool {
                let rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = colorTex
                rpd.colorAttachments[0].loadAction = .clear
                if let resolveTex {
                    rpd.colorAttachments[0].resolveTexture = resolveTex
                    rpd.colorAttachments[0].storeAction = .multisampleResolve
                } else {
                    rpd.colorAttachments[0].storeAction = .store
                }
                rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1)
                rpd.depthAttachment.texture = depthTex
                rpd.depthAttachment.loadAction = .clear
                rpd.depthAttachment.storeAction = .dontCare
                rpd.depthAttachment.clearDepth = 1.0

                guard let cb = commandQueue.makeCommandBuffer() else { return }

                let t0 = CACurrentMediaTime()
                // Advance animation before drawing so per-frame measurement
                // captures both the animation CPU cost and the render cost.
                let animationStart = CACurrentMediaTime()
                player?.update(deltaTime: dt, model: model)
                animationMs = (CACurrentMediaTime() - animationStart) * 1000.0

                let encodeStart = CACurrentMediaTime()
                renderer.drawOffscreenHeadless(
                    to: colorTex, depth: depthTex,
                    commandBuffer: cb, renderPassDescriptor: rpd)
                encodeMs = (CACurrentMediaTime() - encodeStart) * 1000.0

                let waitStart = CACurrentMediaTime()
                cb.commit()
                cb.waitUntilCompleted()
                waitMs = (CACurrentMediaTime() - waitStart) * 1000.0
                totalMs = (CACurrentMediaTime() - t0) * 1000.0
            }
            sample = RenderFrameSample(
                animationMs: animationMs,
                encodeMs: encodeMs,
                waitMs: waitMs,
                totalMs: totalMs)
        }

        // Warm-up
        var discard = RenderFrameSample(animationMs: 0, encodeMs: 0, waitMs: 0, totalMs: 0)
        for _ in 0..<opts.warmup {
            renderOnce(&discard)
        }
        renderer.resetPerformanceMetrics()

        // Measure
        var samples: [RenderFrameSample] = []
        samples.reserveCapacity(opts.frames)
        let benchStart = CACurrentMediaTime()
        for _ in 0..<opts.frames {
            var sample = RenderFrameSample(animationMs: 0, encodeMs: 0, waitMs: 0, totalMs: 0)
            renderOnce(&sample)
            samples.append(sample)
        }
        let wallMs = (CACurrentMediaTime() - benchStart) * 1000.0

        // Report
        let totalSamples = samples.map(\.totalMs)
        let stats = FrameStats.compute(totalSamples)
        let rendererMetrics = renderer.getPerformanceMetrics()

        // CPU budget = animation + encode (excludes GPU wait).
        // This is the time that competes with concurrent LLM inference on the
        // same CPU cores, and directly correlates with battery drain on iOS.
        let cpuBudgetSamples = samples.map { $0.animationMs + $0.encodeMs }
        let cpuStats = FrameStats.compute(cpuBudgetSamples)
        let frameBudget60 = 16.67
        let cpuBudgetPct = cpuStats.medianMs / frameBudget60 * 100.0

        print("""

        ======================================================================
        VRMMetalKit Render Benchmark — \(opts.label)
        ======================================================================
        Model          : \(url.lastPathComponent)
        Animation      : \(opts.vrmaPath.map { "\(($0 as NSString).lastPathComponent) (\(String(format: "%.2f", animDurationSec))s @ \(opts.fps) fps)" } ?? "none (static pose)")
        Load time      : \(String(format: "%.1f ms", loadMs))
        Resolution     : \(opts.width)x\(opts.height) (MSAA \(opts.sampleCount)x)
        Outline width  : \(String(format: "%.4f", opts.outlineWidth))
        Spring bone    : \(opts.enableSpringBone ? "enabled" : "disabled")
        Wireframe      : \(opts.wireframe ? "enabled" : "disabled")
        Lighting       : \(opts.lighting)
        Debug UVs      : \(opts.debugUVs)
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

        CPU budget (animation + encode, excludes GPU wait)
        ----------------------------------------------------------------------
          median : \(String(format: "%7.3f ms", cpuStats.medianMs))  (\(String(format: "%.1f", cpuBudgetPct))% of \(String(format: "%.2f", frameBudget60))ms 60fps frame)
          mean   : \(String(format: "%7.3f ms", cpuStats.meanMs))
          p95    : \(String(format: "%7.3f ms", cpuStats.p95Ms))
          Remaining for LLM/system at 60fps: \(String(format: "%.2f", frameBudget60 - cpuStats.medianMs)) ms/frame
        """)

        print("""

        Render phase breakdown (per frame)
        ----------------------------------------------------------------------
        """)
        printCompactStats(label: "animation", samples: samples.map(\.animationMs))
        printCompactStats(label: "encode", samples: samples.map(\.encodeMs))
        printCompactStats(label: "gpu wait", samples: samples.map(\.waitMs))

        // Sub-phase CPU breakdown captured inside drawOffscreenHeadless by the
        // PerformanceTracker. These attribute the `encode` span to morph setup,
        // spring-bone dispatch, render-item build, and command encoding. A phase
        // with no samples (e.g. spring bone when disabled) is omitted.
        // (jsonKey, displayLabel, phase) — jsonKey is persisted/gated; label is
        // the short human-report column.
        let subPhases: [(key: String, label: String, phase: PerformanceTracker.Phase)] = [
            ("morphSetup", "morphSetup", .morphSetup),
            ("springBone", "springBone", .springBone),
            ("renderItemBuild", "renderItem", .renderItemBuild),
            ("commandEncode", "cmdEncode", .commandEncode),
        ]
        let subPhaseSamples: [(key: String, label: String, samples: [Double])] = subPhases.compactMap {
            guard let s = renderer.performanceTracker?.samples(for: $0.phase), !s.isEmpty else { return nil }
            return (key: $0.key, label: $0.label, samples: s)
        }
        if !subPhaseSamples.isEmpty {
            print("""

            Sub-phase CPU breakdown (inside encode, per frame)
            ----------------------------------------------------------------------
            """)
            for entry in subPhaseSamples {
                printCompactStats(label: entry.label, samples: entry.samples)
            }
        }

        if let m = rendererMetrics {
            // PerformanceTracker returns counters averaged per frame.
            let perFrame: (Int) -> String = { value in
                String(format: "%d", value)
            }
            print("""

            Renderer counters (per frame, averaged)
            ----------------------------------------------------------------------
              draw calls        : \(perFrame(m.drawCalls))
              culled draws      : \(perFrame(m.culledDraws))
              pipeline changes  : \(perFrame(m.pipelineChanges))
              state changes     : \(perFrame(m.stateChanges))
              texture bindings  : \(perFrame(m.textureBindings))
              buffer bindings   : \(perFrame(m.bufferBindings))
              morph computes    : \(perFrame(m.morphComputes))
              triangles         : \(perFrame(m.triangleCount))
              vertices          : \(perFrame(m.vertexCount))
              gpu p95           : \(String(format: "%.3f ms", m.gpuTimeP95Ms))
            """)
        }
        print("======================================================================\n")

        var statsDict: [String: BenchmarkReport.FrameStatsSnapshot] = [
            "render":    snapshot(stats),
            "animation": snapshot(FrameStats.compute(samples.map(\.animationMs))),
            "encode":    snapshot(FrameStats.compute(samples.map(\.encodeMs))),
            "wait":      snapshot(FrameStats.compute(samples.map(\.waitMs))),
            "cpuBudget": snapshot(cpuStats),
        ]
        for entry in subPhaseSamples {
            statsDict[entry.key] = snapshot(FrameStats.compute(entry.samples))
        }
        let report = makeReport(opts: opts, stats: statsDict)
        exit(finalizeReport(opts: opts, report: report))
    }
}

await VRMBenchmarkCLI.main()
