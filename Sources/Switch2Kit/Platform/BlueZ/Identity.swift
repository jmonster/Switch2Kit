#if os(Linux)
import Foundation

// RFC 4122 name-based UUIDs: stable for an adapter/address/type tuple, without
// publishing the Bluetooth address verbatim. This is an identifier, not a
// cryptographic anonymization guarantee. A rotating remote address changes it.
package enum BlueZIdentity {
    package static func uuid(name: String, namespace: UUID = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!) -> UUID {
        var uuid = namespace.uuid
        let prefix = withUnsafeBytes(of: &uuid) { Array($0) }
        var bytes = sha1(prefix + Array(name.utf8))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                           bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    private static func sha1(_ input: [UInt8]) -> [UInt8] {
        func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 { (value << count) | (value >> (32 - count)) }
        var message = input
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8(truncatingIfNeeded: bitLength >> shift)) }
        var hash: [UInt32] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0]
        for offset in stride(from: 0, to: message.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 80)
            for index in 0..<16 {
                for byte in message[(offset + index * 4)..<(offset + index * 4 + 4)] { words[index] = (words[index] << 8) | UInt32(byte) }
            }
            for index in 16..<80 { words[index] = rotate(words[index-3] ^ words[index-8] ^ words[index-14] ^ words[index-16], 1) }
            var a=hash[0], b=hash[1], c=hash[2], d=hash[3], e=hash[4]
            for index in 0..<80 {
                let f: UInt32, k: UInt32
                switch index {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5a827999
                case 20..<40: f = b ^ c ^ d; k = 0x6ed9eba1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc
                default: f = b ^ c ^ d; k = 0xca62c1d6
                }
                let next = rotate(a, 5) &+ f &+ e &+ k &+ words[index]
                e=d; d=c; c=rotate(b, 30); b=a; a=next
            }
            for (index, value) in [a,b,c,d,e].enumerated() { hash[index] &+= value }
        }
        return hash.flatMap { value in [24,16,8,0].map { UInt8(truncatingIfNeeded: value >> $0) } }
    }
    package static func addressBytes(_ address: String) -> Data? {
        let components = address.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 6, components.allSatisfy({ $0.count == 2 }) else { return nil }
        let bytes = components.compactMap { UInt8($0, radix: 16) }
        return bytes.count == 6 ? Data(bytes.reversed()) : nil
    }
}
#endif
