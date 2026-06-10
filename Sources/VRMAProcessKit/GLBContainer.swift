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

/// Minimal glb (binary glTF 2.0) container: one JSON chunk + optional BIN
/// chunk. Edits happen on the parsed `json` dictionary and raw `bin` data;
/// `serialize()` re-emits with correct 4-byte alignment.
///
/// Contract: BIN bytes are preserved except for trailing zero padding added
/// when the length is not 4-byte aligned (re-parsing returns the padded
/// bytes). The JSON chunk is value-preserving but NORMALIZED on every
/// serialize (re-emitted via JSONSerialization with sorted keys), so JSON
/// byte layout is deterministic, not producer-identical.
public struct GLBContainer {
    public var json: [String: Any]
    public var bin: Data

    public enum GLBError: Error { case notGLB, truncated, noJSONChunk }

    public init(json: [String: Any], bin: Data) {
        self.json = json
        // Mirror the slice-safe pattern of init(data:): ensure startIndex == 0 so
        // byte-offset arithmetic in read/write helpers is index-space correct.
        self.bin = bin.startIndex == 0 ? bin : Data(bin)
    }

    public init(data input: Data) throws {
        let data = input.startIndex == 0 ? input : Data(input)
        guard data.count >= 12, data.prefix(4) == Data("glTF".utf8) else { throw GLBError.notGLB }
        var offset = 12
        var jsonDict: [String: Any]?
        var binData = Data()
        while offset + 8 <= data.count {
            let len = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })
            let type = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self) })
            guard offset + 8 + len <= data.count else { throw GLBError.truncated }
            let chunk = data.subdata(in: (offset + 8)..<(offset + 8 + len))
            if type == 0x4E4F534A {  // 'JSON'
                jsonDict = try JSONSerialization.jsonObject(with: chunk) as? [String: Any]
            } else if type == 0x004E4942 {  // 'BIN\0'
                binData = chunk
            }
            offset += 8 + len
        }
        guard let j = jsonDict else { throw GLBError.noJSONChunk }
        self.json = j
        self.bin = binData
    }

    public func serialize() throws -> Data {
        var jsonData = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }  // pad with spaces
        var paddedBin = bin
        while paddedBin.count % 4 != 0 { paddedBin.append(0x00) }
        var out = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        out.append(Data("glTF".utf8))
        u32(2)
        u32(UInt32(12 + 8 + jsonData.count + (paddedBin.isEmpty ? 0 : 8 + paddedBin.count)))
        u32(UInt32(jsonData.count)); u32(0x4E4F534A); out.append(jsonData)
        if !paddedBin.isEmpty { u32(UInt32(paddedBin.count)); u32(0x004E4942); out.append(paddedBin) }
        return out
    }
}
