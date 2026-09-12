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

public struct SpringJoint: AuthorModel {
    public var node: String
    public var hitRadius: Double
    public var stiffness: Double
    public var gravityPower: Double
    public var gravityDir: [Double]
    public var dragForce: Double

    public init(node: String, hitRadius: Double = 0, stiffness: Double = 1, gravityPower: Double = 0, gravityDir: [Double] = [0, -1, 0], dragForce: Double = 0.5) {
        self.node = node
        self.hitRadius = hitRadius
        self.stiffness = stiffness
        self.gravityPower = gravityPower
        self.gravityDir = gravityDir
        self.dragForce = dragForce
    }

    public static let modelName = "SpringJoint"
    public static let schema = JSONSchema.object(properties: [
        "node": .id,
        "hitRadius": .number(minimum: 0).unit("metres").defaulting(to: 0),
        "stiffness": .number(minimum: 0).defaulting(to: 1),
        "gravityPower": .number(minimum: 0).defaulting(to: 0),
        "gravityDir": .vector(3).unit("direction").defaulting(to: [0, -1, 0]),
        "dragForce": JSONSchema.unit.defaulting(to: 0.5),
    ], required: ["node"], description: "VRMC_springBone joint with schema defaults")

    public func validate() throws {
        try ModelCheck.finite(hitRadius, "/hitRadius")
        try ModelCheck.finite(stiffness, "/stiffness")
        try ModelCheck.finite(gravityPower, "/gravityPower")
        guard hitRadius >= 0, stiffness >= 0, gravityPower >= 0 else {
            throw AuthorError.invalidRequest("hitRadius, stiffness and gravityPower must be nonnegative.", path: "/stiffness")
        }
        try ModelCheck.count(gravityDir, 3, "/gravityDir")
        try ModelCheck.range(dragForce, 0, 1, "/dragForce")
    }
}

public struct SpringObject: AuthorModel {
    public var id: String
    public var name: String?
    public var center: String?
    public var joints: [SpringJoint]
    public var colliderGroups: [String]

    public init(id: String, name: String? = nil, center: String? = nil, joints: [SpringJoint], colliderGroups: [String] = []) {
        self.id = id
        self.name = name
        self.center = center
        self.joints = joints
        self.colliderGroups = colliderGroups
    }

    public static let modelName = "Spring"
    public static let schema = JSONSchema.object(properties: [
        "id": .id,
        "name": .string(),
        "center": .id.described("Optional center node"),
        "joints": .array(of: SpringJoint.schema, minItems: 2, description: "Ordered joints; the last is the terminal tail"),
        "colliderGroups": .idList.defaulting(to: []),
    ], required: ["id", "joints"], description: "VRMC_springBone spring chain")

    public func validate() throws {
        guard joints.count >= 2 else { throw AuthorError.invalidRequest("A spring needs at least a root joint and a terminal tail.", path: "/joints") }
        for j in joints { try j.validate() }
        try ModelCheck.uniqueIds(joints.map(\.node), "/joints")
    }
}

public struct SphereShape: AuthorModel {
    public var offset: [Double]
    public var radius: Double

    public init(offset: [Double] = [0, 0, 0], radius: Double) {
        self.offset = offset
        self.radius = radius
    }

    public static let modelName = "SphereShape"
    public static let schema = JSONSchema.object(properties: [
        "offset": .vector(3).unit("metres").defaulting(to: [0, 0, 0]), "radius": .number(minimum: 0).unit("metres"),
    ], required: ["radius"])

    public func validate() throws {
        try ModelCheck.count(offset, 3, "/offset")
        try ModelCheck.finite(radius, "/radius")
        guard radius >= 0 else { throw AuthorError.invalidRequest("radius must be nonnegative.", path: "/radius", observed: .number(radius)) }
    }
}

public struct CapsuleShape: AuthorModel {
    public var offset: [Double]
    public var radius: Double
    public var tail: [Double]

    public init(offset: [Double] = [0, 0, 0], radius: Double, tail: [Double]) {
        self.offset = offset
        self.radius = radius
        self.tail = tail
    }

    public static let modelName = "CapsuleShape"
    public static let schema = JSONSchema.object(properties: [
        "offset": .vector(3).unit("metres").defaulting(to: [0, 0, 0]), "radius": .number(minimum: 0).unit("metres"), "tail": .vector(3).unit("metres"),
    ], required: ["radius", "tail"])

    public func validate() throws {
        try ModelCheck.count(offset, 3, "/offset")
        try ModelCheck.count(tail, 3, "/tail")
        try ModelCheck.finite(radius, "/radius")
        guard radius >= 0 else { throw AuthorError.invalidRequest("radius must be nonnegative.", path: "/radius", observed: .number(radius)) }
    }
}

public struct ColliderShape: AuthorModel {
    public var sphere: SphereShape?
    public var capsule: CapsuleShape?

    public init(sphere: SphereShape) { self.sphere = sphere }
    public init(capsule: CapsuleShape) { self.capsule = capsule }

    public static let modelName = "ColliderShape"
    public static let schema = JSONSchema.oneOf([
        .object(properties: ["sphere": SphereShape.schema], required: ["sphere"]),
        .object(properties: ["capsule": CapsuleShape.schema], required: ["capsule"]),
    ], description: "Exactly one of sphere or capsule")

    public func validate() throws {
        guard (sphere == nil) != (capsule == nil) else { throw AuthorError.invalidRequest("Collider shape must be exactly one of sphere or capsule.", path: "/shape") }
        try sphere?.validate()
        try capsule?.validate()
    }
}

public struct ColliderObject: AuthorModel {
    public var id: String
    public var node: String
    public var shape: ColliderShape

    public init(id: String, node: String, shape: ColliderShape) {
        self.id = id
        self.node = node
        self.shape = shape
    }

    public static let modelName = "Collider"
    public static let schema = JSONSchema.object(properties: [
        "id": .id, "node": .id, "shape": ColliderShape.schema,
    ], required: ["id", "node", "shape"], description: "VRMC_springBone collider; offsets node-local metres")

    public func validate() throws { try shape.validate() }
}

public struct ColliderGroupObject: AuthorModel {
    public var id: String
    public var name: String?
    public var colliders: [String]

    public init(id: String, name: String? = nil, colliders: [String]) {
        self.id = id
        self.name = name
        self.colliders = colliders
    }

    public static let modelName = "ColliderGroup"
    public static let schema = JSONSchema.object(properties: [
        "id": .id, "name": .string(), "colliders": .idList,
    ], required: ["id", "colliders"], description: "VRMC_springBone collider group")

    public func validate() throws { try ModelCheck.uniqueIds(colliders, "/colliders") }
}
