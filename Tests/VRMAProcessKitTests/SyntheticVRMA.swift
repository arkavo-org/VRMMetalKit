import Foundation
@testable import VRMAProcessKit

/// Builds a minimal but valid VRMA glb in memory: a 3-node rig
/// (root → hips → rightUpperLeg), a VRMC_vrm_animation humanBones map,
/// one animation with a hips translation track (constant ground speed
/// `vx` on X, sinusoidal Y bob) and a rightUpperLeg rotation track, plus
/// one non-humanoid "J_Sec_Hair" rotation track for strip tests.
enum SyntheticVRMA {
    /// 30 Hz keys over `duration` seconds.
    static func make(duration: Float = 2.0, vx: Float = 1.5, includeHairTrack: Bool = true) throws -> Data {
        let n = max(2, Int(duration * 30))
        var times: [Float] = []
        var hipsT: [Float] = []      // xyz interleaved
        var legR: [Float] = []       // quat xyzw interleaved
        var hairR: [Float] = []
        for i in 0..<n {
            let t = Float(i) / 30.0
            times.append(t)
            hipsT.append(contentsOf: [0.1 + vx * t, 0.85 + 0.02 * sin(t * 4), 0.05])
            let a = 0.3 * sin(t * 6)
            legR.append(contentsOf: [sin(a / 2), 0, 0, cos(a / 2)])
            hairR.append(contentsOf: [0, sin(a / 4), 0, cos(a / 4)])
        }
        var bin = Data()
        func append(_ floats: [Float]) -> Int {  // returns byteOffset
            let off = bin.count
            floats.withUnsafeBytes { bin.append(contentsOf: $0) }
            return off
        }
        let timesOff = append(times), hipsOff = append(hipsT)
        let legOff = append(legR), hairOff = append(hairR)

        func bufferView(_ off: Int, _ len: Int) -> [String: Any] {
            ["buffer": 0, "byteOffset": off, "byteLength": len]
        }
        func accessor(_ bv: Int, _ count: Int, _ type: String) -> [String: Any] {
            var a: [String: Any] = ["bufferView": bv, "componentType": 5126, "count": count, "type": type]
            if type == "SCALAR" { a["min"] = [0]; a["max"] = [times.last!] }
            return a
        }
        var channels: [[String: Any]] = [
            ["sampler": 0, "target": ["node": 1, "path": "translation"]],
            ["sampler": 1, "target": ["node": 2, "path": "rotation"]],
        ]
        var samplers: [[String: Any]] = [
            ["input": 0, "output": 1, "interpolation": "LINEAR"],
            ["input": 0, "output": 2, "interpolation": "LINEAR"],
        ]
        var accessors: [[String: Any]] = [
            accessor(0, n, "SCALAR"), accessor(1, n, "VEC3"), accessor(2, n, "VEC4"),
        ]
        var bufferViews: [[String: Any]] = [
            bufferView(timesOff, times.count * 4), bufferView(hipsOff, hipsT.count * 4),
            bufferView(legOff, legR.count * 4),
        ]
        var nodes: [[String: Any]] = [
            ["name": "Root", "children": [1]],
            ["name": "J_Bip_C_Hips", "translation": [0, 0.85, 0], "children": [2]],
            ["name": "J_Bip_R_UpperLeg", "translation": [-0.08, -0.05, 0]],
        ]
        if includeHairTrack {
            nodes.append(["name": "J_Sec_Hair", "translation": [0, 0.2, 0]])
            bufferViews.append(bufferView(hairOff, hairR.count * 4))
            accessors.append(accessor(3, n, "VEC4"))
            samplers.append(["input": 0, "output": 3, "interpolation": "LINEAR"])
            channels.append(["sampler": 2, "target": ["node": 3, "path": "rotation"]])
        }
        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "buffers": [["byteLength": bin.count]],
            "bufferViews": bufferViews,
            "accessors": accessors,
            "nodes": nodes,
            "animations": [["channels": channels, "samplers": samplers]],
            "extensions": ["VRMC_vrm_animation": ["specVersion": "1.0", "humanoid": ["humanBones": [
                "hips": ["node": 1], "rightUpperLeg": ["node": 2],
            ]]]],
        ]
        let glb = GLBContainer(json: json, bin: bin)
        return try glb.serialize()
    }
}
