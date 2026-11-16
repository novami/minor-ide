/// Changed lines of a text against a base version (the file at Git HEAD): what the change
/// gutter shows. Computed off the main thread from a rope snapshot.
public struct LineChange: Sendable, Equatable {
	public enum Kind: Sendable, Equatable { case added, modified, deleted }
	public let kind: Kind
	/// Lines of the current text; empty for a deletion (the lines were removed before
	/// `lines.lowerBound`).
	public let lines: Range<Int>
	/// Lines of the base version.
	public let old: Range<Int>

	public init(kind: Kind, lines: Range<Int>, old: Range<Int>) {
		self.kind = kind
		self.lines = lines
		self.old = old
	}
}

public enum LineChanges {
	/// Lines of a text as compared: split at `\n`, a trailing `\r` ignored.
	public static func lines(_ text: String) -> [Substring] {
		// UTF-8 bytes: as Characters "\r\n" is one grapheme, not a "\n".
		text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false).map { line in
			Substring(line.last == 0x0D ? line.dropLast() : line)
		}
	}

	/// Changes of `current` against `base`. The common head and tail are skipped first, so a
	/// typical edit diffs only a few lines; a region with very many edits counts as modified.
	public static func compute(base: [Substring], current: [Substring], maxEdits: Int = 1000) -> [LineChange] {
		var head = 0
		while head < base.count, head < current.count, base[head] == current[head] { head += 1 }
		var tail = 0
		while tail < base.count - head, tail < current.count - head, base[base.count - 1 - tail] == current[current.count - 1 - tail] { tail += 1 }
		let a = Array(base[head..<(base.count - tail)]), b = Array(current[head..<(current.count - tail)])
		if a.isEmpty && b.isEmpty { return [] }
		var changes: [LineChange] = []
		var old: Range<Int>?, new: Range<Int>?
		func close() {
			guard let o = old, let n = new else { return }
			let kind: LineChange.Kind = o.isEmpty ? .added : (n.isEmpty ? .deleted : .modified)
			changes.append(LineChange(kind: kind, lines: n, old: o))
			old = nil
			new = nil
		}
		for run in LineDiff.diff(a, b, maxEdits: maxEdits) {
			let o = (run.old.lowerBound + head)..<(run.old.upperBound + head)
			let n = (run.new.lowerBound + head)..<(run.new.upperBound + head)
			if run.kind == .equal { close(); continue }
			old = old.map { $0.lowerBound..<o.upperBound } ?? o
			new = new.map { $0.lowerBound..<n.upperBound } ?? n
		}
		close()
		return changes
	}
}
