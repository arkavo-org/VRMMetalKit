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

/// MToon direct-light factor targets. MToon 1.0 shades with
/// linearstep(−1 + toony, 1 − toony, NdotL + shift), so a requested shadow end
/// and terminator width solve to toony = 1 − width/2 and
/// shift = toony − 1 − shadowEnd. Illegal factors are rejected, never clamped.
public struct MaterialShadingSolution: Codable, Hashable, Sendable {
    public var shadingToonyFactor: Double
    public var shadingShiftFactor: Double
    public var shadowEnd: Double
    public var terminatorWidth: Double
    public var litStart: Double

    public var json: JSONValue {
        ["shadingToonyFactor": .number(shadingToonyFactor), "shadingShiftFactor": .number(shadingShiftFactor)]
    }
}

public enum MaterialShading {
    public static let toonyRange = 0.0...1.0
    public static let shiftRange = -1.0...1.0
    public static let widthRange = 0.0...2.0
    public static let shadowEndRange = -1.0...1.0

    static func rounded(_ value: Double) -> Double { (value * 1e6).rounded() / 1e6 }

    public static func solve(shadowEnd: Double, terminatorWidth: Double) throws -> MaterialShadingSolution {
        guard shadowEnd.isFinite, terminatorWidth.isFinite else {
            throw AuthorError(code: .invalidRequest, path: "/shadowEnd", message: "shadowEnd and terminatorWidth must be finite.", suggestedCommands: ["describe material shading"])
        }
        guard widthRange.contains(terminatorWidth) else {
            throw AuthorError(code: .invalidRequest, path: "/terminatorWidth", observed: .number(terminatorWidth), required: [0, 2],
                              message: "terminatorWidth must be within [0, 2].", suggestedCommands: ["describe material shading"])
        }
        guard shadowEndRange.contains(shadowEnd) else {
            throw AuthorError(code: .invalidRequest, path: "/shadowEnd", observed: .number(shadowEnd), required: [-1, 1],
                              message: "shadowEnd must be within [-1, 1].", suggestedCommands: ["describe material shading"])
        }
        let toony = rounded(1 - terminatorWidth / 2)
        let shift = rounded(toony - 1 - shadowEnd)
        guard toonyRange.contains(toony) else {
            throw AuthorError(code: .validationFailed, path: "/mtoon/shadingToonyFactor", observed: .number(toony), required: [0, 1],
                              message: "Derived shadingToonyFactor \(toony) is outside [0, 1]; choose a terminatorWidth within [0, 2].",
                              suggestedCommands: ["material shading"])
        }
        guard shiftRange.contains(shift) else {
            throw AuthorError(code: .validationFailed, path: "/mtoon/shadingShiftFactor", observed: .number(shift), required: [-1, 1],
                              message: "Derived shadingShiftFactor \(shift) is outside [-1, 1] for shadowEnd \(shadowEnd) and terminatorWidth \(terminatorWidth); "
                                + "legal shadowEnd for this width is [\(rounded(toony - 2)), \(rounded(toony))] ∩ [-1, 1].",
                              suggestedCommands: ["material shading"])
        }
        return MaterialShadingSolution(shadingToonyFactor: toony, shadingShiftFactor: shift, shadowEnd: rounded(-1 + toony - shift),
                                       terminatorWidth: rounded(2 * (1 - toony)), litStart: rounded(1 - toony - shift))
    }

    /// Inverse: the shadow end / width a material's factors currently produce.
    public static func derive(toony: Double, shift: Double) -> MaterialShadingSolution {
        MaterialShadingSolution(shadingToonyFactor: toony, shadingShiftFactor: shift, shadowEnd: rounded(-1 + toony - shift),
                                terminatorWidth: rounded(2 * (1 - toony)), litStart: rounded(1 - toony - shift))
    }
}
