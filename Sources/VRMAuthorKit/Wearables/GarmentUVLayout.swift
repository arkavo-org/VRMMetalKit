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

/// One rectangle of a garment texture; `rect` is (u0, v0, u1, v1).
public struct GarmentUVIsland: Codable, Hashable, Sendable {
    public var name: String
    public var rect: [Float]

    public init(name: String, rect: [Float]) {
        self.name = name
        self.rect = rect
    }

    public func contains(_ uv: SIMD2<Float>, tolerance: Float = 1e-4) -> Bool {
        uv.x >= rect[0] - tolerance && uv.x <= rect[2] + tolerance && uv.y >= rect[1] - tolerance && uv.y <= rect[3] + tolerance
    }

    func map(_ uv: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(rect[0] + (rect[2] - rect[0]) * min(max(uv.x, 0), 1), rect[1] + (rect[3] - rect[1]) * min(max(uv.y, 0), 1))
    }
}

/// Named islands per outfit kind. Shells remap the body's per-loft UVs into
/// the island of each vertex's region; trim bands share the trim strip.
public enum GarmentUVLayout {
    public static let trim = GarmentUVIsland(name: "trim", rect: [0, 0.9, 1, 1])
    public static let skirt = GarmentUVIsland(name: "skirt", rect: [0, 0.45, 0.5, 0.9])

    public static func islands(for kind: OutfitKind) -> [GarmentUVIsland] {
        switch kind {
        case .top:
            return [GarmentUVIsland(name: "torso", rect: [0, 0, 0.5, 0.9]),
                    GarmentUVIsland(name: "upperArmL", rect: [0.5, 0, 0.75, 0.45]), GarmentUVIsland(name: "upperArmR", rect: [0.75, 0, 1, 0.45]),
                    GarmentUVIsland(name: "forearmL", rect: [0.5, 0.45, 0.75, 0.9]), GarmentUVIsland(name: "forearmR", rect: [0.75, 0.45, 1, 0.9]), trim]
        case .bottom:
            return [GarmentUVIsland(name: "waistHips", rect: [0, 0, 0.5, 0.45]), skirt,
                    GarmentUVIsland(name: "thighL", rect: [0.5, 0, 0.75, 0.45]), GarmentUVIsland(name: "thighR", rect: [0.75, 0, 1, 0.45]),
                    GarmentUVIsland(name: "shinL", rect: [0.5, 0.45, 0.75, 0.9]), GarmentUVIsland(name: "shinR", rect: [0.75, 0.45, 1, 0.9]), trim]
        case .footwear:
            return [GarmentUVIsland(name: "footL", rect: [0, 0, 0.5, 0.9]), GarmentUVIsland(name: "footR", rect: [0.5, 0, 1, 0.9]), trim]
        }
    }

    public static func island(for region: String, kind: OutfitKind) -> GarmentUVIsland? {
        let torso = [WearableRegion.chest, WearableRegion.torso, WearableRegion.waist, WearableRegion.hips]
        let name: String
        switch kind {
        case .top: name = torso.contains(region) ? "torso" : region
        case .bottom: name = (region == WearableRegion.waist || region == WearableRegion.hips || region == WearableRegion.torso) ? "waistHips" : region
        case .footwear: name = region
        }
        return islands(for: kind).first { $0.name == name }
    }
}
