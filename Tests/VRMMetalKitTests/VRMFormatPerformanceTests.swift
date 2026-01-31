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

/// Performance Report: .vrm vs .vrm.glb Loading
///
/// Compares loading performance between:
/// - .vrm: VRM 0.0 format (JSON extension + binary buffer)
/// - .vrm.glb: VRM 1.0 format (GLB container)
final class VRMFormatPerformanceTests: XCTestCase {

    // MARK: - Test Paths
    
    private var vrmFiles: [(name: String, path: String)] {
        [
            ("AliciaSolid.vrm", "/Users/arkavo/Projects/VRMMetalKit/AliciaSolid.vrm"),
            ("PompaGirl_v0.vrm", "/Users/arkavo/Projects/GameOfMods/Resources/vrm/PompaGirl_v0.vrm"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    
    private var vrmGlbFiles: [(name: String, path: String)] {
        [
            ("AvatarSample_A.vrm.glb", "/Users/arkavo/Projects/Muse/Resources/VRM/AvatarSample_A.vrm.glb"),
            ("AvatarSample_C.vrm.glb", "/Users/arkavo/Projects/Muse/Resources/VRM/AvatarSample_C.vrm.glb"),
            ("Pokemon.vrm.glb", "/Users/arkavo/Projects/GameOfMods/Resources/vrm/Pokemon.vrm.glb"),
            ("Roblox.vrm.glb", "/Users/arkavo/Projects/GameOfMods/Resources/vrm/Roblox.vrm.glb"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Performance Tests
    
    /// Compare loading performance: .vrm vs .vrm.glb
    func testVRMLoadingPerformanceComparison() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal not available")
            return
        }
        
        print("\n" + String(repeating: "=", count: 70))
        print("VRM FORMAT LOADING PERFORMANCE REPORT")
        print(String(repeating: "=", count: 70))
        
        var results: [(format: String, name: String, size: Int64, loadTime: Double)] = []
        
        // Test .vrm files
        print("\n📁 .vrm FORMAT (VRM 0.0)")
        print(String(repeating: "-", count: 50))
        
        for (name, path) in vrmFiles {
            let url = URL(fileURLWithPath: path)
            let fileSize = try! FileManager.default.attributesOfItem(atPath: path)[.size] as! Int64
            
            // Warm up
            _ = try? await VRMModel.load(from: url, device: device)
            
            // Measure
            let iterations = 5
            let startTime = CFAbsoluteTimeGetCurrent()
            
            for _ in 0..<iterations {
                _ = try await VRMModel.load(from: url, device: device)
            }
            
            let endTime = CFAbsoluteTimeGetCurrent()
            let avgTime = (endTime - startTime) / Double(iterations) * 1000.0
            
            results.append((".vrm", name, fileSize, avgTime))
            
            print("  \(name.padding(toLength: 25, withPad: " ", startingAt: 0)) | " +
                  "Size: \(String(format: "%6.2f", Double(fileSize) / 1024.0 / 1024.0)) MB | " +
                  "Load: \(String(format: "%7.2f", avgTime)) ms")
        }
        
        // Test .vrm.glb files
        print("\n📁 .vrm.glb FORMAT (VRM 1.0)")
        print(String(repeating: "-", count: 50))
        
        for (name, path) in vrmGlbFiles {
            let url = URL(fileURLWithPath: path)
            let fileSize = try! FileManager.default.attributesOfItem(atPath: path)[.size] as! Int64
            
            // Warm up
            _ = try? await VRMModel.load(from: url, device: device)
            
            // Measure
            let iterations = 5
            let startTime = CFAbsoluteTimeGetCurrent()
            
            for _ in 0..<iterations {
                _ = try await VRMModel.load(from: url, device: device)
            }
            
            let endTime = CFAbsoluteTimeGetCurrent()
            let avgTime = (endTime - startTime) / Double(iterations) * 1000.0
            
            results.append((".vrm.glb", name, fileSize, avgTime))
            
            print("  \(name.padding(toLength: 25, withPad: " ", startingAt: 0)) | " +
                  "Size: \(String(format: "%6.2f", Double(fileSize) / 1024.0 / 1024.0)) MB | " +
                  "Load: \(String(format: "%7.2f", avgTime)) ms")
        }
        
        // Summary
        print("\n" + String(repeating: "=", count: 70))
        print("SUMMARY")
        print(String(repeating: "=", count: 70))
        
        let vrmResults = results.filter { $0.format == ".vrm" }
        let vrmGlbResults = results.filter { $0.format == ".vrm.glb" }
        
        if !vrmResults.isEmpty {
            let avgVrmTime = vrmResults.map { $0.loadTime }.reduce(0, +) / Double(vrmResults.count)
            let avgVrmSize = vrmResults.map { Double($0.size) }.reduce(0, +) / Double(vrmResults.count)
            print("\n.vrm (VRM 0.0):")
            print("  Average Load Time: \(String(format: "%.2f", avgVrmTime)) ms")
            print("  Average File Size: \(String(format: "%.2f", avgVrmSize / 1024.0 / 1024.0)) MB")
        }
        
        if !vrmGlbResults.isEmpty {
            let avgVrmGlbTime = vrmGlbResults.map { $0.loadTime }.reduce(0, +) / Double(vrmGlbResults.count)
            let avgVrmGlbSize = vrmGlbResults.map { Double($0.size) }.reduce(0, +) / Double(vrmGlbResults.count)
            print("\n.vrm.glb (VRM 1.0):")
            print("  Average Load Time: \(String(format: "%.2f", avgVrmGlbTime)) ms")
            print("  Average File Size: \(String(format: "%.2f", avgVrmGlbSize / 1024.0 / 1024.0)) MB")
        }
        
        if !vrmResults.isEmpty && !vrmGlbResults.isEmpty {
            let avgVrmTime = vrmResults.map { $0.loadTime }.reduce(0, +) / Double(vrmResults.count)
            let avgVrmGlbTime = vrmGlbResults.map { $0.loadTime }.reduce(0, +) / Double(vrmGlbResults.count)
            let speedup = avgVrmTime / avgVrmGlbTime
            
            print("\n📊 COMPARISON:")
            print("  Speed Difference: \(String(format: "%.2fx", speedup)) " +
                  "(\(speedup > 1 ? ".vrm.glb faster" : ".vrm faster"))")
        }
        
        print("\n" + String(repeating: "=", count: 70))
    }
    
    /// Detailed breakdown of loading phases
    func testLoadingPhaseBreakdown() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal not available")
            return
        }
        
        print("\n" + String(repeating: "=", count: 70))
        print("LOADING PHASE BREAKDOWN")
        print(String(repeating: "=", count: 70))
        
        // Pick one file of each type
        let vrmPath = vrmFiles.first?.path ?? "/Users/arkavo/Projects/VRMMetalKit/AliciaSolid.vrm"
        let vrmGlbPath = vrmGlbFiles.first?.path ?? "/Users/arkavo/Projects/Muse/Resources/VRM/AvatarSample_A.vrm.glb"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmPath), "No .vrm file available")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmGlbPath), "No .vrm.glb file available")
        
        // Test .vrm
        print("\n📁 .vrm (AliciaSolid.vrm)")
        print(String(repeating: "-", count: 50))
        
        let vrmUrl = URL(fileURLWithPath: vrmPath)
        let vrmData = try! Data(contentsOf: vrmUrl)
        
        let t1 = CFAbsoluteTimeGetCurrent()
        _ = try await VRMModel.load(from: vrmUrl, device: device)
        let t2 = CFAbsoluteTimeGetCurrent()
        
        print("  File I/O (Data load):      \(String(format: "%7.2f", (t2-t1)*1000)) ms")
        print("  Total Load Time:           \(String(format: "%7.2f", (t2-t1)*1000)) ms")
        print("  File Size:                 \(String(format: "%7.2f", Double(vrmData.count)/1024.0/1024.0)) MB")
        
        // Test .vrm.glb
        print("\n📁 .vrm.glb (AvatarSample_A.vrm.glb)")
        print(String(repeating: "-", count: 50))
        
        let vrmGlbUrl = URL(fileURLWithPath: vrmGlbPath)
        let vrmGlbData = try! Data(contentsOf: vrmGlbUrl)
        
        let t3 = CFAbsoluteTimeGetCurrent()
        _ = try await VRMModel.load(from: vrmGlbUrl, device: device)
        let t4 = CFAbsoluteTimeGetCurrent()
        
        print("  File I/O (Data load):      \(String(format: "%7.2f", (t4-t3)*1000)) ms")
        print("  Total Load Time:           \(String(format: "%7.2f", (t4-t3)*1000)) ms")
        print("  File Size:                 \(String(format: "%7.2f", Double(vrmGlbData.count)/1024.0/1024.0)) MB")
        
        print("\n" + String(repeating: "=", count: 70))
    }
    
    /// Memory usage comparison
    func testMemoryUsageComparison() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal not available")
            return
        }
        
        print("\n" + String(repeating: "=", count: 70))
        print("MEMORY USAGE COMPARISON")
        print(String(repeating: "=", count: 70))
        
        let vrmPath = vrmFiles.first?.path ?? "/Users/arkavo/Projects/VRMMetalKit/AliciaSolid.vrm"
        let vrmGlbPath = vrmGlbFiles.first?.path ?? "/Users/arkavo/Projects/Muse/Resources/VRM/AvatarSample_A.vrm.glb"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmPath), "No .vrm file available")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmGlbPath), "No .vrm.glb file available")
        
        // Measure .vrm memory
        print("\n📁 .vrm (AliciaSolid.vrm)")
        
        let t1 = CFAbsoluteTimeGetCurrent()
        let vrmModel = try await VRMModel.load(from: URL(fileURLWithPath: vrmPath), device: device)
        let t2 = CFAbsoluteTimeGetCurrent()
        
        print("  Load Time:  \(String(format: "%.2f", (t2-t1)*1000)) ms")
        print("  Nodes:      \(vrmModel.nodes.count)")
        print("  Meshes:     \(vrmModel.meshes.count)")
        print("  Materials:  \(vrmModel.materials.count)")
        print("  Textures:   \(vrmModel.textures.count)")
        
        // Measure .vrm.glb memory
        print("\n📁 .vrm.glb (AvatarSample_A.vrm.glb)")
        
        let t3 = CFAbsoluteTimeGetCurrent()
        let vrmGlbModel = try await VRMModel.load(from: URL(fileURLWithPath: vrmGlbPath), device: device)
        let t4 = CFAbsoluteTimeGetCurrent()
        
        print("  Load Time:  \(String(format: "%.2f", (t4-t3)*1000)) ms")
        print("  Nodes:      \(vrmGlbModel.nodes.count)")
        print("  Meshes:     \(vrmGlbModel.meshes.count)")
        print("  Materials:  \(vrmGlbModel.materials.count)")
        print("  Textures:   \(vrmGlbModel.textures.count)")
        print("  Is VRM 1.0: \(vrmGlbModel.specVersion == .v1_0)")
        
        print("\n" + String(repeating: "=", count: 70))
    }
    
    /// Stress test: Multiple consecutive loads
    func testConsecutiveLoadStress() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal not available")
            return
        }
        
        print("\n" + String(repeating: "=", count: 70))
        print("CONSECUTIVE LOAD STRESS TEST")
        print(String(repeating: "=", count: 70))
        
        let vrmPath = vrmFiles.first?.path
        let vrmGlbPath = vrmGlbFiles.first?.path
        
        let iterations = 10
        
        // Stress test .vrm
        if let vrmPath = vrmPath, FileManager.default.fileExists(atPath: vrmPath) {
            print("\n📁 .vrm - \(iterations) consecutive loads")
            
            let startTime = CFAbsoluteTimeGetCurrent()
            
            for i in 0..<iterations {
                _ = try await VRMModel.load(from: URL(fileURLWithPath: vrmPath), device: device)
                if i == 0 || i == iterations - 1 {
                    print("  Load \(i+1)/\(iterations) completed")
                }
            }
            
            let endTime = CFAbsoluteTimeGetCurrent()
            let totalTime = (endTime - startTime) * 1000.0
            let avgTime = totalTime / Double(iterations)
            
            print("  Total: \(String(format: "%.2f", totalTime)) ms")
            print("  Avg:   \(String(format: "%.2f", avgTime)) ms")
        }
        
        // Stress test .vrm.glb
        if let vrmGlbPath = vrmGlbPath, FileManager.default.fileExists(atPath: vrmGlbPath) {
            print("\n📁 .vrm.glb - \(iterations) consecutive loads")
            
            let startTime = CFAbsoluteTimeGetCurrent()
            
            for i in 0..<iterations {
                _ = try await VRMModel.load(from: URL(fileURLWithPath: vrmGlbPath), device: device)
                if i == 0 || i == iterations - 1 {
                    print("  Load \(i+1)/\(iterations) completed")
                }
            }
            
            let endTime = CFAbsoluteTimeGetCurrent()
            let totalTime = (endTime - startTime) * 1000.0
            let avgTime = totalTime / Double(iterations)
            
            print("  Total: \(String(format: "%.2f", totalTime)) ms")
            print("  Avg:   \(String(format: "%.2f", avgTime)) ms")
        }
        
        print("\n" + String(repeating: "=", count: 70))
    }
}

