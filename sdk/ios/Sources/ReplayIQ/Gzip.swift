import Compression
import Foundation

/// gzip (RFC 1952) using the Compression framework's raw DEFLATE, so the SDK
/// needs no zlib dependency.
enum Gzip {
    static func compress(_ data: Data) -> Data? {
        let capacity = data.count + data.count / 8 + 1024
        var deflated = Data(count: capacity)
        let written = deflated.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(d, capacity, s, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 || data.isEmpty else { return nil }
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff])
        if data.isEmpty {
            out.append(contentsOf: [0x03, 0x00]) // empty final block
        } else {
            out.append(deflated.prefix(written))
        }
        appendLE(&out, crc32(data))
        appendLE(&out, UInt32(truncatingIfNeeded: data.count))
        return out
    }

    /// Inverse of `compress` (used by the tests).
    static func decompress(_ gz: Data) -> Data? {
        guard gz.count >= 18, gz[gz.startIndex] == 0x1f, gz[gz.startIndex + 1] == 0x8b else { return nil }
        let body = gz.subdata(in: (gz.startIndex + 10)..<(gz.endIndex - 8))
        let size = gz.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let capacity = max(Int(UInt32(littleEndian: size)), 1)
        var out = Data(count: capacity)
        let n = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            body.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, capacity, s, body.count, nil, COMPRESSION_ZLIB)
            }
        }
        return out.prefix(n)
    }

    private static func appendLE(_ d: inout Data, _ v: UInt32) {
        d.append(contentsOf: [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
    }

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for b in buf { crc = table[Int((crc ^ UInt32(b)) & 0xff)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
