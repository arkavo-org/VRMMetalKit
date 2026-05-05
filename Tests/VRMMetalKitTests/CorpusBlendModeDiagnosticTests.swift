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
@testable import VRMMetalKit

/// Diagnostic test: scan the entire ../GameOfMods/ VRM corpus for blend mode usage.
///
/// Goal: find which models actually use non-zero _BlendMode or transparentWithZWrite,
/// so we can identify which ones are affected by the alphaMode mapping fix and which
/// ones might show black bangs / transparency artifacts.
final class CorpusBlendModeDiagnosticTests: XCTestCase {

    private var device: MTLDevice!

    override func setUp() {
        super.setUp()
        device = MTLCreateSystemDefaultDevice()
        XCTAssertNotNil(device, "Metal device required")
    }

    // MARK: - Corpus Scan

    @MainActor
    func testScanAllModelsForBlendModes() async throws {
        let models = try findCorpusModels()
        XCTAssertFalse(models.isEmpty, "No .vrm files found in ../GameOfMods/")

        var reportLines: [String] = []
        var modelsWithNonZeroBlendMode: [String] = []
        var modelsWithTransparentZWrite: [String] = []
        var modelsWithBlendMode3: [String] = []

        for modelURL in models {
            let modelName = modelURL.lastPathComponent
            reportLines.append("")
            reportLines.append("========== " + modelName + " ==========")

            let model: VRMModel
            do {
                model = try await VRMModel.load(from: modelURL, device: device)
            } catch {
                reportLines.append("  ⚠️ FAILED TO LOAD: " + String(describing: error))
                continue
            }

            reportLines.append("  Materials: " + String(model.materials.count))

            for (i, mat) in model.materials.enumerated() {
                let hasTex = mat.baseColorTexture != nil
                let twzw = mat.isTransparentWithZWrite
                reportLines.append("  [" + String(i) + "] " + (mat.name ?? "unnamed"))
                reportLines.append(
                    "      alphaMode='" + mat.alphaMode + "' blendMode=" + String(mat.blendMode)
                    + " transparentWithZWrite=" + String(twzw)
                )
                reportLines.append(
                    "      renderQueue=" + String(mat.renderQueue)
                    + " zWrite=" + String(mat.zWriteEnabled)
                    + " hasTexture=" + String(hasTex)
                )

                if mat.blendMode != 0 {
                    modelsWithNonZeroBlendMode.append(modelName + ": " + (mat.name ?? "mat"+String(i)) + " blendMode=" + String(mat.blendMode))
                }
                if twzw {
                    modelsWithTransparentZWrite.append(modelName + ": " + (mat.name ?? "mat"+String(i)))
                }
                if mat.blendMode == 3 {
                    modelsWithBlendMode3.append(modelName + ": " + (mat.name ?? "mat"+String(i)))
                }
            }
        }

        reportLines.append("")
        reportLines.append("========== SUMMARY ==========")
        reportLines.append("Models scanned: " + String(models.count))
        reportLines.append("Models with non-zero blendMode: " + String(modelsWithNonZeroBlendMode.count))
        for entry in modelsWithNonZeroBlendMode {
            reportLines.append("  → " + entry)
        }
        reportLines.append("Models with blendMode==3: " + String(modelsWithBlendMode3.count))
        for entry in modelsWithBlendMode3 {
            reportLines.append("  → " + entry)
        }
        reportLines.append("Materials with transparentWithZWrite: " + String(modelsWithTransparentZWrite.count))
        for entry in modelsWithTransparentZWrite {
            reportLines.append("  → " + entry)
        }

        let report = reportLines.joined(separator: "\n")
        print(report)

        XCTContext.runActivity(named: "Corpus Blend Mode Report") { activity in
            let attachment = XCTAttachment(string: report)
            attachment.name = "CorpusBlendModeReport.txt"
            activity.add(attachment)
        }
    }

    // MARK: - Per-Model Diagnostics

    /// Specifically inspect both AliciaSolid files to see if the v0.51 version
    /// differs from the main one in blend mode usage.
    func testAliciaSolidVersionsComparison() async throws {
        let root = corpusRoot()
        let candidates = [
            root.appendingPathComponent("AliciaSolid.vrm"),
            root.appendingPathComponent("AliciaSolid_vrm-0.51.vrm"),
        ]

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            let model = try await VRMModel.load(from: url, device: device)
            print("\n=== " + url.lastPathComponent + " ===")
            for mat in model.materials {
                print("  " + (mat.name ?? "?") + ": alphaMode=" + mat.alphaMode + " blendMode=" + String(mat.blendMode) + " twzw=" + String(mat.isTransparentWithZWrite) + " queue=" + String(mat.renderQueue))
            }
        }
    }

    // MARK: - Helpers

    private func corpusRoot() -> URL {
        let fileManager = FileManager.default
        let candidates: [String?] = [
            ProcessInfo.processInfo.environment["PROJECT_ROOT"],
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path,
            fileManager.currentDirectoryPath
        ]

        for candidate in candidates.compactMap({ $0 }) {
            let packagePath = candidate + "/Package.swift"
            if fileManager.fileExists(atPath: packagePath) {
                // Go up one level from project root to find GameOfMods sibling
                let parent = URL(fileURLWithPath: candidate).deletingLastPathComponent()
                return parent.appendingPathComponent("GameOfMods")
            }
        }
        // Fallback: ../GameOfMods relative to current working dir
        return URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .deletingLastPathComponent()
            .appendingPathComponent("GameOfMods")
    }

    private func findCorpusModels() throws -> [URL] {
        let root = corpusRoot()
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            XCTFail("Corpus directory not found: " + root.path)
            return []
        }

        let contents = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return contents
            .filter { $0.pathExtension.lowercased() == "vrm" || $0.lastPathComponent.hasSuffix(".vrm.glb") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
