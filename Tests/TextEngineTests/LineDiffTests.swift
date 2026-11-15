import Testing
@testable import TextEngine

struct LineDiffTests {
	/// Applying the runs to the old lines gives the new ones; the edit count is minimal.
	@Test func runsRebuildNewTextMinimally() {
		let a = ["a", "b", "c", "a", "b", "b", "a"], b = ["c", "b", "a", "b", "a", "c"]
		let runs = LineDiff.diff(a, b)
		var rebuilt: [String] = []
		for r in runs where r.kind != .delete { rebuilt += r.kind == .equal ? Array(a[r.old]) : Array(b[r.new]) }
		#expect(rebuilt == b)
		let edits = runs.filter { $0.kind != .equal }.reduce(0) { $0 + $1.old.count + $1.new.count }
		#expect(edits == 5) // the classic Myers example: D = 5
	}

	@Test func randomEditsRoundTrip() {
		var rng = SystemRandomNumberGenerator()
		for _ in 0..<200 {
			let a = (0..<Int.random(in: 0...15, using: &rng)).map { _ in String(Int.random(in: 0...4, using: &rng)) }
			let b = (0..<Int.random(in: 0...15, using: &rng)).map { _ in String(Int.random(in: 0...4, using: &rng)) }
			var rebuilt: [String] = []
			var oldCovered = 0
			for r in LineDiff.diff(a, b) {
				#expect(r.old.lowerBound == oldCovered)
				oldCovered = r.old.upperBound
				if r.kind != .delete { rebuilt += r.kind == .equal ? Array(a[r.old]) : Array(b[r.new]) }
			}
			#expect(rebuilt == b && oldCovered == a.count)
		}
	}

	@Test func unifiedHunkWithContext() {
		let a = (1...10).map(String.init)
		var b = a
		b[4] = "five"
		let lines = LineDiff.unified(a, b, context: 2)
		#expect(lines.first?.prefix == "@" && lines.first?.text == "@@ -3,5 +3,5 @@")
		#expect(lines.dropFirst().map { "\($0.prefix)\($0.text)" } == [" 3", " 4", "-5", "+five", " 6", " 7"])
	}
}
