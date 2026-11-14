import AppKit
import EditorKit

// Usage: MinorIDE [file]        opens a file (phase-0 spike window)
//        MinorIDE --bench       runs the editor spike benchmark and prints results
//        MinorIDE --snapshot <png> [file]   renders the editor to a PNG (visual check)
//        MINORIDE_FONT_SIZE=40 enlarges the font, useful with --snapshot

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	var window: NSWindow!
	var editor: EditorView!

	func applicationDidFinishLaunching(_ notification: Notification) {
		buildMenu()
		let args = CommandLine.arguments.dropFirst()
		if args.first == "--bench" {
			Bench.run(self)
			return
		}
		if args.first == "--snapshot", args.count >= 2 {
			let file = args.dropFirst(2).first.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
			openWindow(text: file ?? Bench.snapshotText, title: "snapshot")
			snapshot(to: args[args.startIndex + 1])
			NSApp.terminate(nil)
			return
		}
		let text = args.first.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
			?? "// MinorIDE\nfunc main() {\n\tprintln(\"Příliš žluťoučký kůň\")\n}\n"
		openWindow(text: text, title: args.first.map { ($0 as NSString).lastPathComponent } ?? "MinorIDE")
		NSApp.activate()
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

	func openWindow(text: String, title: String) {
		window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
		                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
		window.title = title
		let scroll = NSScrollView(frame: window.contentView!.bounds)
		scroll.autoresizingMask = [.width, .height]
		scroll.hasVerticalScroller = true
		let size = ProcessInfo.processInfo.environment["MINORIDE_FONT_SIZE"].flatMap(Double.init) ?? 13
		editor = EditorView(text: text, font: .monospacedSystemFont(ofSize: size, weight: .regular))
		editor.autoresizingMask = [.width]
		scroll.documentView = editor
		window.contentView = scroll
		editor.updateSize()
		window.center()
		window.makeKeyAndOrderFront(nil)
		window.makeFirstResponder(editor)
	}

	func snapshot(to path: String) {
		editor.displayIfNeeded()
		let rect = editor.visibleRect
		guard let rep = editor.bitmapImageRepForCachingDisplay(in: rect) else { return }
		editor.cacheDisplay(in: rect, to: rep)
		try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
	}

	private func buildMenu() {
		let main = NSMenu()
		let appItem = NSMenuItem()
		main.addItem(appItem)
		let appMenu = NSMenu()
		appMenu.addItem(withTitle: "Quit MinorIDE", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
		appItem.submenu = appMenu
		NSApp.mainMenu = main
	}
}
