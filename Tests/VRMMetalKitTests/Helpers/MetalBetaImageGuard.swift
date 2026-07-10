// Copyright 2026 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest

extension XCTestCase {
    /// Skips tests that abort inside the Metal framework on beta toolchain
    /// images (issue #370): `MTLBinaryArchive.serialize()` and readable
    /// depth-texture validation assert-abort in the simulator driver that
    /// ships with the Xcode 27 beta — on any simulated OS version, so the
    /// runtime version is not a usable signal. The abort happens inside
    /// Metal itself, so the affected tests cannot catch it and must not run.
    /// Native macOS keeps full coverage of these paths (guarded only on
    /// OS 27 beta hosts). Remove once the OS 27 driver no longer aborts.
    func skipOnBetaMetalDriverAborts() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip(
            "Simulator Metal driver from beta toolchains assert-aborts in " +
            "MTLBinaryArchive/depth-descriptor paths (issue #370)."
        )
        #else
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            throw XCTSkip(
                "Metal driver on OS 27 beta images assert-aborts in " +
                "MTLBinaryArchive/depth-descriptor paths (issue #370)."
            )
        }
        #endif
    }
}
