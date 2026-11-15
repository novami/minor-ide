/// Line diff (Myers, O((N+M)·D)): the shortest edit script between two line lists, as
/// runs of equal, deleted and inserted lines. Very different texts (D over `maxEdits`)
/// fall back to "replace everything".
public enum LineDiff {
	public enum Kind: Sendable, Equatable { case equal, delete, insert }

	public struct Run: Sendable, Equatable {
		public var kind: Kind
		public var old: Range<Int>
		public var new: Range<Int>
	}

	public static func diff<T: Hashable>(_ a: [T], _ b: [T], maxEdits: Int = 20_000) -> [Run] {
		// Lines as small integers make comparisons cheap.
		var ids: [T: Int] = [:]
		func id(_ line: T) -> Int {
			if let known = ids[line] { return known }
			ids[line] = ids.count
			return ids.count - 1
		}
		let x = a.map(id), y = b.map(id)
		let n = x.count, m = y.count
		let max = min(n + m, maxEdits)
		var v = [Int](repeating: 0, count: 2 * max + 3) // diagonals -max-1 … max+1
		var trace: [[Int]] = []
		let off = max + 1
		var found = false
		outer: for d in 0...max {
			trace.append(v)
			for k in stride(from: -d, through: d, by: 2) {
				var i = (k == -d || (k != d && v[off + k - 1] < v[off + k + 1])) ? v[off + k + 1] : v[off + k - 1] + 1
				var j = i - k
				while i < n && j < m && x[i] == y[j] { i += 1; j += 1 }
				v[off + k] = i
				if i >= n && j >= m { found = true; break outer }
			}
		}
		guard found else {
			return [Run(kind: .delete, old: 0..<n, new: 0..<0), Run(kind: .insert, old: n..<n, new: 0..<m)].filter { !$0.old.isEmpty || !$0.new.isEmpty }
		}
		// Walk the trace back into single-line steps, then merge them into runs.
		var steps: [(Kind, Int, Int)] = [] // kind, old index, new index
		var i = n, j = m
		for d in stride(from: trace.count - 1, through: 0, by: -1) {
			let v = trace[d], k = i - j
			let prevK = (k == -d || (k != d && v[off + k - 1] < v[off + k + 1])) ? k + 1 : k - 1
			let prevI = d == 0 ? 0 : v[off + prevK], prevJ = prevI - prevK
			while i > prevI && j > prevJ { i -= 1; j -= 1; steps.append((.equal, i, j)) }
			if d > 0 {
				if i == prevI { j -= 1; steps.append((.insert, i, j)) } else { i -= 1; steps.append((.delete, i, j)) }
			}
		}
		var runs: [Run] = []
		for (kind, oi, nj) in steps.reversed() {
			let old = kind == .insert ? oi..<oi : oi..<(oi + 1)
			let new = kind == .delete ? nj..<nj : nj..<(nj + 1)
			if var last = runs.last, last.kind == kind, last.old.upperBound == old.lowerBound, last.new.upperBound == new.lowerBound {
				last.old = last.old.lowerBound..<old.upperBound
				last.new = last.new.lowerBound..<new.upperBound
				runs[runs.count - 1] = last
			} else {
				runs.append(Run(kind: kind, old: old, new: new))
			}
		}
		return runs
	}

	/// Unified diff text (`-`/`+`/space prefixes, @@ hunk headers, `context` lines around).
	public static func unified(_ a: [String], _ b: [String], context: Int = 3) -> [(prefix: Character, text: String)] {
		let runs = diff(a, b)
		var out: [(Character, String)] = []
		var hunk: [(Character, String)] = []
		var hunkOld = 0, hunkNew = 0, oldCount = 0, newCount = 0
		func flush() {
			guard hunk.contains(where: { $0.0 != " " }) else { hunk = []; return }
			out.append(("@", "@@ -\(hunkOld + 1),\(oldCount) +\(hunkNew + 1),\(newCount) @@"))
			out += hunk
			hunk = []
		}
		for (index, run) in runs.enumerated() {
			switch run.kind {
			case .equal:
				let lines = Array(a[run.old])
				let isFirst = index == 0, isLast = index == runs.count - 1
				if lines.count > context * 2 || isFirst || isLast {
					if !isFirst { // tail context of the hunk before
						for l in lines.prefix(context) { hunk.append((" ", l)); oldCount += 1; newCount += 1 }
						flush()
					}
					if !isLast { // head context of the next hunk
						let head = lines.suffix(context)
						hunkOld = run.old.upperBound - head.count
						hunkNew = run.new.upperBound - head.count
						oldCount = head.count
						newCount = head.count
						hunk = head.map { (" ", $0) }
					}
				} else {
					for l in lines { hunk.append((" ", l)); oldCount += 1; newCount += 1 }
				}
			case .delete:
				if hunk.isEmpty && oldCount == 0 && newCount == 0 { hunkOld = run.old.lowerBound; hunkNew = run.new.lowerBound }
				for l in a[run.old] { hunk.append(("-", l)); oldCount += 1 }
			case .insert:
				if hunk.isEmpty && oldCount == 0 && newCount == 0 { hunkOld = run.old.lowerBound; hunkNew = run.new.lowerBound }
				for l in b[run.new] { hunk.append(("+", l)); newCount += 1 }
			}
		}
		flush()
		return out
	}
}
