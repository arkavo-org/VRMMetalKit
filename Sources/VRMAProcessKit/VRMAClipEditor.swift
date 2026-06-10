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
}
