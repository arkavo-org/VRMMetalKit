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

import MetalKit

// MARK: - MTKViewDelegate

extension VRMRenderer: MTKViewDelegate {
    /// `MTKViewDelegate` hook called by the view when its drawable resizes.
    ///
    /// Recomputes ``projectionMatrix`` for the new aspect ratio using a 60°
    /// vertical field of view and the renderer's default near/far planes
    /// (0.1 / 100.0). You typically don't call this directly — `MTKView`
    /// invokes it whenever the backing layer's drawable size changes.
    ///
    /// - Parameters:
    ///   - view: The `MTKView` whose drawable size changed.
    ///   - size: The new drawable size in pixels.
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        let aspect = Float(size.width / size.height)
        projectionMatrix = makePerspective(fovyRadians: .pi / 3, aspectRatio: aspect, nearZ: 0.1, farZ: 100.0)
    }

    /// `MTKViewDelegate` per-frame draw hook.
    ///
    /// Creates a command buffer from the renderer's `commandQueue`, encodes the
    /// frame via ``draw(in:commandBuffer:renderPassDescriptor:)``, presents the
    /// view's `currentDrawable`, and commits. Installs a completion handler
    /// that logs Metal command-buffer errors (and periodic success stats for
    /// large models) to help diagnose GPU failures.
    ///
    /// You typically don't call this directly — `MTKView` invokes it once per
    /// frame on the main thread. If `currentRenderPassDescriptor` or the
    /// command buffer cannot be obtained, the frame is skipped silently.
    ///
    /// - Parameter view: The `MTKView` driving the render loop.
    public func draw(in view: MTKView) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let descriptor = view.currentRenderPassDescriptor else {
            return
        }

        draw(in: view, commandBuffer: commandBuffer, renderPassDescriptor: descriptor)

        if let drawable = view.currentDrawable {
            commandBuffer.present(drawable)
        }

        // Add comprehensive error handler for debugging
        commandBuffer.addCompletedHandler { [weak self] cb in
            if cb.status == .error {
                vrmLog("[VRMRenderer] ❌ METAL ERROR: Command buffer failed!")
                if let error = cb.error {
                    vrmLog("[VRMRenderer] ❌ Error details: \(error)")
                }
                // Log additional debug info
                if let model = self?.model {
                    var totalPrimitives = 0
                    var maxMorphs = 0
                    for mesh in model.meshes {
                        totalPrimitives += mesh.primitives.count
                        for prim in mesh.primitives {
                            maxMorphs = max(maxMorphs, prim.morphTargets.count)
                        }
                    }
                    vrmLog("[VRMRenderer] ❌ Model stats: \(totalPrimitives) primitives, max \(maxMorphs) morphs per primitive")
                }
            } else if cb.status == .completed {
                // Success - log occasionally for complex models
                if let frameCounter = self?.frameCounter, frameCounter % 300 == 0 {
                    if let model = self?.model {
                        var totalPrimitives = 0
                        for mesh in model.meshes {
                            totalPrimitives += mesh.primitives.count
                        }
                        if totalPrimitives > 50 {
                            vrmLog("[VRMRenderer] ✅ Frame \(frameCounter): Successfully rendered \(totalPrimitives) primitives")
                        }
                    }
                }
            }
        }

        commandBuffer.commit()
    }
}

// MARK: - SpringBone Debug Controls

extension VRMRenderer {
    /// Requests a spring-bone simulation reset.
    ///
    /// In the current GPU spring-bone pipeline the simulation state is
    /// (re)initialized automatically when a model is loaded, so this call is a
    /// no-op other than emitting a diagnostic log line. It exists as a stable
    /// entry point for callers that previously drove CPU spring-bone resets
    /// and may be wired back up if an explicit mid-session reset is needed.
    public func resetSpringBone() {
        // GPU system resets automatically on model load
        vrmLog("[VRMRenderer] SpringBone reset (GPU system resets on model load)")
    }

    /// Applies temporary gravity and/or wind overrides to the spring-bone
    /// simulation for a fixed duration.
    ///
    /// Both inputs are optional; pass `nil` to leave that channel untouched
    /// for this call. While the timer is active the supplied values override
    /// ``VRMModel/springBoneGlobalParams``'s `gravity` (an additive external
    /// force, VRMC_springBone-1.0 `model.ExternalForce`) and the wind
    /// direction/amplitude derived from `wind`. When the timer elapses the
    /// renderer restores the external force to its default zero and clears any
    /// wind amplitude that was set via this call.
    ///
    /// Use this to drive transient effects such as gusts, impacts, or jump
    /// reactions on hair and clothing without permanently mutating the spring
    /// configuration.
    ///
    /// - Parameters:
    ///   - gravity: Temporary additive external force in world space (m/s²),
    ///     applied on top of per-joint gravity, or `nil` to leave it unchanged.
    ///   - wind: Temporary wind vector; its direction sets the wind direction
    ///     and its length sets the wind amplitude. Pass `nil` to leave wind
    ///     unchanged.
    ///   - duration: How long, in seconds, the overrides remain active before
    ///     reverting. Defaults to `1.0`.
    public func applySpringBoneForce(gravity: SIMD3<Float>? = nil, wind: SIMD3<Float>? = nil, duration: Float = 1.0) {
        if let gravity = gravity {
            temporaryGravity = gravity
        }
        if let wind = wind {
            temporaryWind = wind
        }
        forceTimer = duration
    }

    func updateSpringBoneForces(deltaTime: Float) {
        // Bug #11: feed character locomotion velocity into the spring-bone
        // predict kernel each frame so hair/clothing trails behind movement.
        model?.springBoneGlobalParams?.externalVelocity = characterVelocity

        // Apply temporary forces if timer is active
        if forceTimer > 0 {
            if let gravity = temporaryGravity {
                model?.springBoneGlobalParams?.gravity = gravity
            }
            if let wind = temporaryWind {
                model?.springBoneGlobalParams?.windDirection = simd_normalize(wind)
                model?.springBoneGlobalParams?.windAmplitude = simd_length(wind)
            }
            forceTimer -= deltaTime
        } else if temporaryGravity != nil || temporaryWind != nil {
            // Timer expired - restore the external force to zero and clear wind
            // Only restore if we had temporary overrides (don't overwrite initial setup)
            if temporaryGravity != nil {
                model?.springBoneGlobalParams?.gravity = VRMConstants.Physics.defaultGravity
            }
            if temporaryWind != nil {
                model?.springBoneGlobalParams?.windAmplitude = 0
            }
            temporaryGravity = nil
            temporaryWind = nil
        }
    }
}
