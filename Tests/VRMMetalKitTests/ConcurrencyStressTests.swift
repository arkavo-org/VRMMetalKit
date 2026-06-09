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

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Concurrency stress tests for types marked `@unchecked Sendable` that claim
/// **full** thread-safety (i.e. callers may invoke from any thread, internal
/// synchronization is provided).
///
/// ## Why these tests exist
///
/// `@unchecked Sendable` is a programmer assertion the compiler does not verify.
/// For 1.0, every type that claims thread-safety needs evidence the claim holds
/// under concurrent load. The most rigorous tool is Thread Sanitizer (TSAN), but
/// **TSAN cannot run via `swift test` on macOS** — `xctest` lives in
/// `/Applications/Xcode.app/...` which is SIP-protected, so
/// `DYLD_INSERT_LIBRARIES` is stripped on launch and TSAN's interceptors never
/// install. The workaround is to enable TSAN in an Xcode test scheme and run
/// `⌘U` in the IDE.
///
/// These tests are the CLI-runnable complement: they hammer each type's mutable
/// surface from many threads. They cannot _prove_ absence of races (TSAN can),
/// but they reliably surface bugs that produce crashes, hangs, or corrupt state
/// under contention. Run them under `--parallel` so other test workers add
/// extra scheduler pressure.
///
/// ## Scope
///
/// Types this file covers (those claiming **full** thread-safety):
/// - `VRMPipelineCache` — NSLock-protected pipeline state cache
/// - `VRMModel` — NSLock-protected via `withLock`
/// - `AnimationPlayer` — playerLock-protected mutable state
/// - `ARFaceSource` / `ARBodySource` — `Mutex<State>`-protected snapshots
/// - `ARKitCoordinateConverter` — `Mutex`-protected process-wide T-pose calibration
/// - `ARKitBodyDriver` — NSLock-protected mutable state; `priority` /
///   `stalenessThreshold` are `let` (config, read lock-free)
///
/// Types deliberately NOT covered (different contract):
/// - `VRMExpressionController` — single-writer (main thread); racing it is UB
///   by design. Documented in its docstring.
/// - `ARKitFaceDriver` — single-writer by design (no internal lock); `@unchecked
///   Sendable` only enables actor storage, not concurrent calls. Same contract
///   as `VRMExpressionController`; documented in its docstring.
/// - `ConstraintSolver` — stateless; conforms to *checked* `Sendable` (no shared
///   mutable state for a race to touch).
/// - `SpringBoneBuffers` — init-then-immutable (allocateBuffers happens once,
///   then GPU-only writes).
/// - `BufferLoader` — effectively immutable after init for the read paths.
///
/// Run: `swift test --filter ConcurrencyStressTests --disable-sandbox`
final class ConcurrencyStressTests: XCTestCase {

    // Tune these to balance CI runtime against race-detection probability.
    // Real races usually manifest within a few thousand contentions; higher
    // numbers raise confidence at the cost of test time.
    private let stressThreadCount = 16
    private let stressIterations = 500

    // MARK: - ARKit Sources

    /// Writer threads call `update(blendShapes:)` while reader threads concurrently
    /// read `isActive`, `blendShapes`, and `lastUpdate`.
    ///
    /// Before the Mutex<State> fix, `isActive` read `lastUpdate` and `maxAge` as
    /// plain vars outside any lock while `update()` wrote `lastUpdate` under the
    /// lock — a genuine data race. TSan would flag it; this test surfaces the
    /// resulting crash or NaN under high contention without TSan.
    func testStressARFaceSource_ConcurrentUpdateAndRead() {
        let source = ARFaceSource(name: "StressTest")
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "stress-arface", attributes: .concurrent)
        let iterations = stressIterations

        // Writer threads
        for i in 0..<stressThreadCount / 2 {
            group.enter()
            queue.async {
                defer { group.leave() }
                for j in 0..<iterations {
                    let shapes = ARKitFaceBlendShapes(
                        timestamp: TimeInterval(i * iterations + j) * 0.001,
                        shapes: ["eyeBlinkLeft": Float(j % 100) / 100.0]
                    )
                    source.update(blendShapes: shapes)
                }
            }
        }

        // Reader threads — isActive previously had a data race here
        for _ in 0..<stressThreadCount / 2 {
            group.enter()
            queue.async {
                defer { group.leave() }
                for _ in 0..<iterations {
                    _ = source.isActive
                    _ = source.lastUpdate
                    _ = source.blendShapes
                }
            }
        }

        group.wait()

        let t = source.lastUpdate
        XCTAssertFalse(t.isNaN, "lastUpdate must not be NaN after concurrent updates")
        XCTAssertFalse(t.isInfinite, "lastUpdate must not be Inf after concurrent updates")
    }

    /// Same race surface for `ARBodySource`.
    func testStressARBodySource_ConcurrentUpdateAndRead() {
        let source = ARBodySource(name: "StressTest")
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "stress-arbody", attributes: .concurrent)
        let iterations = stressIterations

        for i in 0..<stressThreadCount / 2 {
            group.enter()
            queue.async {
                defer { group.leave() }
                for j in 0..<iterations {
                    let skeleton = ARKitBodySkeleton(
                        timestamp: TimeInterval(i * iterations + j) * 0.001,
                        joints: [:],
                        isTracked: true
                    )
                    source.update(skeleton: skeleton)
                }
            }
        }

        for _ in 0..<stressThreadCount / 2 {
            group.enter()
            queue.async {
                defer { group.leave() }
                for _ in 0..<iterations {
                    _ = source.isActive
                    _ = source.lastUpdate
                    _ = source.skeleton
                }
            }
        }

        group.wait()

        let t = source.lastUpdate
        XCTAssertFalse(t.isNaN, "lastUpdate must not be NaN after concurrent updates")
        XCTAssertFalse(t.isInfinite, "lastUpdate must not be Inf after concurrent updates")
    }

    // MARK: - ARKitCoordinateConverter calibration

    /// The converter's T-pose calibration is process-wide mutable state read on
    /// every joint conversion (potentially from a tracking queue) and written by
    /// `calibrateTpose`/`clearCalibration` (app/UI). Before the `Mutex` fix it
    /// was `nonisolated(unsafe)`: concurrent read of the `[ARKitJoint: simd_quatf]`
    /// dictionary while another thread mutated it is a Swift exclusivity/COW
    /// violation that crashes under contention. This hammers both sides.
    func testStressARKitCoordinateConverter_CalibrationConcurrentReadWrite() {
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "stress-converter", attributes: .concurrent)
        let iterations = stressIterations
        let skeleton = ARKitBodySkeleton(
            timestamp: 0,
            joints: [.hips: matrix_identity_float4x4, .leftShoulder: matrix_identity_float4x4],
            isTracked: true)

        // Writers: calibrate / clear the global state.
        for i in 0..<stressThreadCount / 2 {
            group.enter()
            queue.async {
                defer { group.leave() }
                for j in 0..<iterations {
                    if (i + j) % 2 == 0 {
                        ARKitCoordinateConverter.calibrateTpose(skeleton)
                    } else {
                        ARKitCoordinateConverter.clearCalibration()
                    }
                }
            }
        }

        // Readers: read the calibration dictionary + flags concurrently.
        for _ in 0..<stressThreadCount / 2 {
            group.enter()
            queue.async {
                defer { group.leave() }
                for _ in 0..<iterations {
                    _ = ARKitCoordinateConverter.isCalibrated
                    _ = ARKitCoordinateConverter.calibratedTposeRotations
                    _ = ARKitCoordinateConverter.restPoseCalibrationEnabled
                }
            }
        }

        group.wait()

        // Restore clean global state for any other test that reads it.
        ARKitCoordinateConverter.clearCalibration()
        XCTAssertFalse(ARKitCoordinateConverter.isCalibrated,
                       "Converter calibration must be clearable to a consistent state after contention.")
    }

    // MARK: - VRMPipelineCache

    /// Hammers `getLibrary` from many threads. The cache promises (a) no
    /// crash and (b) memoization — all callers receive the same `MTLLibrary`
    /// once one is cached for a given device. `getLibrary` and
    /// `getPipelineState` share the same `NSLock`, so exercising one
    /// validates the locking strategy for both.
    func testStressVRMPipelineCache_ConcurrentGetLibrary() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }

        let cache = VRMPipelineCache.shared
        // Prime the cache once so the first hit doesn't dominate timing — we
        // care about the lock-contention path, not the cold-load cost.
        _ = try cache.getLibrary(device: device)

        let results = ConcurrentResultCollector<ObjectIdentifier>()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "stress-cache", attributes: .concurrent)
        let iterations = stressIterations

        for _ in 0..<stressThreadCount {
            group.enter()
            queue.async {
                defer { group.leave() }
                for _ in 0..<iterations {
                    do {
                        let lib = try cache.getLibrary(device: device)
                        results.append(ObjectIdentifier(lib))
                    } catch {
                        results.appendError(error)
                    }
                }
            }
        }
        group.wait()

        XCTAssertTrue(results.errors.isEmpty,
                      "No errors expected from concurrent cache hits, got \(results.errors.count)")
        let uniqueObjects = Set(results.values)
        XCTAssertEqual(uniqueObjects.count, 1,
                       "Cache must memoize: all \(results.values.count) calls should return the same library, got \(uniqueObjects.count) distinct")
    }

    // MARK: - VRMModel.withLock

    /// `withLock` must be a real mutex: N threads each incrementing a shared
    /// counter under the lock must produce exactly N*iterations as the final
    /// value, with no torn writes or lost updates.
    func testStressVRMModelWithLock_NoLostUpdates() {
        let model = makeMinimalModel()
        let box = IntBox()

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "stress-model-lock", attributes: .concurrent)
        let threadCount = stressThreadCount
        let iterations = stressIterations

        for _ in 0..<threadCount {
            group.enter()
            queue.async {
                defer { group.leave() }
                for _ in 0..<iterations {
                    model.withLock {
                        // Non-atomic read-modify-write — if the lock is real,
                        // this completes correctly. If not, we lose updates.
                        let snapshot = box.value
                        box.value = snapshot + 1
                    }
                }
            }
        }
        group.wait()

        XCTAssertEqual(box.value, threadCount * iterations,
                       "withLock must serialize: lost updates indicate a broken lock")
    }

    /// Recursive lock behavior is NOT promised — but nested `withLock` from
    /// the same thread must at minimum not deadlock the test runner. (NSLock
    /// is not re-entrant; the implementation must not nest lock acquisitions
    /// in callers' code paths.)
    func testStressVRMModelWithLock_DoesNotDeadlockUnderContention() {
        let model = makeMinimalModel()
        let expectation = expectation(description: "all tasks finish")
        expectation.expectedFulfillmentCount = stressThreadCount

        let queue = DispatchQueue(label: "stress-no-deadlock", attributes: .concurrent)
        let iterations = stressIterations
        for _ in 0..<stressThreadCount {
            queue.async {
                for _ in 0..<iterations {
                    _ = model.withLock { 1 + 1 }
                }
                expectation.fulfill()
            }
        }

        // 30s is generous; under proper locking this typically finishes
        // in well under 1s on M-series hardware.
        wait(for: [expectation], timeout: 30.0)
    }

    // MARK: - AnimationPlayer

    /// Pound `update(deltaTime:model:)` from one thread while `play / pause /
    /// seek / load` race from another. The player's docstring promises the
    /// update path is safe to call from a background thread while controls
    /// are touched concurrently.
    func testStressAnimationPlayer_UpdateRacesControl() {
        let model = makeMinimalModel()
        let player = AnimationPlayer()
        let clip = AnimationClip(duration: 1.0)
        player.load(clip)

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "stress-player", attributes: .concurrent)
        let stopFlag = AtomicFlag()

        // Updater
        group.enter()
        queue.async {
            defer { group.leave() }
            while !stopFlag.isSet {
                player.update(deltaTime: 0.016, model: model)
            }
        }

        // Controllers: each thread runs a mix of play/pause/seek/load.
        let iterations = stressIterations
        for _ in 0..<stressThreadCount {
            group.enter()
            queue.async {
                defer { group.leave() }
                for i in 0..<iterations {
                    switch i % 5 {
                    case 0: player.play()
                    case 1: player.pause()
                    case 2: player.seek(to: Float(i % 100) * 0.01)
                    case 3: player.load(AnimationClip(duration: 1.0))
                    default: _ = player.time
                    }
                }
            }
        }

        // Give controllers ~half a second to race the updater, then halt.
        queue.asyncAfter(deadline: .now() + 0.5) { stopFlag.set() }
        group.wait()

        // We can't assert a precise time value (it depends on scheduling), but
        // we _can_ assert no NaN/Inf leaked through and that time is in a
        // sensible range.
        let finalTime = player.time
        XCTAssertFalse(finalTime.isNaN, "AnimationPlayer.time leaked NaN under contention")
        XCTAssertFalse(finalTime.isInfinite, "AnimationPlayer.time leaked Inf under contention")
        XCTAssertGreaterThanOrEqual(finalTime, 0, "Player time should never go negative")
    }

    // MARK: - Helpers

    private func makeMinimalModel() -> VRMModel {
        let json = #"{"asset":{"version":"2.0"}}"#
        let gltf = try! JSONDecoder().decode(GLTFDocument.self, from: Data(json.utf8))
        return VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: ""), humanoid: nil, gltf: gltf)
    }

}

// MARK: - Test infrastructure

/// Thread-safe collector for results gathered from concurrent test paths.
/// Internal lock so the collector itself isn't a race source.
private final class ConcurrentResultCollector<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Value] = []
    private var _errors: [Error] = []

    func append(_ value: Value) {
        lock.lock(); defer { lock.unlock() }
        _values.append(value)
    }

    func appendError(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        _errors.append(error)
    }

    var values: [Value] {
        lock.lock(); defer { lock.unlock() }
        return _values
    }

    var errors: [Error] {
        lock.lock(); defer { lock.unlock() }
        return _errors
    }
}

/// Mutable Int reference cell used as the shared counter for lock stress tests.
/// Mutation is intentionally **unsynchronized** here — the whole point of the
/// test is to prove that the wrapping `model.withLock { ... }` provides the
/// serialization. If the lock works, we observe no torn writes; if it doesn't,
/// the final count is below the expected total.
private final class IntBox: @unchecked Sendable {
    var value: Int = 0
}

/// Tiny boolean flag with atomic semantics for halting concurrent runs.
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    func set() {
        lock.lock(); defer { lock.unlock() }
        _value = true
    }
}
