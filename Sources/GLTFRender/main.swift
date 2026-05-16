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
import simd
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import GLTFMetalKit

// MARK: - Render error surface

enum GLTFRenderError: Error, LocalizedError {
    case missingMetalDevice
    case missingCommandQueue
    case textureAllocationFailed
    case commandBufferFailed(String)
    case pngEncodingFailed
    case invalidInputPath(String)

    var errorDescription: String? {
        switch self {
        case .missingMetalDevice:        return "No Metal device available (CI / headless macOS)."
        case .missingCommandQueue:       return "MTLDevice could not create a command queue."
        case .textureAllocationFailed:   return "Allocation of render-target texture failed."
        case .commandBufferFailed(let s): return "Command buffer execution failed: \(s)"
        case .pngEncodingFailed:         return "CGImageDestination failed to encode the framebuffer as PNG."
        case .invalidInputPath(let p):   return "Input file not found or unreadable: \(p)"
        }
    }
}

// MARK: - CLI args

struct CLIOptions {
    var inputPath: String = ""
    var outputPath: String = "out.png"
    var width: Int = 1024
    var height: Int = 1024
    var animationTime: Float = 0
    var animationIndex: Int = 0
    var cameraDistancePadding: Float = 1.15  // Extra margin on the bounding-sphere fit.
    var enableIBL: Bool = true
    var sampleCount: Int = 1  // MSAA samples; 1, 2, 4, or 8.
    var debugMode: DebugMode = .none
    var printDiagnostics: Bool = false
}

enum DebugMode: String {
    case none
    /// Render world-space normals as RGB (N * 0.5 + 0.5). Diagnostic for
    /// NORMAL accessor decoding + per-vertex normal interpolation.
    case normals
    /// Render TEXCOORD_0 as red/green. Diagnostic for UV decoding + chart layout.
    case uvs
    /// Render per-fragment roughness as greyscale. Diagnostic for the
    /// metallic-roughness texture's G channel + `roughnessFactor`.
    case roughness
}

func printUsage() {
    let usage = """
    GLTFRender — render a glTF 2.0 asset to a PNG via GLTFMetalKit.

    USAGE
      GLTFRender <input.glb> [options]

    OPTIONS
      -o <path>            Output PNG path. Default: out.png
      -w <px>              Output width.  Default: 1024
      -h <px>              Output height. Default: 1024
      --time <sec>         Animation time in seconds (clips are sampled at
                           this time; default = rest pose at t=0).
      --animation <idx>    Animation clip index (default: 0).
      --no-ibl             Use the gray fallback environment instead of
                           the runtime procedural sky. Tests strict
                           direct-light behaviour.
      --camera-padding <s> Padding multiplier on the bounding-sphere fit.
                           Distance = (radius / sin(fovY/2)) * padding.
                           1.0 = tight fit, 1.15 (default) = comfortable margin.
      --msaa <n>           MSAA sample count: 1 (off), 2, 4, or 8.
                           Default: 1.
      --debug <mode>       Diagnostic output mode. Bypasses normal shading.
                           Modes:
                             normals    — world-space normals as RGB.
                             uvs        — TEXCOORD_0 as red/green channels.
                             roughness  — per-fragment roughness as greyscale.
      --diagnostics        Print asset bounds, framing math, and draw-call
                           summary on stderr.

    The renderer auto-frames using the asset's world bounds. To render an
    asset's animation frame-by-frame, drive `--time` from a shell loop.
    """
    print(usage)
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
        case "-o":
            i += 1; opts.outputPath = args[i]
        case "-w":
            i += 1; opts.width = Int(args[i]) ?? opts.width
        case "--height":
            i += 1; opts.height = Int(args[i]) ?? opts.height
        case "--time":
            i += 1; opts.animationTime = Float(args[i]) ?? 0
        case "--animation":
            i += 1; opts.animationIndex = Int(args[i]) ?? 0
        case "--no-ibl":
            opts.enableIBL = false
        case "--camera-padding":
            i += 1; opts.cameraDistancePadding = Float(args[i]) ?? opts.cameraDistancePadding
        case "--msaa":
            i += 1
            let n = Int(args[i]) ?? 1
            opts.sampleCount = [1, 2, 4, 8].contains(n) ? n : 1
        case "--debug":
            i += 1
            opts.debugMode = DebugMode(rawValue: args[i]) ?? .none
        case "--diagnostics":
            opts.printDiagnostics = true
        default:
            if opts.inputPath.isEmpty {
                opts.inputPath = arg
            }
        }
        i += 1
    }
    if opts.inputPath.isEmpty {
        printUsage()
        exit(1)
    }
    let url = URL(fileURLWithPath: opts.inputPath)
    guard (try? Data(contentsOf: url)) != nil else {
        throw GLTFRenderError.invalidInputPath(opts.inputPath)
    }
    return opts
}

// MARK: - Camera helpers

/// Builds opaque + skinned debug pipeline pairs using a factory that takes a
/// `(colorFormat, depthFormat, sampleCount, skinned)` quadruple — the signature
/// shared by every `makeDebug*PipelineState` method on GLTFRenderer.
func makeDebugPipelines(
    renderer: GLTFRenderer,
    colorFormat: MTLPixelFormat,
    depthFormat: MTLPixelFormat,
    sampleCount: Int,
    make: (MTLPixelFormat, MTLPixelFormat, Int, Bool) throws -> MTLRenderPipelineState
) throws -> GLTFRenderer.PipelineStates {
    let opaque = try make(colorFormat, depthFormat, sampleCount, false)
    let skinned = try make(colorFormat, depthFormat, sampleCount, true)
    return GLTFRenderer.PipelineStates(opaque: opaque, skinnedOpaque: skinned)
}

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

// MARK: - PNG export

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
        throw GLTFRenderError.pngEncodingFailed
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
        throw GLTFRenderError.pngEncodingFailed
    }
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw GLTFRenderError.pngEncodingFailed
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw GLTFRenderError.pngEncodingFailed
    }
}

// MARK: - Main

@main
struct GLTFRenderCLI {
    static func main() async throws {
        let opts = try parseArguments()

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw GLTFRenderError.missingMetalDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw GLTFRenderError.missingCommandQueue
        }

        // --- Load asset + renderer ----------------------------------------
        let loader = GLTFAssetLoader()
        let asset = try await loader.load(from: URL(fileURLWithPath: opts.inputPath), device: device)
        let renderer = try GLTFRenderer(device: device)

        if opts.enableIBL {
            renderer.environment = try GLTFEnvironment.makeProcedural(device: device, library: renderer.library)
        }

        let colorFormat: MTLPixelFormat = .bgra8Unorm
        let depthFormat: MTLPixelFormat = .depth32Float
        let pipelines: GLTFRenderer.PipelineStates
        switch opts.debugMode {
        case .none:
            pipelines = try renderer.makePipelineStates(
                colorFormat: colorFormat,
                depthFormat: depthFormat,
                sampleCount: opts.sampleCount
            )
        case .normals:
            pipelines = try makeDebugPipelines(
                renderer: renderer,
                colorFormat: colorFormat,
                depthFormat: depthFormat,
                sampleCount: opts.sampleCount,
                make: renderer.makeDebugNormalsPipelineState
            )
        case .uvs:
            pipelines = try makeDebugPipelines(
                renderer: renderer,
                colorFormat: colorFormat,
                depthFormat: depthFormat,
                sampleCount: opts.sampleCount,
                make: renderer.makeDebugUVsPipelineState
            )
        case .roughness:
            pipelines = try makeDebugPipelines(
                renderer: renderer,
                colorFormat: colorFormat,
                depthFormat: depthFormat,
                sampleCount: opts.sampleCount,
                make: renderer.makeDebugRoughnessPipelineState
            )
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw GLTFRenderError.commandBufferFailed("depth state")
        }

        // --- Auto-framing -------------------------------------------------
        //
        // Bounding-sphere fit: enclose the asset in a sphere centred at the
        // bounds centroid with radius = half-diagonal. Position the camera
        // far enough along the view direction that the sphere fits inside
        // the FOV cone with `cameraDistancePadding` margin.

        let bMin = asset.worldBounds.min
        let bMax = asset.worldBounds.max
        let center = (bMin + bMax) * 0.5
        // Half-diagonal of the world-space AABB. The earlier `max(_, 0.5)`
        // clamp made small assets like Avocado (~0.06m natural extent) get
        // framed as if they were a 1m-radius sphere — camera too far,
        // asset appears as a speck. Keep a tiny epsilon to avoid divide-
        // by-zero on degenerate bounds; otherwise let the asset's real
        // size drive the camera distance.
        let computedRadius = simd_length(bMax - bMin) * 0.5
        let radius = computedRadius > 1e-4 ? computedRadius : 1.0

        let aspect = Float(opts.width) / Float(opts.height)
        let fovY: Float = .pi / 4
        // The vertical FOV is the tight axis when aspect ≥ 1; for wider
        // outputs the horizontal would be tighter — use the smaller of the
        // two to make the sphere fit on both axes.
        let effectiveFov = aspect >= 1 ? fovY : 2 * atan(tan(fovY * 0.5) * aspect)
        let fitDistance = radius / sin(effectiveFov * 0.5)
        let distance = fitDistance * opts.cameraDistancePadding

        // Camera direction: slightly above (y) and to the side (x), mostly
        // along +Z so the camera looks toward -Z. Normalised so the
        // distance is exactly `distance`.
        let direction = normalize(SIMD3<Float>(0.5, 0.35, 1.0))
        let eye = center + direction * distance

        let proj = perspectiveProjection(fovY: fovY, aspect: aspect, near: max(distance * 0.01, 0.01), far: distance * 10)
        let view = lookAt(eye: eye, target: center, up: SIMD3<Float>(0, 1, 0))

        if opts.printDiagnostics {
            FileHandle.standardError.write(Data("""
                [GLTFRender diagnostics]
                  Asset bounds:    min=(\(bMin.x), \(bMin.y), \(bMin.z))  max=(\(bMax.x), \(bMax.y), \(bMax.z))
                  Bounds center:   (\(center.x), \(center.y), \(center.z))
                  Sphere radius:   \(radius)
                  Effective FOV:   \(effectiveFov * 180 / .pi)°  (aspect \(aspect))
                  Fit distance:    \(fitDistance)
                  Eye position:    (\(eye.x), \(eye.y), \(eye.z))
                  Draw calls:      \(asset.drawCalls.count)
                  Animations:      \(asset.animations.count)
                  Lights:          \(asset.lights.count)\n
                """.utf8))
        }

        // Pick draw calls (animated if a clip is asked for, else rest pose).
        let calls: [GLTFDrawCall]
        if !asset.animations.isEmpty,
           opts.animationIndex >= 0,
           opts.animationIndex < asset.animations.count,
           opts.animationTime > 0 {
            calls = asset.drawCalls(animationIndex: opts.animationIndex, time: opts.animationTime)
        } else {
            calls = asset.drawCalls
        }

        let scene = GLTFSceneState(
            viewProjection: proj * view,
            cameraPosition: eye,
            lightDirection: normalize(SIMD3<Float>(-0.3, -1.0, -0.4)),
            lightColor: SIMD3<Float>(3, 3, 3),
            lights: asset.lights
        )

        // --- Offscreen render pass ---------------------------------------

        // Single-sample texture for PNG readback (also serves as the
        // render target when MSAA is off, or the resolve target when on).
        let resolveDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorFormat, width: opts.width, height: opts.height, mipmapped: false
        )
        resolveDescriptor.usage = [.renderTarget, .shaderRead]
        resolveDescriptor.storageMode = .shared
        guard let resolveTexture = device.makeTexture(descriptor: resolveDescriptor) else {
            throw GLTFRenderError.textureAllocationFailed
        }

        let colorTexture: MTLTexture
        if opts.sampleCount > 1 {
            let msaaColorDescriptor = MTLTextureDescriptor()
            msaaColorDescriptor.textureType = .type2DMultisample
            msaaColorDescriptor.pixelFormat = colorFormat
            msaaColorDescriptor.width = opts.width
            msaaColorDescriptor.height = opts.height
            msaaColorDescriptor.sampleCount = opts.sampleCount
            msaaColorDescriptor.usage = [.renderTarget]
            msaaColorDescriptor.storageMode = .private
            guard let t = device.makeTexture(descriptor: msaaColorDescriptor) else {
                throw GLTFRenderError.textureAllocationFailed
            }
            colorTexture = t
        } else {
            colorTexture = resolveTexture
        }

        let depthDescriptor2 = MTLTextureDescriptor()
        depthDescriptor2.textureType = opts.sampleCount > 1 ? .type2DMultisample : .type2D
        depthDescriptor2.pixelFormat = depthFormat
        depthDescriptor2.width = opts.width
        depthDescriptor2.height = opts.height
        depthDescriptor2.sampleCount = opts.sampleCount
        depthDescriptor2.usage = [.renderTarget]
        depthDescriptor2.storageMode = .private
        guard let depthTexture = device.makeTexture(descriptor: depthDescriptor2) else {
            throw GLTFRenderError.textureAllocationFailed
        }

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = colorTexture
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0.08, green: 0.10, blue: 0.15, alpha: 1)
        if opts.sampleCount > 1 {
            renderPass.colorAttachments[0].resolveTexture = resolveTexture
            renderPass.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            renderPass.colorAttachments[0].storeAction = .store
        }
        renderPass.depthAttachment.texture = depthTexture
        renderPass.depthAttachment.loadAction = .clear
        renderPass.depthAttachment.clearDepth = 1.0
        renderPass.depthAttachment.storeAction = .dontCare

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            throw GLTFRenderError.commandBufferFailed("encoder")
        }

        renderer.encodeOpaqueDrawCalls(
            calls,
            scene: scene,
            pipelineStates: pipelines,
            depthState: depthState,
            encoder: encoder
        )
        encoder.endEncoding()
        commandBuffer.commit()
        await commandBuffer.completed()
        if let error = commandBuffer.error {
            throw GLTFRenderError.commandBufferFailed(error.localizedDescription)
        }

        try exportTexture(resolveTexture, to: opts.outputPath)
        let msaaTag = opts.sampleCount > 1 ? ", \(opts.sampleCount)× MSAA" : ""
        print("✅ Wrote \(opts.outputPath) (\(opts.width)×\(opts.height), \(calls.count) draw calls\(msaaTag))")
    }
}
