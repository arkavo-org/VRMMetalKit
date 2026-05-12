// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import simd

/// Records per-frame spring-bone world positions to a CSV file (or in-memory
/// buffer) for trajectory analysis. Each row captures the bone, its parent,
/// and the rigid-follow expectation so tests can assert behaviors like
/// inertia lag and settled-state flutter without re-deriving bind-pose
/// geometry.
///
/// CSV columns: `frame,time_s,bone,wx,wy,wz,px,py,pz,rx,ry,rz`
/// - `w*` — bone world position after physics
/// - `p*` — parent world position (physics-influenced)
/// - `r*` — rigid-follow world position: where this bone would be if every
///   spring joint above it stayed at bind rotation. Computed by walking up
///   to the first non-spring ancestor (whose world matrix is animated and
///   not touched by physics), then composing bind-pose local matrices back
///   down using `initialTranslation`, `initialRotation`, and `initialScale`.
///
/// Long-form (one row per bone-frame) so the bone set can vary between models
/// without changing the schema.
public final class BoneTrajectoryDumper {

    /// Errors thrown by ``BoneTrajectoryDumper``.
    public enum DumperError: Error {
        /// The CSV file path could not be opened for writing.
        case cannotOpenFile(String)
        /// The supplied bone-name filter pattern is not a valid `NSRegularExpression`.
        case invalidRegex(String)
    }

    /// In-memory snapshot — what tests consume directly without round-tripping
    /// through CSV. Mirrors the CSV columns exactly.
    public struct Sample: Equatable {
        /// Zero-based frame index recorded by the dumper.
        public let frame: Int
        /// Frame time in seconds, as supplied to ``BoneTrajectoryDumper/recordFrame(model:frameIndex:timeSeconds:)``.
        public let time: Double
        /// Bone (node) name with commas replaced by underscores for CSV safety.
        public let bone: String
        /// Bone world position after spring-bone physics.
        public let world: SIMD3<Float>
        /// Parent node world position (physics-influenced).
        public let parent: SIMD3<Float>
        /// Rigid-follow world position — where the bone would be if every spring
        /// joint in its ancestor chain stayed at bind rotation.
        public let rigid: SIMD3<Float>

        /// Creates a sample with the given per-frame bone positions.
        public init(frame: Int, time: Double, bone: String,
                    world: SIMD3<Float>, parent: SIMD3<Float>, rigid: SIMD3<Float>) {
            self.frame = frame
            self.time = time
            self.bone = bone
            self.world = world
            self.parent = parent
            self.rigid = rigid
        }
    }

    /// Output sink — the dumper appends per-frame rows to whichever sink was
    /// supplied at init.
    public enum Sink {
        case file(FileHandle)
        case memory  // samples land in `inMemorySamples`
    }

    /// Header line written to CSV outputs. Reuse this when constructing a
    /// CSV from `inMemorySamples` after the fact.
    public static let csvHeader = "frame,time_s,bone,wx,wy,wz,px,py,pz,rx,ry,rz\n"

    /// Parse a CSV file produced by either CSV-sink dumper output or the
    /// `--dump-bones` CLI flag. Malformed rows are skipped silently.
    public static func parseCSV(at path: String) throws -> [Sample] {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        return parseCSV(content: content)
    }

    /// Parses an in-memory CSV string in the dumper's column format. Malformed
    /// rows are skipped silently; the leading header row (if present) is ignored.
    public static func parseCSV(content: String) -> [Sample] {
        var samples: [Sample] = []
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        for (index, raw) in lines.enumerated() {
            if index == 0, raw.hasPrefix("frame,") { continue }  // header
            let fields = raw.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 12,
                  let frame = Int(fields[0]),
                  let time = Double(fields[1]) else { continue }
            let bone = String(fields[2])
            let nums = fields[3..<12].compactMap { Float($0) }
            guard nums.count == 9 else { continue }
            samples.append(Sample(
                frame: frame, time: time, bone: bone,
                world: SIMD3(nums[0], nums[1], nums[2]),
                parent: SIMD3(nums[3], nums[4], nums[5]),
                rigid: SIMD3(nums[6], nums[7], nums[8])
            ))
        }
        return samples
    }

    private let sink: Sink
    private let filter: NSRegularExpression?
    private var springJointIndices: Set<Int> = []

    /// Samples collected when `sink == .memory`. Empty when sink is a file.
    public private(set) var inMemorySamples: [Sample] = []

    /// Writes to a CSV file at `path`. The file is truncated and the header
    /// is written immediately.
    public init(path: String, filterPattern: String? = nil) throws {
        FileManager.default.createFile(atPath: path, contents: nil, attributes: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw DumperError.cannotOpenFile(path)
        }
        self.sink = .file(handle)
        self.filter = try Self.compileFilter(filterPattern)
        try handle.write(contentsOf: Data(Self.csvHeader.utf8))
    }

    /// Collects samples in memory (no file I/O). Read them back via
    /// `inMemorySamples` after recording is done.
    public init(filterPattern: String? = nil) throws {
        self.sink = .memory
        self.filter = try Self.compileFilter(filterPattern)
    }

    private static func compileFilter(_ pattern: String?) throws -> NSRegularExpression? {
        guard let pattern = pattern, !pattern.isEmpty else { return nil }
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            throw DumperError.invalidRegex(pattern)
        }
    }

    /// Append rows for every spring-bone joint that matches the filter (or all
    /// of them if no filter was set). Call after `writeBonesToNodes` and
    /// `model.updateNodeTransforms()` so that `node.worldMatrix` reflects the
    /// latest physics result.
    public func recordFrame(model: VRMModel, frameIndex: Int, timeSeconds: Double) {
        guard let springBone = model.springBone else { return }

        if springJointIndices.isEmpty {
            for spring in springBone.springs {
                for joint in spring.joints where joint.node >= 0 {
                    springJointIndices.insert(joint.node)
                }
            }
        }

        // Cache rigid world matrices for this frame so a deep chain doesn't
        // recompute its entire ancestor path per joint.
        var rigidMatrixCache: [Int: float4x4] = [:]

        var rows = ""
        for spring in springBone.springs {
            for joint in spring.joints {
                guard joint.node >= 0, joint.node < model.nodes.count else { continue }
                let node = model.nodes[joint.node]
                let rawName = node.name ?? "node_\(node.index)"

                if let filter = filter {
                    let range = NSRange(rawName.startIndex..., in: rawName)
                    if filter.firstMatch(in: rawName, options: [], range: range) == nil { continue }
                }

                let safeName = rawName.replacingOccurrences(of: ",", with: "_")
                let w = node.worldPosition
                let p: SIMD3<Float>
                let r: SIMD3<Float>

                if let parent = node.parent {
                    p = parent.worldPosition
                    let rigidMatrix = rigidWorldMatrix(of: node, cache: &rigidMatrixCache)
                    let rigidCol = rigidMatrix.columns.3
                    r = SIMD3<Float>(rigidCol.x, rigidCol.y, rigidCol.z)
                } else {
                    p = w
                    r = w
                }

                switch sink {
                case .memory:
                    inMemorySamples.append(Sample(
                        frame: frameIndex, time: timeSeconds, bone: safeName,
                        world: w, parent: p, rigid: r
                    ))
                case .file:
                    rows += String(
                        format: "%d,%.6f,%@,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\n",
                        frameIndex, timeSeconds, safeName,
                        w.x, w.y, w.z,
                        p.x, p.y, p.z,
                        r.x, r.y, r.z
                    )
                }
            }
        }

        if case let .file(handle) = sink, !rows.isEmpty {
            try? handle.write(contentsOf: Data(rows.utf8))
        }
    }

    /// Closes the file handle (no-op for memory sink).
    public func finish() {
        if case let .file(handle) = sink {
            try? handle.close()
        }
    }

    // MARK: - Rigid-follow matrix

    /// Returns the world matrix this node would have if every spring joint
    /// in its ancestor chain were locked at bind rotation. Non-spring
    /// ancestors use their actual (animated) world matrix.
    private func rigidWorldMatrix(of node: VRMNode, cache: inout [Int: float4x4]) -> float4x4 {
        if let cached = cache[node.index] { return cached }

        // Non-spring nodes: use the node's actual world matrix (animated,
        // not touched by spring physics).
        if !springJointIndices.contains(node.index) {
            cache[node.index] = node.worldMatrix
            return node.worldMatrix
        }

        // Spring root with no parent: nothing above to substitute, use actual.
        guard let parent = node.parent else {
            cache[node.index] = node.worldMatrix
            return node.worldMatrix
        }

        let parentRigid = rigidWorldMatrix(of: parent, cache: &cache)
        let bindLocal = bindPoseLocalMatrix(node)
        let rigid = parentRigid * bindLocal
        cache[node.index] = rigid
        return rigid
    }

    /// Build a node's local matrix from `initialTranslation`, `initialRotation`,
    /// and `initialScale` — i.e., the bind-pose transform untouched by physics
    /// or animation playback.
    private func bindPoseLocalMatrix(_ node: VRMNode) -> float4x4 {
        let t = SIMD3<Float>(node.initialTranslation)
        let q = node.initialRotation
        let s = node.initialScale

        // Translation column-major.
        let translateCol = SIMD4<Float>(t.x, t.y, t.z, 1)

        // Quaternion → 3×3 rotation (matches updateLocalMatrix in VRMNode).
        let x = q.imag.x, y = q.imag.y, z = q.imag.z, w = q.real
        let xx = x * x, yy = y * y, zz = z * z
        let xy = x * y, xz = x * z, yz = y * z
        let wx = w * x, wy = w * y, wz = w * z

        let r0 = SIMD3<Float>(1.0 - 2.0 * (yy + zz), 2.0 * (xy + wz), 2.0 * (xz - wy))
        let r1 = SIMD3<Float>(2.0 * (xy - wz), 1.0 - 2.0 * (xx + zz), 2.0 * (yz + wx))
        let r2 = SIMD3<Float>(2.0 * (xz + wy), 2.0 * (yz - wx), 1.0 - 2.0 * (xx + yy))

        // Compose rotation × scale into 3×3, then promote to 4×4 with translation.
        let col0 = SIMD4<Float>(r0 * s.x, 0)
        let col1 = SIMD4<Float>(r1 * s.y, 0)
        let col2 = SIMD4<Float>(r2 * s.z, 0)

        return float4x4([col0, col1, col2, translateCol])
    }
}
