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

/// Lightweight logging helper gated by compilation flags (disabled by default).
///
/// Available flags:
/// - `VRM_METALKIT_ENABLE_LOGS` - Enable all VRMMetalKit logs
/// - `VRM_METALKIT_ENABLE_DEBUG_ANIMATION` - Enable verbose animation debugging
/// - `VRM_METALKIT_ENABLE_DEBUG_PHYSICS` - Enable verbose physics/SpringBone debugging
/// - `VRM_METALKIT_ENABLE_DEBUG_LOADER` - Enable verbose loading/parsing debugging

// MARK: - Build Configuration Validation

#if DEBUG && !VRM_METALKIT_ENABLE_LOGS && !VRM_METALKIT_ENABLE_DEBUG_ANIMATION && !VRM_METALKIT_ENABLE_DEBUG_PHYSICS && !VRM_METALKIT_ENABLE_DEBUG_LOADER
private let __vrmLoggerDebugNotice: Void = {
    fputs("⚠️ VRMMetalKit: Debug build without logging. Define VRM_METALKIT_ENABLE_LOGS to re-enable debug output.\n", stderr)
} ()
#endif

#if !DEBUG && (VRM_METALKIT_ENABLE_LOGS || VRM_METALKIT_ENABLE_DEBUG_ANIMATION || VRM_METALKIT_ENABLE_DEBUG_PHYSICS || VRM_METALKIT_ENABLE_DEBUG_LOADER)
private let __vrmLoggerReleaseNotice: Void = {
    fputs("⚠️ VRMMetalKit: Release build with debug logging enabled. Disable VRM_METALKIT_ENABLE_* flags for best performance.\n", stderr)
} ()
#endif

// MARK: - Logging Infrastructure

enum VRMLogLevel: String {
    case trace = "TRACE"
    case debug = "DEBUG"
    case info = "INFO"
    case notice = "NOTICE"
    case warning = "WARNING"
    case error = "ERROR"
    case critical = "CRITICAL"
}

@inline(__always)
func vrmLog(
    _ message: @autoclosure () -> String,
    level: VRMLogLevel = .debug,
    category: StaticString = #fileID,
    function: StaticString = #function,
    line: UInt = #line
) {
#if VRM_METALKIT_ENABLE_LOGS
    let categoryDescription = String(describing: category)
    let functionDescription = String(describing: function)
    let prefix = "[VRMMetalKit][\(level.rawValue)][\(categoryDescription).\(functionDescription)#\(line)]"
    Swift.print("\(prefix) \(message())")
#else
    _ = message
    _ = level
    _ = category
    _ = function
    _ = line
#endif
}

/// Animation-specific debug logging (gated by VRM_METALKIT_ENABLE_DEBUG_ANIMATION)
@inline(__always)
func vrmLogAnimation(
    _ message: @autoclosure () -> String,
    category: StaticString = #fileID,
    function: StaticString = #function,
    line: UInt = #line
) {
#if VRM_METALKIT_ENABLE_DEBUG_ANIMATION
    let categoryDescription = String(describing: category)
    let functionDescription = String(describing: function)
    let prefix = "[VRMMetalKit][ANIMATION][\(categoryDescription).\(functionDescription)#\(line)]"
    Swift.print("\(prefix) \(message())")
#else
    _ = message
    _ = category
    _ = function
    _ = line
#endif
}

/// Physics/SpringBone-specific debug logging (gated by VRM_METALKIT_ENABLE_DEBUG_PHYSICS)
@inline(__always)
func vrmLogPhysics(
    _ message: @autoclosure () -> String,
    category: StaticString = #fileID,
    function: StaticString = #function,
    line: UInt = #line
) {
#if VRM_METALKIT_ENABLE_DEBUG_PHYSICS
    let categoryDescription = String(describing: category)
    let functionDescription = String(describing: function)
    let prefix = "[VRMMetalKit][PHYSICS][\(categoryDescription).\(functionDescription)#\(line)]"
    Swift.print("\(prefix) \(message())")
#else
    _ = message
    _ = category
    _ = function
    _ = line
#endif
}

/// Loader-specific debug logging (gated by VRM_METALKIT_ENABLE_DEBUG_LOADER)
@inline(__always)
func vrmLogLoader(
    _ message: @autoclosure () -> String,
    category: StaticString = #fileID,
    function: StaticString = #function,
    line: UInt = #line
) {
#if VRM_METALKIT_ENABLE_DEBUG_LOADER
    let categoryDescription = String(describing: category)
    let functionDescription = String(describing: function)
    let prefix = "[VRMMetalKit][LOADER][\(categoryDescription).\(functionDescription)#\(line)]"
    Swift.print("\(prefix) \(message())")
#else
    _ = message
    _ = category
    _ = function
    _ = line
#endif
}
