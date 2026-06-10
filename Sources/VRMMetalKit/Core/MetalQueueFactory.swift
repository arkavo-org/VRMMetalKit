// Copyright 2026 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import Metal

enum MetalQueueFactory {
    /// Creates a command queue, attaching a shader-logging `MTLLogState` in
    /// DEBUG builds so `os_log` calls inside `.metal` kernels reach the
    /// console.
    ///
    /// Shader logging is mutually exclusive with GPU trace capture:
    /// `MTLCaptureManager` fails with "Capturing Shader logging is not
    /// supported" if any queue on the device carries a log state. Since
    /// capture tooling (Xcode, `gpucapture`, the `GPUTraceCaptureTests`
    /// harness) advertises itself via `METAL_CAPTURE_ENABLED`, logging is
    /// skipped whenever that variable is present.
    static func makeCommandQueue(device: MTLDevice) -> MTLCommandQueue? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["METAL_CAPTURE_ENABLED"] == nil {
            let logStateDesc = MTLLogStateDescriptor()
            logStateDesc.level = .debug
            if let logState = try? device.makeLogState(descriptor: logStateDesc) {
                let queueDesc = MTLCommandQueueDescriptor()
                queueDesc.logState = logState
                if let queue = device.makeCommandQueue(descriptor: queueDesc) {
                    return queue
                }
            }
        }
        #endif
        return device.makeCommandQueue()
    }
}
