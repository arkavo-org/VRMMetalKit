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
import QuartzCore
import simd
import VRMMetalKit

/// Live-host performance: cycles bundled VRMA clips with a short
/// spherical-linear crossfade, blinks on the render thread, and never
/// touches look-at (the host keeps `target = .camera`).
///
/// This is the compositor loop, not the offscreen GPU bench. The bench
/// still measures preferred-vs-host submit on its own model; compositor
/// sampling after that includes this director, so animation cost shows
/// up there.
final class AvatarDirector: @unchecked Sendable {

    private struct Item {
        let name: String
        let clip: AnimationClip
    }

    private let playlist: [Item]
    private var index = 0
    private var time: Float = 0
    private var fading = false
    private var fade: Float = 0
    private var nextIndex = 1

    private let fadeDuration: Float = 0.75

    private var blinkWait: Float
    private var blinkT: Float = -1
    private var blinkDouble = false
    private let blinkClose: Float = 0.07
    private let blinkOpen: Float = 0.12

    init(model: VRMModel) {
        var loaded: [Item] = []
        for name in Self.clipNames {
            let url = Bundle.main.url(forResource: name, withExtension: "vrma")
                ?? Bundle.main.url(forResource: "\(name).vrma", withExtension: nil)
            guard let url else {
                NSLog("[AvatarDirector] missing \(name).vrma")
                continue
            }
            do {
                let clip = try VRMAnimationLoader.loadVRMA(from: url, model: model)
                guard clip.duration > 0.2 else { continue }
                loaded.append(Item(name: name, clip: clip))
                NSLog("[AvatarDirector] loaded \(name) (%.2fs, %d joints)",
                      Double(clip.duration), clip.jointTracks.count)
            } catch {
                NSLog("[AvatarDirector] failed \(name): \(error)")
            }
        }
        self.playlist = loaded
        self.nextIndex = loaded.count > 1 ? 1 : 0
        self.blinkWait = Self.rollBlinkWait()
        if loaded.isEmpty {
            NSLog("[AvatarDirector] no clips — T-pose only")
        } else {
            NSLog("[AvatarDirector] playlist \(loaded.map(\.name).joined(separator: " → "))")
        }
    }

    var clipCount: Int { playlist.count }

    /// Standing / facing-the-viewer clips. Locomotion is in-place
    /// (`applyRootMotion` is never on).
    private static let clipNames = [
        "Neutral_Idle",
        "LookAround",
        "VRoid_Greeting",
        "Relax",
        "Thinking",
        "Action_Greeting",
        "Neutral_Idle2",
        "VRMA_01",
    ]

    func update(deltaTime: Float, model: VRMModel, expressions: VRMExpressionController?) {
        guard !playlist.isEmpty else {
            tickBlink(deltaTime: deltaTime, expressions: expressions)
            return
        }

        let current = playlist[index]
        time += deltaTime

        if !fading {
            let startFadeAt = max(0, current.clip.duration - fadeDuration)
            if time >= startFadeAt, playlist.count > 1 {
                fading = true
                fade = 0
                nextIndex = (index + 1) % playlist.count
            }
        }

        if fading {
            fade = min(1, fade + deltaTime / fadeDuration)
        }

        let fromTime = min(time, current.clip.duration)
        if fading {
            let incoming = playlist[nextIndex]
            let toTime = min(fade * fadeDuration, incoming.clip.duration)
            writeBlend(
                from: current.clip, fromTime: fromTime,
                to: incoming.clip, toTime: toTime,
                alpha: smoothstep(fade),
                model: model,
                expressions: expressions)
            if fade >= 1 {
                index = nextIndex
                time = fadeDuration
                fading = false
                fade = 0
            }
        } else {
            writeBlend(
                from: current.clip, fromTime: fromTime,
                to: nil, toTime: 0,
                alpha: 0,
                model: model,
                expressions: expressions)
        }

        tickBlink(deltaTime: deltaTime, expressions: expressions)
    }

    // MARK: - Pose

    private func writeBlend(
        from: AnimationClip,
        fromTime: Float,
        to: AnimationClip?,
        toTime: Float,
        alpha: Float,
        model: VRMModel,
        expressions: VRMExpressionController?
    ) {
        model.withLock {
            let fromPose = sample(clip: from, time: fromTime, model: model)
            let toPose = to.map { sample(clip: $0, time: toTime, model: model) }

            for (i, node) in model.nodes.enumerated() {
                if let incoming = toPose {
                    node.rotation = slerpShortest(
                        fromPose.rotation[i] ?? node.initialRotation,
                        incoming.rotation[i] ?? node.initialRotation,
                        alpha)
                    if let a = fromPose.translation[i], let b = incoming.translation[i] {
                        node.translation = mix(a, b, alpha)
                    } else if alpha < 0.5, let a = fromPose.translation[i] {
                        node.translation = a
                    } else if let b = incoming.translation[i] {
                        node.translation = b
                    }
                    if let a = fromPose.scale[i], let b = incoming.scale[i] {
                        node.scale = mix(a, b, alpha)
                    }
                } else {
                    if let r = fromPose.rotation[i] { node.rotation = r }
                    if let t = fromPose.translation[i] { node.translation = t }
                    if let s = fromPose.scale[i] { node.scale = s }
                }
                node.updateLocalMatrix()
            }

            model.updateNodeTransforms()
        }

        applyMorphs(from: from, fromTime: fromTime, to: to, toTime: toTime,
                    alpha: to == nil ? 0 : alpha, expressions: expressions)
    }

    private struct SampledPose {
        var rotation: [simd_quatf?]
        var translation: [SIMD3<Float>?]
        var scale: [SIMD3<Float>?]
    }

    private func sample(clip: AnimationClip, time: Float, model: VRMModel) -> SampledPose {
        var pose = SampledPose(
            rotation: Array(repeating: nil, count: model.nodes.count),
            translation: Array(repeating: nil, count: model.nodes.count),
            scale: Array(repeating: nil, count: model.nodes.count))
        for track in clip.jointTracks {
            guard let nodeIndex = model.humanoid?.getBoneNode(track.bone),
                  nodeIndex >= 0, nodeIndex < model.nodes.count else { continue }
            let s = track.sample(at: time)
            pose.rotation[nodeIndex] = s.rotation
            if track.bone != .hips {
                pose.translation[nodeIndex] = s.translation
            }
            pose.scale[nodeIndex] = s.scale
        }
        for track in clip.nodeTracks {
            guard let node = model.findNodeByNormalizedName(track.nodeNameNormalized),
                  let i = model.nodes.firstIndex(where: { $0 === node }) else { continue }
            let s = track.sample(at: time)
            pose.rotation[i] = s.rotation ?? pose.rotation[i]
            pose.translation[i] = s.translation ?? pose.translation[i]
            pose.scale[i] = s.scale ?? pose.scale[i]
        }
        return pose
    }

    private func applyMorphs(
        from: AnimationClip,
        fromTime: Float,
        to: AnimationClip?,
        toTime: Float,
        alpha: Float,
        expressions: VRMExpressionController?
    ) {
        guard let expressions else { return }
        var weights: [String: Float] = [:]
        for track in from.morphTracks {
            weights[track.key] = track.sample(at: fromTime)
        }
        for track in from.expressionTracks {
            weights[track.expression.rawValue] = track.sample(at: fromTime)
        }
        if let to {
            var incoming: [String: Float] = [:]
            for track in to.morphTracks {
                incoming[track.key] = track.sample(at: toTime)
            }
            for track in to.expressionTracks {
                incoming[track.expression.rawValue] = track.sample(at: toTime)
            }
            var keys = Set(weights.keys)
            keys.formUnion(incoming.keys)
            for key in keys {
                weights[key] = mix(weights[key] ?? 0, incoming[key] ?? 0, alpha)
            }
        }
        for (key, weight) in weights {
            if let preset = VRMExpressionPreset(rawValue: key) {
                if preset == .blink { continue }
                expressions.setExpressionWeight(preset, weight: weight)
            } else {
                expressions.setCustomExpressionWeight(key, weight: weight)
            }
        }
    }

    // MARK: - Blink

    private func tickBlink(deltaTime: Float, expressions: VRMExpressionController?) {
        guard let expressions else { return }
        if blinkT < 0 {
            blinkWait -= deltaTime
            if blinkWait <= 0 {
                blinkT = 0
                blinkDouble = Float.random(in: 0...1) < 0.18
            }
            expressions.setExpressionWeight(.blink, weight: 0)
            return
        }

        blinkT += deltaTime
        let close = blinkClose
        let open = blinkOpen
        let span = close + open
        let cycleT: Float
        if blinkDouble, blinkT > span + 0.06 {
            cycleT = blinkT - span - 0.06
            if cycleT >= span {
                finishBlink(expressions)
                return
            }
        } else if !blinkDouble, blinkT >= span {
            finishBlink(expressions)
            return
        } else {
            cycleT = blinkT
        }

        let weight: Float
        if cycleT < close {
            weight = smoothstep(cycleT / close)
        } else {
            weight = 1 - smoothstep((cycleT - close) / open)
        }
        expressions.setExpressionWeight(.blink, weight: weight)
    }

    private func finishBlink(_ expressions: VRMExpressionController) {
        expressions.setExpressionWeight(.blink, weight: 0)
        blinkT = -1
        blinkWait = Self.rollBlinkWait()
        blinkDouble = false
    }

    private static func rollBlinkWait() -> Float {
        Float.random(in: 2.2...5.4)
    }

    // MARK: - Math

    private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        a + (b - a) * t
    }

    private func mix(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * t
    }

    private func smoothstep(_ t: Float) -> Float {
        let x = simd_clamp(t, 0, 1)
        return x * x * (3 - 2 * x)
    }

    private func slerpShortest(_ a: simd_quatf, _ b: simd_quatf, _ t: Float) -> simd_quatf {
        var qb = b
        if simd_dot(a.vector, b.vector) < 0 {
            qb = simd_quatf(ix: -b.imag.x, iy: -b.imag.y, iz: -b.imag.z, r: -b.real)
        }
        return simd_slerp(a, qb, t)
    }
}
