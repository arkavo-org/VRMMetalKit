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
import VRMAProcessKit

// VRMAProcess — locomotion ingest (GameOfMods locomotion design 2026-06-10 §3).
// The input file is never modified; producer truth stays on disk.

func usage() {
    let msg = """
    Usage: VRMAProcess <input.vrma> <output.vrma> [--idle|--walk] [--stride <m/s>]
      Measures stride speed, writes extras.arkavo (version 1), strips hips
      XZ (in-place clips), strips non-humanoid baked tracks, loop-trims by
      pose similarity. --idle/--walk force classification (default: auto,
      idle below \(LocomotionIngest.idleThreshold) m/s). --stride supplies
      an authored stride speed for already-in-place walks (licensed packs).

    """
    FileHandle.standardError.write(Data(msg.utf8))
}

let args = CommandLine.arguments  // args[0] is the binary path
guard args.count >= 3 else {
    usage()
    exit(2)
}

let inputPath  = args[1]
let outputPath = args[2]

// Validate extra arguments: --idle or --walk (not both), optional --stride <m/s>.
var extraArgs = Array(args.dropFirst(3))
let hasIdle = extraArgs.contains("--idle")
let hasWalk = extraArgs.contains("--walk")
var strideOverride: Float?
if let i = extraArgs.firstIndex(of: "--stride") {
    guard i + 1 < extraArgs.count, let v = Float(extraArgs[i + 1]) else {
        FileHandle.standardError.write(Data("VRMAProcess: ERROR --stride requires a numeric m/s value\n".utf8))
        usage()
        exit(2)
    }
    strideOverride = v
    extraArgs.removeSubrange(i...(i + 1))
}
let unknownArgs = extraArgs.filter { $0 != "--idle" && $0 != "--walk" }

if hasIdle && hasWalk {
    FileHandle.standardError.write(Data("VRMAProcess: ERROR --idle and --walk are mutually exclusive\n".utf8))
    usage()
    exit(2)
}
if !unknownArgs.isEmpty {
    FileHandle.standardError.write(Data("VRMAProcess: ERROR unknown argument(s): \(unknownArgs.joined(separator: " "))\n".utf8))
    usage()
    exit(2)
}

// Guard: refuse to overwrite the input file.
let resolvedInput  = URL(fileURLWithPath: inputPath).standardized
let resolvedOutput = URL(fileURLWithPath: outputPath).standardized
if resolvedInput == resolvedOutput {
    FileHandle.standardError.write(Data("VRMAProcess: ERROR refusing to overwrite the input: \(resolvedInput.path)\n".utf8))
    exit(2)
}

let mode: LocomotionIngest.Mode = hasIdle ? .idle : (hasWalk ? .walk : .auto)

do {
    let input = try Data(contentsOf: resolvedInput)
    let output = try LocomotionIngest.process(glb: input, mode: mode, strideOverride: strideOverride)
    try output.write(to: resolvedOutput)
    if let meta = LocomotionExtras.read(from: try GLBContainer(data: output)) {
        print("VRMAProcess: \(resolvedOutput.path) strideSpeed=\(meta.strideSpeed) inPlace=\(meta.inPlace) sourceHipsHeight=\(meta.sourceHipsHeight)")
    }
} catch {
    FileHandle.standardError.write(Data("VRMAProcess: ERROR \(error)\n".utf8))
    exit(1)
}
