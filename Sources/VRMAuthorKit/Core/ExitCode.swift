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

/// Process exit codes from commands.md: 0 success or conforming lint; 1 completed
/// evaluation with failed required gates; 2 invalid request; 3 missing
/// capability/input/credential; 4 revision/idempotency/plan conflict; 5 internal.
public enum ExitCode: Int32, Codable, Hashable, Sendable, CaseIterable {
    case success = 0
    case gateFailed = 1
    case invalidRequest = 2
    case missingCapability = 3
    case conflict = 4
    case internalError = 5

    /// Severity for combining multiple errors: internal > conflict > missing > invalid > gate.
    public var severity: Int {
        switch self {
        case .success: return 0
        case .gateFailed: return 1
        case .invalidRequest: return 2
        case .missingCapability: return 3
        case .conflict: return 4
        case .internalError: return 5
        }
    }

    public static func mostSevere(_ codes: [ExitCode]) -> ExitCode {
        codes.max { $0.severity < $1.severity } ?? .success
    }
}
