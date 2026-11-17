/// What produced an edit; typing and deleting runs coalesce into one undo step.
public enum EditKind: Sendable {
	case typing, deleting, other
}

/// One recorded edit with the selections around it.
public struct Transaction: Sendable {
	public var changes: ChangeSet
	public var inverse: ChangeSet
	public var selectionsBefore: SelectionSet
	public var selectionsAfter: SelectionSet
	public var kind: EditKind
	/// Seconds, any monotonic clock.
	public var time: Double

	/// `rope` is the text before the edit.
	public init(_ changes: ChangeSet, on rope: Rope, before: SelectionSet, after: SelectionSet, kind: EditKind, time: Double) {
		self.changes = changes
		inverse = changes.inverted(against: rope)
		selectionsBefore = before
		selectionsAfter = after
		self.kind = kind
		self.time = time
	}
}

/// Undo/redo stacks. An undo step is a group of transactions applied in order;
/// typing joins the previous step while it continues where it stopped, within
/// `pause` seconds and without starting a new word or line.
public struct EditHistory: Sendable {
	public struct Step: Sendable {
		public fileprivate(set) var transactions: [Transaction]
		public var selectionsBefore: SelectionSet { transactions[0].selectionsBefore }
		public var selectionsAfter: SelectionSet { transactions[transactions.count - 1].selectionsAfter }
	}

	public var pause = 0.5
	public private(set) var undoStack: [Step] = []
	public private(set) var redoStack: [Step] = []
	private var sealed = false

	public init() {}

	public var canUndo: Bool { !undoStack.isEmpty }
	public var canRedo: Bool { !redoStack.isEmpty }

	/// `joiningLast`: the edit belongs to the previous step whatever its kind (a completion's late import).
	public mutating func record(_ t: Transaction, joiningLast: Bool = false) {
		redoStack.removeAll()
		if joiningLast, !undoStack.isEmpty {
			undoStack[undoStack.count - 1].transactions.append(t)
		} else if !sealed, let last = undoStack.last?.transactions.last, Self.coalesces(last, t, pause: pause) {
			undoStack[undoStack.count - 1].transactions.append(t)
		} else {
			undoStack.append(Step(transactions: [t]))
		}
		sealed = false
	}

	/// The next edit starts a new undo step (e.g. after saving).
	public mutating func seal() { sealed = true }

	public mutating func removeAll() {
		undoStack.removeAll()
		redoStack.removeAll()
	}

	/// Pops the last step; apply its transactions' inverses back to front.
	public mutating func undo() -> Step? {
		guard let step = undoStack.popLast() else { return nil }
		redoStack.append(step)
		sealed = true
		return step
	}

	/// Pops the last undone step; apply its transactions front to back.
	public mutating func redo() -> Step? {
		guard let step = redoStack.popLast() else { return nil }
		undoStack.append(step)
		sealed = true
		return step
	}

	static func coalesces(_ a: Transaction, _ b: Transaction, pause: Double) -> Bool {
		guard a.kind == b.kind, a.kind != .other, b.time - a.time <= pause,
		      a.selectionsAfter == b.selectionsBefore else { return false }
		switch b.kind {
		case .typing:
			// "foo bar" undoes as "bar", then "foo ".
			guard let prev = a.changes.changes.last?.text.last, let next = b.changes.changes.first?.text.first else { return true }
			return !(isWordByte(next) && !isWordByte(prev)) && next != 0x0A
		case .deleting:
			let removed = b.inverse.changes.flatMap(\.text)
			return !removed.contains(0x0A)
		case .other:
			return false
		}
	}

	/// Letters, digits, underscore and any non-ASCII byte (accented letters).
	private static func isWordByte(_ b: UInt8) -> Bool {
		b >= 0x80 || b == 0x5F || (b >= 0x30 && b <= 0x39) || ((b | 0x20) >= 0x61 && (b | 0x20) <= 0x7A)
	}
}
