import Foundation

/// The single-pass ingest pipeline from the locomotion spec §3:
/// measure → write extras → strip hips XZ → strip non-humanoid → loop-trim.
public enum LocomotionIngest {
    public enum Mode { case auto, idle, walk }
    /// Below this measured speed (m/s) a clip auto-classifies as idle.
    public static let idleThreshold: Float = 0.1

    public static func process(glb: Data, mode: Mode) throws -> Data {
        var container = try GLBContainer(data: glb)
        let inspector = try VRMAClipInspector(container: container)

        // Measure FIRST — the strip below erases exactly what we measure.
        let measured = try inspector.meanHipsXZSpeed()
        let isIdle = mode == .idle || (mode == .auto && measured < idleThreshold)
        let meta = LocomotionExtras(
            strideSpeed: isIdle ? 0 : measured,
            inPlace: true,
            sourceHipsHeight: try inspector.hipsRestHeight()
        )
        try meta.write(into: &container)

        var editor = VRMAClipEditor(container: container)
        try editor.stripHipsXZ()
        try editor.stripNonHumanoidChannels()
        try editor.loopTrim()  // pose-similarity works for idle and walk alike
        container = editor.container
        return try container.serialize()
    }
}
