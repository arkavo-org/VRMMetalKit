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

/// The `serve` handler. It is the one handler that must stream: it reads
/// stdin line by line and writes each response as soon as it is ready, because
/// JSON-RPC and MCP clients wait for a response before sending the next
/// request. The session policy comes from `VRM_AUTHOR_EVIDENCE_POLICY` (a
/// policy file path that may only tighten) and `VRM_AUTHOR_SESSION=harness`.
public enum ServeHandlers {
    public static let names = ["serve"]

    static func install(_ registry: inout Registry) {
        registry.mustInstall(serve, for: "serve")
    }

    public static func sessionPolicy(env: [String: String], cwd: URL) throws -> EvidencePolicy {
        guard let path = env[ServeSession.evidencePolicyEnvironmentKey], !path.isEmpty else { return .release }
        let url = ProjectAccess.resolve(path, cwd: cwd)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AuthorError(code: .missingInput, path: "/evidencePolicy", observed: .string(path), message: "Evidence policy file not found.", suggestedCommands: ["capabilities"])
        }
        let loaded: EvidencePolicy
        do { loaded = try EvidencePolicy.load(url) } catch let error as ModelValidationError { throw error.errors.first ?? AuthorError.invalidRequest("Invalid evidence policy.") }
        return EvidencePolicy(minimumLevel: loaded.minimumLevel, requireCurrent: true)
    }

    public static func isHarness(env: [String: String]) -> Bool {
        env[ServeSession.harnessEnvironmentKey] == "harness"
    }

    static func serve(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        let requestId = request["requestId"]?.string
        guard let protocolName = request["protocol"]?.string, let serveProtocol = ServeProtocol(rawValue: protocolName) else {
            throw AuthorError.invalidRequest("protocol must be jsonrpc or mcp.", path: "/protocol", observed: request["protocol"])
        }
        var sessionContext = context
        if let path = request["project"]?.string { sessionContext.projectPath = ProjectAccess.resolve(path, cwd: context.cwd) }
        let policy = try sessionPolicy(env: context.env, cwd: context.cwd)
        let stderr = FileHandle.standardError
        var session = ServeSession(context: sessionContext, protocol: serveProtocol, policy: policy, harness: isHarness(env: context.env),
                                   previewRenderer: VRMAuthorRenderAdapter(executableURL: context.executableURL)) { line in
            stderr.write(Data(("vrm-author serve: " + line + "\n").utf8))
        }
        let stdout = FileHandle.standardOutput
        while let line = readLine(strippingNewline: true) {
            if let response = session.handle(line: line) {
                stdout.write(Data((response + "\n").utf8))
            }
        }
        return .succeeded(requestId: requestId, result: ["requestsHandled": .number(Double(session.requestsHandled)), "protocol": .string(serveProtocol.rawValue)])
    }
}
