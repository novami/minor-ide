import AppKit
import EditorKit
import Highlight
import QuartzCore
import TextEngine

/// Phase-0 spike benchmark (spike 0.2). Times are synchronous draw times in the view,
/// a lower bound of on-screen latency (compositing adds roughly one frame).
@MainActor
enum Bench {
	static func run(_ app: AppDelegate) {
		let text = sampleText(bytes: 10 << 20)
		print("document:   \(text.utf8.count / 1_048_576) MB")

		var t = CACurrentMediaTime()
		app.openWindow(text: text, title: "bench")
		let editor = app.editor!
		// Synchronous layout (caret layer) and drawing of text and gutter; the Core Animation
		// commit waits on the render server and is covered by the key-to-frame latency.
		func display() {
			editor.window?.displayIfNeeded() // layout, and hands dirty rects to the layers
			editor.layer?.displayIfNeeded()
			editor.gutter?.layer?.displayIfNeeded()
			editor.sticky?.layer?.displayIfNeeded()
		}
		display()
		report("open + first draw", [CACurrentMediaTime() - t])
		print("lines:      \(editor.rope.lineCount)")

		// Typing in the middle of the document.
		let mid = editor.rope.lineRange(editor.rope.lineCount / 2).upperBound
		editor.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
		editor.replace(mid..<mid, with: "")
		// Warm-up, not measured: first use of fonts, caches and Core Animation layers.
		for _ in 0..<20 {
			editor.insertText("w", replacementRange: NSRange(location: NSNotFound, length: 0))
			display()
		}
		for _ in 0..<20 { editor.doCommand(by: #selector(NSResponder.deleteBackward(_:))) }
		display()
		var samples: [Double] = []
		var model = 0.0
		let drawBefore = editor.drawSeconds
		for _ in 0..<2000 {
			t = CACurrentMediaTime()
			editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
			model += CACurrentMediaTime() - t
			display()
			samples.append(CACurrentMediaTime() - t)
		}
		report("type char", samples)
		let total = samples.reduce(0, +)
		print(String(format: "  [type char breakdown per key: edit %.3f ms, draw body %.3f ms, AppKit/CA %.3f ms]",
		             model / 2 , (editor.drawSeconds - drawBefore) / 2, (total - model - (editor.drawSeconds - drawBefore)) / 2))

		samples = []
		for _ in 0..<300 {
			t = CACurrentMediaTime()
			editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
			display()
			samples.append(CACurrentMediaTime() - t)
		}
		report("type newline", samples)

		samples = []
		for _ in 0..<500 {
			t = CACurrentMediaTime()
			editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
			display()
			samples.append(CACurrentMediaTime() - t)
		}
		report("backspace", samples)

		// Scrolling through the document in 40 px steps, then a long jump.
		let clip = editor.enclosingScrollView!.contentView
		samples = []
		var y: CGFloat = 0
		for _ in 0..<2000 {
			y += 40
			t = CACurrentMediaTime()
			clip.scroll(to: NSPoint(x: 0, y: y))
			editor.enclosingScrollView!.reflectScrolledClipView(clip)
			display()
			samples.append(CACurrentMediaTime() - t)
		}
		report("scroll 40px", samples)

		samples = []
		for i in 0..<200 {
			t = CACurrentMediaTime()
			let target = (i * 7919 + 13) % max(1, Int(editor.frame.height) - 2000) // distinct positions, no tile cache hits
			clip.scroll(to: NSPoint(x: 0, y: CGFloat(target)))
			editor.enclosingScrollView!.reflectScrolledClipView(clip)
			display()
			samples.append(CACurrentMediaTime() - t)
		}
		report("scroll jump", samples)

		keyToFrame(editor)

		// Syntax colouring (the sample is Go): typing and jumping with tokens per drawn line.
		editor.highlighter = SyntaxHighlighter(lexer: GoLexer(), lineCount: editor.rope.lineCount)
		display()
		// The rest of the file is lexed in the background; jumps measured after it finished.
		t = CACurrentMediaTime()
		let lexed = Date(timeIntervalSinceNow: 5)
		while let h = editor.highlighter, h.validUpTo < editor.rope.lineCount - 1, Date() < lexed {
			RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
		}
		report("background lex go", [CACurrentMediaTime() - t])
		samples = []
		for _ in 0..<1000 {
			t = CACurrentMediaTime()
			editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
			display()
			samples.append(CACurrentMediaTime() - t)
		}
		report("type char go", samples)
		samples = []
		for _ in 0..<100 {
			t = CACurrentMediaTime()
			editor.insertText("\"", replacementRange: NSRange(location: NSNotFound, length: 0))
			display()
			samples.append(CACurrentMediaTime() - t)
			editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
			display()
		}
		report("type quote go", samples)
		samples = []
		var jump = UInt64(7)
		for _ in 0..<200 {
			jump = jump &* 6364136223846793005 &+ 1442695040888963407
			let line = Int(jump >> 33) % editor.rope.lineCount
			t = CACurrentMediaTime()
			editor.scroll(NSPoint(x: 0, y: CGFloat(line) * editor.lineHeight))
			display()
			samples.append(CACurrentMediaTime() - t)
		}
		report("scroll jump go", samples)
		t = CACurrentMediaTime()
		SyntaxHighlighter(lexer: GoLexer(), lineCount: editor.rope.lineCount).prepare(upTo: editor.rope.lineCount - 1, in: editor.rope)
		report("lex 10 MB go", [CACurrentMediaTime() - t])
		editor.highlighter = nil

		// Soft wrapping at 40 columns, so most lines of the sample wrap: all rows, typing, jumps.
		let unwrapped = editor.format
		var narrow = unwrapped
		narrow.maxLineLength = 40
		editor.format = narrow
		t = CACurrentMediaTime()
		EditorView.wrapsLines = true
		report("wrap 10 MB", [CACurrentMediaTime() - t])
		display()
		samples = []
		for _ in 0..<1000 {
			t = CACurrentMediaTime()
			editor.insertText("x ", replacementRange: NSRange(location: NSNotFound, length: 0))
			display()
			samples.append(CACurrentMediaTime() - t)
		}
		report("type char wrapped", samples)
		samples = []
		for _ in 0..<200 {
			jump = jump &* 6364136223846793005 &+ 1442695040888963407
			let row = Int(jump >> 33) % editor.rowCount
			t = CACurrentMediaTime()
			editor.scroll(NSPoint(x: 0, y: CGFloat(row) * editor.lineHeight))
			display()
			samples.append(CACurrentMediaTime() - t)
		}
		report("scroll jump wrapped", samples)
		EditorView.wrapsLines = false
		editor.format = unwrapped

		// Raw rope throughput, independent of drawing.
		var rope = Rope(text)
		var rng = UInt64(1)
		t = CACurrentMediaTime()
		for _ in 0..<1_000_000 {
			rng = rng &* 6364136223846793005 &+ 1442695040888963407
			let at = Int(rng >> 33) % (rope.byteCount + 1)
			if rng & 1 == 0 || at == rope.byteCount {
				rope.replace(at..<at, with: "a")
			} else {
				rope.replace(at..<(at + 1), with: "")
			}
		}
		report("1M rope edits", [CACurrentMediaTime() - t])

		exit(checkBudgets() ? 0 : 1)
	}

	/// Real key events through the window and run loop: key to Core Animation commit, and
	/// key to the display frame that shows it (display link, quantized to the refresh rate).
	static func keyToFrame(_ editor: EditorView) {
		guard let window = editor.window else { return }
		NSApp.activate()
		window.orderFrontRegardless()
		let shown = Date(timeIntervalSinceNow: 1) // occlusion state follows the window server
		while !window.occlusionState.contains(.visible), Date() < shown {
			if let e = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.01), inMode: .default, dequeue: true) {
				NSApp.sendEvent(e)
			}
		}
		guard window.occlusionState.contains(.visible) else {
			// AppKit skips drawing and display links pause for occluded windows.
			print("key to frame: skipped, window not visible (display off or screen locked)")
			return
		}
		let monitor = LatencyMonitor(view: editor)
		editor.latencyMonitor = monitor
		defer { editor.latencyMonitor = nil }
		var framesShown = true
		for i in 0..<320 {
			let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
			                           windowNumber: window.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x",
			                           isARepeat: false, keyCode: 7)!
			window.sendEvent(key)
			// Run the loop until the edit is committed and, while frames come, shown.
			let deadline = Date(timeIntervalSinceNow: 0.5)
			while monitor.commits.count <= i || (framesShown && monitor.frames.count <= i), Date() < deadline {
				if let e = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.002), inMode: .default, dequeue: true) {
					NSApp.sendEvent(e)
				}
			}
			if monitor.frames.count <= i { framesShown = false }
		}
		report("key to commit", Array(monitor.commits.dropFirst(20))) // first keys warm up
		if framesShown {
			frameInterval = monitor.frameInterval
			print(String(format: "  [display frame %.2f ms]", monitor.frameInterval * 1000))
			report("key to frame", Array(monitor.frames.dropFirst(20)))
		} else {
			print("key to frame: skipped, no display frames (window occluded, display off or screen locked)")
		}
	}

	static var frameInterval: Double?
	static var lastDraws = (0, 0)
	/// Worst sample of each measurement, checked against the plan's budgets at the end.
	/// p99 and worst sample of each measurement, checked against the plan's budgets at the end.
	static var p99: [String: Double] = [:]
	static var worst: [String: Double] = [:]

	/// Budgets from docs/PLAN.md. Local (default): 99 % of frames under 8 ms, none over 16 ms,
	/// open under 300 ms, 1M rope edits under 2 s. MINORIDE_BENCH_PROFILE=ci is for shared
	/// virtual machines without a GPU: one-off stalls of the VM are not the editor's, so only
	/// p99 (8 ms) and rope throughput (4 s) are checked there.
	static func checkBudgets() -> Bool {
		let ci = ProcessInfo.processInfo.environment["MINORIDE_BENCH_PROFILE"] == "ci"
		let frames = ["type char", "type newline", "backspace", "scroll 40px", "scroll jump", "type char go", "type quote go", "scroll jump go", "type char wrapped", "scroll jump wrapped"]
		var checks: [(String, Double?, Double)] = [] // name, measured, limit (seconds)
		for name in frames {
			checks.append((name + " p99", p99[name], 0.008))
			if !ci { checks.append((name + " max", worst[name], 0.016)) }
		}
		checks.append(("1M rope edits", worst["1M rope edits"], ci ? 4.0 : 2.0))
		// Keystroke latency. The app's own work (key to commit) gets the plan's frame budget.
		// On screen, a committed change waits for the next vsync and is composed for one more
		// frame, so key to frame is up to two display frames; more means the editor missed one.
		checks.append(("key to commit p99", p99["key to commit"], 0.008))
		if !ci { checks.append(("key to commit max", worst["key to commit"], 0.016)) }
		if let frame = frameInterval {
			checks.append(("key to frame p99", p99["key to frame"], 2 * frame + 0.001))
		}

		var ok = true
		for (name, value, limit) in checks {
			guard let value else { continue }
			if value > limit {
				print(String(format: "BUDGET FAIL %@: %.2f ms > %.2f ms", name, value * 1000, limit * 1000))
				ok = false
			}
		}
		print(ok ? "BUDGET OK\(ci ? " (ci profile)" : "")" : "BUDGET EXCEEDED")
		return ok
	}

	static func report(_ name: String, _ samples: [Double]) {
		let sorted = samples.sorted()
		worst[name] = sorted.last
		p99[name] = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
		if let e = (NSApp.delegate as? AppDelegate)?.editor {
			let draws = (e.drawCount - lastDraws.0, e.drawnLines - lastDraws.1)
			lastDraws = (e.drawCount, e.drawnLines)
			print("  [\(name): \(draws.0) draws, \(draws.1) lines, \(e.sticky?.drawCount ?? 0) pinned-line draws in total]")
		}
		let s = samples.sorted()
		func ms(_ v: Double) -> String { String(format: "%.2f ms", v * 1000) }
		if s.count == 1 {
			print("\(name.padding(toLength: 18, withPad: " ", startingAt: 0)) \(ms(s[0]))")
			return
		}
		let p = { (q: Double) in s[min(s.count - 1, Int(Double(s.count) * q))] }
		print("\(name.padding(toLength: 18, withPad: " ", startingAt: 0)) p50 \(ms(p(0.5)))  p99 \(ms(p(0.99)))  max \(ms(s.last!))")
	}

	static let snapshotText = """
	// Fast path: ASCII, Czech, tabs
	func main() {
	\tname := "Příliš žluťoučký kůň úpěl ďábelské ódy"
	\tif x := compute(42); x > 0 {
	\t\tfmt.Println(name, x) // ěščřžýáíé ĚŠČŘŽÝÁÍÉ
	\t}
	}
	// Fallback path: emoji and combining marks
	var smile = "😀 café 👍🏽 e\u{301}"
	\tcolumns:\ta\tbb\tccc|
	    columns:    a   bb  ccc|
	"""

	/// Go-like source with Czech strings, tabs and varied line lengths.
	static func sampleText(bytes: Int) -> String {
		var lines: [String] = []
		var size = 0
		var i = 0
		while size < bytes {
			let block = [
				"// Handler\(i) zpracuje požadavek číslo \(i).",
				"func Handler\(i)(ctx context.Context, req *Request) (*Response, error) {",
				"\tif req == nil {",
				"\t\treturn nil, fmt.Errorf(\"prázdný požadavek %d\", \(i))",
				"\t}",
				"\tresult := make([]string, 0, len(req.Items))",
				"\tfor _, item := range req.Items { result = append(result, strings.ToUpper(item.Name)) }",
				"\treturn &Response{Items: result, Message: \"Příliš žluťoučký kůň úpěl ďábelské ódy 😀\"}, nil",
				"}",
				"",
			]
			for l in block {
				lines.append(l)
				size += l.utf8.count + 1
			}
			i += 1
		}
		return lines.joined(separator: "\n")
	}
}
