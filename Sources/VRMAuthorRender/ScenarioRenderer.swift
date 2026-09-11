//
// Copyright 2026 Arkavo
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
import simd
import VRMAuthorKit
import VRMMetalKit

/// Renders one canonical scenario offscreen with VRMMetalKit and writes
/// deterministic PNG evidence plus, for motion scenarios, a trace.
struct ScenarioRenderer {
    static let rendererId = "vrmmetalkit"
    static let backend = "metal"
    static let mediaTypePNG = "image/png"
    static let mediaTypeJSON = "application/json"

    let device: MTLDevice
    let plan: RenderPlan
    let outputDirectory: URL

    static func rendererDescription(device: MTLDevice, sampleCount: Int? = nil) -> JSONValue {
        var renderer: [String: JSONValue] = [
            "id": .string(rendererId), "version": .string(VRMMetalKit.version), "device": .string(device.name), "backend": .string(backend),
            "pngEncoder": .string(PNGEncoder.version),
        ]
        if let sampleCount { renderer["sampleCount"] = .number(Double(sampleCount)) }
        return .object(renderer)
    }

    struct Targets {
        var colour: MTLTexture
        var multisample: MTLTexture?
        var depth: MTLTexture
        var descriptor: MTLRenderPassDescriptor
    }

    func makeTargets(width: Int, height: Int) throws -> Targets {
        let colourDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        colourDescriptor.usage = [.renderTarget, .shaderRead]
        colourDescriptor.storageMode = .shared
        guard let colour = device.makeTexture(descriptor: colourDescriptor) else { throw RenderFailure("Could not allocate the \(width)x\(height) colour target.") }
        colour.label = "vrm-author-render colour"

        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depthDescriptor.usage = .renderTarget
        depthDescriptor.storageMode = .private
        var multisample: MTLTexture? = nil
        if plan.sampleCount > 1 {
            let msaaDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            msaaDescriptor.textureType = .type2DMultisample
            msaaDescriptor.sampleCount = plan.sampleCount
            msaaDescriptor.usage = .renderTarget
            msaaDescriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: msaaDescriptor) else { throw RenderFailure("Could not allocate the \(plan.sampleCount)x multisample colour target.") }
            texture.label = "vrm-author-render msaa colour"
            multisample = texture
            depthDescriptor.textureType = .type2DMultisample
            depthDescriptor.sampleCount = plan.sampleCount
        }
        guard let depth = device.makeTexture(descriptor: depthDescriptor) else { throw RenderFailure("Could not allocate the depth target.") }
        depth.label = "vrm-author-render depth"

        let descriptor = MTLRenderPassDescriptor()
        let attachment = descriptor.colorAttachments[0]!
        attachment.loadAction = .clear
        attachment.clearColor = MTLClearColor(red: Double(plan.background.x), green: Double(plan.background.y), blue: Double(plan.background.z), alpha: Double(plan.background.w))
        if let multisample {
            attachment.texture = multisample
            attachment.resolveTexture = colour
            attachment.storeAction = .multisampleResolve
        } else {
            attachment.texture = colour
            attachment.storeAction = .store
        }
        descriptor.depthAttachment.texture = depth
        descriptor.depthAttachment.loadAction = .clear
        descriptor.depthAttachment.storeAction = .dontCare
        descriptor.depthAttachment.clearDepth = 1.0
        return Targets(colour: colour, multisample: multisample, depth: depth, descriptor: descriptor)
    }

    // MARK: Matrices

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) throws -> float4x4 {
        let forward = target - eye
        guard simd_length(forward) > 1e-6 else { throw RenderFailure("camera.position and camera.target coincide.") }
        let f = simd_normalize(forward)
        var side = simd_cross(f, up)
        if simd_length(side) < 1e-6 { side = simd_cross(f, SIMD3<Float>(0, 0, 1)) }
        let s = simd_normalize(side)
        let u = simd_cross(s, f)
        return float4x4(
            SIMD4<Float>(s.x, u.x, -f.x, 0),
            SIMD4<Float>(s.y, u.y, -f.y, 0),
            SIMD4<Float>(s.z, u.z, -f.z, 0),
            SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1))
    }

    static func orthographic(heightM: Float, aspect: Float, nearZ: Float, farZ: Float) -> float4x4 {
        let halfHeight = heightM / 2
        let halfWidth = halfHeight * aspect
        let zs = 1 / (nearZ - farZ)
        return float4x4(
            SIMD4<Float>(1 / halfWidth, 0, 0, 0),
            SIMD4<Float>(0, 1 / halfHeight, 0, 0),
            SIMD4<Float>(0, 0, zs, 0),
            SIMD4<Float>(0, 0, nearZ * zs, 1))
    }

    func projectionMatrix(width: Int, height: Int) -> float4x4 {
        let aspect = Float(width) / Float(height)
        switch plan.projection {
        case .perspective:
            return makePerspective(fovyRadians: plan.fovDegrees * .pi / 180, aspectRatio: aspect, nearZ: 0.01, farZ: 100)
        case .orthographic:
            return ScenarioRenderer.orthographic(heightM: plan.orthographicHeightM, aspect: aspect, nearZ: 0.01, farZ: 100)
        }
    }

    // MARK: Rendering

    func configure(renderer: VRMRenderer, model: VRMModel) throws {
        renderer.loadModel(model)
        renderer.disableLight(1)
        renderer.disableLight(2)
        renderer.setLight(0, direction: plan.lightDirection, color: plan.lightColour, intensity: plan.lightIntensity * powf(2, plan.exposureEV))
        renderer.setLightNormalizationMode(.radiometric)
        if !plan.expressionWeights.isEmpty {
            guard let controller = renderer.expressionController else { throw RenderFailure("Scenario sets expression weights but the model exposes no expressions.") }
            for (name, weight) in plan.expressionWeights.sorted(by: { $0.key < $1.key }) {
                if let preset = VRMExpressionPreset(rawValue: name) {
                    controller.setExpressionWeight(preset, weight: weight)
                } else {
                    controller.setCustomExpressionWeight(name, weight: weight)
                }
            }
        }
        renderer.viewMatrix = try ScenarioRenderer.lookAt(eye: plan.cameraPosition, target: plan.cameraTarget, up: plan.cameraUp)
        renderer.projectionMatrix = projectionMatrix(width: plan.width, height: plan.height)
        renderer.simulationDeltaTime = plan.timestepS
        renderer.enableSpringBone = false
    }

    func draw(renderer: VRMRenderer, queue: MTLCommandQueue, targets: Targets) throws {
        guard let commandBuffer = queue.makeCommandBuffer() else { throw RenderFailure("Could not create a command buffer.") }
        renderer.drawOffscreen(to: targets.colour, depth: targets.depth, commandBuffer: commandBuffer, renderPassDescriptor: targets.descriptor)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw RenderFailure("GPU command buffer failed: \(error)") }
    }

    func readPNG(_ texture: MTLTexture) throws -> Data {
        let width = texture.width, height = texture.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return try PNGEncoder.encode(width: width, height: height, rgba: rgba)
    }

    func writeArtifact(_ data: Data, name: String, mediaType: String, role: String) throws -> JSONValue {
        let url = outputDirectory.appendingPathComponent(name)
        try ProjectStore.atomicWrite(data, to: url)
        return ["path": .string(url.path), "sha256": .string(SHA256Hex.hex(data)), "mediaType": .string(mediaType), "sizeBytes": .number(Double(data.count)), "role": .string(role)]
    }

    static func frameName(scenarioId: String, timeS: Double, single: Bool) -> String {
        single ? "\(scenarioId).png" : "\(scenarioId)_t\(String(format: "%.3f", timeS))s.png"
    }

    /// Renders the scenario and returns the manifest artifact entries.
    func render(model: VRMModel) throws -> [JSONValue] {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let config = RendererConfig(strict: .off, colorPixelFormat: .rgba8Unorm, sampleCount: plan.sampleCount, synchronousSpringBone: true)
        let renderer = VRMRenderer(device: device, config: config)
        try configure(renderer: renderer, model: model)
        guard let queue = device.makeCommandQueue() else { throw RenderFailure("Could not create a command queue.") }
        let full = try makeTargets(width: plan.width, height: plan.height)
        var artifacts: [JSONValue] = []

        guard plan.isMotion else {
            try draw(renderer: renderer, queue: queue, targets: full)
            let png = try readPNG(full.colour)
            let times = plan.captureTimesS
            for time in times {
                artifacts.append(try writeArtifact(png, name: ScenarioRenderer.frameName(scenarioId: plan.scenarioId, timeS: time, single: times.count == 1),
                                                   mediaType: ScenarioRenderer.mediaTypePNG, role: "render:\(plan.scenarioId)"))
            }
            return artifacts
        }

        let simulateOnly = try makeTargets(width: 8, height: 8)
        let captures = plan.captureSteps
        var trace = MotionTrace(model: model, timestepS: plan.timestepS)
        let stepCount = plan.stepCount
        let hasSprings = model.springBone.map { !$0.springs.isEmpty } ?? false

        func captureFrame(timeS: Double) throws {
            try draw(renderer: renderer, queue: queue, targets: full)
            let png = try readPNG(full.colour)
            artifacts.append(try writeArtifact(png, name: ScenarioRenderer.frameName(scenarioId: plan.scenarioId, timeS: timeS, single: false),
                                               mediaType: ScenarioRenderer.mediaTypePNG, role: "render:\(plan.scenarioId)"))
        }

        renderer.enableSpringBone = false
        model.updateNodeTransforms()
        trace.sample(step: 0, timeS: 0, keepJoints: true)
        for capture in captures where capture.step == 0 { try captureFrame(timeS: capture.timeS) }

        renderer.enableSpringBone = hasSprings
        for step in stride(from: 1, through: stepCount, by: 1) {
            let timeS = Double(step) * plan.timestepS
            let isCapture = captures.contains { $0.step == step }
            if isCapture {
                for capture in captures where capture.step == step { try captureFrame(timeS: capture.timeS) }
            } else {
                try draw(renderer: renderer, queue: queue, targets: simulateOnly)
            }
            trace.sample(step: step, timeS: timeS, keepJoints: isCapture)
        }

        let traceData = try CanonicalJSON.data(trace.json(scenarioId: plan.scenarioId, durationS: plan.durationS, stepCount: stepCount, captureTimesS: plan.captureTimesS))
        artifacts.append(try writeArtifact(traceData, name: "trace.json", mediaType: ScenarioRenderer.mediaTypeJSON, role: "trace:\(plan.scenarioId)"))
        return artifacts
    }
}
