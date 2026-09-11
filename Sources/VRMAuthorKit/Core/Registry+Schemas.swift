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

/// Common request fields from commands.md, attached per operation kind.
public enum CommonFields {
    public static let format = JSONSchema.enumeration(["json"]).defaulting(to: "json").described("Structured stdout only")
    public static let logLevel = JSONSchema.enumeration(["error", "warn", "info", "debug"]).defaulting(to: "warn").described("Stderr logging")
    public static let requestId = JSONSchema.string(minLength: 1, description: "Persisted idempotency key; generated for writes when omitted")
    public static let project = JSONSchema.path.described("Project directory; no implicit current project")
    public static let expectedRevision = JSONSchema.integer(minimum: 0, description: "Compare-and-swap revision; the CLI resolves the current revision when omitted")
    public static let dryRun = JSONSchema.boolean(description: "Exact edit plan and invalidations without mutation").defaulting(to: false)
    public static let expectedPlanHash = JSONSchema.hash.described("Apply only the inspected plan on its stated base revision")
    public static let out = JSONSchema.path.described("Atomic file/directory result; existing output fails unless replace")
    public static let replace = JSONSchema.boolean(description: "Explicit atomic replacement").defaulting(to: false)
    public static let timeoutSeconds = JSONSchema.number(exclusiveMinimum: 0).unit("seconds").defaulting(to: 300).described("Deadline; a failed mutation leaves the project unchanged")
    public static let maxMemoryMb = JSONSchema.integer(minimum: 1).unit("megabytes").defaulting(to: 4096)
    public static let threads = JSONSchema.integer(minimum: 1).defaulting(to: 1).described("Independent work only; does not change strict output bytes")
    public static let target = JSONSchema.enumeration(["portable-vrm1"]).defaulting(to: "portable-vrm1")
    public static let backend = JSONSchema.enumeration(["portable-strict/1"]).defaulting(to: "portable-strict/1")
    public static let suite = JSONSchema.enumeration(QASuite.allCases.map(\.rawValue))

    static func request(kind: OperationKind, _ fields: [String: JSONSchema], required: [String], out: Bool = false, description: String) -> JSONSchema {
        var props = fields
        var req = required
        props["format"] = format
        props["logLevel"] = logLevel
        props["requestId"] = requestId
        if kind != .projectFree {
            props["project"] = project
            req.append("project")
            props["timeoutSeconds"] = timeoutSeconds
            props["maxMemoryMb"] = maxMemoryMb
            props["threads"] = threads
        }
        if kind == .mutation {
            props["expectedRevision"] = expectedRevision
            props["dryRun"] = dryRun
            props["expectedPlanHash"] = expectedPlanHash
        }
        if out {
            props["out"] = CommonFields.out
            props["replace"] = replace
            req.append("out")
        }
        return JSONSchema.object(properties: props, required: req, description: description)
    }

    static func result(_ fields: [String: JSONSchema], required: [String] = [], description: String) -> JSONSchema {
        JSONSchema.object(properties: fields, required: required, additionalProperties: false, description: description)
    }
}

extension Registry {
    /// The 35 v1 operations with request/result schemas built from commands.md and parameters.md.
    static func v1Operations() -> [Operation] {
        let R = CommonFields.self
        let stringList = JSONSchema.array(of: .string())
        let artifactList = JSONSchema.array(of: ModelSchemas.artifactRef)
        let versionResult = R.result(["tool": .string(), "version": .string(), "protocol": .const(.string(ResultEnvelope.protocolName)), "abi": .string(), "platform": .string()],
                                     required: ["tool", "version", "protocol", "abi"], description: "Tool/protocol/ABI versions")
        let commandEntry = JSONSchema.object(properties: [
            "name": .string(), "rpcMethod": .string(), "kind": .enumeration(["read", "mutation", "projectFree"]), "summary": .string(), "result": .string(),
            "requestSchema": .any(), "resultSchema": .any(), "schemaHash": .hash, "resultSchemaHash": .hash, "examples": .array(of: .any()),
            "units": .map(of: .string()), "requiredEvidence": .enumeration(EvidenceLevel.allCases.map(\.rawValue)), "runnable": .boolean(),
            "prerequisites": stringList,
        ], required: ["name", "rpcMethod", "kind", "requestSchema", "resultSchema", "schemaHash", "requiredEvidence", "runnable"])
        let controlDescriptor = JSONSchema.object(properties: [
            "key": .string(), "unit": .enumeration(ControlUnit.allCases.map(\.rawValue)), "validRange": .vector(2), "recommendedRange": .vector(2),
            "defaultValue": .number(), "side": .enumeration(ControlSide.allCases.map(\.rawValue)), "mirrorKey": .string(),
            "affects": .array(of: ObjectKind.schema), "dependencies": stringList, "description": .string(),
        ], required: ["key", "unit", "validRange", "recommendedRange", "defaultValue", "side", "affects", "dependencies"])
        let objectSummary = JSONSchema.object(properties: [
            "id": .id, "kind": ObjectKind.schema, "revision": .integer(minimum: 0), "writablePointers": stringList,
        ], required: ["id", "kind", "revision", "writablePointers"])
        let planResult = R.result(["plan": ModelSchemas.plan, "invalidations": stringList], description: "Materialized edits and invalidations")
        let checkList = JSONSchema.array(of: .object(properties: [
            "id": .string(), "status": .enumeration(["pass", "fail", "incomplete", "notApplicable"]), "message": .string(), "reportHash": .hash,
        ], required: ["id", "status"]))
        let lossReport = JSONSchema.object(properties: ["preserved": stringList, "lost": stringList, "converted": stringList], required: ["preserved", "lost", "converted"])
        let importResult = R.result(["asset": .id, "sha256": .hash, "kind": .enumeration(AssetKind.allCases.map(\.rawValue)), "lossReport": lossReport,
                                     "ingredient": .any(), "credentialStatus": .string()], required: ["asset", "sha256"], description: "Hashed source, preservation report and ingredient ledger entry")

        return [
            Operation(name: "version", kind: .projectFree, summary: "Tool/protocol/ABI versions", resultDescription: "Tool/protocol/ABI versions",
                      requestSchema: R.request(kind: .projectFree, [:], required: [], description: "No operation arguments"),
                      resultSchema: versionResult, requiredEvidence: .fixtureTested, examples: [[:]]),
            Operation(name: "describe", kind: .projectFree, summary: "Registered schemas, examples, units and required evidence level per command",
                      resultDescription: "Registered schemas, including non-runnable candidates, and each command's required evidence level",
                      requestSchema: R.request(kind: .projectFree, [
                          "command": .string(minLength: 1, description: "One command name, e.g. 'recipe apply'"),
                          "namespace": .enumeration(["v1", "reserved"]).defaulting(to: "v1"),
                      ], required: [], description: "describe arguments"),
                      resultSchema: R.result(["namespace": .string(), "commands": .array(of: commandEntry), "models": stringList], required: ["namespace", "commands"], description: "Command catalogue"),
                      requiredEvidence: .fixtureTested, examples: [[:], ["command": "recipe apply"]]),
            Operation(name: "capabilities", kind: .projectFree, summary: "Scoped availability/evidence manifest", resultDescription: "Scoped availability/evidence manifest",
                      requestSchema: R.request(kind: .projectFree, [
                          "target": R.target,
                          "evidencePolicy": .path.described("JSON {minimumLevel, requireCurrent}; may only tighten the release policy"),
                      ], required: [], description: "capabilities arguments"),
                      resultSchema: R.result([
                          "target": .string(), "entries": .array(of: .any()), "targets": stringList, "templateHashes": .map(of: .hash), "supportedImports": stringList,
                          "backends": stringList, "renderers": stringList, "signerAvailable": .boolean(), "evidencePolicy": EvidencePolicy.schema, "pinnedCommit": .string(),
                      ], required: ["target", "entries", "targets", "templateHashes", "supportedImports", "backends", "renderers", "signerAvailable"], description: "Capability manifest"),
                      requiredEvidence: .fixtureTested, examples: [[:], ["evidencePolicy": "policy.json"]]),
            Operation(name: "doctor", kind: .projectFree, summary: "CPU/backend/renderer/signer/dependency diagnostics", resultDescription: "Diagnostics",
                      requestSchema: R.request(kind: .projectFree, [:], required: [], description: "No operation arguments"),
                      resultSchema: R.result(["python3": .any(), "styleLinter": .any(), "renderer": .any(), "signer": .any(), "determinism": .any(), "acceptance": .any(), "ok": .boolean()],
                                             required: ["python3", "styleLinter", "renderer", "signer", "determinism", "ok"], description: "Diagnostics"),
                      requiredEvidence: .fixtureTested, examples: [[:]]),
            Operation(name: "schema show", kind: .projectFree, summary: "Registered schema, content hash and applicability", resultDescription: "Registered schema, content hash and applicability",
                      requestSchema: R.request(kind: .projectFree, ["name": .string(minLength: 1, description: "Command name or model type, e.g. 'Material'")], required: ["name"], description: "schema show arguments"),
                      resultSchema: R.result(["name": .string(), "kind": .enumeration(["operation-request", "operation-result", "model"]), "schema": .any(), "schemaHash": .hash,
                                              "leaves": stringList, "applicability": stringList], required: ["name", "kind", "schema", "schemaHash", "leaves", "applicability"], description: "One schema"),
                      requiredEvidence: .fixtureTested, examples: [["name": "Material"], ["name": "recipe apply"]]),
            Operation(name: "serve", kind: .projectFree, summary: "JSON-RPC 2.0 session over stdio; MCP adapter negotiates version", resultDescription: "Session summary on exit",
                      requestSchema: R.request(kind: .projectFree, [
                          "stdio": .const(true, description: "Newline-delimited JSON-RPC 2.0 on stdin/stdout"),
                          "protocol": .enumeration(["jsonrpc", "mcp"]).defaulting(to: "jsonrpc"),
                          "project": R.project,
                      ], required: ["stdio"], description: "serve arguments"),
                      resultSchema: R.result(["requestsHandled": .integer(minimum: 0), "protocol": .string()], description: "Session summary"),
                      requiredEvidence: .fixtureTested, examples: [["stdio": true], ["stdio": true, "protocol": "mcp"]]),
            Operation(name: "project init", kind: .projectFree, summary: "New revision 0 and resolved prototype/production recipe", resultDescription: "New revision 0 and resolved recipe",
                      requestSchema: R.request(kind: .projectFree, [
                          "dir": .path.described("Project directory to create"),
                          "template": .id.described("Installed template pack id"),
                          "seed": .integer(minimum: 0, maximum: Int(Recipe.maxSeed)).defaulting(to: 0),
                          "name": .string(minLength: 1).described("Avatar name; defaults to the directory name"),
                      ], required: ["dir", "template"], description: "project init arguments"),
                      resultSchema: R.result(["project": .path, "projectId": .string(), "revision": .integer(minimum: 0), "template": TemplateRef.schema, "recipe": Recipe.schema],
                                             required: ["project", "revision"], description: "Initialized project"),
                      requiredEvidence: .fixtureTested, examples: [["dir": "avatar.vrmauthor", "template": "native-anime-v1", "seed": 7]]),
            Operation(name: "project inspect", kind: .read, summary: "Revision, dependency state, input lock and draft/completion status", resultDescription: "Project status",
                      requestSchema: R.request(kind: .read, [:], required: [], description: "project inspect arguments"),
                      resultSchema: R.result(["projectId": .string(), "name": .string(), "revision": .integer(minimum: 0), "template": TemplateRef.schema, "lock": .any(),
                                              "objects": .integer(minimum: 0), "stale": stringList, "status": .enumeration(["draft", "complete"])], required: ["revision"], description: "Project status"),
                      requiredEvidence: .fixtureTested, examples: [["project": "avatar.vrmauthor"]]),
            Operation(name: "history list", kind: .read, summary: "Revisions and receipts", resultDescription: "Revisions and receipts",
                      requestSchema: R.request(kind: .read, ["limit": .integer(minimum: 1, maximum: 1000).defaulting(to: 100)], required: [], description: "history list arguments"),
                      resultSchema: R.result(["revisions": .array(of: .any()), "receipts": .array(of: .any())], required: ["revisions", "receipts"], description: "History"),
                      requiredEvidence: .fixtureTested, examples: [["project": "avatar.vrmauthor", "limit": 10]]),
            Operation(name: "history restore", kind: .mutation, summary: "New revision restoring that state", resultDescription: "New revision restoring that state",
                      requestSchema: R.request(kind: .mutation, ["revision": .integer(minimum: 0)], required: ["revision"], description: "history restore arguments"),
                      resultSchema: planResult, requiredEvidence: .fixtureTested, examples: [["project": "avatar.vrmauthor", "revision": 3]]),
            Operation(name: "template list", kind: .projectFree, summary: "Installed packs/items with hashes and control schemas", resultDescription: "Installed packs/items",
                      requestSchema: R.request(kind: .projectFree, ["category": .enumeration(TemplateCategory.allCases.map(\.rawValue))], required: [], description: "template list arguments"),
                      resultSchema: R.result(["packs": .array(of: .any()), "items": .array(of: .any())], required: ["packs", "items"], description: "Installed templates"),
                      requiredEvidence: .fixtureTested, examples: [[:], ["category": "hair"]]),
            Operation(name: "recipe export", kind: .read, summary: "Canonical complete Recipe, including pack defaults", resultDescription: "Canonical complete Recipe",
                      requestSchema: R.request(kind: .read, ["resolved": .boolean().defaulting(to: true)], required: [], out: true, description: "recipe export arguments"),
                      resultSchema: R.result(["recipe": Recipe.schema, "artifacts": artifactList], description: "Exported recipe"),
                      requiredEvidence: .fixtureTested, examples: [["project": "avatar.vrmauthor", "out": "recipe.json"]]),
            Operation(name: "recipe apply", kind: .mutation, summary: "Materialized dependency graph and invalidations", resultDescription: "Materialized dependency graph and invalidations",
                      requestSchema: R.request(kind: .mutation, ["recipe": Recipe.schema], required: ["recipe"], description: "recipe apply arguments"),
                      resultSchema: planResult, requiredEvidence: .visuallyValidated, examples: [["project": "avatar.vrmauthor", "recipe": ["schemaVersion": "1.0"]]]),
            Operation(name: "control list", kind: .read, summary: "Available controls for this template/object", resultDescription: "Available controls",
                      requestSchema: R.request(kind: .read, ["object": .id], required: [], description: "control list arguments"),
                      resultSchema: R.result(["controls": .array(of: controlDescriptor)], required: ["controls"], description: "Controls"),
                      requiredEvidence: .fixtureTested, examples: [["project": "avatar.vrmauthor"]]),
            Operation(name: "control describe", kind: .read, summary: "Complete descriptor, endpoints, units and dependencies", resultDescription: "Complete descriptor",
                      requestSchema: R.request(kind: .read, ["key": .string(minLength: 1), "object": .id], required: ["key", "object"], description: "control describe arguments"),
                      resultSchema: R.result(["descriptor": controlDescriptor, "endpoints": .any(), "provenance": .any()], required: ["descriptor"], description: "Descriptor"),
                      requiredEvidence: .fixtureTested, examples: [["project": "avatar.vrmauthor", "object": "avatar:main", "key": "body.heightM"]]),
            Operation(name: "control set", kind: .mutation, summary: "Calibrated source edits and invalidations", resultDescription: "Calibrated source edits and invalidations",
                      requestSchema: R.request(kind: .mutation, ["edit": ControlEdit.schema], required: ["edit"], description: "control set arguments"),
                      resultSchema: planResult, requiredEvidence: .visuallyValidated, examples: [["project": "avatar.vrmauthor", "edit": ["object": "avatar:main", "values": ["body.heightM": 1.7]]]]),
            Operation(name: "object list", kind: .read, summary: "IDs, types, editable field paths and revisions", resultDescription: "IDs, types, editable field paths and revisions",
                      requestSchema: R.request(kind: .read, ["kind": ObjectKind.schema], required: [], description: "object list arguments"),
                      resultSchema: R.result(["objects": .array(of: objectSummary)], required: ["objects"], description: "Objects"),
                      requiredEvidence: .fixtureTested, examples: [["project": "avatar.vrmauthor", "kind": "material"]]),
            Operation(name: "object get", kind: .read, summary: "Typed object and provenance", resultDescription: "Typed object and provenance",
                      requestSchema: R.request(kind: .read, ["id": .id], required: ["id"], description: "object get arguments"),
                      resultSchema: R.result(["object": .any(), "provenance": .any(), "writablePointers": stringList], required: ["object"], description: "Object"),
                      requiredEvidence: .fixtureTested, examples: [["project": "avatar.vrmauthor", "id": "material:hair"]]),
            Operation(name: "object set", kind: .mutation, summary: "Atomic edits to existing supported object fields", resultDescription: "Atomic edits to existing supported object fields",
                      requestSchema: R.request(kind: .mutation, ["edit": ObjectEdit.schema], required: ["edit"], description: "object set arguments"),
                      resultSchema: planResult, requiredEvidence: .fixtureTested, examples: [["project": "avatar.vrmauthor", "edit": ["id": "material:hair", "values": ["/mtoon/shadingToonyFactor": 0.9]]]]),
            Operation(name: "asset import", kind: .mutation, summary: "Hashed source, preservation report and ingredient ledger entry", resultDescription: "Hashed source, preservation report and ingredient ledger entry",
                      requestSchema: R.request(kind: .mutation, ["asset": AssetImport.schema], required: ["asset"], description: "asset import arguments"),
                      resultSchema: importResult, requiredEvidence: .fixtureTested, examples: [["project": "avatar.vrmauthor", "asset": ["path": "ref.png", "kind": "png"]]]),
            Operation(name: "asset inspect", kind: .read, summary: "Geometry/texture facts, extension coverage and credential status", resultDescription: "Asset facts",
                      requestSchema: R.request(kind: .read, ["id": .id], required: ["id"], description: "asset inspect arguments"),
                      resultSchema: R.result(["asset": .any(), "geometry": .any(), "textures": .any(), "extensions": stringList, "credentialStatus": .string()], required: ["asset"], description: "Asset facts"),
                      requiredEvidence: .fixtureTested, examples: [["project": "avatar.vrmauthor", "id": "asset:ref"]]),
            Operation(name: "style attach", kind: .mutation, summary: "Pinned profile; pack material roles retained", resultDescription: "Pinned profile",
                      requestSchema: R.request(kind: .mutation, ["profile": Blob.schema], required: ["profile"], description: "style attach arguments"),
                      resultSchema: planResult, requiredEvidence: .fixtureTested, examples: [["project": "avatar.vrmauthor", "profile": ["path": "docs/style/profiles/vroid-lineage-anime.json", "sha256": .string(String(repeating: "0", count: 64))]]]),
            Operation(name: "style lint", kind: .projectFree, summary: "Profile linter JSON and must-fail exit semantics", resultDescription: "Profile linter JSON and must-fail exit semantics",
                      requestSchema: R.request(kind: .projectFree, ["file": .path, "profile": Blob.schema, "project": R.project], required: ["file"], description: "style lint arguments"),
                      resultSchema: R.result(["report": .any(), "verdict": .enumeration(["conforming", "conforming-with-warnings", "nonconforming"]), "oracleHashes": .map(of: .hash)], required: ["report", "verdict"], description: "Lint report"),
                      requiredEvidence: .corpusValidated, examples: [["file": "avatar.vrm"]]),
            Operation(name: "material shading", kind: .mutation, summary: "Derived MToon factors, or error if factors out of legal bounds", resultDescription: "Derived MToon factors",
                      requestSchema: R.request(kind: .mutation, [
                          "material": .id,
                          "shadowEnd": .number(minimum: -1, maximum: 1).unit("normalized").described("NdotL where shadow ends"),
                          "terminatorWidth": .number(minimum: 0, maximum: 2).unit("normalized").described("toony = 1 - width/2"),
                      ], required: ["material", "shadowEnd", "terminatorWidth"], description: "material shading arguments"),
                      resultSchema: R.result(["shadingToonyFactor": .number(minimum: 0, maximum: 1), "shadingShiftFactor": .number(minimum: -1, maximum: 1), "plan": ModelSchemas.plan], description: "Derived factors"),
                      requiredEvidence: .visuallyValidated, examples: [["project": "avatar.vrmauthor", "material": "material:face", "shadowEnd": -0.7, "terminatorWidth": 0.1]]),
            Operation(name: "build", kind: .read, summary: "Unsigned draft VRM, build hash and ID map", resultDescription: "Unsigned draft VRM, build hash and ID map",
                      requestSchema: R.request(kind: .read, ["target": R.target, "backend": R.backend], required: [], out: true, description: "build arguments"),
                      resultSchema: R.result(["buildHash": .hash, "artifacts": artifactList, "idMap": .any(), "stale": stringList], required: ["buildHash", "artifacts"], description: "Build"),
                      requiredEvidence: .visuallyValidated, examples: [["project": "avatar.vrmauthor", "out": "builds/draft.vrm"]]),
            Operation(name: "qa plan", kind: .read, summary: "Required scenarios, locked thresholds, renderer and consumers for a v1 QA suite", resultDescription: "QA plan",
                      requestSchema: R.request(kind: .read, ["suite": R.suite, "file": .path], required: ["suite", "file"], out: true, description: "qa plan arguments"),
                      resultSchema: R.result(["plan": .any(), "planHash": .hash, "artifacts": artifactList], required: ["planHash"], description: "QA plan"),
                      requiredEvidence: .fixtureTested, examples: [["project": "avatar.vrmauthor", "suite": "spec+style", "file": "builds/draft.vrm", "out": "reports/plan.json"]]),
            Operation(name: "qa run", kind: .read, summary: "Findings, observations and hashed evidence", resultDescription: "Findings, observations and hashed evidence; acceptance runs require an isolated evaluator session",
                      requestSchema: R.request(kind: .read, ["request": QARequest.schema], required: ["request"], out: true, description: "qa run arguments"),
                      resultSchema: R.result(["verdict": .enumeration(["pass", "fail", "incomplete"]), "checks": checkList, "reportHash": .hash, "artifacts": artifactList], required: ["verdict", "checks"], description: "QA report"),
                      requiredEvidence: .fixtureTested, examples: [["project": "avatar.vrmauthor", "request": ["file": "builds/draft.vrm", "suite": "spec+style"], "out": "reports/qa"]]),
            Operation(name: "inspection record", kind: .mutation, summary: "Append-only artifact inspection attestation", resultDescription: "Append-only artifact inspection attestation",
                      requestSchema: R.request(kind: .mutation, ["inspection": Inspection.schema], required: ["inspection"], description: "inspection record arguments"),
                      resultSchema: R.result(["recordHash": .hash, "plan": ModelSchemas.plan], description: "Recorded inspection"),
                      requiredEvidence: .fixtureTested, examples: [["project": "avatar.vrmauthor", "inspection": ["scenarioId": "front", "verdict": "pass"]]]),
            Operation(name: "inspection verify", kind: .read, summary: "Missing/stale/failed inspection coverage", resultDescription: "Missing/stale/failed inspection coverage",
                      requestSchema: R.request(kind: .read, ["report": .path], required: ["report"], description: "inspection verify arguments"),
                      resultSchema: R.result(["verdict": .enumeration(["pass", "fail", "incomplete"]), "missing": stringList, "stale": stringList, "failed": stringList, "uncertain": stringList], required: ["verdict"], description: "Coverage"),
                      requiredEvidence: .fixtureTested, examples: [["project": "avatar.vrmauthor", "report": "reports/qa/report.json"]]),
            Operation(name: "provenance inspect", kind: .read, summary: "Ingredient graph and separate binding/signature/trust results", resultDescription: "Ingredient graph and separate binding/signature/trust results",
                      requestSchema: R.request(kind: .read, ["asset": .id, "file": .path], required: [], description: "provenance inspect arguments; at most one of asset/file"),
                      resultSchema: R.result(["ingredients": .array(of: .any()), "binding": .any(), "signature": .any(), "trust": .any()], required: ["ingredients"], description: "Provenance"),
                      requiredEvidence: .fixtureTested, examples: [["project": "avatar.vrmauthor"], ["project": "avatar.vrmauthor", "file": "out/avatar.vrm"]]),
            Operation(name: "provenance resolve", kind: .mutation, summary: "Source-linked VRM metadata and rights conflicts", resultDescription: "Source-linked VRM metadata and rights conflicts",
                      requestSchema: R.request(kind: .mutation, ["declaration": RightsDeclaration.schema], required: ["declaration"], description: "provenance resolve arguments"),
                      resultSchema: R.result(["meta": VRMMeta.schema, "attribution": .any(), "conflicts": .array(of: .any()), "plan": ModelSchemas.plan], required: ["conflicts"], description: "Resolution"),
                      requiredEvidence: .fixtureTested, examples: [["project": "avatar.vrmauthor", "declaration": ["id": "rights:main"]]]),
            Operation(name: "provenance verify", kind: .projectFree, summary: "Credential validation and asset binding report", resultDescription: "Credential validation and asset binding report",
                      requestSchema: R.request(kind: .projectFree, ["file": .path, "manifest": .path, "trustPolicy": Blob.schema], required: ["file", "manifest", "trustPolicy"], description: "provenance verify arguments"),
                      resultSchema: R.result(["binding": .any(), "signature": .any(), "trust": .any(), "verdict": .enumeration(["pass", "fail", "incomplete"])], required: ["verdict"], description: "Verification"),
                      requiredEvidence: .fixtureTested, examples: [["file": "out/avatar.vrm", "manifest": "out/avatar.vrm.c2pa.json", "trustPolicy": ["path": "trust.json", "sha256": .string(String(repeating: "0", count: 64))]]]),
            Operation(name: "export vrm", kind: .read, summary: "Final unsigned bytes and loss/metadata report; unresolved mandatory metadata fails", resultDescription: "Final unsigned bytes and loss/metadata report",
                      requestSchema: R.request(kind: .read, ["target": R.target], required: [], out: true, description: "export vrm arguments"),
                      resultSchema: R.result(["buildHash": .hash, "artifacts": artifactList, "lossReport": lossReport, "meta": VRMMeta.schema], required: ["buildHash", "artifacts"], description: "Export"),
                      requiredEvidence: .visuallyValidated, examples: [["project": "avatar.vrmauthor", "out": "out/avatar.vrm"]]),
            Operation(name: "export verify", kind: .read, summary: "Checks on the exact export under the authoring-v1 suite", resultDescription: "Checks on the exact export, including consumer import and visual evidence",
                      requestSchema: R.request(kind: .read, ["file": .path, "suite": .enumeration(["authoring-v1"]).defaulting(to: "authoring-v1")], required: ["file"], out: true, description: "export verify arguments"),
                      resultSchema: R.result(["verdict": .enumeration(["pass", "fail", "incomplete"]), "checks": checkList, "reportHash": .hash, "artifacts": artifactList], required: ["verdict", "checks"], description: "Verification report"),
                      requiredEvidence: .fixtureTested, examples: [["project": "avatar.vrmauthor", "file": "out/avatar.vrm", "out": "reports/verify"]]),
            Operation(name: "deliver", kind: .read, summary: "VRM, C2PA sidecar/ingredients, editable project, lock, QA and inspections", resultDescription: "Delivery bundle",
                      requestSchema: R.request(kind: .read, [
                          "file": .path, "report": .path, "signer": .string(minLength: 1, description: "Configured credential reference, never a key"), "trustPolicy": Blob.schema,
                      ], required: ["file", "report", "signer", "trustPolicy"], out: true, description: "deliver arguments"),
                      resultSchema: R.result(["artifacts": artifactList, "sidecar": .any(), "ingredients": .array(of: .any()), "verdict": .enumeration(["delivered", "incomplete", "failed"])], required: ["verdict"], description: "Delivery"),
                      requiredEvidence: .fixtureTested, examples: [["project": "avatar.vrmauthor", "file": "out/avatar.vrm", "report": "reports/verify/report.json", "signer": "keys/dev.ed25519", "trustPolicy": ["path": "trust.json", "sha256": .string(String(repeating: "0", count: 64))], "out": "deliver"]]),
        ]
    }
}
