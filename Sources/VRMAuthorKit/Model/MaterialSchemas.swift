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

/// Leaf schemas for `Material.gltf` and `Material.mtoon`. Phase 0 leaves them
/// open objects; the materials area replaces these two bodies with the complete
/// glTF metallic-roughness and VRMC_materials_mtoon 1.0 leaf enumeration.
public enum MaterialSchemas {
    public static var gltf: JSONSchema {
        JSONSchema.object(properties: [:], required: [], additionalProperties: true, description: "glTF 2.0 material fields (pbrMetallicRoughness, normal/emissive/occlusion textures, alphaMode/alphaCutoff/doubleSided)")
    }

    public static var mtoon: JSONSchema {
        JSONSchema.object(properties: [:], required: [], additionalProperties: true, description: "VRMC_materials_mtoon 1.0 fields")
    }
}
