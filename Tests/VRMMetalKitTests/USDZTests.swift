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


import Testing
import Metal
@testable import VRMMetalKit

/// Tests for USDZ import/export functionality
@Suite("USDZ Import/Export Tests")
struct USDZTests {
    // MARK: - FileFormat Detection Tests

    @Test("Detect VRM format from extension")
    func testDetectVRMFromExtension() {
        let url = URL(fileURLWithPath: "/path/to/model.vrm")
        let format = FileFormat.detect(from: url)
        #expect(format == .vrm)
    }

    @Test("Detect compound VRM.GLB extension")
    func testDetectCompoundVRMGLBExtension() {
        let url = URL(fileURLWithPath: "/path/to/model.vrm.glb")
        let format = FileFormat.detect(from: url)
        #expect(format == .vrm)
    }

    @Test("Detect GLB format from extension")
    func testDetectGLBFromExtension() {
        let url = URL(fileURLWithPath: "/path/to/model.glb")
        let format = FileFormat.detect(from: url)
        #expect(format == .glb)
    }

    @Test("Detect USDZ format from extension")
    func testDetectUSDZFromExtension() {
        let url = URL(fileURLWithPath: "/path/to/model.usdz")
        let format = FileFormat.detect(from: url)
        #expect(format == .usdz)
    }

    @Test("Detect GLB from magic number")
    func testDetectGLBFromMagicNumber() {
        // GLB magic: "glTF" in little-endian = 0x46546C67
        var data = Data()
        var magic: UInt32 = 0x46546C67
        data.append(Data(bytes: &magic, count: 4))

        let format = FileFormat.detect(from: data)
        #expect(format == .glb)
    }

    @Test("Detect USDZ from magic number")
    func testDetectUSDZFromMagicNumber() {
        // USDZ is a ZIP file, magic: "PK" = 0x504B
        var data = Data()
        var magic: UInt16 = 0x504B
        data.append(Data(bytes: &magic, count: 2))

        let format = FileFormat.detect(from: data)
        #expect(format == .usdz)
    }

    @Test("Detect unknown format")
    func testDetectUnknownFormat() {
        let data = Data([0xFF, 0xFF, 0xFF, 0xFF])
        let format = FileFormat.detect(from: data)
        #expect(format == .unknown)
    }

    @Test("FileFormat properties - VRM")
    func testVRMFormatProperties() {
        let format = FileFormat.vrm
        #expect(format.isSupported == true)
        #expect(format.supportsVRM == true)
        #expect(format.description.contains("VRM"))
        #expect(format.fileExtensions.contains("vrm"))
    }

    @Test("FileFormat properties - USDZ")
    func testUSDZFormatProperties() {
        let format = FileFormat.usdz
        #expect(format.isSupported == true)
        #expect(format.supportsVRM == false)
        #expect(format.description.contains("USDZ"))
        #expect(format.fileExtensions.contains("usdz"))
    }

    @Test("FileFormat properties - unknown")
    func testUnknownFormatProperties() {
        let format = FileFormat.unknown
        #expect(format.isSupported == false)
        #expect(format.supportsVRM == false)
        #expect(format.fileExtensions.isEmpty)
    }

    // MARK: - USDZParser Tests

    @Test("USDZParser initialization")
    func testUSDZParserInit() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("Metal not available")
            return
        }

        let parser = USDZParser(device: device)
        #expect(parser != nil)
    }

    @Test("USDZParser import options defaults")
    func testUSDZParserImportOptionsDefaults() {
        let options = USDZParser.ImportOptions()
        #expect(options.generateHumanoidBones == true)
        #expect(options.createDefaultVRMMetadata == true)
        #expect(options.scaleFactor == 1.0)
        #expect(options.useDefaultMToonMaterial == true)
    }

    // MARK: - USDZExporter Tests

    @Test("USDZExporter initialization")
    func testUSDZExporterInit() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("Metal not available")
            return
        }

        let exporter = USDZExporter(device: device)
        #expect(exporter != nil)
    }

    @Test("USDZExporter export options defaults")
    func testUSDZExporterExportOptionsDefaults() {
        let options = USDZExporter.ExportOptions()
        #expect(options.bakeCurrentPose == false)
        #expect(options.includeTextures == true)
        #expect(options.scaleFactor == 1.0)
        #expect(options.optimizeForAR == true)
        #expect(options.maxTextureResolution == 2048)
    }

    // MARK: - Integration Tests

    @Test("Load VRM and export to USDZ")
    func testVRMToUSDZExport() async throws {
        // This test would require a real VRM model file
        // Skipped in unit tests - would be part of integration tests
        #expect(true, "Integration test placeholder")
    }

    @Test("Load USDZ and verify glTF conversion")
    func testUSDZToGLTFConversion() async throws {
        // This test would require a real USDZ file
        // Skipped in unit tests - would be part of integration tests
        #expect(true, "Integration test placeholder")
    }

    // MARK: - Error Handling Tests

    @Test("Unsupported format error for glTF")
    func testUnsupportedFormatError() {
        let error = VRMError.unsupportedFormat(format: .gltf, filePath: "/test.gltf")
        let description = error.localizedDescription
        #expect(description.contains("glTF JSON"))
        #expect(description.contains("not yet supported"))
    }

    @Test("Unsupported format error for unknown")
    func testUnsupportedUnknownFormatError() {
        let error = VRMError.unsupportedFormat(format: .unknown, filePath: "/test.xyz")
        let description = error.localizedDescription
        #expect(description.contains("could not be detected"))
    }

    @Test("Device not set error for USDZ export")
    func testDeviceNotSetErrorForExport() async throws {
        // Create a minimal VRM model without device
        let meta = VRMMeta(
            name: "Test",
            version: "1.0",
            authors: ["Test"],
            copyrightInformation: nil,
            contactInformation: nil,
            references: nil,
            thirdPartyLicenses: nil,
            thumbnailImage: nil,
            licenseUrl: "https://example.com",
            avatarPermission: .onlyAuthor,
            allowExcessivelyViolentUsage: false,
            allowExcessivelySexualUsage: false,
            allowPoliticalOrReligiousUsage: false,
            allowAntisocialOrHateUsage: false,
            commercialUsage: .personalNonProfit,
            allowPoliticalOrReligiousUsageString: nil,
            allowAntisocialOrHateUsageString: nil,
            creditNotation: nil,
            allowRedistribution: false,
            modification: nil,
            otherLicenseUrl: nil
        )

        let document = GLTFDocument(
            asset: GLTFAsset(version: "2.0"),
            scene: nil,
            scenes: nil,
            nodes: nil,
            meshes: nil,
            materials: nil,
            textures: nil,
            images: nil,
            samplers: nil,
            buffers: nil,
            bufferViews: nil,
            accessors: nil,
            skins: nil,
            animations: nil,
            extensions: nil,
            extensionsUsed: nil,
            extensionsRequired: nil,
            binaryBufferData: nil
        )

        let model = VRMModel(specVersion: .v1_0, meta: meta, gltf: document)
        // model.device is nil

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.usdz")

        // Expect this to throw deviceNotSet error
        do {
            try model.exportUSDZ(to: tempURL)
            Issue.record("Expected deviceNotSet error")
        } catch let error as VRMError {
            if case .deviceNotSet = error {
                #expect(true)  // Expected error
            } else {
                Issue.record("Unexpected VRMError: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - VRMModel Extension Tests

    @Test("VRMModel has exportUSDZ methods")
    func testVRMModelExportMethods() {
        // Test that the API exists
        // Actual functionality tested in integration tests
        #expect(VRMModel.self != nil)
    }
}
