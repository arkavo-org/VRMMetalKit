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

/// Configurable memory and structural quotas applied while loading VRM and VRMA files.
///
/// Use ``default`` for typical avatars, ``strict`` when loading untrusted or
/// user-uploaded files, or ``permissive`` for trusted high-complexity assets.
/// Individual fields can also be tuned directly.
public struct VRMLoaderLimits: Sendable, Equatable {
    /// Maximum total scalar elements decoded from a single accessor (`count * components`).
    /// Default `10_000_000` (≈40 MB at 4 bytes/element).
    public var maxAccessorElements: Int

    /// Maximum total buffer-view bytes declared or loaded across a single document.
    /// Default `256 * 1024 * 1024` (256 MiB).
    public var maxTotalBufferBytes: Int

    /// Maximum animation samplers per `.vrma` clip.
    /// Default `4_096`.
    public var maxAnimationSamplers: Int

    /// Maximum keyframes per animation sampler (input track length).
    /// Default `100_000`.
    public var maxKeyframesPerSampler: Int

    /// Maximum spring-bone joints per VRM document.
    /// Default `1_024`.
    public var maxSpringBones: Int

    /// Maximum custom expressions per VRM document (Perfect Sync uses 52).
    /// Default `256`.
    public var maxCustomExpressions: Int

    /// Balanced defaults suitable for standard VRM 0.x and VRM 1.0 avatars.
    public static let `default` = VRMLoaderLimits()

    /// Raised quotas for trusted, high-complexity assets authored or verified by the host app.
    public static let permissive = VRMLoaderLimits(
        maxAccessorElements: 100_000_000,
        maxTotalBufferBytes: 1024 * 1024 * 1024,
        maxAnimationSamplers: 32_768,
        maxKeyframesPerSampler: 1_000_000,
        maxSpringBones: 8_192,
        maxCustomExpressions: 2_048
    )

    /// Tighter quotas for untrusted, user-uploaded, or network-sourced content.
    public static let strict = VRMLoaderLimits(
        maxAccessorElements: 2_000_000,
        maxTotalBufferBytes: 64 * 1024 * 1024,
        maxAnimationSamplers: 512,
        maxKeyframesPerSampler: 20_000,
        maxSpringBones: 256,
        maxCustomExpressions: 64
    )

    /// Creates a loader-limits configuration with the specified quotas.
    public init(
        maxAccessorElements: Int = 10_000_000,
        maxTotalBufferBytes: Int = 256 * 1024 * 1024,
        maxAnimationSamplers: Int = 4_096,
        maxKeyframesPerSampler: Int = 100_000,
        maxSpringBones: Int = 1_024,
        maxCustomExpressions: Int = 256
    ) {
        self.maxAccessorElements = maxAccessorElements
        self.maxTotalBufferBytes = maxTotalBufferBytes
        self.maxAnimationSamplers = maxAnimationSamplers
        self.maxKeyframesPerSampler = maxKeyframesPerSampler
        self.maxSpringBones = maxSpringBones
        self.maxCustomExpressions = maxCustomExpressions
    }
}

extension BufferLoader {
    /// Creates a ``BufferLoader`` configured with quotas from a ``VRMLoaderLimits`` value.
    public convenience init(
        document: GLTFDocument,
        binaryData: Data?,
        baseURL: URL? = nil,
        preloadedData: [Int: Data]? = nil,
        limits: VRMLoaderLimits
    ) {
        self.init(
            document: document,
            binaryData: binaryData,
            baseURL: baseURL,
            preloadedData: preloadedData,
            maxAccessorElements: limits.maxAccessorElements,
            maxTotalBufferBytes: limits.maxTotalBufferBytes
        )
    }
}
