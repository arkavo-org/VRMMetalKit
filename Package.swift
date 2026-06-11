// swift-tools-version: 6.3
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
        ),
        .library(
            name: "GLTFMetalKit",
            targets: ["GLTFMetalKit"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.4.0")
    ],
    targets: [
        .target(
            name: "GLTFCore"
        ),
        .target(
            name: "GLTFMetalKit",
            dependencies: ["GLTFCore"],
            exclude: [
                "Shaders/GLTFPBRShader.metal",
                "Shaders/IBLPrefilter.metal"
            ],
            resources: [
                .copy("Resources/GLTFMetalKitShaders.metallib")
            ]
        ),
        .target(
            name: "VRMMetalKit",
            dependencies: ["GLTFCore"],
            exclude: [
                "Shaders/MorphAccumulate.metal",
                "Shaders/SpringBonePredict.metal",
                "Shaders/SpringBoneDistance.metal",
                "Shaders/SpringBoneCollision.metal",
                "Shaders/SpringBoneKinematic.metal",
                "Shaders/SpringBoneCenterDelta.metal",
                "Shaders/DebugShaders.metal",
                "Shaders/MToonShader.metal",
                "Shaders/SkinnedShader.metal",
                "Shaders/SpriteShader.metal"
            ],
            resources: [
                .copy("Resources/VRMMetalKitShaders.metallib"),
                .copy("Resources/VRMMetalKitShaders_iOS.metallib"),
                .copy("Resources/VRMMetalKitShaders_iOSSimulator.metallib")
            ]
        ),
        .executableTarget(
            name: "VRMAValidator",
            dependencies: ["VRMMetalKit"]
        ),
        .target(
            name: "VRMAProcessKit",
            dependencies: []
        ),
        .executableTarget(
            name: "VRMAProcess",
            dependencies: ["VRMAProcessKit"]
        ),
        .testTarget(
            name: "VRMAProcessKitTests",
            dependencies: ["VRMAProcessKit"]
        ),
        .executableTarget(
            name: "VRMRender",
            dependencies: ["VRMMetalKit"]
        ),
        .executableTarget(
            name: "VRMVideoRenderer",
            dependencies: ["VRMMetalKit"]
        ),
        .executableTarget(
            name: "VRMBenchmark",
            dependencies: ["VRMMetalKit"]
        ),
        .executableTarget(
            name: "GLTFRender",
            dependencies: ["GLTFMetalKit"]
        ),
        .testTarget(
            name: "VRMMetalKitTests",
            dependencies: ["VRMMetalKit", "VRMAProcessKit"],
            resources: [
                .copy("TestData")
            ]
        ),
        .testTarget(
            name: "GLTFMetalKitTests",
            dependencies: ["GLTFMetalKit"],
            resources: [
                .copy("TestData")
            ]
        ),
    ]
)
