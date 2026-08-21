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

/// Resolves glTF samplers to `MTLSamplerState`, deduplicating on the
/// resolved descriptor.
///
/// ## Discussion
/// glTF gives every texture its own sampler — wrap mode per axis, plus
/// magnification and minification filters. An asset typically names a few
/// dozen textures but only a handful of genuinely distinct samplers, and
/// Metal caps how many sampler states may be live at once, so states are
/// keyed by the *resolved* descriptor rather than by sampler index: two
/// sampler entries that spell the same thing share one state.
///
/// The filter mapping is the one ``TextureLoader/createSampler(from:)``
/// has always applied — `9728` NEAREST / `9729` LINEAR plus the
/// `9984`–`9987` mipmap variants, and `33071` CLAMP_TO_EDGE / `33648`
/// MIRRORED_REPEAT / `10497` REPEAT for wrap. Whether the descriptor
/// filters across mip levels is decided by
/// ``TextureLoader/samplerRequestsMipmaps(_:)``, the same predicate the
/// upload path uses to decide whether to build a chain, so a sampler can
/// never filter across levels a texture does not have.
public final class GLTFSamplerCache: @unchecked Sendable {
    private let device: MTLDevice
    private let lock = NSLock()
    private var states: [Key: MTLSamplerState] = [:]

    /// Creates an empty cache bound to a Metal device.
    ///
    /// - Parameter device: Device used to allocate sampler states.
    public init(device: MTLDevice) {
        self.device = device
    }

    /// Number of distinct sampler states allocated so far.
    public var stateCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return states.count
    }

    /// Returns the cached state for a glTF sampler, allocating it on first use.
    ///
    /// - Parameter gltfSampler: Source sampler, or `nil` for the glTF defaults.
    /// - Returns: The shared `MTLSamplerState`, or `nil` if Metal allocation fails.
    public func samplerState(for gltfSampler: GLTFSampler?) -> MTLSamplerState? {
        let descriptor = Self.descriptor(for: gltfSampler)
        let key = Key(descriptor)
        lock.lock()
        defer { lock.unlock() }
        if let existing = states[key] {
            return existing
        }
        guard let state = device.makeSamplerState(descriptor: descriptor) else {
            return nil
        }
        states[key] = state
        return state
    }

    /// Returns the cached state for the sampler named by a texture.
    ///
    /// A texture with no `sampler`, or an index outside the document, falls
    /// back to the glTF defaults.
    ///
    /// - Parameters:
    ///   - index: Texture index in ``GLTFDocument/textures``.
    ///   - document: The decoded ``GLTFDocument``.
    /// - Returns: The shared `MTLSamplerState`, or `nil` if Metal allocation fails.
    public func samplerState(forTextureAt index: Int, in document: GLTFDocument) -> MTLSamplerState? {
        samplerState(for: Self.gltfSampler(forTextureAt: index, in: document))
    }

    /// Builds the `MTLSamplerDescriptor` a glTF sampler resolves to.
    ///
    /// - Parameter gltfSampler: Source sampler, or `nil` for the glTF defaults.
    /// - Returns: A fresh descriptor; callers that need a state should go through ``samplerState(for:)`` so it is shared.
    public static func descriptor(for gltfSampler: GLTFSampler?) -> MTLSamplerDescriptor {
        let descriptor = MTLSamplerDescriptor()

        switch gltfSampler?.minFilter {
        case 9728, 9984, 9986:
            descriptor.minFilter = .nearest
        default:
            descriptor.minFilter = .linear
        }

        if TextureLoader.samplerRequestsMipmaps(gltfSampler) {
            switch gltfSampler?.minFilter {
            case 9984, 9985:
                descriptor.mipFilter = .nearest
            default:
                descriptor.mipFilter = .linear
            }
        } else {
            descriptor.mipFilter = .notMipmapped
        }

        switch gltfSampler?.magFilter {
        case 9728:
            descriptor.magFilter = .nearest
        default:
            descriptor.magFilter = .linear
        }

        descriptor.sAddressMode = addressMode(gltfSampler?.wrapS)
        descriptor.tAddressMode = addressMode(gltfSampler?.wrapT)
        descriptor.maxAnisotropy = 16
        descriptor.normalizedCoordinates = true
        return descriptor
    }

    /// Builds the descriptor the sampler named by a texture resolves to.
    ///
    /// - Parameters:
    ///   - index: Texture index in ``GLTFDocument/textures``.
    ///   - document: The decoded ``GLTFDocument``.
    /// - Returns: A fresh descriptor.
    public static func descriptor(forTextureAt index: Int, in document: GLTFDocument) -> MTLSamplerDescriptor {
        descriptor(for: gltfSampler(forTextureAt: index, in: document))
    }

    private static func gltfSampler(forTextureAt index: Int, in document: GLTFDocument) -> GLTFSampler? {
        guard let texture = document.textures?[safe: index] else { return nil }
        return texture.sampler.flatMap { document.samplers?[safe: $0] }
    }

    private static func addressMode(_ wrap: Int?) -> MTLSamplerAddressMode {
        switch wrap {
        case 33071:
            return .clampToEdge
        case 33648:
            return .mirrorRepeat
        default:
            return .repeat
        }
    }

    private struct Key: Hashable {
        let minFilter: UInt
        let magFilter: UInt
        let mipFilter: UInt
        let sAddressMode: UInt
        let tAddressMode: UInt
        let maxAnisotropy: Int

        init(_ descriptor: MTLSamplerDescriptor) {
            minFilter = descriptor.minFilter.rawValue
            magFilter = descriptor.magFilter.rawValue
            mipFilter = descriptor.mipFilter.rawValue
            sAddressMode = descriptor.sAddressMode.rawValue
            tAddressMode = descriptor.tAddressMode.rawValue
            maxAnisotropy = descriptor.maxAnisotropy
        }
    }
}
