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

/// Routing policy for `VRMRenderer.debugUVs`: which fragment function a debug
/// visualization mode has to run in.
///
/// Most modes are computable from the fragment's inputs alone, so they live in
/// the isolated `mtoon_fragment_debug` / `mtoon_debug_visualize` pair and keep
/// the production fragment free of the visualize cascade.
///
/// ``inlineProductionModes`` cannot: they visualize state that only exists part
/// way through production shading — the flipped normal (mode 11) and the
/// accumulated lit color before the minimum-light floor (mode 35). They are
/// returned by `mtoon_fragment_v2` itself, so their draws must keep the
/// production pipeline; binding the debug fragment for them yields the terminal
/// 'unknown mode' magenta.
public enum MToonDebugMode {

    /// Debug modes answered inside `mtoon_fragment_v2`, not by the isolated
    /// debug fragment.
    ///
    /// - 11: magenta where the fragment's normal was flipped for a back face,
    ///   normal shading elsewhere.
    /// - 35: the lit color accumulated after all light, rim, matcap and
    ///   emissive terms, before the minimum-light floor and saturation.
    public static let inlineProductionModes: Set<Int32> = [11, 35]

    /// `true` when `mode` is served by `mtoon_fragment_debug`, i.e. the draw
    /// must bind the debug pipeline rather than the material's own PSO.
    public static func usesDebugFragment(_ mode: Int32) -> Bool {
        mode != 0 && !inlineProductionModes.contains(mode)
    }
}
