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
import simd

/// Bit-exact disk serialization for `[[PoseSample]]`.
///
/// Every float is written as its `UInt32` bit pattern in decimal, never as a
/// decimal literal, so the round trip is exact and the fixture is a valid
/// byte-identity oracle. A `%.6f`-style format would silently round the
/// captured values and turn the gate into a fuzzy-match test.
enum PipelineBaselineFixture {
    static func serialize(_ sequences: [[PoseSample]]) -> String {
        var tokens: [String] = []
        tokens.reserveCapacity(sequences.reduce(0) { $0 + $1.reduce(0) { $0 + $1.bones.count + $1.roots.count } } * 4 + 8)
        tokens.append(String(sequences.count))
        for sequence in sequences {
            tokens.append(String(sequence.count))
            for sample in sequence {
                tokens.append(String(sample.bones.count))
                tokens.append(String(sample.roots.count))
                for v in sample.bones {
                    tokens.append(String(v.x.bitPattern))
                    tokens.append(String(v.y.bitPattern))
                    tokens.append(String(v.z.bitPattern))
                    tokens.append(String(v.w.bitPattern))
                }
                for v in sample.roots {
                    tokens.append(String(v.x.bitPattern))
                    tokens.append(String(v.y.bitPattern))
                    tokens.append(String(v.z.bitPattern))
                    tokens.append(String(v.w.bitPattern))
                }
            }
        }
        return tokens.joined(separator: "\n")
    }

    static func deserialize(_ text: String) -> [[PoseSample]] {
        var iterator = text.split(whereSeparator: { $0.isWhitespace }).makeIterator()
        func nextInt() -> Int { Int(iterator.next()!)! }
        func nextFloat() -> Float { Float(bitPattern: UInt32(iterator.next()!)!) }
        func nextVec4() -> SIMD4<Float> { SIMD4<Float>(nextFloat(), nextFloat(), nextFloat(), nextFloat()) }

        let modelCount = nextInt()
        var sequences: [[PoseSample]] = []
        sequences.reserveCapacity(modelCount)
        for _ in 0..<modelCount {
            let frameCount = nextInt()
            var frames: [PoseSample] = []
            frames.reserveCapacity(frameCount)
            for _ in 0..<frameCount {
                let boneCount = nextInt()
                let rootCount = nextInt()
                let bones = (0..<boneCount).map { _ in nextVec4() }
                let roots = (0..<rootCount).map { _ in nextVec4() }
                frames.append(PoseSample(bones: bones, roots: roots))
            }
            sequences.append(frames)
        }
        return sequences
    }

    static func write(_ sequences: [[PoseSample]], toFile path: String) throws {
        try serialize(sequences).write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func read(fromFile path: String) throws -> [[PoseSample]] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return deserialize(text)
    }
}
