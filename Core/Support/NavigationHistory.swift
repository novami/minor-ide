/// Back and forward through the places jumps left (plan 3.6), as in a browser: a jump records
/// where it started, Back returns there and keeps the current place for Forward, a new jump
/// clears Forward. `same` tells places that count as one (the same line of a file), so going
/// back from a place lands somewhere else. Methods return the places that left the history,
/// for the caller to free what they hold (anchors).
nonisolated public struct NavigationHistory<Place> {
	public private(set) var back: [Place] = []
	public private(set) var forward: [Place] = []
	public let limit: Int

	public init(limit: Int = 100) {
		self.limit = limit
	}

	public var canGoBack: Bool { !back.isEmpty }
	public var canGoForward: Bool { !forward.isEmpty }

	/// Before a jump away from `place`.
	public mutating func record(_ place: Place, same: (Place, Place) -> Bool) -> [Place] {
		var dropped = forward
		forward = []
		if let last = back.last, same(last, place) { dropped.append(back.removeLast()) }
		back.append(place)
		if back.count > limit { dropped.append(contentsOf: back.prefix(back.count - limit)); back.removeFirst(back.count - limit) }
		return dropped
	}

	/// The place to return to from `current` (nil: none), skipping places that are `current`.
	public mutating func goBack(from current: Place, same: (Place, Place) -> Bool) -> (place: Place?, dropped: [Place]) {
		step(&back, &forward, from: current, same: same)
	}

	public mutating func goForward(from current: Place, same: (Place, Place) -> Bool) -> (place: Place?, dropped: [Place]) {
		step(&forward, &back, from: current, same: same)
	}

	private func step(_ from: inout [Place], _ to: inout [Place], from current: Place,
	                  same: (Place, Place) -> Bool) -> (place: Place?, dropped: [Place]) {
		var dropped: [Place] = []
		while let target = from.popLast() {
			if same(target, current) {
				dropped.append(target)
				continue
			}
			if let last = to.last, same(last, current) { dropped.append(to.removeLast()) }
			to.append(current)
			return (target, dropped)
		}
		return (nil, dropped)
	}
}
