import Foundation

/// Write-side glb surgery for locomotion ingest. All edits are minimal and
/// in-place: the bin chunk is only modified where values change.
public struct VRMAClipEditor {
    public var container: GLBContainer

    public init(container: GLBContainer) { self.container = container }

    /// Rebase the hips translation track's X and Z to their first-frame
    /// values (in-place float writes in the bin chunk; same byte length).
    /// Y (bob) and all rotation tracks are untouched.
    public mutating func stripHipsXZ() throws {
        let inspector = try VRMAClipInspector(container: container)
        let (_, outputAcc) = try inspector.hipsTranslationSampler()
        guard let accessors = container.json["accessors"] as? [[String: Any]],
              outputAcc >= 0, outputAcc < accessors.count,
              let count = accessors[outputAcc]["count"] as? Int,
              let bvIndex = accessors[outputAcc]["bufferView"] as? Int,
              let bvs = container.json["bufferViews"] as? [[String: Any]],
              bvIndex >= 0, bvIndex < bvs.count
        else { throw VRMAClipInspector.InspectError.badAccessor }
        let base = (bvs[bvIndex]["byteOffset"] as? Int ?? 0) + (accessors[outputAcc]["byteOffset"] as? Int ?? 0)
        // count >= 1: the first-frame reads at base/base+8 must be in range.
        // float32 VEC3 required — the write path enforces the same accessor
        // shape the read path (floats(accessor:)) does, so a malformed hips
        // accessor throws instead of being silently stomped.
        // base % 4 == 0: storeBytes(of:toByteOffset:as:) requires Float
        // alignment (glTF guarantees it for float accessors).
        guard base >= 0, count >= 1,
              accessors[outputAcc]["componentType"] as? Int == 5126,
              accessors[outputAcc]["type"] as? String == "VEC3",
              base % 4 == 0,
              base + count * 12 <= container.bin.count
        else { throw VRMAClipInspector.InspectError.badAccessor }
        var bin = container.bin
        let x0 = bin.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: base, as: Float.self) }
        let z0 = bin.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: base + 8, as: Float.self) }
        bin.withUnsafeMutableBytes { raw in
            for i in 0..<count {
                raw.storeBytes(of: x0, toByteOffset: base + i * 12, as: Float.self)
                raw.storeBytes(of: z0, toByteOffset: base + i * 12 + 8, as: Float.self)
            }
        }
        container.bin = bin
    }

    /// Drops animation channels whose target node is not in the
    /// VRMC_vrm_animation humanBones map (baked hair/eye/accessory tracks).
    /// Orphaned samplers/accessors are left in place — valid glTF, zero risk
    /// to untouched data. Returns the number of channels dropped.
    @discardableResult
    public mutating func stripNonHumanoidChannels() throws -> Int {
        let inspector = try VRMAClipInspector(container: container)
        guard var anims = container.json["animations"] as? [[String: Any]], !anims.isEmpty,
              let channels = anims[0]["channels"] as? [[String: Any]]
        else { throw VRMAClipInspector.InspectError.noAnimation }
        let kept = channels.filter { ch in
            guard let target = ch["target"] as? [String: Any], let node = target["node"] as? Int
            else { return false }
            return inspector.humanBoneNodes.contains(node)
        }
        let dropped = channels.count - kept.count
        anims[0]["channels"] = kept
        container.json["animations"] = anims
        return dropped
    }

    /// Pose-similarity loop trim. Works for walk and idle alike (locomotion
    /// spec §3): finds the (start, end) key pair with minimal summed
    /// quaternion distance across all kept rotation channels, subject to
    /// end-start >= 60% of the source key count, then rewrites every
    /// sampler to the [start...end] window with times rebased to zero.
    /// Trimmed data is APPENDED as new bufferViews/accessors and samplers
    /// are repointed — existing bytes stay untouched.
    public mutating func loopTrim() throws {
        let inspector = try VRMAClipInspector(container: container)
        guard var anims = container.json["animations"] as? [[String: Any]], !anims.isEmpty,
              let channels = anims[0]["channels"] as? [[String: Any]],
              var samplers = anims[0]["samplers"] as? [[String: Any]]
        else { throw VRMAClipInspector.InspectError.noAnimation }

        // Collect rotation outputs + the shared key count.
        var rotationOutputs: [[Float]] = []
        var keyCount = 0
        for ch in channels {
            guard let target = ch["target"] as? [String: Any],
                  target["path"] as? String == "rotation",
                  let si = ch["sampler"] as? Int, si >= 0, si < samplers.count,
                  let out = samplers[si]["output"] as? Int else { continue }
            let q = try inspector.floats(accessor: out)
            rotationOutputs.append(q)
            keyCount = q.count / 4
        }
        guard keyCount > 4 else { return }  // nothing meaningful to trim

        func poseDistance(_ a: Int, _ b: Int) -> Float {
            var d: Float = 0
            for q in rotationOutputs {
                var dot: Float = 0
                for k in 0..<4 { dot += q[a * 4 + k] * q[b * 4 + k] }
                d += 1 - min(1, abs(dot))
            }
            return d
        }
        let minSpan = Int(Float(keyCount) * 0.6)
        var best = (s: 0, e: keyCount - 1, d: Float.greatestFiniteMagnitude)
        for s in 0..<(keyCount - minSpan) {
            for e in (s + minSpan)..<keyCount {
                let d = poseDistance(s, e)
                if d < best.d { best = (s, e, d) }
            }
        }

        // Rewrite every sampler to [best.s ... best.e] via appended views.
        var accessors = container.json["accessors"] as! [[String: Any]]
        var bufferViews = container.json["bufferViews"] as! [[String: Any]]
        var bin = container.bin
        var rewritten: [Int: Int] = [:]  // old accessor -> new accessor

        func sliced(_ accessorIndex: Int, comps: Int, rebase: Bool) throws -> Int {
            // rebase only ever true for SCALAR inputs (comps==1)
            precondition(!rebase || comps == 1)
            if let existing = rewritten[accessorIndex] { return existing }
            let vals = try inspector.floats(accessor: accessorIndex)
            guard vals.count >= (best.e + 1) * comps else { throw VRMAClipInspector.InspectError.badAccessor }
            let t0 = rebase ? vals[best.s] : 0
            var slice: [Float] = []
            slice.reserveCapacity((best.e - best.s + 1) * comps)
            for i in best.s...best.e {
                for c in 0..<comps { slice.append(vals[i * comps + c] - (rebase && c == 0 ? t0 : 0)) }
            }
            let off = bin.count
            slice.withUnsafeBytes { bin.append(contentsOf: $0) }
            bufferViews.append(["buffer": 0, "byteOffset": off, "byteLength": slice.count * 4])
            var acc: [String: Any] = [
                "bufferView": bufferViews.count - 1, "componentType": 5126,
                "count": best.e - best.s + 1,
                "type": comps == 1 ? "SCALAR" : (comps == 3 ? "VEC3" : "VEC4"),
            ]
            if comps == 1 { acc["min"] = [0]; acc["max"] = [slice.last!] }
            accessors.append(acc)
            rewritten[accessorIndex] = accessors.count - 1
            return accessors.count - 1
        }

        for (i, s) in samplers.enumerated() {
            guard let input = s["input"] as? Int, let output = s["output"] as? Int else { continue }
            let outComps = ((accessors[output]["type"] as? String) == "VEC3") ? 3 : 4
            samplers[i]["input"] = try sliced(input, comps: 1, rebase: true)
            samplers[i]["output"] = try sliced(output, comps: outComps, rebase: false)
        }
        anims[0]["samplers"] = samplers
        container.json["animations"] = anims
        container.json["accessors"] = accessors
        container.json["bufferViews"] = bufferViews
        if var buffers = container.json["buffers"] as? [[String: Any]], !buffers.isEmpty {
            buffers[0]["byteLength"] = bin.count
            container.json["buffers"] = buffers
        }
        container.bin = bin
    }
}
