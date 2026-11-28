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
import CoreGraphics
import ImageIO
import Metal
import simd

/// Errors raised by VRMMetalKit cosmetic texture compositing and decoding.
public enum VRMCosmeticError: Error, LocalizedError, Sendable {
    case unsupportedPixelFormat(MTLPixelFormat, context: String)
    case imageDecodingFailed(context: String)
    case computePipelineUnavailable(String)
    case invalidCanvasSize(width: Int, height: Int)
    case textureAllocationFailed(width: Int, height: Int, pixelFormat: MTLPixelFormat)
    case commandEncodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPixelFormat(let format, let context):
            return """
            [VRMCosmeticError] Unsupported base texture pixel format \(format.rawValue).
            Where: \(context)
            Suggestion: Provide a color or compressed color texture (e.g. rgba8Unorm, rgba8Unorm_srgb, bgra8Unorm_srgb, bc7_rgbaUnorm_srgb, astc_4x4_srgb). Depth, stencil, integer, and planar YUV formats cannot be composited.
            Spec: https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_materials_mtoon-1.0/README.md
            """
        case .imageDecodingFailed(let context):
            return """
            [VRMCosmeticError] Failed to decode cosmetic image data in memory.
            Where: \(context)
            Suggestion: Supply valid PNG, JPEG, or HEIF image bytes (not corrupted or empty) to VRMTextureLayerStack.makeTexture(from:device:sRGB:).
            Spec: https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#images
            """
        case .computePipelineUnavailable(let detail):
            return """
            [VRMCosmeticError] Cosmetic compute pipeline could not be created: \(detail)
            Where: VRMTextureLayerStack (CosmeticComposite.metal)
            Suggestion: Ensure VRMMetalKitShaders metallib slices are up to date by running `make shaders`.
            Spec: https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_materials_mtoon-1.0/README.md
            """
        case .invalidCanvasSize(let width, let height):
            return """
            [VRMCosmeticError] Invalid cosmetic composite canvas dimensions (\(width)x\(height)).
            Where: VRMTextureLayerStack.encodeComposite
            Suggestion: Pass explicit positive width/height or supply a non-nil base texture or at least one visible layer.
            Spec: https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#textures
            """
        case .textureAllocationFailed(let width, let height, let pixelFormat):
            return """
            [VRMCosmeticError] Failed to allocate Metal texture (\(width)x\(height), format \(pixelFormat.rawValue)).
            Where: VRMTextureLayerStack
            Suggestion: Check device texture limits and available GPU memory, or reduce output canvas resolution.
            Spec: https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#textures
            """
        case .commandEncodingFailed(let detail):
            return """
            [VRMCosmeticError] Failed to encode cosmetic GPU command: \(detail)
            Where: VRMTextureLayerStack
            Suggestion: Ensure the Metal command queue and command buffer are valid and not already committed.
            Spec: https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_materials_mtoon-1.0/README.md
            """
        }
    }
}

/// Blend modes supported by the GPU cosmetic texture compositor (`CosmeticComposite.metal`).
public enum VRMTextureBlendMode: UInt32, Codable, Sendable {
    case normal = 0
    case multiply = 1
    case screen = 2
    case overlay = 3
    case additive = 4
    case eraseAlpha = 5
}

/// Per-layer metallic/roughness finish override written into the glTF-packed
/// finish map (`G = roughness`, `B = metallic`) sampled by `MToonShader.metal` `texture(9)`.
public struct VRMFinishOverride: Codable, Equatable, Sendable {
    public var metallic: Float
    public var roughness: Float

    public init(metallic: Float, roughness: Float) {
        self.metallic = metallic
        self.roughness = roughness
    }
}

/// One compositable 2D decal, makeup, tattoo, or alpha-cutout layer.
public struct VRMTextureLayer: Identifiable, @unchecked Sendable {
    public let id: UUID
    public var name: String?
    public var texture: MTLTexture
    public var blendMode: VRMTextureBlendMode
    public var opacity: Float
    public var tint: SIMD4<Float>
    public var finish: VRMFinishOverride?
    public var landmarkRegion: VRMFaceLandmarkRegion?
    public var uvOffset: SIMD2<Float>
    public var uvScale: SIMD2<Float>
    public var uvRotation: Float
    public var isVisible: Bool

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        texture: MTLTexture,
        blendMode: VRMTextureBlendMode = .normal,
        opacity: Float = 1.0,
        tint: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1),
        finish: VRMFinishOverride? = nil,
        landmarkRegion: VRMFaceLandmarkRegion? = nil,
        uvOffset: SIMD2<Float> = SIMD2<Float>(0, 0),
        uvScale: SIMD2<Float> = SIMD2<Float>(1, 1),
        uvRotation: Float = 0.0,
        isVisible: Bool = true
    ) {
        self.id = id
        self.name = name
        self.texture = texture
        self.blendMode = blendMode
        self.opacity = opacity
        self.tint = tint
        self.finish = finish
        self.landmarkRegion = landmarkRegion
        self.uvOffset = uvOffset
        self.uvScale = uvScale
        self.uvRotation = uvRotation
        self.isVisible = isVisible
    }
}

/// Material texture slot targeted by ``VRMTextureLayerStack/apply(to:slot:in:commandQueue:)``.
public enum VRMTextureSlot: Hashable, Sendable {
    case baseColor
    case emissive
    case shadeMultiply
}

// MARK: - Metal Uniform Payloads (Mirrors CosmeticComposite.metal)

private struct CosmeticBaseCopyParamsCPU {
    var solidColor: SIMD4<Float>
    var baseMultiplier: SIMD4<Float>
    var hasBaseTexture: UInt32
    var decodeBaseSRGB: UInt32
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
}

private struct CosmeticLayerParamsCPU {
    var tint: SIMD4<Float>
    var rectMin: SIMD2<Float>
    var rectSize: SIMD2<Float>
    var uvOffset: SIMD2<Float>
    var uvScale: SIMD2<Float>
    var uvRotation: Float
    var opacity: Float
    var blendMode: UInt32
    var decodeLayerSRGB: UInt32
    var finishMetallic: Float
    var finishRoughness: Float
    var hasFinish: UInt32
    var pad0: UInt32 = 0
}

private struct CosmeticFinalizeParamsCPU {
    var encodeSRGB: UInt32
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
    var pad2: UInt32 = 0
}

/// GPU-accelerated 2D layer compositor for runtime avatar makeup, decals, tattoos,
/// emissive markings, alpha cutouts, and per-pixel glossy/metallic finishes.
///
/// ## Key Guarantees
/// - **Zero disk I/O**: ``makeTexture(from:device:sRGB:label:)`` decodes PNG/JPEG/HEIF
///   directly from in-memory `Data` (TDF-friendly) into GPU memory.
/// - **Linked `shadeMultiplyTexture` sync**: When applied to `.baseColor`, automatically
///   keeps a linked MToon `shadeMultiplyTexture` (same `VRMTexture` wrapper OR distinct
///   wrapper sharing the same `MTLTexture`) in sync so shadow-side shading matches makeup
///   and preserves the shader's `shadeUsesBaseColor` zero-extra-fetch fast path.
/// - **Complete mipmap chains & BC7/sRGB support**: Samples compressed base atlases through
///   Metal's hardware sampler, composites in linear float16, writes a full mipmapped
///   `.rgba8Unorm_srgb` / `.rgba8Unorm` texture, and rejects unsupported formats with
///   ``VRMCosmeticError/unsupportedPixelFormat(_:context:)``.
public final class VRMTextureLayerStack: @unchecked Sendable {
    public let device: MTLDevice
    public var layers: [VRMTextureLayer]
    public var faceLandmarks: VRMFaceLandmarks?
    /// Base color used when compositing without a `baseTexture`.
    public var solidBaseColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)

    /// Most recently composited color texture.
    public private(set) var lastOutputTexture: MTLTexture?
    /// Most recently composited linear finish map (`G=roughness`, `B=metallic`), or `nil` when no visible layer specifies a finish override.
    public private(set) var lastFinishTexture: MTLTexture?

    private let copyBasePipeline: MTLComputePipelineState
    private let compositeLayerPipeline: MTLComputePipelineState
    private let compositeFinishPipeline: MTLComputePipelineState
    private let finalizeOutputPipeline: MTLComputePipelineState
    private let defaultCommandQueue: MTLCommandQueue?

    // Working float16 linear ping-pong canvases + per-target triple-buffered mipmapped output rings
    private var canvasA: MTLTexture?
    private var canvasB: MTLTexture?
    private var canvasSize: (width: Int, height: Int) = (0, 0)

    private struct TextureRing {
        static let slotCount = 3
        var textures: [MTLTexture] = []
        var nextIndex: Int = 0
        var width: Int = 0
        var height: Int = 0
        var sRGB: Bool = false
    }

    // Standalone rings used by direct encodeComposite / composite calls (disjoint from material bindings).
    private var standaloneColorRing = TextureRing()
    private var standaloneFinishRing = TextureRing()

    private var dummy1x1Texture: MTLTexture?

    private struct MaterialBindingKey: Hashable {
        let materialID: ObjectIdentifier
        let slot: VRMTextureSlot
    }

    private struct MaterialBindingState {
        var originalBaseMTLTexture: MTLTexture?
        var createdWrapper: Bool
        var linkedShadeWrapper: VRMTexture?
        var hadLinkedShadeSameWrapper: Bool
        var originalMetallicRoughnessTexture: VRMTexture?
        var originalHasCosmeticFinishMap: Bool
        var originalMetallicFactor: Float
        var originalRoughnessFactor: Float
        var modifiedFinish: Bool
        var colorRing = TextureRing()
        var finishRing = TextureRing()
    }

    private let stateLock = NSLock()
    private var bindings: [MaterialBindingKey: MaterialBindingState] = [:]
    private var bindingGenerations: [MaterialBindingKey: UInt64] = [:]

    /// Creates a GPU texture compositor bound to `device`.
    public init(
        device: MTLDevice,
        layers: [VRMTextureLayer] = [],
        faceLandmarks: VRMFaceLandmarks? = nil
    ) throws {
        self.device = device
        self.layers = layers
        self.faceLandmarks = faceLandmarks
        self.defaultCommandQueue = MetalQueueFactory.makeCommandQueue(device: device)

        let library: MTLLibrary
        do {
            library = try VRMShaderLibraryLoader.loadBundledLibrary(device: device)
        } catch {
            if let fallback = device.makeDefaultLibrary() {
                library = fallback
            } else {
                throw VRMCosmeticError.computePipelineUnavailable(error.localizedDescription)
            }
        }

        func makePipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let fn = library.makeFunction(name: name) else {
                throw VRMCosmeticError.computePipelineUnavailable("Shader function '\(name)' not found in metallib")
            }
            do {
                return try device.makeComputePipelineState(function: fn)
            } catch {
                throw VRMCosmeticError.computePipelineUnavailable("Failed to compile '\(name)': \(error.localizedDescription)")
            }
        }

        self.copyBasePipeline = try makePipeline("cosmetic_copy_base")
        self.compositeLayerPipeline = try makePipeline("cosmetic_composite_layer")
        self.compositeFinishPipeline = try makePipeline("cosmetic_composite_finish")
        self.finalizeOutputPipeline = try makePipeline("cosmetic_finalize_output")
    }

    // MARK: - Zero-Disk In-Memory Image Decoding (TDF-Ready)

    /// Decodes PNG, JPEG, or HEIF image bytes directly from memory into a Metal texture
    /// with straight (unpremultiplied) RGBA8 channels. Never writes to disk.
    public static func makeTexture(
        from imageData: Data,
        device: MTLDevice,
        sRGB: Bool = true,
        label: String? = nil
    ) throws -> MTLTexture {
        guard !imageData.isEmpty,
              let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw VRMCosmeticError.imageDecodingFailed(context: label ?? "in-memory image data (\(imageData.count) bytes)")
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else {
            throw VRMCosmeticError.invalidCanvasSize(width: width, height: height)
        }

        let bytesPerRow = width * 4
        var rgba = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)

        let drawn: Bool = rgba.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress,
                  let ctx = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo.rawValue
                  ) else {
                return false
            }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            throw VRMCosmeticError.imageDecodingFailed(context: "CGContext rasterization failed for \(label ?? "layer")")
        }

        // Unpremultiply RGB so alpha blending in CosmeticComposite.metal sees straight alpha.
        let pixelCount = width * height
        for i in 0..<pixelCount {
            let base = i * 4
            let a = rgba[base + 3]
            if a > 0 && a < 255 {
                let inv = 255.0 / Float(a)
                rgba[base]     = UInt8(min(255, Int((Float(rgba[base]) * inv).rounded())))
                rgba[base + 1] = UInt8(min(255, Int((Float(rgba[base + 1]) * inv).rounded())))
                rgba[base + 2] = UInt8(min(255, Int((Float(rgba[base + 2]) * inv).rounded())))
            }
        }

        let pixelFormat: MTLPixelFormat = sRGB ? .rgba8Unorm_srgb : .rgba8Unorm
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: desc) else {
            throw VRMCosmeticError.textureAllocationFailed(width: width, height: height, pixelFormat: pixelFormat)
        }
        texture.label = label ?? "Cosmetic Layer (\(width)x\(height))"
        rgba.withUnsafeBytes { ptr in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }
        return texture
    }

    /// Uploads raw straight-alpha RGBA8 pixel bytes directly to a Metal texture without
    /// PNG encoding or ImageIO decoding.
    public static func makeTexture(
        rgba8Data: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int? = nil,
        device: MTLDevice,
        sRGB: Bool = true,
        mipmapped: Bool = false,
        label: String? = nil
    ) throws -> MTLTexture {
        guard width > 0, height > 0 else {
            throw VRMCosmeticError.invalidCanvasSize(width: width, height: height)
        }
        let pixelFormat: MTLPixelFormat = sRGB ? .rgba8Unorm_srgb : .rgba8Unorm
        guard let texture = TextureUploader.makeTexture(
            rgba8Data: rgba8Data,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixelFormat: pixelFormat,
            device: device,
            mipmapped: mipmapped
        ) else {
            throw VRMCosmeticError.textureAllocationFailed(
                width: width,
                height: height,
                pixelFormat: pixelFormat
            )
        }
        texture.label = label ?? "Cosmetic Layer RGBA8 (\(width)x\(height))"
        return texture
    }

    // MARK: - Pixel Format Validation

    /// Returns `true` when `format` can be hardware-sampled as a normalized/float color texture
    /// by `CosmeticComposite.metal`.
    public static func isSupportedBasePixelFormat(_ format: MTLPixelFormat) -> Bool {
        switch format {
        case .rgba8Unorm, .rgba8Unorm_srgb,
             .bgra8Unorm, .bgra8Unorm_srgb,
             .rgba16Unorm, .rgba16Float, .rgba32Float,
             .r8Unorm, .rg8Unorm, .r16Float, .rg16Float,
             .rgb10a2Unorm, .bgr10a2Unorm, .rg11b10Float:
            return true
        #if os(macOS)
        case .bc1_rgba, .bc1_rgba_srgb,
             .bc2_rgba, .bc2_rgba_srgb,
             .bc3_rgba, .bc3_rgba_srgb,
             .bc4_rUnorm, .bc5_rgUnorm,
             .bc6H_rgbFloat, .bc6H_rgbuFloat,
             .bc7_rgbaUnorm, .bc7_rgbaUnorm_srgb:
            return true
        #endif
        case .astc_4x4_srgb, .astc_4x4_ldr,
             .astc_6x6_srgb, .astc_6x6_ldr,
             .astc_8x8_srgb, .astc_8x8_ldr,
             .eac_r11Unorm, .eac_rg11Unorm,
             .etc2_rgb8, .etc2_rgb8_srgb,
             .etc2_rgb8a1, .etc2_rgb8a1_srgb,
             .eac_rgba8, .eac_rgba8_srgb:
            return true
        default:
            return false
        }
    }

    // MARK: - Asynchronous & Synchronous GPU Compositing

    /// Encodes GPU compositing of all visible layers onto `commandBuffer`, generating complete
    /// mipmap chains on both the color output and optional per-pixel finish map.
    public func encodeComposite(
        baseTexture: MTLTexture?,
        width explicitWidth: Int? = nil,
        height explicitHeight: Int? = nil,
        sRGB: Bool = true,
        baseFinishTexture: MTLTexture? = nil,
        baseFinishMetallicFactor: Float? = nil,
        baseFinishRoughnessFactor: Float? = nil,
        commandBuffer: MTLCommandBuffer
    ) throws -> (color: MTLTexture, finish: MTLTexture?) {
        try encodeCompositeInternal(
            baseTexture: baseTexture,
            width: explicitWidth,
            height: explicitHeight,
            sRGB: sRGB,
            baseFinishTexture: baseFinishTexture,
            baseFinishMetallicFactor: baseFinishMetallicFactor,
            baseFinishRoughnessFactor: baseFinishRoughnessFactor,
            bindingKey: nil,
            commandBuffer: commandBuffer
        )
    }

    private func encodeCompositeInternal(
        baseTexture: MTLTexture?,
        width explicitWidth: Int?,
        height explicitHeight: Int?,
        sRGB: Bool,
        baseFinishTexture: MTLTexture?,
        baseFinishMetallicFactor: Float?,
        baseFinishRoughnessFactor: Float?,
        bindingKey: MaterialBindingKey?,
        useDedicatedCanvases: Bool = false,
        commandBuffer: MTLCommandBuffer
    ) throws -> (color: MTLTexture, finish: MTLTexture?) {
        if let baseTexture {
            guard Self.isSupportedBasePixelFormat(baseTexture.pixelFormat) else {
                throw VRMCosmeticError.unsupportedPixelFormat(
                    baseTexture.pixelFormat,
                    context: "baseTexture '\(baseTexture.label ?? "unnamed")'"
                )
            }
        }
        if let baseFinishTexture {
            guard Self.isSupportedBasePixelFormat(baseFinishTexture.pixelFormat) else {
                throw VRMCosmeticError.unsupportedPixelFormat(
                    baseFinishTexture.pixelFormat,
                    context: "baseFinishTexture '\(baseFinishTexture.label ?? "unnamed")'"
                )
            }
        }

        let visibleLayers = layers.filter { $0.isVisible && $0.opacity > 0 }
        for layer in visibleLayers {
            guard Self.isSupportedBasePixelFormat(layer.texture.pixelFormat) else {
                throw VRMCosmeticError.unsupportedPixelFormat(
                    layer.texture.pixelFormat,
                    context: "layer '\(layer.name ?? layer.id.uuidString)'"
                )
            }
        }

        let resolvedWidth = explicitWidth ?? baseTexture?.width ?? visibleLayers.first?.texture.width ?? 0
        let resolvedHeight = explicitHeight ?? baseTexture?.height ?? visibleLayers.first?.texture.height ?? 0
        guard resolvedWidth > 0, resolvedHeight > 0 else {
            throw VRMCosmeticError.invalidCanvasSize(width: resolvedWidth, height: resolvedHeight)
        }

        let workingCanvases: (a: MTLTexture, b: MTLTexture)
        if useDedicatedCanvases {
            workingCanvases = try makeWorkingCanvases(width: resolvedWidth, height: resolvedHeight)
        } else {
            try ensureWorkingCanvases(width: resolvedWidth, height: resolvedHeight)
            workingCanvases = (canvasA!, canvasB!)
        }
        let outTexture = try acquireOutputTexture(
            width: resolvedWidth,
            height: resolvedHeight,
            sRGB: sRGB,
            bindingKey: bindingKey
        )
        guard let outWriteView = sRGB ? outTexture.makeTextureView(pixelFormat: .rgba8Unorm) : outTexture else {
            throw VRMCosmeticError.textureAllocationFailed(
                width: resolvedWidth,
                height: resolvedHeight,
                pixelFormat: .rgba8Unorm
            )
        }
        let dummy = try getOrCreateDummyTexture()

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw VRMCosmeticError.commandEncodingFailed("makeComputeCommandEncoder returned nil")
        }
        encoder.label = "VRM Cosmetic Composite"

        // --- Color pass ---
        var src = workingCanvases.a
        var dst = workingCanvases.b

        var copyParams = CosmeticBaseCopyParamsCPU(
            solidColor: solidBaseColor,
            baseMultiplier: SIMD4<Float>(1, 1, 1, 1),
            hasBaseTexture: baseTexture != nil ? 1 : 0,
            decodeBaseSRGB: 0
        )
        encoder.setComputePipelineState(copyBasePipeline)
        encoder.setTexture(baseTexture ?? dummy, index: 0)
        encoder.setTexture(src, index: 1)
        encoder.setBytes(&copyParams, length: MemoryLayout<CosmeticBaseCopyParamsCPU>.stride, index: 0)
        dispatch2D(encoder: encoder, pipeline: copyBasePipeline, width: resolvedWidth, height: resolvedHeight)

        for layer in visibleLayers {
            var layerParams = makeLayerParams(for: layer)
            encoder.setComputePipelineState(compositeLayerPipeline)
            encoder.setTexture(src, index: 0)
            encoder.setTexture(layer.texture, index: 1)
            encoder.setTexture(dst, index: 2)
            encoder.setBytes(&layerParams, length: MemoryLayout<CosmeticLayerParamsCPU>.stride, index: 0)
            dispatch2D(encoder: encoder, pipeline: compositeLayerPipeline, width: resolvedWidth, height: resolvedHeight)
            swap(&src, &dst)
        }

        var finalizeColor = CosmeticFinalizeParamsCPU(encodeSRGB: sRGB ? 1 : 0)
        encoder.setComputePipelineState(finalizeOutputPipeline)
        encoder.setTexture(src, index: 0)
        encoder.setTexture(outWriteView, index: 1)
        encoder.setBytes(&finalizeColor, length: MemoryLayout<CosmeticFinalizeParamsCPU>.stride, index: 0)
        dispatch2D(encoder: encoder, pipeline: finalizeOutputPipeline, width: resolvedWidth, height: resolvedHeight)

        // --- Optional per-pixel finish pass (G=roughness, B=metallic) ---
        let hasFinishLayers = visibleLayers.contains { $0.finish != nil }
        var finishTexture: MTLTexture? = nil

        if hasFinishLayers {
            let finOut = try acquireFinishTexture(
                width: resolvedWidth,
                height: resolvedHeight,
                bindingKey: bindingKey
            )
            src = workingCanvases.a
            dst = workingCanvases.b

            let solidRoughness = max(0, min(1, baseFinishRoughnessFactor ?? 1.0))
            let solidMetallic = max(0, min(1, baseFinishMetallicFactor ?? 0.0))
            let mulRoughness = max(0, min(1, baseFinishRoughnessFactor ?? 1.0))
            let mulMetallic = max(0, min(1, baseFinishMetallicFactor ?? 1.0))

            var finCopy = CosmeticBaseCopyParamsCPU(
                solidColor: SIMD4<Float>(0, solidRoughness, solidMetallic, 1),
                baseMultiplier: SIMD4<Float>(1, mulRoughness, mulMetallic, 1),
                hasBaseTexture: baseFinishTexture != nil ? 1 : 0,
                decodeBaseSRGB: 0
            )
            encoder.setComputePipelineState(copyBasePipeline)
            encoder.setTexture(baseFinishTexture ?? dummy, index: 0)
            encoder.setTexture(src, index: 1)
            encoder.setBytes(&finCopy, length: MemoryLayout<CosmeticBaseCopyParamsCPU>.stride, index: 0)
            dispatch2D(encoder: encoder, pipeline: copyBasePipeline, width: resolvedWidth, height: resolvedHeight)

            for layer in visibleLayers where layer.finish != nil || layer.blendMode == .eraseAlpha {
                var layerParams = makeLayerParams(for: layer)
                encoder.setComputePipelineState(compositeFinishPipeline)
                encoder.setTexture(src, index: 0)
                encoder.setTexture(layer.texture, index: 1)
                encoder.setTexture(dst, index: 2)
                encoder.setBytes(&layerParams, length: MemoryLayout<CosmeticLayerParamsCPU>.stride, index: 0)
                dispatch2D(encoder: encoder, pipeline: compositeFinishPipeline, width: resolvedWidth, height: resolvedHeight)
                swap(&src, &dst)
            }

            var finalizeFinish = CosmeticFinalizeParamsCPU(encodeSRGB: 0)
            encoder.setComputePipelineState(finalizeOutputPipeline)
            encoder.setTexture(src, index: 0)
            encoder.setTexture(finOut, index: 1)
            encoder.setBytes(&finalizeFinish, length: MemoryLayout<CosmeticFinalizeParamsCPU>.stride, index: 0)
            dispatch2D(encoder: encoder, pipeline: finalizeOutputPipeline, width: resolvedWidth, height: resolvedHeight)
            finishTexture = finOut
        }

        encoder.endEncoding()

        // Generate full mipmap chains on the composited textures
        let needsColorMips = outTexture.mipmapLevelCount > 1
        let needsFinishMips = (finishTexture?.mipmapLevelCount ?? 0) > 1
        if needsColorMips || needsFinishMips {
            guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                throw VRMCosmeticError.commandEncodingFailed("makeBlitCommandEncoder returned nil for mipmap generation")
            }
            blit.label = "VRM Cosmetic Mipmaps"
            if needsColorMips {
                blit.generateMipmaps(for: outTexture)
            }
            if let finishTexture, needsFinishMips {
                blit.generateMipmaps(for: finishTexture)
            }
            blit.endEncoding()
        }

        lastOutputTexture = outTexture
        lastFinishTexture = finishTexture
        return (color: outTexture, finish: finishTexture)
    }

    /// Synchronously composites all visible layers and blocks until GPU completion.
    @discardableResult
    public func composite(
        baseTexture: MTLTexture?,
        width: Int? = nil,
        height: Int? = nil,
        sRGB: Bool = true,
        baseFinishTexture: MTLTexture? = nil,
        baseFinishMetallicFactor: Float? = nil,
        baseFinishRoughnessFactor: Float? = nil,
        commandQueue: MTLCommandQueue? = nil
    ) throws -> (color: MTLTexture, finish: MTLTexture?) {
        try compositeInternal(
            baseTexture: baseTexture,
            width: width,
            height: height,
            sRGB: sRGB,
            baseFinishTexture: baseFinishTexture,
            baseFinishMetallicFactor: baseFinishMetallicFactor,
            baseFinishRoughnessFactor: baseFinishRoughnessFactor,
            bindingKey: nil,
            commandQueue: commandQueue
        )
    }

    private func compositeInternal(
        baseTexture: MTLTexture?,
        width: Int?,
        height: Int?,
        sRGB: Bool,
        baseFinishTexture: MTLTexture?,
        baseFinishMetallicFactor: Float?,
        baseFinishRoughnessFactor: Float?,
        bindingKey: MaterialBindingKey?,
        commandQueue: MTLCommandQueue?
    ) throws -> (color: MTLTexture, finish: MTLTexture?) {
        guard let queue = commandQueue ?? defaultCommandQueue,
              let commandBuffer = queue.makeCommandBuffer() else {
            throw VRMCosmeticError.commandEncodingFailed("Failed to create command buffer")
        }
        commandBuffer.label = "VRM Cosmetic Composite Sync"
        let result = try encodeCompositeInternal(
            baseTexture: baseTexture,
            width: width,
            height: height,
            sRGB: sRGB,
            baseFinishTexture: baseFinishTexture,
            baseFinishMetallicFactor: baseFinishMetallicFactor,
            baseFinishRoughnessFactor: baseFinishRoughnessFactor,
            bindingKey: bindingKey,
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw VRMCosmeticError.commandEncodingFailed(error.localizedDescription)
        }
        return result
    }

    // MARK: - Material Application, Linked Shade Sync & Clean Restore

    private func captureOrGetBindingLocked(
        for material: VRMMaterial,
        slot: VRMTextureSlot,
        model: VRMModel?
    ) -> (key: MaterialBindingKey, state: MaterialBindingState, generation: UInt64) {
        let key = MaterialBindingKey(materialID: ObjectIdentifier(material), slot: slot)
        let state: MaterialBindingState
        if let existing = bindings[key] {
            state = existing
        } else {
            let currentWrapper: VRMTexture?
            switch slot {
            case .baseColor: currentWrapper = material.baseColorTexture
            case .emissive: currentWrapper = material.emissiveTexture
            case .shadeMultiply: currentWrapper = material.mtoon?.shadeMultiplyTexture
            }
            let originalMTL = currentWrapper?.mtlTexture
            var sameWrapper = false
            var distinctLinkedShade: VRMTexture? = nil
            if slot == .baseColor, let shadeWrapper = material.mtoon?.shadeMultiplyTexture {
                if let baseWrapper = material.baseColorTexture, shadeWrapper === baseWrapper {
                    sameWrapper = true
                } else if let originalMTL, shadeWrapper.mtlTexture === originalMTL {
                    distinctLinkedShade = shadeWrapper
                }
            }
            let captured = MaterialBindingState(
                originalBaseMTLTexture: originalMTL,
                createdWrapper: currentWrapper == nil,
                linkedShadeWrapper: distinctLinkedShade,
                hadLinkedShadeSameWrapper: sameWrapper,
                originalMetallicRoughnessTexture: material.metallicRoughnessTexture,
                originalHasCosmeticFinishMap: material.hasCosmeticFinishMap,
                originalMetallicFactor: material.metallicFactor,
                originalRoughnessFactor: material.roughnessFactor,
                modifiedFinish: false
            )
            bindings[key] = captured
            state = captured
        }

        if faceLandmarks == nil, let modelLandmarks = model?.faceLandmarks {
            faceLandmarks = modelLandmarks
        }
        let generation = bindingGenerations[key, default: 0] &+ 1
        bindingGenerations[key] = generation
        return (key, state, generation)
    }

    private func commitMaterialMutation(
        result: (color: MTLTexture, finish: MTLTexture?),
        material: VRMMaterial,
        slot: VRMTextureSlot,
        key: MaterialBindingKey,
        state: MaterialBindingState,
        expectedGeneration: UInt64,
        model: VRMModel?
    ) {
        stateLock.lock()
        guard bindingGenerations[key] == expectedGeneration, bindings[key] != nil else {
            stateLock.unlock()
            return
        }
        let hadModifiedFinish = bindings[key]?.modifiedFinish == true
        if slot == .baseColor {
            if result.finish != nil {
                bindings[key]?.modifiedFinish = true
            } else if hadModifiedFinish {
                bindings[key]?.modifiedFinish = false
            }
        }
        stateLock.unlock()

        let applyMutation: () -> Void = {
            switch slot {
            case .baseColor:
                if let wrapper = material.baseColorTexture {
                    wrapper.mtlTexture = result.color
                } else {
                    material.baseColorTexture = VRMTexture(name: "cosmetic_baseColor", mtlTexture: result.color)
                }
                if let distinctShade = state.linkedShadeWrapper {
                    distinctShade.mtlTexture = result.color
                }
                if let finishTex = result.finish {
                    if let existingMR = material.metallicRoughnessTexture,
                       existingMR !== state.originalMetallicRoughnessTexture {
                        existingMR.mtlTexture = finishTex
                    } else {
                        let mrTex = VRMTexture(name: "cosmetic_finish", mtlTexture: finishTex)
                        mrTex.sampler = material.baseColorTexture?.sampler
                        material.metallicRoughnessTexture = mrTex
                    }
                    material.hasCosmeticFinishMap = true
                    material.metallicFactor = 1.0
                    material.roughnessFactor = 1.0
                } else if hadModifiedFinish {
                    material.metallicRoughnessTexture = state.originalMetallicRoughnessTexture
                    material.hasCosmeticFinishMap = state.originalHasCosmeticFinishMap
                    material.metallicFactor = state.originalMetallicFactor
                    material.roughnessFactor = state.originalRoughnessFactor
                }

            case .emissive:
                if let wrapper = material.emissiveTexture {
                    wrapper.mtlTexture = result.color
                } else {
                    material.emissiveTexture = VRMTexture(name: "cosmetic_emissive", mtlTexture: result.color)
                }

            case .shadeMultiply:
                if let mtoon = material.mtoon {
                    if let wrapper = mtoon.shadeMultiplyTexture {
                        wrapper.mtlTexture = result.color
                    } else {
                        mtoon.shadeMultiplyTexture = VRMTexture(name: "cosmetic_shade", mtlTexture: result.color)
                    }
                }
            }
        }

        if let model {
            model.edit { editor in
                applyMutation()
                editor.markMaterialsModified()
            }
        } else {
            applyMutation()
        }
    }

    /// Encodes GPU compositing onto `commandBuffer` without committing or blocking the CPU,
    /// and binds the resulting triple-buffered output texture(s) onto `material`'s `slot`.
    ///
    /// Call before encoding render passes into the same `commandBuffer` (or an earlier command
    /// buffer on the same queue) so Metal orders the compute and mipmap passes before sampling
    /// with zero CPU-GPU stalls.
    @discardableResult
    public func encodeApply(
        to material: VRMMaterial,
        slot: VRMTextureSlot = .baseColor,
        in model: VRMModel? = nil,
        width: Int? = nil,
        height: Int? = nil,
        preserveAuthoredFinish: Bool = false,
        commandBuffer: MTLCommandBuffer
    ) throws -> (color: MTLTexture, finish: MTLTexture?) {
        let isExternalQueue = defaultCommandQueue.map { commandBuffer.commandQueue !== $0 } ?? true
        stateLock.lock()
        let (key, state, generation) = captureOrGetBindingLocked(for: material, slot: slot, model: model)
        let seedAuthored = slot == .baseColor && preserveAuthoredFinish
        let result: (color: MTLTexture, finish: MTLTexture?)
        do {
            result = try encodeCompositeInternal(
                baseTexture: state.originalBaseMTLTexture,
                width: width,
                height: height,
                sRGB: true,
                baseFinishTexture: seedAuthored ? state.originalMetallicRoughnessTexture?.mtlTexture : nil,
                baseFinishMetallicFactor: seedAuthored ? state.originalMetallicFactor : nil,
                baseFinishRoughnessFactor: seedAuthored ? state.originalRoughnessFactor : nil,
                bindingKey: key,
                useDedicatedCanvases: isExternalQueue,
                commandBuffer: commandBuffer
            )
            stateLock.unlock()
        } catch {
            stateLock.unlock()
            throw error
        }
        commitMaterialMutation(
            result: result,
            material: material,
            slot: slot,
            key: key,
            state: state,
            expectedGeneration: generation,
            model: model
        )
        return result
    }

    private struct AsyncCompositePayload: @unchecked Sendable {
        let key: MaterialBindingKey
        let state: MaterialBindingState
        let generation: UInt64
        let color: MTLTexture
        let finish: MTLTexture?
    }

    /// Asynchronously composites this layer stack onto `material`'s `slot` without blocking
    /// the calling thread, suspending until GPU completion before updating the material.
    @discardableResult
    public func applyAsync(
        to material: VRMMaterial,
        slot: VRMTextureSlot = .baseColor,
        in model: VRMModel? = nil,
        width: Int? = nil,
        height: Int? = nil,
        preserveAuthoredFinish: Bool = false,
        commandQueue: MTLCommandQueue? = nil
    ) async throws -> (color: MTLTexture, finish: MTLTexture?) {
        guard let queue = commandQueue ?? defaultCommandQueue,
              let commandBuffer = queue.makeCommandBuffer() else {
            throw VRMCosmeticError.commandEncodingFailed("Failed to create command buffer")
        }
        commandBuffer.label = "VRM Cosmetic Composite Async"
        let isExternalQueue = defaultCommandQueue.map { queue !== $0 } ?? true

        // Lock around encoding AND commandBuffer.commit() so FIFO submission order on defaultCommandQueue
        // matches canvas/ring acquisition, while never holding the lock across the async await.
        let payload = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AsyncCompositePayload, any Error>) in
            stateLock.lock()
            do {
                let captured = captureOrGetBindingLocked(for: material, slot: slot, model: model)
                let seedAuthored = slot == .baseColor && preserveAuthoredFinish
                let encoded = try encodeCompositeInternal(
                    baseTexture: captured.state.originalBaseMTLTexture,
                    width: width,
                    height: height,
                    sRGB: true,
                    baseFinishTexture: seedAuthored ? captured.state.originalMetallicRoughnessTexture?.mtlTexture : nil,
                    baseFinishMetallicFactor: seedAuthored ? captured.state.originalMetallicFactor : nil,
                    baseFinishRoughnessFactor: seedAuthored ? captured.state.originalRoughnessFactor : nil,
                    bindingKey: captured.key,
                    useDedicatedCanvases: isExternalQueue,
                    commandBuffer: commandBuffer
                )
                let completedPayload = AsyncCompositePayload(
                    key: captured.key,
                    state: captured.state,
                    generation: captured.generation,
                    color: encoded.color,
                    finish: encoded.finish
                )
                commandBuffer.addCompletedHandler { cb in
                    if let error = cb.error {
                        continuation.resume(throwing: VRMCosmeticError.commandEncodingFailed(error.localizedDescription))
                    } else {
                        continuation.resume(returning: completedPayload)
                    }
                }
                commandBuffer.commit()
                stateLock.unlock()
            } catch {
                stateLock.unlock()
                continuation.resume(throwing: error)
            }
        }

        let result = (color: payload.color, finish: payload.finish)
        commitMaterialMutation(
            result: result,
            material: material,
            slot: slot,
            key: payload.key,
            state: payload.state,
            expectedGeneration: payload.generation,
            model: model
        )
        return result
    }

    /// Composites this layer stack onto `material`'s `slot` (non-destructively from its original base texture).
    ///
    /// When `slot == .baseColor`:
    /// - Automatically keeps a linked MToon `shadeMultiplyTexture` in sync (both when sharing the same
    ///   `VRMTexture` wrapper and when two distinct wrappers referenced the same original `MTLTexture`),
    ///   preserving the shader's `shadeUsesBaseColor` fast path.
    /// - When any visible layer has a ``VRMFinishOverride``, attaches the composited per-pixel finish map
    ///   to `material.metallicRoughnessTexture` and restores original finish state if finish layers are removed.
    ///   By default (`preserveAuthoredFinish == false`), unpainted texels seed as matte (`roughness = 1`,
    ///   `metallic = 0`) so VRoid/UniVRM default `metallicFactor = 1.0` exports do not turn unpainted skin metallic.
    ///   Pass `preserveAuthoredFinish: true` to seed unpainted texels from the material's authored
    ///   `metallicRoughnessTexture` and factors.
    public func apply(
        to material: VRMMaterial,
        slot: VRMTextureSlot = .baseColor,
        in model: VRMModel? = nil,
        width: Int? = nil,
        height: Int? = nil,
        preserveAuthoredFinish: Bool = false,
        commandQueue: MTLCommandQueue? = nil
    ) throws {
        stateLock.lock()
        let (key, state, generation) = captureOrGetBindingLocked(for: material, slot: slot, model: model)
        let seedAuthored = slot == .baseColor && preserveAuthoredFinish
        let result: (color: MTLTexture, finish: MTLTexture?)
        do {
            result = try compositeInternal(
                baseTexture: state.originalBaseMTLTexture,
                width: width,
                height: height,
                sRGB: true,
                baseFinishTexture: seedAuthored ? state.originalMetallicRoughnessTexture?.mtlTexture : nil,
                baseFinishMetallicFactor: seedAuthored ? state.originalMetallicFactor : nil,
                baseFinishRoughnessFactor: seedAuthored ? state.originalRoughnessFactor : nil,
                bindingKey: key,
                commandQueue: commandQueue
            )
            stateLock.unlock()
        } catch {
            stateLock.unlock()
            throw error
        }
        commitMaterialMutation(
            result: result,
            material: material,
            slot: slot,
            key: key,
            state: state,
            expectedGeneration: generation,
            model: model
        )
    }

    /// Restores `material`'s `slot` (including any synced `shadeMultiplyTexture` and finish map)
    /// back to its original pre-cosmetic state.
    public func clear(
        from material: VRMMaterial,
        slot: VRMTextureSlot = .baseColor,
        in model: VRMModel? = nil
    ) {
        let key = MaterialBindingKey(materialID: ObjectIdentifier(material), slot: slot)
        stateLock.lock()
        bindingGenerations[key, default: 0] &+= 1
        let state = bindings.removeValue(forKey: key)
        stateLock.unlock()
        guard let state else { return }

        let restoreMutation: () -> Void = {
            switch slot {
            case .baseColor:
                if state.createdWrapper {
                    material.baseColorTexture = nil
                } else {
                    material.baseColorTexture?.mtlTexture = state.originalBaseMTLTexture
                }
                if let distinctShade = state.linkedShadeWrapper {
                    distinctShade.mtlTexture = state.originalBaseMTLTexture
                }
                if state.modifiedFinish {
                    material.metallicRoughnessTexture = state.originalMetallicRoughnessTexture
                    material.hasCosmeticFinishMap = state.originalHasCosmeticFinishMap
                    material.metallicFactor = state.originalMetallicFactor
                    material.roughnessFactor = state.originalRoughnessFactor
                }

            case .emissive:
                if state.createdWrapper {
                    material.emissiveTexture = nil
                } else {
                    material.emissiveTexture?.mtlTexture = state.originalBaseMTLTexture
                }

            case .shadeMultiply:
                if state.createdWrapper {
                    material.mtoon?.shadeMultiplyTexture = nil
                } else {
                    material.mtoon?.shadeMultiplyTexture?.mtlTexture = state.originalBaseMTLTexture
                }
            }
        }

        if let model {
            model.edit { editor in
                restoreMutation()
                editor.markMaterialsModified()
            }
        } else {
            restoreMutation()
        }
    }

    // MARK: - Internal Helpers

    private func makeLayerParams(for layer: VRMTextureLayer) -> CosmeticLayerParamsCPU {
        let rect: VRMUVRect
        if let region = layer.landmarkRegion {
            let landmarks = faceLandmarks ?? VRMFaceLandmarks.vroidDefault
            rect = landmarks.rect(for: region) ?? .full
        } else {
            rect = .full
        }
        return CosmeticLayerParamsCPU(
            tint: layer.tint,
            rectMin: rect.origin,
            rectSize: rect.size,
            uvOffset: layer.uvOffset,
            uvScale: layer.uvScale,
            uvRotation: layer.uvRotation,
            opacity: max(0, min(1, layer.opacity)),
            blendMode: layer.blendMode.rawValue,
            decodeLayerSRGB: 0,
            finishMetallic: layer.finish?.metallic ?? 0,
            finishRoughness: layer.finish?.roughness ?? 1,
            hasFinish: layer.finish != nil ? 1 : 0
        )
    }

    private func makeWorkingCanvases(width: Int, height: Int) throws -> (a: MTLTexture, b: MTLTexture) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private

        guard let a = device.makeTexture(descriptor: desc),
              let b = device.makeTexture(descriptor: desc) else {
            throw VRMCosmeticError.textureAllocationFailed(width: width, height: height, pixelFormat: .rgba16Float)
        }
        a.label = "Cosmetic Canvas A (\(width)x\(height))"
        b.label = "Cosmetic Canvas B (\(width)x\(height))"
        return (a, b)
    }

    private func ensureWorkingCanvases(width: Int, height: Int) throws {
        if canvasA != nil, canvasB != nil, canvasSize == (width, height) {
            return
        }
        let created = try makeWorkingCanvases(width: width, height: height)
        canvasA = created.a
        canvasB = created.b
        canvasSize = (width, height)
    }

    private func acquireOutputTexture(
        width: Int,
        height: Int,
        sRGB: Bool,
        bindingKey: MaterialBindingKey?
    ) throws -> MTLTexture {
        if let key = bindingKey, var state = bindings[key] {
            let tex = try acquireColorTexture(from: &state.colorRing, width: width, height: height, sRGB: sRGB)
            bindings[key] = state
            return tex
        }
        return try acquireColorTexture(from: &standaloneColorRing, width: width, height: height, sRGB: sRGB)
    }

    private func acquireColorTexture(
        from ring: inout TextureRing,
        width: Int,
        height: Int,
        sRGB: Bool
    ) throws -> MTLTexture {
        if ring.width == width, ring.height == height, ring.sRGB == sRGB, ring.textures.count == TextureRing.slotCount {
            let tex = ring.textures[ring.nextIndex]
            ring.nextIndex = (ring.nextIndex + 1) % TextureRing.slotCount
            return tex
        }
        let pixelFormat: MTLPixelFormat = sRGB ? .rgba8Unorm_srgb : .rgba8Unorm
        let mipCount = max(1, Int(floor(log2(Double(max(width, height))))) + 1)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: mipCount > 1
        )
        desc.mipmapLevelCount = mipCount
        desc.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
        desc.storageMode = .shared

        var textures: [MTLTexture] = []
        textures.reserveCapacity(TextureRing.slotCount)
        for i in 0..<TextureRing.slotCount {
            guard let tex = device.makeTexture(descriptor: desc) else {
                throw VRMCosmeticError.textureAllocationFailed(width: width, height: height, pixelFormat: pixelFormat)
            }
            tex.label = "Cosmetic Output \(i) (\(width)x\(height))"
            textures.append(tex)
        }
        ring = TextureRing(textures: textures, nextIndex: 1 % TextureRing.slotCount, width: width, height: height, sRGB: sRGB)
        return textures[0]
    }

    private func acquireFinishTexture(
        width: Int,
        height: Int,
        bindingKey: MaterialBindingKey?
    ) throws -> MTLTexture {
        if let key = bindingKey, var state = bindings[key] {
            let tex = try acquireFinishTexture(from: &state.finishRing, width: width, height: height)
            bindings[key] = state
            return tex
        }
        return try acquireFinishTexture(from: &standaloneFinishRing, width: width, height: height)
    }

    private func acquireFinishTexture(
        from ring: inout TextureRing,
        width: Int,
        height: Int
    ) throws -> MTLTexture {
        if ring.width == width, ring.height == height, ring.textures.count == TextureRing.slotCount {
            let tex = ring.textures[ring.nextIndex]
            ring.nextIndex = (ring.nextIndex + 1) % TextureRing.slotCount
            return tex
        }
        let mipCount = max(1, Int(floor(log2(Double(max(width, height))))) + 1)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: mipCount > 1
        )
        desc.mipmapLevelCount = mipCount
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared

        var textures: [MTLTexture] = []
        textures.reserveCapacity(TextureRing.slotCount)
        for i in 0..<TextureRing.slotCount {
            guard let tex = device.makeTexture(descriptor: desc) else {
                throw VRMCosmeticError.textureAllocationFailed(width: width, height: height, pixelFormat: .rgba8Unorm)
            }
            tex.label = "Cosmetic Finish Map \(i) (\(width)x\(height))"
            textures.append(tex)
        }
        ring = TextureRing(textures: textures, nextIndex: 1 % TextureRing.slotCount, width: width, height: height, sRGB: false)
        return textures[0]
    }

    private func getOrCreateDummyTexture() throws -> MTLTexture {
        if let existing = dummy1x1Texture { return existing }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw VRMCosmeticError.textureAllocationFailed(width: 1, height: 1, pixelFormat: .rgba8Unorm)
        }
        var px: [UInt8] = [0, 0, 0, 0]
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
        tex.label = "Cosmetic Dummy 1x1"
        dummy1x1Texture = tex
        return tex
    }

    private func dispatch2D(
        encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
        let tgW = max(1, min(16, pipeline.threadExecutionWidth))
        let tgH = max(1, min(16, pipeline.maxTotalThreadsPerThreadgroup / tgW))
        let threadsPerGroup = MTLSize(width: tgW, height: tgH, depth: 1)
        let threadgroups = MTLSize(
            width: (width + tgW - 1) / tgW,
            height: (height + tgH - 1) / tgH,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
    }
}
