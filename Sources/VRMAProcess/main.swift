import Foundation
import VRMAProcessKit

// VRMAProcess — locomotion ingest (GameOfMods locomotion design 2026-06-10 §3).
// The input file is never modified; producer truth stays on disk.

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("""
    Usage: VRMAProcess <input.vrma> <output.vrma> [--idle|--walk]
      Measures stride speed, writes extras.arkavo (version 1), strips hips
      XZ (in-place clips), strips non-humanoid baked tracks, loop-trims by
      pose similarity. --idle/--walk force classification (default: auto,
      idle below \(LocomotionIngest.idleThreshold) m/s).
    """)
    exit(2)
}
let mode: LocomotionIngest.Mode = args.contains("--idle") ? .idle : (args.contains("--walk") ? .walk : .auto)
do {
    let input = try Data(contentsOf: URL(fileURLWithPath: args[1]))
    let output = try LocomotionIngest.process(glb: input, mode: mode)
    try output.write(to: URL(fileURLWithPath: args[2]))
    if let meta = LocomotionExtras.read(from: try GLBContainer(data: output)) {
        print("VRMAProcess: \(args[2]) strideSpeed=\(meta.strideSpeed) inPlace=\(meta.inPlace) sourceHipsHeight=\(meta.sourceHipsHeight)")
    }
} catch {
    FileHandle.standardError.write(Data("VRMAProcess: ERROR \(error)\n".utf8))
    exit(1)
}
