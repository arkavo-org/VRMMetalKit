import Foundation

/// Read-side helpers over a VRMA GLBContainer: locate the hips channel via
/// the VRMC_vrm_animation humanBones map and decode sampler float data.
public struct VRMAClipInspector {
    let container: GLBContainer
    public let hipsNode: Int
    public let humanBoneNodes: Set<Int>

    public enum InspectError: Error { case noAnimation, noHumanoidMap, noHipsTranslation, badAccessor }

    public init(container: GLBContainer) throws {
        self.container = container
        guard let ext = container.json["extensions"] as? [String: Any],
              let vrma = ext["VRMC_vrm_animation"] as? [String: Any],
              let humanoid = vrma["humanoid"] as? [String: Any],
              let bones = humanoid["humanBones"] as? [String: Any]
        else { throw InspectError.noHumanoidMap }
        var nodes = Set<Int>()
        var hips: Int?
        for (name, v) in bones {
            guard let d = v as? [String: Any], let n = d["node"] as? Int else { continue }
            nodes.insert(n)
            if name == "hips" { hips = n }
        }
        guard let h = hips else { throw InspectError.noHumanoidMap }
        self.hipsNode = h
        self.humanBoneNodes = nodes
    }

    func animation0() throws -> [String: Any] {
        guard let anims = container.json["animations"] as? [[String: Any]], let a = anims.first
        else { throw InspectError.noAnimation }
        return a
    }

    /// Decodes the float array backing accessor `index`.
    public func floats(accessor index: Int) throws -> [Float] {
        guard let accessors = container.json["accessors"] as? [[String: Any]],
              index < accessors.count,
              let bvIndex = accessors[index]["bufferView"] as? Int,
              let count = accessors[index]["count"] as? Int,
              let type = accessors[index]["type"] as? String,
              let bvs = container.json["bufferViews"] as? [[String: Any]],
              bvIndex < bvs.count
        else { throw InspectError.badAccessor }
        let comps = ["SCALAR": 1, "VEC3": 3, "VEC4": 4][type] ?? 1
        let byteOffset = (bvs[bvIndex]["byteOffset"] as? Int ?? 0) + (accessors[index]["byteOffset"] as? Int ?? 0)
        let n = count * comps
        return container.bin.withUnsafeBytes { raw in
            (0..<n).map { raw.loadUnaligned(fromByteOffset: byteOffset + $0 * 4, as: Float.self) }
        }
    }

    /// (input accessor, output accessor) of the hips translation channel.
    public func hipsTranslationSampler() throws -> (input: Int, output: Int) {
        let anim = try animation0()
        guard let channels = anim["channels"] as? [[String: Any]],
              let samplers = anim["samplers"] as? [[String: Any]]
        else { throw InspectError.noAnimation }
        for ch in channels {
            guard let target = ch["target"] as? [String: Any],
                  target["node"] as? Int == hipsNode,
                  target["path"] as? String == "translation",
                  let si = ch["sampler"] as? Int, si < samplers.count,
                  let input = samplers[si]["input"] as? Int,
                  let output = samplers[si]["output"] as? Int
            else { continue }
            return (input, output)
        }
        throw InspectError.noHipsTranslation
    }

    /// Mean ground speed of the hips over the clip: total XZ path length / duration.
    public func meanHipsXZSpeed() throws -> Float {
        let (inputAcc, outputAcc) = try hipsTranslationSampler()
        let times = try floats(accessor: inputAcc)
        let xyz = try floats(accessor: outputAcc)
        guard times.count >= 2, xyz.count == times.count * 3 else { throw InspectError.badAccessor }
        var path: Float = 0
        for i in 1..<times.count {
            let dx = xyz[i * 3] - xyz[(i - 1) * 3]
            let dz = xyz[i * 3 + 2] - xyz[(i - 1) * 3 + 2]
            path += (dx * dx + dz * dz).squareRoot()
        }
        let duration = times.last! - times.first!
        return duration > 0 ? path / duration : 0
    }

    /// Rest hips world height from the node hierarchy (sum of ancestor Y translations).
    public func hipsRestHeight() throws -> Float {
        guard let nodes = container.json["nodes"] as? [[String: Any]] else { throw InspectError.badAccessor }
        var parent: [Int: Int] = [:]
        for (i, n) in nodes.enumerated() {
            for c in (n["children"] as? [Int]) ?? [] { parent[c] = i }
        }
        var y: Float = 0
        var cur: Int? = hipsNode
        while let c = cur {
            if let t = nodes[c]["translation"] as? [Any], t.count == 3 {
                y += Float((t[1] as? NSNumber)?.doubleValue ?? 0)
            }
            cur = parent[c]
        }
        return y
    }
}
