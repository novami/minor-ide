import Foundation

/// Line layouts for a contiguous window of lines, stored in an array. Inserting or removing
/// lines shifts the window with one array splice instead of rebuilding a dictionary.
struct LayoutCache {
	private(set) var base = 0
	private var slots: [LineLayout?] = []

	/// A jump further than this from the window starts a new window instead of padding it.
	static let maxGap = 256

	var count: Int { slots.count }

	subscript(line: Int) -> LineLayout? {
		get {
			let i = line - base
			return i >= 0 && i < slots.count ? slots[i] : nil
		}
		set {
			var i = line - base
			if slots.isEmpty || i < -LayoutCache.maxGap || i >= slots.count + LayoutCache.maxGap {
				reset(at: line, with: newValue)
				return
			}
			if i < 0 {
				slots.insert(contentsOf: repeatElement(nil, count: -i), at: 0)
				base = line
				i = 0
			} else if i >= slots.count {
				slots.append(contentsOf: repeatElement(nil, count: i - slots.count + 1))
			}
			slots[i] = newValue
		}
	}

	/// Lines `line…line+removed` were replaced by `removed+delta+1` lines.
	mutating func shift(from line: Int, removed: Int, delta: Int) {
		guard !slots.isEmpty else { return }
		let lo = line - base
		let oldHi = line + removed + 1 - base
		if oldHi <= 0 { // edit entirely above the window
			base += delta
		} else if lo >= slots.count { // below the window
			return
		} else if lo < 0 { // overlaps the window start
			removeAll()
		} else if oldHi >= slots.count {
			slots.removeSubrange(lo...)
		} else {
			slots.replaceSubrange(lo..<oldHi, with: repeatElement(nil, count: removed + delta + 1))
		}
	}

	/// Drops layouts outside `keep` once the window exceeds `limit` lines.
	mutating func trim(keep: ClosedRange<Int>, limit: Int) {
		guard slots.count > limit else { return }
		let lo = max(keep.lowerBound - base, 0)
		let hi = min(keep.upperBound - base + 1, slots.count)
		let old = slots
		slots = lo < hi ? Array(slots[lo..<hi]) : []
		base += lo
		LayoutCache.release(old)
	}

	mutating func removeAll() {
		LayoutCache.release(slots)
		slots = []
	}

	private mutating func reset(at line: Int, with value: LineLayout?) {
		LayoutCache.release(slots)
		base = line
		slots = [value]
	}

	/// Frees layouts on a background queue; freeing thousands on the main thread caused 2 ms frame spikes.
	private static func release(_ layouts: [LineLayout?]) {
		guard !layouts.isEmpty else { return }
		let box = Evicted(layouts)
		DispatchQueue.global(qos: .utility).async { box.release() }
	}
}

/// CTLine is immutable and safe to release on any thread; nothing touches evicted layouts again.
private final class Evicted: @unchecked Sendable {
	private var layouts: [LineLayout?]?
	init(_ layouts: [LineLayout?]) { self.layouts = layouts }
	func release() { layouts = nil }
}
