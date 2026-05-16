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
@_exported import GLTFCore

/// GLTFMetalKit — PBR rendering of static glTF 2.0 assets on Metal.
///
/// Sibling product to VRMMetalKit. Both share the parsing and Metal-helper
/// infrastructure in GLTFCore; GLTFMetalKit adds a PBR renderer aimed at
/// inanimate objects (props, scenery, items) without VRM-extension overhead.
///
/// Phase 3a MVP covers: static meshes + scene graph + PBR materials + IBL +
/// correct color pipeline + KHR_lights_punctual + KHR_materials_unlit.
/// Phase 3b adds skinning, morph targets, and the animation playback runtime.
public enum GLTFMetalKit {
    /// Bundle that holds the compiled shader metallib and IBL assets.
    public static var bundle: Bundle { .module }
}
