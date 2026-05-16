//
// Copyright 2025 Arkavo
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

/// Orthographic camera utilities for 2.5D VRM rendering
/// Provides projection matrices optimized for visual novel/dialogue scenes
public struct OrthographicCamera {

    // MARK: - Camera Presets

    /// Standard camera framing presets for VRM characters
    public enum Preset {
        /// Tight VTuber-style framing (shoulders and up).
        case bust
        /// Upper body framing (waist and up).
        case medium
        /// Full character visible.
        case fullBody
        /// Custom view-frustum height in world units.
        case custom(height: Float)

        /// Height in world units (assuming standard 1.6-1.8m VRM)
        public var height: Float {
            switch self {
            case .bust:
                return 0.6  // ~30% of character height
            case .medium:
                return 1.2  // ~70% of character height
            case .fullBody:
                return 2.0  // 110% of character height (with headroom)
            case .custom(let h):
                return h
            }
        }

        /// Descriptive name for debugging
        public var name: String {
            switch self {
            case .bust: return "Bust"
            case .medium: return "Medium"
            case .fullBody: return "Full Body"
            case .custom(let h): return "Custom(\(h)m)"
            }
        }
    }

    // MARK: - Projection Matrix Construction

    /// Create orthographic projection matrix from preset
    /// - Parameters:
    ///   - preset: Camera framing preset
    ///   - aspectRatio: Viewport width / height
    ///   - near: Near clipping plane (default: 0.1)
    ///   - far: Far clipping plane (default: 100.0)
    /// - Returns: Orthographic projection matrix
    public static func makeProjection(
        preset: Preset,
        aspectRatio: Float,
        near: Float = 0.1,
        far: Float = 100.0
    ) -> simd_float4x4 {
        return makeProjection(
            height: preset.height,
            aspectRatio: aspectRatio,
            near: near,
            far: far
        )
    }

    /// Create orthographic projection matrix with explicit height
    /// - Parameters:
    ///   - height: Height of the view frustum in world units
    ///   - aspectRatio: Viewport width / height
    ///   - near: Near clipping plane
    ///   - far: Far clipping plane
    /// - Returns: Orthographic projection matrix
    public static func makeProjection(
        height: Float,
        aspectRatio: Float,
        near: Float = 0.1,
        far: Float = 100.0
    ) -> simd_float4x4 {
        let halfHeight = height / 2.0
        let halfWidth = halfHeight * aspectRatio

        return makeOrthographic(
            left: -halfWidth,
            right: halfWidth,
            bottom: -halfHeight,
            top: halfHeight,
            near: near,
            far: far
        )
    }

    /// Create orthographic projection matrix from explicit bounds
    /// - Parameters:
    ///   - left: Left clipping plane
    ///   - right: Right clipping plane
    ///   - bottom: Bottom clipping plane
    ///   - top: Top clipping plane
    ///   - near: Near clipping plane
    ///   - far: Far clipping plane
    /// - Returns: Orthographic projection matrix
    public static func makeOrthographic(
        left: Float,
        right: Float,
        bottom: Float,
        top: Float,
        near: Float,
        far: Float
    ) -> simd_float4x4 {
        let rml = right - left
        let tmb = top - bottom
        let fmn = far - near

        // OpenGL-style orthographic projection (Metal uses same convention)
        return simd_float4x4(columns: (
            SIMD4<Float>(2.0 / rml, 0, 0, 0),
            SIMD4<Float>(0, 2.0 / tmb, 0, 0),
            SIMD4<Float>(0, 0, -1.0 / fmn, 0),
            SIMD4<Float>(-(right + left) / rml, -(top + bottom) / tmb, -near / fmn, 1)
        ))
    }

    // MARK: - View Matrix Construction

    /// Create view matrix for orthographic 2.5D rendering
    /// Positions camera to center character in frame
    /// - Parameters:
    ///   - characterPosition: World position of character center (usually origin)
    ///   - distance: Distance from character (default: 5.0 units)
    ///   - offset: Optional vertical offset for centering (default: 0)
    /// - Returns: View matrix looking at character
    public static func makeViewMatrix(
        characterPosition: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
        distance: Float = 5.0,
        offset: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    ) -> simd_float4x4 {
        // Camera position: in front of character along +Z axis
        let cameraPosition = characterPosition + SIMD3<Float>(0, 0, distance) + offset

        // Look at character
        let target = characterPosition
        let up = SIMD3<Float>(0, 1, 0)  // Y-up

        return makeLookAt(eye: cameraPosition, target: target, up: up)
    }

    /// Create look-at view matrix
    /// - Parameters:
    ///   - eye: Camera position
    ///   - target: Point camera is looking at
    ///   - up: Up vector (usually (0, 1, 0))
    /// - Returns: View matrix
    public static func makeLookAt(
        eye: SIMD3<Float>,
        target: SIMD3<Float>,
        up: SIMD3<Float>
    ) -> simd_float4x4 {
        // Calculate basis vectors
        let zAxis = normalize(eye - target)  // Forward (camera looks along -Z)
        let xAxis = normalize(cross(up, zAxis))  // Right
        let yAxis = cross(zAxis, xAxis)  // Up

        // Build view matrix
        return simd_float4x4(columns: (
            SIMD4<Float>(xAxis.x, yAxis.x, zAxis.x, 0),
            SIMD4<Float>(xAxis.y, yAxis.y, zAxis.y, 0),
            SIMD4<Float>(xAxis.z, yAxis.z, zAxis.z, 0),
            SIMD4<Float>(-dot(xAxis, eye), -dot(yAxis, eye), -dot(zAxis, eye), 1)
        ))
    }

    // MARK: - Camera Configuration

    /// Complete camera configuration for 2.5D rendering
    public struct Configuration {
        /// Framing preset that drives projection-matrix height.
        public var preset: Preset
        /// Viewport aspect ratio (width / height).
        public var aspectRatio: Float
        /// Near clipping plane in world units.
        public var nearPlane: Float
        /// Far clipping plane in world units.
        public var farPlane: Float
        /// World-space position of the character the camera frames.
        public var characterPosition: SIMD3<Float>
        /// Camera distance along +Z from `characterPosition`.
        public var cameraDistance: Float
        /// Additional camera offset applied on top of the character-relative position.
        public var offset: SIMD3<Float>

        /// Creates a camera configuration with sensible defaults for 2.5D framing.
        public init(
            preset: Preset = .medium,
            aspectRatio: Float = 16.0 / 9.0,
            nearPlane: Float = 0.1,
            farPlane: Float = 100.0,
            characterPosition: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
            cameraDistance: Float = 5.0,
            offset: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
        ) {
            self.preset = preset
            self.aspectRatio = aspectRatio
            self.nearPlane = nearPlane
            self.farPlane = farPlane
            self.characterPosition = characterPosition
            self.cameraDistance = cameraDistance
            self.offset = offset
        }

        /// Generate projection matrix from configuration
        public var projectionMatrix: simd_float4x4 {
            return OrthographicCamera.makeProjection(
                preset: preset,
                aspectRatio: aspectRatio,
                near: nearPlane,
                far: farPlane
            )
        }

        /// Generate view matrix from configuration
        public var viewMatrix: simd_float4x4 {
            return OrthographicCamera.makeViewMatrix(
                characterPosition: characterPosition,
                distance: cameraDistance,
                offset: offset
            )
        }
    }

}
