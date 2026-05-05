import XCTest
import Metal
@testable import VRMMetalKit

final class AliciaSolidDressDebugTests: XCTestCase {
    @MainActor
    func testRenderOtherZWriteIsolated() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTSkip("No Metal device")
            return
        }
        
        let modelURL = URL(fileURLWithPath: "../GameOfMods/AliciaSolid_vrm-0.51.vrm")
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        // Find Alicia_other_zwrite
        for (i, mat) in model.materials.enumerated() {
            if mat.name == "Alicia_other_zwrite" {
                print("[DEBUG] Alicia_other_zwrite at index \(i)")
                print("  alphaMode: \(mat.alphaMode)")
                print("  blendMode: \(mat.blendMode)")
                print("  isTransparentWithZWrite: \(mat.isTransparentWithZWrite)")
                print("  renderQueue: \(mat.renderQueue)")
                print("  zWriteEnabled: \(mat.zWriteEnabled)")
                print("  baseColorFactor: \(mat.baseColorFactor)")
                print("  hasTexture: \(mat.baseColorTexture != nil)")
            }
        }
        
        let width = 512
        let height = 512
        
        // Helper to render and save
        func renderAndSave(config: RendererConfig, path: String) throws {
            let renderer = VRMRenderer(device: device, config: config)
            renderer.loadModel(model)
            renderer.viewMatrix = makeLookAt(eye: SIMD3<Float>(0, 1.3, 1.8), target: SIMD3<Float>(0, 1.3, 0), up: SIMD3<Float>(0, 1, 0))
            renderer.projectionMatrix = makePerspectiveProjection(fovY: Float(60 * Double.pi / 180), aspectRatio: Float(width)/Float(height), nearZ: 0.01, farZ: 100)
            
            let colorDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: config.colorPixelFormat, width: width, height: height, mipmapped: false)
            colorDesc.usage = [.renderTarget, .shaderRead]
            colorDesc.storageMode = .shared
            let colorTex = device.makeTexture(descriptor: colorDesc)!
            
            let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
            depthDesc.usage = [.renderTarget]
            depthDesc.storageMode = .private
            let depthTex = device.makeTexture(descriptor: depthDesc)!
            
            let readback = device.makeBuffer(length: width * height * 4, options: .storageModeShared)!
            
            guard let commandBuffer = device.makeCommandQueue()?.makeCommandBuffer() else {
                XCTFail("No command buffer")
                return
            }
            
            let rpDesc = MTLRenderPassDescriptor()
            rpDesc.colorAttachments[0].texture = colorTex
            rpDesc.colorAttachments[0].loadAction = .clear
            rpDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0.15, green: 0.17, blue: 0.21, alpha: 1.0)
            rpDesc.colorAttachments[0].storeAction = .store
            rpDesc.depthAttachment.texture = depthTex
            rpDesc.depthAttachment.loadAction = .clear
            rpDesc.depthAttachment.clearDepth = 1.0
            rpDesc.depthAttachment.storeAction = .store
            
            renderer.drawOffscreenHeadless(to: colorTex, depth: depthTex, commandBuffer: commandBuffer, renderPassDescriptor: rpDesc)
            
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(from: colorTex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: width, height: height, depth: 1), to: readback, destinationOffset: 0, destinationBytesPerRow: width * 4, destinationBytesPerImage: width * height * 4)
                blit.endEncoding()
            }
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            
            let pixelData = Data(bytes: readback.contents(), count: width * height * 4)
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            let provider = CGDataProvider(data: pixelData as CFData)!
            let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let rep = NSBitmapImageRep(cgImage: image)
            let pngData = rep.representation(using: .png, properties: [:])!
            try pngData.write(to: URL(fileURLWithPath: path))
            print("[DEBUG] Saved to \(path)")
        }
        
        // Full render
        var config1 = RendererConfig(strict: .off)
        config1.colorPixelFormat = .bgra8Unorm_srgb
        try renderAndSave(config: config1, path: "/tmp/v051_full_debug.png")
        
        // Alicia_other_zwrite only
        var config2 = RendererConfig(strict: .off)
        config2.colorPixelFormat = .bgra8Unorm_srgb
        config2.renderFilter = .material("Alicia_other_zwrite")
        try renderAndSave(config: config2, path: "/tmp/v051_other_zwrite_only.png")
        
        // Alicia_wear only
        var config3 = RendererConfig(strict: .off)
        config3.colorPixelFormat = .bgra8Unorm_srgb
        config3.renderFilter = .material("Alicia_wear")
        try renderAndSave(config: config3, path: "/tmp/v051_wear_only.png")
    }
}
