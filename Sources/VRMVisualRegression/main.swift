//
//  VRMVisualRegression.swift
//  VRMMetalKit
//
//  CLI tool for visual regression testing of VRM rendering
//
//  USAGE:
//      swift run VRMVisualRegression compare <reference.mov> <test.mov>
//      swift run VRMVisualRegression compare-lbs-dqs <vrm> <vrma>
//      swift run VRMVisualRegression generate <vrm> <vrma> <output.mov>
//

import Foundation
import VRMMetalKit
import Metal
import MetalKit
import AVFoundation
import CoreImage

// MARK: - Errors

enum VisualRegressionError: Error {
    case failedToCreateDevice
    case failedToLoadVideo
    case framesMismatch(Int, Int)
    case dimensionsMismatch(Int, Int, Int, Int)
    case thresholdExceeded(Double, Double)
    case fileNotFound(String)
    case invalidArguments
    case referenceGenerationFailed
}

// MARK: - Comparison Result

struct ComparisonResult {
    let frameCount: Int
    let matchingFrames: Int
    let differentFrames: Int
    let maxDifference: Double
    let averageDifference: Double
    let maxDiffFrame: Int
    let psnr: Double
    let passed: Bool
    
    var summary: String {
        """
        📊 Visual Regression Results
        ═════════════════════════════════════════════════════
        Frames compared:    \(frameCount)
        Matching frames:    \(matchingFrames) (\(String(format: "%.1f", Double(matchingFrames)/Double(frameCount)*100))%)
        Different frames:   \(differentFrames) (\(String(format: "%.1f", Double(differentFrames)/Double(frameCount)*100))%)
        
        Difference Metrics:
          Max difference:   \(String(format: "%.4f", maxDifference))
          Average diff:     \(String(format: "%.4f", averageDifference))
          Worst frame:      #\(maxDiffFrame)
          PSNR:             \(String(format: "%.2f", psnr)) dB
        
        Result: \(passed ? "✅ PASSED" : "❌ FAILED")
        ═════════════════════════════════════════════════════
        """
    }
}

// MARK: - Video Frame Extractor

class VideoFrameExtractor {
    let asset: AVAsset
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    let track: AVAssetTrack
    
    init(url: URL) throws {
        asset = AVAsset(url: url)
        
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw VisualRegressionError.failedToLoadVideo
        }
        track = videoTrack
        
        reader = try AVAssetReader(asset: asset)
        
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        
        output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        
        guard reader.startReading() else {
            throw VisualRegressionError.failedToLoadVideo
        }
    }
    
    var frameCount: Int {
        Int(track.nominalFrameRate * Float(track.timeRange.duration.seconds))
    }
    
    var dimensions: (width: Int, height: Int) {
        let size = track.naturalSize
        return (Int(size.width), Int(size.height))
    }
    
    func extractFrames(maxFrames: Int? = nil) throws -> [CGImage] {
        var frames: [CGImage] = []
        let limit = maxFrames ?? frameCount
        let context = CIContext()
        
        while frames.count < limit {
            guard let sampleBuffer = output.copyNextSampleBuffer(),
                  let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                break
            }
            
            let ciImage = CIImage(cvPixelBuffer: imageBuffer)
            if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
                frames.append(cgImage)
            }
        }
        
        return frames
    }
}

// MARK: - Frame Comparison

struct FrameComparison {
    let identical: Bool
    let maxDifference: Double
    let averageDifference: Double
    let differentPixels: Int
    let psnr: Double
}

struct ImageComparator {
    
    static func compare(_ image1: CGImage, _ image2: CGImage, threshold: Double = 0.01) -> FrameComparison {
        guard image1.width == image2.width && image1.height == image2.height else {
            return FrameComparison(
                identical: false,
                maxDifference: 1.0,
                averageDifference: 1.0,
                differentPixels: image1.width * image1.height,
                psnr: 0.0
            )
        }
        
        let width = image1.width
        let height = image1.height
        let totalPixels = width * height
        
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        
        guard let data1 = calloc(height * bytesPerRow, MemoryLayout<UInt8>.size),
              let data2 = calloc(height * bytesPerRow, MemoryLayout<UInt8>.size) else {
            fatalError("Failed to allocate memory")
        }
        
        defer {
            free(data1)
            free(data2)
        }
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        
        guard let context1 = CGContext(
            data: data1,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ),
        let context2 = CGContext(
            data: data2,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            fatalError("Failed to create contexts")
        }
        
        context1.draw(image1, in: CGRect(x: 0, y: 0, width: width, height: height))
        context2.draw(image2, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        let ptr1 = data1.bindMemory(to: UInt8.self, capacity: height * bytesPerRow)
        let ptr2 = data2.bindMemory(to: UInt8.self, capacity: height * bytesPerRow)
        
        var maxDiff: Double = 0
        var totalDiff: Double = 0
        var differentPixels = 0
        var mse: Double = 0
        
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                
                let r1 = Double(ptr1[offset]) / 255.0
                let g1 = Double(ptr1[offset + 1]) / 255.0
                let b1 = Double(ptr1[offset + 2]) / 255.0
                
                let r2 = Double(ptr2[offset]) / 255.0
                let g2 = Double(ptr2[offset + 1]) / 255.0
                let b2 = Double(ptr2[offset + 2]) / 255.0
                
                // Perceptual difference
                let dr = abs(r1 - r2) * 0.299
                let dg = abs(g1 - g2) * 0.587
                let db = abs(b1 - b2) * 0.114
                let pixelDiff = dr + dg + db
                
                maxDiff = max(maxDiff, pixelDiff)
                totalDiff += pixelDiff
                
                if pixelDiff > threshold {
                    differentPixels += 1
                }
                
                let rError = Double(ptr1[offset]) - Double(ptr2[offset])
                let gError = Double(ptr1[offset + 1]) - Double(ptr2[offset + 1])
                let bError = Double(ptr1[offset + 2]) - Double(ptr2[offset + 2])
                mse += (rError * rError + gError * gError + bError * bError) / 3.0
            }
        }
        
        let averageDiff = totalDiff / Double(totalPixels)
        mse /= Double(totalPixels)
        let psnr = mse > 0 ? 10 * log10((255.0 * 255.0) / mse) : 99.0
        
        return FrameComparison(
            identical: maxDiff < threshold,
            maxDifference: maxDiff,
            averageDifference: averageDiff,
            differentPixels: differentPixels,
            psnr: psnr
        )
    }
}


// MARK: - Video Comparison

class VideoComparator {
    
    static func compare(
        referenceURL: URL,
        testURL: URL,
        threshold: Double = 0.02,
        maxFrames: Int? = nil
    ) throws -> ComparisonResult {
        
        print("📂 Loading reference video: \(referenceURL.path)")
        let reference = try VideoFrameExtractor(url: referenceURL)
        
        print("📂 Loading test video: \(testURL.path)")
        let test = try VideoFrameExtractor(url: testURL)
        
        let refDims = reference.dimensions
        let testDims = test.dimensions
        
        guard refDims == testDims else {
            throw VisualRegressionError.dimensionsMismatch(
                refDims.width, refDims.height,
                testDims.width, testDims.height
            )
        }
        
        print("   Resolution: \(refDims.width)x\(refDims.height)")
        
        let refFrameCount = reference.frameCount
        let testFrameCount = test.frameCount
        let compareFrameCount = min(maxFrames ?? min(refFrameCount, testFrameCount), min(refFrameCount, testFrameCount))
        
        print("   Reference frames: \(refFrameCount)")
        print("   Test frames: \(testFrameCount)")
        print("   Comparing: \(compareFrameCount) frames")
        
        var matchingFrames = 0
        var differentFrames = 0
        var maxDifference: Double = 0
        var totalDifference: Double = 0
        var maxDiffFrame = 0
        var totalPSNR: Double = 0
        
        print("\n⏳ Extracting and comparing frames...")
        let refFrames = try reference.extractFrames(maxFrames: compareFrameCount)
        let testFrames = try test.extractFrames(maxFrames: compareFrameCount)
        
        guard refFrames.count == testFrames.count else {
            throw VisualRegressionError.framesMismatch(refFrames.count, testFrames.count)
        }
        
        for (index, (refFrame, testFrame)) in zip(refFrames, testFrames).enumerated() {
            let comparison = ImageComparator.compare(refFrame, testFrame, threshold: threshold)
            
            if comparison.identical {
                matchingFrames += 1
            } else {
                differentFrames += 1
            }
            
            if comparison.maxDifference > maxDifference {
                maxDifference = comparison.maxDifference
                maxDiffFrame = index
            }
            
            totalDifference += comparison.averageDifference
            totalPSNR += comparison.psnr
            
            if (index + 1) % 30 == 0 || index == refFrames.count - 1 {
                let progress = Double(index + 1) / Double(refFrames.count) * 100
                print("   📊 Progress: \(String(format: "%.1f", progress))% (frame \(index + 1)/\(refFrames.count))")
            }
        }
        
        let averageDifference = totalDifference / Double(compareFrameCount)
        let averagePSNR = totalPSNR / Double(compareFrameCount)
        let passed = maxDifference <= threshold
        
        return ComparisonResult(
            frameCount: compareFrameCount,
            matchingFrames: matchingFrames,
            differentFrames: differentFrames,
            maxDifference: maxDifference,
            averageDifference: averageDifference,
            maxDiffFrame: maxDiffFrame,
            psnr: averagePSNR,
            passed: passed
        )
    }
}

// MARK: - LBS vs DQS Comparison

@MainActor
func compareLBSvsDQS(
    vrmPath: String,
    vrmaPath: String,
    duration: Double = 2.0,
    fps: Int = 30,
    width: Int = 640,
    height: Int = 360
) async throws -> ComparisonResult {
    
    print("🎬 Generating LBS vs DQS comparison")
    print("   Model: \(vrmPath)")
    print("   Animation: \(vrmaPath)")
    print("   Duration: \(duration)s @ \(fps)fps")
    print("")
    
    let lbsPath = "/tmp/vrm_regression_lbs_\(UUID().uuidString).mov"
    let dqsPath = "/tmp/vrm_regression_dqs_\(UUID().uuidString).mov"
    
    defer {
        try? FileManager.default.removeItem(atPath: lbsPath)
        try? FileManager.default.removeItem(atPath: dqsPath)
    }
    
    print("⏳ Rendering with Linear Blend Skinning...")
    try await renderTestVideo(
        vrmPath: vrmPath,
        vrmaPath: vrmaPath,
        outputPath: lbsPath,
        duration: duration,
        fps: fps,
        width: width,
        height: height,
        useDQS: false
    )
    
    print("\n⏳ Rendering with Dual Quaternion Skinning...")
    try await renderTestVideo(
        vrmPath: vrmPath,
        vrmaPath: vrmaPath,
        outputPath: dqsPath,
        duration: duration,
        fps: fps,
        width: width,
        height: height,
        useDQS: true
    )
    
    print("\n🔍 Comparing outputs...")
    return try VideoComparator.compare(
        referenceURL: URL(fileURLWithPath: lbsPath),
        testURL: URL(fileURLWithPath: dqsPath),
        threshold: 0.05,
        maxFrames: nil
    )
}

@MainActor
func renderTestVideo(
    vrmPath: String,
    vrmaPath: String,
    outputPath: String,
    duration: Double,
    fps: Int,
    width: Int,
    height: Int,
    useDQS: Bool
) async throws {
    
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw VisualRegressionError.failedToCreateDevice
    }
    
    let model = try await VRMModel.load(from: URL(fileURLWithPath: vrmPath), device: device)
    let animationClip = try VRMAnimationLoader.loadVRMA(from: URL(fileURLWithPath: vrmaPath), model: model)
    
    let player = AnimationPlayer()
    player.load(animationClip)
    player.play()
    
    var config = RendererConfig()
    config.sampleCount = 1
    config.strict = .off
    config.skinningMode = useDQS ? .dualQuaternion : .linearBlend
    
    if useDQS {
        VRMPipelineCache.shared.clearCache()
    }
    
    let renderer = VRMRenderer(device: device, config: config)
    renderer.loadModel(model)
    
    renderer.setLight(0, direction: SIMD3<Float>(-0.2, 0.5, -0.85),
                      color: SIMD3<Float>(1.0, 1.0, 1.0), intensity: 1.0)
    renderer.disableLight(1)
    renderer.setLight(2, direction: SIMD3<Float>(0.0, 0.2, 1.0),
                      color: SIMD3<Float>(1.0, 1.0, 1.0), intensity: 0.3)
    renderer.setAmbientColor(SIMD3<Float>(0.03, 0.03, 0.05))
    
    renderer.viewMatrix = lookAt(eye: SIMD3<Float>(0, 1, 3),
                                  center: SIMD3<Float>(0, 1, 0),
                                  up: SIMD3<Float>(0, 1, 0))
    
    let aspectRatio = Float(width) / Float(height)
    renderer.projectionMatrix = perspective(fovRadians: Float.pi / 4, aspect: aspectRatio, near: 0.1, far: 100)
    
    let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: width,
        height: height,
        mipmapped: false
    )
    colorDescriptor.usage = [.renderTarget, .shaderRead]
    colorDescriptor.storageMode = .managed
    
    let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .depth32Float,
        width: width,
        height: height,
        mipmapped: false
    )
    depthDescriptor.usage = .renderTarget
    depthDescriptor.storageMode = .private
    
    guard let colorTexture = device.makeTexture(descriptor: colorDescriptor),
          let depthTexture = device.makeTexture(descriptor: depthDescriptor) else {
        throw VisualRegressionError.failedToCreateDevice
    }
    
    let videoWriter = try AVAssetWriter(url: URL(fileURLWithPath: outputPath), fileType: .mov)
    
    let videoSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: width * height * 2
        ]
    ]
    
    let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    writerInput.expectsMediaDataInRealTime = false
    
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: writerInput,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
    )
    
    videoWriter.add(writerInput)
    videoWriter.startWriting()
    videoWriter.startSession(atSourceTime: .zero)
    
    let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
    let totalFrames = Int(duration * Double(fps))
    
    for frameIndex in 0..<totalFrames {
        player.update(deltaTime: 1.0 / Float(fps), model: model)
        
        guard let commandQueue = device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            continue
        }
        
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = colorTexture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.depthAttachment.texture = depthTexture
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.clearDepth = 1.0
        renderPassDescriptor.depthAttachment.storeAction = .dontCare
        
        renderer.drawOffscreenHeadless(
            to: colorTexture,
            depth: depthTexture,
            commandBuffer: commandBuffer,
            renderPassDescriptor: renderPassDescriptor
        )
        
        commandBuffer.commit()
        
        // Wait for completion using async-friendly polling
        while commandBuffer.status != .completed && commandBuffer.status != .error {
            await Task.yield()
        }
        
        guard commandBuffer.status == .completed else {
            throw VisualRegressionError.failedToCreateDevice
        }
        
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [:]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                           kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        
        guard let pb = pixelBuffer else { continue }
        
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let baseAddress = CVPixelBufferGetBaseAddress(pb)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        
        colorTexture.getBytes(baseAddress, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        
        let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
        
        while !writerInput.isReadyForMoreMediaData {
            await Task.yield()
        }
        
        adaptor.append(pb, withPresentationTime: presentationTime)
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
    }
    
    writerInput.markAsFinished()
    await videoWriter.finishWriting()
}


// MARK: - Math Helpers

func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> matrix_float4x4 {
    let f = normalize(center - eye)
    let s = normalize(cross(f, up))
    let u = cross(s, f)
    
    var result = matrix_float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1))
    result.columns.0 = SIMD4<Float>(s.x, u.x, -f.x, 0)
    result.columns.1 = SIMD4<Float>(s.y, u.y, -f.y, 0)
    result.columns.2 = SIMD4<Float>(s.z, u.z, -f.z, 0)
    result.columns.3 = SIMD4<Float>(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)
    
    return result
}

func perspective(fovRadians: Float, aspect: Float, near: Float, far: Float) -> matrix_float4x4 {
    let tanHalfFov = tan(fovRadians / 2)
    
    var result = matrix_float4x4()
    result.columns.0 = SIMD4<Float>(1 / (aspect * tanHalfFov), 0, 0, 0)
    result.columns.1 = SIMD4<Float>(0, 1 / tanHalfFov, 0, 0)
    result.columns.2 = SIMD4<Float>(0, 0, -(far + near) / (far - near), -1)
    result.columns.3 = SIMD4<Float>(0, 0, -(2 * far * near) / (far - near), 0)
    
    return result
}

// MARK: - Usage

func printUsage() {
    print("""
    VRMVisualRegression - Visual regression testing for VRM rendering
    
    USAGE:
        swift run VRMVisualRegression <command> [arguments]
    
    COMMANDS:
        compare <reference.mov> <test.mov> [options]
            Compare two video files for visual differences
            
        compare-lbs-dqs <model.vrm> <anim.vrma> [options]
            Render the same animation with LBS and DQS and compare
            This verifies that DQS produces different (volume-preserving) output
            
        generate <model.vrm> <anim.vrma> <output.mov> [options]
            Generate a reference video for later comparison
            
    OPTIONS:
        -t, --threshold <value>   Difference threshold (default: 0.02)
        --max-frames <n>          Compare at most N frames
        -w, --width <pixels>      Render width (default: 640)
        -h, --height <pixels>     Render height (default: 360)
        -d, --duration <secs>     Render duration (default: 2.0)
        -f, --fps <fps>           Frames per second (default: 30)
        --help                    Show this help message
    
    EXAMPLES:
        # Compare two existing videos
        swift run VRMVisualRegression compare reference.mov new_render.mov
        
        # Compare LBS vs DQS (key test for DQS implementation)
        swift run VRMVisualRegression compare-lbs-dqs model.vrm anim.vrma
        
        # Generate reference for regression testing
        swift run VRMVisualRegression generate model.vrm anim.vrma reference.mov
        
    EXIT CODES:
        0   Success / No regressions detected
        1   Regressions detected or error
    """)
}

// MARK: - Arguments

struct CompareOptions {
    var command: String = ""
    var referencePath: String = ""
    var testPath: String = ""
    var vrmPath: String = ""
    var vrmaPath: String = ""
    var outputPath: String = ""
    var threshold: Double = 0.02
    var maxFrames: Int?
    var width: Int = 640
    var height: Int = 360
    var duration: Double = 2.0
    var fps: Int = 30
}

func parseArguments() -> CompareOptions? {
    let args = CommandLine.arguments
    
    if args.count < 2 || args.contains("--help") {
        printUsage()
        return nil
    }
    
    var options = CompareOptions()
    options.command = args[1]
    
    switch options.command {
    case "compare":
        guard args.count >= 4 else {
            print("Error: compare requires reference and test video paths")
            return nil
        }
        options.referencePath = args[2]
        options.testPath = args[3]
        
    case "compare-lbs-dqs":
        guard args.count >= 4 else {
            print("Error: compare-lbs-dqs requires VRM and VRMA paths")
            return nil
        }
        options.vrmPath = args[2]
        options.vrmaPath = args[3]
        
    case "generate":
        guard args.count >= 5 else {
            print("Error: generate requires VRM, VRMA, and output paths")
            return nil
        }
        options.vrmPath = args[2]
        options.vrmaPath = args[3]
        options.outputPath = args[4]
        
    default:
        print("Error: Unknown command '\(options.command)'")
        printUsage()
        return nil
    }
    
    var i = min(args.count, options.command == "compare" ? 4 : (options.command == "generate" ? 5 : 4))
    while i < args.count {
        let arg = args[i]
        
        switch arg {
        case "-t", "--threshold":
            i += 1
            if i < args.count, let val = Double(args[i]) {
                options.threshold = val
            }
        case "--max-frames":
            i += 1
            if i < args.count, let val = Int(args[i]) {
                options.maxFrames = val
            }
        case "-w", "--width":
            i += 1
            if i < args.count, let val = Int(args[i]) {
                options.width = val
            }
        case "-h", "--height":
            i += 1
            if i < args.count, let val = Int(args[i]) {
                options.height = val
            }
        case "-d", "--duration":
            i += 1
            if i < args.count, let val = Double(args[i]) {
                options.duration = val
            }
        case "-f", "--fps":
            i += 1
            if i < args.count, let val = Int(args[i]) {
                options.fps = val
            }
        default:
            break
        }
        
        i += 1
    }
    
    return options
}

// MARK: - Main

@main
struct VRMVisualRegressionCLI {
    static func main() async {
        guard let options = parseArguments() else {
            exit(0)
        }
        
        do {
            switch options.command {
            case "compare":
                try await runCompare(options: options)
                
            case "compare-lbs-dqs":
                try await runCompareLBSDQS(options: options)
                
            case "generate":
                try await runGenerate(options: options)
                
            default:
                print("Unknown command")
                exit(1)
            }
        } catch {
            print("❌ Error: \(error)")
            exit(1)
        }
    }
    
    static func runCompare(options: CompareOptions) async throws {
        let result = try VideoComparator.compare(
            referenceURL: URL(fileURLWithPath: options.referencePath),
            testURL: URL(fileURLWithPath: options.testPath),
            threshold: options.threshold,
            maxFrames: options.maxFrames
        )
        
        print("\n" + result.summary)
        
        exit(result.passed ? 0 : 1)
    }
    
    static func runCompareLBSDQS(options: CompareOptions) async throws {
        let result = try await compareLBSvsDQS(
            vrmPath: options.vrmPath,
            vrmaPath: options.vrmaPath,
            duration: options.duration,
            fps: options.fps,
            width: options.width,
            height: options.height
        )
        
        print("\n" + result.summary)
        
        let dqsWorking = result.maxDifference > 0.01 && result.differentFrames > 0
        
        if dqsWorking {
            print("\n✅ DQS is producing different output from LBS (volume-preserving skinning active)")
            print("   Max difference: \(String(format: "%.4f", result.maxDifference))")
            print("   Different frames: \(result.differentFrames)/\(result.frameCount)")
            exit(0)
        } else {
            print("\n⚠️  WARNING: DQS output is nearly identical to LBS")
            print("   This may indicate DQS is not being applied correctly")
            exit(1)
        }
    }
    
    static func runGenerate(options: CompareOptions) async throws {
        print("🎬 Generating reference video...")
        print("   Model: \(options.vrmPath)")
        print("   Animation: \(options.vrmaPath)")
        print("   Output: \(options.outputPath)")
        
        try await renderTestVideo(
            vrmPath: options.vrmPath,
            vrmaPath: options.vrmaPath,
            outputPath: options.outputPath,
            duration: options.duration,
            fps: options.fps,
            width: options.width,
            height: options.height,
            useDQS: false
        )
        
        print("\n✅ Reference video generated: \(options.outputPath)")
        exit(0)
    }
}
