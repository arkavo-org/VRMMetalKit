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

public struct SignerAvailabilityReport: Codable, Hashable, Sendable {
    public var available: Bool
    public var signer: String?
    public var trustPolicyPath: String?
    public var trusted: Bool
    public var reason: String

    public var json: JSONValue {
        var o: [String: JSONValue] = ["available": .bool(available), "trusted": .bool(trusted), "reason": .string(reason)]
        if let signer { o["signer"] = .string(signer) }
        if let trustPolicyPath { o["trustPolicy"] = .string(trustPolicyPath) }
        return .object(o)
    }
}

/// Whether a signing credential resolves from the environment: the trust
/// policy at `VRM_AUTHOR_TRUST_POLICY` must configure the signer named by
/// `VRM_AUTHOR_SIGNER` with a loadable private key matching its public key.
/// Used by `capabilities.signerAvailable` and `doctor.signer`.
public enum SignerAvailability {
    public static let trustPolicyKey = "VRM_AUTHOR_TRUST_POLICY"
    public static let signerKey = "VRM_AUTHOR_SIGNER"

    public static func check(env: [String: String], cwd: URL) -> SignerAvailabilityReport {
        guard let policyPath = env[trustPolicyKey], !policyPath.isEmpty else {
            return SignerAvailabilityReport(available: false, signer: env[signerKey], trustPolicyPath: nil, trusted: false, reason: "\(trustPolicyKey) is not set")
        }
        let url = URL(fileURLWithPath: policyPath, relativeTo: cwd).standardizedFileURL
        let policy: TrustPolicy
        do { policy = try TrustPolicy.load(url) } catch {
            return SignerAvailabilityReport(available: false, signer: env[signerKey], trustPolicyPath: url.path, trusted: false, reason: "trust policy unreadable: \((error as? AuthorError)?.message ?? "\(error)")")
        }
        guard let signer = env[signerKey], !signer.isEmpty else {
            return SignerAvailabilityReport(available: false, signer: nil, trustPolicyPath: url.path, trusted: false, reason: "\(signerKey) is not set")
        }
        do {
            _ = try SidecarSigner(signer: signer, policy: policy)
        } catch {
            return SignerAvailabilityReport(available: false, signer: signer, trustPolicyPath: url.path, trusted: policy.trusted.contains(signer),
                                            reason: (error as? AuthorError)?.message ?? "\(error)")
        }
        let trusted = policy.trusted.contains(signer)
        return SignerAvailabilityReport(available: true, signer: signer, trustPolicyPath: url.path, trusted: trusted,
                                        reason: trusted ? "signer key resolves and is trusted" : "signer key resolves but is not in the trusted list")
    }

    /// The environment trust policy, when configured and readable.
    public static func environmentPolicy(env: [String: String], cwd: URL) -> TrustPolicy? {
        guard let path = env[trustPolicyKey], !path.isEmpty else { return nil }
        return try? TrustPolicy.load(URL(fileURLWithPath: path, relativeTo: cwd).standardizedFileURL)
    }
}
