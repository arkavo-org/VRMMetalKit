// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import simd
import VRMMetalKit

/// Records per-frame spring-bone world positions to a CSV file for post-render
/// trajectory analysis. Each row captures the bone, its parent, and the
/// rigid-follow expectation so tests can assert behaviors like inertia lag and
/// settled-state flutter without re-deriving bind-pose geometry.
///
/// CSV columns: `frame,time_s,bone,wx,wy,wz,px,py,pz,rx,ry,rz`
/// - `w*` — bone world position after physics
/// - `p*` — parent world position
/// - `r*` — rigid-follow world position = parent.worldMatrix * (initialTranslation, 1)
///
/// Long-form (one row per bone-frame) so the bone set can vary between models
/// without changing the schema.
final class BoneTrajectoryDumper {

    enum DumperError: Error {
        case cannotOpenFile(String)
        case invalidRegex(String)
    }

    private let fileHandle: FileHandle
    private let filter: NSRegularExpression?

    init(path: String, filterPattern: String?) throws {
        FileManager.default.createFile(atPath: path, contents: nil, attributes: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw DumperError.cannotOpenFile(path)
        }
        self.fileHandle = handle

        if let pattern = filterPattern, !pattern.isEmpty {
            do {
                self.filter = try NSRegularExpression(pattern: pattern)
            } catch {
                throw DumperError.invalidRegex(pattern)
            }
        } else {
            self.filter = nil
        }

        let header = "frame,time_s,bone,wx,wy,wz,px,py,pz,rx,ry,rz\n"
        try handle.write(contentsOf: Data(header.utf8))
    }

    /// Append rows for every spring-bone joint that matches the filter (or all of
    /// them if no filter was set). Call after the per-frame draw + GPU completion
    /// so that `node.worldMatrix` reflects the latest physics result that
    /// `writeBonesToNodes` has applied.
    func recordFrame(model: VRMModel, frameIndex: Int, timeSeconds: Double) {
        guard let springBone = model.springBone else { return }

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
                    let bindLocal = SIMD4<Float>(node.initialTranslation, 1.0)
                    let world4 = parent.worldMatrix * bindLocal
                    r = SIMD3<Float>(world4.x, world4.y, world4.z)
                } else {
                    // Root joint: no parent → rigid-follow == own position.
                    p = w
                    r = w
                }

                rows += String(
                    format: "%d,%.6f,%@,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\n",
                    frameIndex, timeSeconds, safeName,
                    w.x, w.y, w.z,
                    p.x, p.y, p.z,
                    r.x, r.y, r.z
                )
            }
        }

        if !rows.isEmpty {
            try? fileHandle.write(contentsOf: Data(rows.utf8))
        }
    }

    func finish() {
        try? fileHandle.close()
    }
}
