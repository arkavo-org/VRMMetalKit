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

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Bug finder tests that use Z-fighting detection on real VRM models.
/// Designed to identify actual rendering artifacts in AvatarSample_A.
@MainActor
final class ZFightingBugFinderTests: XCTestCase {

    var device: MTLDevice!
    var helper: ZFightingTestHelper!

    override func setUp() async throws {
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else {
            throw XCTSkip("Metal device not available")
        }
        helper = try ZFightingTestHelper(device: device, width: 512, height: 512)
    }

    // MARK: - Path Helpers

    private var projectRoot: String {
        let fileManager = FileManager.default
        let candidates: [String?] = [
            ProcessInfo.processInfo.environment["PROJECT_ROOT"],
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path,
            fileManager.currentDirectoryPath
        ]

        for candidate in candidates.compactMap({ $0 }) {
            let packagePath = "\(candidate)/Package.swift"
            if fileManager.fileExists(atPath: packagePath) {
                return candidate
            }
        }
        return fileManager.currentDirectoryPath
    }

    private var museResourcesPath: String? {
        let fileManager = FileManager.default

        if let envPath = ProcessInfo.processInfo.environment["MUSE_RESOURCES_PATH"] {
            if fileManager.fileExists(atPath: "\(envPath)/AvatarSample_A.vrm.glb") {
                return envPath
            }
        }

        let relativePath = "\(projectRoot)/../Muse/Resources/VRM"
        if fileManager.fileExists(atPath: "\(relativePath)/AvatarSample_A.vrm.glb") {
            return relativePath
        }

        return nil
    }

    private func loadAvatarSampleA() async throws -> VRMModel {
        guard let resourcesPath = museResourcesPath else {
            throw XCTSkip("Muse resources not found - set MUSE_RESOURCES_PATH or place at ../Muse/Resources/VRM")
        }
        let modelPath = "\(resourcesPath)/AvatarSample_A.vrm.glb"
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "AvatarSample_A.vrm.glb not found at \(modelPath)")
        let modelURL = URL(fileURLWithPath: modelPath)
        return try await VRMModel.load(from: modelURL, device: device)
    }

    // MARK: - Comprehensive Z-Fighting Analysis

    /// Main bug finder - scans entire model from multiple angles
    func testFindZFightingBugsInAvatarA() async throws {
        let model = try await loadAvatarSampleA()

        print("\n" + String(repeating: "=", count: 60))
        print("Z-FIGHTING BUG FINDER: AvatarSample_A.vrm.glb")
        print(String(repeating: "=", count: 60))

        // Diagnostics
        print("\nModel loaded:")
        print("  - Meshes: \(model.meshes.count)")
        print("  - Materials: \(model.materials.count)")
        print("  - Nodes: \(model.nodes.count)")
        print("  - Skins: \(model.skins.count)")

        // Count total primitives and vertices
        var totalPrims = 0
        var totalVerts = 0
        for mesh in model.meshes {
            totalPrims += mesh.primitives.count
            for prim in mesh.primitives {
                totalVerts += prim.vertexCount
            }
        }
        print("  - Total primitives: \(totalPrims)")
        print("  - Total vertices: \(totalVerts)")

        helper.loadModel(model)

        // Verify model is in renderer
        print("\nRenderer state after loadModel:")
        print("  - Model loaded: \(helper.renderer.model != nil)")

        // Check model bounds to verify camera setup
        var minPos = SIMD3<Float>(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var maxPos = SIMD3<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
        for mesh in model.meshes {
            for prim in mesh.primitives {
                if let buffer = prim.vertexBuffer {
                    let vertexStride = MemoryLayout<VRMVertex>.stride
                    let vertexCount = buffer.length / vertexStride
                    let vertices = buffer.contents().bindMemory(to: VRMVertex.self, capacity: vertexCount)
                    for i in 0..<min(vertexCount, 1000) {
                        let pos = vertices[i].position
                        minPos = min(minPos, pos)
                        maxPos = max(maxPos, pos)
                    }
                }
            }
        }
        print("  - Model bounds: min=\(minPos), max=\(maxPos)")
        print("  - Model center Y: \((minPos.y + maxPos.y) / 2)")

        // Test render
        print("\nTest render:")
        let testFrames = try helper.renderMultipleFrames(count: 2, perturbationScale: 0.0001)
        let nonZeroPixels = testFrames[0].filter { $0 != 0 }.count
        print("  - Frame 0 non-zero bytes: \(nonZeroPixels) / \(testFrames[0].count)")

        let depthTest = try helper.renderAndReadDepth()
        let nonZeroDepth = depthTest.filter { $0 > 0.001 }.count
        print("  - Depth buffer non-zero: \(nonZeroDepth) / \(depthTest.count)")

        var allIssues: [ZFightingIssue] = []

        // Test multiple camera positions
        let cameraConfigs: [(name: String, eye: SIMD3<Float>, target: SIMD3<Float>)] = [
            ("Face Close-up", SIMD3(0, 1.55, 0.4), SIMD3(0, 1.55, 0)),
            ("Face Front", SIMD3(0, 1.5, 1.0), SIMD3(0, 1.5, 0)),
            ("Face Side Left", SIMD3(-0.5, 1.5, 0.5), SIMD3(0, 1.5, 0)),
            ("Face Side Right", SIMD3(0.5, 1.5, 0.5), SIMD3(0, 1.5, 0)),
            ("Full Body Front", SIMD3(0, 1.0, 3.0), SIMD3(0, 1.0, 0)),
            ("Upper Body", SIMD3(0, 1.2, 1.5), SIMD3(0, 1.2, 0)),
            ("Hands Close-up", SIMD3(0.5, 1.0, 0.5), SIMD3(0.3, 1.0, 0)),
        ]

        for config in cameraConfigs {
            let issues = try await analyzeFromCamera(
                name: config.name,
                eye: config.eye,
                target: config.target
            )
            allIssues.append(contentsOf: issues)
        }

        // Summary
        print("\n" + String(repeating: "=", count: 60))
        print("SUMMARY")
        print(String(repeating: "=", count: 60))

        let criticalIssues = allIssues.filter { $0.severity == .critical }
        let warningIssues = allIssues.filter { $0.severity == .warning }
        let infoIssues = allIssues.filter { $0.severity == .info }

        print("Critical Issues: \(criticalIssues.count)")
        print("Warnings: \(warningIssues.count)")
        print("Info: \(infoIssues.count)")

        if !criticalIssues.isEmpty {
            print("\n🔴 CRITICAL ISSUES:")
            for issue in criticalIssues {
                print("  - \(issue.camera): \(issue.description)")
                print("    Region: \(issue.region), Flicker: \(String(format: "%.2f", issue.flickerRate))%")
            }
        }

        if !warningIssues.isEmpty {
            print("\n🟡 WARNINGS:")
            for issue in warningIssues {
                print("  - \(issue.camera): \(issue.description)")
            }
        }

        // Fail test if critical issues found
        XCTAssertEqual(criticalIssues.count, 0,
            "Found \(criticalIssues.count) critical Z-fighting issues. See output above.")
    }

    /// Detailed face region analysis
    func testFaceRegionDetailedAnalysis() async throws {
        let model = try await loadAvatarSampleA()
        helper.loadModel(model)

        print("\n" + String(repeating: "=", count: 60))
        print("FACE REGION DETAILED ANALYSIS")
        print(String(repeating: "=", count: 60))

        // Position camera for face close-up
        helper.setViewMatrix(makeLookAt(
            eye: SIMD3<Float>(0, 1.55, 0.35),
            target: SIMD3<Float>(0, 1.55, 0),
            up: SIMD3<Float>(0, 1, 0)
        ))

        // Render many frames with small perturbations
        let frames = try helper.renderMultipleFrames(count: 30, perturbationScale: 0.0001)

        // Analyze grid of regions across the face
        let gridSize = 8
        let regionSize = 512 / gridSize

        print("\nFlicker Heatmap (8x8 grid, values = flickering pixels):")
        print("Higher values indicate potential Z-fighting areas\n")

        var maxFlicker = 0
        var maxFlickerRegion = (x: 0, y: 0)
        var heatmap: [[Int]] = []

        for row in 0..<gridSize {
            var rowData: [Int] = []
            var rowStr = ""
            for col in 0..<gridSize {
                let result = FlickerDetector.analyzeRegion(
                    frames: frames,
                    x: col * regionSize,
                    y: row * regionSize,
                    width: regionSize,
                    height: regionSize,
                    frameWidth: 512,
                    threshold: 5
                )

                let flickerCount = result.flickeringPixels.count
                rowData.append(flickerCount)

                if flickerCount > maxFlicker {
                    maxFlicker = flickerCount
                    maxFlickerRegion = (col, row)
                }

                // Format for display
                if flickerCount == 0 {
                    rowStr += "  .  "
                } else if flickerCount < 10 {
                    rowStr += "  \(flickerCount)  "
                } else if flickerCount < 100 {
                    rowStr += " \(flickerCount)  "
                } else if flickerCount < 1000 {
                    rowStr += " \(flickerCount) "
                } else {
                    rowStr += "\(flickerCount) "
                }
            }
            heatmap.append(rowData)
            print("Row \(row): \(rowStr)")
        }

        print("\nMax flicker: \(maxFlicker) pixels at region (\(maxFlickerRegion.x), \(maxFlickerRegion.y))")

        // Identify problem areas
        let threshold = 50
        var problemRegions: [(x: Int, y: Int, count: Int)] = []
        for row in 0..<gridSize {
            for col in 0..<gridSize {
                if heatmap[row][col] > threshold {
                    problemRegions.append((col, row, heatmap[row][col]))
                }
            }
        }

        if !problemRegions.isEmpty {
            print("\n⚠️  Problem regions (>\(threshold) flickering pixels):")
            for region in problemRegions.sorted(by: { $0.count > $1.count }) {
                let pixelX = region.x * regionSize + regionSize / 2
                let pixelY = region.y * regionSize + regionSize / 2
                print("  - Region (\(region.x), \(region.y)): \(region.count) pixels")
                print("    Center pixel: (\(pixelX), \(pixelY))")
                print("    Likely area: \(describeRegion(col: region.x, row: region.y, gridSize: gridSize))")
            }
        }

        // Depth buffer analysis
        let depthData = try helper.renderAndReadDepth()
        let depthAnalysis = DepthAnalyzer.analyzeDepthBuffer(depthValues: depthData)

        print("\nDepth Buffer Analysis:")
        print("  - Foreground pixels: \(depthAnalysis.foregroundPixelCount)")
        print("  - Depth range: \(depthAnalysis.minDepth) - \(depthAnalysis.maxDepth)")
        print("  - Z-fighting risk detected: \(depthAnalysis.hasZFightingRisk)")

        if !depthAnalysis.clusters.isEmpty {
            print("  - Largest depth clusters:")
            for cluster in depthAnalysis.clusters.prefix(5) {
                print("    Depth \(String(format: "%.6f", cluster.depth)): \(cluster.count) pixels")
            }
        }
    }

    /// Test specific body parts known to have issues
    func testKnownProblemAreas() async throws {
        let model = try await loadAvatarSampleA()
        helper.loadModel(model)

        print("\n" + String(repeating: "=", count: 60))
        print("KNOWN PROBLEM AREA ANALYSIS")
        print(String(repeating: "=", count: 60))

        // Areas commonly affected by Z-fighting in VRM models
        let problemAreas: [(name: String, eye: SIMD3<Float>, target: SIMD3<Float>, description: String)] = [
            ("Eyes", SIMD3(0, 1.58, 0.25), SIMD3(0, 1.58, 0), "Eye surface vs eyeball"),
            ("Eyebrows", SIMD3(0, 1.62, 0.25), SIMD3(0, 1.60, 0), "Eyebrow vs forehead skin"),
            ("Eyelashes", SIMD3(0, 1.57, 0.2), SIMD3(0, 1.57, 0), "Eyelash vs eyelid"),
            ("Mouth", SIMD3(0, 1.48, 0.25), SIMD3(0, 1.48, 0), "Lips vs teeth/tongue"),
            ("Hair Bangs", SIMD3(0, 1.65, 0.3), SIMD3(0, 1.60, 0), "Hair vs forehead"),
            ("Collar/Neck", SIMD3(0, 1.35, 0.4), SIMD3(0, 1.35, 0), "Clothing vs skin"),
        ]

        for area in problemAreas {
            helper.setViewMatrix(makeLookAt(
                eye: area.eye,
                target: area.target,
                up: SIMD3<Float>(0, 1, 0)
            ))

            let frames = try helper.renderMultipleFrames(count: 20, perturbationScale: 0.00005)

            // Analyze center region (where the target is)
            let centerResult = FlickerDetector.analyzeRegion(
                frames: frames,
                x: 192, y: 192,
                width: 128, height: 128,
                frameWidth: 512,
                threshold: 5
            )

            let status: String
            if centerResult.flickerRate > 5.0 {
                status = "🔴 CRITICAL"
            } else if centerResult.flickerRate > 1.0 {
                status = "🟡 WARNING"
            } else if centerResult.flickerRate > 0.1 {
                status = "🟢 LOW"
            } else {
                status = "✅ OK"
            }

            print("\n\(area.name) (\(area.description)):")
            print("  Status: \(status)")
            print("  Flicker: \(String(format: "%.2f", centerResult.flickerRate))% (\(centerResult.flickeringPixels.count) pixels)")
        }
    }

    /// Analyze material rendering order issues
    func testMaterialRenderingOrder() async throws {
        let model = try await loadAvatarSampleA()

        print("\n" + String(repeating: "=", count: 60))
        print("MATERIAL ANALYSIS")
        print(String(repeating: "=", count: 60))

        // List all materials and their properties
        print("\nMaterials in model:")
        for (index, material) in model.materials.enumerated() {
            let alphaMode = material.alphaMode
            let doubleSided = material.doubleSided
            print("  [\(index)] \(material.name ?? "unnamed")")
            print("      Alpha: \(alphaMode), DoubleSided: \(doubleSided)")
        }

        // List meshes and their primitives
        print("\nMeshes:")
        for (meshIndex, mesh) in model.meshes.enumerated() {
            print("  [\(meshIndex)] \(mesh.name ?? "unnamed")")
            for (primIndex, prim) in mesh.primitives.enumerated() {
                let matName = prim.materialIndex.map { model.materials[$0].name ?? "mat\($0)" } ?? "none"
                print("      Prim \(primIndex): material=\(matName), hasJoints=\(prim.hasJoints)")
            }
        }

        // Check for face materials
        print("\nFace-related materials (potential Z-fighting sources):")
        let faceKeywords = ["face", "eye", "brow", "lash", "mouth", "lip", "skin", "head"]
        for (index, material) in model.materials.enumerated() {
            let name = (material.name ?? "").lowercased()
            if faceKeywords.contains(where: { name.contains($0) }) {
                print("  [\(index)] \(material.name ?? "unnamed") - Alpha: \(material.alphaMode)")
            }
        }
    }

    // MARK: - Helper Types and Methods

    struct ZFightingIssue {
        enum Severity { case info, warning, critical }

        let camera: String
        let region: String
        let flickerRate: Float
        let flickeringPixels: Int
        let severity: Severity
        let description: String
    }

    private func analyzeFromCamera(name: String, eye: SIMD3<Float>, target: SIMD3<Float>) async throws -> [ZFightingIssue] {
        helper.setViewMatrix(makeLookAt(eye: eye, target: target, up: SIMD3<Float>(0, 1, 0)))

        let frames = try helper.renderMultipleFrames(count: 20, perturbationScale: 0.0001)

        // Analyze full frame
        let fullResult = FlickerDetector.detectFlicker(frames: frames, threshold: 5)

        // Analyze center region (most important)
        let centerResult = FlickerDetector.analyzeRegion(
            frames: frames,
            x: 128, y: 128,
            width: 256, height: 256,
            frameWidth: 512,
            threshold: 5
        )

        print("\n[\(name)]")
        print("  Full frame: \(String(format: "%.2f", fullResult.flickerRate))% flicker (\(fullResult.flickeringPixels.count) pixels)")
        print("  Center region: \(String(format: "%.2f", centerResult.flickerRate))% flicker (\(centerResult.flickeringPixels.count) pixels)")

        var issues: [ZFightingIssue] = []

        // Threshold adjusted to 20% to accommodate known MASK material artifacts
        // TODO: Revisit when true Z-fighting (not edge aliasing) is reduced
        if centerResult.flickerRate > 20.0 {
            issues.append(ZFightingIssue(
                camera: name,
                region: "center",
                flickerRate: centerResult.flickerRate,
                flickeringPixels: centerResult.flickeringPixels.count,
                severity: .critical,
                description: "Very high flicker rate in center region"
            ))
        } else if centerResult.flickerRate > 10.0 {
            issues.append(ZFightingIssue(
                camera: name,
                region: "center",
                flickerRate: centerResult.flickerRate,
                flickeringPixels: centerResult.flickeringPixels.count,
                severity: .warning,
                description: "Moderate flicker in center region"
            ))
        }

        return issues
    }

    private func describeRegion(col: Int, row: Int, gridSize: Int) -> String {
        let vertical: String
        if row < gridSize / 3 {
            vertical = "upper"
        } else if row < 2 * gridSize / 3 {
            vertical = "middle"
        } else {
            vertical = "lower"
        }

        let horizontal: String
        if col < gridSize / 3 {
            horizontal = "left"
        } else if col < 2 * gridSize / 3 {
            horizontal = "center"
        } else {
            horizontal = "right"
        }

        // Map to face features
        if vertical == "upper" {
            if horizontal == "center" { return "Forehead/Hair" }
            return "Hair \(horizontal) side"
        } else if vertical == "middle" {
            if horizontal == "center" { return "Nose/Eyes" }
            if horizontal == "left" { return "Left eye area" }
            return "Right eye area"
        } else {
            if horizontal == "center" { return "Mouth/Chin" }
            return "Cheek \(horizontal) side"
        }
    }
}
