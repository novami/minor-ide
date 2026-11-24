/// Tokens of a document, kept current across edits. The state at each line start is stored;
/// after an edit lexing restarts at the edited line and stops as soon as the state at a
/// line start equals the one stored before (usually right after the edited line). States
/// past `validUpTo` are computed when a line there is drawn, or in the background
/// (`backgroundJob` / `finishBackgroundJob`).
nonisolated public final class SyntaxHighlighter {
	public let lexer: any Lexer
	/// State at the start of each line (count = lines + 1); entries after `validUpTo` are stale.
	private var states: GapArray<LexState>
	/// states[0...validUpTo] are correct.
	public private(set) var validUpTo = 0
	/// Lines relexed in one edit before the rest is left for later (an opened block comment).
	public var eagerLimit = 2000
	/// Bumped by every edit; background results for an older generation are dropped.
	public private(set) var generation = 0
	private var scratch: [Token] = []

	public init(lexer: any Lexer, lineCount: Int) {
		self.lexer = lexer
		states = GapArray(repeating: .start, count: lineCount + 1)
	}

	private var lineCount: Int { states.count - 1 }

	/// Tokens of one line; lexes forward from the last known state when needed.
	public func tokens(line: Int, in rope: Rope) -> [Token] {
		ensureStates(upTo: line, in: rope)
		return tokens(line: line, bytes: rope.bytes(in: rope.lineRange(line)))
	}

	/// Tokens of a line whose bytes the caller already has; states up to it must be known
	/// (`tokens(line:in:)` or `prepare(upTo:in:)`).
	public func tokens(line: Int, bytes: [UInt8]) -> [Token] {
		var state = states[line]
		var tokens: [Token] = []
		lexer.lex(bytes[...], state: &state, tokens: &tokens)
		return tokens
	}

	/// Makes the states up to `line` known (before drawing a screen of lines).
	public func prepare(upTo line: Int, in rope: Rope) {
		ensureStates(upTo: line, in: rope)
	}

	/// State at the start of a line (embedded language at a position, smart indent later).
	public func state(atLine line: Int, in rope: Rope) -> LexState {
		ensureStates(upTo: line, in: rope)
		return states[line]
	}

	private func ensureStates(upTo line: Int, in rope: Rope) {
		guard line > validUpTo else { return }
		var state = states[validUpTo]
		var l = validUpTo
		Self.forEachLine(of: rope, from: validUpTo, count: line - validUpTo) { bytes in
			scratch.removeAll(keepingCapacity: true)
			lexer.lex(bytes, state: &state, tokens: &scratch)
			l += 1
			states[l] = state
		}
		validUpTo = line
	}

	/// Calls `body` with the bytes of `count` lines from `first`, read from the rope in large
	/// chunks (looking each line up separately costs more than lexing it).
	static func forEachLine(of rope: Rope, from first: Int, count: Int, _ body: (ArraySlice<UInt8>) -> Void) {
		guard count > 0 else { return }
		var offset = rope.offset(ofLine: first)
		var remaining = count
		var carry: [UInt8] = []
		while remaining > 0 {
			let end = min(offset + 1 << 16, rope.byteCount)
			let chunk = rope.bytes(in: offset..<end)
			var lineStart = 0
			while remaining > 0, let nl = chunk[lineStart...].firstIndex(of: 0x0A) {
				if carry.isEmpty {
					body(chunk[lineStart..<nl])
				} else {
					carry.append(contentsOf: chunk[lineStart..<nl])
					body(carry[...])
					carry.removeAll(keepingCapacity: true)
				}
				remaining -= 1
				lineStart = nl + 1
			}
			guard remaining > 0 else { return }
			carry.append(contentsOf: chunk[lineStart...])
			offset = end
			if end == rope.byteCount { // the last line has no newline
				body(carry[...])
				return
			}
		}
	}

	/// Follows an edit that replaced old lines `firstLine...oldLastLine` with
	/// `firstLine...newLastLine` (rope is the text after the edit). Returns the lines whose
	/// tokens may have changed, to redraw.
	@discardableResult
	public func edit(firstLine: Int, oldLastLine: Int, newLastLine: Int, in rope: Rope) -> ClosedRange<Int> {
		generation += 1
		// Keep the states after the edit, shifted; the edited lines' states are unknown.
		let delta = newLastLine - oldLastLine
		states.replace((firstLine + 1)..<(oldLastLine + 1), with: .start, count: newLastLine - firstLine)
		let previousValid = validUpTo
		guard firstLine < validUpTo else {
			validUpTo = min(validUpTo, firstLine)
			return firstLine...newLastLine
		}
		// Stored states after the edit are trustworthy only where they were valid before.
		let trustedFrom = newLastLine + 1, trustedTo = previousValid + delta
		var state = states[firstLine]
		var line = firstLine
		while line < rope.lineCount {
			scratch.removeAll(keepingCapacity: true)
			lexer.lex(rope.bytes(in: rope.lineRange(line))[...], state: &state, tokens: &scratch)
			line += 1
			if line >= trustedFrom && line <= trustedTo && states[line] == state {
				validUpTo = max(line, trustedTo)
				return firstLine...(line - 1)
			}
			states[line] = state
			if line - firstLine > eagerLimit && line > newLastLine {
				validUpTo = line
				return firstLine...(rope.lineCount - 1)
			}
		}
		validUpTo = rope.lineCount - 1
		return firstLine...(rope.lineCount - 1)
	}

	// MARK: Background

	/// Work left past `validUpTo`: lex it off the main thread with `lexStates`, then hand the
	/// result to `finishBackgroundJob`.
	public struct Job: Sendable {
		public let lexer: any Lexer
		public let rope: Rope
		public let from: Int
		public let state: LexState
		public let generation: Int
	}

	public func backgroundJob(rope: Rope) -> Job? {
		guard validUpTo < lineCount - 1 else { return nil }
		return Job(lexer: lexer, rope: rope, from: validUpTo, state: states[validUpTo], generation: generation)
	}

	/// States at the starts of lines job.from+1 … end; runs on any thread.
	public static func lexStates(_ job: Job) -> [LexState] {
		var state = job.state
		var result: [LexState] = []
		var tokens: [Token] = []
		result.reserveCapacity(job.rope.lineCount - job.from)
		forEachLine(of: job.rope, from: job.from, count: job.rope.lineCount - job.from) { bytes in
			tokens.removeAll(keepingCapacity: true)
			job.lexer.lex(bytes, state: &state, tokens: &tokens)
			result.append(state)
		}
		return result
	}

	/// Stores background results unless an edit came in between; true when stored.
	@discardableResult
	public func finishBackgroundJob(_ job: Job, states result: [LexState]) -> Bool {
		guard job.generation == generation, job.from <= validUpTo else { return false }
		for (i, s) in result.enumerated() where job.from + 1 + i > validUpTo {
			states[job.from + 1 + i] = s
		}
		validUpTo = max(validUpTo, min(lineCount - 1, job.from + result.count))
		return true
	}
}
