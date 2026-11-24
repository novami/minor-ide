/// Array with a gap at the last edit, so inserting or removing elements near the previous
/// edit (typing) moves only a few of them instead of the whole tail.
nonisolated struct GapArray<Element> {
	private var storage: [Element]
	private var gapStart: Int
	private var gapEnd: Int
	private let filler: Element

	init(repeating value: Element, count: Int) {
		storage = Array(repeating: value, count: count)
		gapStart = count
		gapEnd = count
		filler = value
	}

	var count: Int { storage.count - (gapEnd - gapStart) }

	subscript(i: Int) -> Element {
		get { storage[i < gapStart ? i : i + gapEnd - gapStart] }
		set { storage[i < gapStart ? i : i + gapEnd - gapStart] = newValue }
	}

	private mutating func moveGap(to index: Int) {
		if index < gapStart {
			let n = gapStart - index
			for k in stride(from: n - 1, through: 0, by: -1) { storage[gapEnd - n + k] = storage[index + k] }
			gapStart -= n
			gapEnd -= n
		} else if index > gapStart {
			let n = index - gapStart
			for k in 0..<n { storage[gapStart + k] = storage[gapEnd + k] }
			gapStart += n
			gapEnd += n
		}
	}

	/// Replaces `range` with `newCount` copies of `value`.
	mutating func replace(_ range: Range<Int>, with value: Element, count newCount: Int) {
		moveGap(to: range.lowerBound)
		gapEnd += range.count // the removed elements join the gap
		if gapEnd - gapStart < newCount {
			let grow = max(newCount, 1024, storage.count / 8)
			storage.insert(contentsOf: repeatElement(filler, count: grow), at: gapEnd)
			gapEnd += grow
		}
		for k in 0..<newCount { storage[gapStart + k] = value }
		gapStart += newCount
	}
}
