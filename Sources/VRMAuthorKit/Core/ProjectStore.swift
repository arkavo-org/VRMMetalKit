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

/// Persistent project state (project.json). Objects are JSON objects keyed by id
/// carrying `id`, `kind`, `revision`, `provenance` and `writablePointers`.
public struct ProjectState: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var projectId: String
    public var name: String
    public var template: TemplateRef?
    public var seed: UInt64
    public var revision: Int
    public var objects: [String: JSONValue]
    public var recipe: JSONValue?
    public var style: JSONValue?
    public var imports: [JSONValue]

    public init(projectId: String, name: String, template: TemplateRef?, seed: UInt64) {
        self.schemaVersion = 1
        self.projectId = projectId
        self.name = name
        self.template = template
        self.seed = seed
        self.revision = 0
        self.objects = [:]
        self.recipe = nil
        self.style = nil
        self.imports = []
    }

    public func object(id: String) -> ProjectObject? {
        objects[id].flatMap { ProjectObject(json: $0) }
    }

    public var objectIds: [String] { objects.keys.sorted { CompiledAvatar.precedes($0, $1) } }
}

/// Typed view of one stored object.
public struct ProjectObject: Hashable, Sendable {
    public static let reservedKeys: Set<String> = ["id", "kind", "revision", "provenance", "writablePointers"]

    public var id: String
    public var kind: ObjectKind
    public var revision: Int
    public var provenance: JSONValue
    public var writablePointers: [JSONPointer]
    public var fields: [String: JSONValue]

    public init(id: String, kind: ObjectKind, revision: Int = 0, provenance: JSONValue, writablePointers: [String], fields: [String: JSONValue]) throws {
        self.id = id
        self.kind = kind
        self.revision = revision
        self.provenance = provenance
        self.writablePointers = try writablePointers.map { try JSONPointer($0) }
        self.fields = fields.filter { !ProjectObject.reservedKeys.contains($0.key) }
    }

    public init?(json: JSONValue) {
        guard let o = json.object, let id = o["id"]?.string, let kindText = o["kind"]?.string, let kind = ObjectKind(rawValue: kindText),
              let revision = o["revision"]?.int else { return nil }
        let pointers = (o["writablePointers"]?.array ?? []).compactMap { $0.string }.compactMap { try? JSONPointer($0) }
        self.id = id
        self.kind = kind
        self.revision = revision
        self.provenance = o["provenance"] ?? .null
        self.writablePointers = pointers
        self.fields = o.filter { !ProjectObject.reservedKeys.contains($0.key) }
    }

    public var json: JSONValue {
        var o = fields
        o["id"] = .string(id)
        o["kind"] = .string(kind.rawValue)
        o["revision"] = .number(Double(revision))
        o["provenance"] = provenance
        o["writablePointers"] = JSONValue(writablePointers.map(\.description))
        return .object(o)
    }

    public func isWritable(_ pointer: JSONPointer) -> Bool {
        writablePointers.contains { $0.covers(pointer) }
    }
}

public struct RevisionRecord: Codable, Hashable, Sendable {
    public var revision: Int
    public var parent: Int?
    public var requestId: String?
    public var operation: String?
    public var plan: Plan?
    public var state: ProjectState
}

public struct Receipt: Codable, Hashable, Sendable {
    public var requestId: String
    public var payloadHash: String
    public var revisionBefore: Int
    public var revisionAfter: Int
    public var result: ResultEnvelope
}

/// Outcome of a mutation body, recorded into the plan and the revision.
public struct MutationTransaction: Sendable {
    public private(set) var state: ProjectState
    public private(set) var edits: [PlanEdit] = []
    public private(set) var invalidations: [String] = []
    public private(set) var prerequisites: [String] = []
    public var cost: JSONValue = ["cpuSeconds": 0]
    public var artifacts: [ArtifactRef] = []
    public var warnings: [AuthorWarning] = []
    public var operation: String?

    public init(state: ProjectState) { self.state = state }

    public func object(id: String) throws -> ProjectObject {
        guard let object = state.object(id: id) else {
            throw AuthorError(code: .objectNotFound, objectId: id, message: "No object with id '\(id)'.", suggestedCommands: ["object list"])
        }
        return object
    }

    /// Typed validation hook run before a pointer write commits.
    public typealias FieldValidator = (ProjectObject, JSONPointer, JSONValue) throws -> Void

    /// Writes one RFC 6901 pointer inside an object's fields; the pointer must be
    /// covered by the object's writablePointers, and the id/kind/revision/provenance
    /// keys are never writable.
    public mutating func set(objectId: String, pointer: JSONPointer, value: JSONValue, validator: FieldValidator? = nil) throws {
        var object = try self.object(id: objectId)
        guard let first = pointer.tokens.first, !ProjectObject.reservedKeys.contains(first) else {
            throw AuthorError(code: .invalidRequest, objectId: objectId, path: pointer.description, message: "Pointer '\(pointer)' is not a writable field.",
                              suggestedCommands: ["object get"])
        }
        guard object.isWritable(pointer) else {
            throw AuthorError(code: .invalidRequest, objectId: objectId, path: pointer.description, observed: .string(pointer.description),
                              required: JSONValue(object.writablePointers.map(\.description)),
                              message: "Pointer '\(pointer)' is read-only on \(object.kind.rawValue) '\(objectId)'.", suggestedCommands: ["object get"])
        }
        try validator?(object, pointer, value)
        var fields = JSONValue.object(object.fields)
        let before = pointer.get(in: fields)
        try pointer.set(in: &fields, to: value)
        object.fields = fields.object ?? [:]
        object.revision = state.revision + 1
        state.objects[objectId] = object.json
        edits.append(PlanEdit(objectId: objectId, pointer: pointer.description, before: before, after: value))
    }

    public mutating func insert(_ object: ProjectObject) throws {
        guard state.objects[object.id] == nil else {
            throw AuthorError(code: .invalidRequest, objectId: object.id, message: "Object '\(object.id)' already exists.")
        }
        var stored = object
        stored.revision = state.revision + 1
        state.objects[object.id] = stored.json
        edits.append(PlanEdit(objectId: object.id, pointer: "", before: nil, after: stored.json))
    }

    public mutating func replace(_ object: ProjectObject) throws {
        let before = try self.object(id: object.id)
        var stored = object
        stored.revision = state.revision + 1
        state.objects[object.id] = stored.json
        edits.append(PlanEdit(objectId: object.id, pointer: "", before: before.json, after: stored.json))
    }

    public mutating func remove(objectId: String) throws {
        let before = try object(id: objectId)
        state.objects[objectId] = nil
        edits.append(PlanEdit(objectId: objectId, pointer: "", before: before.json, after: nil))
    }

    public mutating func setRecipe(_ recipe: JSONValue?) {
        edits.append(PlanEdit(objectId: "recipe", pointer: "", before: state.recipe, after: recipe))
        state.recipe = recipe
    }

    public mutating func setStyle(_ style: JSONValue?) {
        edits.append(PlanEdit(objectId: "style", pointer: "", before: state.style, after: style))
        state.style = style
    }

    public mutating func appendImport(_ record: JSONValue) {
        edits.append(PlanEdit(objectId: "imports", pointer: "/-", before: nil, after: record))
        state.imports.append(record)
    }

    public mutating func restore(_ snapshot: ProjectState) {
        edits.append(PlanEdit(objectId: "project", pointer: "", before: .number(Double(state.revision)), after: .number(Double(snapshot.revision))))
        var restored = snapshot
        restored.revision = state.revision
        state = restored
    }

    public mutating func invalidate(_ node: String) {
        if !invalidations.contains(node) { invalidations.append(node) }
    }

    public mutating func require(_ prerequisite: String) {
        if !prerequisites.contains(prerequisite) { prerequisites.append(prerequisite) }
    }
}

/// README §3 project layout with atomic writes, revision CAS and request receipts.
public struct ProjectStore: Sendable {
    public let root: URL

    public static let directoryExtension = "vrmauthor"
    public static let tempInfix = ".tmp-"

    public var projectFile: URL { root.appendingPathComponent("project.json") }
    public var lockFile: URL { root.appendingPathComponent("lock.json") }
    public var revisionsDirectory: URL { root.appendingPathComponent("revisions") }
    public var receiptsDirectory: URL { root.appendingPathComponent("receipts") }
    public var assetsDirectory: URL { root.appendingPathComponent("assets").appendingPathComponent("sha256") }
    public var buildsDirectory: URL { root.appendingPathComponent("builds") }
    public var reportsDirectory: URL { root.appendingPathComponent("reports") }
    private var mutexFile: URL { root.appendingPathComponent(".mutex") }

    private init(root: URL) { self.root = root.standardizedFileURL }

    public static func revisionFileName(_ revision: Int) -> String { String(format: "%06d.json", revision) }

    /// Creates the layout and revision 0. `at` is the project directory itself.
    public static func create(at url: URL, name: String, template: TemplateRef?, seed: UInt64, lock: JSONValue) throws -> ProjectStore {
        let fm = FileManager.default
        let store = ProjectStore(root: url)
        if fm.fileExists(atPath: store.projectFile.path) {
            throw AuthorError(code: .invalidRequest, path: url.path, message: "A project already exists at \(url.path).", suggestedCommands: ["project inspect"])
        }
        for dir in [store.root, store.revisionsDirectory, store.receiptsDirectory, store.assetsDirectory, store.buildsDirectory, store.reportsDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let projectId = SHA256Hex.hex("\(name)\u{0}\(template?.id ?? "")\u{0}\(template?.sha256 ?? "")\u{0}\(seed)")
        let state = ProjectState(projectId: projectId, name: name, template: template, seed: seed)
        try store.atomicWrite(try CanonicalJSON.data(lock), to: store.lockFile)
        let record = RevisionRecord(revision: 0, parent: nil, requestId: nil, operation: "project init", plan: nil, state: state)
        try store.atomicWrite(try CanonicalJSON.encode(record), to: store.revisionsDirectory.appendingPathComponent(revisionFileName(0)))
        try store.writeState(state)
        return store
    }

    public static func open(at url: URL) throws -> ProjectStore {
        let store = ProjectStore(root: url)
        guard FileManager.default.fileExists(atPath: store.projectFile.path) else {
            throw AuthorError(code: .projectNotFound, path: url.path, message: "No project.json at \(url.path).", suggestedCommands: ["project init"])
        }
        _ = try store.state()
        return store
    }

    public static func exists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path)
    }

    // MARK: Reads

    public func state() throws -> ProjectState {
        try JSONValue.parse(try Data(contentsOf: projectFile)).decode(ProjectState.self)
    }

    public func lock() throws -> JSONValue {
        try JSONValue.parse(try Data(contentsOf: lockFile))
    }

    public func revisionNumbers() throws -> [Int] {
        let current = try state().revision
        let names = (try? FileManager.default.contentsOfDirectory(atPath: revisionsDirectory.path)) ?? []
        return names.compactMap { name -> Int? in
            guard name.count == 11, name.hasSuffix(".json"), let n = Int(name.dropLast(5)), ProjectStore.revisionFileName(n) == name else { return nil }
            return n <= current ? n : nil
        }.sorted()
    }

    public func revision(_ number: Int) throws -> RevisionRecord {
        let url = revisionsDirectory.appendingPathComponent(ProjectStore.revisionFileName(number))
        guard number >= 0, number <= (try state().revision), FileManager.default.fileExists(atPath: url.path) else {
            throw AuthorError(code: .invalidRequest, path: "/revision", observed: .number(Double(number)), message: "Revision \(number) does not exist.", suggestedCommands: ["history list"])
        }
        return try JSONValue.parse(try Data(contentsOf: url)).decode(RevisionRecord.self)
    }

    public func receipt(requestId: String) throws -> Receipt? {
        let url = receiptsDirectory.appendingPathComponent(ProjectStore.receiptFileName(requestId))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let receipt = try JSONValue.parse(try Data(contentsOf: url)).decode(Receipt.self)
        return receipt.revisionAfter <= (try state().revision) ? receipt : nil
    }

    public func receipts() throws -> [Receipt] {
        let current = try state().revision
        let names = (try? FileManager.default.contentsOfDirectory(atPath: receiptsDirectory.path)) ?? []
        return try names.filter { $0.hasSuffix(".json") && !$0.contains(ProjectStore.tempInfix) }.sorted().compactMap { name in
            let receipt = try JSONValue.parse(try Data(contentsOf: receiptsDirectory.appendingPathComponent(name))).decode(Receipt.self)
            return receipt.revisionAfter <= current ? receipt : nil
        }.sorted { $0.revisionAfter < $1.revisionAfter }
    }

    public static func receiptFileName(_ requestId: String) -> String {
        let safe = requestId.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "." }
        return (safe && requestId.count <= 128 ? requestId : SHA256Hex.hex(requestId)) + ".json"
    }

    /// Payload hash for idempotency: the request minus requestId, dryRun and expectedPlanHash.
    public static func payloadHash(_ payload: JSONValue) throws -> String {
        var o = payload.object ?? [:]
        o["requestId"] = nil
        o["dryRun"] = nil
        o["expectedPlanHash"] = nil
        return try CanonicalJSON.sha256(.object(o))
    }

    // MARK: Mutation

    /// Atomic mutation with CAS on `expectedRevision`, receipt replay on
    /// `requestId`, dry-run plans that consume nothing, and `expectedPlanHash`.
    public func mutate(requestId: String, payload: JSONValue, expectedRevision: Int?, dryRun: Bool, expectedPlanHash: String?, operation: String? = nil,
                       body: (inout MutationTransaction) throws -> JSONValue?) throws -> ResultEnvelope {
        let mutex = try ProcessMutex(path: mutexFile.path)
        defer { mutex.release() }

        let hash = try ProjectStore.payloadHash(payload)
        if !dryRun, let receipt = try receipt(requestId: requestId) {
            guard receipt.payloadHash == hash else {
                throw AuthorError(code: .requestIdReused, path: "/requestId", observed: .string(hash), required: .string(receipt.payloadHash),
                                  message: "requestId '\(requestId)' was already used with a different payload.", suggestedCommands: ["history list"])
            }
            return receipt.result
        }
        let current = try state()
        if let expectedRevision, expectedRevision != current.revision {
            throw AuthorError(code: .revisionConflict, path: "/expectedRevision", observed: .number(Double(current.revision)), required: .number(Double(expectedRevision)),
                              message: "Project is at revision \(current.revision), expected \(expectedRevision).", suggestedCommands: ["project inspect"])
        }
        var transaction = MutationTransaction(state: current)
        transaction.operation = operation
        let result = try body(&transaction)
        let plan = try Plan.hashed(baseRevision: current.revision, edits: transaction.edits, invalidations: transaction.invalidations,
                                   prerequisites: transaction.prerequisites, cost: transaction.cost)
        if dryRun {
            var envelope = ResultEnvelope.succeeded(requestId: requestId, revisionBefore: current.revision, revisionAfter: current.revision, result: result)
            envelope.plan = plan
            envelope.warnings = transaction.warnings
            return envelope
        }
        if let expectedPlanHash, expectedPlanHash != plan.planHash {
            throw AuthorError(code: .planHashMismatch, path: "/expectedPlanHash", observed: .string(plan.planHash), required: .string(expectedPlanHash),
                              message: "The plan for this request differs from the inspected plan.", suggestedCommands: ["--dry-run"])
        }
        var next = transaction.state
        next.revision = current.revision + 1
        var envelope = ResultEnvelope.succeeded(requestId: requestId, revisionBefore: current.revision, revisionAfter: next.revision, result: result)
        envelope.plan = plan
        envelope.artifacts = transaction.artifacts
        envelope.warnings = transaction.warnings
        let record = RevisionRecord(revision: next.revision, parent: current.revision, requestId: requestId, operation: operation, plan: plan, state: next)
        try atomicWrite(try CanonicalJSON.encode(record), to: revisionsDirectory.appendingPathComponent(ProjectStore.revisionFileName(next.revision)))
        let receipt = Receipt(requestId: requestId, payloadHash: hash, revisionBefore: current.revision, revisionAfter: next.revision, result: envelope)
        try atomicWrite(try CanonicalJSON.encode(receipt), to: receiptsDirectory.appendingPathComponent(ProjectStore.receiptFileName(requestId)))
        try writeState(next)
        return envelope
    }

    // MARK: Files

    private func writeState(_ state: ProjectState) throws {
        try atomicWrite(try CanonicalJSON.encode(state), to: projectFile)
    }

    /// Writes to `<name>.tmp-<pid>-<nonce>` in the same directory, then renames over the target.
    public func atomicWrite(_ data: Data, to url: URL) throws {
        try ProjectStore.atomicWrite(data, to: url)
    }

    public static func atomicWrite(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appendingPathComponent(url.lastPathComponent + tempInfix + "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        do {
            try data.write(to: temp, options: [])
            guard rename(temp.path, url.path) == 0 else {
                let code = errno
                try? FileManager.default.removeItem(at: temp)
                throw AuthorError(code: .ioError, path: url.path, message: "rename failed: \(String(cString: strerror(code)))")
            }
        } catch let error as AuthorError {
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw AuthorError(code: .ioError, path: url.path, message: "write failed: \(error)")
        }
    }

    /// Stores bytes under assets/sha256/<hash> and returns the hash.
    public func storeAsset(_ data: Data) throws -> String {
        let hash = SHA256Hex.hex(data)
        let url = assetsDirectory.appendingPathComponent(hash)
        if !FileManager.default.fileExists(atPath: url.path) { try atomicWrite(data, to: url) }
        return hash
    }
}

/// flock-based cross-process mutex; released on process death.
final class ProcessMutex {
    private let descriptor: Int32

    init(path: String) throws {
        descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw AuthorError(code: .ioError, path: path, message: "cannot open mutex: \(String(cString: strerror(errno)))") }
        guard flock(descriptor, LOCK_EX) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw AuthorError(code: .ioError, path: path, message: "cannot lock project: \(String(cString: strerror(code)))")
        }
    }

    func release() {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}
