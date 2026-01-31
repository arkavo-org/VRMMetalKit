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
    var cameraPosition: SIMD3<Float> = SIMD3<Float>(0, 1.5, 2.0)
    var cameraTarget: SIMD3<Float> = SIMD3<Float>(0, 1.5, 0)
    var sampleCount: Int = 1
}

// MARK: - Errors

enum RenderError: Error {
    case failedToCreateImage
    case failedToSaveImage
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
        --camera-pos <x,y,z>       Camera position (default: 0,1.5,2)
        --camera-target <x,y,z>    Camera look-at target (default: 0,1.5,0)
        --msaa <samples>           MSAA sample count (1, 2, 4, default: 1)
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
            
            // Print material info
            print("Material Details:")
            for (i, mat) in model.materials.enumerated() {
                let name = mat.name ?? "Material_\(i)"
                let alpha = mat.alphaMode
                print("  [\(i)] \(name) - \(alpha)")
            }
            print("")
            
            // Print mesh info for face materials
            print("Mesh/Primitive Analysis for Face Materials:")
            for (i, mat) in model.materials.enumerated() {
                let name = mat.name ?? "Material_\(i)"
                if name.lowercased().contains("face") || name.lowercased().contains("mouth") {
                    print("  Material [\(i)]: \(name)")
                    // Find meshes using this material
                    for (meshIdx, mesh) in model.meshes.enumerated() {
                        for (primIdx, prim) in mesh.primitives.enumerated() {
                            if prim.materialIndex == i {
                                print("    → Mesh \(meshIdx), Prim \(primIdx): \(prim.vertexCount) vertices, \(prim.indexCount) indices")
                                print("      Has texCoords: \(prim.hasTexCoords)")
                            }
                        }
                    }
                }
            }
            
            // Export textures for inspection
            print("")
            print("Exporting textures...")
            let outputDir = (options.outputPath as NSString).deletingLastPathComponent
            for (i, texture) in model.textures.enumerated() {
                if let mtlTexture = texture.mtlTexture {
                    let texturePath = "\(outputDir)/texture_\(i).png"
                    do {
                        try exportTexture(mtlTexture, to: texturePath, device: device)
                        print("  ✓ Exported: \(texturePath)")
                    } catch {
                        print("  ✗ Failed to export texture \(i): \(error)")
                    }
                }
            }
            
            print("")
            print("Model loaded successfully!")
            print("Textures exported to: \(outputDir)")
            
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
