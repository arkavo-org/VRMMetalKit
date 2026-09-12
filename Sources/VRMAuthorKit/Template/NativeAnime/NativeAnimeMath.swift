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

typealias NAVec3 = SIMD3<Double>
typealias NAVec2 = SIMD2<Double>

enum NAMath {
    static let xAxis = NAVec3(1, 0, 0)
    static let yAxis = NAVec3(0, 1, 0)
    static let zAxis = NAVec3(0, 0, 1)

    static func dot(_ a: NAVec3, _ b: NAVec3) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }

    static func cross(_ a: NAVec3, _ b: NAVec3) -> NAVec3 {
        NAVec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }

    static func length(_ a: NAVec3) -> Double { dot(a, a).squareRoot() }

    static func normalize(_ a: NAVec3, fallback: NAVec3 = NAVec3(0, 0, 1)) -> NAVec3 {
        let l = length(a)
        return l > 1e-18 ? a / l : fallback
    }

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        if edge1 == edge0 { return x < edge0 ? 0 : 1 }
        let t = clamp((x - edge0) / (edge1 - edge0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    static func lerp(_ a: NAVec3, _ b: NAVec3, _ t: Double) -> NAVec3 { a + (b - a) * t }

    static func degrees(_ d: Double) -> Double { d * .pi / 180 }

    /// Rotates `p` about the unit `axis` through `angle` radians around `pivot`.
    static func rotate(_ p: NAVec3, about axis: NAVec3, angle: Double, pivot: NAVec3) -> NAVec3 {
        let v = p - pivot
        let c = cos(angle), s = sin(angle)
        let r = v * c + cross(axis, v) * s + axis * (dot(axis, v) * (1 - c))
        return pivot + r
    }

    /// Distance from `p` to segment `ab`.
    static func segmentDistance(_ p: NAVec3, _ a: NAVec3, _ b: NAVec3) -> Double {
        let ab = b - a
        let l2 = dot(ab, ab)
        if l2 < 1e-18 { return length(p - a) }
        let t = clamp(dot(p - a, ab) / l2, 0, 1)
        return length(p - (a + ab * t))
    }

    static func f(_ v: NAVec3) -> SIMD3<Float> { SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z)) }
    static func f(_ v: NAVec2) -> SIMD2<Float> { SIMD2<Float>(Float(v.x), Float(v.y)) }
}
