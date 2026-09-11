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

/// Locates and hash-verifies the pinned style oracles (verification.md §2)
/// and runs `python3 scripts/style_lint.py lint --profile P --json FILE`.
public struct StyleToolchain: Sendable {
    public static let pinnedLinterSHA256 = "01679f040546fa76b6c4b8f6c84244388201ad04f0f449157c5ec634716b5881"
    public static let pinnedProfileSHA256 = "7eeb1f41bada650d39b7c32a31c273bbd889cca22d390164b8a7dd9b1f9c1f35"
    public static let linterRelativePath = "scripts/style_lint.py"
    public static let profileRelativePath = "docs/style/profiles/vroid-lineage-anime.json"
    public static let linterEnvironmentKey = "VRM_AUTHOR_STYLE_LINTER"
    public static let profileEnvironmentKey = "VRM_AUTHOR_STYLE_PROFILE"
    public static let pythonEnvironmentKey = "VRM_AUTHOR_PYTHON3"

    public var linter: URL?
    public var profile: URL?
    public var python: URL?

    public init(linter: URL?, profile: URL?, python: URL?) {
        self.linter = linter
        self.profile = profile
        self.python = python
    }

    // MARK: Location

    /// Walks up from `start` until a directory containing `relativePath` is found.
    static func ancestor(of start: URL, containing relativePath: String) -> URL? {
        var dir = start.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(relativePath).path) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
    }

    /// Repository root: an ancestor of cwd, of the executable, or of this
    /// source file (development builds) that contains scripts/style_lint.py.
    public static func repoRoot(cwd: URL, executableURL: URL?) -> URL? {
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for start in [cwd, executableURL?.deletingLastPathComponent(), sourceRoot].compactMap({ $0 }) {
            if let root = ancestor(of: start, containing: linterRelativePath) { return root }
        }
        return nil
    }

    public static func python3(env: [String: String]) -> URL? {
        let fm = FileManager.default
        if let override = env[pythonEnvironmentKey], !override.isEmpty, fm.isExecutableFile(atPath: override) { return URL(fileURLWithPath: override) }
        for dir in (env["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("python3")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public static func locate(cwd: URL, executableURL: URL?, env: [String: String]) -> StyleToolchain {
        let root = repoRoot(cwd: cwd, executableURL: executableURL)
        func resolve(_ key: String, _ relative: String) -> URL? {
            if let override = env[key], !override.isEmpty { return URL(fileURLWithPath: override, relativeTo: cwd).standardizedFileURL }
            return root?.appendingPathComponent(relative)
        }
        return StyleToolchain(linter: resolve(linterEnvironmentKey, linterRelativePath), profile: resolve(profileEnvironmentKey, profileRelativePath), python: python3(env: env))
    }

    public static func locate(context: OperationContext) -> StyleToolchain {
        locate(cwd: context.cwd, executableURL: context.executableURL, env: context.env)
    }

    // MARK: Verification

    public struct Verified: Sendable {
        public var linter: URL
        public var profile: URL
        public var python: URL
        public var oracleHashes: [String: String]
    }

    static func verifyPinned(_ url: URL?, relative: String, pinned: String, what: String) throws -> String {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            throw AuthorError(code: .missingCapability, path: relative, required: .string(pinned),
                              message: "\(what) not found; expected \(relative) under the repository root or \(what == "Style linter" ? linterEnvironmentKey : profileEnvironmentKey).",
                              suggestedCommands: ["doctor"])
        }
        let hash = try SHA256Hex.hex(fileAt: url)
        guard hash == pinned else {
            throw AuthorError(code: .missingCapability, path: url.path, observed: .string(hash), required: .string(pinned),
                              message: "\(what) at \(url.path) does not match the pinned oracle hash from verification.md §2.", suggestedCommands: ["doctor"])
        }
        return hash
    }

    /// Verifies python3 and the pinned linter; `profileOverride` (already
    /// hash-checked by the caller) replaces the pinned profile when given.
    public func verified(profileOverride: (url: URL, sha256: String)? = nil) throws -> Verified {
        guard let python else {
            throw AuthorError(code: .missingCapability, path: "python3", message: "python3 not found on PATH; style lint runs the pinned scripts/style_lint.py under python3.",
                              suggestedCommands: ["doctor"])
        }
        let linterHash = try StyleToolchain.verifyPinned(linter, relative: StyleToolchain.linterRelativePath, pinned: StyleToolchain.pinnedLinterSHA256, what: "Style linter")
        var hashes = [StyleToolchain.linterRelativePath: linterHash]
        let profileURL: URL
        if let profileOverride {
            profileURL = profileOverride.url
            hashes[profileOverride.url.path] = profileOverride.sha256
        } else {
            hashes[StyleToolchain.profileRelativePath] = try StyleToolchain.verifyPinned(profile, relative: StyleToolchain.profileRelativePath, pinned: StyleToolchain.pinnedProfileSHA256, what: "Style profile")
            profileURL = profile!
        }
        return Verified(linter: linter!, profile: profileURL, python: python, oracleHashes: hashes)
    }

    // MARK: Diagnostics

    /// Doctor-style report: presence and hash status of python3, linter and profile.
    public static func diagnose(context: OperationContext) -> JSONValue {
        let toolchain = locate(context: context)
        func entry(_ url: URL?, pinned: String) -> JSONValue {
            var out: [String: JSONValue] = ["found": .bool(url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false), "pinnedSha256": .string(pinned)]
            if let url { out["path"] = .string(url.path) }
            if let url, let hash = try? SHA256Hex.hex(fileAt: url) {
                out["sha256"] = .string(hash)
                out["matches"] = .bool(hash == pinned)
            } else {
                out["matches"] = false
            }
            return .object(out)
        }
        var python: [String: JSONValue] = ["found": .bool(toolchain.python != nil)]
        if let py = toolchain.python { python["path"] = .string(py.path) }
        let linter = entry(toolchain.linter, pinned: pinnedLinterSHA256)
        let profile = entry(toolchain.profile, pinned: pinnedProfileSHA256)
        let ok = toolchain.python != nil && linter["matches"] == true && profile["matches"] == true
        return ["python3": .object(python), "styleLinter": linter, "styleProfile": profile, "ok": .bool(ok)]
    }

    // MARK: Execution

    public struct LinterRun: Sendable {
        public var exitStatus: Int32
        public var stdout: Data
        public var stderr: String
        public var arguments: [String]
    }

    public static func runLinter(python: URL, linter: URL, profile: URL, file: URL, cwd: URL, env: [String: String]) throws -> LinterRun {
        let process = Process()
        process.executableURL = python
        process.arguments = [linter.path, "lint", "--profile", profile.path, "--json", file.path]
        process.currentDirectoryURL = cwd
        var environment = env
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONHASHSEED"] = "0"
        process.environment = environment
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        do {
            try process.run()
        } catch {
            throw AuthorError(code: .missingCapability, path: python.path, message: "Cannot launch python3: \(error)", suggestedCommands: ["doctor"])
        }
        let stdout = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()
        return LinterRun(exitStatus: process.terminationStatus, stdout: stdout, stderr: String(decoding: errBox.data, as: UTF8.self), arguments: process.arguments ?? [])
    }
}

final class DataBox: @unchecked Sendable {
    var data = Data()
}
