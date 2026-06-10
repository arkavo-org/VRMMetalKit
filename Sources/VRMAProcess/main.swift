import Foundation
import VRMAProcessKit

// VRMAProcess — locomotion ingest (GameOfMods locomotion design 2026-06-10 §3).
// The input file is never modified; producer truth stays on disk.

func usage() {
    let msg = """
    Usage: VRMAProcess <input.vrma> <output.vrma> [--idle|--walk]
      Measures stride speed, writes extras.arkavo (version 1), strips hips
      XZ (in-place clips), strips non-humanoid baked tracks, loop-trims by
      pose similarity. --idle/--walk force classification (default: auto,
      idle below \(LocomotionIngest.idleThreshold) m/s).

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

// Validate extra arguments: only --idle or --walk are allowed; not both.
let extraArgs = args.dropFirst(3)
let hasIdle = extraArgs.contains("--idle")
let hasWalk = extraArgs.contains("--walk")
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
    let output = try LocomotionIngest.process(glb: input, mode: mode)
    try output.write(to: resolvedOutput)
    if let meta = LocomotionExtras.read(from: try GLBContainer(data: output)) {
        print("VRMAProcess: \(resolvedOutput.path) strideSpeed=\(meta.strideSpeed) inPlace=\(meta.inPlace) sourceHipsHeight=\(meta.sourceHipsHeight)")
    }
} catch {
    FileHandle.standardError.write(Data("VRMAProcess: ERROR \(error)\n".utf8))
    exit(1)
}
