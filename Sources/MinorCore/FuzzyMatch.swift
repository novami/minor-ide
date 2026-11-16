/// Fuzzy matching of a query against file paths: the query's characters must appear in order
/// (case-insensitive); the best placement is chosen by dynamic programming. Matches at word
/// starts (after `/ _ - .` or space, camelCase humps, start of the file name), consecutive
/// runs and matches in the file name score higher; gaps cost a little.
/// Spaces split the query into terms that must all match (in any order).
public struct FuzzyQuery: Sendable {
	let terms: [[UInt8]]

	public init(_ text: String) {
		terms = text.lowercased().split(separator: " ").map { Array($0.utf8) }
	}

	public var isEmpty: Bool { terms.isEmpty }

	/// Score of `path`, nil when it does not match.
	public func score(_ path: FuzzyPath) -> Int? {
		var scratch = Scratch()
		return score(path, &scratch)
	}

	/// Reusable rows of the scoring table (no allocation per path in a search loop).
	public struct Scratch {
		var prev: [Int] = [], cur: [Int] = []
		public init() {}
	}

	public func score(_ path: FuzzyPath, _ scratch: inout Scratch) -> Int? {
		var total = 0
		for term in terms {
			guard let s = FuzzyQuery.score(term, path, &scratch) else { return nil }
			total += s
		}
		return total
	}

	/// Byte offsets of matched characters (for highlighting a shown row).
	public func positions(_ path: FuzzyPath) -> [Int] {
		var all: Set<Int> = []
		for term in terms { all.formUnion(FuzzyQuery.positions(term, path)) }
		return all.sorted()
	}

	static let match = 16, boundary = 10, separator = 8, hump = 7, consecutive = 5, inName = 4
	static let gapStart = 3, gapExtend = 1
	static let none = Int.min / 4

	/// Bonus for matching at byte `j`.
	static func bonus(_ p: FuzzyPath, _ j: Int) -> Int {
		var b = j >= p.nameStart ? inName : 0
		if j == p.nameStart { return b + boundary }
		if j == 0 { return b + boundary }
		let prev = p.bytes[j - 1], c = p.bytes[j]
		switch prev {
		case UInt8(ascii: "/"): b += boundary
		case UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: " "): b += separator
		default:
			let prevLower = prev >= 0x61 && prev <= 0x7A, prevDigit = prev >= 0x30 && prev <= 0x39
			let upper = c >= 0x41 && c <= 0x5A, digit = c >= 0x30 && c <= 0x39
			if (prevLower && upper) || (!prevDigit && digit) { b += hump }
		}
		return b
	}

	/// Quick check that `term` is a subsequence; returns the range worth scoring.
	static func window(_ term: [UInt8], _ p: FuzzyPath) -> Range<Int>? {
		let lower = p.lower
		var i = 0, first = -1
		for j in 0..<lower.count where lower[j] == term[i] {
			if first < 0 { first = j }
			i += 1
			if i == term.count { break }
		}
		guard i == term.count else { return nil }
		// Last possible end: scan backwards for the term from the end.
		var k = term.count - 1, last = -1
		for j in stride(from: lower.count - 1, through: first, by: -1) where lower[j] == term[k] {
			if last < 0 { last = j }
			if k == 0 { break }
			k -= 1
		}
		return first..<(last + 1)
	}

	static func score(_ term: [UInt8], _ p: FuzzyPath, _ scratch: inout Scratch) -> Int? {
		guard let win = window(term, p) else { return nil }
		let n = win.count, m = term.count
		if scratch.prev.count < n {
			scratch.prev = [Int](repeating: none, count: n)
			scratch.cur = scratch.prev
		}
		for j in 0..<n { scratch.prev[j] = none }
		var prev: [Int] = [], cur: [Int] = []
		swap(&prev, &scratch.prev) // move out, so writes do not copy
		swap(&cur, &scratch.cur)
		defer { swap(&prev, &scratch.prev); swap(&cur, &scratch.cur) }
		for i in 0..<m {
			var carry = none // best of prev[k] - gap for k <= j-2
			for jj in 0..<n {
				let j = win.lowerBound + jj
				if jj >= 2 { carry = max(carry == none ? none : carry - gapExtend, prev[jj - 2] == none ? none : prev[jj - 2] - gapStart) }
				guard p.lower[j] == term[i] else { cur[jj] = none; continue }
				let gain = match + bonus(p, j)
				if i == 0 {
					cur[jj] = gain
				} else {
					var best = carry
					if jj >= 1, prev[jj - 1] != none { best = max(best, prev[jj - 1] + consecutive) }
					cur[jj] = best == none ? none : best + gain
				}
			}
			swap(&prev, &cur)
		}
		let best = prev[0..<n].max() ?? none
		return best <= none / 2 ? nil : best
	}

	static func positions(_ term: [UInt8], _ p: FuzzyPath) -> [Int] {
		guard let win = window(term, p) else { return [] }
		let n = win.count, m = term.count
		var table = [[Int]](repeating: [Int](repeating: none, count: n), count: m)
		var from = [[Int]](repeating: [Int](repeating: -1, count: n), count: m)
		for i in 0..<m {
			var carry = none, carryFrom = -1
			for jj in 0..<n {
				let j = win.lowerBound + jj
				if jj >= 2, i > 0 {
					let extended = carry == none ? none : carry - gapExtend
					let started = table[i - 1][jj - 2] == none ? none : table[i - 1][jj - 2] - gapStart
					if started >= extended { carry = started; carryFrom = jj - 2 } else { carry = extended }
				}
				guard p.lower[j] == term[i] else { continue }
				let gain = match + bonus(p, j)
				if i == 0 { table[i][jj] = gain; continue }
				var best = carry, origin = carryFrom
				if jj >= 1, table[i - 1][jj - 1] != none, table[i - 1][jj - 1] + consecutive >= best {
					best = table[i - 1][jj - 1] + consecutive
					origin = jj - 1
				}
				if best != none { table[i][jj] = best + gain; from[i][jj] = origin }
			}
		}
		guard var jj = table[m - 1].indices.max(by: { table[m - 1][$0] < table[m - 1][$1] }), table[m - 1][jj] != none else { return [] }
		var result: [Int] = []
		for i in stride(from: m - 1, through: 0, by: -1) {
			result.append(win.lowerBound + jj)
			if i > 0 { jj = from[i][jj] }
		}
		return result.reversed()
	}
}

/// A path prepared for matching (bytes, ASCII-lowercased bytes, file name offset).
public struct FuzzyPath: Sendable {
	public let path: String
	let bytes: [UInt8]
	let lower: [UInt8]
	let nameStart: Int

	public init(_ path: String) {
		self.path = path
		bytes = Array(path.utf8)
		lower = bytes.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 32 : $0 }
		nameStart = (bytes.lastIndex(of: UInt8(ascii: "/")) ?? -1) + 1
	}
}
