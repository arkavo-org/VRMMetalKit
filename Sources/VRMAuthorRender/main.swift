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
import Metal
import VRMAuthorKit
import VRMMetalKit

let usage = """
Usage: vrm-author-render --file AVATAR.vrm --scenario SCENARIO.json --out DIR
       vrm-author-render --device-info

Renders one canonical `vrm-author qa run --suite authoring-v1` scenario with
VRMMetalKit and prints a JSON manifest {renderer, scenario, artifacts[]} on stdout
(also written to DIR/manifest.json). SCENARIO.json is a RenderScenario
{id, kind, configuration}. Exit codes: 0 success, 1 usage or render failure,
2 unreadable input, 3 no Metal device.

"""

enum RenderExit {
    static let success: Int32 = 0
    static let failure: Int32 = 1
    static let badInput: Int32 = 2
    static let noDevice: Int32 = 3
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("vrm-author-render: \(message)\n".utf8))
    exit(code)
}

func emit(_ value: JSONValue) throws {
    let data = try CanonicalJSON.data(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

struct Arguments {
    var file: String?
    var scenario: String?
    var out: String?
    var deviceInfo = false

    init(_ raw: [String]) {
        var index = 0
        while index < raw.count {
            let argument = raw[index]
            func value() -> String {
                index += 1
                guard index < raw.count else { fail("\(argument) requires a value.\n\(usage)", code: RenderExit.failure) }
                return raw[index]
            }
            switch argument {
            case "--file": file = value()
            case "--scenario": scenario = value()
            case "--out": out = value()
            case "--device-info": deviceInfo = true
            case "-h", "--help":
                FileHandle.standardOutput.write(Data(usage.utf8))
                exit(RenderExit.success)
            default: fail("Unknown argument '\(argument)'.\n\(usage)", code: RenderExit.failure)
            }
            index += 1
        }
    }
}

let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))

guard let device = MTLCreateSystemDefaultDevice() else {
    fail("No Metal device is available; authoring-v1 render scenarios stay incomplete on this host.", code: RenderExit.noDevice)
}

if arguments.deviceInfo {
    do { try emit(["renderer": ScenarioRenderer.rendererDescription(device: device)]) } catch { fail("\(error)", code: RenderExit.failure) }
    exit(RenderExit.success)
}

guard let filePath = arguments.file, let scenarioPath = arguments.scenario, let outPath = arguments.out else {
    fail("--file, --scenario and --out are required.\n\(usage)", code: RenderExit.failure)
}

let fileURL = URL(fileURLWithPath: filePath)
let scenarioURL = URL(fileURLWithPath: scenarioPath)
let outputDirectory = URL(fileURLWithPath: outPath)

let scenario: RenderScenario
do {
    scenario = try JSONValue.parse(try Data(contentsOf: scenarioURL)).decode(RenderScenario.self)
} catch {
    fail("Could not read the scenario at \(scenarioURL.path): \(error)", code: RenderExit.badInput)
}

let plan: RenderPlan
do { plan = try RenderPlan(scenario: scenario) } catch { fail("Scenario '\(scenario.id)' is invalid: \(error)", code: RenderExit.badInput) }

let modelData: Data
do { modelData = try Data(contentsOf: fileURL) } catch { fail("Could not read the avatar at \(fileURL.path): \(error)", code: RenderExit.badInput) }

let model: VRMModel
do {
    model = try await VRMModel.load(from: modelData, filePath: fileURL.path, device: device)
} catch {
    fail("VRMMetalKit could not load \(fileURL.path): \(error)", code: RenderExit.badInput)
}

do {
    let renderer = ScenarioRenderer(device: device, plan: plan, outputDirectory: outputDirectory)
    let artifacts = try renderer.render(model: model)
    let manifest: JSONValue = [
        "manifestVersion": 1,
        "renderer": ScenarioRenderer.rendererDescription(device: device, sampleCount: plan.sampleCount),
        "scenario": ["id": .string(scenario.id), "kind": .string(scenario.kind), "configurationHash": .string(try CanonicalJSON.sha256(scenario.configuration))],
        "file": ["path": .string(fileURL.path), "sha256": .string(SHA256Hex.hex(modelData))],
        "artifacts": .array(artifacts),
    ]
    try ProjectStore.atomicWrite(try CanonicalJSON.data(manifest), to: outputDirectory.appendingPathComponent("manifest.json"))
    try emit(manifest)
    exit(RenderExit.success)
} catch {
    fail("Rendering '\(scenario.id)' failed: \(error)", code: RenderExit.failure)
}
