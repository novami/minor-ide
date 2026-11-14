import AppKit
import EditorKit
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
		editor.displayIfNeeded()
		report("open + first draw", [CACurrentMediaTime() - t])
		print("lines:      \(editor.rope.lineCount)")

		// Typing in the middle of the document.
		let mid = editor.rope.lineRange(editor.rope.lineCount / 2).upperBound
		editor.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
		editor.replace(mid..<mid, with: "")
		var samples: [Double] = []
		var model = 0.0
		let drawBefore = editor.drawSeconds
		for _ in 0..<2000 {
			t = CACurrentMediaTime()
			editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
			model += CACurrentMediaTime() - t
			editor.displayIfNeeded()
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
			editor.displayIfNeeded()
			samples.append(CACurrentMediaTime() - t)
		}
		report("type newline", samples)

		samples = []
		for _ in 0..<500 {
			t = CACurrentMediaTime()
			editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
			editor.displayIfNeeded()
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
			editor.displayIfNeeded()
			samples.append(CACurrentMediaTime() - t)
		}
		report("scroll 40px", samples)

		samples = []
		for i in 0..<200 {
			t = CACurrentMediaTime()
			let target = (i * 7919 + 13) % max(1, Int(editor.frame.height) - 2000) // distinct positions, no tile cache hits
			clip.scroll(to: NSPoint(x: 0, y: CGFloat(target)))
			editor.enclosingScrollView!.reflectScrolledClipView(clip)
			editor.displayIfNeeded()
			samples.append(CACurrentMediaTime() - t)
		}
		report("scroll jump", samples)

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

		NSApp.terminate(nil)
	}

	static var lastDraws = (0, 0)

	static func report(_ name: String, _ samples: [Double]) {
		if let e = (NSApp.delegate as? AppDelegate)?.editor {
			let draws = (e.drawCount - lastDraws.0, e.drawnLines - lastDraws.1)
			lastDraws = (e.drawCount, e.drawnLines)
			print("  [\(name): \(draws.0) draws, \(draws.1) lines]")
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
