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
import Metal

/// Calculates depth bias values for materials to resolve Z-fighting
///
/// Depth bias (polygon offset) pushes fragments toward the camera in depth buffer space,
/// ensuring they pass depth tests against coplanar surfaces. This resolves true Z-fighting
/// between overlapping geometry.
///
/// ## Usage
/// ```swift
/// let calculator = DepthBiasCalculator()
/// let bias = calculator.depthBias(for: "FaceMouth", isOverlay: true)
/// renderEncoder.setDepthBias(bias, slopeScale: 2.0, clamp: 0.1)
/// ```
public struct DepthBiasCalculator {
    
    /// Global scale factor applied to all depth bias values
    public var scale: Float = 1.0
    
    /// Base depth bias values by material category
    private let baseBiasValues: [String: Float] = [
        // Body - minimal bias (base layer)
        "Body_SKIN": 0.005,
        "Body": 0.005,
        
        // Clothing - higher bias to render on top of body
        // Hip/skirt boundary needs clear separation
        "Cloth": 0.015,
        "Clothing": 0.015,
        "Skirt": 0.015,
        "Bottoms": 0.015,
        "Pants": 0.015,
        
        // Base face - slight bias
        "Face_SKIN": 0.01,
        "Face": 0.01,
        "Skin": 0.01,  // Note: Body_SKIN should be checked first
        
        // Face overlays - progressive bias for layering
        "Mouth": 0.02,
        "FaceMouth": 0.02,
        "Lip": 0.02,
        
        "Eyebrow": 0.025,
        "Brow": 0.025,
        
        "Eyelash": 0.03,
        "Eyeline": 0.03,
        
        "Eye": 0.03,
        "EyeIris": 0.03,
        "EyeWhite": 0.03,
        
        // Highlights on top
        "Highlight": 0.04,
        "EyeHighlight": 0.04,
    ]
    
    /// Default bias for unknown materials
    private let defaultBias: Float = 0.01
    
    /// Additional bias for overlay materials
    private let overlayBiasOffset: Float = 0.01
    
    /// Creates a new depth bias calculator
    /// - Parameter scale: Global scale factor for all bias values (default: 1.0)
    public init(scale: Float = 1.0) {
        self.scale = scale
    }
    
    /// Returns the depth bias for a material
    ///
    /// - Parameters:
    ///   - materialName: Name of the material
    ///   - isOverlay: Whether this is an overlay material (renders on top of base)
    /// - Returns: Depth bias value in depth buffer units (positive = toward camera)
    public func depthBias(for materialName: String, isOverlay: Bool) -> Float {
        // Look up base bias for material
        let baseBias = lookupBias(for: materialName)
        
        // Add overlay offset if applicable
        let overlayOffset = isOverlay ? overlayBiasOffset : 0.0
        
        // Apply global scale
        return (baseBias + overlayOffset) * scale
    }
    
    /// Returns the recommended slope scale for depth bias
    ///
    /// Slope scale compensates for surfaces angled away from camera.
    /// Steeper angles need more compensation.
    public var slopeScale: Float { 2.0 }
    
    /// Returns the recommended clamp value for depth bias
    ///
    /// Clamp prevents excessive bias that could cause visual artifacts.
    public var clamp: Float { 0.1 }
    
    /// Sets up depth bias on a render encoder for a material
    ///
    /// - Parameters:
    ///   - encoder: The render command encoder
    ///   - materialName: Name of the material being rendered
    ///   - isOverlay: Whether this is an overlay material
    public func applyDepthBias(
        to encoder: MTLRenderCommandEncoder,
        for materialName: String,
        isOverlay: Bool
    ) {
        let bias = depthBias(for: materialName, isOverlay: isOverlay)
        encoder.setDepthBias(bias, slopeScale: slopeScale, clamp: clamp)
    }
    
    // MARK: - Private Methods
    
    private func lookupBias(for materialName: String) -> Float {
        let lowercased = materialName.lowercased()
        
        // Try exact match first
        if let exactMatch = baseBiasValues[materialName] {
            return exactMatch
        }
        
        // PRIORITY 1: Check for clothing first (before body/skin)
        // Hip/skirt boundary needs clear clothing identification
        if lowercased.contains("cloth") || lowercased.contains("clothing") ||
           lowercased.contains("skirt") || lowercased.contains("bottoms") ||
           lowercased.contains("pants") {
            return baseBiasValues["Cloth"] ?? 0.015
        }
        
        // PRIORITY 2: Check for body materials (before generic skin)
        // Body_SKIN should get body bias, not face skin bias
        if lowercased.contains("body") {
            return baseBiasValues["Body"] ?? 0.005
        }
        
        // PRIORITY 3: Face-specific features
        if lowercased.contains("mouth") || lowercased.contains("lip") {
            return baseBiasValues["Mouth"] ?? defaultBias
        }
        if lowercased.contains("eyebrow") || lowercased.contains("brow") {
            return baseBiasValues["Eyebrow"] ?? defaultBias
        }
        if lowercased.contains("eye") {
            return baseBiasValues["Eye"] ?? defaultBias
        }
        if lowercased.contains("face") {
            return baseBiasValues["Face"] ?? defaultBias
        }
        
        // PRIORITY 4: Generic skin (only if not body or face)
        if lowercased.contains("skin") {
            return baseBiasValues["Skin"] ?? defaultBias
        }
        
        if lowercased.contains("highlight") {
            return baseBiasValues["Highlight"] ?? defaultBias
        }
        
        // Try partial matches from baseBiasValues
        for (key, value) in baseBiasValues {
            if lowercased.contains(key.lowercased()) {
                return value
            }
        }
        
        return defaultBias
    }
}

// MARK: - Documentation

/*
 ## Depth Bias Strategy
 
 ### Problem
 True Z-fighting occurs when two surfaces occupy the same depth (coplanar).
 The depth buffer has limited precision, so fragments at identical world-space
 depth may have slightly different depth buffer values due to:
 - Floating-point rounding in vertex transformation
 - Different interpolation precision
 - Numerical differences in matrix math
 
 ### Solution
 Depth bias pushes fragments toward the camera (lower depth value) so they
 consistently pass the depth test against coplanar surfaces behind them.
 
 ### Bias Values
 
 | Material Category | Base Bias | Overlay Offset | Total |
 |-------------------|-----------|----------------|-------|
 | Body/Clothing | 0.005 | - | 0.005 |
 | Face (base) | 0.010 | - | 0.010 |
 | Mouth | 0.020 | +0.010 | 0.030 |
 | Eyebrow | 0.025 | +0.010 | 0.035 |
 | Eye | 0.030 | +0.010 | 0.040 |
 | Highlight | 0.040 | +0.010 | 0.050 |
 
 ### Metal API
 ```swift
 encoder.setDepthBias(depthBias, slopeScale: 2.0, clamp: 0.1)
 ```
 
 - `depthBias`: Constant offset in depth buffer units
 - `slopeScale`: Multiplier for surface slope (steeper = more bias)
 - `clamp`: Maximum bias to prevent artifacts
 
 ### Best Practices
 1. Use progressive bias for layered materials (mouth over face over body)
 2. Keep bias values small to avoid visible depth artifacts
 3. Tune `slopeScale` for your typical geometry curvature
 4. Test with camera at various angles to surface
 */
