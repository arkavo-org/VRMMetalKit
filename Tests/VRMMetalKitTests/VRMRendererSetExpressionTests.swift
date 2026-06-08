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

import XCTest
import Metal
@testable import VRMMetalKit

/// `VRMRenderer.setExpression` is a thin convenience over
/// `expressionController?.setExpressionWeight(...)` so apps don't thread `?.`
/// through the optional controller at every call site.
final class VRMRendererSetExpressionTests: XCTestCase {

    private func makeRenderer() throws -> VRMRenderer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        return VRMRenderer(device: device)
    }

    func testSetExpressionForwardsPresetWeightToController() throws {
        let renderer = try makeRenderer()
        renderer.setExpression(.happy, weight: 0.5)
        XCTAssertEqual(renderer.expressionController?.weight(for: .happy), 0.5,
                       "setExpression(preset:) must forward the weight to the controller")
    }

    func testSetExpressionClampsPresetWeight() throws {
        let renderer = try makeRenderer()
        renderer.setExpression(.blink, weight: 5.0)
        XCTAssertEqual(renderer.expressionController?.weight(for: .blink), 1.0,
                       "weights must be clamped to [0, 1] (delegated to the controller)")
    }

    func testSetExpressionForwardsCustomNameWeightToController() throws {
        let renderer = try makeRenderer()
        // Custom weights only apply once the expression is registered.
        renderer.expressionController?.registerCustomExpression(VRMExpression(name: "Wink"), name: "Wink")
        renderer.setExpression("Wink", weight: 0.75)
        XCTAssertEqual(renderer.expressionController?.weight(forCustom: "Wink"), 0.75,
                       "setExpression(custom name:) must forward to the custom-expression setter")
    }
}
