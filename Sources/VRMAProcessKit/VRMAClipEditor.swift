import Foundation

/// All animation samplers must share one keyframe timeline; resample before trimming.
public enum EditError: Error, CustomStringConvertible {
    case unalignedKeyframes
    public var description: String {
        switch self {
        case .unalignedKeyframes:
            return "animation channels carry genuinely different keyframe timelines — resample to a shared timeline before trimming"
        }
    }
}

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
    /// end-start >= 60% of the source key count, then rewrites only the
    /// channel-referenced samplers to the [start...end] window with times
    /// rebased to zero. Orphaned samplers are left untouched.
    /// Trimmed data is APPENDED as new bufferViews/accessors and samplers
    /// are repointed — existing bytes stay untouched.
    ///
    /// Timelines may live in distinct accessors as long as their values are
    /// identical (the common exporter pattern); genuinely divergent timelines
    /// throw unalignedKeyframes. When values match, all kept samplers' "input"
    /// is repointed to ONE shared new canonical accessor (not 91 identical copies).
    public mutating func loopTrim() throws {
        let inspector = try VRMAClipInspector(container: container)
        guard var anims = container.json["animations"] as? [[String: Any]], !anims.isEmpty,
              let channels = anims[0]["channels"] as? [[String: Any]],
              var samplers = anims[0]["samplers"] as? [[String: Any]]
        else { throw VRMAClipInspector.InspectError.noAnimation }

        // Every kept channel is sliced on the same [s...e] key window, so ALL of
        // them — rotations and the hips translation alike — must share one keyframe
        // timeline. Exporters commonly emit N distinct accessor objects that are
        // byte-identical (one per channel), so we first collect distinct accessor
        // indices and then verify their VALUES are elementwise equal before accepting.
        var channelInputs: [Int] = []
        for ch in channels {
            guard let si = ch["sampler"] as? Int, si >= 0, si < samplers.count,
                  let input = samplers[si]["input"] as? Int else { continue }
            channelInputs.append(input)
        }
        let distinctInputs = Array(Set(channelInputs))
        if distinctInputs.count > 1 {
            // Decode the first and compare every other accessor elementwise.
            let canonical = try inspector.floats(accessor: distinctInputs[0])
            for i in 1..<distinctInputs.count {
                let other = try inspector.floats(accessor: distinctInputs[i])
                guard other.count == canonical.count,
                      zip(other, canonical).allSatisfy({ $0 == $1 })
                else { throw EditError.unalignedKeyframes }
            }
        }
        // All timelines are value-identical; use the first distinct input as the
        // canonical accessor index for slicing.
        let canonicalInputIndex = distinctInputs.first

        guard let accessors0 = container.json["accessors"] as? [[String: Any]] else {
            throw VRMAClipInspector.InspectError.badAccessor
        }
        guard let bufferViews0 = container.json["bufferViews"] as? [[String: Any]] else {
            throw VRMAClipInspector.InspectError.badAccessor
        }

        // Collect rotation outputs for the seam metric.
        var rotationOutputs: [[Float]] = []
        for ch in channels {
            guard let target = ch["target"] as? [String: Any],
                  target["path"] as? String == "rotation",
                  let si = ch["sampler"] as? Int, si >= 0, si < samplers.count,
                  let out = samplers[si]["output"] as? Int else { continue }
            let q = try inspector.floats(accessor: out)
            rotationOutputs.append(q)
        }

        // keyCount comes from the canonical input accessor — the one timeline
        // every channel was just validated against (by value).
        guard let canonicalInput = canonicalInputIndex else {
            return  // no channels at all, nothing to trim
        }
        let keyCount: Int
        guard canonicalInput >= 0, canonicalInput < accessors0.count,
              let kc = accessors0[canonicalInput]["count"] as? Int
        else { throw VRMAClipInspector.InspectError.badAccessor }
        keyCount = kc
        guard !rotationOutputs.isEmpty else { return }  // no rotation channels, nothing to trim

        guard keyCount > 4 else { return }  // nothing meaningful to trim

        // Each rotation output must be exactly one quat per key.
        for q in rotationOutputs {
            guard q.count == keyCount * 4 else { throw VRMAClipInspector.InspectError.badAccessor }
        }

        // Hips Y joins the seam metric: idle rotations are near-flat, so
        // without the bob term the seam lands arbitrarily and pops vertically.
        var hipsY: [Float] = []
        if let (_, hipsOutputAcc) = try? inspector.hipsTranslationSampler() {
            let hipsVals = try inspector.floats(accessor: hipsOutputAcc)
            // VEC3 interleaved: x, y, z — hipsY is index 1, 4, 7, ...
            if hipsVals.count == keyCount * 3 {
                hipsY = stride(from: 1, to: hipsVals.count, by: 3).map { hipsVals[$0] }
            } else if !hipsVals.isEmpty {
                // count mismatch — throw rather than use corrupt data
                throw VRMAClipInspector.InspectError.badAccessor
            }
        }
        // Bob samples must align with the shared timeline.
        if !hipsY.isEmpty {
            guard hipsY.count == keyCount else { throw VRMAClipInspector.InspectError.badAccessor }
        }

        let wY: Float = 1.5  // ~1 cm of bob ≈ a few degrees of joint mismatch on the 1-|dot| scale
        func poseDistance(_ a: Int, _ b: Int) -> Float {
            var d: Float = 0
            for q in rotationOutputs {
                var dot: Float = 0
                for k in 0..<4 { dot += q[a * 4 + k] * q[b * 4 + k] }
                d += 1 - min(1, abs(dot))
            }
            // ~1 cm of bob mismatch weighs like a few degrees of joint error.
            if !hipsY.isEmpty {
                d += wY * abs(hipsY[a] - hipsY[b])
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

        // Rewrite only channel-referenced samplers to [best.s ... best.e] via appended views.
        // All kept samplers share ONE sliced input accessor (the canonical timeline);
        // outputs are still sliced per-accessor as each channel has its own data.
        var accessors = accessors0
        var bufferViews = bufferViews0
        var bin = container.bin

        let usedSamplers = Set(channels.compactMap { $0["sampler"] as? Int })

        var rewritten: [String: Int] = [:]

        let compsByType: [String: Int] = ["SCALAR": 1, "VEC3": 3, "VEC4": 4]

        func sliced(_ accessorIndex: Int, comps: Int, rebase: Bool) throws -> Int {
            // rebase only ever true for SCALAR inputs (comps==1)
            precondition(!rebase || comps == 1)
            let key = "\(accessorIndex)/\(comps)/\(rebase)"
            if let existing = rewritten[key] { return existing }
            let vals = try inspector.floats(accessor: accessorIndex)
            guard vals.count == keyCount * comps else { throw VRMAClipInspector.InspectError.badAccessor }
            let t0 = rebase ? vals[best.s] : 0
            var slice: [Float] = []
            slice.reserveCapacity((best.e - best.s + 1) * comps)
            for i in best.s...best.e {
                for c in 0..<comps { slice.append(vals[i * comps + c] - (rebase && c == 0 ? t0 : 0)) }
            }
            while bin.count % 4 != 0 { bin.append(0) }
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
            rewritten[key] = accessors.count - 1
            return accessors.count - 1
        }

        // Slice the canonical input ONCE; every kept sampler repoints to it.
        let sharedInputNew = try sliced(canonicalInput, comps: 1, rebase: true)

        for (i, s) in samplers.enumerated() {
            guard usedSamplers.contains(i) else { continue }
            guard let output = s["output"] as? Int else { continue }
            guard output >= 0, output < accessors.count,
                  let typeStr = accessors[output]["type"] as? String,
                  let outComps = compsByType[typeStr]
            else { throw VRMAClipInspector.InspectError.badAccessor }
            samplers[i]["input"] = sharedInputNew
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
