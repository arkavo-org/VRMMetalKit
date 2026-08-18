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

import Metal
import simd

/// One compositor view (typically a stereo eye) for
/// ``VRMRenderer/encodeCompositorViews(commandBuffer:views:)``.
///
/// The host owns the textures — on visionOS they are the drawable color and
/// depth attachments. The renderer does not present.
public struct CompositorViewTarget {
    public var colorTexture: MTLTexture
    public var depthTexture: MTLTexture
    public var renderPassDescriptor: MTLRenderPassDescriptor
    public var viewMatrix: simd_float4x4
    public var projectionMatrix: simd_float4x4

    public init(
        colorTexture: MTLTexture,
        depthTexture: MTLTexture,
        renderPassDescriptor: MTLRenderPassDescriptor,
        viewMatrix: simd_float4x4,
        projectionMatrix: simd_float4x4
    ) {
        self.colorTexture = colorTexture
        self.depthTexture = depthTexture
        self.renderPassDescriptor = renderPassDescriptor
        self.viewMatrix = viewMatrix
        self.projectionMatrix = projectionMatrix
    }
}

/// Stereo layout used by the visionOS-shaped bench and as documentation for
/// CompositorServices hosts. Real devices should use the drawable's own
/// view transforms; this is a Mac stand-in (IPD offset along local X).
public enum VisionOSStereoLayout {
    public static let defaultWidth = 1920
    public static let defaultHeight = 1824
    public static let defaultViewCount = 2
    public static let ipd: Float = 0.063
    public static let cadenceHz: Double = 90
    public static var frameBudgetMs: Double { 1000.0 / cadenceHz }

    public static func viewMatrices(center: simd_float4x4, ipd: Float = ipd) -> (left: simd_float4x4, right: simd_float4x4) {
        let half = ipd * 0.5
        return (translate(center, x: -half), translate(center, x: half))
    }

    private static func translate(_ view: simd_float4x4, x: Float) -> simd_float4x4 {
        var translated = view
        translated.columns.3.x += x
        return translated
    }
}
