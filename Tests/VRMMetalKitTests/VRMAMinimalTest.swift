//
// Minimal test to reproduce VRMA Signal 11 crash
//

import XCTest
import Metal
import simd
@testable import VRMMetalKit

final class VRMAMinimalTest: XCTestCase {
    func testMinimalVRMALoad() async throws {
        // Use the same projectRoot logic as VRMAValidationTests
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

        var projectRoot = fileManager.currentDirectoryPath
        for candidate in candidates.compactMap({ $0 }) {
            let packagePath = "\(candidate)/Package.swift"
            let vrmPath = "\(candidate)/AliciaSolid.vrm"
            if fileManager.fileExists(atPath: packagePath) &&
               fileManager.fileExists(atPath: vrmPath) {
                projectRoot = candidate
                break
            }
        }

        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"

        guard FileManager.default.fileExists(atPath: modelPath),
              FileManager.default.fileExists(atPath: vrmaPath) else {
            throw XCTSkip("Test files not found at \(projectRoot)")
        }

        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal not available")
            return
        }

        print("[TEST] Loading model...")
        let model = try await VRMModel.load(from: URL(fileURLWithPath: modelPath), device: device)
        
        print("[TEST] Loading VRMA...")
        let clip = try VRMAnimationLoader.loadVRMA(from: URL(fileURLWithPath: vrmaPath), model: model)

        // Reproduce VRMAValidationTests loop: create multiple AnimationPlayers
        let frameTimes: [Float] = [0.0, clip.duration / 2.0, max(0, clip.duration - 0.001)]

        for (frameIndex, time) in frameTimes.enumerated() {
            print("[TEST] ===== Frame \(frameIndex): time=\(time) =====")

            print("[TEST] Creating AnimationPlayer...")
            let player = AnimationPlayer()
            player.load(clip) 
            player.isLooping = false

            print("[TEST] Calling player.update()...")
            player.update(deltaTime: time, model: model)
            print("[TEST] player.update() returned successfully!")

            // Reproduce what VRMAValidationTests does next
            print("[TEST] Updating world transforms...")
            for node in model.nodes where node.parent == nil {
                node.updateWorldTransform()
            }
            print("[TEST] World transforms updated!")
        }
    }
}