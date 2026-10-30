// Fork-only (phone-hub). Foundation-only: compiled into NOOPiOS AND the NOOPiOSHubTests bundle.
import Foundation

/// RFC 1952 gzip. Foundation has no gzip writer, but `NSData.compressed(using: .zlib)` produces a raw
/// RFC 1951 DEFLATE stream (no zlib header), so a gzip member is: 10-byte header + that stream +
/// CRC-32 (little-endian) + input size mod 2^32 (little-endian).
enum HubGzip {
    static func gzip(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff]) // magic, deflate, no flags, mtime 0, OS unknown
        out.append(deflated)
        appendLE32(&out, crc32(data))
        appendLE32(&out, UInt32(truncatingIfNeeded: data.count))
        return out
    }

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    private static func appendLE32(_ d: inout Data, _ v: UInt32) {
        d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }
}
