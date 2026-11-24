import Foundation

/// Classic hex view: offset, 16 bytes in hex (two groups of 8), printable ASCII.
nonisolated public enum HexDump {
	public static func format(_ data: Data, limit: Int = 1 << 20) -> String {
		let bytes = [UInt8](data.prefix(limit))
		let digits = Array("0123456789abcdef".utf8)
		var out: [UInt8] = []
		out.reserveCapacity(bytes.count / 16 * 78 + 80)
		for row in stride(from: 0, to: bytes.count, by: 16) {
			for shift in stride(from: 28, through: 0, by: -4) { out.append(digits[(row >> shift) & 0xF]) }
			out.append(contentsOf: [0x20, 0x20])
			let chunk = bytes[row..<min(row + 16, bytes.count)]
			for i in 0..<16 {
				if i == 8 { out.append(0x20) }
				if i < chunk.count {
					let b = chunk[chunk.startIndex + i]
					out.append(contentsOf: [digits[Int(b >> 4)], digits[Int(b & 0xF)], 0x20])
				} else {
					out.append(contentsOf: [0x20, 0x20, 0x20])
				}
			}
			out.append(contentsOf: [0x20, 0x7C])
			for b in chunk { out.append(b >= 0x20 && b < 0x7F ? b : 0x2E) }
			out.append(contentsOf: [0x7C, 0x0A])
		}
		return String(decoding: out, as: UTF8.self)
	}
}
