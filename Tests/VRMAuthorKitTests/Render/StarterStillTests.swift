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
import XCTest
@testable import VRMAuthorKit

/// Pixel acceptance on the locked QA stills of the female starter. Skips
/// without `vrm-author-render` or a Metal device. With
/// `VRM_AUTHOR_STILLS_OUT` set, every rendered still is also copied to
/// `<dir>/<scenario>__vrm-author-female.png` for the comparison set.
final class StarterStillTests: XCTestCase {
    private var project: TestProject!
    private var avatar: CompiledAvatar!
    private var attachments: TemplateAttachments!
    private var adapter: VRMAuthorRenderAdapter!
    private var file: URL!
    private var data: Data!

    override func setUpWithError() throws {
        guard let binary = RenderPackTests.rendererBinary else { throw XCTSkip("vrm-author-render is not built next to the test bundle") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device is available on this host.") }
        let env = [VRMAuthorRenderLocator.environmentKey: binary.path]
        adapter = VRMAuthorRenderAdapter(executableURL: nil, environment: env)
        project = try TestProject.make(pack: NativeAnimeFixture.pack, registry: TestProject.registry(render: adapter), env: env)
        let recipe = try NativeAnimeStarters.starterRecipe(base: .female, registry: TemplateRegistry.standard())
        (avatar, attachments) = try NativeAnimeFixture.pack.compileWithAttachments(recipe, seed: NativeAnimeStarters.seed)
        data = try GLBWriter.write(avatar).data
        file = URL(fileURLWithPath: project.path("female.vrm"))
        try data.write(to: file)
    }

    override func tearDownWithError() throws { project?.cleanup() }

    private func still(_ id: String) throws -> (width: Int, height: Int, rgba: [UInt8]) {
        let scenario = try XCTUnwrap(QAPins.renderScenarios().first { $0.id == id })
        let out = URL(fileURLWithPath: project.path(id))
        let artifacts = try XCTUnwrap(try adapter.render(scenario: scenario, file: file, data: data, outputDirectory: out, context: project.context))
        let png = try Data(contentsOf: URL(fileURLWithPath: artifacts[0].path))
        if let dir = ProcessInfo.processInfo.environment["VRM_AUTHOR_STILLS_OUT"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(id)__vrm-author-female.png"))
        }
        return try RenderPackTests.rgbaPixels(png)
    }

    /// Projects a world point through a locked scenario camera (perspective,
    /// fov 30°, square image) to pixel coordinates.
    private func project(_ p: SIMD3<Float>, scenario id: String, size: Int) throws -> SIMD2<Float> {
        let scenario = try XCTUnwrap(QAPins.renderScenarios().first { $0.id == id })
        let cam = scenario.configuration["camera"]!
        let eye = SIMD3<Float>(cam["position"]!.array!.map { Float($0.number!) })
        let target = SIMD3<Float>(cam["target"]!.array!.map { Float($0.number!) })
        let f = V3.normalize(target - eye)
        let r = V3.normalize(V3.cross(f, SIMD3(0, 1, 0)))
        let u = V3.cross(r, f)
        let d = p - eye
        let x = V3.dot(d, r), y = V3.dot(d, u), z = V3.dot(d, f)
        let scale = 1 / tan(15 * Float.pi / 180)
        let ndcX = x / z * scale, ndcY = y / z * scale
        return SIMD2((ndcX * 0.5 + 0.5) * Float(size), (0.5 - ndcY * 0.5) * Float(size))
    }

    private func luminance(_ img: (width: Int, height: Int, rgba: [UInt8]), _ x: Int, _ y: Int) -> Float {
        let i = (y * img.width + x) * 4
        return (0.2126 * Float(img.rgba[i]) + 0.7152 * Float(img.rgba[i + 1]) + 0.0722 * Float(img.rgba[i + 2])) / 255
    }

    private func hue(_ img: (width: Int, height: Int, rgba: [UInt8]), _ x: Int, _ y: Int) -> (hue: Float, sat: Float, lum: Float) {
        let i = (y * img.width + x) * 4
        let r = Float(img.rgba[i]) / 255, g = Float(img.rgba[i + 1]) / 255, b = Float(img.rgba[i + 2]) / 255
        let hi = max(r, g, b), lo = min(r, g, b), c = hi - lo
        var h: Float = 0
        if c > 1e-4 {
            if hi == r { h = ((g - b) / c).truncatingRemainder(dividingBy: 6) } else if hi == g { h = (b - r) / c + 2 } else { h = (r - g) / c + 4 }
            h *= 60
            if h < 0 { h += 360 }
        }
        return (h, hi > 0 ? c / hi : 0, luminance(img, x, y))
    }

    private func hueOf(_ linear: SIMD3<Float>) -> Float {
        func byte(_ c: Float) -> UInt8 { UInt8(min(max(ColourTransfer.linearToSrgb(Double(c)) * 255, 0), 255).rounded()) }
        let img = (width: 1, height: 1, rgba: [byte(linear.x), byte(linear.y), byte(linear.z), 255])
        return hue(img, 0, 0).hue
    }

    func testFrontCollarShowsNoDarkNecklineBand() throws {
        let img = try still("visual.front")
        let neck = attachments.jointWorldPositions[.neck]!, head = attachments.jointWorldPositions[.head]!
        let top = try project(head, scenario: "visual.front", size: img.width)
        let bottom = try project(neck - SIMD3(0, 0.04, 0), scenario: "visual.front", size: img.width)
        let left = try project(neck - SIMD3(0.04, 0, 0), scenario: "visual.front", size: img.width)
        let right = try project(neck + SIMD3(0.04, 0, 0), scenario: "visual.front", size: img.width)
        var run = 0, worst = 0
        for y in Int(top.y)...Int(bottom.y) {
            var sum: Float = 0
            for x in Int(left.x)...Int(right.x) { sum += luminance(img, x, y) }
            let mean = sum / Float(Int(right.x) - Int(left.x) + 1)
            run = mean < 0.15 ? run + 1 : 0
            worst = max(worst, run)
        }
        XCTAssertLessThan(worst, 8, "a \(worst)-row dark band sits inside the neckline box")
    }

    func testThreeQuarterShowsASkirtHemBand() throws {
        let img = try still("visual.threeQuarter")
        let skirt = try XCTUnwrap(avatar.meshes.first { mesh in mesh.id.hasPrefix("mesh:garment:") && attachments.garments.contains { g in g.meshId == mesh.id && g.preset == "skirt-v1" } }).primitives[0]
        let hemY = skirt.positions.map(\.y).min()!
        let centre = try project(SIMD3(0, hemY, 0), scenario: "visual.threeQuarter", size: img.width)
        let halfWidth = 40
        func rowMean(_ y: Int) -> Float { (Int(centre.x) - halfWidth...Int(centre.x) + halfWidth).reduce(Float(0)) { $0 + luminance(img, $1, y) } / Float(2 * halfWidth + 1) }
        let above = (Int(centre.y) - 30..<Int(centre.y) - 10).map(rowMean).reduce(0, +) / 20
        var run = 0, best = 0
        for y in (Int(centre.y) - 12)...(Int(centre.y) + 12) {
            run = rowMean(y) < above * 0.90 ? run + 1 : 0
            best = max(best, run)
        }
        XCTAssertGreaterThanOrEqual(best, 5, "no ≥5-row band darker than the cloth above the hem (best run \(best))")
    }

    func testCrownShowsNoScalpThroughTheHair() throws {
        let hairHue = hueOf(NativeAnimeTextures.rgb(NativeAnimeFixture.pack.defaults.hair[0].texture.baseColour))
        let skinHue = hueOf(MaterialRoleDefaults.baseColour(for: .faceSkin))
        for id in ["visual.front", "visual.threeQuarter"] {
            let img = try still(id)
            let c = attachments.headCenter, R = attachments.headRadii.y
            let lo = try project(c + SIMD3(-0.8 * R, 0.70 * R, 0), scenario: id, size: img.width)
            let hi = try project(c + SIMD3(0.8 * R, 1.10 * R, 0), scenario: id, size: img.width)
            var hair = 0, skin = 0
            for y in Int(hi.y)...Int(lo.y) {
                for x in Int(min(lo.x, hi.x))...Int(max(lo.x, hi.x)) {
                    let p = hue(img, x, y)
                    guard p.sat > 0.12 else { continue }
                    if abs(p.hue - hairHue) < 14 && p.lum < 0.55 { hair += 1 } else if abs(p.hue - skinHue) < 10 && p.lum > 0.55 { skin += 1 }
                }
            }
            XCTAssertGreaterThan(hair, 500, "\(id): hair silhouette found")
            XCTAssertLessThan(Double(skin) / Double(hair + skin), 0.02, "\(id): \(skin) scalp pixels among \(hair) hair pixels")
        }
    }

    func testWritesEveryStillForTheComparisonSet() throws {
        guard ProcessInfo.processInfo.environment["VRM_AUTHOR_STILLS_OUT"] != nil else { throw XCTSkip("set VRM_AUTHOR_STILLS_OUT to refresh the comparison stills") }
        for scenario in QAPins.renderScenarios() where scenario.kind == "visual" || scenario.kind == "expression" {
            let img = try still(scenario.id)
            XCTAssertEqual(img.width, 1024, scenario.id)
        }
    }
}
