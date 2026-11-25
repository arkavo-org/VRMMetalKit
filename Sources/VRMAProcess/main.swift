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

// VRMAProcess — locomotion ingest & VRMA asset hygiene CLI.
// The input file is never modified; producer truth stays on disk.

func usage() {
    let msg = """
    Usage: VRMAProcess <input.vrma> <output.vrma> [options]
      Locomotion ingest (default):
        Measures stride speed, writes extras.arkavo (version 1), strips hips XZ
        (in-place clips), strips non-humanoid baked tracks (preserving expressions
        and lookAt), strips constant eye channels, normalizes rest pose, and
        loop-trims by pose similarity.
      Options:
        --idle | --walk              Force classification (default: auto, idle < \(LocomotionIngest.idleThreshold) m/s)
        --stride <m/s>               Authored stride speed for already-in-place walks
        --hygiene-only               Run hygiene passes only (keep hips XZ, skip extras & loop-trim)
        --min-arm-abduction <deg>    Enforce smooth C1 outward abduction floor on hanging arms (0..90)
        --no-normalize-rest          Skip baking non-identity humanoid rest rotations to identity
        --keep-eye-channels          Skip stripping constant leftEye/rightEye channels

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

var extraArgs = Array(args.dropFirst(3))
var hasIdle = false
var hasWalk = false
var hygieneOnly = false
var normalizeRestPose = true
var stripConstantEyeChannels = true
var strideOverride: Float?
var minArmAbduction: Float?

var i = 0
while i < extraArgs.count {
    let arg = extraArgs[i]
    switch arg {
    case "--idle":
        hasIdle = true
        i += 1
    case "--walk":
        hasWalk = true
        i += 1
    case "--hygiene-only":
        hygieneOnly = true
        i += 1
    case "--no-normalize-rest":
        normalizeRestPose = false
        i += 1
    case "--keep-eye-channels":
        stripConstantEyeChannels = false
        i += 1
    case "--stride":
        guard i + 1 < extraArgs.count, let v = Float(extraArgs[i + 1]), v.isFinite else {
            FileHandle.standardError.write(Data("VRMAProcess: ERROR --stride requires a finite numeric m/s value\n".utf8))
            usage()
            exit(2)
        }
        strideOverride = v
        i += 2
    case "--min-arm-abduction":
        guard i + 1 < extraArgs.count, let v = Float(extraArgs[i + 1]), v.isFinite, v >= 0, v < 90 else {
            FileHandle.standardError.write(Data("VRMAProcess: ERROR --min-arm-abduction requires a finite degree value in [0, 90)\n".utf8))
            usage()
            exit(2)
        }
        minArmAbduction = v
        i += 2
    default:
        FileHandle.standardError.write(Data("VRMAProcess: ERROR unknown argument: \(arg)\n".utf8))
        usage()
        exit(2)
    }
}

if hasIdle, strideOverride != nil {
    FileHandle.standardError.write(Data("VRMAProcess: ERROR --stride is meaningless with --idle (idle is the explicit strideSpeed-0 entry)\n".utf8))
    usage()
    exit(2)
}
if hasIdle && hasWalk {
    FileHandle.standardError.write(Data("VRMAProcess: ERROR --idle and --walk are mutually exclusive\n".utf8))
    usage()
    exit(2)
}
if hygieneOnly && (hasIdle || hasWalk || strideOverride != nil) {
    FileHandle.standardError.write(Data("VRMAProcess: ERROR --hygiene-only cannot be combined with --idle, --walk, or --stride\n".utf8))
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
    let output: Data
    if hygieneOnly {
        output = try LocomotionIngest.processHygiene(
            glb: input,
            stripNonHumanoid: true,
            stripEyeChannels: stripConstantEyeChannels,
            onlyConstantEyes: true,
            normalizeRestPose: normalizeRestPose,
            minArmAbductionDegrees: minArmAbduction
        )
        try output.write(to: resolvedOutput)
        print("VRMAProcess: \(resolvedOutput.path) hygiene-only normalizeRest=\(normalizeRestPose) stripEyes=\(stripConstantEyeChannels) minArmAbduction=\(minArmAbduction.map { "\($0)" } ?? "off")")
    } else {
        output = try LocomotionIngest.process(
            glb: input,
            mode: mode,
            strideOverride: strideOverride,
            stripConstantEyeChannels: stripConstantEyeChannels,
            normalizeRestPose: normalizeRestPose,
            minArmAbductionDegrees: minArmAbduction
        )
        try output.write(to: resolvedOutput)
        if let meta = LocomotionExtras.read(from: try GLBContainer(data: output)) {
            print("VRMAProcess: \(resolvedOutput.path) strideSpeed=\(meta.strideSpeed) inPlace=\(meta.inPlace) sourceHipsHeight=\(meta.sourceHipsHeight)")
        }
    }
} catch {
    FileHandle.standardError.write(Data("VRMAProcess: ERROR \(error)\n".utf8))
    exit(1)
}
