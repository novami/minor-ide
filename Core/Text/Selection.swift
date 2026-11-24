/// One selection: `anchor` stays put while extending, `head` is where the caret is drawn.
/// Offsets are UTF-8 byte offsets into the rope.
nonisolated public struct Selection: Sendable, Hashable {
	public var anchor: Int
	public var head: Int

	public init(anchor: Int, head: Int) {
		self.anchor = anchor
		self.head = head
	}

	public init(caret: Int) { self.init(anchor: caret, head: caret) }

	public var range: Range<Int> { min(anchor, head)..<max(anchor, head) }
	public var isEmpty: Bool { anchor == head }
	public var isReversed: Bool { head < anchor }
}

/// Selections sorted by position and never overlapping; `primary` is the one the
/// view scrolls to and that input methods see (the most recently added).
nonisolated public struct SelectionSet: Sendable, Equatable {
	public private(set) var all: [Selection]
	public private(set) var primaryIndex: Int

	public init(caret: Int = 0) {
		all = [Selection(caret: caret)]
		primaryIndex = 0
	}

	/// Sorts and merges overlapping selections. `primary` indexes into `selections`.
	public init(_ selections: [Selection], primary: Int? = nil) {
		precondition(!selections.isEmpty, "selection set cannot be empty")
		let p = primary ?? selections.count - 1
		let order = selections.indices.sorted {
			let a = selections[$0].range, b = selections[$1].range
			return a.lowerBound != b.lowerBound ? a.lowerBound < b.lowerBound : a.upperBound < b.upperBound
		}
		var merged: [Selection] = []
		var primaryIndex = 0
		for i in order {
			let s = selections[i]
			if let last = merged.last, Self.overlaps(last, s) {
				let lower = last.range.lowerBound
				let upper = max(last.range.upperBound, s.range.upperBound)
				let reversed = last.isEmpty ? s.isReversed : last.isReversed
				merged[merged.count - 1] = reversed ? Selection(anchor: upper, head: lower) : Selection(anchor: lower, head: upper)
			} else {
				merged.append(s)
			}
			if i == p { primaryIndex = merged.count - 1 }
		}
		all = merged
		self.primaryIndex = primaryIndex
	}

	/// Ranges overlap, or touch while one of them is a bare caret.
	private static func overlaps(_ a: Selection, _ b: Selection) -> Bool {
		b.range.lowerBound < a.range.upperBound
			|| (b.range.lowerBound == a.range.upperBound && (a.isEmpty || b.isEmpty))
	}

	public var primary: Selection { all[primaryIndex] }
	public var count: Int { all.count }

	/// Adds a selection and makes it primary.
	public func adding(_ s: Selection) -> SelectionSet {
		SelectionSet(all + [s], primary: all.count)
	}

	/// Replaces the primary selection (extending with Shift, dragging).
	public func replacingPrimary(_ s: Selection) -> SelectionSet {
		var list = all
		list[primaryIndex] = s
		return SelectionSet(list, primary: primaryIndex)
	}

	/// Applies `transform` to every selection, keeping the primary one.
	public func map(_ transform: (Selection) -> Selection) -> SelectionSet {
		SelectionSet(all.map(transform), primary: primaryIndex)
	}

	/// Follows an edit: carets stay after inserted text, ranges do not grow at their edges.
	public func mapped(through changes: ChangeSet) -> SelectionSet {
		map { s in
			if s.isEmpty { return Selection(caret: changes.map(s.head, bias: .after)) }
			let lower = changes.map(s.range.lowerBound, bias: .after)
			let upper = max(lower, changes.map(s.range.upperBound, bias: .before))
			return s.isReversed ? Selection(anchor: upper, head: lower) : Selection(anchor: lower, head: upper)
		}
	}
}

/// Several replacements applied together (one per caret). Ranges are in the
/// coordinates of the text before the edit; overlapping ranges are merged.
nonisolated public struct ChangeSet: Sendable, Equatable {
	public struct Change: Sendable, Equatable {
		public var range: Range<Int>
		public var text: [UInt8]

		public init(range: Range<Int>, text: [UInt8]) {
			self.range = range
			self.text = text
		}
	}

	public enum Bias: Sendable { case before, after }

	public private(set) var changes: [Change]
	/// `deltas[i]`: how much the changes before `changes[i]` shift the text.
	private var deltas: [Int] = []

	public init(_ edits: [(Range<Int>, String)]) {
		self.init(changes: edits.map { Change(range: $0.0, text: Array($0.1.utf8)) })
	}

	public init(changes edits: [Change]) {
		let sorted = edits
			.sorted { $0.range.lowerBound != $1.range.lowerBound ? $0.range.lowerBound < $1.range.lowerBound : $0.range.upperBound < $1.range.upperBound }
		var out: [Change] = []
		for c in sorted {
			if let last = out.last, c.range.lowerBound < last.range.upperBound {
				out[out.count - 1] = Change(range: last.range.lowerBound..<max(last.range.upperBound, c.range.upperBound), text: last.text + c.text)
			} else {
				out.append(c)
			}
		}
		changes = out
		deltas.reserveCapacity(out.count + 1)
		var delta = 0
		for c in out {
			deltas.append(delta)
			delta += c.text.count - c.range.count
		}
		deltas.append(delta)
	}

	public var isEmpty: Bool { changes.allSatisfy { $0.range.isEmpty && $0.text.isEmpty } }

	/// The change set that undoes this one; `rope` is the text before the edit.
	public func inverted(against rope: Rope) -> ChangeSet {
		var delta = 0
		var out: [Change] = []
		for c in changes {
			let start = c.range.lowerBound + delta
			out.append(Change(range: start..<(start + c.text.count), text: rope.bytes(in: c.range)))
			delta += c.text.count - c.range.count
		}
		return ChangeSet(changes: out)
	}

	/// Applies back to front, so earlier ranges stay valid.
	public func apply(to rope: inout Rope) {
		for c in changes.reversed() { rope.replace(c.range, with: c.text) }
	}

	/// Where `offset` ends up after the edit. At an insertion point or inside a
	/// replaced range, `.before` keeps it before the new text and `.after` puts it after.
	public func map(_ offset: Int, bias: Bias) -> Int {
		// First change the offset is not past (upper bounds never decrease).
		var lo = 0, hi = changes.count
		while lo < hi {
			let mid = (lo + hi) / 2
			let r = changes[mid].range
			if offset > r.upperBound || (offset == r.upperBound && !r.isEmpty) { lo = mid + 1 } else { hi = mid }
		}
		let delta = deltas[lo]
		guard lo < changes.count else { return offset + delta }
		let c = changes[lo]
		if offset < c.range.lowerBound { return offset + delta }
		if offset == c.range.lowerBound && !c.range.isEmpty { return offset + delta }
		return c.range.lowerBound + delta + (bias == .after ? c.text.count : 0)
	}
}
