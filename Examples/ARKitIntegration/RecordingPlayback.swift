//
// Copyright 2025 Arkavo
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
import VRMMetalKit

/// Recording and playback system for ARKit tracking data
///
/// This example demonstrates how to record ARKit face and body tracking sessions
/// to JSON files for later playback. Useful for:
/// - Testing without live ARKit session
/// - Debugging specific tracking issues
/// - Offline processing and analysis
/// - Automated testing with real data
/// - Performance benchmarking
///
/// Usage:
/// ```swift
/// // Recording
/// let recorder = ARKitRecorder()
/// recorder.startRecording()
/// // ... capture frames ...
/// try recorder.stopRecording(to: sessionURL)
///
/// // Playback
/// try recorder.playback(from: sessionURL) { face, body in
///     faceDriver.update(blendShapes: face, controller: controller)
///     bodyDriver.update(skeleton: body, nodes: nodes, humanoid: humanoid)
/// }
/// ```
class ARKitRecorder {
    // MARK: - Properties

    /// Recorded face tracking frames
    private var faceFrames: [ARKitFaceBlendShapes] = []

    /// Recorded body tracking frames
    private var bodyFrames: [ARKitBodySkeleton] = []

    /// Whether recording is currently active
    private var isRecording = false

    /// Recording metadata
    private var metadata: [String: String] = [:]

    // MARK: - Recording

    /// Start a new recording session
    ///
    /// - Parameter metadata: Optional metadata to attach to recording
    func startRecording(metadata: [String: String] = [:]) {
        faceFrames.removeAll()
        bodyFrames.removeAll()
        self.metadata = metadata
        self.metadata["startTime"] = ISO8601DateFormatter().string(from: Date())
        isRecording = true

        print("Started recording ARKit session")
    }

    /// Record a face tracking frame
    ///
    /// - Parameter blendShapes: Face blend shapes to record
    func record(face blendShapes: ARKitFaceBlendShapes) {
        guard isRecording else { return }
        faceFrames.append(blendShapes)
    }

    /// Record a body tracking frame
    ///
    /// - Parameter skeleton: Body skeleton to record
    func record(body skeleton: ARKitBodySkeleton) {
        guard isRecording else { return }
        bodyFrames.append(skeleton)
    }

    /// Stop recording and save to file
    ///
    /// - Parameter url: File URL to save recording
    /// - Throws: Recording errors if save fails
    func stopRecording(to url: URL) throws {
        guard isRecording else {
            throw RecordingError.notRecording
        }

        isRecording = false

        // Add final metadata
        metadata["endTime"] = ISO8601DateFormatter().string(from: Date())
        metadata["faceFrameCount"] = "\(faceFrames.count)"
        metadata["bodyFrameCount"] = "\(bodyFrames.count)"

        if let firstFace = faceFrames.first, let lastFace = faceFrames.last {
            let duration = lastFace.timestamp - firstFace.timestamp
            metadata["duration"] = String(format: "%.2f", duration)
            metadata["faceFPS"] = String(format: "%.1f", Double(faceFrames.count) / duration)
        }

        if let firstBody = bodyFrames.first, let lastBody = bodyFrames.last {
            let duration = lastBody.timestamp - firstBody.timestamp
            metadata["bodyFPS"] = String(format: "%.1f", Double(bodyFrames.count) / duration)
        }

        // Create recording
        let recording = ARKitRecording(
            faceFrames: faceFrames,
            bodyFrames: bodyFrames,
            metadata: metadata
        )

        // Encode to JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(recording)

        // Write to file
        try data.write(to: url, options: .atomic)

        print("""
        Stopped recording ARKit session:
          File: \(url.path)
          Face frames: \(faceFrames.count)
          Body frames: \(bodyFrames.count)
          Duration: \(metadata["duration"] ?? "unknown")s
          Face FPS: \(metadata["faceFPS"] ?? "unknown")
          Body FPS: \(metadata["bodyFPS"] ?? "unknown")
        """)
    }

    /// Cancel recording without saving
    func cancelRecording() {
        isRecording = false
        faceFrames.removeAll()
        bodyFrames.removeAll()
        metadata.removeAll()
        print("Cancelled recording")
    }

    // MARK: - Playback

    /// Play back a recorded session
    ///
    /// - Parameters:
    ///   - url: File URL of recorded session
    ///   - fps: Playback frame rate (default: 60 FPS)
    ///   - onFrame: Callback for each frame with face and/or body data
    /// - Throws: Recording errors if load fails
    func playback(
        from url: URL,
        at fps: Double = 60,
        onFrame: (ARKitFaceBlendShapes?, ARKitBodySkeleton?) -> Void
    ) throws {
        // Load recording
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let recording = try decoder.decode(ARKitRecording.self, from: data)

        print("""
        Playing back ARKit session:
          File: \(url.path)
          Face frames: \(recording.faceFrames.count)
          Body frames: \(recording.bodyFrames.count)
          Playback FPS: \(fps)
        """)

        // Determine frame count
        let maxFrames = max(recording.faceFrames.count, recording.bodyFrames.count)
        let frameDuration = 1.0 / fps

        // Playback frames
        for i in 0..<maxFrames {
            let face = i < recording.faceFrames.count ? recording.faceFrames[i] : nil
            let body = i < recording.bodyFrames.count ? recording.bodyFrames[i] : nil

            onFrame(face, body)

            // Sleep to maintain playback rate
            Thread.sleep(forTimeInterval: frameDuration)
        }

        print("Playback completed")
    }

    /// Play back with original timing (respects recorded timestamps)
    ///
    /// - Parameters:
    ///   - url: File URL of recorded session
    ///   - onFrame: Callback for each frame
    /// - Throws: Recording errors if load fails
    func playbackWithOriginalTiming(
        from url: URL,
        onFrame: (ARKitFaceBlendShapes?, ARKitBodySkeleton?) -> Void
    ) throws {
        let data = try Data(contentsOf: url)
        let recording = try JSONDecoder().decode(ARKitRecording.self, from: data)

        print("Playing back with original timing...")

        // Merge face and body frames by timestamp
        let allEvents = mergeFramesByTimestamp(
            face: recording.faceFrames,
            body: recording.bodyFrames
        )

        var lastTimestamp: TimeInterval = 0

        for event in allEvents {
            // Sleep until next frame based on timestamp delta
            if lastTimestamp > 0 {
                let delta = event.timestamp - lastTimestamp
                if delta > 0 {
                    Thread.sleep(forTimeInterval: delta)
                }
            }

            onFrame(event.face, event.body)
            lastTimestamp = event.timestamp
        }

        print("Playback completed")
    }

    /// Get recording metadata without loading full recording
    ///
    /// - Parameter url: File URL of recording
    /// - Returns: Metadata dictionary
    /// - Throws: Recording errors if load fails
    func getMetadata(from url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        let recording = try JSONDecoder().decode(ARKitRecording.self, from: data)
        return recording.metadata
    }

    // MARK: - Helper Methods

    /// Merge face and body frames by timestamp
    private func mergeFramesByTimestamp(
        face: [ARKitFaceBlendShapes],
        body: [ARKitBodySkeleton]
    ) -> [PlaybackEvent] {
        var events: [PlaybackEvent] = []

        // Add all face frames
        for faceFrame in face {
            events.append(PlaybackEvent(
                timestamp: faceFrame.timestamp,
                face: faceFrame,
                body: nil
            ))
        }

        // Add all body frames
        for bodyFrame in body {
            events.append(PlaybackEvent(
                timestamp: bodyFrame.timestamp,
                face: nil,
                body: bodyFrame
            ))
        }

        // Sort by timestamp
        return events.sorted { $0.timestamp < $1.timestamp }
    }
}

// MARK: - Recording Types

/// A recorded ARKit session with face and body tracking data
struct ARKitRecording: Codable {
    let faceFrames: [ARKitFaceBlendShapes]
    let bodyFrames: [ARKitBodySkeleton]
    let metadata: [String: String]
}

/// A playback event combining face and body data at a specific timestamp
private struct PlaybackEvent {
    let timestamp: TimeInterval
    let face: ARKitFaceBlendShapes?
    let body: ARKitBodySkeleton?
}

/// Errors that can occur during recording/playback
enum RecordingError: Error, LocalizedError {
    case notRecording
    case alreadyRecording
    case fileNotFound
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .notRecording:
            return "Not currently recording"
        case .alreadyRecording:
            return "Already recording - stop current recording first"
        case .fileNotFound:
            return "Recording file not found"
        case .invalidFormat:
            return "Invalid recording file format"
        }
    }
}

// MARK: - Usage Examples

/*
 // Simple recording session
 let recorder = ARKitRecorder()

 // Start recording
 recorder.startRecording(metadata: [
     "session": "test_session_1",
     "device": "iPhone 15 Pro",
     "scenario": "desk_work"
 ])

 // Record frames (in your camera event handler)
 func onCameraMetadata(_ event: CameraMetadataEvent) {
     if let face = extractFaceData(from: event) {
         recorder.record(face: face)
     }
     if let body = extractBodyData(from: event) {
         recorder.record(body: body)
     }
 }

 // Stop and save
 let recordingURL = URL(fileURLWithPath: "session.json")
 try recorder.stopRecording(to: recordingURL)

 // Playback at 60 FPS
 try recorder.playback(from: recordingURL, at: 60) { face, body in
     if let face = face {
         faceDriver.update(blendShapes: face, controller: controller)
     }
     if let body = body {
         bodyDriver.update(skeleton: body, nodes: nodes, humanoid: humanoid)
     }
 }

 // Playback with original timing
 try recorder.playbackWithOriginalTiming(from: recordingURL) { face, body in
     // Same as above
 }

 // Get metadata
 let metadata = try recorder.getMetadata(from: recordingURL)
 print("Recording duration: \(metadata["duration"] ?? "unknown")s")
 print("Face FPS: \(metadata["faceFPS"] ?? "unknown")")
 */
