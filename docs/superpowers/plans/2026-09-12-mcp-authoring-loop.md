# MCP Authoring Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 1:1 MCP projection of the vrm-author registry with six facade tools, two generated starter-recipe resources, and QA results that carry preview images, leaving the 35 CLI/JSON-RPC commands untouched.

**Architecture:** `ServeSession.dispatchMCP` routes `tools/*` to a new `MCPFacade` (tool table + per-operation evidence gate + composition over the existing public `invokeOperation`) and `resources/*` to a new `MCPResources` (starter recipes generated from the `native-anime-v1` pack defaults plus a pointer-keyed override table). `vrm_qa` runs the locked `qa run` unchanged, then a `QAPreviewRenderer` re-renders selected scenarios at a small size through the session's `RenderAdapter` and base64-encodes the PNG bytes as MCP image content.

**Tech Stack:** Swift 6.2 package `VRMAuthorKit` (Foundation + CryptoKit only), XCTest, MCP 2025-06-18 over newline-delimited JSON-RPC, `scripts/repin_packs.py`.

**Spec:** `docs/superpowers/specs/2026-09-12-mcp-authoring-loop-design.md` (§3–§5, §7–§8). §6 (craft on the starters) is a separate plan.

## Global Constraints

- `Sources/VRMAuthorKit` imports only Foundation and CryptoKit (no Metal, no AppKit, no ImageIO). There is no PNG decoder; never decode or resample an image in-process.
- New files carry the Apache 2.0 header used by every file in `Sources/VRMAuthorKit` (copy it from `Sources/VRMAuthorKit/Serve/ServeHandlers.swift` lines 1–15).
- No temporary or explanatory comments in code (CLAUDE.md rule). Doc comments that describe what a type is for are fine.
- Tests run with `swift test --filter <Name> --disable-sandbox`. `--filter` only filters execution, so every test file must compile.
- Commit after each task. Do not push.
- `expectedRevision` is never auto-filled by the facade. `isError` is true only for protocol/handler errors; a QA verdict is a result. `motion.idle` is never previewed. Preview hashes never enter any report, evidence file or pack.
- Override pointers are RFC 6901 and must resolve to existing locations in the default recipe (`/body/body.heightM`, `/hair/0/controls/lengthM`, `/outfits/1/preset`).
- `vrm_build` defaults `out` to `<project>/draft.vrm`; nothing but `BuildSupport.recordBuild` writes under `builds/`.
- The Serve tests are pinned by `docs/proposals/vrm-author-cli/acceptance/packs/serve.json`; the final task re-pins with `python3 scripts/repin_packs.py`.

---

## File map

| File | Responsibility |
|---|---|
| `Sources/VRMAuthorKit/Template/NativeAnime/NativeAnimeStarters.swift` (new) | `NativeAnimeStarterBase` enum, override tables, `starterRecipe(base:registry:)` |
| `Sources/VRMAuthorKit/Serve/MCPResources.swift` (new) | Resource URIs, `resources/list` and `resources/read` results |
| `Sources/VRMAuthorKit/Serve/MCPFacade.swift` (new) | `MCPFacadeTool` table, evidence gate, descriptors, `tools/call` composition, text summaries |
| `Sources/VRMAuthorKit/QA/QAPreviewRenderer.swift` (new) | Preview pass over a `RenderAdapter` at a small size; PNG bytes → base64 image blocks |
| `Sources/VRMAuthorKit/Serve/ServeSession.swift` (modify) | `previewRenderer` property; `dispatchMCP` routes to facade/resources; `initialize` capabilities + instructions |
| `Sources/VRMAuthorKit/Serve/ServeHandlers.swift` (modify) | Passes `VRMAuthorRenderAdapter()` as the preview renderer |
| `Tests/VRMAuthorKitTests/Template/NativeAnimeStartersTests.swift` (new) | Override pointers resolve, recipes validate, seed/name/template hash |
| `Tests/VRMAuthorKitTests/Serve/MCPResourcesTests.swift` (new) | Wire shape of `resources/list`/`read`, `-32002` |
| `Tests/VRMAuthorKitTests/Serve/MCPFacadeTests.swift` (new) | Tool list/gating, each tool's composition, end-to-end loop, image blocks with a fake renderer |
| `Tests/VRMAuthorKitTests/Serve/MCPClientTests.swift` (modify) | Assertions that encoded the 1:1 surface move to the facade shape |
| `docs/proposals/vrm-author-cli/README.md`, `commands.md`, `CLAUDE.md` (modify) | MCP adapter description |

Shared test fixture: every MCP test that needs a real pack uses
`TemplateRegistry.standard()` (the `native-anime-v1` pack), not
`StubTemplatePack`, because starters and the end-to-end loop compile real
geometry. `ProjectTestHarness.context(cwd:…, templates: TemplateRegistry.standard())`
does that.

---

### Task 1: Starter recipes from the native-anime pack

**Files:**
- Create: `Sources/VRMAuthorKit/Template/NativeAnime/NativeAnimeStarters.swift`
- Test: `Tests/VRMAuthorKitTests/Template/NativeAnimeStartersTests.swift`

**Interfaces:**
- Consumes: `TemplateRegistry.standard()`, `TemplateRegistry.pack(id:)`, `TemplatePack.defaults: Recipe`, `Recipe.jsonValue()` / `Recipe.decode(_:)` (every `AuthorModel` has both), `JSONPointer(_ text: String) throws`, `JSONPointer.get(in:)`, `JSONPointer.set(in:to:)`.
- Produces:
  ```swift
  public enum NativeAnimeStarterBase: String, CaseIterable, Sendable { case female, male }
  public enum NativeAnimeStarters {
      public static let seed: UInt64 = 42
      public static func overrides(for base: NativeAnimeStarterBase) -> [(pointer: String, value: JSONValue)]
      /// The pack default recipe with `seed`, `name` and the base's overrides applied. Throws AuthorError(.missingCapability) when the pack is not installed and AuthorError(.internalError) when a pointer does not resolve.
      public static func starterRecipe(base: NativeAnimeStarterBase, registry: TemplateRegistry) throws -> Recipe
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/VRMAuthorKitTests/Template/NativeAnimeStartersTests.swift
import XCTest
@testable import VRMAuthorKit

final class NativeAnimeStartersTests: XCTestCase {
    private let registry = TemplateRegistry.standard()

    func testEveryOverridePointerResolvesInTheDefaultRecipe() throws {
        let pack = try XCTUnwrap(registry.pack(id: NativeAnimeV1Pack.packId))
        let defaults = try pack.defaults.jsonValue()
        for base in NativeAnimeStarterBase.allCases {
            for override in NativeAnimeStarters.overrides(for: base) {
                let pointer = try JSONPointer(override.pointer)
                XCTAssertNotNil(pointer.get(in: defaults), "\(base): \(override.pointer) does not exist in the default recipe")
            }
        }
    }

    func testStartersValidateAndDifferOnlyByOverrides() throws {
        let pack = try XCTUnwrap(registry.pack(id: NativeAnimeV1Pack.packId))
        for base in NativeAnimeStarterBase.allCases {
            let recipe = try NativeAnimeStarters.starterRecipe(base: base, registry: registry)
            XCTAssertNoThrow(try recipe.validate())
            XCTAssertEqual(recipe.seed, 42)
            XCTAssertEqual(recipe.name, base.rawValue)
            XCTAssertEqual(recipe.template.sha256, pack.sha256)
            let json = try recipe.jsonValue()
            for override in NativeAnimeStarters.overrides(for: base) {
                XCTAssertEqual(try JSONPointer(override.pointer).get(in: json), override.value, "\(base): \(override.pointer)")
            }
            XCTAssertEqual(recipe.hair.first?.id, "hair.main")
            XCTAssertEqual(recipe.outfits.map(\.id), ["outfit.top", "outfit.bottom", "outfit.footwear"])
        }
        let female = try NativeAnimeStarters.starterRecipe(base: .female, registry: registry)
        let male = try NativeAnimeStarters.starterRecipe(base: .male, registry: registry)
        XCTAssertEqual(female.outfits[1].preset, "skirt-v1")
        XCTAssertEqual(male.outfits[1].preset, "bottom-v1")
        XCTAssertEqual(female.body["body.heightM"], 1.60)
        XCTAssertEqual(male.body["body.heightM"], 1.74)
        XCTAssertEqual(male.hair[0].controls.lengthM, 0.13)
    }

    func testOverridesStayInsidePublishedControlRanges() throws {
        let pack = try XCTUnwrap(registry.pack(id: NativeAnimeV1Pack.packId))
        for base in NativeAnimeStarterBase.allCases {
            let recipe = try NativeAnimeStarters.starterRecipe(base: base, registry: registry)
            for (key, value) in recipe.body.merging(recipe.face, uniquingKeysWith: { a, _ in a }) {
                let descriptor = try XCTUnwrap(pack.control(key), key)
                XCTAssertTrue(descriptor.accepts(value), "\(base): \(key)=\(value) outside \(descriptor.validRange)")
            }
        }
    }

    func testStartersCompile() throws {
        for base in NativeAnimeStarterBase.allCases {
            let recipe = try NativeAnimeStarters.starterRecipe(base: base, registry: registry)
            let pack = try XCTUnwrap(registry.pack(id: recipe.template.id))
            XCTAssertNoThrow(try pack.compile(recipe, seed: recipe.seed), "\(base)")
        }
    }

    func testUnknownPackIsMissingCapability() {
        XCTAssertThrowsError(try NativeAnimeStarters.starterRecipe(base: .female, registry: TemplateRegistry(packs: []))) { error in
            XCTAssertEqual((error as? AuthorError)?.code, .missingCapability)
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter NativeAnimeStartersTests --disable-sandbox`
Expected: compile error, `NativeAnimeStarters` not found.

- [ ] **Step 3: Implement the starters**

```swift
// Sources/VRMAuthorKit/Template/NativeAnime/NativeAnimeStarters.swift
// (Apache 2.0 header)
import Foundation

public enum NativeAnimeStarterBase: String, CaseIterable, Sendable {
    case female, male
}

/// Two human bases over the native-anime pack defaults. Each is the default
/// recipe with seed 42, the base's name and an ordered override table applied
/// by JSON pointer; every pointer must already exist in the default recipe.
public enum NativeAnimeStarters {
    public static let seed: UInt64 = 42

    public static func overrides(for base: NativeAnimeStarterBase) -> [(pointer: String, value: JSONValue)] {
        switch base {
        case .female:
            return [
                ("/body/body.heightM", 1.60), ("/body/body.headCount", 6.6),
                ("/body/body.proportion.shoulderWidth", -0.20), ("/body/body.proportion.hipWidth", 0.30),
                ("/body/body.proportion.torsoLength", 0),
                ("/body/body.shape.chest", 0.45), ("/body/body.shape.waist", -0.35), ("/body/body.shape.hip", 0.35), ("/body/body.shape.muscle", -0.10),
                ("/face/face.jaw.width", -0.25), ("/face/face.chin.length", -0.15), ("/face/face.chin.pointedness", 0.20),
                ("/face/face.eye.left.height", 0.25), ("/face/face.eye.right.height", 0.25),
                ("/face/face.brow.left.thickness", -0.20), ("/face/face.brow.right.thickness", -0.20),
                ("/face/face.lip.fullness", 0.20),
                ("/hair/0/preset", "bob-v1"), ("/hair/0/controls/lengthM", 0.20), ("/hair/0/controls/tipBendDeg", 12),
                ("/outfits/1/preset", "skirt-v1"),
            ]
        case .male:
            return [
                ("/body/body.heightM", 1.74), ("/body/body.headCount", 7.2),
                ("/body/body.proportion.shoulderWidth", 0.45), ("/body/body.proportion.hipWidth", -0.20),
                ("/body/body.proportion.torsoLength", 0.10),
                ("/body/body.shape.chest", -0.10), ("/body/body.shape.waist", 0.10), ("/body/body.shape.hip", -0.15), ("/body/body.shape.muscle", 0.35),
                ("/face/face.jaw.width", 0.35), ("/face/face.chin.length", 0.20), ("/face/face.chin.pointedness", -0.10),
                ("/face/face.eye.left.height", -0.15), ("/face/face.eye.right.height", -0.15),
                ("/face/face.brow.left.thickness", 0.35), ("/face/face.brow.right.thickness", 0.35),
                ("/face/face.lip.fullness", -0.20),
                ("/hair/0/preset", "bob-v1"), ("/hair/0/controls/lengthM", 0.13), ("/hair/0/controls/tipBendDeg", 0),
                ("/outfits/1/preset", "bottom-v1"),
            ]
        }
    }

    public static func starterRecipe(base: NativeAnimeStarterBase, registry: TemplateRegistry) throws -> Recipe {
        guard let pack = registry.pack(id: NativeAnimeV1Pack.packId) else {
            throw AuthorError(code: .missingCapability, path: "/template", observed: .string(NativeAnimeV1Pack.packId),
                              message: "Template pack '\(NativeAnimeV1Pack.packId)' is not installed.", suggestedCommands: ["template list"])
        }
        var json = try pack.defaults.jsonValue()
        for override in overrides(for: base) {
            let pointer = try JSONPointer(override.pointer)
            guard pointer.get(in: json) != nil else {
                throw AuthorError(code: .internalError, path: override.pointer, message: "Starter override does not resolve in the pack default recipe.", suggestedCommands: ["template list"])
            }
            try pointer.set(in: &json, to: override.value)
        }
        var recipe = try Recipe.decode(json)
        recipe.seed = seed
        recipe.name = base.rawValue
        try recipe.validate()
        return recipe
    }
}
```

If `JSONValue` lacks `ExpressibleByIntegerLiteral`/`FloatLiteral`/`StringLiteral` conformances the literal table will not compile; check `Sources/VRMAuthorKit/Core/JSONValue.swift` (the registry schemas use `["seed": 7]` and `"version"` literals, so they exist). If `HairControls.lengthM` is not the property name, read `Sources/VRMAuthorKit/Model/HairItem.swift` and use the real one in the test.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter NativeAnimeStartersTests --disable-sandbox`
Expected: 5 tests pass. If `testOverridesStayInsidePublishedControlRanges` fails on a value, lower that value to the descriptor's range in the table (the spec fixes pointers, not values) and note it in the commit message.

- [ ] **Step 5: Commit**

```bash
git add Sources/VRMAuthorKit/Template/NativeAnime/NativeAnimeStarters.swift Tests/VRMAuthorKitTests/Template/NativeAnimeStartersTests.swift
git commit -m "vrm-author: female/male starter recipes over the native-anime pack"
```

---

### Task 2: MCP resources for the starters

**Files:**
- Create: `Sources/VRMAuthorKit/Serve/MCPResources.swift`
- Modify: `Sources/VRMAuthorKit/Serve/ServeSession.swift` (`dispatchMCP`, `initialize`)
- Test: `Tests/VRMAuthorKitTests/Serve/MCPResourcesTests.swift`

**Interfaces:**
- Consumes: `NativeAnimeStarters.starterRecipe(base:registry:)` (Task 1), `CanonicalJSON.string(_:)`.
- Produces:
  ```swift
  public enum MCPResources {
      public static let scheme = "recipe"
      public static let resourceNotFound = -32002
      public static var uris: [String]                                  // ["recipe://native-anime-v1/female", "recipe://native-anime-v1/male"]
      public static func list() -> JSONValue                            // {"resources":[{uri,name,title,description,mimeType}]}
      public static func read(uri: String, templates: TemplateRegistry) throws -> JSONValue   // {"contents":[{uri,mimeType,text}]}; throws RPCError(-32002)
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/VRMAuthorKitTests/Serve/MCPResourcesTests.swift
import XCTest
@testable import VRMAuthorKit

final class MCPResourcesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try ProjectTestHarness.makeRoot() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func session(env: [String: String] = [:]) -> ServeSession {
        ServeSession(context: ProjectTestHarness.context(cwd: root, env: env, templates: TemplateRegistry.standard()), protocol: .mcp,
                     harness: ServeHandlers.isHarness(env: env))
    }

    private func exchange(_ session: inout ServeSession, _ line: String) throws -> JSONValue {
        try JSONValue.parse(try XCTUnwrap(session.handle(line: line), line))
    }

    func testInitializeDeclaresResources() throws {
        var server = session()
        let initialize = try exchange(&server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}"#)
        XCTAssertEqual(initialize["result"]?["capabilities"]?["resources"], ["subscribe": false, "listChanged": false])
        XCTAssertEqual(initialize["result"]?["capabilities"]?["tools"], ["listChanged": false])
        let instructions = try XCTUnwrap(initialize["result"]?["instructions"]?.string)
        XCTAssertTrue(instructions.contains("recipe://native-anime-v1/female"))
        XCTAssertTrue(instructions.contains("vrm_qa"))
    }

    func testListAndReadInEverySession() throws {
        for env in [[:], ["VRM_AUTHOR_SESSION": "harness"]] {
            var server = session(env: env)
            let list = try exchange(&server, #"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#)
            let resources = try XCTUnwrap(list["result"]?["resources"]?.array)
            XCTAssertEqual(resources.compactMap { $0["uri"]?.string }, ["recipe://native-anime-v1/female", "recipe://native-anime-v1/male"])
            XCTAssertEqual(resources[0]["mimeType"], "application/json")
            XCTAssertEqual(resources[0]["name"], "female")
            XCTAssertNotNil(resources[0]["description"]?.string)

            let read = try exchange(&server, #"{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"recipe://native-anime-v1/male"}}"#)
            let contents = try XCTUnwrap(read["result"]?["contents"]?.array)
            XCTAssertEqual(contents.count, 1)
            XCTAssertEqual(contents[0]["uri"], "recipe://native-anime-v1/male")
            XCTAssertEqual(contents[0]["mimeType"], "application/json")
            let recipe = try Recipe.decode(try JSONValue.parse(try XCTUnwrap(contents[0]["text"]?.string)))
            XCTAssertEqual(recipe.name, "male")
            XCTAssertEqual(recipe.seed, 42)
            XCTAssertEqual(recipe.template.sha256, TemplateRegistry.standard().templateHashes()[NativeAnimeV1Pack.packId])
        }
    }

    func testUnknownResourceIsMinus32002() throws {
        var server = session()
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{"uri":"recipe://native-anime-v1/robot"}}"#)["error"]?["code"], -32002)
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{}}"#)["error"]?["code"], -32602)
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","id":3,"method":"resources/templates/list"}"#)["result"]?["resourceTemplates"], [])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MCPResourcesTests --disable-sandbox`
Expected: `testInitializeDeclaresResources` fails on `capabilities.resources`; the other two fail with `-32601`.

- [ ] **Step 3: Implement `MCPResources`**

```swift
// Sources/VRMAuthorKit/Serve/MCPResources.swift
// (Apache 2.0 header)
import Foundation

/// MCP resources: starter Recipe documents an agent reads, edits and passes
/// to `vrm_recipe apply`. They are generated from the installed pack on every
/// read, so `template.sha256` always matches the pack the session can build.
public enum MCPResources {
    public static let scheme = "recipe"
    public static let resourceNotFound = -32002
    public static let mimeType = "application/json"

    static let bases: [(uri: String, base: NativeAnimeStarterBase, description: String)] = [
        ("recipe://native-anime-v1/female", .female, "Female starter Recipe for the native-anime-v1 pack (seed 42): bob, top, skirt, footwear."),
        ("recipe://native-anime-v1/male", .male, "Male starter Recipe for the native-anime-v1 pack (seed 42): short bob, top, bottom, footwear."),
    ]

    public static var uris: [String] { bases.map(\.uri) }

    public static func list() -> JSONValue {
        ["resources": .array(bases.map { entry in
            ["uri": .string(entry.uri), "name": .string(entry.base.rawValue), "title": .string("Starter recipe: \(entry.base.rawValue)"),
             "description": .string(entry.description), "mimeType": .string(mimeType)]
        })]
    }

    public static func read(uri: String, templates: TemplateRegistry) throws -> JSONValue {
        guard let entry = bases.first(where: { $0.uri == uri }) else {
            throw RPCError(code: resourceNotFound, message: "Resource not found: \(uri)", data: ["availableResources": JSONValue(uris)])
        }
        let recipe: Recipe
        do { recipe = try NativeAnimeStarters.starterRecipe(base: entry.base, registry: templates) }
        catch let error as AuthorError { throw RPCError(code: RPCError.internalError, message: error.message, data: ["code": .string(error.code.rawValue)]) }
        let text = try CanonicalJSON.string(try recipe.jsonValue())
        return ["contents": [["uri": .string(uri), "mimeType": .string(mimeType), "text": .string(text)]]]
    }
}
```

- [ ] **Step 4: Route `resources/*` and declare the capability in `ServeSession`**

In `Sources/VRMAuthorKit/Serve/ServeSession.swift`, inside `dispatchMCP`:

Replace the `initialize` return with:

```swift
            return [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false], "resources": ["subscribe": false, "listChanged": false]],
                "serverInfo": ["name": .string(context.toolInfo.tool), "version": .string(context.toolInfo.version), "title": "vrm-author"],
                "instructions": .string(ServeSession.mcpInstructions),
            ]
```

Add the static string (next to `mcpProtocolVersion`):

```swift
    public static let mcpInstructions = """
    vrm-author authoring loop. 1) resources/read recipe://native-anime-v1/female or recipe://native-anime-v1/male for a complete starter Recipe. \
    2) vrm_project {action:"init"} to create a project, then edit the Recipe document (for example /body/body.heightM) and vrm_recipe {action:"apply", recipe, expectedRevision}. \
    3) vrm_build, then vrm_qa: read the checks and look at the preview images, patch the Recipe, apply again. 4) vrm_export when the checks pass. \
    vrm_discover lists control ranges and presets. Every result carries revision; mutations require expectedRevision. Preview images are views, not evidence.
    """
```

Add the cases before `default:`:

```swift
        case "resources/list":
            let p = try paramsObject(params)
            if p["cursor"] != nil { throw RPCError(code: RPCError.invalidParams, message: "Invalid params: unknown cursor") }
            return MCPResources.list()
        case "resources/templates/list":
            return ["resourceTemplates": []]
        case "resources/read":
            let p = try paramsObject(params)
            guard let uri = p["uri"]?.string else { throw RPCError(code: RPCError.invalidParams, message: "Invalid params: uri is required") }
            return try MCPResources.read(uri: uri, templates: context.templates)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter MCPResourcesTests --disable-sandbox`
Expected: 3 tests pass. `MCPClientTests.testInitializeListAndCallAsAnIndependentClient` now fails on its `capabilities` equality and `testToolCallMutationsFailuresAndUnknownTools` on `resources/list` → -32601; both are rewritten in Task 3.

- [ ] **Step 6: Commit**

```bash
git add Sources/VRMAuthorKit/Serve/MCPResources.swift Sources/VRMAuthorKit/Serve/ServeSession.swift Tests/VRMAuthorKitTests/Serve/MCPResourcesTests.swift
git commit -m "vrm-author: MCP starter recipe resources"
```

---

### Task 3: Facade tool table, gating and `tools/list`

**Files:**
- Create: `Sources/VRMAuthorKit/Serve/MCPFacade.swift`
- Modify: `Sources/VRMAuthorKit/Serve/ServeSession.swift` (`tools/list`, `tools/call`, `exposedOperations`, `toolDescriptor`)
- Modify: `Tests/VRMAuthorKitTests/Serve/MCPClientTests.swift`
- Test: `Tests/VRMAuthorKitTests/Serve/MCPFacadeTests.swift`

**Interfaces:**
- Consumes: `ServeSession.invokeOperation(_:params:isNotification:)`, `EvidenceRegistry.capability(for:toolInfo:policy:).productionEligible`, `Registry.operation(named:)`.
- Produces:
  ```swift
  public struct MCPFacadeTool: Sendable {
      public var name: String            // "vrm_discover" …
      public var title: String
      public var description: String
      public var operations: [String]    // registry operation names it maps to
      public var inputSchema: JSONSchema
      public var readOnly: Bool
      public var idempotent: Bool
  }
  public enum MCPFacade {
      public static let tools: [MCPFacadeTool]                       // six, in loop order
      public static func tool(named name: String) -> MCPFacadeTool?
      public static func eligible(_ operationName: String, session: ServeSession) -> Bool
      public static func listed(session: ServeSession) -> [MCPFacadeTool]   // any mapped op eligible, or harness
      public static func descriptor(_ tool: MCPFacadeTool) -> JSONValue
      public static func call(_ tool: MCPFacadeTool, arguments: [String: JSONValue], session: ServeSession) throws -> JSONValue  // tools/call result
      // internal helpers used by Tasks 4–6:
      static func invoke(_ operationName: String, params: [String: JSONValue], session: ServeSession, tool: String) throws -> InvokeOutcome
      static func toolResult(envelope: JSONValue, revision: JSONValue, isError: Bool, text: String, extra: [String: JSONValue] = [:], images: [JSONValue] = []) -> JSONValue
      static func summary(tool: String, envelope: JSONValue) -> String
      static func missingCapability(tool: String, operation: String, session: ServeSession) -> JSONValue
  }
  enum InvokeOutcome { case envelope(JSONValue); case refused(JSONValue) }   // refused = ready tools/call result
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/VRMAuthorKitTests/Serve/MCPFacadeTests.swift
import XCTest
@testable import VRMAuthorKit

final class MCPFacadeTests: XCTestCase {
    static let toolNames = ["vrm_discover", "vrm_project", "vrm_recipe", "vrm_build", "vrm_qa", "vrm_export"]
    var root: URL!

    override func setUpWithError() throws { root = try ProjectTestHarness.makeRoot() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// Fixture-tested, current evidence for the named operations.
    func evidence(admitting names: [String]) -> EvidenceRegistry {
        let registry = Registry.v1()
        var evidence = EvidenceRegistry()
        for name in names {
            let op = registry.operation(named: name)!
            let packHash = SHA256Hex.hex("pack-\(name)")
            evidence.packs[name] = AcceptancePackSummary(id: name, operation: name, packHash: packHash, requestSchemaHash: op.schemaHash, resultSchemaHash: op.resultSchemaHash,
                                                         requiredLevel: .fixtureTested, dimensions: ["fixture": "required"], oracleHashes: [:], path: "x")
            evidence.entries.append(EvidenceEntry(operation: name, packHash: packHash, requestSchemaHash: op.schemaHash, evidenceLevel: .fixtureTested, evidenceStatus: .current,
                                                  dimensions: ["fixture": DimensionRecord(status: .pass, reportHash: String(repeating: "1", count: 64))]))
        }
        return evidence
    }

    func session(env: [String: String] = [:], evidence: EvidenceRegistry = EvidenceRegistry(), policy: EvidencePolicy = .release,
                 previewRenderer: (any RenderAdapter)? = nil) -> ServeSession {
        ServeSession(context: ProjectTestHarness.context(cwd: root, env: env, evidence: evidence, templates: TemplateRegistry.standard()), protocol: .mcp,
                     policy: policy, harness: ServeHandlers.isHarness(env: env), previewRenderer: previewRenderer)
    }

    func exchange(_ session: inout ServeSession, _ line: String) throws -> JSONValue {
        let response = try XCTUnwrap(session.handle(line: line), line)
        XCTAssertFalse(response.contains("\n"))
        return try JSONValue.parse(response)
    }

    func call(_ session: inout ServeSession, id: Int, _ tool: String, _ arguments: [String: JSONValue]) throws -> JSONValue {
        let line = try CanonicalJSON.string(["jsonrpc": "2.0", "id": .number(Double(id)), "method": "tools/call", "params": ["name": .string(tool), "arguments": .object(arguments)]])
        return try exchange(&session, line)
    }

    func toolNames(_ session: inout ServeSession) throws -> [String] {
        try XCTUnwrap(try exchange(&session, #"{"jsonrpc":"2.0","id":99,"method":"tools/list"}"#)["result"]?["tools"]?.array).compactMap { $0["name"]?.string }
    }

    // MARK: Listing and gating

    func testHarnessListsExactlyTheSixFacadeTools() throws {
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"])
        XCTAssertEqual(try toolNames(&server), Self.toolNames)
        let tools = try XCTUnwrap(try exchange(&server, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)["result"]?["tools"]?.array)
        let discover = try XCTUnwrap(tools.first { $0["name"] == "vrm_discover" })
        XCTAssertEqual(discover["annotations"]?["readOnlyHint"], true)
        XCTAssertEqual(discover["inputSchema"]?["type"], "object")
        let recipe = try XCTUnwrap(tools.first { $0["name"] == "vrm_recipe" })
        XCTAssertEqual(recipe["annotations"]?["readOnlyHint"], false)
        XCTAssertEqual(recipe["annotations"]?["idempotentHint"], true)
        XCTAssertEqual(recipe["inputSchema"]?["properties"]?["action"]?["enum"], ["export", "apply"])
        for tool in tools { XCTAssertFalse(try XCTUnwrap(tool["name"]?.string).contains("."), "registry rpcMethods are not MCP tools") }
    }

    func testReleaseWithNoEvidenceListsNothingAndRefusesCalls() throws {
        var server = session()
        XCTAssertEqual(try toolNames(&server), [])
        let refused = try call(&server, id: 2, "vrm_discover", [:])
        XCTAssertEqual(refused["error"]?["code"], -32602)
        XCTAssertEqual(refused["error"]?["data"]?["availableTools"], [])
    }

    func testToolAppearsWhenAnyMappedOperationIsAdmittedAndRefusesTheOther() throws {
        var server = session(evidence: evidence(admitting: ["project init"]))
        XCTAssertEqual(try toolNames(&server), ["vrm_project"])
        let dir = root.appendingPathComponent("p.vrmauthor")
        let initialised = try call(&server, id: 1, "vrm_project", ["action": "init", "dir": .string(dir.path), "template": "native-anime-v1", "seed": 3])
        XCTAssertEqual(initialised["result"]?["isError"], false)
        XCTAssertEqual(initialised["result"]?["structuredContent"]?["revision"], 0)
        let inspect = try call(&server, id: 2, "vrm_project", ["action": "inspect", "project": .string(dir.path)])
        XCTAssertNil(inspect["error"])
        XCTAssertEqual(inspect["result"]?["isError"], true)
        let error = try XCTUnwrap(inspect["result"]?["structuredContent"]?["errors"]?[0])
        XCTAssertEqual(error["code"], "MISSING_CAPABILITY")
        XCTAssertEqual(error["path"], "/operation")
        XCTAssertEqual(error["observed"], "project inspect")
        XCTAssertTrue(try XCTUnwrap(inspect["result"]?["content"]?[0]?["text"]?.string).contains("project inspect"))
    }

    func testTightenedPolicyHidesToolsAgain() throws {
        var server = session(evidence: evidence(admitting: ["project init", "build"]), policy: EvidencePolicy(minimumLevel: .visuallyValidated))
        XCTAssertEqual(try toolNames(&server), [])
    }

    func testUnknownMethodsAndBadParams() throws {
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"])
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"control.set","arguments":{}}}"#)["error"]?["code"], -32602)
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"vrm_project","arguments":{"action":"delete"}}}"#)["error"]?["code"], -32602)
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"vrm_build","arguments":[]}}"#)["error"]?["code"], -32602)
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"vrm_discover","arguments":{}}}"#)["error"]?["code"], -32600)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MCPFacadeTests --disable-sandbox`
Expected: compile error (`previewRenderer:` label, `MCPFacade`).

- [ ] **Step 3: Implement the facade skeleton**

```swift
// Sources/VRMAuthorKit/Serve/MCPFacade.swift
// (Apache 2.0 header)
import Foundation

/// One MCP tool composed over registry operations.
public struct MCPFacadeTool: Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var operations: [String]
    public var inputSchema: JSONSchema
    public var readOnly: Bool
    public var idempotent: Bool
}

enum InvokeOutcome {
    case envelope(JSONValue)
    case refused(JSONValue)
}

/// The MCP surface: six tools over the same handlers the CLI and JSON-RPC
/// use. A tool is listed when any operation it maps to is admitted (or the
/// session is a harness); an action whose operation is not admitted returns a
/// MISSING_CAPABILITY envelope instead of hiding the whole tool.
public enum MCPFacade {
    static let projectField = JSONSchema.path.described("Project directory; defaults to the session project")

    public static let tools: [MCPFacadeTool] = [
        MCPFacadeTool(name: "vrm_discover", title: "Discover", description: "Template packs, avatar control ranges, hair/outfit/accessory presets, renderers, starter resource URIs and admitted operations. Pass project to include current control values.",
                      operations: ["capabilities", "template list", "recipe export"],
                      inputSchema: .object(properties: ["project": projectField], required: [], description: "vrm_discover arguments"), readOnly: true, idempotent: true),
        MCPFacadeTool(name: "vrm_project", title: "Project", description: "init: create a project from a template pack and seed. inspect: revision, dependency state and status.",
                      operations: ["project init", "project inspect"],
                      inputSchema: .object(properties: [
                          "action": .enumeration(["init", "inspect"]), "dir": .path.described("init: project directory to create"),
                          "template": .id.described("init: template pack id; defaults to native-anime-v1"), "seed": .integer(minimum: 0, maximum: Int(Recipe.maxSeed)).defaulting(to: 0),
                          "name": .string(minLength: 1), "project": projectField,
                      ], required: ["action"], description: "vrm_project arguments"), readOnly: false, idempotent: false),
        MCPFacadeTool(name: "vrm_recipe", title: "Recipe", description: "export: the complete Recipe document. apply: replace it (edit the export in place, e.g. /body/body.heightM); requires expectedRevision.",
                      operations: ["recipe export", "recipe apply"],
                      inputSchema: .object(properties: [
                          "action": .enumeration(["export", "apply"]), "project": projectField, "recipe": Recipe.schema,
                          "expectedRevision": .integer(minimum: 0), "requestId": .string(minLength: 1), "dryRun": .boolean(),
                      ], required: ["action"], description: "vrm_recipe arguments"), readOnly: false, idempotent: true),
        MCPFacadeTool(name: "vrm_build", title: "Build", description: "Deterministic compile to an unsigned draft VRM. out defaults to <project>/draft.vrm.",
                      operations: ["build"],
                      inputSchema: .object(properties: ["project": projectField, "out": .path, "replace": .boolean()], required: [], description: "vrm_build arguments"), readOnly: false, idempotent: true),
        MCPFacadeTool(name: "vrm_qa", title: "QA", description: "Run the QA suite on a build (default: the newest build, suite authoring-v1) and return checks plus preview images. images: key (front + happy), all (six views), paths (none).",
                      operations: ["qa run"],
                      inputSchema: .object(properties: [
                          "project": projectField, "file": .path, "suite": .enumeration(["spec+style", "authoring-v1"]), "out": .path,
                          "images": .enumeration(["key", "all", "paths"]).defaulting(to: "key"), "previewSize": .integer(minimum: 128, maximum: 1024).defaulting(to: 512),
                      ], required: [], description: "vrm_qa arguments"), readOnly: false, idempotent: false),
        MCPFacadeTool(name: "vrm_export", title: "Export", description: "Final unsigned VRM bytes with loss and metadata report.",
                      operations: ["export vrm"],
                      inputSchema: .object(properties: ["project": projectField, "out": .path, "replace": .boolean()], required: ["out"], description: "vrm_export arguments"), readOnly: false, idempotent: false),
    ]

    public static func tool(named name: String) -> MCPFacadeTool? { tools.first { $0.name == name } }

    public static func eligible(_ operationName: String, session: ServeSession) -> Bool {
        guard let op = session.context.registry.operation(named: operationName), op.isRunnable else { return false }
        if session.harness { return true }
        return session.context.evidenceRegistry.capability(for: op, toolInfo: session.context.toolInfo, policy: session.policy).productionEligible
    }

    public static func listed(session: ServeSession) -> [MCPFacadeTool] {
        tools.filter { tool in tool.operations.contains { eligible($0, session: session) } }
    }

    public static func descriptor(_ tool: MCPFacadeTool) -> JSONValue {
        [
            "name": .string(tool.name), "title": .string(tool.title), "description": .string(tool.description), "inputSchema": tool.inputSchema.json,
            "annotations": ["title": .string(tool.title), "readOnlyHint": .bool(tool.readOnly), "destructiveHint": false, "idempotentHint": .bool(tool.idempotent), "openWorldHint": false],
        ]
    }

    // MARK: Composition helpers

    static func invoke(_ operationName: String, params: [String: JSONValue], session: ServeSession, tool: String) throws -> InvokeOutcome {
        guard let op = session.context.registry.operation(named: operationName) else {
            throw RPCError(code: RPCError.internalError, message: "Facade maps to unknown operation '\(operationName)'")
        }
        guard eligible(operationName, session: session) else { return .refused(missingCapability(tool: tool, operation: operationName, session: session)) }
        return .envelope(try session.invokeOperation(op, params: params, isNotification: false))
    }

    static func revision(of envelope: JSONValue) -> JSONValue {
        if let after = envelope["revisionAfter"], !after.isNull { return after }
        if let r = envelope["result"]?["revision"], !r.isNull { return r }
        return .null
    }

    static func toolResult(envelope: JSONValue, revision: JSONValue, isError: Bool, text: String, extra: [String: JSONValue] = [:], images: [JSONValue] = []) -> JSONValue {
        var structured = envelope.object ?? [:]
        structured["revision"] = revision
        for (k, v) in extra { structured[k] = v }
        return ["content": .array([["type": "text", "text": .string(text)]] + images), "structuredContent": .object(structured), "isError": .bool(isError)]
    }

    static func summary(tool: String, envelope: JSONValue) -> String {
        let status = envelope["status"]?.string ?? "unknown"
        var lines = ["\(tool) \(status); revision \(revisionText(envelope))"]
        for error in envelope["errors"]?.array ?? [] {
            lines.append("error \(error["code"]?.string ?? "?") \(error["path"]?.string ?? "") \(error["message"]?.string ?? "")")
        }
        for warning in envelope["warnings"]?.array ?? [] {
            lines.append("warning \(warning["code"]?.string ?? "?") \(warning["message"]?.string ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    static func revisionText(_ envelope: JSONValue) -> String {
        let r = revision(of: envelope)
        return r.int.map(String.init) ?? "n/a"
    }

    static func missingCapability(tool: String, operation: String, session: ServeSession) -> JSONValue {
        let op = session.context.registry.operation(named: operation)
        let error = AuthorError(code: .missingCapability, path: "/operation", observed: .string(operation),
                                required: op.map { .string($0.requiredEvidence.rawValue) },
                                message: "'\(operation)' has no admitted evidence under the session policy; it is not callable through \(tool) in this session.",
                                suggestedCommands: ["capabilities"])
        let envelope = ResultEnvelope.failed(requestId: nil, revision: nil, errors: [error])
        let json = (try? ServeSession.rpcResult(envelope)) ?? .object([:])
        return toolResult(envelope: json, revision: .null, isError: true, text: summary(tool: tool, envelope: json))
    }

    static func projectArgument(_ arguments: [String: JSONValue], session: ServeSession) throws -> String {
        if let p = arguments["project"]?.string { return p }
        if let p = session.context.projectPath { return p.path }
        throw RPCError(code: RPCError.invalidParams, message: "Invalid params: project is required (no session project)", data: ["path": "/project"])
    }

    static func validate(_ tool: MCPFacadeTool, _ arguments: [String: JSONValue]) throws {
        let violations = tool.inputSchema.requestErrors(for: .object(arguments))
        if let first = violations.first {
            throw RPCError(code: RPCError.invalidParams, message: "Invalid params: \(first.message)", data: ["path": .string(first.path ?? "/")])
        }
    }

    // MARK: Dispatch

    public static func call(_ tool: MCPFacadeTool, arguments raw: [String: JSONValue], session: ServeSession) throws -> JSONValue {
        try validate(tool, raw)
        let arguments = tool.inputSchema.applyingDefaults(to: .object(raw)).object ?? raw
        switch tool.name {
        case "vrm_discover": return try discover(arguments, session: session)
        case "vrm_project": return try project(arguments, session: session)
        case "vrm_recipe": return try recipe(arguments, session: session)
        case "vrm_build": return try build(arguments, session: session)
        case "vrm_qa": return try qa(arguments, session: session)
        case "vrm_export": return try export(arguments, session: session)
        default: throw RPCError(code: RPCError.methodNotFound, message: "Unknown tool: \(tool.name)")
        }
    }

    // Tasks 4–6 replace these bodies.
    static func discover(_ arguments: [String: JSONValue], session: ServeSession) throws -> JSONValue { throw RPCError(code: RPCError.internalError, message: "not implemented") }
    static func recipe(_ arguments: [String: JSONValue], session: ServeSession) throws -> JSONValue { throw RPCError(code: RPCError.internalError, message: "not implemented") }
    static func build(_ arguments: [String: JSONValue], session: ServeSession) throws -> JSONValue { throw RPCError(code: RPCError.internalError, message: "not implemented") }
    static func qa(_ arguments: [String: JSONValue], session: ServeSession) throws -> JSONValue { throw RPCError(code: RPCError.internalError, message: "not implemented") }
    static func export(_ arguments: [String: JSONValue], session: ServeSession) throws -> JSONValue { throw RPCError(code: RPCError.internalError, message: "not implemented") }

    static func project(_ arguments: [String: JSONValue], session: ServeSession) throws -> JSONValue {
        switch arguments["action"]?.string {
        case "init":
            var params: [String: JSONValue] = ["template": arguments["template"] ?? .string(NativeAnimeV1Pack.packId)]
            guard let dir = arguments["dir"] else { throw RPCError(code: RPCError.invalidParams, message: "Invalid params: dir is required for init", data: ["path": "/dir"]) }
            params["dir"] = dir
            if let seed = arguments["seed"] { params["seed"] = seed }
            if let name = arguments["name"] { params["name"] = name }
            switch try invoke("project init", params: params, session: session, tool: "vrm_project") {
            case .refused(let r): return r
            case .envelope(let e): return toolResult(envelope: e, revision: revision(of: e), isError: e["status"] != "succeeded", text: summary(tool: "vrm_project init", envelope: e))
            }
        case "inspect":
            let project = try projectArgument(arguments, session: session)
            switch try invoke("project inspect", params: ["project": .string(project)], session: session, tool: "vrm_project") {
            case .refused(let r): return r
            case .envelope(let e):
                let rev = e["result"]?["revision"] ?? revision(of: e)
                return toolResult(envelope: e, revision: rev, isError: e["status"] != "succeeded", text: summary(tool: "vrm_project inspect", envelope: e))
            }
        default:
            throw RPCError(code: RPCError.invalidParams, message: "Invalid params: action must be init or inspect", data: ["path": "/action"])
        }
    }
}
```

`JSONSchema.requestErrors(for:)` returns `[AuthorError]` (used by `Registry.invoke`); `AuthorError` has `message` and `path`. `JSONSchema.applyingDefaults(to:)` exists (also used by `Registry.invoke`). `JSONValue.isNull` exists (used in `ServeSession.handle(message:)`). If `.path` / `.id` static schemas are not visible from this file, they are the ones used in `Registry+Schemas.swift` (`JSONSchema.path`, `JSONSchema.id`); check their access level and make them `public` or `internal` as needed (same module, so `static let` without `private` is enough).

- [ ] **Step 4: Route `tools/*` through the facade in `ServeSession`**

In `ServeSession.swift`:

1. Add the property and init parameter:

```swift
    public let previewRenderer: (any RenderAdapter)?

    public init(context: OperationContext, protocol: ServeProtocol, policy: EvidencePolicy = .release, harness: Bool = false,
                previewRenderer: (any RenderAdapter)? = nil, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.context = context
        self.protocol = `protocol`
        self.policy = policy
        self.harness = harness
        self.previewRenderer = previewRenderer
        self.log = log
    }
```

2. Replace the `tools/list` and `tools/call` cases:

```swift
        case "tools/list":
            let p = try paramsObject(params)
            if p["cursor"] != nil { throw RPCError(code: RPCError.invalidParams, message: "Invalid params: unknown cursor") }
            return ["tools": .array(MCPFacade.listed(session: self).map(MCPFacade.descriptor))]
        case "tools/call":
            guard !isNotification else { throw RPCError(code: RPCError.invalidRequest, message: "Invalid Request: tools/call cannot be a notification") }
            let p = try paramsObject(params)
            guard let name = p["name"]?.string else { throw RPCError(code: RPCError.invalidParams, message: "Invalid params: name is required") }
            let listed = MCPFacade.listed(session: self)
            guard let tool = listed.first(where: { $0.name == name }) else {
                throw RPCError(code: RPCError.invalidParams, message: "Unknown tool: \(name)", data: ["availableTools": JSONValue(listed.map(\.name))])
            }
            let arguments: [String: JSONValue]
            if let raw = p["arguments"] {
                guard let o = raw.object else { throw RPCError(code: RPCError.invalidParams, message: "Invalid params: arguments must be an object") }
                arguments = o
            } else {
                arguments = [:]
            }
            return try MCPFacade.call(tool, arguments: arguments, session: self)
```

3. Delete `exposedOperations()` and `toolDescriptor(_:)` (grep the package for callers first: `grep -rn "exposedOperations\|toolDescriptor" Sources Tests`; the only ones are in `ServeSession.swift` and `MCPClientTests.swift`).

4. In `ServeHandlers.serve`, pass the renderer:

```swift
        var session = ServeSession(context: sessionContext, protocol: serveProtocol, policy: policy, harness: isHarness(env: context.env),
                                   previewRenderer: VRMAuthorRenderAdapter(executableURL: context.executableURL)) { line in
```

- [ ] **Step 5: Rewrite the assertions in `MCPClientTests` that encoded the 1:1 surface**

In `Tests/VRMAuthorKitTests/Serve/MCPClientTests.swift`:

- `testInitializeListAndCallAsAnIndependentClient`: change the `capabilities` assertion to
  `XCTAssertEqual(initialize["result"]?["capabilities"], ["tools": ["listChanged": false], "resources": ["subscribe": false, "listChanged": false]])`.
  Replace everything from `let list = …` through the `ping` assertion with:

```swift
        let list = try exchange(&server, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        XCTAssertEqual(list["id"], 2)
        let tools = try XCTUnwrap(list["result"]?["tools"]?.array)
        XCTAssertNil(list["result"]?["nextCursor"])
        XCTAssertEqual(tools.compactMap { $0["name"]?.string }, ["vrm_discover", "vrm_project", "vrm_recipe", "vrm_build", "vrm_qa", "vrm_export"])
        for tool in tools {
            XCTAssertEqual(tool["inputSchema"]?["type"], "object")
            XCTAssertNotNil(tool["description"]?.string)
            XCTAssertNotNil(tool["annotations"]?["readOnlyHint"]?.bool)
        }
        var reduced = session(env: ["VRM_AUTHOR_SESSION": "harness"], registry: withoutBuild)
        let reducedNames = try XCTUnwrap(try exchange(&reduced, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)["result"]?["tools"]?.array).compactMap { $0["name"]?.string }
        XCTAssertTrue(reducedNames.contains("vrm_project"))
        XCTAssertFalse(reducedNames.contains("vrm_build"), "a tool whose only operation has no handler is not listed")

        let ping = try exchange(&server, #"{"jsonrpc":"2.0","id":4,"method":"ping"}"#)
        XCTAssertEqual(ping["result"], [:])
```

- `testToolCallMutationsFailuresAndUnknownTools`: replace the body with

```swift
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"], registry: withoutBuild)
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"control.set","arguments":{}}}"#)["error"]?["code"], -32602, "registry methods are not MCP tools")
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"vrm_build","arguments":{}}}"#)["error"]?["code"], -32602, "handler-less operations stay hidden")
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"arguments":{}}}"#)["error"]?["code"], -32602)
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"vrm_project","arguments":[]}}"#)["error"]?["code"], -32602)
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","id":5,"method":"resources/list"}"#)["result"]?["resources"]?.array?.count, 2)
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"vrm_discover","arguments":{}}}"#)["error"]?["code"], -32600, "tools/call cannot be a notification")
        XCTAssertEqual(try exchange(&server, #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)["error"]?["code"], -32600, "MCP has no batches")
        XCTAssertEqual(try exchange(&server, "{oops")["error"]?["code"], -32700)
```

- `testToolsListFollowsSessionEvidencePolicy`: `qualifiedEvidence()` admits `version` and `object list`, which no facade tool maps to. Change the helper's list to `["template list", "project inspect"]`, then:
  - `some` assertion becomes `XCTAssertEqual(…, ["vrm_discover", "vrm_project"])`.
  - Replace the `objectList` call and its assertion with an inspect call:
    ```swift
        let inspect = try CanonicalJSON.string(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "vrm_project", "arguments": ["action": "inspect", "project": .string(dir.path)]]])
        XCTAssertEqual(try exchange(&qualified, inspect)["result"]?["structuredContent"]?["revision"], 0)
    ```
  - Final harness assertion becomes `XCTAssertEqual(…["tools"]!.array!.count, 6, "harness sessions expose every facade tool")`.

- [ ] **Step 6: Run the Serve tests**

Run: `swift test --filter "MCPFacadeTests|MCPClientTests|MCPResourcesTests|ServePackTests" --disable-sandbox`
Expected: all pass. `ServePackTests` may assert the old `tools/list` shape; if it does, update it the same way (facade names, count 6) and note it for the re-pin in Task 7.

- [ ] **Step 7: Commit**

```bash
git add Sources/VRMAuthorKit/Serve Tests/VRMAuthorKitTests/Serve
git commit -m "vrm-author: MCP facade tool table, per-operation gate and vrm_project"
```

---

### Task 4: `vrm_discover` and `vrm_recipe`

**Files:**
- Modify: `Sources/VRMAuthorKit/Serve/MCPFacade.swift` (`discover`, `recipe`)
- Test: `Tests/VRMAuthorKitTests/Serve/MCPFacadeTests.swift`

**Interfaces:**
- Consumes: `MCPFacade.invoke`, `toolResult`, `summary`, `projectArgument` (Task 3); `MCPResources.uris` (Task 2); `capabilities` result (`entries[].operation`, `entries[].productionEligible`, `renderers`, `templateHashes`); `template list` result (`packs[].{id,sha256,controls}`, `items[].{id,category,controls}`); `recipe export` result (`recipe`).
- Produces: `vrm_discover` structuredContent `{templates, controls, presets, renderers, starters, evidence}` and `vrm_recipe` results per spec §3.2.

- [ ] **Step 1: Add the failing tests**

Append to `MCPFacadeTests`:

```swift
    // MARK: vrm_discover

    func testDiscoverWithoutProjectWritesNothingAndListsPackData() throws {
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"])
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let result = try call(&server, id: 1, "vrm_discover", [:])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), before)
        XCTAssertEqual(result["result"]?["isError"], false)
        let s = try XCTUnwrap(result["result"]?["structuredContent"])
        XCTAssertEqual(s["templates"]?[0]?["id"], "native-anime-v1")
        XCTAssertEqual(s["templates"]?[0]?["sha256"], .string(TemplateRegistry.standard().templateHashes()["native-anime-v1"]!))
        let controls = try XCTUnwrap(s["controls"]?.array)
        XCTAssertEqual(controls.count, 44)
        XCTAssertEqual(controls.first { $0["key"] == "body.heightM" }?["validRange"], [1.2, 2.0])
        XCTAssertNil(controls.first { $0["key"] == "body.heightM" }?["value"])
        XCTAssertEqual(s["presets"]?["hair"]?.array?.compactMap { $0["id"]?.string }, ["bob-v1", "long-v1", "ponytail-v1"])
        XCTAssertEqual(s["presets"]?["outfit"]?.array?.count, 4)
        XCTAssertEqual(s["presets"]?["accessory"]?.array?.count, 3)
        XCTAssertEqual(s["starters"], ["recipe://native-anime-v1/female", "recipe://native-anime-v1/male"])
        XCTAssertEqual(s["evidence"]?["admitted"], [])
        XCTAssertNotNil(s["renderers"]?.array)
        XCTAssertEqual(s["revision"], .null)
    }

    func testDiscoverWithProjectCarriesCurrentValuesAndAdmittedOperations() throws {
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"], evidence: evidence(admitting: ["template list"]))
        let dir = root.appendingPathComponent("d.vrmauthor")
        _ = try call(&server, id: 1, "vrm_project", ["action": "init", "dir": .string(dir.path), "seed": 42])
        let s = try XCTUnwrap(try call(&server, id: 2, "vrm_discover", ["project": .string(dir.path)])["result"]?["structuredContent"])
        XCTAssertEqual(s["controls"]?.array?.first { $0["key"] == "body.heightM" }?["value"], 1.65)
        XCTAssertEqual(s["evidence"]?["admitted"], ["template list"])
        XCTAssertEqual(s["revision"], 0)
    }

    // MARK: vrm_recipe

    func testRecipeExportApplyRoundTripAndRevisionRules() throws {
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"])
        let dir = root.appendingPathComponent("r.vrmauthor")
        _ = try call(&server, id: 1, "vrm_project", ["action": "init", "dir": .string(dir.path), "seed": 42])
        let exported = try call(&server, id: 2, "vrm_recipe", ["action": "export", "project": .string(dir.path)])
        XCTAssertEqual(exported["result"]?["isError"], false)
        XCTAssertEqual(exported["result"]?["structuredContent"]?["revision"], 0)
        var recipe = try XCTUnwrap(exported["result"]?["structuredContent"]?["result"]?["recipe"])
        try JSONPointer("/body/body.heightM").set(in: &recipe, to: 1.5)

        let missing = try call(&server, id: 3, "vrm_recipe", ["action": "apply", "project": .string(dir.path), "recipe": recipe])
        XCTAssertEqual(missing["error"]?["code"], -32602, "expectedRevision is never auto-filled")

        let applied = try call(&server, id: 4, "vrm_recipe", ["action": "apply", "project": .string(dir.path), "recipe": recipe, "expectedRevision": 0, "requestId": "apply-1"])
        XCTAssertNil(applied["error"])
        XCTAssertEqual(applied["result"]?["isError"], false)
        XCTAssertEqual(applied["result"]?["structuredContent"]?["revision"], 1)
        XCTAssertTrue(try XCTUnwrap(applied["result"]?["content"]?[0]?["text"]?.string).hasPrefix("vrm_recipe apply succeeded; revision 1"))

        let stale = try call(&server, id: 5, "vrm_recipe", ["action": "apply", "project": .string(dir.path), "recipe": recipe, "expectedRevision": 0, "requestId": "apply-2"])
        XCTAssertNil(stale["error"])
        XCTAssertEqual(stale["result"]?["isError"], true, "a domain failure that changed nothing is a tool error")
        XCTAssertEqual(stale["result"]?["structuredContent"]?["errors"]?[0]?["code"], "REVISION_CONFLICT")

        let again = try call(&server, id: 6, "vrm_recipe", ["action": "export", "project": .string(dir.path)])
        XCTAssertEqual(again["result"]?["structuredContent"]?["result"]?["recipe"]?["body"]?["body.heightM"], 1.5)
        XCTAssertEqual(again["result"]?["structuredContent"]?["revision"], 1)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter MCPFacadeTests --disable-sandbox`
Expected: the three new tests fail with `-32603 not implemented`.

- [ ] **Step 3: Implement `discover` and `recipe`**

Replace the two stub bodies in `MCPFacade.swift`:

```swift
    static func discover(_ arguments: [String: JSONValue], session: ServeSession) throws -> JSONValue {
        let capabilities: JSONValue
        switch try invoke("capabilities", params: [:], session: session, tool: "vrm_discover") {
        case .refused(let r): return r
        case .envelope(let e): capabilities = e
        }
        let templates: JSONValue
        switch try invoke("template list", params: [:], session: session, tool: "vrm_discover") {
        case .refused(let r): return r
        case .envelope(let e): templates = e
        }
        var values: [String: JSONValue] = [:]
        var revision: JSONValue = .null
        if let project = arguments["project"]?.string {
            switch try invoke("recipe export", params: ["project": .string(project)], session: session, tool: "vrm_discover") {
            case .refused(let r): return r
            case .envelope(let e):
                revision = self.revision(of: e)
                for section in ["body", "face"] {
                    for (k, v) in e["result"]?["recipe"]?[section]?.object ?? [:] { values[k] = v }
                }
            }
        }
        let packs = templates["result"]?["packs"]?.array ?? []
        let controls: [JSONValue] = (packs.first?["controls"]?.array ?? []).map { descriptor in
            var d = descriptor.object ?? [:]
            if let key = d["key"]?.string, let v = values[key] { d["value"] = v }
            return .object(d)
        }
        var presets: [String: [JSONValue]] = ["hair": [], "outfit": [], "accessory": []]
        for item in templates["result"]?["items"]?.array ?? [] {
            guard let category = item["category"]?.string else { continue }
            presets[category, default: []].append(["id": item["id"] ?? .null, "controls": item["controls"] ?? []])
        }
        let admitted = (capabilities["result"]?["entries"]?.array ?? []).filter { $0["productionEligible"] == true }.compactMap { $0["operation"]?.string }
        let structured: [String: JSONValue] = [
            "templates": .array(packs.map { ["id": $0["id"] ?? .null, "sha256": $0["sha256"] ?? .null] }),
            "controls": .array(controls),
            "presets": .object(presets.mapValues { .array($0) }),
            "renderers": capabilities["result"]?["renderers"] ?? [],
            "starters": JSONValue(MCPResources.uris),
            "evidence": ["admitted": JSONValue(admitted)],
        ]
        let text = "vrm_discover succeeded; \(controls.count) controls, \(presets.values.map(\.count).reduce(0, +)) presets, \(admitted.count) admitted operations"
        return toolResult(envelope: .object(["protocol": .string(ResultEnvelope.protocolName), "status": "succeeded"]), revision: revision, isError: false, text: text, extra: structured)
    }

    static func recipe(_ arguments: [String: JSONValue], session: ServeSession) throws -> JSONValue {
        let project = try projectArgument(arguments, session: session)
        switch arguments["action"]?.string {
        case "export":
            switch try invoke("recipe export", params: ["project": .string(project), "out": .string(project + "/reports/mcp-recipe-export.json"), "replace": true], session: session, tool: "vrm_recipe") {
            case .refused(let r): return r
            case .envelope(let e): return toolResult(envelope: e, revision: revision(of: e), isError: e["status"] != "succeeded", text: summary(tool: "vrm_recipe export", envelope: e))
            }
        case "apply":
            guard let recipe = arguments["recipe"] else { throw RPCError(code: RPCError.invalidParams, message: "Invalid params: recipe is required for apply", data: ["path": "/recipe"]) }
            var params: [String: JSONValue] = ["project": .string(project), "recipe": recipe]
            for key in ["expectedRevision", "requestId", "dryRun"] { if let v = arguments[key] { params[key] = v } }
            switch try invoke("recipe apply", params: params, session: session, tool: "vrm_recipe") {
            case .refused(let r): return r
            case .envelope(let e): return toolResult(envelope: e, revision: revision(of: e), isError: e["status"] != "succeeded", text: summary(tool: "vrm_recipe apply", envelope: e))
            }
        default:
            throw RPCError(code: RPCError.invalidParams, message: "Invalid params: action must be export or apply", data: ["path": "/action"])
        }
    }
```

`recipe export` requires `out` (its schema has `out: true`), so the facade writes the export under `<project>/reports/` and returns the inline `result.recipe`. `revision export` for a read op sets `revisionAfter`, which `revision(of:)` picks up. If `recipe apply`'s revision-conflict error code is not `REVISION_CONFLICT`, read `ProjectHandlers.swift`/`ProjectAccess.swift` for the code it throws and fix the test, not the handler.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter MCPFacadeTests --disable-sandbox`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/VRMAuthorKit/Serve/MCPFacade.swift Tests/VRMAuthorKitTests/Serve/MCPFacadeTests.swift
git commit -m "vrm-author: vrm_discover and vrm_recipe facade tools"
```

---

### Task 5: `vrm_build` and `vrm_export`

**Files:**
- Modify: `Sources/VRMAuthorKit/Serve/MCPFacade.swift` (`build`, `export`)
- Test: `Tests/VRMAuthorKitTests/Serve/MCPFacadeTests.swift`

**Interfaces:**
- Consumes: Task 3 helpers; `build` request `{project, out, replace}`; `export vrm` request `{project, out, replace}`; `BuildSupport.latestBuildHash(_:)`, `BuildSupport.avatarURL(_:_:)`, `ProjectStore.open(at:)`.
- Produces: `vrm_build`/`vrm_export` results; `MCPFacade.latestBuildFile(project:) throws -> String` (used by Task 6).

- [ ] **Step 1: Add the failing tests**

```swift
    // MARK: vrm_build / vrm_export

    func testBuildDefaultsToDraftAtProjectRootAndExportWritesFinal() throws {
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"])
        let dir = root.appendingPathComponent("b.vrmauthor")
        _ = try call(&server, id: 1, "vrm_project", ["action": "init", "dir": .string(dir.path), "seed": 42])
        let built = try call(&server, id: 2, "vrm_build", ["project": .string(dir.path)])
        XCTAssertEqual(built["result"]?["isError"], false)
        let s = try XCTUnwrap(built["result"]?["structuredContent"])
        XCTAssertEqual(s["revision"], 0)
        let hash = try XCTUnwrap(s["result"]?["buildHash"]?.string)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("draft.vrm").path))
        let builds = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("builds").path).sorted()
        XCTAssertEqual(builds, [hash, "latest.json"], "nothing but recordBuild output under builds/")
        XCTAssertEqual(try MCPFacade.latestBuildFile(project: dir.path), dir.appendingPathComponent("builds/\(hash)/avatar.vrm").path)

        let rebuilt = try call(&server, id: 3, "vrm_build", ["project": .string(dir.path)])
        XCTAssertEqual(rebuilt["result"]?["isError"], false, "default replace:true lets the draft be rebuilt")
        XCTAssertEqual(rebuilt["result"]?["structuredContent"]?["result"]?["buildHash"], .string(hash), "same recipe, same bytes")

        let cli = ProjectTestHarness.invoke(server.context, "build", ["project": .string(dir.path), "out": .string(dir.appendingPathComponent("cli.vrm").path)])
        XCTAssertEqual(cli.result?["buildHash"], .string(hash), "facade and CLI build the same bytes")

        let exported = try call(&server, id: 4, "vrm_export", ["project": .string(dir.path), "out": .string(root.appendingPathComponent("final.vrm").path)])
        XCTAssertEqual(exported["result"]?["isError"], false)
        XCTAssertNotNil(exported["result"]?["structuredContent"]?["result"]?["lossReport"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("final.vrm").path))
    }

    func testLatestBuildFileFailsBeforeAnyBuild() throws {
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"])
        let dir = root.appendingPathComponent("nb.vrmauthor")
        _ = try call(&server, id: 1, "vrm_project", ["action": "init", "dir": .string(dir.path)])
        XCTAssertThrowsError(try MCPFacade.latestBuildFile(project: dir.path)) { error in
            XCTAssertEqual((error as? AuthorError)?.code, .missingInput)
            XCTAssertEqual((error as? AuthorError)?.suggestedCommands, ["build"])
        }
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter MCPFacadeTests --disable-sandbox`
Expected: compile error on `latestBuildFile`.

- [ ] **Step 3: Implement**

```swift
    static func build(_ arguments: [String: JSONValue], session: ServeSession) throws -> JSONValue {
        let project = try projectArgument(arguments, session: session)
        let out = arguments["out"]?.string ?? URL(fileURLWithPath: project).appendingPathComponent("draft.vrm").path
        let params: [String: JSONValue] = ["project": .string(project), "out": .string(out), "replace": arguments["replace"] ?? true]
        switch try invoke("build", params: params, session: session, tool: "vrm_build") {
        case .refused(let r): return r
        case .envelope(let e): return toolResult(envelope: e, revision: revision(of: e), isError: e["status"] != "succeeded", text: summary(tool: "vrm_build", envelope: e))
        }
    }

    static func export(_ arguments: [String: JSONValue], session: ServeSession) throws -> JSONValue {
        let project = try projectArgument(arguments, session: session)
        guard let out = arguments["out"]?.string else { throw RPCError(code: RPCError.invalidParams, message: "Invalid params: out is required", data: ["path": "/out"]) }
        var params: [String: JSONValue] = ["project": .string(project), "out": .string(out)]
        if let replace = arguments["replace"] { params["replace"] = replace }
        switch try invoke("export vrm", params: params, session: session, tool: "vrm_export") {
        case .refused(let r): return r
        case .envelope(let e): return toolResult(envelope: e, revision: revision(of: e), isError: e["status"] != "succeeded", text: summary(tool: "vrm_export", envelope: e))
        }
    }

    /// `builds/<hash>/avatar.vrm` for the project's newest build.
    static func latestBuildFile(project: String) throws -> String {
        let store = try ProjectStore.open(at: URL(fileURLWithPath: project))
        guard let hash = BuildSupport.latestBuildHash(store) else {
            throw AuthorError(code: .missingInput, path: "/file", message: "No build recorded for this project.", suggestedCommands: ["build"])
        }
        let url = BuildSupport.avatarURL(store, hash)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AuthorError(code: .missingInput, path: "/file", observed: .string(url.path), message: "Latest build file is missing.", suggestedCommands: ["build"])
        }
        return url.path
    }
```

If `build`'s `revisionAfter` is nil for a read operation, `revision(of:)` falls back to `result.revision`; if that is also absent the test expecting `0` fails. In that case read the project revision explicitly: `let rev = try? ProjectStore.open(at: URL(fileURLWithPath: project)).state().revision` and pass `.number(Double(rev))`. Apply the same fallback inside `revision(of:)` by adding an optional `project:` parameter rather than special-casing one tool.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter MCPFacadeTests --disable-sandbox`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/VRMAuthorKit/Serve/MCPFacade.swift Tests/VRMAuthorKitTests/Serve/MCPFacadeTests.swift
git commit -m "vrm-author: vrm_build and vrm_export facade tools"
```

---

### Task 6: Preview renderer and `vrm_qa` with image content

**Files:**
- Create: `Sources/VRMAuthorKit/QA/QAPreviewRenderer.swift`
- Modify: `Sources/VRMAuthorKit/Serve/MCPFacade.swift` (`qa`)
- Test: `Tests/VRMAuthorKitTests/Serve/MCPFacadeTests.swift`

**Interfaces:**
- Consumes: `RenderAdapter.render(scenario:file:data:outputDirectory:context:) -> [ArtifactRef]?`, `QAPins.renderScenarios()`, `RenderScenario(id:kind:configuration:)`, `JSONValue.merging` (used in `QAPins`), `ServeSession.previewRenderer`, `MCPFacade.latestBuildFile(project:)` (Task 5), `qa run` request `{project, request:{file,suite}, out, replace}`.
- Produces:
  ```swift
  public enum QAPreviewMode: String, CaseIterable, Sendable { case key, all, paths
      public var scenarioIds: [String]   // key → ["visual.front","expression.happy"]; all → the 6 visual/expression ids; paths → []
  }
  public struct QAPreview: Sendable { public var scenarioId, path, sha256: String; public var width, height: Int; public var pngBase64: String }
  public enum QAPreviewRenderer {
      /// Renders each selected scenario at size×size under outputDirectory/preview/<id>/ and returns one preview per scenario that produced a PNG. Returns [] when render is nil.
      public static func render(mode: QAPreviewMode, size: Int, file: URL, data: Data, outputDirectory: URL, render: (any RenderAdapter)?, context: OperationContext) throws -> [QAPreview]
      public static func imageBlock(_ preview: QAPreview) -> JSONValue   // {"type":"image","data":…,"mimeType":"image/png"}
      public static func json(_ preview: QAPreview) -> JSONValue         // {scenarioId,path,sha256,width,height,"evidence":false}
  }
  ```

- [ ] **Step 1: Add a fake renderer and the failing tests**

Add at file scope in `MCPFacadeTests.swift`:

```swift
/// Writes a valid, tiny PNG for every scenario so image plumbing is testable
/// without Metal. It records the size each scenario asked for.
final class FakeRenderer: RenderAdapter, @unchecked Sendable {
    var identity: String { "fake/1" }
    let sizes = NSMutableDictionary()

    func render(scenario: RenderScenario, file: URL, data: Data, outputDirectory: URL, context: OperationContext) throws -> [ArtifactRef]? {
        let w = scenario.configuration["width"]?.int ?? 1024
        let h = scenario.configuration["height"]?.int ?? 1024
        sizes[scenario.id] = w
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let png = try PNGEncoder.encode(width: 2, height: 2, rgba: [UInt8](repeating: 128, count: 16))
        let url = outputDirectory.appendingPathComponent("\(scenario.id).png")
        try png.write(to: url)
        return [BuildSupport.artifact(url, data: png, mediaType: "image/png", role: "render", buildHash: nil)]
    }
}
```

Append tests:

```swift
    // MARK: vrm_qa

    func preparedProject(_ server: inout ServeSession, name: String) throws -> URL {
        let dir = root.appendingPathComponent(name)
        _ = try call(&server, id: 1, "vrm_project", ["action": "init", "dir": .string(dir.path), "seed": 42])
        let built = try call(&server, id: 2, "vrm_build", ["project": .string(dir.path)])
        XCTAssertEqual(built["result"]?["isError"], false)
        return dir
    }

    func testQaWithoutRendererIsIncompleteNotError() throws {
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"])
        let dir = try preparedProject(&server, name: "q1.vrmauthor")
        let qa = try call(&server, id: 3, "vrm_qa", ["project": .string(dir.path)])
        XCTAssertNil(qa["error"])
        XCTAssertEqual(qa["result"]?["isError"], false)
        let s = try XCTUnwrap(qa["result"]?["structuredContent"])
        XCTAssertEqual(s["status"], "incomplete")
        XCTAssertEqual(s["result"]?["verdict"], "incomplete")
        XCTAssertEqual(s["previews"], [])
        XCTAssertEqual(s["revision"], 0)
        let content = try XCTUnwrap(qa["result"]?["content"]?.array)
        XCTAssertEqual(content.count, 1)
        let text = try XCTUnwrap(content[0]["text"]?.string)
        XCTAssertTrue(text.contains("spec.structure.glb pass"))
        XCTAssertTrue(text.contains("inspection record"), "the text block says the loop cannot reach complete through MCP")
        XCTAssertTrue(text.contains("renderer"), "names the missing renderer")
    }

    func testQaFileDefaultsToLatestBuildAndSuiteCanBeSpecStyle() throws {
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"])
        let dir = try preparedProject(&server, name: "q2.vrmauthor")
        let qa = try call(&server, id: 3, "vrm_qa", ["project": .string(dir.path), "suite": "spec+style", "images": "paths"])
        let s = try XCTUnwrap(qa["result"]?["structuredContent"])
        XCTAssertEqual(s["status"], "succeeded")
        XCTAssertEqual(s["result"]?["verdict"], "pass")
        XCTAssertEqual(qa["result"]?["content"]?.array?.count, 1)
        let plain = ProjectTestHarness.invoke(server.context, "qa run", ["project": .string(dir.path), "request": ["file": .string(try MCPFacade.latestBuildFile(project: dir.path)), "suite": "spec+style"], "out": .string(root.appendingPathComponent("plain-qa").path)])
        XCTAssertEqual(plain.result?["reportHash"], s["result"]?["reportHash"], "the facade runs the same locked qa run")
    }

    func testQaNoBuildFailsWithBuildSuggestion() throws {
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"])
        let dir = root.appendingPathComponent("q3.vrmauthor")
        _ = try call(&server, id: 1, "vrm_project", ["action": "init", "dir": .string(dir.path)])
        let qa = try call(&server, id: 2, "vrm_qa", ["project": .string(dir.path)])
        XCTAssertEqual(qa["result"]?["isError"], true)
        XCTAssertEqual(qa["result"]?["structuredContent"]?["errors"]?[0]?["suggestedCommands"], ["build"])
    }

    func testQaPreviewImagesFollowTheImagesMode() throws {
        let fake = FakeRenderer()
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"], previewRenderer: fake)
        let dir = try preparedProject(&server, name: "q4.vrmauthor")

        let key = try call(&server, id: 3, "vrm_qa", ["project": .string(dir.path), "previewSize": 256])
        let keyContent = try XCTUnwrap(key["result"]?["content"]?.array)
        XCTAssertEqual(keyContent.map { $0["type"]?.string }, ["text", "image", "image"])
        XCTAssertEqual(keyContent[1]["mimeType"], "image/png")
        let png = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(keyContent[1]["data"]?.string)))
        XCTAssertEqual([UInt8](png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let previews = try XCTUnwrap(key["result"]?["structuredContent"]?["previews"]?.array)
        XCTAssertEqual(previews.map { $0["scenarioId"]?.string }, ["visual.front", "expression.happy"])
        XCTAssertEqual(previews[0]["evidence"], false)
        XCTAssertEqual(previews[0]["width"], 256)
        XCTAssertEqual(fake.sizes["visual.front"] as? Int, 256, "preview pass overrides the scenario size")
        let path = try XCTUnwrap(previews[0]["path"]?.string)
        XCTAssertTrue(path.contains("/preview/visual.front/"))
        XCTAssertEqual(previews[0]["sha256"], .string(SHA256Hex.hex(try Data(contentsOf: URL(fileURLWithPath: path)))))
        XCTAssertNil(fake.sizes["motion.idle"], "motion is never previewed")

        let all = try call(&server, id: 4, "vrm_qa", ["project": .string(dir.path), "images": "all"])
        XCTAssertEqual(all["result"]?["content"]?.array?.count, 7)
        XCTAssertEqual(all["result"]?["structuredContent"]?["previews"]?.array?.compactMap { $0["scenarioId"]?.string },
                       ["visual.front", "visual.threeQuarter", "visual.profile", "expression.blink", "expression.aa", "expression.happy"])

        let paths = try call(&server, id: 5, "vrm_qa", ["project": .string(dir.path), "images": "paths"])
        XCTAssertEqual(paths["result"]?["content"]?.array?.count, 1)
        XCTAssertEqual(paths["result"]?["structuredContent"]?["previews"], [])

        let report = try XCTUnwrap(all["result"]?["structuredContent"]?["result"]?["artifacts"]?.array).compactMap { $0["path"]?.string }
        XCTAssertFalse(report.contains { $0.contains("/preview/") }, "preview files are not QA artifacts")
    }
```

`testQaWithoutRendererIsIncompleteNotError` relies on the `qa run` handler using `NoRenderer` in test contexts: `ProjectTestHarness.context` builds `Registry.v1()`, whose installer uses `VRMAuthorRenderAdapter()`. That adapter returns nil when no `vrm-author-render` sibling exists next to the *test* executable, which is the case under `swift test`. If on this machine the sibling resolves (check `VRMAuthorRenderLocator`), pass `env: ["VRM_AUTHOR_SESSION": "harness", "VRM_AUTHOR_RENDERER": "/nonexistent"]` in that test to force the unavailable path.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter MCPFacadeTests --disable-sandbox`
Expected: compile error (`QAPreviewRenderer` types are referenced only through the facade, so the failure is the `-32603 not implemented` from `qa`).

- [ ] **Step 3: Implement `QAPreviewRenderer`**

```swift
// Sources/VRMAuthorKit/QA/QAPreviewRenderer.swift
// (Apache 2.0 header)
import Foundation

public enum QAPreviewMode: String, CaseIterable, Sendable {
    case key, all, paths

    public var scenarioIds: [String] {
        switch self {
        case .key: return ["visual.front", "expression.happy"]
        case .all: return QAPins.renderScenarios().filter { $0.kind == "visual" || $0.kind == "expression" }.map(\.id)
        case .paths: return []
        }
    }
}

public struct QAPreview: Sendable {
    public var scenarioId: String
    public var path: String
    public var sha256: String
    public var width: Int
    public var height: Int
    public var pngBase64: String
}

/// A second rasterisation of locked QA scenarios at a small size, for an
/// agent to look at. Previews are views: their bytes and hashes never enter a
/// QA report, evidence file, inspection binding or acceptance pack.
public enum QAPreviewRenderer {
    public static let mimeType = "image/png"

    public static func render(mode: QAPreviewMode, size: Int, file: URL, data: Data, outputDirectory: URL, render: (any RenderAdapter)?, context: OperationContext) throws -> [QAPreview] {
        guard let render, mode != .paths else { return [] }
        let wanted = mode.scenarioIds
        var previews: [QAPreview] = []
        for scenario in QAPins.renderScenarios() where wanted.contains(scenario.id) {
            let sized = RenderScenario(id: scenario.id, kind: scenario.kind,
                                       configuration: scenario.configuration.merging(["width": .number(Double(size)), "height": .number(Double(size))]))
            let directory = outputDirectory.appendingPathComponent("preview").appendingPathComponent(scenario.id)
            guard let artifacts = try render.render(scenario: sized, file: file, data: data, outputDirectory: directory, context: context),
                  let png = artifacts.first(where: { $0.mediaType == mimeType }) else { continue }
            let bytes = try Data(contentsOf: URL(fileURLWithPath: png.path))
            previews.append(QAPreview(scenarioId: scenario.id, path: png.path, sha256: SHA256Hex.hex(bytes), width: size, height: size, pngBase64: bytes.base64EncodedString()))
        }
        return previews
    }

    public static func imageBlock(_ preview: QAPreview) -> JSONValue {
        ["type": "image", "data": .string(preview.pngBase64), "mimeType": .string(mimeType)]
    }

    public static func json(_ preview: QAPreview) -> JSONValue {
        ["scenarioId": .string(preview.scenarioId), "path": .string(preview.path), "sha256": .string(preview.sha256),
         "width": .number(Double(preview.width)), "height": .number(Double(preview.height)), "evidence": false]
    }
}
```

`JSONValue.merging(_:)` is the helper `QAPins.renderScenarios()` uses; if it is `internal` to another file it is still visible here (same module).

- [ ] **Step 4: Implement `qa` in the facade**

```swift
    static let inspectionNote = "Previews are views, not evidence. Inspection records (CLI `inspection record`) are still required for `complete`; through MCP the project stays a draft."

    static func qa(_ arguments: [String: JSONValue], session: ServeSession) throws -> JSONValue {
        let project = try projectArgument(arguments, session: session)
        let suite = arguments["suite"]?.string ?? "authoring-v1"
        let mode = QAPreviewMode(rawValue: arguments["images"]?.string ?? "key") ?? .key
        let size = arguments["previewSize"]?.int ?? 512
        let file: String
        if let f = arguments["file"]?.string { file = f } else {
            do { file = try latestBuildFile(project: project) } catch let error as AuthorError {
                let e = try ServeSession.rpcResult(.failed(requestId: nil, revision: nil, errors: [error]))
                return toolResult(envelope: e, revision: .null, isError: true, text: summary(tool: "vrm_qa", envelope: e), extra: ["previews": []])
            }
        }
        let revisionNumber = (try? ProjectStore.open(at: URL(fileURLWithPath: project)).state().revision) ?? 0
        let out: String
        if let o = arguments["out"]?.string { out = o } else {
            let reports = URL(fileURLWithPath: project).appendingPathComponent("reports")
            var n = 1
            while FileManager.default.fileExists(atPath: reports.appendingPathComponent("mcp-qa-\(revisionNumber)-\(n)").path) { n += 1 }
            out = reports.appendingPathComponent("mcp-qa-\(revisionNumber)-\(n)").path
        }
        let params: [String: JSONValue] = ["project": .string(project), "request": ["file": .string(file), "suite": .string(suite)], "out": .string(out)]
        let envelope: JSONValue
        switch try invoke("qa run", params: params, session: session, tool: "vrm_qa") {
        case .refused(let r): return r
        case .envelope(let e): envelope = e
        }
        let ran = envelope["result"]?["verdict"] != nil
        var previews: [QAPreview] = []
        var warnings: [String] = []
        if ran, suite == "authoring-v1" {
            let fileURL = URL(fileURLWithPath: file)
            let data = try Data(contentsOf: fileURL)
            var requestContext = session.context
            requestContext.projectPath = URL(fileURLWithPath: project)
            previews = try QAPreviewRenderer.render(mode: mode, size: size, file: fileURL, data: data, outputDirectory: URL(fileURLWithPath: out), render: session.previewRenderer, context: requestContext)
            if mode != .paths, session.previewRenderer == nil || previews.isEmpty {
                warnings.append("warning RENDERER_UNAVAILABLE no preview renderer in this session; render scenarios are incomplete")
            }
        }
        var lines = ["vrm_qa \(envelope["status"]?.string ?? "unknown"); verdict \(envelope["result"]?["verdict"]?.string ?? "n/a"); revision \(revisionNumber)"]
        for check in envelope["result"]?["checks"]?.array ?? [] {
            lines.append("\(check["id"]?.string ?? "?") \(check["status"]?.string ?? "?") \(check["message"]?.string ?? "")")
        }
        if !ran { for error in envelope["errors"]?.array ?? [] { lines.append("error \(error["code"]?.string ?? "?") \(error["message"]?.string ?? "")") } }
        lines += warnings
        lines.append(inspectionNote)
        return toolResult(envelope: envelope, revision: .number(Double(revisionNumber)), isError: !ran, text: lines.joined(separator: "\n"),
                          extra: ["previews": .array(previews.map(QAPreviewRenderer.json))], images: previews.map(QAPreviewRenderer.imageBlock))
    }
```

`qa run` returns `status: "failed"` with `result.verdict: "fail"` on failing checks and `"incomplete"` for missing renders; both have a verdict, so `ran` is true and `isError` is false. A handler error (bad file, project not found) has no verdict, so `isError` is true.

- [ ] **Step 5: Run to verify they pass**

Run: `swift test --filter MCPFacadeTests --disable-sandbox`
Expected: all pass. `testQaWithoutRendererIsIncompleteNotError` depends on `qa run` marking render scenarios `incomplete` without a renderer; if the verdict comes back `pass` because the harness context found a real renderer, apply the `VRM_AUTHOR_RENDERER` note from Step 1.

- [ ] **Step 6: Add the Metal-guarded end-to-end test**

Append to `MCPFacadeTests`:

```swift
    func testRealPreviewPassMatchesRequestedSize() throws {
        let adapter = VRMAuthorRenderAdapter(executableURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/vrm-author"))
        try XCTSkipIf(adapter.identity == VRMAuthorRenderAdapter.unavailableIdentity, "vrm-author-render or Metal unavailable")
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"], previewRenderer: adapter)
        let dir = try preparedProject(&server, name: "q5.vrmauthor")
        let qa = try call(&server, id: 3, "vrm_qa", ["project": .string(dir.path), "previewSize": 256])
        let previews = try XCTUnwrap(qa["result"]?["structuredContent"]?["previews"]?.array)
        XCTAssertEqual(previews.count, 2)
        for preview in previews {
            let png = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(preview["path"]?.string)))
            let ihdr = [UInt8](png[16..<24])
            let width = Int(ihdr[0]) << 24 | Int(ihdr[1]) << 16 | Int(ihdr[2]) << 8 | Int(ihdr[3])
            let height = Int(ihdr[4]) << 24 | Int(ihdr[5]) << 16 | Int(ihdr[6]) << 8 | Int(ihdr[7])
            XCTAssertEqual(width, 256)
            XCTAssertEqual(height, 256)
        }
    }
```

Run: `swift build && swift test --filter MCPFacadeTests/testRealPreviewPassMatchesRequestedSize --disable-sandbox`
Expected: passes on this Mac (M4 Max); skips where the renderer is absent. This test also exercises the real `qa run` render path (about 30 s).

- [ ] **Step 7: Commit**

```bash
git add Sources/VRMAuthorKit/QA/QAPreviewRenderer.swift Sources/VRMAuthorKit/Serve/MCPFacade.swift Tests/VRMAuthorKitTests/Serve/MCPFacadeTests.swift
git commit -m "vrm-author: vrm_qa with preview images as MCP image content"
```

---

### Task 7: Docs, full suite, re-pin

**Files:**
- Modify: `docs/proposals/vrm-author-cli/README.md` (§4 MCP paragraph), `docs/proposals/vrm-author-cli/commands.md` (lines 55 and 107), `CLAUDE.md` (vrm-author section)
- Modify: `docs/proposals/vrm-author-cli/acceptance/packs/*.json`, `acceptance/evidence.json` (via the script)

- [ ] **Step 1: README §4**

Replace the paragraph starting `` `serve --stdio --protocol mcp` is a v1 adapter over the same registry `` with:

```markdown
`serve --stdio --protocol mcp` is a v1 adapter over the same registry, pinned initially
to MCP 2025-06-18 with version negotiation. It implements initialization, capability
negotiation, `tools/list`, `tools/call`, `resources/list`, `resources/read`, structured
tool results and stderr-only logs. MCP does not project the 35 commands 1:1: it exposes
six facade tools composed over the same handlers (`vrm_discover`, `vrm_project`,
`vrm_recipe`, `vrm_build`, `vrm_qa`, `vrm_export`) and two starter Recipe resources
(`recipe://native-anime-v1/female`, `recipe://native-anime-v1/male`). `vrm_qa` returns
the locked QA checks plus small preview renders as MCP image content; previews are views
for the agent, never evidence. A facade tool is listed when any operation it maps to has
admitted evidence (or in a harness session); a not-yet-admitted action returns
`MISSING_CAPABILITY`. The 1:1 surface is `--protocol jsonrpc`. JSON-RPC alone is not MCP
compatibility; test the adapter with an independent client.
See [MCP tool requirements](https://modelcontextprotocol.io/specification/2025-06-18/server/tools).
```

Keep the A2A sentence that follows.

- [ ] **Step 2: commands.md**

Line 55: replace `MCP tool discovery filters to the session's admitted runnable tools.` with
`MCP exposes six facade tools over these handlers (see README §4); a facade tool is listed when any operation it maps to is admitted, and the full 1:1 surface is the jsonrpc protocol.`

Line 107 (the `serve` row): change the last cell to `JSON-RPC 2.0 session (1:1 commands); MCP adapter negotiates version and exposes the six-tool facade plus starter recipe resources`.

- [ ] **Step 3: CLAUDE.md**

Replace the sentence
`Production `capabilities`/MCP `tools/list` expose only commands with admitted evidence in `acceptance/evidence.json` (written by the independent evaluator, never by handlers); `VRM_AUTHOR_SESSION=harness` exposes every runnable handler.`
with
`Production `capabilities` and the jsonrpc protocol gate on admitted evidence in `acceptance/evidence.json` (written by the independent evaluator, never by handlers); `VRM_AUTHOR_SESSION=harness` lifts that gate. MCP (`serve --stdio --protocol mcp`) exposes six facade tools (`vrm_discover`, `vrm_project`, `vrm_recipe`, `vrm_build`, `vrm_qa`, `vrm_export`) and two `recipe://native-anime-v1/{female,male}` resources; a tool is listed when any operation it maps to is admitted.`

- [ ] **Step 4: Full VRMAuthorKit suite**

Run: `swift build && swift test --filter VRMAuthorKitTests --disable-sandbox`
Expected: all green. Fix any pack test that asserted the old MCP shape before moving on.

- [ ] **Step 5: Re-pin packs**

```bash
git add -A docs CLAUDE.md
git commit -m "docs: MCP facade in the vrm-author contract"
python3 scripts/repin_packs.py --check
python3 scripts/repin_packs.py
python3 scripts/repin_packs.py --check
git add docs/proposals/vrm-author-cli/acceptance
git commit -m "acceptance: re-pin onto $(git rev-parse --short HEAD) after the MCP facade"
```

Expected: the first `--check` reports the Serve (and any other touched) packs stale; the second reports clean. If `repin_packs.py` requires a clean tree or a specific head, follow its message; the pattern from recent history is one `acceptance: re-pin onto <sha>` commit after the code commit.

- [ ] **Step 6: Regenerate the sanity render and sanity-check the loop by hand**

```bash
.build/debug/vrm-author serve --stdio --protocol mcp <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"manual","version":"1"}}}
{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"recipe://native-anime-v1/female"}}
{"jsonrpc":"2.0","id":3,"method":"tools/list"}
EOF
```

Expected: `initialize` shows `resources` in capabilities; the resource read returns a Recipe with `"name":"female"`; `tools/list` returns `[]` (release session, no admitted evidence). Repeat with `VRM_AUTHOR_SESSION=harness` and expect six tools. Do not push.
