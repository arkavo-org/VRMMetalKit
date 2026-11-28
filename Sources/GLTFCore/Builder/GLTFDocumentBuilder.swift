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

/// Builder for creating glTF documents programmatically
public final class GLTFDocumentBuilder {

    private var asset: GLTFAsset?
    private var scenes: [GLTFScene] = []
    private var nodes: [GLTFNode] = []
    private var meshes: [GLTFMesh] = []
    private var materials: [GLTFMaterial] = []
    private var textures: [GLTFTexture] = []
    private var images: [GLTFImage] = []
    private var samplers: [GLTFSampler] = []
    private var buffers: [GLTFBuffer] = []
    private var bufferViews: [GLTFBufferView] = []
    private var accessors: [GLTFAccessor] = []
    private var skins: [GLTFSkin] = []
    private var animations: [GLTFAnimation] = []
    private var extensions: [String: Any] = [:]
    private var extras: [String: Any] = [:]
    private var extensionsUsed: [String] = []
    private var extensionsRequired: [String] = []
    private var defaultScene: Int = 0
    private var binaryBufferData: Data?

    /// Creates an empty builder. ``setAsset(_:)`` must be called before ``build()``.
    public init() {}

    // MARK: - Configuration

    /// Sets the document's `asset` block. Required before ``build()``.
    @discardableResult
    public func setAsset(_ asset: GLTFAsset) -> GLTFDocumentBuilder {
        self.asset = asset
        return self
    }

    /// Appends a scene to the document.
    @discardableResult
    public func addScene(_ scene: GLTFScene) -> GLTFDocumentBuilder {
        scenes.append(scene)
        return self
    }

    /// Replaces the node array.
    @discardableResult
    public func setNodes(_ nodes: [GLTFNode]) -> GLTFDocumentBuilder {
        self.nodes = nodes
        return self
    }

    /// Replaces the mesh array.
    @discardableResult
    public func setMeshes(_ meshes: [GLTFMesh]) -> GLTFDocumentBuilder {
        self.meshes = meshes
        return self
    }

    /// Replaces the material array.
    @discardableResult
    public func setMaterials(_ materials: [GLTFMaterial]) -> GLTFDocumentBuilder {
        self.materials = materials
        return self
    }

    /// Replaces the texture array.
    @discardableResult
    public func setTextures(_ textures: [GLTFTexture]) -> GLTFDocumentBuilder {
        self.textures = textures
        return self
    }

    /// Replaces the image array.
    @discardableResult
    public func setImages(_ images: [GLTFImage]) -> GLTFDocumentBuilder {
        self.images = images
        return self
    }

    /// Replaces the sampler array.
    @discardableResult
    public func setSamplers(_ samplers: [GLTFSampler]) -> GLTFDocumentBuilder {
        self.samplers = samplers
        return self
    }

    /// Replaces the buffer array.
    @discardableResult
    public func setBuffers(_ buffers: [GLTFBuffer]) -> GLTFDocumentBuilder {
        self.buffers = buffers
        return self
    }

    /// Replaces the bufferView array.
    @discardableResult
    public func setBufferViews(_ bufferViews: [GLTFBufferView]) -> GLTFDocumentBuilder {
        self.bufferViews = bufferViews
        return self
    }

    /// Replaces the accessor array.
    @discardableResult
    public func setAccessors(_ accessors: [GLTFAccessor]) -> GLTFDocumentBuilder {
        self.accessors = accessors
        return self
    }

    /// Replaces the skin array.
    @discardableResult
    public func setSkins(_ skins: [GLTFSkin]) -> GLTFDocumentBuilder {
        self.skins = skins
        return self
    }

    /// Replaces the animation array.
    @discardableResult
    public func setAnimations(_ animations: [GLTFAnimation]) -> GLTFDocumentBuilder {
        self.animations = animations
        return self
    }

    /// Adds or replaces a top-level glTF extension payload under `name`.
    @discardableResult
    public func addExtension(name: String, data: Any) -> GLTFDocumentBuilder {
        extensions[name] = data
        return self
    }

    /// Sets the document's `extensionsUsed` list.
    @discardableResult
    public func setExtensionsUsed(_ extensions: [String]) -> GLTFDocumentBuilder {
        self.extensionsUsed = extensions
        return self
    }

    /// Sets the document's `extensionsRequired` list.
    @discardableResult
    public func setExtensionsRequired(_ extensions: [String]) -> GLTFDocumentBuilder {
        self.extensionsRequired = extensions
        return self
    }

    /// Sets the document's top-level `extras` dictionary.
    @discardableResult
    public func setExtras(_ extras: [String: Any]) -> GLTFDocumentBuilder {
        self.extras = extras
        return self
    }

    /// Sets the in-memory GLB binary chunk backing buffer index 0.
    @discardableResult
    public func setBinaryBufferData(_ data: Data?) -> GLTFDocumentBuilder {
        self.binaryBufferData = data
        return self
    }

    /// Sets the index of the default scene that consumers should open.
    @discardableResult
    public func setDefaultScene(_ index: Int) -> GLTFDocumentBuilder {
        self.defaultScene = index
        return self
    }

    // MARK: - Build

    /// Assembles the configured fields directly into a ``GLTFDocument`` without JSON serialization.
    ///
    /// - Throws: `BuilderError.missingAsset` when ``setAsset(_:)`` was not called.
    public func build() throws -> GLTFDocument {
        guard let asset = asset else {
            throw BuilderError.missingAsset
        }

        return GLTFDocument(
            asset: asset,
            scene: scenes.isEmpty ? nil : defaultScene,
            scenes: scenes.isEmpty ? nil : scenes,
            nodes: nodes.isEmpty ? nil : nodes,
            meshes: meshes.isEmpty ? nil : meshes,
            materials: materials.isEmpty ? nil : materials,
            textures: textures.isEmpty ? nil : textures,
            images: images.isEmpty ? nil : images,
            samplers: samplers.isEmpty ? nil : samplers,
            buffers: buffers.isEmpty ? nil : buffers,
            bufferViews: bufferViews.isEmpty ? nil : bufferViews,
            accessors: accessors.isEmpty ? nil : accessors,
            skins: skins.isEmpty ? nil : skins,
            animations: animations.isEmpty ? nil : animations,
            extensions: extensions.isEmpty ? nil : extensions,
            extras: extras.isEmpty ? nil : extras,
            extensionsUsed: extensionsUsed.isEmpty ? nil : extensionsUsed,
            extensionsRequired: extensionsRequired.isEmpty ? nil : extensionsRequired,
            binaryBufferData: binaryBufferData
        )
    }

    public enum BuilderError: Error, LocalizedError {
        case missingAsset

        public var errorDescription: String? {
            switch self {
            case .missingAsset:
                return "GLTFDocumentBuilder: setAsset(_:) must be called before build()."
            }
        }
    }
}
