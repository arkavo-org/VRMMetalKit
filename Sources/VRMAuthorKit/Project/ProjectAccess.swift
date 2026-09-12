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

/// Shared plumbing for project-bound handlers: store resolution, template
/// lookup and the mutation wrapper that turns store errors into envelopes
/// carrying the project's current revision.
public enum ProjectAccess {
    /// Resolves a request path against the working directory, treating the
    /// directory as such even when the URL was not built with `isDirectory`.
    public static func resolve(_ path: String, cwd: URL) -> URL {
        URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: cwd.path, isDirectory: true)).standardizedFileURL
    }

    public static func projectURL(_ context: OperationContext, _ request: JSONValue) throws -> URL {
        if let path = request["project"]?.string { return resolve(path, cwd: context.cwd) }
        if let url = context.projectPath { return url }
        throw AuthorError(code: .invalidRequest, path: "/project", message: "project is required; there is no implicit current project.", suggestedCommands: ["project init"])
    }

    public static func store(_ context: OperationContext, _ request: JSONValue) throws -> ProjectStore {
        try ProjectStore.open(at: try projectURL(context, request))
    }

    public static func pack(_ context: OperationContext, template: TemplateRef?) throws -> any TemplatePack {
        guard let template else {
            throw AuthorError(code: .missingCapability, path: "/template", message: "Project has no template pack recorded.", suggestedCommands: ["project inspect"])
        }
        guard let pack = context.templates.pack(id: template.id) else {
            throw AuthorError(code: .missingCapability, path: "/template", observed: .string(template.id), required: JSONValue(context.templates.ids),
                              message: "Template pack '\(template.id)' is not installed in this build.", suggestedCommands: ["template list"])
        }
        guard pack.sha256 == template.sha256 else {
            throw AuthorError(code: .missingCapability, path: "/template/sha256", observed: .string(pack.sha256), required: .string(template.sha256),
                              message: "Installed template pack '\(template.id)' does not match the project's pinned hash.", suggestedCommands: ["template list", "project inspect"])
        }
        return pack
    }

    public static func generatedRequestId() -> String { "req-" + UUID().uuidString.lowercased() }

    /// Runs `body` through `ProjectStore.mutate`, generating a requestId when
    /// absent and reporting failures against the current revision.
    public static func mutation(_ context: OperationContext, _ request: JSONValue, operation: String,
                                body: (ProjectStore, inout MutationTransaction) throws -> [String: JSONValue]) -> ResultEnvelope {
        let requestId = request["requestId"]?.string ?? generatedRequestId()
        var current: Int?
        do {
            let store = try store(context, request)
            current = try store.state().revision
            var envelope = try store.mutate(requestId: requestId, payload: request, expectedRevision: request["expectedRevision"]?.int,
                                            dryRun: request["dryRun"]?.bool ?? false, expectedPlanHash: request["expectedPlanHash"]?.string, operation: operation) { tx in
                .object(try body(store, &tx))
            }
            if var result = envelope.result?.object, let plan = envelope.plan {
                result["plan"] = try JSONValue.from(plan)
                envelope.result = .object(result)
            }
            return envelope
        } catch let error as AuthorError {
            return .failed(requestId: requestId, revision: current, errors: [error])
        } catch let error as ModelValidationError {
            return .failed(requestId: requestId, revision: current, errors: error.errors)
        } catch {
            return .failed(requestId: requestId, revision: current, errors: [AuthorError.internalError(error)])
        }
    }

    static func read(_ context: OperationContext, _ request: JSONValue, body: (ProjectStore, ProjectState) throws -> JSONValue) throws -> ResultEnvelope {
        let store = try store(context, request)
        let state = try store.state()
        return .succeeded(requestId: request["requestId"]?.string, revisionBefore: state.revision, revisionAfter: state.revision, result: try body(store, state))
    }
}
