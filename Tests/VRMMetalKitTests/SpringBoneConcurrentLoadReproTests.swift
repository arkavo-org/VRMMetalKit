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
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd
@testable import VRMMetalKit

/// Opt-in reproduction harness for #452: a single synchronous-spring-bone
/// frame of a spring-haired avatar must hash identically on every run, even
/// while another process keeps the GPU busy.
///
/// Mirrors the vrm-conformance `avatarH_idle_t1p0` cell: fresh load with
/// collider augmentation, `synchronousSpringBone`, 4x MSAA into an sRGB
/// target, an idle VRMA sampled at t = 1.0, one headless frame.
///
/// - `VMK_452_REPRO_RUNS=N` runs the measurement loop N times and writes one
///   line per run (pixel hash, post-warmup and post-frame `bonePosCurr`
///   hashes, spring-joint node hash, pixels differing from run 0) to
///   `$VMK_452_OUT/runs.tsv`, plus PNGs of the first run and of every run
///   whose pixels differ from it, and a per-bone table for every run whose
///   bones differ. `VMK_452_REFERENCE_PNG` compares run 0 with a golden.
/// - `VMK_452_LOAD_SECONDS=S` instead renders a second avatar in a loop for S
///   seconds; run it in a separate process to supply the concurrent GPU load.
///
/// Fixtures: `VMK_452_MODEL`, `VMK_452_VRMA`, `VMK_452_LOAD_MODEL` (absolute
/// paths; the AvatarSample fixtures are gitignored).
@MainActor
final class SpringBoneConcurrentLoadReproTests: XCTestCase {

    private struct Env {
        static func string(_ key: String) -> String? {
            ProcessInfo.processInfo.environment[key].flatMap { $0.isEmpty ? nil : $0 }
        }
        static func int(_ key: String) -> Int? { string(key).flatMap(Int.init) }
    }

    private let size = 1024

    func testRepeatedSyncFrameHashesUnderLoad() async throws {
        guard let runs = Env.int("VMK_452_REPRO_RUNS"), runs > 0 else {
            throw XCTSkip("Set VMK_452_REPRO_RUNS to run the #452 repro loop")
        }
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }
        let modelPath = Env.string("VMK_452_MODEL") ?? "AvatarSample_H_1.0.vrm"
        let vrmaPath = Env.string("VMK_452_VRMA") ?? "VRMA_01.vrma"
        let outDir = URL(fileURLWithPath: Env.string("VMK_452_OUT") ?? NSTemporaryDirectory())
        guard FileManager.default.fileExists(atPath: modelPath),
              FileManager.default.fileExists(atPath: vrmaPath) else {
            throw XCTSkip("Fixtures not found: \(modelPath), \(vrmaPath)")
        }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var lines = ["run\tpixels\twarmupBones\tframeBones\tsnapshotBones\tdiffPixels"]
        var basePixels: [UInt8] = []
        var baseFrameBones: [SIMD3<Float>] = []
        var baseWarmupBones: [SIMD3<Float>] = []
        var pixelOutliers = 0
        var boneOutliers = 0
        var warmupOutliers = 0

        for run in 0..<runs {
            let result = try await renderCell(device: device, queue: queue,
                                              modelPath: modelPath, vrmaPath: vrmaPath)
            if run == 0 {
                basePixels = result.pixels
                baseFrameBones = result.frameBones
                baseWarmupBones = result.warmupBones
                try writePNG(result.pixels, to: outDir.appendingPathComponent("run0.png"))
                try describeChains(result, to: outDir.appendingPathComponent("chains.txt"))
                if let refPath = Env.string("VMK_452_REFERENCE_PNG"), let ref = readPNG(refPath) {
                    try "reference=\(refPath) differingPixels=\(differingPixels(ref, result.pixels))\n"
                        .write(to: outDir.appendingPathComponent("reference.txt"), atomically: true, encoding: .utf8)
                }
            }
            let diffPixels = differingPixels(result.pixels, basePixels)
            let pixelHash = sha(result.pixels)
            if result.pixels != basePixels {
                pixelOutliers += 1
                try writePNG(result.pixels, to: outDir.appendingPathComponent("run\(run).png"))
            }
            if result.frameBones != baseFrameBones {
                boneOutliers += 1
                try reportBoneDiff(base: baseFrameBones, other: result.frameBones, result: result,
                                   to: outDir.appendingPathComponent("run\(run)_frame_bones.txt"))
            }
            if result.warmupBones != baseWarmupBones {
                warmupOutliers += 1
                try reportBoneDiff(base: baseWarmupBones, other: result.warmupBones, result: result,
                                   to: outDir.appendingPathComponent("run\(run)_warmup_bones.txt"))
            }
            lines.append("\(run)\t\(pixelHash)\t\(sha(result.warmupBones))\t\(sha(result.frameBones))\t\(sha(result.snapshotBones))\t\(diffPixels)")
            try (lines.joined(separator: "\n") + "\n")
                .write(to: outDir.appendingPathComponent("runs.tsv"), atomically: true, encoding: .utf8)
        }
        let summary = "runs=\(runs) pixelOutliers=\(pixelOutliers) frameBoneOutliers=\(boneOutliers) warmupBoneOutliers=\(warmupOutliers)"
        try summary.write(to: outDir.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
        print("[#452] \(summary)")
    }

    func testConcurrentGPULoadGenerator() async throws {
        guard let seconds = Env.int("VMK_452_LOAD_SECONDS"), seconds > 0 else {
            throw XCTSkip("Set VMK_452_LOAD_SECONDS to run the #452 load generator")
        }
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }
        let modelPath = Env.string("VMK_452_LOAD_MODEL") ?? "AvatarSample_A_1.0.vrm.glb"
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw XCTSkip("Load model not found: \(modelPath)")
        }
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        var frames = 0
        while Date() < deadline {
            let model = try await VRMModel.load(from: URL(fileURLWithPath: modelPath), device: device)
            let renderer = makeRenderer(device: device, model: model)
            for _ in 0..<60 where Date() < deadline {
                _ = try renderFrame(renderer: renderer, device: device, queue: queue)
                frames += 1
            }
        }
        print("[#452] load generator rendered \(frames) frames")
    }

    // MARK: - Cell

    private struct CellResult {
        let pixels: [UInt8]
        let warmupBones: [SIMD3<Float>]
        let frameBones: [SIMD3<Float>]
        let snapshotBones: [SIMD3<Float>]
        let chainRanges: [Range<Int>]
        let parentIndices: [UInt32]
        let chainNames: [String]
    }

    private func makeRenderer(device: MTLDevice, model: VRMModel) -> VRMRenderer {
        var config = RendererConfig()
        config.sampleCount = 4
        config.strict = .off
        config.synchronousSpringBone = true
        config.colorPixelFormat = .rgba8Unorm_srgb
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.enableSpringBone = true
        let fov: Float = 30.0
        let tanHalfFov = tan(fov * .pi / 180.0 / 2)
        let near: Float = 0.01
        let far: Float = 100.0
        renderer.projectionMatrix = float4x4(columns: (
            SIMD4<Float>(1 / tanHalfFov, 0, 0, 0),
            SIMD4<Float>(0, 1 / tanHalfFov, 0, 0),
            SIMD4<Float>(0, 0, -(far + near) / (far - near), -1),
            SIMD4<Float>(0, 0, -(2 * far * near) / (far - near), 0)))
        let eye = SIMD3<Float>(0, 0.9, 3.2)
        let f = normalize(SIMD3<Float>(0, 0.8, 0) - eye)
        let s = normalize(cross(f, SIMD3<Float>(0, 1, 0)))
        let u = cross(s, f)
        renderer.viewMatrix = float4x4(columns: (
            SIMD4<Float>(s.x, u.x, -f.x, 0),
            SIMD4<Float>(s.y, u.y, -f.y, 0),
            SIMD4<Float>(s.z, u.z, -f.z, 0),
            SIMD4<Float>(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)))
        renderer.setLight(0, direction: SIMD3<Float>(-0.3, -0.6, -0.7),
                          color: SIMD3<Float>(1, 1, 1), intensity: 1)
        renderer.disableLight(1)
        renderer.disableLight(2)
        renderer.setAmbientColor(SIMD3<Float>(repeating: 0.5 * 0.3))
        return renderer
    }

    private func renderCell(device: MTLDevice, queue: MTLCommandQueue,
                            modelPath: String, vrmaPath: String) async throws -> CellResult {
        let model = try await VRMModel.load(
            from: URL(fileURLWithPath: modelPath), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        let renderer = makeRenderer(device: device, model: model)
        let warmupBones = readBones(model.springBoneBuffers?.bonePosCurr, count: model.springBoneBuffers?.numBones ?? 0)

        let clip = try VRMAnimationLoader.loadVRMA(from: URL(fileURLWithPath: vrmaPath), model: model)
        let time: Float = 1.0
        for track in clip.jointTracks {
            let (rot, trans, _) = track.sample(at: time)
            if let rot { model.setLocalRotation(rot, for: track.bone) }
            if let trans, track.bone == .hips { model.setHipsTranslation(trans) }
        }
        if let controller = renderer.expressionController {
            var presetNames = Set<String>()
            for track in clip.expressionTracks {
                controller.setExpressionWeight(track.expression, weight: track.sample(at: time))
                presetNames.insert(track.expression.rawValue)
            }
            for track in clip.morphTracks where !presetNames.contains(track.key) {
                let w = track.sample(at: time)
                if let preset = VRMExpressionPreset(rawValue: track.key) {
                    controller.setExpressionWeight(preset, weight: w)
                } else {
                    controller.setCustomExpressionWeight(track.key, weight: w)
                }
            }
        }
        if let sampler = clip.lookAtTargetSampler {
            renderer.lookAtController?.target = .headLocalPoint(sampler(time))
            renderer.lookAtController?.applyImmediately()
        }

        let pixels = try renderFrame(renderer: renderer, device: device, queue: queue)
        let buffers = model.springBoneBuffers
        let frameBones = readBones(buffers?.bonePosCurr, count: buffers?.numBones ?? 0)
        let snapshotBones = springJointWorldPositions(model: model)
        var parents: [UInt32] = []
        if let params = buffers?.boneParams, let n = buffers?.numBones, n > 0 {
            let p = params.contents().bindMemory(to: BoneParams.self, capacity: n)
            parents = (0..<n).map { p[$0].parentIndex }
        }
        let roots = parents.indices.filter { parents[$0] == UInt32.max }
        let ranges = roots.indices.map { i in
            roots[i]..<(i + 1 < roots.count ? roots[i + 1] : parents.count)
        }
        let names = (model.springBone?.springs ?? []).filter { !$0.joints.isEmpty }.map { spring in
            (spring.joints.first.flatMap { model.nodes[safe: $0.node]?.name }) ?? "?"
        }
        return CellResult(pixels: pixels, warmupBones: warmupBones, frameBones: frameBones,
                          snapshotBones: snapshotBones, chainRanges: ranges, parentIndices: parents,
                          chainNames: names)
    }

    private func renderFrame(renderer: VRMRenderer, device: MTLDevice,
                             queue: MTLCommandQueue) throws -> [UInt8] {
        let msColorDesc = MTLTextureDescriptor()
        msColorDesc.textureType = .type2DMultisample
        msColorDesc.pixelFormat = .rgba8Unorm_srgb
        msColorDesc.width = size
        msColorDesc.height = size
        msColorDesc.sampleCount = 4
        msColorDesc.usage = [.renderTarget]
        msColorDesc.storageMode = .private
        let resolveDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb, width: size, height: size, mipmapped: false)
        resolveDesc.usage = [.renderTarget, .shaderRead]
        resolveDesc.storageMode = .shared
        let depthDesc = MTLTextureDescriptor()
        depthDesc.textureType = .type2DMultisample
        depthDesc.pixelFormat = .depth32Float
        depthDesc.width = size
        depthDesc.height = size
        depthDesc.sampleCount = 4
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private
        guard let msColor = device.makeTexture(descriptor: msColorDesc),
              let resolve = device.makeTexture(descriptor: resolveDesc),
              let msDepth = device.makeTexture(descriptor: depthDesc),
              let commandBuffer = queue.makeCommandBuffer() else {
            throw XCTSkip("Could not allocate render resources")
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = msColor
        rpd.colorAttachments[0].resolveTexture = resolve
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .multisampleResolve
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 0, blue: 1, alpha: 1)
        rpd.depthAttachment.texture = msDepth
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.storeAction = .dontCare
        rpd.depthAttachment.clearDepth = 1.0

        renderer.drawOffscreenHeadless(to: msColor, depth: msDepth,
                                       commandBuffer: commandBuffer, renderPassDescriptor: rpd)
        let done = DispatchSemaphore(value: 0)
        commandBuffer.addCompletedHandler { _ in done.signal() }
        commandBuffer.commit()
        done.wait()

        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        pixels.withUnsafeMutableBytes { raw in
            resolve.getBytes(raw.baseAddress!, bytesPerRow: size * 4,
                             from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        }
        return pixels
    }

    // MARK: - Diagnostics

    private func readBones(_ buffer: MTLBuffer?, count: Int) -> [SIMD3<Float>] {
        guard let buffer, count > 0 else { return [] }
        let p = buffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: count)
        return Array(UnsafeBufferPointer(start: p, count: count))
    }

    private func springJointWorldPositions(model: VRMModel) -> [SIMD3<Float>] {
        guard let springBone = model.springBone else { return [] }
        var out: [SIMD3<Float>] = []
        for spring in springBone.springs {
            for joint in spring.joints {
                out.append(model.nodes[safe: joint.node]?.worldPosition ?? SIMD3<Float>(repeating: .nan))
            }
        }
        return out
    }

    private func differingPixels(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count else { return -1 }
        return stride(from: 0, to: a.count, by: 4).filter { a[$0..<$0 + 4] != b[$0..<$0 + 4] }.count
    }

    private func sha<T>(_ values: [T]) -> String {
        values.withUnsafeBytes { raw in
            SHA256.hash(data: raw).prefix(6).map { String(format: "%02x", $0) }.joined()
        }
    }

    private func describeChains(_ result: CellResult, to url: URL) throws {
        var text = "numBones=\(result.frameBones.count) chains=\(result.chainRanges.count)\n"
        for (i, r) in result.chainRanges.enumerated() {
            let straddles = (r.lowerBound / 32) != ((r.upperBound - 1) / 32)
            let name = i < result.chainNames.count ? result.chainNames[i] : "?"
            text += "chain \(i): \(r.lowerBound)..<\(r.upperBound) \(name)\(straddles ? "  STRADDLES-32" : "")\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func reportBoneDiff(base: [SIMD3<Float>], other: [SIMD3<Float>],
                                result: CellResult, to url: URL) throws {
        var text = "bone\tchain\tmod32\tparent\t|delta|\n"
        for i in 0..<min(base.count, other.count) where base[i] != other[i] {
            let chain = result.chainRanges.firstIndex { $0.contains(i) } ?? -1
            let parent = i < result.parentIndices.count ? Int(Int32(bitPattern: result.parentIndices[i])) : -2
            text += "\(i)\t\(chain)\t\(i % 32)\t\(parent)\t\(simd_length(base[i] - other[i]))\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func readPNG(_ path: String) -> [UInt8]? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var out = [UInt8](repeating: 0, count: size * size * 4)
        let ok = out.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setBlendMode(.copy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        return ok ? out : nil
    }

    private func writePNG(_ pixels: [UInt8], to url: URL) throws {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
