import XCTest
@testable import MinorIDE

final class HistoryTests: XCTestCase {
	func testInvertedChangeSetRestoresText() {
		var rope = Rope("abc\ndef")
		let cs = ChangeSet([(1..<2, "XYZ"), (4..<4, "-"), (5..<7, "")])
		let inverse = cs.inverted(against: rope)
		cs.apply(to: &rope)
		XCTAssertEqual(rope.string, "aXYZc\n-d")
		inverse.apply(to: &rope)
		XCTAssertEqual(rope.string, "abc\ndef")
	}

	/// Random multi-caret edits, then undo everything and redo everything.
	func testRandomEditsUndoAndRedo() {
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
			XCTAssertEqual(rope.string, snapshots[n])
		}
		for n in 1...steps {
			for t in history.redo()!.transactions { t.changes.apply(to: &rope) }
			XCTAssertEqual(rope.string, snapshots[n])
		}
	}

	/// Typing, deleting, caret moves, undo and redo interleaved at random, checked against
	/// a model that keeps the text and selections after each undo step.
	func testInterleavedEditsUndoRedoMatchModel() {
		var rng = SplitMix64(seed: 99)
		var rope = Rope("ahoj\nsvěte\n😀 čau\n")
		var sel = SelectionSet(caret: 0)
		var history = EditHistory()
		var states = [(rope.string, sel)] // states[i] = after undo step i
		var befores = [sel] // befores[i] = selections right before step i
		var current = 0
		var time = 0.0
		let pieces = ["a", "b", " ", "\n", "č", "😀", "_x"]

		func randomCarets() -> SelectionSet {
			let raw = (0..<Int.random(in: 1...3, using: &rng)).map { _ -> Selection in
				let a = rope.scalarBoundary(atOrBefore: Int.random(in: 0...rope.byteCount, using: &rng))
				let b = rng.next() % 3 == 0 ? rope.scalarBoundary(atOrBefore: min(rope.byteCount, a + 4)) : a
				return Selection(anchor: a, head: b)
			}
			return SelectionSet(raw)
		}

		for _ in 0..<3000 {
			time += [0.1, 0.1, 0.1, 1.0][Int(rng.next() % 4)]
			switch rng.next() % 10 {
			case 0:
				sel = randomCarets()
			case 1:
				guard let step = history.undo() else { continue }
				for t in step.transactions.reversed() { t.inverse.apply(to: &rope) }
				sel = step.selectionsBefore
				XCTAssertEqual(sel, befores[current])
				current -= 1
				XCTAssertEqual(rope.string, states[current].0)
			case 2:
				guard let step = history.redo() else { continue }
				for t in step.transactions { t.changes.apply(to: &rope) }
				sel = step.selectionsAfter
				current += 1
				XCTAssertEqual(rope.string, states[current].0)
				XCTAssertEqual(sel, states[current].1)
			default:
				let deleting = rng.next() % 3 == 0
				let piece = pieces[Int(rng.next() % UInt64(pieces.count))]
				let cs = ChangeSet(sel.all.map { s -> (Range<Int>, String) in
					guard deleting else { return (s.range, piece) }
					let start = s.isEmpty ? rope.scalarBoundary(atOrBefore: max(0, s.range.lowerBound - 1)) : s.range.lowerBound
					return (start..<s.range.upperBound, "")
				})
				guard !cs.isEmpty else { continue }
				let after = sel.mapped(through: cs).map { Selection(caret: $0.range.upperBound) }
				let before = history.undoStack.count, selBefore = sel
				history.record(Transaction(cs, on: rope, before: sel, after: after, kind: deleting ? .deleting : .typing, time: time))
				cs.apply(to: &rope)
				sel = after
				if history.undoStack.count > before {
					current += 1
					states.removeSubrange(current...)
					befores.removeSubrange(current...)
					states.append((rope.string, sel))
					befores.append(selBefore)
				} else {
					states[current] = (rope.string, sel)
				}
				XCTAssertTrue(history.undoStack.count == current && history.redoStack.isEmpty)
			}
		}
		XCTAssertTrue(rope.validate())
	}

	func testTypingCoalescesByWordPauseAndCaret() {
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
		XCTAssertEqual(history.undoStack.count, 2) // "foo ", "bar"
		type("x", after: 1) // pause
		XCTAssertEqual(history.undoStack.count, 3)
		type("y", at: 0) // caret moved
		XCTAssertEqual(history.undoStack.count, 4)
		history.seal()
		type("z", at: 1)
		XCTAssertEqual(history.undoStack.count, 5)
	}
}
