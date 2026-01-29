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
import Metal

final class VRMDrawCallExecutor {
    func logDrawIntro(item: RenderItem, drawIndex: Int, frameCounter: Int, index: Int, model: VRMModel) {
        let meshName = item.mesh.name ?? "unnamed"
        let materialName = item.materialName
        let prim = item.primitive
        let meshPrimIndex = item.mesh.primitives.firstIndex(where: { $0 === prim }) ?? -1

        var skinIdxStr = "none"
        var paletteCountStr = "0"
        let paletteVersionStr = "0"
        if let skinIndex = item.node.skin {
            skinIdxStr = "\(skinIndex)"
            if skinIndex < model.skins.count {
                let skin = model.skins[skinIndex]
                paletteCountStr = "\(skin.joints.count)"
            }
        }

        let positionSlot = prim.morphTargets.isEmpty ? 0 : 20

        let modeStr: String
        switch prim.primitiveType {
        case .point: modeStr = "POINTS"
        case .line: modeStr = "LINES"
        case .lineStrip: modeStr = "LINE_STRIP"
        case .triangle: modeStr = "TRIANGLES"
        case .triangleStrip: modeStr = "TRIANGLE_STRIP"
        @unknown default: modeStr = "UNKNOWN"
        }

        let indexTypeStr = prim.indexType == .uint16 ? "u16" : "u32"

        let psoLabel: String
        switch item.effectiveAlphaMode {
        case "opaque": psoLabel = "opaque"
        case "mask": psoLabel = "mask"
        case "blend": psoLabel = "blend"
        default: psoLabel = "unknown"
        }

        let meshPrimIdx = meshPrimIndex
        let idxInfo = "\(indexTypeStr)/\(prim.indexBufferOffset)/\(prim.indexCount)"
        let skinInfo = "\(skinIdxStr)/\(paletteCountStr)/\(paletteVersionStr)"
        vrmLog("[DRAW] i=\(drawIndex) mesh='\(meshName)' prim=\(meshPrimIdx) mat='\(materialName)' mode=\(modeStr) idx=\(idxInfo) skin=\(skinInfo) pso=\(psoLabel) pos_slot=\(positionSlot)")

        if drawIndex == 14 && frameCounter <= 2 {
            vrmLog("[DRAW 14 DEBUG] Enter draw loop for wedge primitive (index=\(index))")
        }
    }

    func validateDrawFive(item: RenderItem, model: VRMModel) {
        let prim = item.primitive
        let meshName = item.mesh.name ?? "unnamed"
        let meshPrimIndex = item.mesh.primitives.firstIndex(where: { $0 === prim }) ?? -1
        vrmLog("🔍 [DRAW 5 DECISIVE CHECK] mesh='\(meshName)' prim=\(meshPrimIndex)")

        let modeDesc: String
        switch prim.primitiveType {
        case .point: modeDesc = "POINTS (0)"
        case .line: modeDesc = "LINES (1)"
        case .lineStrip: modeDesc = "LINE_STRIP (3)"
        case .triangle: modeDesc = "TRIANGLES (4)"
        case .triangleStrip: modeDesc = "TRIANGLE_STRIP (5)"
        @unknown default: modeDesc = "UNKNOWN"
        }
        vrmLog("📐 [PRIMITIVE MODE] type=\(modeDesc) idxType=\(prim.indexType == .uint16 ? "uint16" : "uint32") idxCount=\(prim.indexCount) vertexCount=\(prim.vertexCount)")

        guard let indexBuffer = prim.indexBuffer else {
            vrmLog("❌ [DRAW 5] Missing index buffer")
            return
        }

        let indexCount = prim.indexCount
        var outOfRangeCount = 0
        var maxIndex: UInt32 = 0

        if prim.indexType == .uint16 {
            let ptr = indexBuffer.contents().advanced(by: prim.indexBufferOffset).assumingMemoryBound(to: UInt16.self)
            for i in 0..<indexCount {
                let idx = UInt32(ptr[i])
                if idx >= prim.vertexCount {
                    outOfRangeCount += 1
                    vrmLog("   ❌ idx[\(i)] = \(idx) (>= \(prim.vertexCount))")
                }
                maxIndex = max(maxIndex, idx)
            }
        } else {
            let ptr = indexBuffer.contents().advanced(by: prim.indexBufferOffset).assumingMemoryBound(to: UInt32.self)
            for i in 0..<indexCount {
                let idx = ptr[i]
                if idx >= prim.vertexCount {
                    outOfRangeCount += 1
                    vrmLog("   ❌ idx[\(i)] = \(idx) (>= \(prim.vertexCount))")
                }
                maxIndex = max(maxIndex, idx)
            }
        }

        if outOfRangeCount == 0 {
            vrmLog("   ✅ All indices within range (max=\(maxIndex))")
        } else {
            vrmLog("   ❌ \(outOfRangeCount) indices exceed vertex count")
        }

        let sampleCount = min(24, indexCount)
        let sample = (0..<sampleCount).map { "\($0)" }.joined(separator: ", ")
        vrmLog("   Sample indices: [\(sample)]")
    }
}
