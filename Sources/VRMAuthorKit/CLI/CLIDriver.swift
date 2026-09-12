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

/// Thin CLI over the registry: parse, locate evidence, dispatch, print the
/// envelope as compact canonical JSON on stdout, logs on stderr, mapped exit code.
public enum CLIDriver {
    public static let usage = """
    Usage: vrm-author <command> [--project PATH] [--request PATH|-] [--flag value]...
      Commands: \(Registry.v1Names.joined(separator: ", "))
      `vrm-author describe [--command NAME]` prints every request/result schema.
      Flags are kebab-case aliases of camelCase request keys; a key given both in
      --request JSON and as a flag is an error. Results are JSON on stdout.

    """

    public static func run(arguments: [String],
                           environment: [String: String] = ProcessInfo.processInfo.environment,
                           cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                           executableURL: URL? = Bundle.main.executableURL,
                           stdin: @escaping StandardInputProvider = { FileHandle.standardInput.readDataToEndOfFile() },
                           stdout: (Data) -> Void = { FileHandle.standardOutput.write($0) },
                           stderr: (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }) -> Int32 {
        if arguments.isEmpty {
            stderr(usage)
            return ExitCode.invalidRequest.rawValue
        }
        if arguments == ["--help"] || arguments == ["-h"] || arguments == ["help"] {
            stderr(usage)
            return ExitCode.success.rawValue
        }
        let registry = Registry.v1()
        let envelope: ResultEnvelope
        do {
            let invocation = try CommandLineParser.parse(arguments, registry: registry, stdin: stdin, cwd: cwd)
            var evidence = EvidenceRegistry()
            if let dir = EvidenceRegistry.locate(cwd: cwd, executableURL: executableURL, env: environment) {
                do { evidence = try EvidenceRegistry.load(acceptanceDirectory: dir) } catch { stderr("vrm-author: evidence registry unreadable at \(dir.path): \(error)\n") }
            }
            let projectPath = invocation.request["project"]?.string.map { URL(fileURLWithPath: $0, relativeTo: cwd).standardizedFileURL }
            let context = OperationContext(projectPath: projectPath, cwd: cwd, env: environment, stdin: stdin, evidenceRegistry: evidence,
                                           registry: registry, templates: .standard(), executableURL: executableURL, toolInfo: .current)
            let logLevel = invocation.request["logLevel"]?.string ?? "warn"
            envelope = registry.invoke(invocation.operation.name, request: invocation.request, context: context)
            if logLevel != "error" {
                for warning in envelope.warnings { stderr("vrm-author: warning \(warning.code): \(warning.message)\n") }
            }
            for error in envelope.errors { stderr("vrm-author: error \(error.code.rawValue): \(error.message)\n") }
        } catch let error as AuthorError {
            envelope = .failed(requestId: nil, revision: nil, errors: [error])
            stderr("vrm-author: error \(error.code.rawValue): \(error.message)\n")
        } catch let error as ModelValidationError {
            envelope = .failed(requestId: nil, revision: nil, errors: error.errors)
            for e in error.errors { stderr("vrm-author: error \(e.code.rawValue): \(e.message)\n") }
        } catch {
            envelope = .failed(requestId: nil, revision: nil, errors: [AuthorError.internalError(error)])
            stderr("vrm-author: error INTERNAL: \(error)\n")
        }
        do {
            var data = try envelope.canonicalData()
            data.append(0x0A)
            stdout(data)
        } catch {
            stderr("vrm-author: error INTERNAL: cannot serialize result: \(error)\n")
            return ExitCode.internalError.rawValue
        }
        return envelope.exitCode.rawValue
    }
}
