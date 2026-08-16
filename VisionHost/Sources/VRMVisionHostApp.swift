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

import SwiftUI
import CompositorServices

/// Renders a VRM avatar into a fully immersive space with Metal, through
/// CompositorServices.
///
/// The app declares `CPSceneSessionRoleImmersiveSpaceApplication` as its
/// preferred scene role, so it launches straight into the immersive space —
/// the avatar stands in the room rather than inside a window.
@main
struct VRMVisionHostApp: App {
    var body: some Scene {
        ImmersiveSpace {
            CompositorLayer(configuration: AvatarLayerConfiguration()) { layerRenderer in
                ImmersiveRenderer(layerRenderer: layerRenderer).start()
            }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}

/// Requests a layered drawable with a depth attachment.
///
/// The depth format is required: the compositor reprojects rendered frames
/// using the depth buffer, and VRM rendering is depth-sorted regardless.
struct AvatarLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        configuration.depthFormat = .depth32Float
        configuration.colorFormat = .bgra8Unorm_srgb

        let supported = capabilities.supportedLayouts(options: [])
        configuration.layout = supported.contains(.layered) ? .layered : .dedicated
    }
}
