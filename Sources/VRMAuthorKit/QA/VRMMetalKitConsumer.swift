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

/// The authoring-v1 `vrmmetalkit` consumer: hands exported bytes to the
/// `vrm-author-render` executable's `--check-import` mode, which loads them
/// with VRMMetalKit's loader. Without the executable it throws
/// `MISSING_CAPABILITY`, so the pin reports `incomplete` rather than pass.
public struct VRMMetalKitSubprocessConsumer: ConsumerImporter {
    public static let checkImportFlag = "--check-import"
    public static let versionFlag = "--version"
    public static let unavailableVersion = "unavailable"

    private let executableURL: URL?
    private let environment: [String: String]
    private let timeout: TimeInterval
    private let probe: CachedProbe

    /// - Parameters:
    ///   - executableURL: the running executable whose sibling `vrm-author-render` is used when `VRM_AUTHOR_RENDERER` is unset.
    ///   - environment: fallback environment when no `OperationContext` is supplied.
    ///   - timeout: wall-clock limit for one import in seconds.
    public init(executableURL: URL? = Bundle.main.executableURL, environment: [String: String] = ProcessInfo.processInfo.environment, timeout: TimeInterval = 300) {
        self.executableURL = executableURL
        self.environment = environment
        self.timeout = timeout
        self.probe = CachedProbe()
    }

    public var id: String { QAPins.consumerVRMMetalKit }

    /// VRMMetalKit's version from `--version`, probed once; `unavailable`
    /// when the executable is absent.
    public var version: String {
        probe.value {
            guard let binary = binary(),
                  let manifest = try? VRMAuthorRenderAdapter.run(binary, arguments: [VRMMetalKitSubprocessConsumer.versionFlag], timeout: 120),
                  let version = manifest["renderer"]?["version"]?.string else { return VRMMetalKitSubprocessConsumer.unavailableVersion }
            return version
        }
    }

    public func binary(context: OperationContext? = nil) -> URL? {
        VRMAuthorRenderLocator.binary(context: context, executableURL: executableURL, environment: environment)
    }

    public func importVRM(_ data: Data) throws -> ConsumerImportReport {
        try importVRM(data, binary: binary())
    }

    public func importVRM(_ data: Data, context: OperationContext) throws -> ConsumerImportReport {
        try importVRM(data, binary: binary(context: context))
    }

    func importVRM(_ data: Data, binary: URL?) throws -> ConsumerImportReport {
        guard let binary else {
            throw AuthorError(code: .missingCapability, path: VRMAuthorRenderLocator.environmentKey,
                              message: "Consumer '\(id)' needs vrm-author-render next to the executable or via \(VRMAuthorRenderLocator.environmentKey).", suggestedCommands: ["doctor"])
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vrm-author-consumer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("import.vrm")
        try ProjectStore.atomicWrite(data, to: fileURL)
        let output: JSONValue
        do {
            guard let manifest = try VRMAuthorRenderAdapter.run(binary, arguments: [VRMMetalKitSubprocessConsumer.checkImportFlag, fileURL.path], timeout: timeout) else {
                throw AuthorError(code: .missingCapability, path: binary.path, message: "\(binary.lastPathComponent) reported no Metal device for the import check.", suggestedCommands: ["doctor"])
            }
            output = manifest
        } catch let error as AuthorError where error.code == .internalError {
            throw AuthorError(code: .validationFailed, path: binary.path, observed: error.observed, message: "VRMMetalKit rejected the file: \(error.message)", suggestedCommands: ["qa run"])
        }
        return try VRMMetalKitSubprocessConsumer.report(from: output, binary: binary)
    }

    static func report(from output: JSONValue, binary: URL) throws -> ConsumerImportReport {
        if let error = output["error"]?.string {
            throw AuthorError(code: .validationFailed, path: binary.path, message: error, suggestedCommands: ["qa run"])
        }
        guard output["consumer"]?.string == QAPins.consumerVRMMetalKit else {
            throw AuthorError(code: .validationFailed, path: binary.path, observed: output["consumer"], required: .string(QAPins.consumerVRMMetalKit),
                              message: "\(binary.lastPathComponent) reported an unexpected consumer id.", suggestedCommands: ["doctor"])
        }
        func count(_ key: String) throws -> Int {
            guard let value = output[key]?.int else {
                throw AuthorError(code: .validationFailed, path: binary.path, message: "\(binary.lastPathComponent) import report lacks '\(key)'.", suggestedCommands: ["doctor"])
            }
            return value
        }
        var warnings = output["warnings"]?.array?.compactMap(\.string) ?? []
        if output["requiredBonesPresent"]?.bool == false, warnings.isEmpty { warnings.append("VRMMetalKit found required humanoid bones missing.") }
        return ConsumerImportReport(consumer: QAPins.consumerVRMMetalKit, version: output["version"]?.string ?? unavailableVersion,
                                    humanoidBones: try count("humanoidBones"), expressions: try count("expressions"), springs: try count("springs"),
                                    colliders: try count("colliders"), colliderGroups: try count("colliderGroups"), meshes: try count("meshes"),
                                    materials: try count("materials"), warnings: warnings)
    }
}
