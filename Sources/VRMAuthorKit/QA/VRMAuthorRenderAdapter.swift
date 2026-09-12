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

/// Drives the `vrm-author-render` executable (VRMMetalKit, Metal) as a
/// subprocess, one scenario per run, and returns the hash-verified artifacts
/// it reports. Nil when the executable is absent or reports no Metal device,
/// so authoring-v1 render scenarios stay `incomplete` rather than pass.
public struct VRMAuthorRenderAdapter: RenderAdapter {
    public static let rendererId = VRMAuthorRenderLocator.rendererId
    public static let unavailableIdentity = "\(rendererId)/unavailable"
    public static let noDeviceExitCode: Int32 = 3

    private let executableURL: URL?
    private let environment: [String: String]
    private let timeout: TimeInterval
    private let probe: CachedProbe

    /// - Parameters:
    ///   - executableURL: the running executable whose sibling `vrm-author-render` is used when `VRM_AUTHOR_RENDERER` is unset.
    ///   - environment: fallback environment for identity probing before any `OperationContext` exists.
    ///   - timeout: per-scenario wall-clock limit in seconds.
    public init(executableURL: URL? = Bundle.main.executableURL, environment: [String: String] = ProcessInfo.processInfo.environment, timeout: TimeInterval = 900) {
        self.executableURL = executableURL
        self.environment = environment
        self.timeout = timeout
        self.probe = CachedProbe()
    }

    public func binary(context: OperationContext? = nil) -> URL? {
        VRMAuthorRenderLocator.binary(context: context, executableURL: executableURL, environment: environment)
    }

    /// `vrmmetalkit/<version>@<device>` from `--device-info`, probed once and
    /// cached; `vrmmetalkit/unavailable` when the executable or device is missing.
    public var identity: String {
        probe.value {
            guard let binary = binary() else { return VRMAuthorRenderAdapter.unavailableIdentity }
            guard let manifest = try? VRMAuthorRenderAdapter.run(binary, arguments: ["--device-info"], timeout: 120),
                  let renderer = manifest["renderer"], let version = renderer["version"]?.string, let device = renderer["device"]?.string else {
                return VRMAuthorRenderAdapter.unavailableIdentity
            }
            return "\(VRMAuthorRenderAdapter.rendererId)/\(version)@\(device)"
        }
    }

    public func render(scenario: RenderScenario, file: URL, data: Data, outputDirectory: URL, context: OperationContext) throws -> [ArtifactRef]? {
        guard let binary = binary(context: context) else { return nil }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let scenarioURL = outputDirectory.appendingPathComponent("scenario.json")
        try ProjectStore.atomicWrite(try CanonicalJSON.encode(scenario), to: scenarioURL)
        guard let manifest = try VRMAuthorRenderAdapter.run(binary, arguments: ["--file", file.path, "--scenario", scenarioURL.path, "--out", outputDirectory.path],
                                                            timeout: timeout, manifestURL: outputDirectory.appendingPathComponent("manifest.json")) else { return nil }
        return try VRMAuthorRenderAdapter.artifacts(from: manifest, scenario: scenario, binary: binary)
    }

    // MARK: Manifest verification

    static func artifacts(from manifest: JSONValue, scenario: RenderScenario, binary: URL) throws -> [ArtifactRef] {
        guard manifest["renderer"]?["id"]?.string == rendererId else {
            throw AuthorError(code: .validationFailed, path: binary.path, observed: manifest["renderer"]?["id"], required: .string(rendererId),
                              message: "\(binary.lastPathComponent) reported an unexpected renderer id.", suggestedCommands: ["doctor"])
        }
        guard let entries = manifest["artifacts"]?.array, !entries.isEmpty else {
            throw AuthorError(code: .validationFailed, path: binary.path, message: "\(binary.lastPathComponent) reported no artifacts for \(scenario.id).", suggestedCommands: ["doctor"])
        }
        return try entries.map { entry in
            guard let path = entry["path"]?.string, let sha256 = entry["sha256"]?.string, let mediaType = entry["mediaType"]?.string else {
                throw AuthorError(code: .validationFailed, path: binary.path, message: "Render manifest entry for \(scenario.id) lacks path, sha256 or mediaType.", suggestedCommands: ["doctor"])
            }
            let url = URL(fileURLWithPath: path)
            guard let bytes = try? Data(contentsOf: url) else {
                throw AuthorError(code: .missingInput, path: path, message: "Render artifact for \(scenario.id) is missing at \(path).", suggestedCommands: ["qa run"])
            }
            let actual = SHA256Hex.hex(bytes)
            guard actual == sha256 else {
                throw AuthorError(code: .validationFailed, path: path, observed: .string(actual), required: .string(sha256),
                                  message: "Render artifact sha256 does not match the renderer manifest for \(scenario.id).", suggestedCommands: ["qa run"])
            }
            return ArtifactRef(path: url.path, sha256: sha256, mediaType: mediaType, sizeBytes: bytes.count, role: entry["role"]?.string ?? "render:\(scenario.id)")
        }
    }

    // MARK: Subprocess

    /// Runs the renderer; nil when it exits with the no-device code.
    static func run(_ binary: URL, arguments: [String], timeout: TimeInterval, manifestURL: URL? = nil) throws -> JSONValue? {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let collector = OutputCollector()
        stdout.fileHandleForReading.readabilityHandler = { handle in collector.append(handle.availableData, toError: false) }
        stderr.fileHandleForReading.readabilityHandler = { handle in collector.append(handle.availableData, toError: true) }
        do { try process.run() } catch {
            throw AuthorError(code: .missingCapability, path: binary.path, message: "Could not launch \(binary.lastPathComponent): \(error)", suggestedCommands: ["doctor"])
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw AuthorError(code: .internalError, path: binary.path, message: "\(binary.lastPathComponent) exceeded \(Int(timeout))s and was terminated.", suggestedCommands: ["doctor"])
        }
        process.waitUntilExit()
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        collector.append(stdout.fileHandleForReading.readDataToEndOfFile(), toError: false)
        collector.append(stderr.fileHandleForReading.readDataToEndOfFile(), toError: true)
        let (output, errorOutput) = collector.snapshot()
        let status = process.terminationStatus
        if status == noDeviceExitCode { return nil }
        guard status == 0 else {
            let detail = String(decoding: errorOutput.suffix(2000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AuthorError(code: .internalError, path: binary.path, observed: .number(Double(status)),
                              message: "\(binary.lastPathComponent) exited with status \(status): \(detail)", suggestedCommands: ["doctor"])
        }
        if let manifestURL, let data = try? Data(contentsOf: manifestURL), let manifest = try? JSONValue.parse(data) { return manifest }
        let lines = String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let last = lines.last, let manifest = try? JSONValue.parse(Data(last.utf8)) else {
            throw AuthorError(code: .validationFailed, path: binary.path, message: "\(binary.lastPathComponent) printed no JSON manifest.", suggestedCommands: ["doctor"])
        }
        return manifest
    }

    private final class OutputCollector: Sendable {
        private let state = Mutex<(output: Data, error: Data)>((Data(), Data()))

        func append(_ data: Data, toError: Bool) {
            guard !data.isEmpty else { return }
            state.withLock { if toError { $0.error.append(data) } else { $0.output.append(data) } }
        }

        func snapshot() -> (Data, Data) { state.withLock { ($0.output, $0.error) } }
    }
}
