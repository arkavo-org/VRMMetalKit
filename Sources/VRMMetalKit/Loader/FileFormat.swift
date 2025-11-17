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

/// Supported 3D file formats for VRMMetalKit
public enum FileFormat: String, Sendable {
    /// VRM 1.0/0.0 model (GLB with VRM extensions)
    case vrm = "vrm"

    /// Generic GLB (binary glTF) file
    case glb = "glb"

    /// glTF JSON file (with external resources)
    case gltf = "gltf"

    /// USDZ (Universal Scene Description zip archive)
    case usdz = "usdz"

    /// Unknown or unsupported format
    case unknown = "unknown"

    // MARK: - Magic Numbers

    /// GLB magic number: "glTF" in little-endian (0x46546C67)
    private static let glbMagic: UInt32 = 0x46546C67

    /// USDZ is a zip file, magic number: "PK" (0x504B)
    private static let zipMagic: UInt16 = 0x504B

    // MARK: - Detection

    /// Detect file format from URL extension
    /// - Parameter url: File URL to analyze
    /// - Returns: Detected file format
    public static func detect(from url: URL) -> FileFormat {
        let ext = url.pathExtension.lowercased()

        // Handle compound extensions like .vrm.glb
        let fullPath = url.lastPathComponent.lowercased()
        if fullPath.hasSuffix(".vrm.glb") {
            return .vrm
        }

        return FileFormat(rawValue: ext) ?? .unknown
    }

    /// Detect file format from binary data by analyzing magic numbers
    /// - Parameter data: Binary data to analyze
    /// - Returns: Detected file format, or .unknown if cannot be determined
    public static func detect(from data: Data) -> FileFormat {
        guard data.count >= 4 else {
            return .unknown
        }

        // Check GLB magic number (VRM/GLB both use GLB container)
        let magic32 = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        if magic32 == glbMagic {
            // Could be VRM or GLB - need to check for VRM extension
            // Return GLB here, caller can distinguish by checking extensions
            return .glb
        }

        // Check ZIP magic number (USDZ)
        let magic16 = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt16.self) }
        if magic16 == zipMagic {
            return .usdz
        }

        // Check if it's JSON (glTF)
        if let firstChar = data.first, firstChar == UInt8(ascii: "{") {
            return .gltf
        }

        return .unknown
    }

    /// Detect file format using both URL and data
    /// - Parameters:
    ///   - url: File URL
    ///   - data: Binary data
    /// - Returns: Best guess of file format (prefers magic number over extension)
    public static func detect(from url: URL, data: Data) -> FileFormat {
        // Magic number is more reliable than extension
        let dataFormat = detect(from: data)
        if dataFormat != .unknown {
            return dataFormat
        }

        // Fall back to extension
        return detect(from: url)
    }

    // MARK: - Format Properties

    /// Whether this format is supported for loading
    public var isSupported: Bool {
        switch self {
        case .vrm, .glb, .usdz:
            return true
        case .gltf:
            return false // Not yet implemented
        case .unknown:
            return false
        }
    }

    /// Whether this format supports VRM extensions
    public var supportsVRM: Bool {
        switch self {
        case .vrm, .glb:
            return true
        case .gltf, .usdz, .unknown:
            return false
        }
    }

    /// Human-readable format description
    public var description: String {
        switch self {
        case .vrm:
            return "VRM Model (GLB with VRM extensions)"
        case .glb:
            return "Binary glTF (GLB)"
        case .gltf:
            return "glTF JSON (with external resources)"
        case .usdz:
            return "Universal Scene Description (USDZ)"
        case .unknown:
            return "Unknown format"
        }
    }

    /// Recommended file extensions
    public var fileExtensions: [String] {
        switch self {
        case .vrm:
            return ["vrm", "vrm.glb"]
        case .glb:
            return ["glb"]
        case .gltf:
            return ["gltf"]
        case .usdz:
            return ["usdz"]
        case .unknown:
            return []
        }
    }
}

// MARK: - Error Extension

extension VRMError {
    /// Unsupported file format error
    static func unsupportedFormat(format: FileFormat, filePath: String?) -> VRMError {
        let suggestion: String
        switch format {
        case .gltf:
            suggestion = "glTF JSON files are not yet supported. Please use GLB (binary glTF) or VRM format instead."
        case .unknown:
            suggestion = "The file format could not be detected. Supported formats: VRM (.vrm, .vrm.glb), GLB (.glb), USDZ (.usdz)"
        default:
            suggestion = "This format is recognized but not supported. Supported formats: VRM, GLB, USDZ"
        }

        return .invalidGLBFormat(
            reason: "Unsupported file format: \(format.description)",
            filePath: filePath
        )
    }
}
