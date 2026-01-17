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

import MetalKit
import simd

// MARK: - Projection Matrix Helpers

func makePerspective(fovyRadians: Float, aspectRatio: Float, nearZ: Float, farZ: Float) -> float4x4 {
    let ys = 1 / tanf(fovyRadians * 0.5)
    let xs = ys / aspectRatio
    let zs = farZ / (nearZ - farZ)

    return float4x4(
        SIMD4<Float>(xs, 0, 0, 0),
        SIMD4<Float>(0, ys, 0, 0),
        SIMD4<Float>(0, 0, zs, -1),
        SIMD4<Float>(0, 0, nearZ * zs, 0)
    )
}

// MARK: - Dummy View for Headless Rendering

class DummyView: MTKView {
    private let _size: CGSize

    init(size: CGSize) {
        self._size = size
        super.init(frame: .zero, device: nil)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    nonisolated override var drawableSize: CGSize {
        get { _size }
        set { }  // Ignore sets
    }
}

// MARK: - Matrix Extensions

extension float4x4 {
    var inverse: float4x4 {
        return simd_inverse(self)
    }

    var transpose: float4x4 {
        return simd_transpose(self)
    }
}

// MARK: - Vector Extensions

extension SIMD3<Float> {
    var normalized: SIMD3<Float> {
        let length = sqrt(x * x + y * y + z * z)
        guard length > 0 else { return self }
        return self / length
    }
}
