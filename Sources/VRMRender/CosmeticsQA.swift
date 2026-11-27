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
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import simd
import VRMMetalKit

/// Real-avatar visual QA & showcase runner exercising all 4 VRMMetalKit 2.0 cosmetics phases
/// and stitching a labeled 3x2 contact sheet (`contact_sheet.png`) alongside individual PNGs.
enum CosmeticsQARunner {

    struct PanelResult {
        let filename: String
        let title: String
        let subtitle: String
        let image: CGImage
    }

    @MainActor
    static func run(
        inputPath: String,
        outputDir: String,
        panelSize: Int,
        sampleCount: Int
    ) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RenderError.failedToCreateTexture
        }

        let outURL = URL(fileURLWithPath: outputDir, isDirectory: true)
        try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

        print("VRMRender --cosmetics-qa")
        print("=====================================")
        print("Avatar: \(inputPath)")
        print("Output: \(outputDir)")
        print("Panel:  \(panelSize)x\(panelSize) (\(sampleCount)x MSAA)")
        print("")

        let modelURL = URL(fileURLWithPath: inputPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        let avatarName = model.meta.name ?? modelURL.deletingPathExtension().lastPathComponent
        print("✓ Loaded '\(avatarName)' (spec=\(model.specVersion), materials=\(model.materials.count), meshes=\(model.meshes.count))")

        // Capture T-pose reference bone positions BEFORE posing arms (for accurate T-pose skinned garments)
        model.updateNodeTransforms()
        let tPoseUpperChest = boneWorldPosition(model: model, bone: .upperChest)
            ?? boneWorldPosition(model: model, bone: .chest)
            ?? SIMD3<Float>(0, 1.22, 0)
        let tPoseNeck = boneWorldPosition(model: model, bone: .neck)
            ?? (tPoseUpperChest + SIMD3<Float>(0, 0.12, 0))
        let tPoseLeftUpperArm = boneWorldPosition(model: model, bone: .leftUpperArm)
            ?? (tPoseUpperChest + SIMD3<Float>(0.14, 0.05, 0))
        let tPoseRightUpperArm = boneWorldPosition(model: model, bone: .rightUpperArm)
            ?? (tPoseUpperChest + SIMD3<Float>(-0.14, 0.05, 0))

        // Save original T-pose arm rotations so Panel 5 attaches in T-pose then animates cleanly into A-pose
        let leftArmNode = model.humanoid?.getBoneNode(.leftUpperArm).flatMap { $0 < model.nodes.count ? model.nodes[$0] : nil }
        let rightArmNode = model.humanoid?.getBoneNode(.rightUpperArm).flatMap { $0 < model.nodes.count ? model.nodes[$0] : nil }
        let tPoseLeftArmRot = leftArmNode?.rotation
        let tPoseRightArmRot = rightArmNode?.rotation

        // Relax arms from T-pose into a natural A-pose for clean portrait framing
        applyNaturalAPose(model: model, armDropDegrees: 42)
        model.updateNodeTransforms()

        // Locate head & chest world positions for auto-framing portraits and upper-body panels
        let headPos = boneWorldPosition(model: model, bone: .head)
            ?? fallbackHeadPosition(model: model)
        let chestPos = boneWorldPosition(model: model, bone: .upperChest)
            ?? boneWorldPosition(model: model, bone: .chest)
            ?? SIMD3<Float>(headPos.x, headPos.y - 0.25, headPos.z)
        let faceForwardZ = detectFaceForwardSign(model: model, headPos: headPos)
        print(String(format: "✓ Head=(%.3f, %.3f, %.3f) Chest=(%.3f, %.3f, %.3f) forwardZ=%+.0f",
                     headPos.x, headPos.y, headPos.z, chestPos.x, chestPos.y, chestPos.z, faceForwardZ))

        // Locate primary face skin material
        let faceMaterial = findFaceSkinMaterial(in: model)
        print("✓ Face skin material: \(faceMaterial?.name ?? "<not found>")")

        // Renderer setup (spec-driven v2.0 default, synchronous SpringBone for deterministic offline capture)
        var config = RendererConfig()
        config.sampleCount = sampleCount
        config.strict = .off
        config.synchronousSpringBone = true
        let renderer = VRMRenderer(device: device, config: config)
        renderer.enableSpringBone = true
        renderer.loadModel(model)
        configureStudioLights(renderer: renderer, faceForwardZ: faceForwardZ)

        // Camera presets (portrait close-up & upper-body)
        let portraitTarget = headPos + SIMD3<Float>(0, 0.055, 0)
        let portraitEye = portraitTarget + SIMD3<Float>(0, 0.01, faceForwardZ * 0.44)
        let threeQuarterEye = portraitTarget + SIMD3<Float>(0.14, 0.02, faceForwardZ * 0.46)
        let upperBodyTarget = chestPos + SIMD3<Float>(0, 0.08, 0)
        let upperBodyEye = upperBodyTarget + SIMD3<Float>(0.12, 0.05, faceForwardZ * 0.92)
        let physicsTarget = headPos + SIMD3<Float>(0, -0.06, 0)
        let physicsEye = physicsTarget + SIMD3<Float>(0.36, 0.04, faceForwardZ * 0.66)

        guard let queue = device.makeCommandQueue() else {
            throw RenderError.failedToCreateCommandBuffer
        }

        // Warm up host SpringBones so hair settles cleanly before panel 1
        renderer.warmupPhysics(steps: 20)

        var panels: [PanelResult] = []

        // -----------------------------------------------------------------
        // Panel 1: Baseline (v2.0 spec-driven portrait)
        // -----------------------------------------------------------------
        let p1 = try await renderPanel(
            renderer: renderer, device: device, queue: queue,
            size: panelSize, eye: portraitEye, target: portraitTarget,
            fovDegrees: 34, filename: "01_baseline.png", outURL: outURL,
            title: "1. Baseline (v2.0 Spec-Driven)",
            subtitle: "\(avatarName) • \(model.specVersion)"
        )
        panels.append(p1)
        print("✓ [1/6] \(p1.filename)")

        // -----------------------------------------------------------------
        // Panel 2: Face UV Landmarks Calibration Overlay + 2D Atlas Dump
        // -----------------------------------------------------------------
        let landmarkStack = try VRMTextureLayerStack(
            device: device,
            faceLandmarks: model.faceLandmarks ?? .vroidDefault
        )
        if let faceMat = faceMaterial {
            landmarkStack.layers = try makeLandmarkOverlayLayers(device: device)
            try landmarkStack.apply(to: faceMat, slot: .baseColor, in: model, commandQueue: queue)
            if let atlasTex = landmarkStack.lastOutputTexture {
                try exportTexture(atlasTex, to: outURL.appendingPathComponent("02_landmarks_atlas.png").path, device: device)
            }
        }
        let p2 = try await renderPanel(
            renderer: renderer, device: device, queue: queue,
            size: panelSize, eye: portraitEye, target: portraitTarget,
            fovDegrees: 34, filename: "02_landmarks_uv.png", outURL: outURL,
            title: "2. Face UV Landmarks",
            subtitle: "vroidDefault calibration overlay"
        )
        panels.append(p2)
        print("✓ [2/6] \(p2.filename) + 02_landmarks_atlas.png")
        if let faceMat = faceMaterial {
            landmarkStack.clear(from: faceMat, slot: .baseColor, in: model)
        }

        // -----------------------------------------------------------------
        // Panel 3: Layered GPU Makeup + Per-Pixel Specular Gloss Finish
        // -----------------------------------------------------------------
        let makeupStack = try VRMTextureLayerStack(
            device: device,
            faceLandmarks: model.faceLandmarks ?? .vroidDefault
        )
        var finishSummary = "no face mat"
        if let faceMat = faceMaterial {
            makeupStack.layers = try makeEditorialMakeupLayers(device: device)
            try makeupStack.apply(to: faceMat, slot: .baseColor, in: model, commandQueue: queue)
            if let atlasTex = makeupStack.lastOutputTexture {
                try exportTexture(atlasTex, to: outURL.appendingPathComponent("03_makeup_atlas.png").path, device: device)
            }
            if let finTex = makeupStack.lastFinishTexture {
                try exportTexture(finTex, to: outURL.appendingPathComponent("03_finish_map.png").path, device: device)
            }
            let linkedSync = (faceMat.mtoon?.shadeMultiplyTexture?.mtlTexture === faceMat.baseColorTexture?.mtlTexture)
            finishSummary = "\(makeupStack.layers.count) layers • gloss lips + glitter • shadeSync=\(linkedSync)"
        }
        // Slightly front-angled key light to catch specular lip gloss & metallic cheek star
        renderer.setLight(0, direction: SIMD3<Float>(0.18, 0.28, -faceForwardZ * 0.94),
                          color: SIMD3<Float>(1.0, 0.98, 0.96), intensity: 1.15)
        let p3 = try await renderPanel(
            renderer: renderer, device: device, queue: queue,
            size: panelSize, eye: threeQuarterEye, target: portraitTarget,
            fovDegrees: 32, filename: "03_makeup_gloss.png", outURL: outURL,
            title: "3. GPU Makeup + Gloss Finish",
            subtitle: finishSummary
        )
        panels.append(p3)
        print("✓ [3/6] \(p3.filename) (\(finishSummary))")
        configureStudioLights(renderer: renderer, faceForwardZ: faceForwardZ)

        // -----------------------------------------------------------------
        // Panel 4: Rigid 3D Accessories (Tinted Glasses + Golden Halo)
        // -----------------------------------------------------------------
        let eyeCenterLocal = computeEyeBridgeOffsetInHeadSpace(model: model, faceForwardZ: faceForwardZ)
        let glassesGLB = try buildProceduralGlassesGLB(faceForwardZ: faceForwardZ)
        let haloGLB = try buildProceduralHaloGLB()
        let glassesAsset = try await VRMCosmeticAsset.load(from: glassesGLB, device: device)
        let haloAsset = try await VRMCosmeticAsset.load(from: haloGLB, device: device)

        let glassesHandle = try model.attach(
            glassesAsset,
            to: .head,
            options: VRMAttachmentOptions(firstPersonFlag: .thirdPersonOnly)
        )
        _ = model.updateTransform(for: glassesHandle, translation: eyeCenterLocal)

        let haloHandle = try model.attach(
            haloAsset,
            to: .head,
            options: VRMAttachmentOptions(firstPersonFlag: .thirdPersonOnly)
        )
        _ = model.updateTransform(
            for: haloHandle,
            translation: SIMD3<Float>(0, eyeCenterLocal.y + 0.145, -faceForwardZ * 0.02),
            rotation: simd_quatf(angle: faceForwardZ * 0.14, axis: SIMD3<Float>(1, 0, 0))
        )

        let p4 = try await renderPanel(
            renderer: renderer, device: device, queue: queue,
            size: panelSize, eye: threeQuarterEye, target: portraitTarget + SIMD3<Float>(0, 0.03, 0),
            fovDegrees: 38, filename: "04_rigid_accessories.png", outURL: outURL,
            title: "4. Rigid 3D Wearables",
            subtitle: "Glasses (BLEND) + Halo (.thirdPersonOnly)"
        )
        panels.append(p4)
        print("✓ [4/6] \(p4.filename)")

        // -----------------------------------------------------------------
        // Panel 5: Skinned Garment (Shoulder Cape) + 2-Bit Vertex Body Mask
        // -----------------------------------------------------------------
        // Restore T-pose so the T-pose-authored skinned mantle binds 1:1, then lower arms to A-pose
        // so the skinned shoulders deform smoothly with zero double-rotation.
        if let leftArmNode, let tPoseLeftArmRot {
            leftArmNode.rotation = tPoseLeftArmRot
            leftArmNode.updateLocalMatrix()
        }
        if let rightArmNode, let tPoseRightArmRot {
            rightArmNode.rotation = tPoseRightArmRot
            rightArmNode.updateLocalMatrix()
        }
        model.updateNodeTransforms()

        let capeGLB = try buildProceduralSkinnedMantleGLB(
            upperChestPos: tPoseUpperChest,
            neckPos: tPoseNeck,
            lArmPos: tPoseLeftUpperArm,
            rArmPos: tPoseRightUpperArm,
            faceForwardZ: faceForwardZ
        )
        let capeAsset = try await VRMCosmeticAsset.load(from: capeGLB, device: device)
        let capeHandle = try model.attachSkinned(
            capeAsset,
            options: VRMAttachmentOptions(
                proportionFit: .exact,
                bodyMaskBones: [.upperChest],
                bodyMaskWeightThreshold: 0.75
            )
        )
        // Lower arms into natural A-pose AFTER skinned attachment so mantle shoulders deform live
        applyNaturalAPose(model: model, armDropDegrees: 42)
        model.updateNodeTransforms()

        let p5 = try await renderPanel(
            renderer: renderer, device: device, queue: queue,
            size: panelSize, eye: upperBodyEye, target: upperBodyTarget,
            fovDegrees: 38, filename: "05_skinned_garment_mask.png", outURL: outURL,
            title: "5. Skinned Garment + Body Mask",
            subtitle: "T-pose bind → live A-pose + 2-bit mask"
        )
        panels.append(p5)
        print("✓ [5/6] \(p5.filename)")
        model.detach(capeHandle)

        // -----------------------------------------------------------------
        // Panel 6: Dynamic SpringBone Physics Cosmetic under Live Head Swing
        // -----------------------------------------------------------------
        let ribbonGLB = try buildProceduralSpringBoneRibbonsGLB(
            anchorOffset: SIMD3<Float>(0, eyeCenterLocal.y + 0.055, -faceForwardZ * 0.015),
            faceForwardZ: faceForwardZ
        )
        let ribbonAsset = try await VRMCosmeticAsset.load(from: ribbonGLB, device: device)
        let ribbonHandle = try model.attach(ribbonAsset, to: .head)
        try renderer.commitSpringBoneChanges(warmupNewChainSteps: 15)

        // Animate a brisk head yaw sweep so the attached SpringBone twin-ribbons trail with momentum
        if let headNode = model.humanoid?.getBoneNode(.head).flatMap({ $0 < model.nodes.count ? model.nodes[$0] : nil }) {
            let baseHeadRot = headNode.rotation
            let steps = 28
            for step in 0..<steps {
                let t = Float(step) / Float(steps - 1)
                let yaw: Float = -0.58 + 1.12 * t // brisk sweep -33 deg -> +31 deg
                headNode.rotation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)) * baseHeadRot
                headNode.updateLocalMatrix()
                model.updateNodeTransforms()
                renderer.warmupPhysics(steps: 1)
            }
        }
        let p6 = try await renderPanel(
            renderer: renderer, device: device, queue: queue,
            size: panelSize, eye: physicsEye, target: physicsTarget,
            fovDegrees: 42, filename: "06_springbone_physics.png", outURL: outURL,
            title: "6. Dynamic SpringBone Cosmetic",
            subtitle: "Single-solver twin ribbons mid-swing"
        )
        panels.append(p6)
        print("✓ [6/6] \(p6.filename)")

        // Clean detach verification
        model.detach(ribbonHandle)
        model.detach(glassesHandle)
        model.detach(haloHandle)
        if let faceMat = faceMaterial {
            makeupStack.clear(from: faceMat, slot: .baseColor, in: model)
        }
        try renderer.commitSpringBoneChanges(warmupNewChainSteps: 0)

        // Stitch 3x2 labeled contact sheet
        let sheetPath = outURL.appendingPathComponent("contact_sheet.png").path
        try writeContactSheet(
            panels: panels,
            headerTitle: "VRMMetalKit 2.0 Cosmetics Visual QA — \(avatarName)",
            to: sheetPath
        )
        print("")
        print("✅ Contact sheet saved: \(sheetPath)")
    }

    // MARK: - Rendering & Contact Sheet Composition

    @MainActor
    private static func configureStudioLights(renderer: VRMRenderer, faceForwardZ: Float) {
        renderer.setLight(0, direction: SIMD3<Float>(-0.22, 0.45, -faceForwardZ * 0.86),
                          color: SIMD3<Float>(1.0, 1.0, 1.0), intensity: 1.0)
        renderer.disableLight(1)
        renderer.setLight(2, direction: SIMD3<Float>(0.25, 0.25, faceForwardZ * 0.92),
                          color: SIMD3<Float>(0.9, 0.95, 1.0), intensity: 0.35)
        renderer.setAmbientColor(SIMD3<Float>(0.05, 0.05, 0.06))
        renderer.setLightNormalizationMode(.radiometric)
    }

    @MainActor
    private static func renderPanel(
        renderer: VRMRenderer,
        device: MTLDevice,
        queue: MTLCommandQueue,
        size: Int,
        eye: SIMD3<Float>,
        target: SIMD3<Float>,
        fovDegrees: Float,
        filename: String,
        outURL: URL,
        title: String,
        subtitle: String
    ) async throws -> PanelResult {
        renderer.projectionMatrix = perspective(
            fovRadians: fovDegrees * .pi / 180.0,
            aspect: 1.0,
            near: 0.01,
            far: 100.0
        )
        renderer.viewMatrix = lookAt(eye: eye, center: target, up: SIMD3<Float>(0, 1, 0))

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false
        )
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .shared
        guard let colorTex = device.makeTexture(descriptor: colorDesc) else {
            throw RenderError.failedToCreateTexture
        }

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: size, height: size, mipmapped: false
        )
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private
        guard let depthTex = device.makeTexture(descriptor: depthDesc) else {
            throw RenderError.failedToCreateTexture
        }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = colorTex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.13, green: 0.15, blue: 0.20, alpha: 1.0)
        rpd.depthAttachment.texture = depthTex
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.storeAction = .dontCare
        rpd.depthAttachment.clearDepth = 1.0

        guard let cb = queue.makeCommandBuffer() else {
            throw RenderError.failedToCreateCommandBuffer
        }
        renderer.drawOffscreenHeadless(
            to: colorTex,
            depth: depthTex,
            commandBuffer: cb,
            renderPassDescriptor: rpd
        )
        await withCheckedContinuation { cont in
            cb.addCompletedHandler { _ in cont.resume() }
            cb.commit()
        }

        let fileURL = outURL.appendingPathComponent(filename)
        try exportTexture(colorTex, to: fileURL.path, device: device)
        let cgImg = try makeCGImage(from: colorTex)
        return PanelResult(filename: filename, title: title, subtitle: subtitle, image: cgImg)
    }

    private static func makeCGImage(from texture: MTLTexture) throws -> CGImage {
        let w = texture.width
        let h = texture.height
        let bpr = w * 4
        var data = Data(count: h * bpr)
        data.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let img = CGImage(
                width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else {
            throw RenderError.failedToCreateImage
        }
        return img
    }

    private static func writeContactSheet(
        panels: [PanelResult],
        headerTitle: String,
        to path: String
    ) throws {
        guard let first = panels.first else { return }
        let cols = 3
        let rows = (panels.count + cols - 1) / cols
        let cellW = first.image.width
        let cellH = first.image.height
        let pad = 20
        let captionH = 56
        let headerH = 64
        let sheetW = cols * cellW + (cols + 1) * pad
        let sheetH = headerH + rows * (cellH + captionH) + (rows + 1) * pad

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: sheetW,
            height: sheetH,
            bitsPerComponent: 8,
            bytesPerRow: sheetW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw RenderError.failedToCreateImage
        }

        // Background
        ctx.setFillColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))

        // Header text (CoreGraphics origin is bottom-left)
        drawText(ctx, text: headerTitle, x: CGFloat(pad), y: CGFloat(sheetH - headerH + 20), fontSize: 28, bold: true, color: (0.95, 0.97, 1.0))

        for (idx, panel) in panels.enumerated() {
            let col = idx % cols
            let row = idx / cols
            let x = pad + col * (cellW + pad)
            let topY = sheetH - headerH - pad - row * (cellH + captionH + pad)
            let imgY = topY - cellH
            let capY = imgY - captionH

            // Card background
            ctx.setFillColor(red: 0.13, green: 0.15, blue: 0.19, alpha: 1.0)
            ctx.fill(CGRect(x: x - 2, y: capY - 2, width: cellW + 4, height: cellH + captionH + 4))

            // Rendered panel image
            ctx.draw(panel.image, in: CGRect(x: x, y: imgY, width: cellW, height: cellH))

            // Caption banner
            ctx.setFillColor(red: 0.11, green: 0.13, blue: 0.17, alpha: 1.0)
            ctx.fill(CGRect(x: x, y: capY, width: cellW, height: captionH))
            drawText(ctx, text: panel.title, x: CGFloat(x + 12), y: CGFloat(capY + 30), fontSize: 18, bold: true, color: (0.95, 0.97, 1.0))
            drawText(ctx, text: panel.subtitle, x: CGFloat(x + 12), y: CGFloat(capY + 10), fontSize: 13, bold: false, color: (0.68, 0.74, 0.84))
        }

        guard let outImage = ctx.makeImage() else {
            throw RenderError.failedToCreateImage
        }
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError.failedToSaveImage
        }
        CGImageDestinationAddImage(dest, outImage, nil)
        if !CGImageDestinationFinalize(dest) {
            throw RenderError.failedToSaveImage
        }
    }

    private static func drawText(
        _ ctx: CGContext,
        text: String,
        x: CGFloat,
        y: CGFloat,
        fontSize: CGFloat,
        bold: Bool,
        color: (CGFloat, CGFloat, CGFloat)
    ) {
        let fontName: CFString = (bold ? "HelveticaNeue-Bold" : "HelveticaNeue") as CFString
        let font = CTFontCreateWithName(fontName, fontSize, nil)
        let cgColor = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [color.0, color.1, color.2, 1.0])!
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor,
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: - Model Helpers

    private static func findFaceSkinMaterial(in model: VRMModel) -> VRMMaterial? {
        if let exact = model.materials.first(where: {
            let n = ($0.name ?? "").lowercased()
            return n.contains("face") && n.contains("skin")
        }) {
            return exact
        }
        return model.materials.first(where: { ($0.name ?? "").lowercased().contains("face") })
    }

    private static func boneWorldPosition(model: VRMModel, bone: VRMHumanoidBone) -> SIMD3<Float>? {
        guard let idx = model.humanoid?.getBoneNode(bone), idx >= 0, idx < model.nodes.count else {
            return nil
        }
        let m = model.nodes[idx].worldMatrix
        return SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    private static func fallbackHeadPosition(model: VRMModel) -> SIMD3<Float> {
        let (mn, mx) = model.calculateBoundingBox()
        return SIMD3<Float>((mn.x + mx.x) * 0.5, mn.y + (mx.y - mn.y) * 0.85, (mn.z + mx.z) * 0.5)
    }

    private static func detectFaceForwardSign(model: VRMModel, headPos: SIMD3<Float>) -> Float {
        // VRM 1.0 faces +Z; VRM 0.x normalized by VRMMetalKit also faces +Z (check eyes Z relative to head)
        if let le = boneWorldPosition(model: model, bone: .leftEye) {
            return (le.z - headPos.z) >= 0 ? 1.0 : -1.0
        }
        return 1.0
    }

    private static func computeEyeBridgeOffsetInHeadSpace(model: VRMModel, faceForwardZ: Float) -> SIMD3<Float> {
        guard let headIdx = model.humanoid?.getBoneNode(.head), headIdx < model.nodes.count else {
            return SIMD3<Float>(0, 0.075, faceForwardZ * 0.125)
        }
        let headInv = simd_inverse(model.nodes[headIdx].worldMatrix)

        // Compute front-most face Z from Face_00_SKIN primitive bounds so glasses clear the nose bridge,
        // and center vertically on the leftEye/rightEye bone midpoint (-0.006m to land directly on pupil center).
        var faceFrontLocalZ: Float = faceForwardZ * 0.115
        for node in model.nodes {
            guard let meshIdx = node.mesh, meshIdx < model.meshes.count else { continue }
            for prim in model.meshes[meshIdx].primitives {
                if let matIdx = prim.materialIndex, matIdx < model.materials.count {
                    let mname = (model.materials[matIdx].name ?? "").lowercased()
                    if mname.contains("face") && mname.contains("skin") {
                        let zCorner = faceForwardZ >= 0 ? prim.localMax.z : prim.localMin.z
                        let worldPt = node.worldMatrix * SIMD4<Float>(0, (prim.localMin.y + prim.localMax.y) * 0.5, zCorner, 1)
                        let localPt = headInv * worldPt
                        faceFrontLocalZ = localPt.z + faceForwardZ * 0.012
                        break
                    }
                }
            }
        }

        if let le = boneWorldPosition(model: model, bone: .leftEye),
           let re = boneWorldPosition(model: model, bone: .rightEye) {
            let midWorld = (le + re) * 0.5
            let midLocal4 = headInv * SIMD4<Float>(midWorld.x, midWorld.y, midWorld.z, 1)
            return SIMD3<Float>(midLocal4.x, midLocal4.y - 0.006, faceFrontLocalZ)
        }
        return SIMD3<Float>(0, 0.068, faceFrontLocalZ)
    }

    private static func applyNaturalAPose(model: VRMModel, armDropDegrees: Float) {
        let rad = armDropDegrees * .pi / 180.0
        if let lIdx = model.humanoid?.getBoneNode(.leftUpperArm), lIdx < model.nodes.count {
            let node = model.nodes[lIdx]
            node.rotation = simd_quatf(angle: -rad, axis: SIMD3<Float>(0, 0, 1)) * node.rotation
            node.updateLocalMatrix()
        }
        if let rIdx = model.humanoid?.getBoneNode(.rightUpperArm), rIdx < model.nodes.count {
            let node = model.nodes[rIdx]
            node.rotation = simd_quatf(angle: rad, axis: SIMD3<Float>(0, 0, 1)) * node.rotation
            node.updateLocalMatrix()
        }
    }

    // MARK: - Procedural In-Memory PNG Decal Generators (Zero Disk I/O)

    private static func encodePNGData(width: Int, height: Int, draw: (CGContext, Int, Int) -> Void) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw RenderError.failedToCreateImage
        }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        // Flip Y so drawing uses top-left (0, 0) UV coordinates directly
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        draw(ctx, width, height)
        guard let cg = ctx.makeImage() else { throw RenderError.failedToCreateImage }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError.failedToSaveImage
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.failedToSaveImage }
        return out as Data
    }

    private static func makeLandmarkOverlayLayers(device: MTLDevice) throws -> [VRMTextureLayer] {
        let specs: [(VRMFaceLandmarkRegion, (CGFloat, CGFloat, CGFloat))] = [
            (.forehead,   (0.20, 0.85, 1.00)),
            (.leftBrow,   (1.00, 0.85, 0.15)),
            (.rightBrow,  (1.00, 0.85, 0.15)),
            (.leftEye,    (0.25, 1.00, 0.45)),
            (.rightEye,   (0.25, 1.00, 0.45)),
            (.leftCheek,  (1.00, 0.45, 0.70)),
            (.rightCheek, (1.00, 0.45, 0.70)),
            (.nose,       (0.75, 0.45, 1.00)),
            (.lips,       (1.00, 0.15, 0.25)),
        ]
        var layers: [VRMTextureLayer] = []
        for (region, rgb) in specs {
            let png = try encodePNGData(width: 128, height: 128) { ctx, w, h in
                let rect = CGRect(x: 4, y: 4, width: w - 8, height: h - 8)
                ctx.setFillColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 0.22)
                ctx.fill(rect)
                ctx.setStrokeColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 0.95)
                ctx.setLineWidth(6)
                ctx.stroke(rect)
                // Center crosshair
                ctx.setLineWidth(3)
                ctx.move(to: CGPoint(x: w / 2 - 12, y: h / 2))
                ctx.addLine(to: CGPoint(x: w / 2 + 12, y: h / 2))
                ctx.move(to: CGPoint(x: w / 2, y: h / 2 - 12))
                ctx.addLine(to: CGPoint(x: w / 2, y: h / 2 + 12))
                ctx.strokePath()
            }
            let tex = try VRMTextureLayerStack.makeTexture(from: png, device: device, sRGB: true, label: "overlay_\(region.rawValue)")
            layers.append(VRMTextureLayer(name: region.rawValue, texture: tex, blendMode: .normal, opacity: 0.92, landmarkRegion: region))
        }
        return layers
    }

    private static func makeEditorialMakeupLayers(device: MTLDevice) throws -> [VRMTextureLayer] {
        // 1. Soft radial rose blush (feathered ellipse)
        let blushPNG = try encodePNGData(width: 128, height: 128) { ctx, w, h in
            let colors = [
                CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0.92, 0.36, 0.46, 0.80])!,
                CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0.95, 0.45, 0.55, 0.35])!,
                CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0.95, 0.50, 0.60, 0.00])!,
            ] as CFArray
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 0.55, 1.0])!
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(w) * 0.5, y: CGFloat(h) * 0.5)
            ctx.scaleBy(x: 1.0, y: 0.72)
            ctx.drawRadialGradient(grad, startCenter: .zero, startRadius: 2, endCenter: .zero, endRadius: CGFloat(w) * 0.46, options: [])
            ctx.restoreGState()
        }
        let blushTex = try VRMTextureLayerStack.makeTexture(from: blushPNG, device: device, sRGB: true, label: "rose_blush")

        // 2. Sculpted glossy berry lips (cupid's bow upper lip + fuller lower lip)
        let lipsPNG = try encodePNGData(width: 256, height: 128) { ctx, w, h in
            let fw = CGFloat(w), fh = CGFloat(h)
            let lipPath = CGMutablePath()
            lipPath.move(to: CGPoint(x: fw * 0.14, y: fh * 0.50))
            lipPath.addCurve(
                to: CGPoint(x: fw * 0.50, y: fh * 0.34),
                control1: CGPoint(x: fw * 0.28, y: fh * 0.22),
                control2: CGPoint(x: fw * 0.42, y: fh * 0.20)
            )
            lipPath.addCurve(
                to: CGPoint(x: fw * 0.86, y: fh * 0.50),
                control1: CGPoint(x: fw * 0.58, y: fh * 0.20),
                control2: CGPoint(x: fw * 0.72, y: fh * 0.22)
            )
            lipPath.addCurve(
                to: CGPoint(x: fw * 0.14, y: fh * 0.50),
                control1: CGPoint(x: fw * 0.74, y: fh * 0.86),
                control2: CGPoint(x: fw * 0.26, y: fh * 0.86)
            )
            lipPath.closeSubpath()

            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 6, color: CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0.78, 0.10, 0.26, 0.7])!)
            ctx.setFillColor(red: 0.80, green: 0.12, blue: 0.28, alpha: 0.90)
            ctx.addPath(lipPath)
            ctx.fillPath()
            ctx.restoreGState()

            // Specular highlight glint on lower lip
            ctx.setFillColor(red: 1.0, green: 0.78, blue: 0.84, alpha: 0.55)
            ctx.fillEllipse(in: CGRect(x: fw * 0.38, y: fh * 0.56, width: fw * 0.24, height: fh * 0.14))
        }
        let lipsTex = try VRMTextureLayerStack.makeTexture(from: lipsPNG, device: device, sRGB: true, label: "gloss_lips")

        // 3. Metallic gold 4-point star sticker for left cheek
        let starPNG = try encodePNGData(width: 128, height: 128) { ctx, w, h in
            let cx = CGFloat(w) * 0.5, cy = CGFloat(h) * 0.5
            let outerR = CGFloat(w) * 0.40, innerR = CGFloat(w) * 0.11
            let path = CGMutablePath()
            for i in 0..<8 {
                let angle = CGFloat(i) * .pi / 4.0
                let r = (i % 2 == 0) ? outerR : innerR
                let pt = CGPoint(x: cx + cos(angle) * r, y: cy + sin(angle) * r)
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            path.closeSubpath()
            ctx.setFillColor(red: 1.0, green: 0.84, blue: 0.32, alpha: 1.0)
            ctx.addPath(path)
            ctx.fillPath()
        }
        let starTex = try VRMTextureLayerStack.makeTexture(from: starPNG, device: device, sRGB: true, label: "gold_star")

        // 4. Soft plum eyeshadow sweep along upper eyelid region
        let shadowPNG = try encodePNGData(width: 128, height: 128) { ctx, w, h in
            let colors = [
                CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0.46, 0.20, 0.44, 0.65])!,
                CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0.58, 0.28, 0.52, 0.00])!,
            ] as CFArray
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 1.0])!
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(w) * 0.5, y: CGFloat(h) * 0.32)
            ctx.scaleBy(x: 1.1, y: 0.45)
            ctx.drawRadialGradient(grad, startCenter: .zero, startRadius: 4, endCenter: .zero, endRadius: CGFloat(w) * 0.42, options: [])
            ctx.restoreGState()
        }
        let shadowTex = try VRMTextureLayerStack.makeTexture(from: shadowPNG, device: device, sRGB: true, label: "eyeshadow")

        return [
            VRMTextureLayer(name: "left_blush", texture: blushTex, blendMode: .multiply, opacity: 0.65, landmarkRegion: .leftCheek),
            VRMTextureLayer(name: "right_blush", texture: blushTex, blendMode: .multiply, opacity: 0.65, landmarkRegion: .rightCheek),
            VRMTextureLayer(name: "left_eyeshadow", texture: shadowTex, blendMode: .multiply, opacity: 0.55, landmarkRegion: .leftEye),
            VRMTextureLayer(name: "right_eyeshadow", texture: shadowTex, blendMode: .multiply, opacity: 0.55, landmarkRegion: .rightEye),
            VRMTextureLayer(
                name: "berry_gloss_lips",
                texture: lipsTex,
                blendMode: .normal,
                opacity: 0.88,
                finish: VRMFinishOverride(metallic: 0.48, roughness: 0.12),
                landmarkRegion: .lips
            ),
            VRMTextureLayer(
                name: "cheek_gold_star",
                texture: starTex,
                blendMode: .normal,
                opacity: 0.95,
                finish: VRMFinishOverride(metallic: 0.94, roughness: 0.16),
                landmarkRegion: .leftCheek,
                uvOffset: SIMD2<Float>(0.10, -0.18),
                uvScale: SIMD2<Float>(0.36, 0.36)
            ),
        ]
    }

    // MARK: - Procedural In-Memory GLB Builders (Zero Disk I/O)

    private struct MeshBuilder {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var joints: [SIMD4<UInt16>] = []
        var weights: [SIMD4<Float>] = []
        var indices: [UInt16] = []

        mutating func addBox(
            center: SIMD3<Float>,
            halfExtents: SIMD3<Float>,
            joint: SIMD4<UInt16> = .zero,
            weight: SIMD4<Float> = SIMD4<Float>(1, 0, 0, 0)
        ) {
            let hx = halfExtents.x, hy = halfExtents.y, hz = halfExtents.z
            let faces: [([SIMD3<Float>], SIMD3<Float>)] = [
                ([SIMD3(-hx, -hy, hz), SIMD3(hx, -hy, hz), SIMD3(hx, hy, hz), SIMD3(-hx, hy, hz)], SIMD3(0, 0, 1)),
                ([SIMD3(hx, -hy, -hz), SIMD3(-hx, -hy, -hz), SIMD3(-hx, hy, -hz), SIMD3(hx, hy, -hz)], SIMD3(0, 0, -1)),
                ([SIMD3(hx, -hy, hz), SIMD3(hx, -hy, -hz), SIMD3(hx, hy, -hz), SIMD3(hx, hy, hz)], SIMD3(1, 0, 0)),
                ([SIMD3(-hx, -hy, -hz), SIMD3(-hx, -hy, hz), SIMD3(-hx, hy, hz), SIMD3(-hx, hy, -hz)], SIMD3(-1, 0, 0)),
                ([SIMD3(-hx, hy, hz), SIMD3(hx, hy, hz), SIMD3(hx, hy, -hz), SIMD3(-hx, hy, -hz)], SIMD3(0, 1, 0)),
                ([SIMD3(-hx, -hy, -hz), SIMD3(hx, -hy, -hz), SIMD3(hx, -hy, hz), SIMD3(-hx, -hy, hz)], SIMD3(0, -1, 0)),
            ]
            for (corners, n) in faces {
                let base = UInt16(positions.count)
                let quadUVs: [SIMD2<Float>] = [[0, 1], [1, 1], [1, 0], [0, 0]]
                for (i, c) in corners.enumerated() {
                    positions.append(center + c)
                    normals.append(n)
                    uvs.append(quadUVs[i])
                    joints.append(joint)
                    weights.append(weight)
                }
                indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
            }
        }

        mutating func addTorus(
            center: SIMD3<Float>,
            majorRadius: Float,
            minorRadius: Float,
            axis: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
            majorSegs: Int = 28,
            minorSegs: Int = 10
        ) {
            let up = simd_normalize(axis)
            let ref = abs(up.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
            let right = simd_normalize(simd_cross(up, ref))
            let fwd = simd_cross(right, up)

            let base = positions.count
            for i in 0...majorSegs {
                let theta = Float(i) / Float(majorSegs) * 2.0 * .pi
                let cosT = cos(theta), sinT = sin(theta)
                let radial = right * cosT + fwd * sinT
                let ringCenter = center + radial * majorRadius
                for j in 0...minorSegs {
                    let phi = Float(j) / Float(minorSegs) * 2.0 * .pi
                    let n = simd_normalize(radial * cos(phi) + up * sin(phi))
                    positions.append(ringCenter + n * minorRadius)
                    normals.append(n)
                    uvs.append(SIMD2<Float>(Float(i) / Float(majorSegs), Float(j) / Float(minorSegs)))
                    joints.append(.zero)
                    weights.append(SIMD4<Float>(1, 0, 0, 0))
                }
            }
            let stride = minorSegs + 1
            for i in 0..<majorSegs {
                for j in 0..<minorSegs {
                    let a = UInt16(base + i * stride + j)
                    let b = UInt16(base + (i + 1) * stride + j)
                    let c = UInt16(base + (i + 1) * stride + j + 1)
                    let d = UInt16(base + i * stride + j + 1)
                    indices.append(contentsOf: [a, b, c, a, c, d])
                }
            }
        }

        mutating func addDisc(center: SIMD3<Float>, radius: Float, normalZ: Float, segs: Int = 24) {
            let base = UInt16(positions.count)
            let n = SIMD3<Float>(0, 0, normalZ)
            positions.append(center)
            normals.append(n)
            uvs.append(SIMD2<Float>(0.5, 0.5))
            joints.append(.zero)
            weights.append(SIMD4<Float>(1, 0, 0, 0))
            for i in 0...segs {
                let a = Float(i) / Float(segs) * 2.0 * .pi
                positions.append(center + SIMD3<Float>(cos(a) * radius, sin(a) * radius, 0))
                normals.append(n)
                uvs.append(SIMD2<Float>(0.5 + 0.5 * cos(a), 0.5 + 0.5 * sin(a)))
                joints.append(.zero)
                weights.append(SIMD4<Float>(1, 0, 0, 0))
            }
            for i in 0..<segs {
                if normalZ >= 0 {
                    indices.append(contentsOf: [base, base + UInt16(1 + i), base + UInt16(2 + i)])
                } else {
                    indices.append(contentsOf: [base, base + UInt16(2 + i), base + UInt16(1 + i)])
                }
            }
        }
    }

    private struct GLBPacker {
        var bin = Data()
        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []

        mutating func appendBytes(_ bytes: Data, target: Int? = nil) -> Int {
            while bin.count % 4 != 0 { bin.append(0) }
            let offset = bin.count
            bin.append(bytes)
            var bv: [String: Any] = ["buffer": 0, "byteOffset": offset, "byteLength": bytes.count]
            if let target { bv["target"] = target }
            bufferViews.append(bv)
            return bufferViews.count - 1
        }

        mutating func addVec3(_ values: [SIMD3<Float>], target: Int = 34962) -> Int {
            var bytes = Data(capacity: values.count * 12)
            var mn = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var mx = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for v in values {
                mn = simd_min(mn, v); mx = simd_max(mx, v)
                var x = v.x, y = v.y, z = v.z
                bytes.append(Data(bytes: &x, count: 4))
                bytes.append(Data(bytes: &y, count: 4))
                bytes.append(Data(bytes: &z, count: 4))
            }
            let bv = appendBytes(bytes, target: target)
            accessors.append([
                "bufferView": bv, "componentType": 5126, "count": values.count, "type": "VEC3",
                "min": [mn.x, mn.y, mn.z], "max": [mx.x, mx.y, mx.z],
            ])
            return accessors.count - 1
        }

        mutating func addVec2(_ values: [SIMD2<Float>]) -> Int {
            var bytes = Data(capacity: values.count * 8)
            for v in values {
                var x = v.x, y = v.y
                bytes.append(Data(bytes: &x, count: 4))
                bytes.append(Data(bytes: &y, count: 4))
            }
            let bv = appendBytes(bytes, target: 34962)
            accessors.append(["bufferView": bv, "componentType": 5126, "count": values.count, "type": "VEC2"])
            return accessors.count - 1
        }

        mutating func addJoints(_ values: [SIMD4<UInt16>]) -> Int {
            var bytes = Data(capacity: values.count * 8)
            for v in values {
                var a = v.x, b = v.y, c = v.z, d = v.w
                bytes.append(Data(bytes: &a, count: 2))
                bytes.append(Data(bytes: &b, count: 2))
                bytes.append(Data(bytes: &c, count: 2))
                bytes.append(Data(bytes: &d, count: 2))
            }
            let bv = appendBytes(bytes, target: 34962)
            accessors.append(["bufferView": bv, "componentType": 5123, "count": values.count, "type": "VEC4"])
            return accessors.count - 1
        }

        mutating func addWeights(_ values: [SIMD4<Float>]) -> Int {
            var bytes = Data(capacity: values.count * 16)
            for v in values {
                var a = v.x, b = v.y, c = v.z, d = v.w
                bytes.append(Data(bytes: &a, count: 4))
                bytes.append(Data(bytes: &b, count: 4))
                bytes.append(Data(bytes: &c, count: 4))
                bytes.append(Data(bytes: &d, count: 4))
            }
            let bv = appendBytes(bytes, target: 34962)
            accessors.append(["bufferView": bv, "componentType": 5126, "count": values.count, "type": "VEC4"])
            return accessors.count - 1
        }

        mutating func addIndices(_ values: [UInt16]) -> Int {
            var bytes = Data(capacity: values.count * 2)
            for idx in values {
                var v = idx
                bytes.append(Data(bytes: &v, count: 2))
            }
            let bv = appendBytes(bytes, target: 34963)
            accessors.append(["bufferView": bv, "componentType": 5123, "count": values.count, "type": "SCALAR"])
            return accessors.count - 1
        }

        mutating func addMatrices(_ matrices: [float4x4]) -> Int {
            var bytes = Data(capacity: matrices.count * 64)
            for m in matrices {
                for col in 0..<4 {
                    let c = m[col]
                    var vals: [Float] = [c.x, c.y, c.z, c.w]
                    bytes.append(Data(bytes: &vals, count: 16))
                }
            }
            let bv = appendBytes(bytes, target: nil)
            accessors.append(["bufferView": bv, "componentType": 5126, "count": matrices.count, "type": "MAT4"])
            return accessors.count - 1
        }

        mutating func addPrimitive(_ mb: MeshBuilder, material: Int, skinned: Bool = false) -> [String: Any] {
            var attrs: [String: Any] = [
                "POSITION": addVec3(mb.positions),
                "NORMAL": addVec3(mb.normals),
                "TEXCOORD_0": addVec2(mb.uvs),
            ]
            if skinned {
                attrs["JOINTS_0"] = addJoints(mb.joints)
                attrs["WEIGHTS_0"] = addWeights(mb.weights)
            }
            return [
                "attributes": attrs,
                "indices": addIndices(mb.indices),
                "material": material,
            ]
        }

        func pack(gltf: [String: Any]) throws -> Data {
            var doc = gltf
            var paddedBin = bin
            while paddedBin.count % 4 != 0 { paddedBin.append(0) }
            doc["buffers"] = [["byteLength": paddedBin.count]]
            doc["bufferViews"] = bufferViews
            doc["accessors"] = accessors

            var jsonData = try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])
            while jsonData.count % 4 != 0 { jsonData.append(0x20) }

            let totalLength = UInt32(12 + 8 + jsonData.count + 8 + paddedBin.count)
            var out = Data(capacity: Int(totalLength))
            func appendU32(_ v: UInt32) {
                var le = v.littleEndian
                out.append(Data(bytes: &le, count: 4))
            }
            out.append(contentsOf: [0x67, 0x6C, 0x54, 0x46]) // "glTF"
            appendU32(2)
            appendU32(totalLength)
            appendU32(UInt32(jsonData.count))
            appendU32(0x4E4F534A) // JSON
            out.append(jsonData)
            appendU32(UInt32(paddedBin.count))
            appendU32(0x004E4942) // BIN
            out.append(paddedBin)
            return out
        }
    }

    private static func buildProceduralGlassesGLB(faceForwardZ: Float) throws -> Data {
        var frame = MeshBuilder()
        let eyeSep: Float = 0.036
        let lensR: Float = 0.024
        // Left & right round frames
        frame.addTorus(center: SIMD3<Float>(eyeSep, 0, 0), majorRadius: lensR, minorRadius: 0.0024, axis: SIMD3<Float>(0, 0, 1))
        frame.addTorus(center: SIMD3<Float>(-eyeSep, 0, 0), majorRadius: lensR, minorRadius: 0.0024, axis: SIMD3<Float>(0, 0, 1))
        // Nose bridge
        frame.addBox(center: SIMD3<Float>(0, 0.003, 0), halfExtents: SIMD3<Float>(0.012, 0.0022, 0.0022))
        // Left & right temple arms extending toward ears
        let armLen: Float = 0.095
        frame.addBox(center: SIMD3<Float>(eyeSep + lensR + 0.003, 0.003, -faceForwardZ * armLen * 0.5),
                     halfExtents: SIMD3<Float>(0.0020, 0.0024, armLen * 0.5))
        frame.addBox(center: SIMD3<Float>(-(eyeSep + lensR + 0.003), 0.003, -faceForwardZ * armLen * 0.5),
                     halfExtents: SIMD3<Float>(0.0020, 0.0024, armLen * 0.5))

        var lenses = MeshBuilder()
        lenses.addDisc(center: SIMD3<Float>(eyeSep, 0, 0), radius: lensR - 0.001, normalZ: faceForwardZ)
        lenses.addDisc(center: SIMD3<Float>(-eyeSep, 0, 0), radius: lensR - 0.001, normalZ: faceForwardZ)

        var packer = GLBPacker()
        let framePrim = packer.addPrimitive(frame, material: 0)
        let lensPrim = packer.addPrimitive(lenses, material: 1)

        let gltf: [String: Any] = [
            "asset": ["version": "2.0"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["name": "GlassesRoot", "mesh": 0]],
            "meshes": [["name": "GlassesMesh", "primitives": [framePrim, lensPrim]]],
            "materials": [
                [
                    "name": "GlassesFrame_Gold",
                    "pbrMetallicRoughness": [
                        "baseColorFactor": [0.92, 0.72, 0.28, 1.0],
                        "metallicFactor": 0.9,
                        "roughnessFactor": 0.2,
                    ],
                    "extensions": [
                        "VRMC_materials_mtoon": [
                            "specVersion": "1.0",
                            "shadeColorFactor": [0.55, 0.38, 0.12],
                            "shadingToonyFactor": 0.85,
                        ]
                    ],
                ],
                [
                    "name": "GlassesLens_Tint",
                    "alphaMode": "BLEND",
                    "doubleSided": true,
                    "pbrMetallicRoughness": [
                        "baseColorFactor": [0.12, 0.18, 0.30, 0.42],
                        "metallicFactor": 0.2,
                        "roughnessFactor": 0.1,
                    ],
                    "extensions": [
                        "VRMC_materials_mtoon": [
                            "specVersion": "1.0",
                            "shadeColorFactor": [0.08, 0.12, 0.22],
                            "transparentWithZWrite": false,
                        ]
                    ],
                ],
            ],
        ]
        return try packer.pack(gltf: gltf)
    }

    private static func buildProceduralHaloGLB() throws -> Data {
        var halo = MeshBuilder()
        halo.addTorus(center: .zero, majorRadius: 0.095, minorRadius: 0.0085, axis: SIMD3<Float>(0, 1, 0), majorSegs: 36, minorSegs: 12)
        var packer = GLBPacker()
        let prim = packer.addPrimitive(halo, material: 0)
        let gltf: [String: Any] = [
            "asset": ["version": "2.0"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["name": "HaloRoot", "mesh": 0]],
            "meshes": [["name": "HaloMesh", "primitives": [prim]]],
            "materials": [
                [
                    "name": "Halo_EmissiveGold",
                    "pbrMetallicRoughness": ["baseColorFactor": [1.0, 0.88, 0.42, 1.0]],
                    "emissiveFactor": [0.65, 0.50, 0.12],
                    "extensions": [
                        "VRMC_materials_mtoon": [
                            "specVersion": "1.0",
                            "shadeColorFactor": [0.90, 0.72, 0.22],
                        ]
                    ],
                ]
            ],
        ]
        return try packer.pack(gltf: gltf)
    }

    private static func buildProceduralSkinnedMantleGLB(
        upperChestPos: SIMD3<Float>,
        neckPos: SIMD3<Float>,
        lArmPos: SIMD3<Float>,
        rArmPos: SIMD3<Float>,
        faceForwardZ: Float
    ) throws -> Data {
        // 3 skinned joints matching host humanoid names in T-pose: upperChest (0), leftUpperArm (1), rightUpperArm (2)
        let jointWorldPositions = [upperChestPos, lArmPos, rArmPos]
        var ibms: [float4x4] = []
        for pos in jointWorldPositions {
            var m = matrix_identity_float4x4
            m.columns.3 = SIMD4<Float>(-pos.x, -pos.y, -pos.z, 1)
            ibms.append(m)
        }

        // Build a single continuous watertight multi-ring shoulder mantle (shared vertices across rings)
        // plus matching gold bottom hem trim and front collar clasp.
        var mantle = MeshBuilder()
        var trim = MeshBuilder()
        let ringSegs = 36
        let yTop = neckPos.y - 0.012
        let yUpper = upperChestPos.y + 0.040
        let yMid = upperChestPos.y - 0.035
        let yBot = upperChestPos.y - 0.125

        struct RingSpec {
            let y: Float
            let rx: Float
            let rz: Float
            let shoulderW: Float
            let notch: Float
        }

        let rings: [RingSpec] = [
            RingSpec(y: yTop,   rx: 0.088, rz: 0.080, shoulderW: 0.00, notch: 0.030),
            RingSpec(y: yUpper, rx: 0.160, rz: 0.118, shoulderW: 0.22, notch: 0.015),
            RingSpec(y: yMid,   rx: 0.195, rz: 0.134, shoulderW: 0.36, notch: 0.000),
            RingSpec(y: yBot,   rx: 0.215, rz: 0.146, shoulderW: 0.42, notch: 0.000),
        ]

        func appendContinuousRings(into mb: inout MeshBuilder, specs: [RingSpec]) {
            let base = mb.positions.count
            let stride = ringSegs + 1
            for (rIdx, spec) in specs.enumerated() {
                let vCoord = Float(rIdx) / Float(max(1, specs.count - 1))
                for i in 0...ringSegs {
                    let a = Float(i) / Float(ringSegs) * 2.0 * .pi
                    let cx = cos(a), sz = sin(a)
                    let frontNotch = max(0, sz * faceForwardZ)
                    let p = SIMD3<Float>(
                        upperChestPos.x + cx * spec.rx,
                        spec.y - frontNotch * spec.notch,
                        upperChestPos.z + sz * spec.rz
                    )
                    let n = simd_normalize(SIMD3<Float>(cx / spec.rx, 0.22, sz / spec.rz))

                    let sideBias = max(0, abs(cx) - 0.55) / 0.45 * spec.shoulderW
                    let j: SIMD4<UInt16> = cx >= 0 ? SIMD4<UInt16>(0, 1, 0, 0) : SIMD4<UInt16>(0, 2, 0, 0)
                    let w = SIMD4<Float>(1.0 - sideBias, sideBias, 0, 0)

                    mb.positions.append(p)
                    mb.normals.append(n)
                    mb.uvs.append(SIMD2<Float>(Float(i) / Float(ringSegs), vCoord))
                    mb.joints.append(j)
                    mb.weights.append(w)
                }
            }
            for rIdx in 0..<(specs.count - 1) {
                for i in 0..<ringSegs {
                    let a = UInt16(base + rIdx * stride + i)
                    let b = UInt16(base + rIdx * stride + i + 1)
                    let c = UInt16(base + (rIdx + 1) * stride + i + 1)
                    let d = UInt16(base + (rIdx + 1) * stride + i)
                    mb.indices.append(contentsOf: [a, b, c, a, c, d])
                }
            }
        }

        appendContinuousRings(into: &mantle, specs: rings)
        // Gold bottom hem trim with identical shoulderW so it hugs the bottom edge cleanly
        appendContinuousRings(into: &trim, specs: [
            RingSpec(y: yBot + 0.012, rx: 0.217, rz: 0.148, shoulderW: 0.42, notch: 0),
            RingSpec(y: yBot - 0.010, rx: 0.220, rz: 0.151, shoulderW: 0.42, notch: 0),
        ])
        // Gold clasp at collar front
        trim.addBox(
            center: SIMD3<Float>(upperChestPos.x, yTop - 0.040, upperChestPos.z + faceForwardZ * 0.104),
            halfExtents: SIMD3<Float>(0.022, 0.016, 0.009),
            joint: SIMD4<UInt16>(0, 0, 0, 0),
            weight: SIMD4<Float>(1, 0, 0, 0)
        )

        var packer = GLBPacker()
        let mantlePrim = packer.addPrimitive(mantle, material: 0, skinned: true)
        let trimPrim = packer.addPrimitive(trim, material: 1, skinned: true)
        let ibmAcc = packer.addMatrices(ibms)

        let gltf: [String: Any] = [
            "asset": ["version": "2.0"],
            "scene": 0,
            "scenes": [["nodes": [0, 3]]],
            "nodes": [
                ["name": "upperChest", "translation": [upperChestPos.x, upperChestPos.y, upperChestPos.z], "children": [1, 2]],
                ["name": "leftUpperArm", "translation": [lArmPos.x - upperChestPos.x, lArmPos.y - upperChestPos.y, lArmPos.z - upperChestPos.z]],
                ["name": "rightUpperArm", "translation": [rArmPos.x - upperChestPos.x, rArmPos.y - upperChestPos.y, rArmPos.z - upperChestPos.z]],
                ["name": "MantleMeshNode", "mesh": 0, "skin": 0],
            ],
            "skins": [[
                "name": "MantleSkin",
                "joints": [0, 1, 2],
                "inverseBindMatrices": ibmAcc,
            ]],
            "meshes": [[
                "name": "RoyalMantle",
                "primitives": [mantlePrim, trimPrim],
            ]],
            "materials": [
                [
                    "name": "Mantle_CrimsonVelvet",
                    "doubleSided": true,
                    "pbrMetallicRoughness": ["baseColorFactor": [0.58, 0.10, 0.18, 1.0]],
                    "extensions": [
                        "VRMC_materials_mtoon": [
                            "specVersion": "1.0",
                            "shadeColorFactor": [0.28, 0.04, 0.09],
                            "shadingToonyFactor": 0.8,
                        ]
                    ],
                ],
                [
                    "name": "Mantle_GoldTrim",
                    "doubleSided": true,
                    "pbrMetallicRoughness": ["baseColorFactor": [0.95, 0.78, 0.30, 1.0]],
                    "extensions": [
                        "VRMC_materials_mtoon": [
                            "specVersion": "1.0",
                            "shadeColorFactor": [0.60, 0.44, 0.12],
                            "shadingToonyFactor": 0.85,
                        ]
                    ],
                ],
            ],
            "extensions": [
                "VRMC_vrm": [
                    "specVersion": "1.0",
                    "meta": ["name": "RoyalMantle", "licenseUrl": "https://vrm.dev/licenses/1.0/"],
                    "humanoid": [
                        "humanBones": [
                            "upperChest": ["node": 0],
                            "leftUpperArm": ["node": 1],
                            "rightUpperArm": ["node": 2],
                        ]
                    ],
                ]
            ],
        ]
        return try packer.pack(gltf: gltf)
    }

    private static func buildProceduralSpringBoneRibbonsGLB(
        anchorOffset: SIMD3<Float>,
        faceForwardZ: Float
    ) throws -> Data {
        // Two 5-joint SpringBone side-ribbon streamers hanging from gold hair clips on both sides of the head
        let segLen: Float = 0.072
        let jointsPerChain = 5
        var nodes: [[String: Any]] = []
        var meshes: [[String: Any]] = []
        var packer = GLBPacker()

        // Node 0: root anchor
        nodes.append([
            "name": "RibbonRoot",
            "translation": [anchorOffset.x, anchorOffset.y, anchorOffset.z],
            "children": [1, 1 + jointsPerChain],
        ])

        // Root node mesh: gold bow knot + first downward ribbon segment starting right at the pivot
        var rootMesh = MeshBuilder()
        rootMesh.addBox(center: SIMD3<Float>(0, -segLen * 0.5, 0), halfExtents: SIMD3<Float>(0.020, segLen * 0.52, 0.005))
        let rootSegPrim = packer.addPrimitive(rootMesh, material: 0)

        var bowMesh = MeshBuilder()
        bowMesh.addBox(center: SIMD3<Float>(0, 0, 0), halfExtents: SIMD3<Float>(0.032, 0.018, 0.015))
        let bowPrim = packer.addPrimitive(bowMesh, material: 1)
        meshes.append(["name": "RibbonSegment", "primitives": [rootSegPrim]])
        meshes.append(["name": "RibbonRootWithBow", "primitives": [rootSegPrim, bowPrim]])

        var springs: [[String: Any]] = []
        let sides: [(String, Float)] = [("LeftRibbon", 0.118), ("RightRibbon", -0.118)]
        for (sideIdx, (sideName, xOff)) in sides.enumerated() {
            let baseNode = 1 + sideIdx * jointsPerChain
            var jointEntries: [[String: Any]] = []
            for j in 0..<jointsPerChain {
                let nodeIdx = baseNode + j
                var nodeDict: [String: Any] = ["name": "\(sideName)_\(j)"]
                if j == 0 {
                    nodeDict["translation"] = [xOff, 0.0, -faceForwardZ * 0.01]
                    nodeDict["mesh"] = 1
                } else {
                    nodeDict["translation"] = [0.0, -segLen, 0.0]
                    if j < jointsPerChain - 1 {
                        nodeDict["mesh"] = 0
                    }
                }
                if j < jointsPerChain - 1 {
                    nodeDict["children"] = [nodeIdx + 1]
                }
                nodes.append(nodeDict)
                jointEntries.append([
                    "node": nodeIdx,
                    "hitRadius": 0.018,
                    "stiffness": 0.20,
                    "gravityPower": 0.75,
                    "gravityDir": [0.0, -1.0, 0.0],
                    "dragForce": 0.15,
                ])
            }
            springs.append([
                "name": sideName,
                "joints": jointEntries,
            ])
        }

        let gltf: [String: Any] = [
            "asset": ["version": "2.0"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": nodes,
            "meshes": meshes,
            "materials": [
                [
                    "name": "Ribbon_AzureSilk",
                    "doubleSided": true,
                    "pbrMetallicRoughness": ["baseColorFactor": [0.18, 0.56, 0.96, 1.0]],
                    "extensions": [
                        "VRMC_materials_mtoon": [
                            "specVersion": "1.0",
                            "shadeColorFactor": [0.07, 0.26, 0.62],
                            "shadingToonyFactor": 0.85,
                        ]
                    ],
                ],
                [
                    "name": "Ribbon_GoldKnot",
                    "pbrMetallicRoughness": ["baseColorFactor": [0.98, 0.82, 0.32, 1.0]],
                    "extensions": [
                        "VRMC_materials_mtoon": [
                            "specVersion": "1.0",
                            "shadeColorFactor": [0.65, 0.48, 0.14],
                        ]
                    ],
                ],
            ],
            "extensions": [
                "VRMC_springBone": [
                    "specVersion": "1.0",
                    "springs": springs,
                ]
            ],
        ]
        return try packer.pack(gltf: gltf)
    }
}
