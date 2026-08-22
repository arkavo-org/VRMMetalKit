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
import simd
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import GLTFMetalKit
import QuadrupedGait
import VRMMetalKit

// MARK: - Errors

enum HoundDemoError: Error, LocalizedError {
    case missingMetalDevice
    case missingCommandQueue
    case textureAllocationFailed
    case commandBufferFailed(String)
    case pngEncodingFailed
    case videoEncodingFailed(String)
    case invalidInputPath(String)
    case missingNode(String)
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .missingMetalDevice:        return "No Metal device available (headless macOS required)."
        case .missingCommandQueue:       return "MTLDevice could not create a command queue."
        case .textureAllocationFailed:   return "Allocation of render-target texture failed."
        case .commandBufferFailed(let s): return "Command buffer execution failed: \(s)"
        case .pngEncodingFailed:         return "CGImageDestination failed to encode the framebuffer as PNG."
        case .videoEncodingFailed(let s): return "AVAssetWriter failed: \(s)"
        case .invalidInputPath(let p):   return "Input file not found or unreadable: \(p)"
        case .missingNode(let n):        return "Rig node not found in asset: \(n)"
        case .invalidArguments(let s):   return s
        }
    }
}

// MARK: - CLI

enum DemoMode: String {
    case drive
    case walk
    case transition
}

enum CameraPreset: String {
    /// Camera on −X looking at the origin: the nose (−Z) points left.
    case side
    /// Head-on from the nose side.
    case front
    /// Rear three-quarter: tail bar + one flank strip.
    case rear
    /// Front three-quarter: nose + left flank.
    case threeQuarter = "three-quarter"
}

struct CLIOptions {
    var glbPath: String = ""
    var mode: DemoMode?
    var speed: Float?
    var time: Float = 0
    var steering: Float = 0
    var acceleration: Float = 0
    var outputPath: String = "out.png"
    var width: Int = 1024
    var height: Int = 1024
    var riderPath: String?
    var camera: CameraPreset = .side
    var enableIBL: Bool = true
    /// Dim "night" lighting so the emissive strips read.
    var dim: Bool = false
    /// Print per-leg paw world-space heights on stderr.
    var debugLegs: Bool = false
    var sampleCount: Int = 4
    /// Video output path; switches the demo from still-PNG to video mode.
    var videoPath: String?
    /// Video duration in seconds; nil picks a per-mode default.
    var duration: Float?
    var fps: Int = 60
}

func printUsage() {
    print("""
    AKIRAHoundDemo — headless pose verification renderer for AKIRA_Hound.glb.

    USAGE
      AKIRAHoundDemo <glbPath> --mode <drive|walk|transition> [options]

    OPTIONS
      --speed <m/s>        Forward speed. Defaults: drive 15, walk 1.2, transition 0.5.
      --time <s>           Simulation time, stepped deterministically at 120 Hz.
                           In walk mode the legs are fully deployed first (at zero
                           speed), so --time maps directly onto stride phase.
      --steering <-1..1>   Steering input (drive-mode body roll).
      --accel <m/s²>       Longitudinal acceleration (drive-mode body pitch).
                           In video mode, ramps the drive speed from 0 to --speed.
      -o <path>            Output PNG path. Default: out.png
      --size <WxH>         Output size. Default: 1024x1024
      --rider <path.vrm>   Mount a VRM rider at Seat_Mount and composite it.
      --camera <preset>    side | front | rear | three-quarter. Default: side.
      --dim                Night lighting (dim key light, dark background, no IBL).
      --no-ibl             Gray fallback environment instead of the procedural sky.
      --msaa <n>           MSAA sample count: 1 (off), 2, 4, or 8. Default: 4.
                           Forced to 1 when --rider is used (shared depth pass).
      --video <path.mov>   Render an H.264 video instead of a still PNG.
      --duration <s>       Video duration. Defaults: walk two full strides
                           (2 / strideFrequency ≈ 1.25 s), drive 2 s,
                           transition 0.8 s.
      --fps <n>            Video frame rate. Default: 60.
    """)
}

func consumeValue(_ args: [String], _ i: inout Int, flag: String) throws -> String {
    i += 1
    guard i < args.count else {
        throw HoundDemoError.invalidArguments("\(flag) requires a value")
    }
    return args[i]
}

func consumeFloat(_ args: [String], _ i: inout Int, flag: String) throws -> Float {
    let raw = try consumeValue(args, &i, flag: flag)
    guard let value = Float(raw) else {
        throw HoundDemoError.invalidArguments("\(flag) must be a number, got '\(raw)'")
    }
    return value
}

func parseArguments() throws -> CLIOptions {
    var opts = CLIOptions()
    let args = CommandLine.arguments
    var i = 1
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "-h", "--help":
            printUsage(); exit(0)
        case "--mode":
            let raw = try consumeValue(args, &i, flag: "--mode")
            guard let mode = DemoMode(rawValue: raw) else {
                throw HoundDemoError.invalidArguments("--mode must be drive, walk, or transition")
            }
            opts.mode = mode
        case "--speed":
            opts.speed = try consumeFloat(args, &i, flag: "--speed")
        case "--time":
            opts.time = try consumeFloat(args, &i, flag: "--time")
        case "--steering":
            opts.steering = try consumeFloat(args, &i, flag: "--steering")
        case "--accel":
            opts.acceleration = try consumeFloat(args, &i, flag: "--accel")
        case "-o":
            opts.outputPath = try consumeValue(args, &i, flag: "-o")
        case "--size":
            let raw = try consumeValue(args, &i, flag: "--size")
            let parts = raw.lowercased().split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
                throw HoundDemoError.invalidArguments("--size must be WxH, e.g. 1024x1024")
            }
            opts.width = parts[0]; opts.height = parts[1]
        case "--rider":
            opts.riderPath = try consumeValue(args, &i, flag: "--rider")
        case "--camera":
            let raw = try consumeValue(args, &i, flag: "--camera")
            guard let camera = CameraPreset(rawValue: raw) else {
                throw HoundDemoError.invalidArguments("--camera must be side, front, rear, or three-quarter")
            }
            opts.camera = camera
        case "--dim":
            opts.dim = true
        case "--debug-legs":
            opts.debugLegs = true
        case "--no-ibl":
            opts.enableIBL = false
        case "--msaa":
            let raw = try consumeValue(args, &i, flag: "--msaa")
            guard let n = Int(raw), [1, 2, 4, 8].contains(n) else {
                throw HoundDemoError.invalidArguments("--msaa must be 1, 2, 4, or 8")
            }
            opts.sampleCount = n
        case "--video":
            opts.videoPath = try consumeValue(args, &i, flag: "--video")
        case "--duration":
            opts.duration = try consumeFloat(args, &i, flag: "--duration")
        case "--fps":
            let raw = try consumeValue(args, &i, flag: "--fps")
            guard let n = Int(raw), n > 0 else {
                throw HoundDemoError.invalidArguments("--fps must be a positive integer")
            }
            opts.fps = n
        default:
            if !arg.hasPrefix("-"), opts.glbPath.isEmpty {
                opts.glbPath = arg
            }
        }
        i += 1
    }
    guard !opts.glbPath.isEmpty, opts.mode != nil else {
        printUsage()
        throw HoundDemoError.invalidArguments("glbPath and --mode are required")
    }
    guard (try? Data(contentsOf: URL(fileURLWithPath: opts.glbPath))) != nil else {
        throw HoundDemoError.invalidInputPath(opts.glbPath)
    }
    return opts
}

// MARK: - Camera helpers

func perspectiveProjection(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let y = 1 / tan(fovY * 0.5)
    let x = y / aspect
    let z = far / (near - far)
    return simd_float4x4(
        SIMD4<Float>(x, 0, 0, 0),
        SIMD4<Float>(0, y, 0, 0),
        SIMD4<Float>(0, 0, z, -1),
        SIMD4<Float>(0, 0, z * near, 0)
    )
}

func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let z = normalize(eye - target)
    let x = normalize(cross(up, z))
    let y = cross(z, x)
    return simd_float4x4(
        SIMD4<Float>(x.x, y.x, z.x, 0),
        SIMD4<Float>(x.y, y.y, z.y, 0),
        SIMD4<Float>(x.z, y.z, z.z, 0),
        SIMD4<Float>(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
    )
}

// MARK: - PNG export (mirrors GLTFRender; kept local to this executable)

func exportTexture(_ texture: MTLTexture, to path: String) throws {
    let width = texture.width
    let height = texture.height
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    pixels.withUnsafeMutableBufferPointer { ptr in
        texture.getBytes(ptr.baseAddress!, bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    }
    let data = Data(pixels)
    guard let provider = CGDataProvider(data: data as CFData) else {
        throw HoundDemoError.pngEncodingFailed
    }
    let bitmapInfo: CGBitmapInfo
    switch texture.pixelFormat {
    case .bgra8Unorm, .bgra8Unorm_srgb:
        bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    default:
        bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    guard let image = CGImage(
        width: width, height: height,
        bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo,
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    ) else {
        throw HoundDemoError.pngEncodingFailed
    }
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw HoundDemoError.pngEncodingFailed
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw HoundDemoError.pngEncodingFailed
    }
}

// MARK: - Video export (adapted from Sources/VRMVideoRenderer/main.swift)

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

/// Copies the resolved color texture into the pixel buffer's base address.
/// Locks the buffer for writing; the caller unlocks after appending it.
func copyTextureToPixelBuffer(_ texture: MTLTexture, to pixelBuffer: CVPixelBuffer) throws {
    guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else {
        throw HoundDemoError.videoEncodingFailed("CVPixelBufferLockBaseAddress failed")
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        throw HoundDemoError.videoEncodingFailed("CVPixelBufferGetBaseAddress returned nil")
    }
    texture.getBytes(
        baseAddress,
        bytesPerRow: bytesPerRow,
        from: MTLRegionMake2D(0, 0, texture.width, texture.height),
        mipmapLevel: 0
    )
}

/// AVAssetWriter + input + pixel-buffer adaptor for 32BGRA H.264 .mov output.
struct VideoWriter {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
}

func makeVideoWriter(path: String, width: Int, height: Int) throws -> VideoWriter {
    let outputURL = URL(fileURLWithPath: path)
    // AVAssetWriter.init throws if the path already exists; remove first.
    if FileManager.default.fileExists(atPath: path) {
        try FileManager.default.removeItem(at: outputURL)
    }
    let writer = try AVAssetWriter(url: outputURL, fileType: .mov)

    let videoSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: width * height * 4,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]
    ]

    let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    input.expectsMediaDataInRealTime = false

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
    )

    writer.add(input)
    guard writer.startWriting() else {
        throw HoundDemoError.videoEncodingFailed(writer.error?.localizedDescription ?? "startWriting failed")
    }
    writer.startSession(atSourceTime: .zero)
    return VideoWriter(writer: writer, input: input, adaptor: adaptor)
}

// MARK: - Rig wiring

/// Hip pivot Y in Body space, matching the generator
/// (`Sources/AKIRAHoundGen/HoundAsset.swift`: hips at `[±0.30, 0.45, ∓0.18/+0.18]`).
/// Read back from the asset at runtime; this constant only documents the expectation.
let expectedHipPivotY: Float = 0.45

/// Vertical distance from hip pivot to the ground plane in walk mode.
/// Leg segments are 0.55 + 0.55 + 0.30; a standing height of 1.05 m leaves the
/// 2-bone chain reaching 0.75 m of its 1.10 m maximum — a comfortably bent knee —
/// and puts the tail-hump top at ~1.5 m with the Body raised. In walk the
/// knee-mounted wheels (r=0.40) ride at the thigh, ~0.10 m clear of the ground.
let standingHeight: Float = 1.05

func makeRigMap() -> QuadrupedRigMap {
    func leg(_ prefix: String) -> LegNodeNames {
        LegNodeNames(
            hip: "Leg_\(prefix)_Hip",
            knee: "Leg_\(prefix)_Knee",
            ankle: "Leg_\(prefix)_Ankle",
            paw: "Leg_\(prefix)_Paw",
            wheel: "Leg_\(prefix)_Wheel"
        )
    }
    return QuadrupedRigMap(body: "Body", seatMount: "Seat_Mount", legs: [
        .frontLeft: leg("FL"),
        .frontRight: leg("FR"),
        .rearLeft: leg("RL"),
        .rearRight: leg("RR"),
    ])
}

/// Steps the engine deterministically at 120 Hz for `duration` seconds.
func simulate(
    controller: QuadrupedRigController,
    duration: Float,
    speed: Float,
    steering: Float,
    acceleration: Float,
    mode: LocomotionMode
) {
    var remaining = duration
    while remaining > 1e-6 {
        let dt = min(Float(1.0 / 120.0), remaining)
        controller.update(deltaTime: dt, speed: speed, steering: steering, acceleration: acceleration, mode: mode)
        remaining -= dt
    }
}

// MARK: - Main

@main
struct AKIRAHoundDemoCLI {
    @MainActor
    static func main() async throws {
        var opts = try parseArguments()
        let mode = opts.mode!
        let speed = opts.speed ?? (mode == .drive ? 15.0 : mode == .walk ? 1.2 : 0.5)

        // Video duration defaults: two full walk strides, a short drive run,
        // or one transition unfold.
        let strideFrequency: Float = 1.6
        let videoDuration: Float? = opts.videoPath != nil
            ? (opts.duration ?? (mode == .walk ? 2.0 / strideFrequency : mode == .drive ? 2.0 : 0.8))
            : nil

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw HoundDemoError.missingMetalDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw HoundDemoError.missingCommandQueue
        }

        // --- Load asset ---------------------------------------------------
        let loader = GLTFAssetLoader()
        let asset = try await loader.load(from: URL(fileURLWithPath: opts.glbPath), device: device)
        let renderer = try GLTFRenderer(device: device)
        if opts.enableIBL && !opts.dim {
            renderer.environment = try GLTFEnvironment.makeProcedural(device: device, library: renderer.library)
        }

        // --- Gait engine + rig controller ---------------------------------
        //
        // Tucked pose in the engine's convention (all joint angles measured
        // from straight-down): the generator authors the rest pose AS the
        // tucked drive stance with hip/knee/ankle X-rotations α, −2α, α,
        // α = acos(0.05/0.55) ≈ 84.8° — positive on front legs (knee swung
        // forward), mirrored on the rear. The wheel rides at the knee
        // (radius 0.40), so α puts the knee centre 0.40 m up: the wheels
        // touch the ground while the paw hovers ~5 cm above it. With identity
        // joint rotations the authored chain points straight down, so these
        // angles are exactly the engine-convention tucked pose.
        let alpha = acos(Float(0.05) / Float(0.55))
        var tucked: [LegID: LegJointPose] = [:]
        for leg in LegID.allCases {
            let front = (leg == .frontLeft || leg == .frontRight)
            let a = front ? alpha : -alpha
            tucked[leg] = LegJointPose(hipAngle: a, kneeAngle: -2 * a, ankleAngle: a)
        }

        let rigMap = makeRigMap()
        guard let bodyIndex = asset.nodeIndex(named: rigMap.body) else {
            throw HoundDemoError.missingNode(rigMap.body)
        }
        let bodyRest = asset.restPose(ofNode: bodyIndex)
        let bodyRestRotation = bodyRest.rotation ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

        // Hip pivots in Body space, read from the asset's rest pose. Hips are
        // children of Body, so compose the Body rest transform (identity
        // today, composed anyway so a future Body offset stays correct).
        var hipOffsets: [LegID: SIMD3<Float>] = [:]
        for (leg, names) in rigMap.legs {
            guard let hipIndex = asset.nodeIndex(named: names.hip) else {
                throw HoundDemoError.missingNode(names.hip)
            }
            let hipRest = asset.restPose(ofNode: hipIndex)
            hipOffsets[leg] = (bodyRest.translation ?? .zero)
                + bodyRestRotation.act(hipRest.translation ?? .zero)
        }
        let hipPivotY = hipOffsets[.frontLeft]?.y ?? expectedHipPivotY

        let segments: [LegID: LegSegmentLengths] = Dictionary(
            uniqueKeysWithValues: LegID.allCases.map {
                ($0, LegSegmentLengths(upper: 0.55, lower: 0.55, paw: 0.30))
            }
        )
        let parameters = GaitParameters(
            strideLength: 0.8,
            stepHeight: 0.15,
            strideFrequency: strideFrequency,
            referenceSpeed: 1.2,   // walk demo speed, so the stride plays at full amplitude
            // In transition video mode the drive→walk unfold spans the whole
            // clip, so the engine's transition duration IS the video duration.
            transitionDuration: (videoDuration != nil && mode == .transition) ? (videoDuration ?? 0.4) : 0.4,
            wheelRadius: 0.40,     // authored wheel radius
            standingHeight: standingHeight
        )
        let engine = QuadrupedGaitEngine(
            segments: segments, tuckedPose: tucked, hipOffsets: hipOffsets, parameters: parameters
        )
        let controller = try QuadrupedRigController(
            asset: asset, rigMap: rigMap, engine: engine, jointSpace: .absolute
        )

        // --- Per-frame pose assembly ---------------------------------------
        //
        // This asset's rest pose is the tucked fold (α ≈ ±85° at the hip),
        // and the engine works in absolute joint angles whose tucked pose
        // equals that authored fold — so the controller is configured with
        // `.absolute` joint space: engine quaternions replace joint rest
        // rotations exactly, blend 0 reproduces the authored tuck, blend 1
        // the ground-clamped gait. Engine +Z-forward angles map onto this
        // asset's −Z nose because each bone child sits at local −Y: Rx(+θ)
        // yields z' = −L·sin(θ). No extra sagittal flip.
        //
        // Stance height is owned by the demo: the engine's bodyPose bobY is a
        // small 2×-frequency oscillation, not the drive→walk body rise. Lift
        // the Body node so the hip pivots sit at `standingHeight` in walk,
        // smoothstepped by transitionBlend to match the joint slerp timing.
        func assemblePoses() -> (poses: [Int: GLTFNodePose], blendSmooth: Float) {
            var poses = controller.nodePoses
            let blend = controller.engine.transitionBlend
            let blendSmooth = blend * blend * (3 - 2 * blend)
            let stanceY = blendSmooth * (standingHeight - hipPivotY)
            if var bodyPose = poses[bodyIndex] {
                bodyPose.translation = (bodyPose.translation ?? .zero) + SIMD3<Float>(0, stanceY, 0)
                poses[bodyIndex] = bodyPose
            }
            return (poses, blendSmooth)
        }

        // --- Rider model (optional) ----------------------------------------
        // The rider is composited into the same color/depth textures in a
        // second pass with load actions set to .load. Depth conventions match
        // (Metal standard Z, .less), so the rider occludes/is occluded by the
        // vehicle correctly. MSAA must be off so the depth texture is shared.
        var riderModel: VRMModel?
        var riderLocalTopY: Float = 0
        /// Bind-pose transform of each rider root node. The mount is applied
        /// to these originals every frame — composing onto the live transform
        /// would accumulate the offset once per frame.
        var riderRootRest: [(node: VRMNode, translation: SIMD3<Float>, rotation: simd_quatf)] = []
        if let riderPath = opts.riderPath {
            opts.sampleCount = 1
            let model = try await VRMModel.load(from: URL(fileURLWithPath: riderPath), device: device)
            // Bind-pose height, before mounting (the mount is rigid, so the
            // rider's top just translates up by the mount Y).
            let (_, localMax) = model.calculateBoundingBox()
            riderLocalTopY = localMax.y
            riderRootRest = model.nodes.filter { $0.parent == nil }
                .map { ($0, $0.translation, $0.rotation) }
            riderModel = model
        }

        /// Rigidly mounts the rider at Seat_Mount for the current frame,
        /// yawed 180° so the rider (VRM forward = +Z) faces the nose (−Z).
        /// Returns the rider's world-space top Y for camera framing.
        @discardableResult
        func mountRider(worldMatrices: [simd_float4x4], log: Bool = false) -> Float? {
            guard let riderModel else { return nil }
            let seatWorld = controller.riderRootTransform(worldMatrices: worldMatrices, localOffset: .zero)
            let faceNose = simd_float4x4(simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)))
            let mount = seatWorld * faceNose
            let mountRotation = simd_quatf(mount)
            let mountTranslation = SIMD3<Float>(mount.columns.3.x, mount.columns.3.y, mount.columns.3.z)
            for (node, restTranslation, restRotation) in riderRootRest {
                node.translation = mountTranslation + mountRotation.act(restTranslation)
                node.rotation = mountRotation * restRotation
                node.updateLocalMatrix()
            }
            riderModel.updateNodeTransforms()
            if log {
                FileHandle.standardError.write(Data("[AKIRAHoundDemo] rider root: t=(\(mountTranslation.x), \(mountTranslation.y), \(mountTranslation.z))\n".utf8))
            }
            return mountTranslation.y + riderLocalTopY
        }

        // --- Pre-roll simulation -------------------------------------------
        let locoMode: LocomotionMode = mode == .drive ? .drive : .walk
        if videoDuration != nil {
            // Video mode: walk deploys the legs at zero speed before frame 0
            // (phase does not advance at speed 0); drive and transition start
            // from the authored tuck and unfold inside the clip.
            if mode == .walk {
                simulate(controller: controller, duration: parameters.transitionDuration + 0.25,
                         speed: 0, steering: 0, acceleration: 0, mode: .walk)
            }
        } else {
            switch mode {
            case .drive:
                simulate(controller: controller, duration: opts.time, speed: speed,
                         steering: opts.steering, acceleration: opts.acceleration, mode: .drive)
            case .walk:
                // Fully deploy the legs at zero speed (phase does not advance at
                // speed 0), then run the stride — --time maps onto stride phase.
                simulate(controller: controller, duration: parameters.transitionDuration + 0.25,
                         speed: 0, steering: 0, acceleration: 0, mode: .walk)
                simulate(controller: controller, duration: opts.time, speed: speed,
                         steering: opts.steering, acceleration: opts.acceleration, mode: .walk)
            case .transition:
                // Half the transition duration → transitionBlend == 0.5.
                simulate(controller: controller, duration: parameters.transitionDuration * 0.5,
                         speed: speed, steering: opts.steering, acceleration: opts.acceleration, mode: .walk)
            }
        }

        // --- Frame-0 evaluation ---------------------------------------------
        let initialAssembly = assemblePoses()
        let blendSmooth = initialAssembly.blendSmooth
        let (initialDrawCalls, initialWorldMatrices) = asset.evaluate(poses: initialAssembly.poses)

        if opts.debugLegs {
            // Ground-truth check: world-space Y of each paw and wheel origin.
            for (leg, names) in rigMap.legs.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                if let paw = asset.nodeIndex(named: names.paw), initialWorldMatrices.indices.contains(paw) {
                    let m = initialWorldMatrices[paw]
                    FileHandle.standardError.write(Data(
                        "[debug-legs] \(leg.rawValue): paw world y=\(String(format: "%.3f", m.columns.3.y)) z=\(String(format: "%.3f", m.columns.3.z))\n".utf8))
                }
            }
        }

        let riderTopY = mountRider(worldMatrices: initialWorldMatrices, log: riderModel != nil)

        // --- Camera framing ------------------------------------------------
        // Frame from the rest-pose world bounds, following the body rise in
        // walk. Video mode frames the fully deployed end state (blend = 1) so
        // the transition unfold doesn't shift the framing mid-clip.
        let framingBlendSmooth = videoDuration != nil ? Float(1) : blendSmooth
        let stanceY = framingBlendSmooth * (standingHeight - hipPivotY)
        let currentStanceY = blendSmooth * (standingHeight - hipPivotY)
        let bMin = asset.worldBounds.min
        let bMax = asset.worldBounds.max
        var center = (bMin + bMax) * 0.5
        // Deployed legs reach below the rest-pose bounds mid-transition, so
        // extend the fit box down to the paw plane as the blend progresses.
        let fitBottom = framingBlendSmooth > 0.01
            ? min(bMin.y, hipPivotY - standingHeight + stanceY)
            : bMin.y
        // The rider mount translates up with the body rise; project its frame-0
        // top to the framing blend.
        let fitTop = max(bMax.y + stanceY, riderTopY.map { $0 + (stanceY - currentStanceY) } ?? -.infinity)
        center.y = (fitTop + fitBottom) * 0.5

        let aspect = Float(opts.width) / Float(opts.height)
        let fovY: Float = .pi / 4

        let direction: SIMD3<Float>
        switch opts.camera {
        case .side:          direction = SIMD3<Float>(-1.0, 0.15, 0.0)   // nose points left
        case .front:         direction = SIMD3<Float>(0.0, 0.12, -1.0)
        case .rear:          direction = SIMD3<Float>(0.5, 0.28, 1.0)
        case .threeQuarter:  direction = SIMD3<Float>(-0.6, 0.32, -1.0)
        }
        let viewDir = normalize(direction)

        // Per-view fit: project the bounds corners onto the camera's screen
        // axes and fit the projected rectangle (not the full diagonal — a
        // diagonal fit leaves head-on views of a long vehicle tiny).
        let camZ = -viewDir
        let camX = normalize(cross(SIMD3<Float>(0, 1, 0), camZ))
        let camY = cross(camZ, camX)
        var halfW: Float = 0
        var halfH: Float = 0
        for cx in [bMin.x, bMax.x] {
            for cy in [fitBottom, fitTop] {
                for cz in [bMin.z, bMax.z] {
                    let d = SIMD3<Float>(cx, cy, cz) - center
                    halfW = max(halfW, abs(dot(d, camX)))
                    halfH = max(halfH, abs(dot(d, camY)))
                }
            }
        }
        let halfFov = fovY * 0.5
        // 1.25 padding: the projected-rect fit is exact for the AABB, but
        // perspective enlarges the near end of the vehicle.
        let distance = max(halfH / tan(halfFov), halfW / (tan(halfFov) * aspect)) * 1.25
        let eye = center + viewDir * distance
        let proj = perspectiveProjection(fovY: fovY, aspect: aspect, near: max(distance * 0.01, 0.01), far: distance * 10)
        let view = lookAt(eye: eye, target: center, up: SIMD3<Float>(0, 1, 0))

        let scene = GLTFSceneState(
            viewProjection: proj * view,
            cameraPosition: eye,
            lightDirection: normalize(SIMD3<Float>(-0.3, -1.0, -0.4)),
            lightColor: opts.dim ? SIMD3<Float>(0.22, 0.26, 0.40) : SIMD3<Float>(3, 3, 3),
            lights: asset.lights
        )

        // --- Rider renderer (optional) --------------------------------------
        var riderRenderer: VRMRenderer?
        if let riderModel {
            var config = RendererConfig()
            config.sampleCount = 1
            config.strict = .off
            config.synchronousSpringBone = true
            let vrmRenderer = VRMRenderer(device: device, config: config)
            vrmRenderer.setLight(0, direction: SIMD3<Float>(-0.2, 0.5, -0.85),
                                 color: SIMD3<Float>(1, 1, 1), intensity: 1.0)
            vrmRenderer.disableLight(1)
            vrmRenderer.setLight(2, direction: SIMD3<Float>(0.0, 0.2, 1.0),
                                 color: SIMD3<Float>(1, 1, 1), intensity: 0.3)
            vrmRenderer.setAmbientColor(SIMD3<Float>(0.04, 0.04, 0.04))
            vrmRenderer.setLightNormalizationMode(.radiometric)
            vrmRenderer.loadModel(riderModel)
            vrmRenderer.viewMatrix = view
            vrmRenderer.projectionMatrix = proj
            riderRenderer = vrmRenderer
        }

        // --- Offscreen render targets --------------------------------------
        let colorFormat: MTLPixelFormat = .bgra8Unorm
        let depthFormat: MTLPixelFormat = .depth32Float
        let pipelines = try renderer.makePipelineStates(
            colorFormat: colorFormat, depthFormat: depthFormat, sampleCount: opts.sampleCount
        )
        let depthStencilDescriptor = MTLDepthStencilDescriptor()
        depthStencilDescriptor.depthCompareFunction = .less
        depthStencilDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthStencilDescriptor) else {
            throw HoundDemoError.commandBufferFailed("depth state")
        }

        let resolveDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorFormat, width: opts.width, height: opts.height, mipmapped: false
        )
        resolveDescriptor.usage = [.renderTarget, .shaderRead]
        resolveDescriptor.storageMode = .shared
        guard let resolveTexture = device.makeTexture(descriptor: resolveDescriptor) else {
            throw HoundDemoError.textureAllocationFailed
        }

        let colorTexture: MTLTexture
        if opts.sampleCount > 1 {
            let msaaDescriptor = MTLTextureDescriptor()
            msaaDescriptor.textureType = .type2DMultisample
            msaaDescriptor.pixelFormat = colorFormat
            msaaDescriptor.width = opts.width
            msaaDescriptor.height = opts.height
            msaaDescriptor.sampleCount = opts.sampleCount
            msaaDescriptor.usage = [.renderTarget]
            msaaDescriptor.storageMode = .private
            guard let t = device.makeTexture(descriptor: msaaDescriptor) else {
                throw HoundDemoError.textureAllocationFailed
            }
            colorTexture = t
        } else {
            colorTexture = resolveTexture
        }

        let depthTextureDescriptor = MTLTextureDescriptor()
        depthTextureDescriptor.textureType = opts.sampleCount > 1 ? .type2DMultisample : .type2D
        depthTextureDescriptor.pixelFormat = depthFormat
        depthTextureDescriptor.width = opts.width
        depthTextureDescriptor.height = opts.height
        depthTextureDescriptor.sampleCount = opts.sampleCount
        depthTextureDescriptor.usage = [.renderTarget]
        depthTextureDescriptor.storageMode = .private
        guard let depthTexture = device.makeTexture(descriptor: depthTextureDescriptor) else {
            throw HoundDemoError.textureAllocationFailed
        }

        /// Encodes the vehicle pass (plus the rider composite pass) into a
        /// single command buffer and waits for GPU completion.
        func renderFrame(_ drawCalls: [GLTFDrawCall]) async throws {
            guard let commandBuffer = queue.makeCommandBuffer() else {
                throw HoundDemoError.commandBufferFailed("command buffer")
            }

            // Pass 1: the vehicle.
            let vehiclePass = MTLRenderPassDescriptor()
            vehiclePass.colorAttachments[0].texture = colorTexture
            vehiclePass.colorAttachments[0].loadAction = .clear
            vehiclePass.colorAttachments[0].clearColor = opts.dim
                ? MTLClearColor(red: 0.012, green: 0.016, blue: 0.045, alpha: 1)
                : MTLClearColor(red: 0.08, green: 0.10, blue: 0.15, alpha: 1)
            if opts.sampleCount > 1 {
                vehiclePass.colorAttachments[0].resolveTexture = resolveTexture
                vehiclePass.colorAttachments[0].storeAction = .multisampleResolve
            } else {
                vehiclePass.colorAttachments[0].storeAction = .store
            }
            vehiclePass.depthAttachment.texture = depthTexture
            vehiclePass.depthAttachment.loadAction = .clear
            vehiclePass.depthAttachment.clearDepth = 1.0
            vehiclePass.depthAttachment.storeAction = riderRenderer != nil ? .store : .dontCare

            guard let vehicleEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: vehiclePass) else {
                throw HoundDemoError.commandBufferFailed("vehicle encoder")
            }
            renderer.encodeOpaqueDrawCalls(
                drawCalls, scene: scene, pipelineStates: pipelines, depthState: depthState, encoder: vehicleEncoder
            )
            vehicleEncoder.endEncoding()

            // Pass 2: the rider, composited over the vehicle with shared depth.
            if let riderRenderer {
                let riderPass = MTLRenderPassDescriptor()
                riderPass.colorAttachments[0].texture = resolveTexture
                riderPass.colorAttachments[0].loadAction = .load
                riderPass.colorAttachments[0].storeAction = .store
                riderPass.depthAttachment.texture = depthTexture
                riderPass.depthAttachment.loadAction = .load
                riderPass.depthAttachment.storeAction = .dontCare
                riderRenderer.drawOffscreenHeadless(
                    to: resolveTexture, depth: depthTexture,
                    commandBuffer: commandBuffer, renderPassDescriptor: riderPass
                )
            }

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                commandBuffer.addCompletedHandler { _ in continuation.resume() }
                commandBuffer.commit()
            }
            if let error = commandBuffer.error {
                throw HoundDemoError.commandBufferFailed(error.localizedDescription)
            }
        }

        // --- Output ---------------------------------------------------------
        if let videoPath = opts.videoPath, let videoDuration {
            let fps = opts.fps
            let dt = Float(1) / Float(fps)
            let totalFrames = max(1, Int((Double(videoDuration) * Double(fps)).rounded()))
            let videoWriter = try makeVideoWriter(path: videoPath, width: opts.width, height: opts.height)

            // Drive-mode acceleration ramp: with --accel, start from rest and
            // ramp to the target speed, passing the acceleration through so
            // the body pitch reads while the ramp is active.
            var driveSpeed: Float = (mode == .drive && opts.acceleration > 0) ? 0 : speed
            let initialWheelSpin = controller.engine.jointPoses()[.frontLeft]?.wheelSpinAngle ?? 0

            do {
                for frame in 0..<totalFrames {
                    if frame > 0 {
                        var accelInput: Float = 0
                        if mode == .drive && opts.acceleration > 0 && driveSpeed < speed {
                            driveSpeed = min(speed, driveSpeed + opts.acceleration * dt)
                            accelInput = opts.acceleration
                        }
                        controller.update(deltaTime: dt,
                                          speed: mode == .drive ? driveSpeed : speed,
                                          steering: opts.steering, acceleration: accelInput, mode: locoMode)
                    }

                    let frameAssembly = assemblePoses()
                    let (frameDrawCalls, frameWorldMatrices) = asset.evaluate(poses: frameAssembly.poses)
                    mountRider(worldMatrices: frameWorldMatrices)
                    try await renderFrame(frameDrawCalls)

                    guard let pixelBuffer = createPixelBuffer(width: opts.width, height: opts.height) else {
                        throw HoundDemoError.textureAllocationFailed
                    }
                    try copyTextureToPixelBuffer(resolveTexture, to: pixelBuffer)
                    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
                    while !videoWriter.input.isReadyForMoreMediaData {
                        if videoWriter.writer.status != .writing {
                            let detail = videoWriter.writer.error?.localizedDescription ?? "writer status \(videoWriter.writer.status.rawValue)"
                            throw HoundDemoError.videoEncodingFailed(detail)
                        }
                        await Task.yield()
                    }
                    let presentationTime = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
                    guard videoWriter.adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                        let detail = videoWriter.writer.error?.localizedDescription ?? "adaptor.append rejected frame \(frame)"
                        throw HoundDemoError.videoEncodingFailed(detail)
                    }
                }
            } catch {
                // Don't leave a truncated, unplayable .mov behind.
                videoWriter.writer.cancelWriting()
                try? FileManager.default.removeItem(atPath: videoPath)
                throw error
            }

            videoWriter.input.markAsFinished()
            await videoWriter.writer.finishWriting()
            if let error = videoWriter.writer.error {
                throw HoundDemoError.videoEncodingFailed(error.localizedDescription)
            }

            let finalWheelSpin = controller.engine.jointPoses()[.frontLeft]?.wheelSpinAngle ?? 0
            FileHandle.standardError.write(Data(
                "[AKIRAHoundDemo] FL wheel spin: \(String(format: "%.2f", initialWheelSpin)) → \(String(format: "%.2f", finalWheelSpin)) rad (Δ \(String(format: "%.2f", finalWheelSpin - initialWheelSpin)) rad)\n".utf8))
            print("✅ Wrote \(videoPath) (\(opts.width)×\(opts.height), \(totalFrames) frames @ \(fps) fps, "
                + "mode=\(mode.rawValue), speed=\(speed), duration=\(String(format: "%.2f", videoDuration))s)")
        } else {
            try await renderFrame(initialDrawCalls)
            try exportTexture(resolveTexture, to: opts.outputPath)
            print("✅ Wrote \(opts.outputPath) (\(opts.width)×\(opts.height), mode=\(mode.rawValue), "
                + "speed=\(speed), time=\(opts.time), blend=\(String(format: "%.2f", controller.engine.transitionBlend)), "
                + "\(initialDrawCalls.count) draw calls)")
        }
    }
}
