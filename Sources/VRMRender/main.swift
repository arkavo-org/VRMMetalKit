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
import MetalKit
import VRMMetalKit
import UniformTypeIdentifiers
import CoreGraphics

// MARK: - Texture Export

func exportTexture(_ texture: MTLTexture, to path: String, device: MTLDevice) throws {
    let width = texture.width
    let height = texture.height
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    let bytesPerImage = height * bytesPerRow
    
    // Read texture data
    var pixelData = Data(count: bytesPerImage)
    
    pixelData.withUnsafeMutableBytes { rawBuffer in
        guard let pointer = rawBuffer.baseAddress else { return }
        texture.getBytes(pointer, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    }
    
    // Create CGImage
    guard let provider = CGDataProvider(data: pixelData as CFData) else {
        throw RenderError.failedToCreateImage
    }
    
    let bitmapInfo: CGBitmapInfo
    switch texture.pixelFormat {
    case .rgba8Unorm, .rgba8Unorm_srgb:
        bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    case .bgra8Unorm, .bgra8Unorm_srgb:
        bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    default:
        // For other formats, try RGBA
        bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    
    guard let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ) else {
        throw RenderError.failedToCreateImage
    }
    
    // Save to file
    let url = URL(fileURLWithPath: path)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw RenderError.failedToSaveImage
    }
    
    CGImageDestinationAddImage(destination, image, nil)
    
    if !CGImageDestinationFinalize(destination) {
        throw RenderError.failedToSaveImage
    }
}

// MARK: - CLI Arguments

struct RenderOptions {
    var inputPath: String = ""
    var outputPath: String = ""
    var width: Int = 1024
    var height: Int = 1024
    var debugMode: Int = 0
    var cameraPosition: SIMD3<Float> = SIMD3<Float>(0, 1.3, -1.8)
    var cameraTarget: SIMD3<Float> = SIMD3<Float>(0, 1.3, 0)
    var sampleCount: Int = 4
    var bgColorTop: SIMD3<Float> = SIMD3<Float>(0.15, 0.18, 0.25)
    var bgColorBottom: SIMD3<Float> = SIMD3<Float>(0.08, 0.08, 0.12)
}

// MARK: - Errors

enum RenderError: Error {
    case failedToCreateImage
    case failedToSaveImage
    case failedToCreateTexture
    case failedToCreateCommandBuffer
}

// MARK: - Debug Modes

let debugModes: [(id: Int, name: String, description: String)] = [
    (0, "normal", "Normal rendering"),
    (1, "uvs", "Show UV coordinates as colors"),
    (2, "hasTexture", "Show hasBaseColorTexture flag (green=yes, red=no)"),
    (3, "baseColorFactor", "Show baseColorFactor directly"),
    (4, "rawTexture", "Show sampled texture directly (no lighting)"),
    (5, "normals", "Show world normal direction as colors"),
    (6, "lightColor", "Show light color"),
    (7, "ndotl", "Show NdotL (diffuse lighting term)"),
    (8, "lightDir", "Show light direction"),
    (9, "litColor", "Show litColor before saturation (scaled by 0.25)"),
    (10, "viewDir", "Show view direction"),
    (11, "normalFlip", "Show where normals were flipped (magenta)"),
    (12, "rawBase", "Show raw base color (texture * factor, no lighting)"),
    (13, "vertexColor", "Show vertex color only"),
    (14, "shadowStep", "Show shadowStep as grayscale"),
    (15, "lightingFactor", "Show lightingFactor (lit/shadow interpolation)"),
    (16, "rawNdotL", "Show raw NdotL as color (green=positive, red=negative)"),
]

// MARK: - Print Usage

func printUsage() {
    print("""
    VRMRender - Render VRM models to image files
    
    USAGE:
        swift run VRMRender [options] <input.vrm> <output.png>
    
    OPTIONS:
        -w, --width <pixels>       Output width (default: 1024)
        -h, --height <pixels>      Output height (default: 1024)
        -d, --debug <mode>         Debug mode (0-16, default: 0)
        --camera-pos <x,y,z>       Camera position (default: 0,1.3,-1.8)
        --camera-target <x,y,z>    Camera look-at target (default: 0,1.3,0)
        --msaa <samples>           MSAA sample count (1, 2, 4, default: 4)
        --list-debug               List all debug modes
        --help                     Show this help message
    
    DEBUG MODES:
    """)
    for mode in debugModes {
        print(String(format: "        %2d: %-20s - %@", mode.id, mode.name, mode.description))
    }
    print("""
    
    EXAMPLES:
        swift run VRMRender model.vrm output.png
        swift run VRMRender -w 2048 -h 2048 model.vrm output.png
        swift run VRMRender -d 4 model.vrm output_texture.png
        swift run VRMRender --camera-pos 0,1.5,1 model.vrm output_front.png
    """)
}

// MARK: - Parse Arguments

func parseArguments() -> RenderOptions? {
    let args = CommandLine.arguments
    
    if args.count < 2 {
        printUsage()
        return nil
    }
    
    if args.contains("--help") || args.contains("-?") {
        printUsage()
        return nil
    }
    
    if args.contains("--list-debug") {
        print("Available debug modes:")
        for mode in debugModes {
            print(String(format: "  %2d: %-20s - %@", mode.id, mode.name, mode.description))
        }
        return nil
    }
    
    var options = RenderOptions()
    var i = 1
    var positionalArgs: [String] = []
    
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
        case "-d", "--debug":
            i += 1
            if i < args.count, let val = Int(args[i]) {
                options.debugMode = val
            }
        case "--camera-pos":
            i += 1
            if i < args.count {
                let parts = args[i].split(separator: ",").compactMap { Float($0) }
                if parts.count == 3 {
                    options.cameraPosition = SIMD3<Float>(parts[0], parts[1], parts[2])
                }
            }
        case "--camera-target":
            i += 1
            if i < args.count {
                let parts = args[i].split(separator: ",").compactMap { Float($0) }
                if parts.count == 3 {
                    options.cameraTarget = SIMD3<Float>(parts[0], parts[1], parts[2])
                }
            }
        case "--msaa":
            i += 1
            if i < args.count, let val = Int(args[i]) {
                options.sampleCount = val
            }
        default:
            if !arg.hasPrefix("-") {
                positionalArgs.append(arg)
            }
        }
        
        i += 1
    }
    
    guard positionalArgs.count >= 2 else {
        print("Error: Missing input or output path")
        printUsage()
        return nil
    }
    
    options.inputPath = positionalArgs[0]
    options.outputPath = positionalArgs[1]
    
    return options
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

// MARK: - Main

@main
struct VRMRenderCLI {
    static func main() async {
        guard let options = parseArguments() else {
            exit(0)
        }
        
        // Validate input file
        guard FileManager.default.fileExists(atPath: options.inputPath) else {
            print("Error: Input file not found: \(options.inputPath)")
            exit(1)
        }
        
        // Get Metal device
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("Error: Metal is not available on this system")
            exit(1)
        }
        
        print("VRMRender - Rendering VRM to image")
        print("=====================================")
        print("Input:  \(options.inputPath)")
        print("Output: \(options.outputPath)")
        print("Size:   \(options.width)x\(options.height)")
        print("MSAA:   \(options.sampleCount)x")
    print("Quality: High (rim lighting, studio setup)")
        if options.debugMode > 0 {
            if let mode = debugModes.first(where: { $0.id == options.debugMode }) {
                print("Debug:  \(mode.id) - \(mode.name)")
            }
        }
        print("")
        
        do {
            // Load the VRM model
            print("Loading VRM model...")
            let modelURL = URL(fileURLWithPath: options.inputPath)
            let model = try await VRMModel.load(from: modelURL, device: device)
            print("  ✓ Loaded: \(model.meta.name ?? "Unnamed")")
            print("  ✓ Materials: \(model.materials.count)")
            print("  ✓ Meshes: \(model.meshes.count)")
            print("")
            
            // Create renderer
            print("Setting up renderer...")
            var config = RendererConfig()
            config.sampleCount = options.sampleCount
            config.strict = .off
            
            let renderer = VRMRenderer(device: device, config: config)
            renderer.loadModel(model)
            
            // Pure anime/cel-shading: Single key light for hard step shadows
            // No fill light = hard edges between light and shadow (traditional anime look)
            renderer.setLight(0, direction: SIMD3<Float>(-0.2, 0.5, -0.85), 
                              color: SIMD3<Float>(1.0, 1.0, 1.0), intensity: 1.0)
            
            // Fill light disabled - crucial for cel-shading
            renderer.disableLight(1)
            
            // Subtle rim light for edge definition only
            renderer.setLight(2, direction: SIMD3<Float>(0.0, 0.2, 1.0), 
                              color: SIMD3<Float>(1.0, 1.0, 1.0), intensity: 0.3)
            
            // Very low ambient for high contrast (anime style)
            renderer.setAmbientColor(SIMD3<Float>(0.03, 0.03, 0.05))
            
            // Calculate bounding box for auto-framing
            let (minBounds, maxBounds) = model.calculateBoundingBox()
            let center = (minBounds + maxBounds) / 2
            let size = maxBounds - minBounds
            let maxDimension = max(size.x, max(size.y, size.z))
            
            print("  ✓ Model bounds: \(size)")
            print("  ✓ Center: \(center)")
            
            // Set up camera matrices
            let aspect = Float(options.width) / Float(options.height)
            renderer.projectionMatrix = perspective(fovRadians: Float(45.0 * .pi / 180.0), aspect: aspect, near: 0.01, far: 100.0)
            renderer.viewMatrix = lookAt(eye: options.cameraPosition, center: options.cameraTarget, up: SIMD3<Float>(0, 1, 0))
            
            print("")
            print("Rendering...")
            
            // Create textures for offscreen rendering
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: options.width,
                height: options.height,
                mipmapped: false
            )
            textureDescriptor.usage = [.renderTarget, .shaderRead]
            textureDescriptor.storageMode = .shared
            
            guard let colorTexture = device.makeTexture(descriptor: textureDescriptor) else {
                throw RenderError.failedToCreateTexture
            }
            
            // Depth texture
            let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .depth32Float,
                width: options.width,
                height: options.height,
                mipmapped: false
            )
            depthDescriptor.usage = .renderTarget
            depthDescriptor.storageMode = .shared
            
            guard let depthTexture = device.makeTexture(descriptor: depthDescriptor) else {
                throw RenderError.failedToCreateTexture
            }
            
            // Create render pass descriptor
            let renderPassDescriptor = MTLRenderPassDescriptor()
            renderPassDescriptor.colorAttachments[0].texture = colorTexture
            renderPassDescriptor.colorAttachments[0].loadAction = .clear
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            // Studio lighting background - dark blue-gray gradient
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
                red: 0.12, 
                green: 0.14, 
                blue: 0.18, 
                alpha: 1.0
            )
            
            renderPassDescriptor.depthAttachment.texture = depthTexture
            renderPassDescriptor.depthAttachment.loadAction = .clear
            renderPassDescriptor.depthAttachment.storeAction = .dontCare
            renderPassDescriptor.depthAttachment.clearDepth = 1.0
            
            // Create command buffer
            guard let commandQueue = device.makeCommandQueue(),
                  let commandBuffer = commandQueue.makeCommandBuffer() else {
                throw RenderError.failedToCreateCommandBuffer
            }
            
            // Render
            renderer.drawOffscreenHeadless(
                to: colorTexture,
                depth: depthTexture,
                commandBuffer: commandBuffer,
                renderPassDescriptor: renderPassDescriptor
            )
            
            // Add completion handler before commit
            await withCheckedContinuation { continuation in
                commandBuffer.addCompletedHandler { _ in
                    continuation.resume()
                }
                commandBuffer.commit()
            }
            
            print("  ✓ Rendered to texture")
            print("")
            
            // Export to PNG
            print("Exporting to PNG...")
            try exportTexture(colorTexture, to: options.outputPath, device: device)
            print("  ✓ Saved: \(options.outputPath)")
            
            print("")
            print("✅ Render complete!")
            
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
