// Copyright 2026 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest

extension XCTestCase {
    /// Skips tests that abort inside the Metal framework on OS 27 beta images
    /// (issue #370): `MTLBinaryArchive.serialize()` and readable depth-texture
    /// validation assert-abort in the beta driver. The abort happens inside
    /// Metal itself, so the affected tests cannot catch it and must not run.
    /// Remove once the OS 27 driver no longer aborts on these paths.
    func skipOnOS27BetaMetalDriver() throws {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            throw XCTSkip(
                "Metal driver on OS 27 beta images assert-aborts in " +
                "MTLBinaryArchive/depth-descriptor paths (issue #370)."
            )
        }
    }
}
