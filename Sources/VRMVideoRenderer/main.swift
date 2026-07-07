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
    case commandBufferFailed(frame: Int, message: String)
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
        --silhouette            Render avatar as a pure-black silhouette
                                with an additive directional rim
        --rim-power <float>     Fresnel exponent for silhouette rim
                                (typical 4..12, default: 5)
        --crowd                 Render multiple avatars approaching/touching
        --avatar-count N        Avatars in the crowd (default 2)
        --crowd-start-sep M     Start half-separation in meters (default 1.0)
        --crowd-hold-sep M      Hold half-separation in meters (default 0.18)
        --crowd-no-contact      Disable cross-avatar collision (before/after baseline)
        --body-contact-margin M Contact-aware motion: cap torso overlap at M meters
                                (bodies press to contact instead of clipping through)
        --postural              Postural yield: upper body leans away on contact
        --stagger               Stagger shove: contact displaces the CoM and a
                                capture step keeps the avatar upright (crowd only)
        --stagger-gain G        Override the shove gain (metres of CoM offset per
                                metre of penetration; default 6.0)
        --spring-gravity <M>    Downward spring-bone gravity (app-layer). Auto-applied
                                to rigs that author none (e.g. AvatarSample); 0 disables.
        --realtime              Use the async spring path a live app uses (sleep gate live)
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
    var silhouette: Bool = false
    var rimPower: Float = 5.0
    var crowd: Bool = false
    var avatarCount: Int = 2
    var crowdStartSep: Float = 1.0      // half-separation at start (meters)
    var crowdHoldSep: Float = 0.18      // half-separation at hold (the tunable half of the coupled pair)
    var crowdNoContact: Bool = false
    var crowdRealtime: Bool = false     // async spring path (sleep gate live), the path a live app uses
    var bodyContactMargin: Float? = nil // Component A: contact-aware clamp (nil = off)
    var postural: Bool = false          // Component B: postural yield
    var stagger: Bool = false           // stagger shove + capture step (design 2026-07-07)
    var staggerGain: Float? = nil       // shoveGain override (calibration knob)
    var springGravity: Float? = nil     // Override app-layer spring gravity (nil = auto)
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
        case "--silhouette":
            options.silhouette = true
        case "--rim-power":
            i += 1
            if i < args.count, let val = Float(args[i]) {
                options.rimPower = max(0, val)
            }
        case "--crowd":
            options.crowd = true
        case "--avatar-count":
            i += 1; guard i < args.count else { return nil }
            options.avatarCount = max(2, Int(args[i]) ?? 2)
        case "--crowd-start-sep":
            i += 1; guard i < args.count else { return nil }
            options.crowdStartSep = Float(args[i]) ?? options.crowdStartSep
        case "--crowd-hold-sep":
            i += 1; guard i < args.count else { return nil }
            options.crowdHoldSep = Float(args[i]) ?? options.crowdHoldSep
        case "--crowd-no-contact":
            options.crowdNoContact = true
        case "--body-contact-margin":
            i += 1; guard i < args.count else { return nil }
            options.bodyContactMargin = Float(args[i]) ?? options.bodyContactMargin
        case "--postural":
            options.postural = true
        case "--stagger":
            options.stagger = true
        case "--stagger-gain":
            i += 1; guard i < args.count else { return nil }
            options.staggerGain = Float(args[i]) ?? options.staggerGain
        case "--spring-gravity":
            i += 1; guard i < args.count else { return nil }
            options.springGravity = Float(args[i]) ?? options.springGravity
        case "--realtime":
            options.crowdRealtime = true
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

// MARK: - Spring-bone gravity default (app-layer)

/// Magnitude of the default downward spring gravity supplied to rigs that author
/// no per-joint gravity. `globalParams.gravity` is spec-additive (default zero);
/// a real app is expected to set it, just like lighting.
private let autoSpringGravity: Float = 2.0

/// Supply the app-layer spring gravity a real host would set. VRM rigs that
/// author `gravityPower == 0` on every joint (the AvatarSample family, for one)
/// have NO downward force, so hair settles to its bind direction — which for a
/// high ponytail points straight UP. This gives such rigs a sane default so hair
/// hangs naturally, while respecting rigs that DID author gravity (adding to them
/// would double their droop). `--spring-gravity X` overrides for any rig; `0`
/// disables. Mirrors the design intent of `globalParams.gravity` (VMK#324): an
/// additive external force the application, not the loader, provides.
func applySpringGravityDefault(model: VRMModel, options: RenderOptions) {
    let magnitude: Float
    if let override = options.springGravity {
        magnitude = override
    } else {
        let maxAuthored = (model.springBone?.springs ?? [])
            .flatMap { $0.joints }.map { $0.gravityPower }.max() ?? 0
        magnitude = maxAuthored < 0.001 ? autoSpringGravity : 0
    }
    guard magnitude > 0 else { return }
    model.springBoneGlobalParams?.gravity = SIMD3<Float>(0, -magnitude, 0)
}

/// Hero/portrait lighting: 3-point (key + cool fill + warm rim) with lifted
/// ambient. Shared by the single-avatar `--hero-lighting` path and the crowd
/// path (which otherwise inherits the renderer's dark cel default).
func applyHeroLighting(to renderer: VRMRenderer) {
    renderer.setLight(0, direction: SIMD3<Float>(0.3, -0.3, -0.85),
                      color: SIMD3<Float>(1.0, 0.97, 0.92), intensity: 1.0)
    renderer.setLight(1, direction: SIMD3<Float>(-0.5, -0.1, -0.85),
                      color: SIMD3<Float>(0.85, 0.9, 1.0), intensity: 0.55)
    renderer.setLight(2, direction: SIMD3<Float>(0.0, -0.4, 0.85),
                      color: SIMD3<Float>(1.0, 0.95, 0.9), intensity: 0.4)
    renderer.setAmbientColor(SIMD3<Float>(0.18, 0.18, 0.2))
    renderer.setLightNormalizationMode(.radiometric)
}

// MARK: - Video Pipeline

/// The MSAA render targets, AVAssetWriter, and command queue shared by both
/// the single-avatar and crowd render loops.
struct VideoPipeline {
    let resolveTexture: MTLTexture
    let msaaColorTexture: MTLTexture
    let msaaDepthTexture: MTLTexture
    let videoWriter: AVAssetWriter
    let writerInput: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let sharedCommandQueue: MTLCommandQueue
    let frameDuration: CMTime
    let totalFrames: Int
}

func makeVideoPipeline(options: RenderOptions, device: MTLDevice, sampleCount: Int) throws -> VideoPipeline {
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
    msaaColorDescriptor.sampleCount = sampleCount
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
    msaaDepthDescriptor.sampleCount = sampleCount
    msaaDepthDescriptor.usage = .renderTarget
    msaaDepthDescriptor.storageMode = .private

    guard let msaaDepthTexture = device.makeTexture(descriptor: msaaDepthDescriptor) else {
        throw VideoRenderError.failedToCreateTexture
    }

    // Setup video writer
    print("📝 Setting up video encoder...")
    let outputURL = URL(fileURLWithPath: options.outputPath)
    // AVAssetWriter.init throws if the path already exists; remove first.
    if FileManager.default.fileExists(atPath: options.outputPath) {
        try FileManager.default.removeItem(at: outputURL)
    }
    let videoWriter = try AVAssetWriter(url: outputURL, fileType: .mov)

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
    guard videoWriter.startWriting() else {
        throw VideoRenderError.videoEncodingFailed
    }
    videoWriter.startSession(atSourceTime: .zero)

    let frameDuration = CMTime(value: 1, timescale: CMTimeScale(options.fps))
    let totalFrames = Int(options.duration * Double(options.fps))

    // Reuse a single command queue across the whole run. Creating one per
    // frame spawns a Metal driver thread per iteration, which accumulates
    // until the OS watchdog kills the process on long videos.
    guard let sharedCommandQueue = device.makeCommandQueue() else {
        throw VideoRenderError.failedToCreateCommandQueue
    }

    return VideoPipeline(
        resolveTexture: resolveTexture,
        msaaColorTexture: msaaColorTexture,
        msaaDepthTexture: msaaDepthTexture,
        videoWriter: videoWriter,
        writerInput: writerInput,
        adaptor: adaptor,
        sharedCommandQueue: sharedCommandQueue,
        frameDuration: frameDuration,
        totalFrames: totalFrames
    )
}

// MARK: - Crowd Setup

/// Build N avatars, wire a contact group, and drive `CrowdFrameStepper` into the
/// existing MSAA -> pixelBuffer -> AVAssetWriter pipeline.
func buildCrowd(modelURL: URL, animURL: URL, device: MTLDevice,
                options: RenderOptions) async throws -> (CrowdFrameStepper, SpringBoneContactGroup?) {
    var config = RendererConfig()
    // Default: synchronous spring path (deterministic, sleep gate off). With
    // --realtime, use the async path a live app uses: spring compute piped into
    // the shared command buffer, one-frame readback lag, and the sleep gate LIVE
    // (so F1 — waking a settled avatar to an approaching partner — is exercised).
    config.synchronousSpringBone = !options.crowdRealtime
    config.sampleCount = 4

    let group: SpringBoneContactGroup? = options.crowdNoContact ? nil : SpringBoneContactGroup()
    var avatars: [CrowdFrameStepper.Avatar] = []
    let aspect = Float(options.width) / Float(options.height)

    for index in 0..<options.avatarCount {
        let model = try await VRMModel.load(from: modelURL, device: device, options: VRMLoadingOptions())
        // Bake inward facing once (design §4.1) via T/R/S — never localMatrix.
        for root in model.nodes where root.parent == nil {
            root.rotation = CrowdPlacement.facing(avatarIndex: index, avatarCount: options.avatarCount)
        }
        model.updateNodeTransforms()

        let renderer = VRMRenderer(device: device, config: config)
        // --realtime uses the async spring path (synchronousSpringBone=false),
        // whose dt defaults to WALL-CLOCK — meaningless for an offline render that
        // runs at hundreds of fps (springs would advance ~3ms while animation
        // advances 1/fps, yanking hair/cloth without damping = permanent flaring).
        // Pin the async path to frame-time dt so the offline video is correctly
        // timed while still exercising the async code path (sleep gate, one-frame lag).
        if options.crowdRealtime {
            renderer.simulationDeltaTime = TimeInterval(1.0 / Double(options.fps))
        }
        renderer.loadModelWithoutWarmup(model)
        renderer.enableSpringBone = true
        renderer.projectionMatrix = options.orthographic
            ? orthographic(height: 2.0, aspect: aspect, near: 0.1, far: 100)
            : perspective(fovRadians: Float.pi / 4, aspect: aspect, near: 0.1, far: 100)

        let clip = try VRMAnimationLoader.loadVRMA(from: animURL, model: model)
        let player = AnimationPlayer(); player.load(clip); player.play()

        // Apply the first animation frame BEFORE warming up SpringBone physics.
        // Mirrors the single-avatar path: warming up against the bind pose makes
        // springs settle at rest and then snap when frame 0 is applied, causing
        // the hair/cloth pop artifact (#351).
        player.update(deltaTime: 0, model: model)
        applySpringGravityDefault(model: model, options: options)
        renderer.warmupPhysics(steps: 30)

        // The crowd path (unlike renderVideo) sets no lights, so it fell back to
        // the renderer's dark cel default. Give it the hero 3-point + lifted
        // ambient so the composite reads clearly.
        applyHeroLighting(to: renderer)

        if let group { renderer.joinContactGroup(group) }
        avatars.append(CrowdFrameStepper.Avatar(renderer: renderer, model: model, player: player, index: index))
    }

    let driver = CrowdMotionDriver(
        startSep: options.crowdStartSep, holdSep: options.crowdHoldSep,
        approachStart: 0.1, approachEnd: 0.4, holdEnd: 0.7, partEnd: 0.95)
    let postural: PosturalContactParams? = options.postural ? PosturalContactParams() : nil
    var stagger: StaggerShoveParams? = nil
    if options.stagger {
        var p = StaggerShoveParams()
        if let gain = options.staggerGain { p.shoveGain = gain }
        stagger = p
    }
    return (CrowdFrameStepper(avatars: avatars, driver: driver, group: group, fps: Float(options.fps),
                              bodyContactMargin: options.bodyContactMargin, postural: postural,
                              stagger: stagger), group)
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

        if options.crowd {
            try await renderCrowd(options: options, device: device)
            return
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
        config.synchronousSpringBone = true  // offline render — no interactivity penalty (#267)

        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModelWithoutWarmup(model)

        // Apply the first animation frame BEFORE warming up SpringBone physics.
        // VRMRenderer.loadModel calls warmupPhysics against the current skeleton
        // pose; if the model is still in bind pose, the springs settle at rest and
        // then snap when the first rendered frame jumps to frame 0. This causes
        // hair/penetration artifacts on models like AvatarSample_A (see #351).
        player.update(deltaTime: 0, model: model)
        applySpringGravityDefault(model: model, options: options)
        renderer.warmupPhysics(steps: 30)
        renderer.enableSpringBone = true

        // Set up lighting
        if options.silhouette {
            var sil = SilhouetteRenderConfig()
            sil.rimFresnelPower = options.rimPower
            renderer.applySilhouetteMode(model: model, config: sil)
            print("   🌒 Silhouette mode (rim power \(options.rimPower))")
        } else if options.heroLighting {
            // Hero/portrait setup: 3-point with soft fill and lifted ambient.
            // .radiometric (factor π) cancels the shader's BRDF_LAMBERT_NORM (1/π),
            // so authored intensities pass through unscaled — same effective brightness
            // as the pre-radiometric setup.
            applyHeroLighting(to: renderer)
            print("   💡 Lighting: hero (3-point, lifted ambient)")
        } else {
            // Default cel-shading: hard step shadows, dark ambient.
            // .radiometric cancels the shader's BRDF_LAMBERT_NORM (1/π) so
            // intensity passes through; matches v0.10.0 brightness exactly.
            renderer.setLight(0, direction: SIMD3<Float>(-0.2, 0.5, -0.85),
                              color: SIMD3<Float>(1.0, 1.0, 1.0), intensity: 1.0)
            renderer.disableLight(1)
            renderer.setLight(2, direction: SIMD3<Float>(0.0, 0.2, 1.0),
                              color: SIMD3<Float>(1.0, 1.0, 1.0), intensity: 0.3)
            renderer.setAmbientColor(SIMD3<Float>(0.03, 0.03, 0.05))
            renderer.setLightNormalizationMode(.radiometric)
        }

        let pipeline = try makeVideoPipeline(options: options, device: device, sampleCount: config.sampleCount)
        let resolveTexture = pipeline.resolveTexture
        let msaaColorTexture = pipeline.msaaColorTexture
        let msaaDepthTexture = pipeline.msaaDepthTexture
        let videoWriter = pipeline.videoWriter
        let writerInput = pipeline.writerInput
        let adaptor = pipeline.adaptor
        let sharedCommandQueue = pipeline.sharedCommandQueue
        let frameDuration = pipeline.frameDuration
        let totalFrames = pipeline.totalFrames

        // Drive VRM gaze so bone-mode eyes compose onto their authored rest
        // rotation each frame (without a controller the eye bones never get set,
        // leaving VRoid/AvatarSample eyes in a broken/blank state).
        let lookAtController = VRMLookAtController()
        lookAtController.setup(model: model, expressionController: renderer.expressionController)
        lookAtController.saccadeEnabled = false
        lookAtController.target = .forward

        // Render loop
        print("⏳ Rendering...")
        let startTime = Date()

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
                lookAtController.applyImmediately()

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

    @MainActor
    static func renderCrowd(options: RenderOptions, device: MTLDevice) async throws {
        print("👥 Crowd mode: \(options.avatarCount) avatars, contact=\(!options.crowdNoContact)")
        print("   Model: \(options.vrmPath)")
        print("   Animation: \(options.vrmaPath)")
        print("   Output: \(options.outputPath)")
        print("   Resolution: \(options.width)x\(options.height) @ \(options.fps)fps for \(options.duration)s")
        print("")

        let modelURL = URL(fileURLWithPath: options.vrmPath)
        let animURL = URL(fileURLWithPath: options.vrmaPath)

        print("📦 Loading \(options.avatarCount) avatar instances...")
        let (stepper, group) = try await buildCrowd(modelURL: modelURL, animURL: animURL, device: device, options: options)
        print("   ✅ Crowd built (\(group == nil ? "no contact group" : "joined contact group"))")

        // Per-avatar gaze: drive each avatar's eyes to a forward rest each frame
        // so bone-mode eyes compose onto their authored rest rotation (without it,
        // VRoid/AvatarSample eyes render blank — same fix as the single path).
        let lookAtControllers: [VRMLookAtController] = stepper.avatarsForCamera.map { av in
            let c = VRMLookAtController()
            c.setup(model: av.model, expressionController: av.renderer.expressionController)
            c.saccadeEnabled = false
            c.target = .forward
            return c
        }

        print("🎨 Setting up video pipeline...")
        let pipeline = try makeVideoPipeline(options: options, device: device, sampleCount: 4)

        // Render loop
        print("⏳ Rendering crowd...")
        let startTime = Date()
        let totalFrames = pipeline.totalFrames

        for frameIndex in 0..<totalFrames {
            let t = totalFrames > 1 ? Float(frameIndex) / Float(totalFrames - 1) : 0

            // Shared camera for all avatars (orbit or fixed), applied before stepping.
            let view: float4x4
            // Ring radius (N>=3) is set by the start separation, not the avatar
            // count — more avatars pack denser onto the same ring.
            let ringRadius = options.crowdStartSep
            if options.orbitCamera {
                let angle = Float(frameIndex) / Float(totalFrames) * 2.0 * Float.pi
                let radius = max(options.orbitTarget.radius, ringRadius * 2.8 + 1.0)
                let cy = options.orbitTarget.centerY
                view = lookAt(eye: SIMD3<Float>(sin(angle) * radius, cy, cos(angle) * radius),
                              center: SIMD3<Float>(0, cy, 0), up: SIMD3<Float>(0, 1, 0))
            } else if options.avatarCount >= 3 {
                // Ring: frame the full diameter + avatar height, raised and
                // tilted down to see into the cluster (the line heuristic
                // under-frames a ring).
                let dist = max(3.0, ringRadius * 3.5 + 1.5)
                view = lookAt(eye: SIMD3<Float>(0, 2.0, dist), center: SIMD3<Float>(0, 1.0, 0), up: SIMD3<Float>(0, 1, 0))
            } else {
                // Two avatars on a line at ∓startSep.
                let dist = max(2.5, Float(options.avatarCount) * options.crowdStartSep * 1.1)
                view = lookAt(eye: SIMD3<Float>(0, 1.3, dist), center: SIMD3<Float>(0, 1.3, 0), up: SIMD3<Float>(0, 1, 0))
            }
            for av in stepper.avatarsForCamera { av.renderer.viewMatrix = view }

            stepper.step(frameTime: t)
            // Gaze after the pose/exchange step, before compositing (eyes don't
            // affect the contact snapshot).
            for c in lookAtControllers { c.applyImmediately() }

            guard let pixelBuffer = createPixelBuffer(width: options.width, height: options.height),
                  let commandBuffer = pipeline.sharedCommandQueue.makeCommandBuffer() else { continue }

            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = pipeline.msaaColorTexture
            rpd.colorAttachments[0].resolveTexture = pipeline.resolveTexture
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
            rpd.colorAttachments[0].storeAction = .multisampleResolve
            rpd.depthAttachment.texture = pipeline.msaaDepthTexture
            rpd.depthAttachment.clearDepth = 1.0
            rpd.depthAttachment.storeAction = .dontCare

            // drawComposite overrides loadAction/storeAction per avatar (clear+load
            // for load, store+resolve for store) so all N avatars accumulate in one
            // frame before the final pass resolves into resolveTexture.
            stepper.drawComposite(color: pipeline.msaaColorTexture, depth: pipeline.msaaDepthTexture,
                                  commandBuffer: commandBuffer, renderPassDescriptor: rpd)

            commandBuffer.commit()

            // Wait for completion (can't use waitUntilCompleted in async context)
            while commandBuffer.status != .completed && commandBuffer.status != .error {
                await Task.yield()
            }

            // A GPU error means the resolve texture holds garbage; don't append a
            // corrupt frame — fail loudly rather than silently encode it. The pixel
            // buffer is not locked until copyTextureToPixelBuffer below, so nothing
            // to release here.
            if commandBuffer.status == .error {
                throw VideoRenderError.commandBufferFailed(frame: frameIndex,
                    message: commandBuffer.error?.localizedDescription ?? "unknown GPU error")
            }

            copyTextureToPixelBuffer(pipeline.resolveTexture, to: pixelBuffer, device: device, commandBuffer: commandBuffer)

            let presentationTime = CMTimeMultiply(pipeline.frameDuration, multiplier: Int32(frameIndex))

            while !pipeline.writerInput.isReadyForMoreMediaData {
                await Task.yield()
            }

            pipeline.adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

            // Progress
            if frameIndex % 30 == 0 || frameIndex == totalFrames - 1 {
                let progress = Double(frameIndex + 1) / Double(totalFrames) * 100
                let elapsed = Date().timeIntervalSince(startTime)
                let currentFps = Double(frameIndex + 1) / elapsed
                print("   📊 Progress: \(String(format: "%.1f", progress))% (\(frameIndex + 1)/\(totalFrames) frames, \(String(format: "%.1f", currentFps)) fps)")
            }
        }

        pipeline.writerInput.markAsFinished()
        await pipeline.videoWriter.finishWriting()

        let totalTime = Date().timeIntervalSince(startTime)
        print("")
        print("✅ Crowd render complete!")
        print("   📁 Output: \(options.outputPath)")
        print("   ⏱️  Time: \(String(format: "%.2f", totalTime))s")
        print("   🎬 Average: \(String(format: "%.1f", Double(totalFrames) / totalTime)) fps")
    }
}

await VRMVideoRendererCLI.main()
