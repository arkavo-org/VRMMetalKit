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

import Metal

/// Tracks the most recent encoder bindings and skips redundant Metal API calls
/// when the new value matches the previous one. Reset at the start of every
/// render pass via `reset()` since the cache is only valid within a single
/// `MTLRenderCommandEncoder`'s lifetime.
///
/// Only inline-bytes calls (`setVertexBytes` / `setFragmentBytes`) are NOT
/// deduplicated, since their payload bytes can change while the call site
/// is unchanged.
final class EncoderStateCache {
    // Metal allows up to 31 buffer/texture slots per stage on current hardware.
    private static let slotCount = 31

    private var pipelineState: MTLRenderPipelineState?
    private var depthStencilState: MTLDepthStencilState?
    private var cullMode: MTLCullMode?
    private var frontFacing: MTLWinding?
    private var triangleFillMode: MTLTriangleFillMode?

    private var vertexBuffers: [(buffer: MTLBuffer, offset: Int)?] = Array(repeating: nil, count: slotCount)
    private var fragmentBuffers: [(buffer: MTLBuffer, offset: Int)?] = Array(repeating: nil, count: slotCount)
    private var fragmentTextures: [MTLTexture?] = Array(repeating: nil, count: slotCount)

    var skippedCalls: Int = 0
    var emittedCalls: Int = 0

    func reset() {
        pipelineState = nil
        depthStencilState = nil
        cullMode = nil
        frontFacing = nil
        triangleFillMode = nil
        for i in 0..<vertexBuffers.count { vertexBuffers[i] = nil }
        for i in 0..<fragmentBuffers.count { fragmentBuffers[i] = nil }
        for i in 0..<fragmentTextures.count { fragmentTextures[i] = nil }
        skippedCalls = 0
        emittedCalls = 0
    }

    func setRenderPipelineState(_ encoder: MTLRenderCommandEncoder, _ state: MTLRenderPipelineState) {
        if pipelineState === state {
            skippedCalls &+= 1
            return
        }
        encoder.setRenderPipelineState(state)
        pipelineState = state
        emittedCalls &+= 1
    }

    func setDepthStencilState(_ encoder: MTLRenderCommandEncoder, _ state: MTLDepthStencilState?) {
        if let state, depthStencilState === state {
            skippedCalls &+= 1
            return
        }
        if state == nil && depthStencilState == nil {
            skippedCalls &+= 1
            return
        }
        encoder.setDepthStencilState(state)
        depthStencilState = state
        emittedCalls &+= 1
    }

    func setCullMode(_ encoder: MTLRenderCommandEncoder, _ mode: MTLCullMode) {
        if cullMode == mode {
            skippedCalls &+= 1
            return
        }
        encoder.setCullMode(mode)
        cullMode = mode
        emittedCalls &+= 1
    }

    func setFrontFacing(_ encoder: MTLRenderCommandEncoder, _ winding: MTLWinding) {
        if frontFacing == winding {
            skippedCalls &+= 1
            return
        }
        encoder.setFrontFacing(winding)
        frontFacing = winding
        emittedCalls &+= 1
    }

    func setTriangleFillMode(_ encoder: MTLRenderCommandEncoder, _ mode: MTLTriangleFillMode) {
        if triangleFillMode == mode {
            skippedCalls &+= 1
            return
        }
        encoder.setTriangleFillMode(mode)
        triangleFillMode = mode
        emittedCalls &+= 1
    }

    func setVertexBuffer(_ encoder: MTLRenderCommandEncoder, _ buffer: MTLBuffer?, offset: Int, index: Int) {
        guard index >= 0 && index < vertexBuffers.count else {
            encoder.setVertexBuffer(buffer, offset: offset, index: index)
            emittedCalls &+= 1
            return
        }
        if let buffer, let prev = vertexBuffers[index], prev.buffer === buffer, prev.offset == offset {
            skippedCalls &+= 1
            return
        }
        encoder.setVertexBuffer(buffer, offset: offset, index: index)
        if let buffer {
            vertexBuffers[index] = (buffer, offset)
        } else {
            vertexBuffers[index] = nil
        }
        emittedCalls &+= 1
    }

    func setFragmentBuffer(_ encoder: MTLRenderCommandEncoder, _ buffer: MTLBuffer?, offset: Int, index: Int) {
        guard index >= 0 && index < fragmentBuffers.count else {
            encoder.setFragmentBuffer(buffer, offset: offset, index: index)
            emittedCalls &+= 1
            return
        }
        if let buffer, let prev = fragmentBuffers[index], prev.buffer === buffer, prev.offset == offset {
            skippedCalls &+= 1
            return
        }
        encoder.setFragmentBuffer(buffer, offset: offset, index: index)
        if let buffer {
            fragmentBuffers[index] = (buffer, offset)
        } else {
            fragmentBuffers[index] = nil
        }
        emittedCalls &+= 1
    }

    func setFragmentTexture(_ encoder: MTLRenderCommandEncoder, _ texture: MTLTexture?, index: Int) {
        guard index >= 0 && index < fragmentTextures.count else {
            encoder.setFragmentTexture(texture, index: index)
            emittedCalls &+= 1
            return
        }
        let prev = fragmentTextures[index]
        // Match identity for non-nil and treat both-nil as equal.
        if prev === texture {
            skippedCalls &+= 1
            return
        }
        encoder.setFragmentTexture(texture, index: index)
        fragmentTextures[index] = texture
        emittedCalls &+= 1
    }
}
