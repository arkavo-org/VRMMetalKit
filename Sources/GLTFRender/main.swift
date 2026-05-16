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
    var cameraDistanceScale: Float = 1.5  // Multiplied against asset bounds diagonal.
    var enableIBL: Bool = true
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
      --camera-distance <s> Camera distance scale; the camera is placed
                           at `bounds_diagonal * s` from the asset center.
                           Default: 1.5

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
        case "--camera-distance":
            i += 1; opts.cameraDistanceScale = Float(args[i]) ?? opts.cameraDistanceScale
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
        let pipelines = try renderer.makePipelineStates(colorFormat: colorFormat, depthFormat: depthFormat)

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw GLTFRenderError.commandBufferFailed("depth state")
        }

        // --- Auto-framing -------------------------------------------------
        // World bounds in GLTFAsset are best-effort (translation-only). Frame
        // a comfortable camera distance from the bounds diagonal, looking at
        // the bounds centre.
        let bMin = asset.worldBounds.min
        let bMax = asset.worldBounds.max
        let center = (bMin + bMax) * 0.5
        let diag = simd_length(bMax - bMin)
        // Fallback if bounds collapse (single-point assets like AnimatedCube).
        let safeDiag = max(diag, 1.0)
        let distance = max(safeDiag * opts.cameraDistanceScale, 1.0)
        let eye = center + SIMD3<Float>(0.7, 0.5, 1.0) * distance

        let aspect = Float(opts.width) / Float(opts.height)
        let proj = perspectiveProjection(fovY: .pi / 4, aspect: aspect, near: 0.05, far: max(distance * 10, 100))
        let view = lookAt(eye: eye, target: center, up: SIMD3<Float>(0, 1, 0))

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

        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorFormat, width: opts.width, height: opts.height, mipmapped: false
        )
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        colorDescriptor.storageMode = .shared
        guard let colorTexture = device.makeTexture(descriptor: colorDescriptor) else {
            throw GLTFRenderError.textureAllocationFailed
        }
        let depthDescriptor2 = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: depthFormat, width: opts.width, height: opts.height, mipmapped: false
        )
        depthDescriptor2.usage = [.renderTarget]
        depthDescriptor2.storageMode = .private
        guard let depthTexture = device.makeTexture(descriptor: depthDescriptor2) else {
            throw GLTFRenderError.textureAllocationFailed
        }

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = colorTexture
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0.08, green: 0.10, blue: 0.15, alpha: 1)
        renderPass.colorAttachments[0].storeAction = .store
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

        try exportTexture(colorTexture, to: opts.outputPath)
        print("✅ Wrote \(opts.outputPath) (\(opts.width)×\(opts.height), \(calls.count) draw calls)")
    }
}
