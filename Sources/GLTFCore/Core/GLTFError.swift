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

/// Errors thrown by GLTFCore loaders and the glTF 2.0 parsing/decoding pipeline.
///
/// Cases conform to `LocalizedError` with messages that describe what went
/// wrong, where it happened, a suggested fix, and a link to the relevant
/// glTF spec section. See ``errorDescription`` for the rendered output.
public enum GLTFError: Error {
    /// The GLB container does not conform to the glTF 2.0 binary format.
    case invalidGLBFormat(reason: String, filePath: String?)
    /// JSON parsing of a glTF chunk failed.
    case invalidJSON(context: String, underlyingError: String?, filePath: String?)
    /// The specification version found in the file is not supported by this runtime.
    case unsupportedVersion(version: String, supported: [String], filePath: String?)

    /// A required buffer is missing or shorter than the declared byte length.
    case missingBuffer(bufferIndex: Int, requiredBy: String, expectedSize: Int?, filePath: String?)
    /// An accessor references invalid buffer-view ranges, component types, or counts.
    case invalidAccessor(accessorIndex: Int, reason: String, context: String, filePath: String?)

    /// A texture referenced by a material could not be loaded.
    case missingTexture(textureIndex: Int, materialName: String?, uri: String?, filePath: String?)
    /// A texture's image data is corrupted or in an unsupported format.
    case invalidImageData(textureIndex: Int, reason: String, filePath: String?)

    /// A mesh or primitive is structurally invalid (missing attributes, bad indices, etc.).
    case invalidMesh(meshIndex: Int, primitiveIndex: Int?, reason: String, filePath: String?)
    /// A required vertex attribute (e.g. `POSITION`) is absent on the mesh.
    case missingVertexAttribute(meshIndex: Int, attributeName: String, filePath: String?)

    /// A GPU operation was requested but no Metal device has been assigned.
    case deviceNotSet(context: String)
    /// A file path could not be resolved or read.
    case invalidPath(path: String, reason: String, filePath: String?)

    /// A material has parameters outside valid ranges or references missing resources.
    case invalidMaterial(materialIndex: Int, reason: String, filePath: String?)

    /// The glTF document declares `extensionsRequired` entries that this runtime does not implement.
    case unsupportedRequiredExtension([String])

    /// Loading was cancelled via Swift Concurrency task cancellation.
    case loadingCancelled
}

extension GLTFError: LocalizedError {
    /// Returns a multi-line, LLM-friendly description: what went wrong, where, a suggested fix, and a spec URL.
    public var errorDescription: String? {
        switch self {
        case .invalidGLBFormat(let reason, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            return """
            ❌ Invalid GLB Format

            \(fileInfo)Reason: \(reason)

            Suggestion: Ensure the file is a valid GLB (binary glTF) file. GLB files must start with the magic number 0x46546C67 ('glTF' in ASCII) and have a valid header structure.

            glTF Spec: https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#glb-file-format-specification
            """

        case .invalidJSON(let context, let underlyingError, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            let errorInfo = underlyingError.map { "\nUnderlying error: \($0)" } ?? ""
            return """
            ❌ Invalid JSON Data

            \(fileInfo)Context: \(context)\(errorInfo)

            Suggestion: Check that the JSON structure in your glTF/GLB file is valid and follows the glTF 2.0 specification. Use a JSON validator or glTF validator tool.

            Tools: https://github.khronos.org/glTF-Validator/
            """

        case .unsupportedVersion(let version, let supported, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            let supportedStr = supported.joined(separator: ", ")
            return """
            ❌ Unsupported Version

            \(fileInfo)Version found: \(version)
            Supported versions: \(supportedStr)

            Suggestion: Convert your model to a supported version. Use conversion tools or export from your 3D software with the correct version settings.
            """

        case .missingBuffer(let bufferIndex, let requiredBy, let expectedSize, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            let sizeInfo = expectedSize.map { " (expected size: \($0) bytes)" } ?? ""
            return """
            ❌ Missing Buffer Data

            \(fileInfo)Buffer index: \(bufferIndex)
            Required by: \(requiredBy)\(sizeInfo)

            Suggestion: The buffer data is missing or incomplete. Check that all buffers referenced in the glTF JSON are present in the GLB binary chunk or as external files. Ensure buffer byte lengths match the declared sizes.

            glTF Spec: https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#buffers-and-buffer-views
            """

        case .invalidAccessor(let accessorIndex, let reason, let context, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            return """
            ❌ Invalid Accessor

            \(fileInfo)Accessor index: \(accessorIndex)
            Context: \(context)
            Reason: \(reason)

            Suggestion: Accessors define how to read vertex data from buffers. Check that the accessor's bufferView, componentType, type, and count are valid. Ensure the accessor doesn't read beyond the buffer bounds.

            glTF Spec: https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#accessors
            """

        case .missingTexture(let textureIndex, let materialName, let uri, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            let materialInfo = materialName.map { "Material: '\($0)'\n" } ?? ""
            let uriInfo = uri.map { "URI: '\($0)'\n" } ?? ""
            return """
            ❌ Missing Texture

            \(fileInfo)\(materialInfo)Texture index: \(textureIndex)
            \(uriInfo)
            Suggestion: The texture file is missing or cannot be loaded. Check that:
            • External texture files exist at the specified URI
            • Embedded textures are properly stored in the GLB binary chunk
            • Data URIs are valid base64-encoded images
            • File paths are correct and accessible

            Supported formats: PNG, JPEG, KTX2, Basis Universal
            """

        case .invalidImageData(let textureIndex, let reason, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            return """
            ❌ Invalid Image Data

            \(fileInfo)Texture index: \(textureIndex)
            Reason: \(reason)

            Suggestion: The image data is corrupted or in an unsupported format. Re-export your textures as PNG or JPEG and ensure they're properly embedded or referenced.
            """

        case .invalidMesh(let meshIndex, let primitiveIndex, let reason, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            let primInfo = primitiveIndex.map { ", primitive \($0)" } ?? ""
            return """
            ❌ Invalid Mesh Data

            \(fileInfo)Mesh index: \(meshIndex)\(primInfo)
            Reason: \(reason)

            Suggestion: Check that your mesh has:
            • Valid vertex positions (POSITION attribute)
            • Valid normals (NORMAL attribute)
            • Valid UVs if textures are used (TEXCOORD_0)
            • Valid indices if indexed drawing is used
            • Skinning data (JOINTS_0, WEIGHTS_0) if the mesh is rigged

            glTF Spec: https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#meshes
            """

        case .missingVertexAttribute(let meshIndex, let attributeName, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            return """
            ❌ Missing Vertex Attribute

            \(fileInfo)Mesh index: \(meshIndex)
            Attribute: \(attributeName)

            Suggestion: The mesh is missing the '\(attributeName)' vertex attribute. Common attributes:
            • POSITION (required) - vertex positions
            • NORMAL (recommended) - for lighting
            • TEXCOORD_0 (for textures) - UV coordinates
            • JOINTS_0, WEIGHTS_0 (for skinning) - bone influences

            Ensure your 3D model has this data and it's properly exported.
            """

        case .deviceNotSet(let context):
            return """
            ❌ Metal Device Not Set

            Context: \(context)

            Suggestion: You must set a Metal device before performing GPU operations. Call `model.device = MTLCreateSystemDefaultDevice()` or pass a device during initialization.
            """

        case .invalidPath(let path, let reason, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            return """
            ❌ Invalid File Path

            \(fileInfo)Path: '\(path)'
            Reason: \(reason)

            Suggestion: Check that the file path is correct and accessible. Ensure:
            • The file exists at the specified location
            • You have read permissions
            • The path doesn't contain invalid characters
            • Relative paths are resolved correctly from the base directory
            """

        case .invalidMaterial(let materialIndex, let reason, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            return """
            ❌ Invalid Material

            \(fileInfo)Material index: \(materialIndex)
            Reason: \(reason)

            Suggestion: Check that the material has valid properties:
            • Base color texture references valid texture indices
            • PBR metallic-roughness values are in valid ranges [0, 1]
            • Alpha mode is one of: OPAQUE, MASK, BLEND

            glTF Spec: https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#materials
            """

        case .unsupportedRequiredExtension(let extensions):
            let list = extensions.joined(separator: ", ")
            return """
            ❌ Unsupported Required Extension(s)

            Required extensions not supported by this runtime: \(list)

            Suggestion: This glTF file requires extensions that this runtime does not implement. Check whether a newer version supports these extensions, or export the model without requiring them.

            glTF Spec: https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#specifying-extensions
            """

        case .loadingCancelled:
            return """
            ⚠️ Loading Cancelled

            The model loading was cancelled by the user.

            Suggestion: If this was unexpected, check that:
            • The loading task wasn't explicitly cancelled
            • The parent Task wasn't cancelled
            • No timeout or cancellation token was triggered
            """
        }
    }
}
