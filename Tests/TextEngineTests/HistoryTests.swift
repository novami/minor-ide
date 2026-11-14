import Testing
@testable import TextEngine

struct HistoryTests {
	@Test func invertedChangeSetRestoresText() {
		var rope = Rope("abc\ndef")
		let cs = ChangeSet([(1..<2, "XYZ"), (4..<4, "-"), (5..<7, "")])
		let inverse = cs.inverted(against: rope)
		cs.apply(to: &rope)
		#expect(rope.string == "aXYZc\n-d")
		inverse.apply(to: &rope)
		#expect(rope.string == "abc\ndef")
	}

	/// Random multi-caret edits, then undo everything and redo everything.
	@Test func randomEditsUndoAndRedo() {
		var rng = SplitMix64(seed: 42)
		var rope = Rope("hello\nsvěte\n")
		var history = EditHistory()
		var snapshots = [rope.string]
		let alphabet = ["a", " ", "\n", "č", "xy", ""]
		for i in 0..<300 {
			var edits: [(Range<Int>, String)] = []
			for _ in 0..<Int.random(in: 1...3, using: &rng) {
				let a = rope.scalarBoundary(atOrBefore: Int.random(in: 0...rope.byteCount, using: &rng))
				let b = rope.scalarBoundary(atOrBefore: min(rope.byteCount, a + Int.random(in: 0...3, using: &rng)))
				edits.append((a..<max(a, b), alphabet.randomElement(using: &rng)!))
			}
			let cs = ChangeSet(edits)
			guard !cs.isEmpty else { continue }
			let sel = SelectionSet(caret: 0)
			history.record(Transaction(cs, on: rope, before: sel, after: sel, kind: .other, time: Double(i)))
			cs.apply(to: &rope)
			snapshots.append(rope.string)
		}
		let steps = history.undoStack.count
		for n in (0..<steps).reversed() {
			for t in history.undo()!.transactions.reversed() { t.inverse.apply(to: &rope) }
			#expect(rope.string == snapshots[n])
		}
		for n in 1...steps {
			for t in history.redo()!.transactions { t.changes.apply(to: &rope) }
			#expect(rope.string == snapshots[n])
		}
	}

	@Test func typingCoalescesByWordPauseAndCaret() {
		var history = EditHistory()
		var rope = Rope("")
		var time = 0.0
		func type(_ s: String, at offset: Int? = nil, after delay: Double = 0.1) {
			let at = offset ?? rope.byteCount
			let cs = ChangeSet([(at..<at, s)])
			time += delay
			history.record(Transaction(cs, on: rope, before: SelectionSet(caret: at), after: SelectionSet(caret: at + s.utf8.count),
			                           kind: .typing, time: time))
			cs.apply(to: &rope)
		}
		for c in "foo bar" { type(String(c)) }
		#expect(history.undoStack.count == 2) // "foo ", "bar"
		type("x", after: 1) // pause
		#expect(history.undoStack.count == 3)
		type("y", at: 0) // caret moved
		#expect(history.undoStack.count == 4)
		history.seal()
		type("z", at: 1)
		#expect(history.undoStack.count == 5)
	}
}
