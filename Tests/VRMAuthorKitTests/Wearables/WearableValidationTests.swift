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
import XCTest
@testable import VRMAuthorKit

final class WearableValidationTests: XCTestCase {
    let chain: [CompiledNode] = [
        CompiledNode(id: "head", name: "head"),
        CompiledNode(id: "a0", name: "a0", parentId: "head"),
        CompiledNode(id: "a1", name: "a1", parentId: "a0"),
        CompiledNode(id: "a2", name: "a2", parentId: "a1"),
        CompiledNode(id: "b0", name: "b0", parentId: "head"),
        CompiledNode(id: "b1", name: "b1", parentId: "b0"),
    ]

    func spring(_ id: String, _ nodes: [String]) -> SpringObject { SpringObject(id: id, joints: nodes.map { SpringJoint(node: $0) }) }

    func code(_ block: () throws -> Void) -> AuthorError? {
        do { try block(); return nil } catch let e as AuthorError { return e } catch { return nil }
    }

    func testOverlappingChainsAreRejected() {
        XCTAssertNil(code { try WearableValidation.noOverlappingChains([spring("s1", ["a0", "a1", "a2"]), spring("s2", ["b0", "b1"])]) })
        let e = code { try WearableValidation.noOverlappingChains([spring("s1", ["a0", "a1", "a2"]), spring("s2", ["a1", "a2"])]) }
        XCTAssertEqual(e?.code, .springChainOverlap)
        XCTAssertEqual(e?.code.rawValue, "SPRING_CHAIN_OVERLAP")
        XCTAssertEqual(e?.objectId, "s2")
        XCTAssertEqual(e?.observed, .string("a1"))
    }

    func testTerminalTailMustExistAndDescend() {
        XCTAssertNil(code { try WearableValidation.terminalTailPresent([spring("s1", ["a0", "a1", "a2"]), spring("s2", ["b0", "b1"])], nodes: chain) })
        XCTAssertNil(code { try WearableValidation.terminalTailPresent([spring("s1", ["a0", "a2"])], nodes: chain) })
        let missing = code { try WearableValidation.terminalTailPresent([spring("s1", ["a0", "a1", "ghost"])], nodes: chain) }
        XCTAssertEqual(missing?.code, .springTailMissing)
        XCTAssertEqual(missing?.observed, .string("ghost"))
        let single = code { try WearableValidation.terminalTailPresent([spring("s1", ["a0"])], nodes: chain) }
        XCTAssertEqual(single?.code, .springTailMissing)
        let crossed = code { try WearableValidation.terminalTailPresent([spring("s1", ["a0", "b1"])], nodes: chain) }
        XCTAssertEqual(crossed?.code, .springTailMissing)
        XCTAssertEqual(crossed?.path, "/joints/1/node")
        let reversed = code { try WearableValidation.terminalTailPresent([spring("s1", ["a2", "a1"])], nodes: chain) }
        XCTAssertEqual(reversed?.code, .springTailMissing)
    }

    func testValidateSpringsCombinesModelAndStructure() {
        XCTAssertNil(code { try WearableValidation.validateSprings([spring("s1", ["a0", "a1", "a2"]), spring("s2", ["b0", "b1"])], nodes: chain) })
        XCTAssertEqual(code { try WearableValidation.validateSprings([spring("s1", ["a0", "a0"])], nodes: chain) }?.code, .invalidRequest)
        XCTAssertEqual(code { try WearableValidation.validateSprings([spring("s1", ["a0", "a1"]), spring("s2", ["a1", "a2"])], nodes: chain) }?.code, .springChainOverlap)
    }

    func testMeshValidation() {
        let p: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)]
        let n: [SIMD3<Float>] = Array(repeating: SIMD3(0, 0, 1), count: 3)
        let uv: [SIMD2<Float>] = Array(repeating: SIMD2(0, 0), count: 3)
        func mesh(positions: [SIMD3<Float>] = p, indices: [UInt32] = [0, 1, 2], weights: [SIMD4<Float>]? = nil) -> CompiledMesh {
            CompiledMesh(id: "m", name: "m", primitives: [CompiledPrimitive(materialId: "x", positions: positions, normals: n, uv0: uv,
                                                                            joints0: weights == nil ? nil : Array(repeating: SIMD4(0, 0, 0, 0), count: 3),
                                                                            weights0: weights, indices: indices)])
        }
        XCTAssertNil(code { try WearableValidation.validateMesh(mesh()) })
        XCTAssertEqual(code { try WearableValidation.validateMesh(mesh(indices: [0, 1, 3])) }?.code, .meshInvalid)
        XCTAssertEqual(code { try WearableValidation.validateMesh(mesh(indices: [0, 1, 1])) }?.code, .meshInvalid)
        XCTAssertEqual(code { try WearableValidation.validateMesh(mesh(indices: [0, 1])) }?.code, .meshInvalid)
        XCTAssertEqual(code { try WearableValidation.validateMesh(mesh(positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0)])) }?.code, .meshInvalid)
        XCTAssertEqual(code { try WearableValidation.validateMesh(mesh(positions: [SIMD3(.nan, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)])) }?.code, .meshInvalid)
        XCTAssertEqual(code { try WearableValidation.validateMesh(mesh(weights: Array(repeating: SIMD4(0.5, 0, 0, 0), count: 3))) }?.code, .meshInvalid)
        XCTAssertNil(code { try WearableValidation.validateMesh(mesh(weights: Array(repeating: SIMD4(1, 0, 0, 0), count: 3))) })
    }

    func testColliderModelHasNoCCDField() {
        let collider = ColliderObject(id: "c", node: "n", shape: ColliderShape(sphere: SphereShape(radius: 0.1)))
        let labels = Mirror(reflecting: collider).children.compactMap(\.label)
        XCTAssertEqual(labels, ["id", "node", "shape"])
        let text = String(decoding: (try? CanonicalJSON.data(ColliderObject.schema.json)) ?? Data(), as: UTF8.self).lowercased()
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(text.contains("ccd") || text.contains("swept") || text.contains("synthetic"))
    }
}
