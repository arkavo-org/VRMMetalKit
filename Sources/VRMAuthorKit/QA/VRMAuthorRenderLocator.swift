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
import Synchronization

/// Finds the optional `vrm-author-render` executable: `VRM_AUTHOR_RENDERER`
/// wins, then a sibling of the running executable.
public enum VRMAuthorRenderLocator {
    public static let rendererId = "vrmmetalkit"
    public static let environmentKey = "VRM_AUTHOR_RENDERER"
    public static let binaryNames = ["vrm-author-render", "VRMAuthorRender"]

    public static func locate(executableURL: URL?, env: [String: String]) -> URL? {
        if let configured = env[environmentKey], !configured.isEmpty {
            let url = URL(fileURLWithPath: configured)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        guard let directory = executableURL?.deletingLastPathComponent() else { return nil }
        for name in binaryNames {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Renderer ids `capabilities` and `doctor` report.
    public static func renderers(executableURL: URL?, env: [String: String]) -> [String] {
        locate(executableURL: executableURL, env: env) == nil ? [] : [rendererId]
    }
}

/// A value computed on first use and kept for the process lifetime. Both
/// subprocess wrappers probe their executable exactly once.
final class CachedProbe: Sendable {
    private let cached = Mutex<String?>(nil)

    func value(_ compute: () -> String) -> String {
        cached.withLock { value in
            if let value { return value }
            let computed = compute()
            value = computed
            return computed
        }
    }
}

extension VRMAuthorRenderLocator {
    /// The request's own context wins over the wrapper's construction-time environment.
    static func binary(context: OperationContext?, executableURL: URL?, environment: [String: String]) -> URL? {
        if let context, let found = locate(executableURL: context.executableURL, env: context.env) { return found }
        return locate(executableURL: executableURL, env: environment)
    }
}
