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

/// The native-anime-v1 body/face control allowlist (parameters.md table),
/// expanded over `{side}` and carrying the per-control mesh-region masks that
/// a control is permitted to displace.
public enum NativeAnimeControls {
    public static let sides = ["left", "right"]

    /// Dependency tags reported by `ControlDescriptor.dependencies`.
    public enum Dependency {
        public static let geometry = "geometry"
        public static let rig = "rig"
        public static let morphs = "morphs"
        public static let fit = "fit"
        public static let springs = "springs"
        public static let lookAt = "lookat"
        public static let attachments = "attachments"
        public static let texture = "texture"
    }

    struct Entry {
        var key: String
        var unit: ControlUnit
        var valid: [Double]
        var recommended: [Double]
        var defaultValue: Double
        var affects: [ObjectKind]
        var dependencies: [String]
        var description: String
        var regions: [String]
    }

    static let bodyKinds: [ObjectKind] = [.avatar, .mesh, .garment]
    static let rigKinds: [ObjectKind] = [.avatar, .mesh, .node, .humanoid, .garment, .hair, .accessory, .spring, .collider, .lookat]
    static let faceKinds: [ObjectKind] = [.avatar, .mesh, .expression]

    static let allRegions = "*"

    static let bodyRegions = ["neck", "chest", "torso", "waist", "hips", "upperArmL", "upperArmR", "forearmL", "forearmR", "handL", "handR",
                              "thighL", "thighR", "shinL", "shinR", "footL", "footR"]
    static let armRegions = ["upperArmL", "upperArmR", "forearmL", "forearmR", "handL", "handR"]
    static let legRegions = ["thighL", "thighR", "shinL", "shinR", "footL", "footR"]
    static let headShellRegions = ["scalp", "nape", "forehead", "face", "jaw", "chin", "eyeSocketL", "eyeSocketR", "earL", "earR", "nose", "browL", "browR",
                                   "lipsUpper", "lipsLower", "innerMouth"]

    static func B(_ key: String, _ affects: [ObjectKind], _ deps: [String], _ description: String, regions: [String]) -> Entry {
        Entry(key: key, unit: .normalized, valid: [-1, 1], recommended: [-1, 1], defaultValue: 0, affects: affects, dependencies: deps,
              description: description, regions: regions)
    }

    static func U(_ key: String, _ defaultValue: Double, _ affects: [ObjectKind], _ deps: [String], _ description: String, regions: [String]) -> Entry {
        Entry(key: key, unit: .normalized, valid: [0, 1], recommended: [0, 1], defaultValue: defaultValue, affects: affects, dependencies: deps,
              description: description, regions: regions)
    }

    static func sided(_ template: String, side: String) -> String { template.replacingOccurrences(of: "{side}", with: side) }
    static func suffix(_ side: String) -> String { side == "left" ? "L" : "R" }

    /// Table rows in parameters.md order; `{side}` rows expand to left then right.
    static var entries: [Entry] {
        var rows: [Entry] = []
        let d = Dependency.self
        rows.append(Entry(key: "body.heightM", unit: .metres, valid: [1.2, 2.0], recommended: [1.4, 1.85], defaultValue: 1.65, affects: rigKinds,
                          dependencies: [d.geometry, d.rig, d.fit, d.springs, d.morphs, d.lookAt, d.attachments],
                          description: "Overall stature in metres; the whole rig and mesh scale while relative shape is preserved.", regions: [allRegions]))
        rows.append(Entry(key: "body.headCount", unit: .ratio, valid: [4.5, 8], recommended: [5.5, 7.5], defaultValue: 6.3, affects: rigKinds,
                          dependencies: [d.geometry, d.rig, d.fit, d.springs, d.morphs, d.lookAt, d.attachments],
                          description: "Head/body proportion as heads per stature; head and body re-proportion at fixed total height.", regions: [allRegions]))
        rows.append(B("body.proportion.shoulderWidth", rigKinds, [d.geometry, d.rig, d.fit], "Shoulder joint spread; arms follow.",
                      regions: ["chest", "torso"] + armRegions))
        rows.append(B("body.proportion.torsoLength", rigKinds, [d.geometry, d.rig, d.fit], "Hip-to-neck length traded against leg length at fixed stature.",
                      regions: ["chest", "torso", "waist", "hips"] + legRegions))
        rows.append(B("body.proportion.armLength", rigKinds, [d.geometry, d.rig, d.fit], "Upper and lower arm length.", regions: armRegions))
        rows.append(B("body.proportion.legLength", rigKinds, [d.geometry, d.rig, d.fit], "Leg length traded against torso length at fixed stature.",
                      regions: ["chest", "torso", "waist", "hips"] + legRegions))
        rows.append(B("body.proportion.hipWidth", rigKinds, [d.geometry, d.rig, d.fit], "Hip joint spread; legs follow.",
                      regions: ["hips", "waist"] + legRegions))
        rows.append(B("body.shape.chest", bodyKinds, [d.geometry, d.fit], "Chest ring depth and width basis.", regions: ["chest"]))
        rows.append(B("body.shape.waist", bodyKinds, [d.geometry, d.fit], "Waist ring radial basis.", regions: ["waist"]))
        rows.append(B("body.shape.hip", bodyKinds, [d.geometry, d.fit], "Hip ring radial basis.", regions: ["hips"]))
        rows.append(B("body.shape.muscle", bodyKinds, [d.geometry, d.fit], "Limb and torso radial mass basis.",
                      regions: ["chest", "torso", "waist", "hips"] + armRegions + legRegions))
        rows.append(B("face.head.width", faceKinds + [.hair, .accessory], [d.geometry, d.fit, d.attachments], "Head shell lateral silhouette; eye and mouth loops keep their topology.",
                      regions: headShellRegions))
        rows.append(B("face.head.depth", faceKinds + [.hair, .accessory], [d.geometry, d.fit, d.attachments], "Head shell front/back silhouette.",
                      regions: headShellRegions))
        rows.append(B("face.jaw.width", faceKinds, [d.geometry, d.morphs], "Lower head shell lateral width.", regions: ["face", "jaw", "chin", "earL", "earR"]))
        rows.append(B("face.chin.length", faceKinds, [d.geometry, d.morphs], "Chin extension downward.", regions: ["jaw", "chin"]))
        rows.append(B("face.chin.pointedness", faceKinds, [d.geometry, d.morphs], "Chin lateral convergence.", regions: ["jaw", "chin"]))
        for side in sides {
            let s = suffix(side)
            let eyeRegions = ["eyeSocket\(s)", "eyelidUpper\(s)", "eyelidLower\(s)", "globe\(s)"]
            rows.append(B(sided("face.eye.{side}.height", side: side), faceKinds + [.node, .lookat], [d.geometry, d.rig, d.morphs, d.lookAt],
                          "Eye opening height; lids, globe and pivot regenerate together.", regions: eyeRegions))
            rows.append(B(sided("face.eye.{side}.width", side: side), faceKinds + [.node, .lookat], [d.geometry, d.rig, d.morphs, d.lookAt],
                          "Eye opening width; lids, globe and pivot regenerate together.", regions: eyeRegions))
            rows.append(B(sided("face.eye.{side}.spacing", side: side), faceKinds + [.node, .lookat], [d.geometry, d.rig, d.morphs, d.lookAt],
                          "Eye pivot lateral offset from the head centre.", regions: eyeRegions))
            rows.append(B(sided("face.eye.{side}.tilt", side: side), faceKinds, [d.geometry, d.morphs],
                          "Lid ring tilt blend (outer corner up for positive); not degrees.", regions: eyeRegions))
        }
        for side in sides {
            let s = suffix(side)
            rows.append(U(sided("face.iris.{side}.size", side: side), 0.5, [.avatar, .mesh, .image], [d.geometry, d.texture],
                          "Iris ring polar angle on the globe; the iris UV region is constant.", regions: ["globe\(s)"]))
        }
        for side in sides {
            let s = suffix(side)
            rows.append(U(sided("face.pupil.{side}.size", side: side), 0.5, [.avatar, .mesh, .image], [d.geometry, d.texture],
                          "Pupil ring polar angle as a fraction of the iris angle.", regions: ["globe\(s)"]))
        }
        for side in sides {
            let s = suffix(side)
            rows.append(B(sided("face.brow.{side}.height", side: side), faceKinds, [d.geometry, d.morphs], "Brow strip vertical offset.", regions: ["brow\(s)"]))
            rows.append(B(sided("face.brow.{side}.angle", side: side), faceKinds, [d.geometry, d.morphs], "Brow strip rotation (outer end up for positive).", regions: ["brow\(s)"]))
            rows.append(B(sided("face.brow.{side}.thickness", side: side), faceKinds, [d.geometry, d.morphs], "Brow strip vertical extent.", regions: ["brow\(s)"]))
        }
        rows.append(B("face.nose.height", faceKinds, [d.geometry], "Nose vertical extent.", regions: ["nose"]))
        rows.append(B("face.nose.width", faceKinds, [d.geometry], "Nose lateral extent.", regions: ["nose"]))
        rows.append(B("face.nose.projection", faceKinds, [d.geometry], "Nose forward projection.", regions: ["nose"]))
        rows.append(B("face.mouth.width", faceKinds, [d.geometry, d.morphs], "Lip ring lateral extent with viseme preservation.",
                      regions: ["lipsUpper", "lipsLower", "innerMouth"]))
        rows.append(B("face.mouth.height", faceKinds, [d.geometry, d.morphs], "Lip ring vertical extent with viseme preservation.",
                      regions: ["lipsUpper", "lipsLower", "innerMouth"]))
        rows.append(B("face.lip.fullness", faceKinds, [d.geometry, d.morphs], "Outer lip contour fullness and forward push.",
                      regions: ["lipsUpper", "lipsLower"]))
        for side in sides {
            let s = suffix(side)
            rows.append(B(sided("face.ear.{side}.size", side: side), faceKinds + [.accessory, .node], [d.geometry, d.attachments], "Ear scale about its root.", regions: ["ear\(s)"]))
            rows.append(B(sided("face.ear.{side}.angle", side: side), faceKinds + [.accessory, .node], [d.geometry, d.attachments], "Ear fan-out about its root axis.", regions: ["ear\(s)"]))
        }
        return rows
    }

    public static var descriptors: [ControlDescriptor] {
        entries.map { e in
            var side = ControlSide.none
            var mirror: String?
            if e.key.contains(".left.") {
                side = .left
                mirror = e.key.replacingOccurrences(of: ".left.", with: ".right.")
            } else if e.key.contains(".right.") {
                side = .right
                mirror = e.key.replacingOccurrences(of: ".right.", with: ".left.")
            }
            return ControlDescriptor(key: e.key, unit: e.unit, validRange: e.valid, recommendedRange: e.recommended, defaultValue: e.defaultValue,
                                     side: side, mirrorKey: mirror, affects: e.affects, dependencies: e.dependencies, description: e.description)
        }
    }

    /// Mesh regions (by region name; "*" = every vertex of every mesh) that a
    /// control may displace. Vertices outside these regions must be bit-identical
    /// to the default build.
    public static var regionMasks: [String: [String]] {
        var out: [String: [String]] = [:]
        for e in entries { out[e.key] = e.regions }
        return out
    }

    public static var keys: [String] { entries.map(\.key) }

    public static var defaultBody: ControlValues {
        var out: ControlValues = [:]
        for e in entries where e.key.hasPrefix("body.") { out[e.key] = e.defaultValue }
        return out
    }

    public static var defaultFace: ControlValues {
        var out: ControlValues = [:]
        for e in entries where e.key.hasPrefix("face.") { out[e.key] = e.defaultValue }
        return out
    }
}

/// Fully resolved control values for one compile: defaults overlaid with the
/// recipe's body/face maps, every key validated against its descriptor.
struct NativeAnimeControlSet {
    private(set) var values: [String: Double]

    init(body: ControlValues, face: ControlValues) throws {
        var resolved: [String: Double] = [:]
        let descriptors = NativeAnimeControls.descriptors
        var byKey: [String: ControlDescriptor] = [:]
        for d in descriptors {
            byKey[d.key] = d
            resolved[d.key] = d.defaultValue
        }
        for (group, map) in [("body", body), ("face", face)] {
            for key in map.keys.sorted() {
                let value = map[key]!
                guard let d = byKey[key], key.hasPrefix(group + ".") else {
                    throw AuthorError.unknownField("/\(group)/\(JSONPointer.escape(key))", observed: .number(value))
                }
                guard d.accepts(value) else {
                    throw AuthorError.invalidRequest("Control '\(key)' must be within [\(d.validRange[0]), \(d.validRange[1])] \(d.unit.rawValue).",
                                                     path: "/\(group)/\(JSONPointer.escape(key))", observed: .number(value),
                                                     required: JSONValue(d.validRange))
                }
                resolved[key] = value
            }
        }
        values = resolved
    }

    subscript(_ key: String) -> Double { values[key] ?? 0 }

    func side(_ template: String, _ side: String) -> Double { self[NativeAnimeControls.sided(template, side: side)] }
}
