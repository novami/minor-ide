/// Handle of a position kept in an `AnchorSet`.
nonisolated public struct AnchorID: Sendable, Hashable {
	let raw: Int
}

/// Byte offsets that follow edits (diagnostics, bookmarks, breakpoints, navigation history).
/// An anchor inside deleted text moves to where the deletion was; an anchor at an
/// insertion point stays before the new text with `.before`, moves after it with `.after`.
nonisolated public struct AnchorSet: Sendable {
	private struct Entry: Sendable {
		var offset: Int
		var bias: ChangeSet.Bias
	}

	private var entries: [AnchorID: Entry] = [:]
	private var nextID = 0

	public init() {}

	public var count: Int { entries.count }

	public mutating func add(at offset: Int, bias: ChangeSet.Bias = .before) -> AnchorID {
		let id = AnchorID(raw: nextID)
		nextID += 1
		entries[id] = Entry(offset: offset, bias: bias)
		return id
	}

	public mutating func remove(_ id: AnchorID) {
		entries[id] = nil
	}

	public mutating func removeAll() {
		entries.removeAll()
	}

	public func offset(of id: AnchorID) -> Int? {
		entries[id]?.offset
	}

	/// Anchors inside `range` (end included), sorted by offset.
	public func anchors(in range: ClosedRange<Int>) -> [(id: AnchorID, offset: Int)] {
		entries.compactMap { range.contains($0.value.offset) ? (id: $0.key, offset: $0.value.offset) : nil }
			.sorted { $0.offset != $1.offset ? $0.offset < $1.offset : $0.id.raw < $1.id.raw }
	}

	/// Moves every anchor through an edit; `changes` are in the coordinates before it.
	public mutating func apply(_ changes: ChangeSet) {
		guard !entries.isEmpty, !changes.isEmpty else { return }
		for key in entries.keys {
			guard let e = entries[key] else { continue }
			entries[key]?.offset = changes.map(e.offset, bias: e.bias)
		}
	}
}
