import Foundation

/// Minimal glb (binary glTF 2.0) container: one JSON chunk + optional BIN
/// chunk. Edits happen on the parsed `json` dictionary and raw `bin` data;
/// `serialize()` re-emits with correct 4-byte alignment. Bytes we do not
/// touch are preserved (producer truth).
public struct GLBContainer {
    public var json: [String: Any]
    public var bin: Data

    public enum GLBError: Error { case notGLB, truncated, noJSONChunk }

    public init(json: [String: Any], bin: Data) {
        self.json = json
        self.bin = bin
    }

    public init(data: Data) throws {
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

    public mutating func serialize() throws -> Data {
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
