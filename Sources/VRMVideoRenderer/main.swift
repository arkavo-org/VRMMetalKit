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
import VRMMetalKit
import Metal
import MetalKit
import AVFoundation

// MARK: - Errors

enum VideoRenderError: Error {
    case failedToCreateDevice
    case failedToCreateTexture
    case failedToCreateRenderer
    case failedToLoadModel
    case failedToLoadAnimation
    case failedToCreateCommandQueue
    case videoEncodingFailed
    case missingArguments
    case fileNotFound(String)
}

// MARK: - Matrix Utilities

func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> matrix_float4x4 {
    let f = normalize(center - eye)
    let s = normalize(cross(f, up))
    let u = cross(s, f)
    
    var result = matrix_float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1))
    result.columns.0 = SIMD4<Float>(s.x, u.x, -f.x, 0)
    result.columns.1 = SIMD4<Float>(s.y, u.y, -f.y, 0)
    result.columns.2 = SIMD4<Float>(s.z, u.z, -f.z, 0)
    result.columns.3 = SIMD4<Float>(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)
    
    return result
}

func perspective(fovRadians: Float, aspect: Float, near: Float, far: Float) -> matrix_float4x4 {
    let tanHalfFov = tan(fovRadians / 2)
    
    var result = matrix_float4x4()
    result.columns.0 = SIMD4<Float>(1 / (aspect * tanHalfFov), 0, 0, 0)
    result.columns.1 = SIMD4<Float>(0, 1 / tanHalfFov, 0, 0)
    result.columns.2 = SIMD4<Float>(0, 0, -(far + near) / (far - near), -1)
    result.columns.3 = SIMD4<Float>(0, 0, -(2 * far * near) / (far - near), 0)
    
    return result
}

func orthographic(height: Float, aspect: Float, near: Float, far: Float) -> matrix_float4x4 {
    let width = height * aspect
    
    var result = matrix_float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1))
    result.columns.0.x = 2 / width
    result.columns.1.y = 2 / height
    result.columns.2.z = -2 / (far - near)
    result.columns.3.z = -(far + near) / (far - near)
    
    return result
}

// MARK: - Usage

func printUsage() {
    print("""
    VRMVideoRenderer - Render VRM + VRMA animation to video file
    
    USAGE:
        swift run VRMVideoRenderer <input.vrm> <input.vrma> <output.mov> [options]
    
    ARGUMENTS:
        <input.vrm>       Path to VRM model file
        <input.vrma>      Path to VRMA animation file
        <output.mov>      Output video file path
    
    OPTIONS:
        -w, --width <pixels>    Output width (default: 1920)
        -h, --height <pixels>   Output height (default: 1080)
        -f, --fps <fps>         Frames per second (default: 30)
        -d, --duration <secs>   Duration in seconds (default: 5.0)
        --orbit                 Enable orbiting camera
        --orbit-target <target> Orbit focus: face, hips, body (default: body)
        --ortho                 Use orthographic projection
        --hevc                  Use HEVC codec instead of H.264
        --root-motion           Enable root motion (hips translation)
        --dump-bones <path>     Write per-frame bone trajectory CSV alongside the .mov
        --dump-bones-filter <regex>
                                Regex on bone name to limit dump output (default: all)
        --outline-scale <float> Multiply every material's outlineWidthFactor by this
                                value. Default 1.0. Try 0.5 to soften toon outlines.
                                Use 0.0 for hero/portrait stills — the toon outline
                                pass renders dark silhouette edges on Face_SKIN that
                                read as "drawn-on decals" at 3/4 head profiles. Off
                                produces a cleaner profile at the cost of the cel
                                outline aesthetic.
        --hero-lighting         Use a softer 3-point lighting + lifted ambient for
                                hero/portrait shots instead of the cel-shading default.
                                Pair with `--outline-scale 0.0` for a clean stillshot.
        --help                  Show this help message

    EXAMPLES:
        swift run VRMVideoRenderer model.vrm anim.vrma output.mov
        swift run VRMVideoRenderer model.vrm anim.vrma output.mov --orbit --orbit-target face
        swift run VRMVideoRenderer model.vrm anim.vrma output.mov --orbit --orbit-target hips
        swift run VRMVideoRenderer model.vrm anim.vrma output.mov -w 1280 -h 720 -f 60
        # Hero/portrait still extracted from a video render:
        swift run VRMVideoRenderer model.vrm anim.vrma /tmp/hero.mov \\
            -w 2048 -h 2048 -f 30 -d 4 --hero-lighting --outline-scale 0.0
        ffmpeg -y -i /tmp/hero.mov -ss 2.5 -frames:v 1 -update 1 hero.png
    """)
}

// MARK: - Parse Arguments

enum OrbitTarget: String {
    case body, face, hips

    var centerY: Float {
        switch self {
        case .body: return 1.0
        case .face: return 1.45
        case .hips: return 0.85
        }
    }

    var radius: Float {
        switch self {
        case .body: return 3.0
        case .face: return 0.6
        case .hips: return 1.5
        }
    }
}

struct RenderOptions {
    var vrmPath: String = ""
    var vrmaPath: String = ""
    var outputPath: String = ""
    var width: Int = 1920
    var height: Int = 1080
    var fps: Int = 30
    var duration: Double = 5.0
    var orbitCamera: Bool = false
    var orbitTarget: OrbitTarget = .body
    var orthographic: Bool = false
    var hevc: Bool = false
    var rootMotion: Bool = false
    var handednessFix: Bool = true  // Enable by default
    var containerRotation: Bool = true  // Enable by default to fix "lying down" issue
    var dumpBonesPath: String? = nil
    var dumpBonesFilter: String? = nil
    var outlineScale: Float = 1.0
    var heroLighting: Bool = false
}

func parseArguments() -> RenderOptions? {
    let args = CommandLine.arguments
    
    if args.count < 2 || args.contains("--help") || args.contains("-?") {
        printUsage()
        return nil
    }
    
    guard args.count >= 4 else {
        print("Error: Missing required arguments")
        printUsage()
        return nil
    }
    
    var options = RenderOptions()
    options.vrmPath = args[1]
    options.vrmaPath = args[2]
    options.outputPath = args[3]
    
    var i = 4
    while i < args.count {
        let arg = args[i]
        
        switch arg {
        case "-w", "--width":
            i += 1
            if i < args.count, let val = Int(args[i]) {
                options.width = val
            }
        case "-h", "--height":
            i += 1
            if i < args.count, let val = Int(args[i]) {
                options.height = val
            }
        case "-f", "--fps":
            i += 1
            if i < args.count, let val = Int(args[i]) {
                options.fps = val
            }
        case "-d", "--duration":
            i += 1
            if i < args.count, let val = Double(args[i]) {
                options.duration = val
            }
        case "--orbit":
            options.orbitCamera = true
        case "--orbit-target":
            i += 1
            if i < args.count, let target = OrbitTarget(rawValue: args[i]) {
                options.orbitTarget = target
            } else {
                print("Warning: Invalid orbit target. Use: face, hips, body")
            }
        case "--ortho":
            options.orthographic = true
        case "--hevc":
            options.hevc = true
        case "--root-motion":
            options.rootMotion = true
        case "--dump-bones":
            i += 1
            if i < args.count { options.dumpBonesPath = args[i] }
        case "--dump-bones-filter":
            i += 1
            if i < args.count { options.dumpBonesFilter = args[i] }
        case "--outline-scale":
            i += 1
            if i < args.count, let val = Float(args[i]) {
                options.outlineScale = max(0, val)
            }
        case "--hero-lighting":
            options.heroLighting = true
        default:
            break
        }
        
        i += 1
    }
    
    return options
}

// MARK: - Pixel Buffer Helpers

func createPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    var pixelBuffer: CVPixelBuffer?
    let attrs: [String: Any] = [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
    ]
    
    CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attrs as CFDictionary,
        &pixelBuffer
    )
    
    return pixelBuffer
}

func copyTextureToPixelBuffer(_ texture: MTLTexture, to pixelBuffer: CVPixelBuffer, device: MTLDevice, commandBuffer: MTLCommandBuffer) {
    guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
        return
    }
    
    // Use getBytes instead of blit encoder for raw memory access
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)!
    
    texture.getBytes(
        baseAddress,
        bytesPerRow: bytesPerRow,
        from: MTLRegionMake2D(0, 0, texture.width, texture.height),
        mipmapLevel: 0
    )
}

// MARK: - Main

struct VRMVideoRendererCLI {
    @MainActor
    static func main() async {
        guard let options = parseArguments() else {
            exit(0)
        }
        
        // Validate input files
        guard FileManager.default.fileExists(atPath: options.vrmPath) else {
            print("❌ Error: VRM file not found: \(options.vrmPath)")
            exit(1)
        }
        
        guard FileManager.default.fileExists(atPath: options.vrmaPath) else {
            print("❌ Error: VRMA file not found: \(options.vrmaPath)")
            exit(1)
        }
        
        do {
            try await renderVideo(options: options)
            exit(0)
        } catch {
            print("❌ Error: \(error)")
            exit(1)
        }
    }
    
    @MainActor
    static func renderVideo(options: RenderOptions) async throws {
        print("🎬 VRM Video Renderer")
        print("   Model: \(options.vrmPath)")
        print("   Animation: \(options.vrmaPath)")
        print("   Output: \(options.outputPath)")
        print("   Resolution: \(options.width)x\(options.height) @ \(options.fps)fps for \(options.duration)s")
        print("")
        
        // Setup Metal
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw VideoRenderError.failedToCreateDevice
        }
        
        // Load VRM model
        print("📦 Loading VRM model...")
        let modelURL = URL(fileURLWithPath: options.vrmPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        print("   ✅ Loaded: \(model.meta.name ?? "Unnamed")")

        // Optionally scale every MToon material's outline width
        if options.outlineScale != 1.0 {
            var scaled = 0
            for material in model.materials {
                guard var mtoon = material.mtoon else { continue }
                mtoon.outlineWidthFactor *= options.outlineScale
                material.mtoon = mtoon
                scaled += 1
            }
            print("   ✏️  outlineWidthFactor scaled by \(options.outlineScale) on \(scaled) MToon materials")
        }
        
        // Load VRMA animation
        print("🎞️  Loading VRMA animation...")
        let animURL = URL(fileURLWithPath: options.vrmaPath)
        let animationClip = try VRMAnimationLoader.loadVRMA(from: animURL, model: model)
        print("   ✅ Loaded: VRMA (\(String(format: "%.2f", animationClip.duration))s, \(animationClip.jointTracks.count) joints)")
        
        // VRMRenderer automatically handles VRM 1.0 vs 0.0 facing via vrmVersionRotation
        print("   🔄 VRM version: \(model.isVRM0 ? "0.0" : "1.0") (renderer handles facing automatically)")
        
        // Setup animation player
        let player = AnimationPlayer()
        player.load(animationClip)
        player.applyRootMotion = options.rootMotion
        player.play()
        
        print("   🎬 Animation: rootMotion=\(options.rootMotion)")
        
        // Setup renderer
        print("🎨 Setting up renderer...")
        var config = RendererConfig()
        config.sampleCount = 4  // Enable 4x MSAA for alpha-to-coverage on MASK materials
        config.strict = .off

        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.enableSpringBone = true

        // Set up lighting
        if options.heroLighting {
            // Hero/portrait setup: 3-point with soft fill and lifted ambient.
            // Key: front-right, slightly warm.
            renderer.setLight(0, direction: SIMD3<Float>(0.3, -0.3, -0.85),
                              color: SIMD3<Float>(1.0, 0.97, 0.92), intensity: 1.0)
            // Fill: front-left, cool, half-strength.
            renderer.setLight(1, direction: SIMD3<Float>(-0.5, -0.1, -0.85),
                              color: SIMD3<Float>(0.85, 0.9, 1.0), intensity: 0.55)
            // Rim: behind, slightly warm, edge highlight.
            renderer.setLight(2, direction: SIMD3<Float>(0.0, -0.4, 0.85),
                              color: SIMD3<Float>(1.0, 0.95, 0.9), intensity: 0.4)
            renderer.setAmbientColor(SIMD3<Float>(0.18, 0.18, 0.2))
            print("   💡 Lighting: hero (3-point, lifted ambient)")
        } else {
            // Default cel-shading: hard step shadows, dark ambient.
            renderer.setLight(0, direction: SIMD3<Float>(-0.2, 0.5, -0.85),
                              color: SIMD3<Float>(1.0, 1.0, 1.0), intensity: 1.0)
            renderer.disableLight(1)
            renderer.setLight(2, direction: SIMD3<Float>(0.0, 0.2, 1.0),
                              color: SIMD3<Float>(1.0, 1.0, 1.0), intensity: 0.3)
            renderer.setAmbientColor(SIMD3<Float>(0.03, 0.03, 0.05))
        }

        // Create resolve texture (final output, non-multisampled)
        // Use BGRA format to match AVFoundation's pixel buffer format (kCVPixelFormatType_32BGRA)
        let resolveDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: options.width,
            height: options.height,
            mipmapped: false
        )
        resolveDescriptor.usage = [.renderTarget, .shaderRead]
        resolveDescriptor.storageMode = .managed

        guard let resolveTexture = device.makeTexture(descriptor: resolveDescriptor) else {
            throw VideoRenderError.failedToCreateTexture
        }

        // Create multisample color texture for MSAA rendering
        let msaaColorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: options.width,
            height: options.height,
            mipmapped: false
        )
        msaaColorDescriptor.textureType = .type2DMultisample
        msaaColorDescriptor.sampleCount = config.sampleCount
        msaaColorDescriptor.usage = .renderTarget
        msaaColorDescriptor.storageMode = .private

        guard let msaaColorTexture = device.makeTexture(descriptor: msaaColorDescriptor) else {
            throw VideoRenderError.failedToCreateTexture
        }

        // Create multisample depth texture
        let msaaDepthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: options.width,
            height: options.height,
            mipmapped: false
        )
        msaaDepthDescriptor.textureType = .type2DMultisample
        msaaDepthDescriptor.sampleCount = config.sampleCount
        msaaDepthDescriptor.usage = .renderTarget
        msaaDepthDescriptor.storageMode = .private

        guard let msaaDepthTexture = device.makeTexture(descriptor: msaaDepthDescriptor) else {
            throw VideoRenderError.failedToCreateTexture
        }
        
        // Setup video writer
        print("📝 Setting up video encoder...")
        let videoWriter = try AVAssetWriter(url: URL(fileURLWithPath: options.outputPath), fileType: .mov)
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: options.hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: options.width,
            AVVideoHeightKey: options.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: options.width * options.height * 4,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false
        
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: options.width,
                kCVPixelBufferHeightKey as String: options.height
            ]
        )
        
        videoWriter.add(writerInput)
        videoWriter.startWriting()
        videoWriter.startSession(atSourceTime: .zero)
        
        // Render loop
        print("⏳ Rendering...")
        let startTime = Date()
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        let totalFrames = Int(options.duration * Double(options.fps))

        // Reuse a single command queue across the whole run. Creating one per
        // frame spawns a Metal driver thread per iteration, which accumulates
        // until the OS watchdog kills the process on long videos.
        guard let sharedCommandQueue = device.makeCommandQueue() else {
            throw VideoRenderError.failedToCreateCommandQueue
        }

        // Optional bone trajectory CSV dumper for physics-verification tests.
        let boneDumper: BoneTrajectoryDumper?
        if let path = options.dumpBonesPath {
            boneDumper = try BoneTrajectoryDumper(path: path, filterPattern: options.dumpBonesFilter)
            print("📈 Dumping bone trajectories to: \(path)")
            if let pattern = options.dumpBonesFilter {
                print("   Filter: \(pattern)")
            }
        } else {
            boneDumper = nil
        }

            for frameIndex in 0..<totalFrames {
                // Update animation
                player.update(deltaTime: 1.0 / Float(options.fps), model: model)
                
                // Update camera
                if options.orbitCamera {
                    let angle = Float(frameIndex) / Float(totalFrames) * 2.0 * Float.pi
                    let radius = options.orbitTarget.radius
                    let centerY = options.orbitTarget.centerY
                    renderer.viewMatrix = lookAt(
                        eye: SIMD3<Float>(sin(angle) * radius, centerY, cos(angle) * radius),
                        center: SIMD3<Float>(0, centerY, 0),
                        up: SIMD3<Float>(0, 1, 0)
                    )
                } else {
                    // Standard camera setup: at +Z looking towards origin
                    // VRM 0.0 gets 180° Y rotation, VRM 1.0 faces +Z natively
                    renderer.viewMatrix = lookAt(
                        eye: SIMD3<Float>(0, 1, 3),
                        center: SIMD3<Float>(0, 1, 0),
                        up: SIMD3<Float>(0, 1, 0)
                    )
                }
                
                // Set projection
                let aspectRatio = Float(options.width) / Float(options.height)
                if options.orthographic {
                    renderer.projectionMatrix = orthographic(height: 2.0, aspect: aspectRatio, near: 0.1, far: 100)
                } else {
                    renderer.projectionMatrix = perspective(fovRadians: Float.pi / 4, aspect: aspectRatio, near: 0.1, far: 100)
                }
                
                // Create pixel buffer (command queue hoisted above loop)
                guard let pixelBuffer = createPixelBuffer(width: options.width, height: options.height),
                      let commandBuffer = sharedCommandQueue.makeCommandBuffer() else {
                    continue
                }
                
                // Render pass with MSAA
                let renderPassDescriptor = MTLRenderPassDescriptor()
                renderPassDescriptor.colorAttachments[0].texture = msaaColorTexture
                renderPassDescriptor.colorAttachments[0].resolveTexture = resolveTexture
                renderPassDescriptor.colorAttachments[0].loadAction = .clear
                renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
                renderPassDescriptor.colorAttachments[0].storeAction = .multisampleResolve
                renderPassDescriptor.depthAttachment.texture = msaaDepthTexture
                renderPassDescriptor.depthAttachment.loadAction = .clear
                renderPassDescriptor.depthAttachment.clearDepth = 1.0
                renderPassDescriptor.depthAttachment.storeAction = .dontCare

                // Draw to MSAA texture (resolves to resolveTexture)
                renderer.drawOffscreenHeadless(
                    to: msaaColorTexture,
                    depth: msaaDepthTexture,
                    commandBuffer: commandBuffer,
                    renderPassDescriptor: renderPassDescriptor
                )
                
                commandBuffer.commit()
                
                // Wait for completion (can't use waitUntilCompleted in async context)
                while commandBuffer.status != .completed && commandBuffer.status != .error {
                    await Task.yield()
                }
                
                // Copy resolved texture to pixel buffer (CPU readback)
                copyTextureToPixelBuffer(resolveTexture, to: pixelBuffer, device: device, commandBuffer: commandBuffer)
                
                // Append frame
                let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
                
                // Wait until writer is ready
                while !writerInput.isReadyForMoreMediaData {
                    await Task.yield()
                }
                
                adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
                CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

                // Sample bone trajectories AFTER GPU completion. Note that
                // node.worldMatrix here reflects the writeBonesToNodes call that
                // ran at the start of this frame's draw — which consumed the
                // previous frame's physics snapshot. The 1-frame physics lag is
                // consistent across the run and acceptable for trajectory analysis.
                if let dumper = boneDumper {
                    let timeSeconds = Double(frameIndex) / Double(options.fps)
                    dumper.recordFrame(model: model, frameIndex: frameIndex, timeSeconds: timeSeconds)
                }

                // Progress
                if frameIndex % 30 == 0 || frameIndex == totalFrames - 1 {
                    let progress = Double(frameIndex + 1) / Double(totalFrames) * 100
                    let elapsed = Date().timeIntervalSince(startTime)
                    let currentFps = Double(frameIndex + 1) / elapsed
                    print("   📊 Progress: \(String(format: "%.1f", progress))% (\(frameIndex + 1)/\(totalFrames) frames, \(String(format: "%.1f", currentFps)) fps)")
                }
            }
            
        writerInput.markAsFinished()
        await videoWriter.finishWriting()
        boneDumper?.finish()

        let totalTime = Date().timeIntervalSince(startTime)
        print("")
        print("✅ Render complete!")
        print("   📁 Output: \(options.outputPath)")
        print("   ⏱️  Time: \(String(format: "%.2f", totalTime))s")
        print("   🎬 Average: \(String(format: "%.1f", Double(totalFrames) / totalTime)) fps")
    }
}

await VRMVideoRendererCLI.main()
