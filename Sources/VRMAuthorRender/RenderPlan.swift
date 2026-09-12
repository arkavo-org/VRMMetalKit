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
import simd
import VRMAuthorKit

struct RenderFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// The `RenderScenario.configuration` fields `qa plan` locks for authoring-v1,
/// decoded into typed values with the canonical-pack defaults.
struct RenderPlan {
    enum Projection: String { case perspective, orthographic }

    var scenarioId: String
    var kind: String
    var width: Int
    var height: Int
    var projection: Projection
    var fovDegrees: Float
    var orthographicHeightM: Float
    var cameraPosition: SIMD3<Float>
    var cameraTarget: SIMD3<Float>
    var cameraUp: SIMD3<Float>
    var background: SIMD4<Float>
    var exposureEV: Float
    var lightDirection: SIMD3<Float>
    var lightColour: SIMD3<Float>
    var lightIntensity: Float
    var pose: String
    var expressionWeights: [String: Float]
    var frameTimesS: [Double]?
    var timestepS: Double
    var durationS: Double
    var sampleCount: Int

    static let defaultSampleCount = 4
    static let defaultTimestepS = 1.0 / 120.0

    init(scenario: RenderScenario) throws {
        let c = scenario.configuration
        scenarioId = scenario.id
        kind = scenario.kind
        width = try RenderPlan.int(c["width"], "width", default: 1024)
        height = try RenderPlan.int(c["height"], "height", default: 1024)
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { throw RenderFailure("width/height must be within 1...16384.") }
        let projectionText = c["projection"]?.string ?? Projection.perspective.rawValue
        guard let projection = Projection(rawValue: projectionText) else { throw RenderFailure("projection must be perspective or orthographic; found '\(projectionText)'.") }
        self.projection = projection
        fovDegrees = try RenderPlan.float(c["fovDegrees"], "fovDegrees", default: 30)
        orthographicHeightM = try RenderPlan.float(c["orthographicHeightM"], "orthographicHeightM", default: 2)
        guard fovDegrees > 0, fovDegrees < 180, orthographicHeightM > 0 else { throw RenderFailure("fovDegrees must lie in (0, 180) and orthographicHeightM must be positive.") }
        cameraPosition = try RenderPlan.vec3(c["camera"]?["position"], "camera.position", default: [0, 1.3, 2.4])
        cameraTarget = try RenderPlan.vec3(c["camera"]?["target"], "camera.target", default: [0, 1.0, 0])
        cameraUp = try RenderPlan.vec3(c["up"] ?? c["camera"]?["up"], "up", default: [0, 1, 0])
        background = try RenderPlan.vec4(c["background"], "background", default: [0.5, 0.5, 0.5, 1])
        exposureEV = try RenderPlan.float(c["exposureEV"], "exposureEV", default: 0)
        lightDirection = try RenderPlan.vec3(c["light"]?["direction"], "light.direction", default: [-0.3, -1, -0.5])
        lightColour = try RenderPlan.vec3(c["light"]?["colour"] ?? c["light"]?["color"], "light.colour", default: [1, 1, 1])
        lightIntensity = try RenderPlan.float(c["light"]?["intensity"], "light.intensity", default: 1)
        if let type = c["light"]?["type"]?.string, type != "directional" { throw RenderFailure("light.type '\(type)' is not supported; only directional lights render.") }
        pose = c["pose"]?.string ?? "rest"
        guard pose == "rest" else { throw RenderFailure("pose '\(pose)' is not supported; only the rest pose renders.") }
        var weights: [String: Float] = [:]
        for (name, value) in c["expressionWeights"]?.object ?? [:] {
            guard let weight = value.number else { throw RenderFailure("expressionWeights.\(name) must be a number.") }
            weights[name] = Float(min(max(weight, 0), 1))
        }
        expressionWeights = weights
        if let times = c["frameTimesS"]?.array {
            frameTimesS = try times.map { value in
                guard let time = value.number, time >= 0 else { throw RenderFailure("frameTimesS entries must be non-negative numbers.") }
                return time
            }
        } else {
            frameTimesS = nil
        }
        timestepS = try RenderPlan.double(c["timestepS"], "timestepS", default: RenderPlan.defaultTimestepS)
        durationS = try RenderPlan.double(c["durationS"], "durationS", default: 0)
        guard timestepS > 0, durationS >= 0 else { throw RenderFailure("timestepS must be positive and durationS non-negative.") }
        sampleCount = try RenderPlan.int(c["sampleCount"], "sampleCount", default: RenderPlan.defaultSampleCount)
        guard [1, 2, 4, 8].contains(sampleCount) else { throw RenderFailure("sampleCount must be 1, 2, 4 or 8.") }
    }

    var isMotion: Bool { kind == "motion" }

    /// Simulation step count for motion scenarios; zero for stills.
    var stepCount: Int { isMotion ? Int((durationS / timestepS).rounded()) : 0 }

    /// Times at which a PNG is captured. Stills capture the listed frame times
    /// (default `[0]`); motion scenarios capture the listed times or, when none
    /// are listed, every whole second from 0 through the duration.
    var captureTimesS: [Double] {
        if let frameTimesS, !frameTimesS.isEmpty { return frameTimesS }
        guard isMotion else { return [0] }
        return stride(from: 0.0, through: durationS + 1e-9, by: 1.0).map { $0 }
    }

    /// Maps each capture time to the simulation step index after which it is
    /// captured (step 0 = rest pose before any simulation).
    var captureSteps: [(step: Int, timeS: Double)] {
        captureTimesS.map { time in
            let step = min(max(Int((time / timestepS).rounded()), 0), stepCount)
            return (step, time)
        }
    }

    // MARK: Decoding helpers

    private static func int(_ value: JSONValue?, _ name: String, default fallback: Int) throws -> Int {
        guard let value else { return fallback }
        guard let number = value.number, number == number.rounded() else { throw RenderFailure("\(name) must be an integer.") }
        return Int(number)
    }

    private static func float(_ value: JSONValue?, _ name: String, default fallback: Float) throws -> Float {
        guard let value else { return fallback }
        guard let number = value.number else { throw RenderFailure("\(name) must be a number.") }
        return Float(number)
    }

    private static func double(_ value: JSONValue?, _ name: String, default fallback: Double) throws -> Double {
        guard let value else { return fallback }
        guard let number = value.number else { throw RenderFailure("\(name) must be a number.") }
        return number
    }

    private static func floats(_ value: JSONValue, _ name: String, count: Int) throws -> [Float] {
        guard let array = value.array, array.count == count else { throw RenderFailure("\(name) must be an array of \(count) numbers.") }
        return try array.map { element in
            guard let number = element.number else { throw RenderFailure("\(name) must contain only numbers.") }
            return Float(number)
        }
    }

    private static func vec3(_ value: JSONValue?, _ name: String, default fallback: SIMD3<Float>) throws -> SIMD3<Float> {
        guard let value else { return fallback }
        let f = try floats(value, name, count: 3)
        return SIMD3<Float>(f[0], f[1], f[2])
    }

    private static func vec4(_ value: JSONValue?, _ name: String, default fallback: SIMD4<Float>) throws -> SIMD4<Float> {
        guard let value else { return fallback }
        let f = try floats(value, name, count: 4)
        return SIMD4<Float>(f[0], f[1], f[2], f[3])
    }
}
