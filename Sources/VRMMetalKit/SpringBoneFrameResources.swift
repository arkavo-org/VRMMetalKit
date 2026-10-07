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


import Foundation
import Metal

/// One command buffer's immutable host inputs and GPU readback destinations.
/// A lease is returned to the pool only after its completion handler consumes readback.
final class SpringBoneFrameResources: @unchecked Sendable {
    struct Binding {
        let buffer: MTLBuffer
        let offset: Int
    }

    private let device: MTLDevice
    private var buffers: [MTLBuffer] = []
    private var bufferIndex = 0
    private var offset = 0

    init(device: MTLDevice) { self.device = device }

    func reset() {
        bufferIndex = 0
        offset = 0
    }

    func allocate(length: Int) -> Binding? {
        guard length > 0 else { return nil }
        let alignedLength = (length + 255) & ~255
        while bufferIndex < buffers.count {
            let buffer = buffers[bufferIndex]
            if offset + alignedLength <= buffer.length {
                let binding = Binding(buffer: buffer, offset: offset)
                offset += alignedLength
                return binding
            }
            bufferIndex += 1
            offset = 0
        }
        guard let buffer = device.makeBuffer(length: max(65536, alignedLength), options: .storageModeShared) else {
            return nil
        }
        buffer.label = "SpringBone Frame Upload and Readback"
        buffers.append(buffer)
        offset = alignedLength
        return Binding(buffer: buffer, offset: 0)
    }

    func snapshot(_ source: MTLBuffer, offset: Int = 0, length: Int? = nil) -> Binding? {
        let length = length ?? (source.length - offset)
        guard offset >= 0, length > 0, offset + length <= source.length,
              let binding = allocate(length: length) else { return nil }
        binding.buffer.contents().advanced(by: binding.offset)
            .copyMemory(from: source.contents().advanced(by: offset), byteCount: length)
        return binding
    }
}

/// Encoding and Metal completion callbacks access the free list under the lock.
final class SpringBoneFramePool: @unchecked Sendable {
    private let device: MTLDevice
    private let lock = NSLock()
    private var available: [SpringBoneFrameResources] = []

    init(device: MTLDevice) { self.device = device }

    func acquire() -> SpringBoneFrameResources {
        let resources = lock.withLock { available.popLast() } ?? SpringBoneFrameResources(device: device)
        resources.reset()
        return resources
    }

    func release(_ resources: SpringBoneFrameResources) {
        lock.withLock {
            if available.count < VRMConstants.Rendering.maxBufferedFrames {
                available.append(resources)
            }
        }
    }
}
