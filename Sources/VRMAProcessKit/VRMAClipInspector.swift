import Foundation

/// Read-side helpers over a VRMA GLBContainer: locate the hips channel via
/// the VRMC_vrm_animation humanBones map and decode sampler float data.
public struct VRMAClipInspector {
    let container: GLBContainer
    public let hipsNode: Int
    public let humanBoneNodes: Set<Int>

    public enum InspectError: Error { case noAnimation, noHumanoidMap, noHipsTranslation, badAccessor, malformedNodes }

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
    /// Throws `badAccessor` if componentType is not 5126 (Float), type is not SCALAR/VEC3/VEC4,
    /// any index is out of range, or the byte range exceeds the bin buffer.
    public func floats(accessor index: Int) throws -> [Float] {
        guard let accessors = container.json["accessors"] as? [[String: Any]],
              index >= 0, index < accessors.count,
              let bvIndex = accessors[index]["bufferView"] as? Int,
              bvIndex >= 0,
              let count = accessors[index]["count"] as? Int,
              let componentType = accessors[index]["componentType"] as? Int,
              let type = accessors[index]["type"] as? String,
              let bvs = container.json["bufferViews"] as? [[String: Any]],
              bvIndex < bvs.count
        else { throw InspectError.badAccessor }
        // componentType 5126 (Float32) and a recognised vector width are required; any other type throws.
        guard componentType == 5126,
              let comps = ["SCALAR": 1, "VEC3": 3, "VEC4": 4][type]
        else { throw InspectError.badAccessor }
        let byteOffset = (bvs[bvIndex]["byteOffset"] as? Int ?? 0) + (accessors[index]["byteOffset"] as? Int ?? 0)
        let n = count * comps
        // Byte range must lie within the bin buffer before any unsafe memory access.
        guard byteOffset >= 0, n >= 0,
              byteOffset + n * 4 <= container.bin.count
        else { throw InspectError.badAccessor }
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
                  let si = ch["sampler"] as? Int, si >= 0, si < samplers.count,
                  let input = samplers[si]["input"] as? Int, input >= 0,
                  let output = samplers[si]["output"] as? Int, output >= 0
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
    /// Throws `malformedNodes` if a cycle is detected in the parent chain.
    public func hipsRestHeight() throws -> Float {
        guard let nodes = container.json["nodes"] as? [[String: Any]] else { throw InspectError.badAccessor }
        var parent: [Int: Int] = [:]
        for (i, n) in nodes.enumerated() {
            // Children indices that are out of range or negative are silently skipped.
            for c in (n["children"] as? [Int]) ?? [] {
                guard c >= 0, c < nodes.count else { continue }
                parent[c] = i
            }
        }
        var y: Float = 0
        var cur: Int? = hipsNode
        var visited = Set<Int>()
        while let c = cur {
            // Out-of-range or repeated node indices indicate a malformed hierarchy.
            guard c >= 0, c < nodes.count else { throw InspectError.malformedNodes }
            guard visited.insert(c).inserted else { throw InspectError.malformedNodes }
            if let t = nodes[c]["translation"] as? [Any], t.count == 3 {
                y += Float((t[1] as? NSNumber)?.doubleValue ?? 0)
            }
            cur = parent[c]
        }
        return y
    }
}
