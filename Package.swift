// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.
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

import PackageDescription

let package = Package(
    name: "VRMMetalKit",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
    ],
    products: [
        .library(
            name: "VRMMetalKit",
            targets: ["VRMMetalKit"]
        )
    ],
    targets: [
        .target(
            name: "VRMMetalKit",
            exclude: [
                "Shaders/MorphTargetCompute.metal",
                "Shaders/MorphAccumulate.metal",
                "Shaders/SpringBonePredict.metal",
                "Shaders/SpringBoneDistance.metal",
                "Shaders/SpringBoneCollision.metal",
                "Shaders/SpringBoneKinematic.metal",
                "Shaders/DebugShaders.metal",
                "Shaders/MToonShader.metal",
                "Shaders/SkinnedShader.metal",
                "Shaders/Toon2DShader.metal",
                "Shaders/Toon2DSkinnedShader.metal",
                "Shaders/SpriteShader.metal"
            ],
            resources: [
                .copy("Resources")
            ],
            swiftSettings: [
                .define("VRM_METALKIT_ENABLE_DEBUG_ANIMATION"),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "VRMAValidator",
            dependencies: ["VRMMetalKit"]
        ),
        .testTarget(
            name: "VRMMetalKitTests",
            dependencies: ["VRMMetalKit"],
            resources: [
                .copy("TestData")
            ]
        ),
    ]
)
