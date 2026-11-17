import AppKit
import EditorKit
import LSPKit
import MinorCore
import TextEngine

/// The language servers of one project (plan 3.1, 3.3). gopls starts when the first Go file of
/// a trusted project is shown in an editor and runs until the project closes or is restricted.
/// Shown files are opened in the server, edits and saves follow them, FSEvents become watched
/// file changes. Status and progress go to the status bars, the log to the Language Servers panel.
@MainActor
final class LanguageServices {
	enum Status: Equatable {
		/// No server needed yet (no Go file shown, or Restricted Mode).
		case idle
		case locating
		/// gopls was not found; `goInstalled` says whether it can be installed with `go install`.
		case missing(goInstalled: Bool)
		case installing
		case server(ServerState)
	}

	private weak var project: Project?
	private(set) var status: Status = .idle
	private(set) var progress = ProgressTracker()
	/// Log lines, oldest first, at most `logLimit`.
	private(set) var log: [String] = []
	static let logLimit = 5000
	/// Called when the status or progress changes (status bars, panel).
	var onUpdate: [() -> Void] = []
	/// Called with every new log line (the panel appends it).
	var onLog: ((String) -> Void)?
	/// Diagnostics by URI as the server published them (files with none are left out).
	private(set) var problems: [String: PublishedDiagnostics] = [:]
	/// Called when diagnostics arrive or are cleared (Problems panel).
	var onProblems: [() -> Void] = []
	/// Edits of open documents by the version they made: diagnostics of an older version are
	/// moved through them to the current text.
	private var edits: [String: [(version: Int, changes: ChangeSet)]] = [:]
	static let keptEdits = 64

	private var server: LanguageServer?
	private struct Opened {
		weak var doc: FileDocument?
		let uri: String
	}
	private var opened: [ObjectIdentifier: Opened] = [:]
	private var observers: [NSObjectProtocol] = []
	/// Files outside the project opened from it (a jump into the standard library): the
	/// server takes them too.
	private var adopted: Set<String> = []
	private var closed = false
	private let time: DateFormatter = {
		let f = DateFormatter()
		f.dateFormat = "HH:mm:ss"
		return f
	}()

	init(project: Project) {
		self.project = project
		let center = NotificationCenter.default
		// URL changes (Save As, rename) reopen the file under its new address.
		observers.append(center.addObserver(forName: FileDocument.stateDidChange, object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.scheduleSync() }
		})
		observers.append(center.addObserver(forName: FileDocument.didSave, object: nil, queue: .main) { [weak self] note in
			guard let object = note.object else { return }
			let id = ObjectIdentifier(object as AnyObject)
			MainActor.assumeIsolated {
				guard let self else { return }
				self.sync()
				if let entry = self.opened[id] { self.server?.save(uri: entry.uri) }
			}
		})
	}

	// MARK: Documents

	private var syncPending = false

	/// Syncs once after the current event (windows and panes finish closing first).
	func scheduleSync() {
		guard !syncPending else { return }
		syncPending = true
		DispatchQueue.main.async { [weak self] in
			MainActor.assumeIsolated {
				self?.syncPending = false
				self?.sync()
			}
		}
	}

	/// Opens shown project files the server handles and closes the rest; starts gopls when
	/// the first such file shows, stops it in Restricted Mode.
	func sync() {
		guard let project, !closed else { return }
		guard project.isTrusted else { return shutDown(log: "restricted mode") }
		let wanted = FileDocument.all.filter { doc in
			guard let url = doc.url, project.contains(url) || adopted.contains(url.standardizedFileURL.path),
			      !doc.text.views.isEmpty else { return false }
			return Gopls.languageID(forPath: url.path) != nil
		}
		for (id, entry) in opened {
			if let doc = entry.doc, wanted.contains(where: { $0 === doc }), doc.url.map(Self.uri) == entry.uri { continue }
			server?.close(uri: entry.uri)
			entry.doc?.text.onTextEdit = nil
			entry.doc?.text.setDiagnostics([])
			entry.doc?.text.showsDiagnostics = false
			edits[entry.uri] = nil
			opened[id] = nil
		}
		guard let server else {
			if !wanted.isEmpty { locate() }
			return
		}
		for doc in wanted where opened[ObjectIdentifier(doc)] == nil {
			guard let url = doc.url, let languageID = Gopls.languageID(forPath: url.path) else { continue }
			let uri = Self.uri(url)
			let text = doc.text
			server.open(uri: uri, languageID: languageID, version: text.version, text: text.rope)
			text.onTextEdit = { [weak server, weak self] changes, rope, version in
				server?.change(uri: uri, version: version, changes: changes, text: rope)
				self?.edits[uri, default: []].append((version, changes))
				if let n = self?.edits[uri]?.count, n > Self.keptEdits { self?.edits[uri]?.removeFirst(n - Self.keptEdits) }
			}
			opened[ObjectIdentifier(doc)] = Opened(doc: doc, uri: uri)
			text.showsDiagnostics = true
			// Problems the server found before the file was opened (positions in the text on disk).
			if let report = problems[uri] {
				let encoding = server.positionEncoding
				text.setDiagnostics(zip(report.diagnostics, report.diagnostics.map { text.rope.range(of: $0.range, encoding: encoding) }).map(Self.diagnostic))
			}
		}
	}

	/// How the server counts characters (positions of files that are not open).
	var positionEncoding: PositionEncoding { server?.positionEncoding ?? .utf16 }

	/// Whether the server has `doc` open (its diagnostics are in its text).
	func isTracking(_ doc: FileDocument) -> Bool { opened[ObjectIdentifier(doc)]?.doc === doc }

	// MARK: Diagnostics

	private func received(_ report: PublishedDiagnostics) {
		problems[report.uri] = report.diagnostics.isEmpty ? nil : report
		if let entry = opened.values.first(where: { $0.uri == report.uri }), let doc = entry.doc {
			// Too old to move to the current text: the server publishes again for the newer one.
			if let ranges = report.ranges, let version = report.version, let current = moved(ranges, uri: report.uri, from: version, to: doc.text.version) {
				doc.text.setDiagnostics(zip(report.diagnostics, current).map(Self.diagnostic))
			}
		}
		for handler in onProblems { handler() }
	}

	/// Byte ranges of `version` in the text of `current`, through the edits in between.
	private func moved(_ ranges: [Range<Int>], uri: String, from version: Int, to current: Int) -> [Range<Int>]? {
		guard version != current else { return ranges }
		let log = edits[uri] ?? []
		guard version < current, let first = log.firstIndex(where: { $0.version == version + 1 }), log.last?.version == current else { return nil }
		return ranges.map { r in
			var lo = r.lowerBound, hi = r.upperBound
			for (_, changes) in log[first...] {
				lo = changes.map(lo, bias: .after)
				hi = max(lo, changes.map(hi, bias: .before))
			}
			return lo..<hi
		}
	}

	static func diagnostic(_ d: Diagnostic, _ range: Range<Int>) -> EditorDiagnostic {
		let related = d.related.compactMap { r -> EditorDiagnostic.Related? in
			guard let url = URL(string: r.location.uri), url.isFileURL else { return nil }
			return EditorDiagnostic.Related(url: url, line: r.location.range.start.line, character: r.location.range.start.character, message: r.message)
		}
		let link = d.href.flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? $0 : nil }
		return EditorDiagnostic(range: range, severity: EditorDiagnostic.Severity(rawValue: d.severity.rawValue) ?? .error,
		                        message: d.message, source: d.source, code: d.code, link: link, related: related, unnecessary: d.unnecessary)
	}

	private func clearProblems() {
		guard !problems.isEmpty || opened.values.contains(where: { $0.doc?.text.hasDiagnostics == true }) else { return }
		problems = [:]
		for entry in opened.values { entry.doc?.text.setDiagnostics([]) }
		for handler in onProblems { handler() }
	}

	func adopt(_ url: URL) { adopted.insert(url.standardizedFileURL.path) }

	static func uri(_ url: URL) -> String { url.standardizedFileURL.absoluteString }

	/// The running server that has `doc` open, with its URI there.
	func endpoint(for doc: FileDocument) -> (server: LanguageServer, uri: String)? {
		guard let server, let entry = opened[ObjectIdentifier(doc)], entry.doc === doc else { return nil }
		return (server, entry.uri)
	}

	/// A request to the server about an open file (features of 3.4–3.7 build on this).
	func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
		guard let server else { throw LSPError.notRunning }
		return try await server.request(method, params)
	}

	/// Snapshot check: waits for gopls to settle, edits `editor` in memory and asks for its
	/// symbols; prints the state, the symbols and the end of the log.
	func checkForSnapshot(_ editor: EditorView, url: URL, pane: EditorPane, usages: UsagesPanel) {
		let completion = pane.completion, navigation = pane.navigation
		func wait(_ done: () -> Bool) {
			let deadline = Date().addingTimeInterval(15)
			while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
		}
		wait { status == .server(.running) && !progress.isActive }
		print("language server:", status, progress.text ?? "")
		editor.replace([(editor.rope.byteCount..<editor.rope.byteCount, "\nfunc minorideCheck() {}\n")])
		var names: [String] = []
		let uri = Self.uri(url)
		wait {
			Task { names = ((try? await request("textDocument/documentSymbol", ["textDocument": ["uri": .string(uri)]]))?.arrayValue ?? []).compactMap { $0["name"]?.stringValue } }
			RunLoop.main.run(until: Date().addingTimeInterval(0.3))
			return names.contains("minorideCheck")
		}
		print("symbols:", names.suffix(5))
		editor.undo(nil)
		// Completion through the popup: an unimported package, accepted with Return.
		let end = editor.rope.byteCount
		editor.replace([(end..<end, "\nfunc minorideComplete() {\n\t_ = strings.ToUpp\n}\n")])
		editor.setSelections(SelectionSet(caret: editor.rope.byteCount - 3))
		editor.showCompletions(nil)
		wait { completion?.isShowing == true }
		_ = editor.commandInterceptor?(#selector(NSResponder.insertNewline(_:)))
		let text = editor.rope.string
		print("completion:", completion?.isShowing == false, text.split(separator: "\n").suffix(3).joined(separator: " | "),
		      "import added:", text.contains("\"strings\""))
		editor.undo(nil)
		editor.undo(nil)
		// Typing starts it: a word, then a trigger character.
		let e2 = editor.rope.byteCount
		editor.replace([(e2..<e2, "\nfunc minorideTyped() {\n\t\n}\n")])
		editor.setSelections(SelectionSet(caret: editor.rope.byteCount - 3))
		for c in "strin" { editor.insertText(String(c), replacementRange: NSRange(location: NSNotFound, length: 0)) }
		wait { completion?.isShowing == true }
		let word = completion?.isShowing == true
		for c in "gs." { editor.insertText(String(c), replacementRange: NSRange(location: NSNotFound, length: 0)) }
		wait { completion?.isShowing == true }
		print("typed: word", word, "dot", completion?.isShowing == true)
		_ = editor.commandInterceptor?(#selector(NSResponder.cancelOperation(_:)))
		for _ in 0..<4 { editor.undo(nil) }
		// Not in a comment, also at its end.
		let e3 = editor.rope.byteCount
		editor.replace([(e3..<e3, "\n// ")])
		for c in "strin" { editor.insertText(String(c), replacementRange: NSRange(location: NSNotFound, length: 0)) }
		RunLoop.main.run(until: Date().addingTimeInterval(1))
		print("in comment:", completion?.isShowing == true)
		for _ in 0..<3 { editor.undo(nil) }
		// Jumps: the call to its declaration, the declaration (⌘+click) to its only usage, usages to the panel.
		let e4 = editor.rope.byteCount
		editor.replace([(e4..<e4, "\nfunc minorideTarget() {}\n\nfunc minorideNav() { minorideTarget() }\n")])
		let declaration = e4 + "\nfunc ".utf8.count
		let call = e4 + "\nfunc minorideTarget() {}\n\nfunc minorideNav() { ".utf8.count
		editor.setSelections(SelectionSet(caret: call + 3))
		navigation?.jump(.definition)
		wait { editor.caret == declaration }
		print("definition:", editor.caret == declaration)
		let window = editor.window?.delegate as? DocumentWindow
		window?.navigateBack(nil)
		let back = editor.caret == call + 3
		window?.navigateForward(nil)
		print("back:", back, "forward:", editor.caret == declaration)
		_ = editor.onNavigate?(declaration + 2)
		wait { editor.caret == call }
		print("declaration click → usage:", editor.caret == call)
		navigation?.findUsages()
		RunLoop.main.run(until: Date().addingTimeInterval(0.1))
		wait { !usages.isSearching }
		print("usages:", usages.statusText, usages.rowsForSnapshot)
		// The list follows edits of the file.
		editor.replace([(0..<0, "\n")])
		print("usages after edit:", usages.rowsForSnapshot.dropFirst().map { $0.prefix(9) })
		editor.undo(nil)
		editor.undo(nil)
		// Into the standard library: a tab of this project, and gopls has the file.
		let e5 = editor.rope.byteCount
		editor.replace([(e5..<e5, "\nfunc minorideStd() { fmt.Println() }\n")])
		editor.setSelections(SelectionSet(caret: editor.rope.byteCount - "Println() }\n".utf8.count + 2))
		navigation?.jump(.definition)
		var std: FileDocument?
		wait {
			std = FileDocument.all.first { $0.url?.lastPathComponent == "print.go" }
			return std.map { endpoint(for: $0) != nil } ?? false
		}
		print("standard library:", std?.url?.path ?? "not opened", "served:", std.map { endpoint(for: $0) != nil } ?? false)
		let stdWindow = std?.text.views.first?.window?.delegate as? DocumentWindow
		let before = editor.caret
		editor.setSelections(SelectionSet(caret: 0))
		stdWindow?.navigateBack(nil)
		print("back from the standard library:", stdWindow != nil && editor.caret == before,
		      "tab in front:", editor.window.map { $0.tabGroup?.selectedWindow === $0 } ?? false)
		editor.undo(nil)
		// Documentation under the resting mouse, then parameter info while typing a call.
		let e6 = editor.rope.byteCount
		editor.replace([(e6..<e6, "\n// minorideDoc says *hi*.\nfunc minorideDoc(a int, b string) {}\n\nfunc minorideCall() { minorideDoc }\n")])
		let callEnd = editor.rope.byteCount - " }\n".utf8.count
		let symbol = editor.rope.wordRange(at: callEnd - 2)
		RunLoop.main.run(until: Date().addingTimeInterval(0.1))
		editor.mouseWord = symbol
		editor.onMouseWord?(symbol)
		wait { pane.hover?.isShowing == true }
		print("hover:", pane.hover?.debugText?.replacingOccurrences(of: "\n", with: " | ") ?? "none")
		editor.setSelections(SelectionSet(caret: callEnd))
		print("hover closes on caret move:", pane.hover?.isShowing == false)
		for c in "(1, " { editor.insertText(String(c), replacementRange: NSRange(location: NSNotFound, length: 0)) }
		wait { pane.signatureHelp?.debugText?.hasSuffix("b string") == true }
		print("parameter info:", pane.signatureHelp?.debugText ?? "none")
		_ = editor.commandInterceptor?(#selector(NSResponder.cancelOperation(_:)))
		print("parameter info closes on Esc:", pane.signatureHelp?.isShowing == false)
		for _ in 0..<5 { editor.undo(nil) }
		print("text restored:", editor.rope.byteCount == e6)
		// Diagnostics: an undefined call, an edit above it while gopls works, F2, the Problems panel.
		let e7 = editor.rope.byteCount
		editor.replace([(e7..<e7, "\nfunc minorideBad() { minorideMissing() }\n")])
		let doc = editor.document
		if let scroll = editor.enclosingScrollView, let strip = editor.diagnosticStrip {
			let f = { (r: NSRect) in "x \(Int(r.minX))–\(Int(r.maxX))" }
			print("strip:", strip.isHidden ? "hidden" : f(strip.frame), "scroller:", scroll.verticalScroller.map { f($0.frame) } ?? "none",
			      "clip:", f(scroll.contentView.frame), "insets:", scroll.contentView.contentInsets.left, scroll.contentView.contentInsets.right,
			      "editor width:", Int(editor.frame.width), "scroll width:", Int(scroll.frame.width))
		}
		wait { doc.diagnostics.contains { $0.message.contains("minorideMissing") } }
		editor.replace([(0..<0, "\n")])
		let bad = doc.diagnostics.first { $0.message.contains("minorideMissing") }
		print("diagnostic:", bad.map { "\($0.severity) \($0.message) at “\(editor.rope.string(in: $0.range))”" } ?? "none")
		RunLoop.main.run(until: Date().addingTimeInterval(1))
		print("after edit:", doc.diagnostics.first { $0.message.contains("minorideMissing") }.map { editor.rope.string(in: $0.range) } ?? "none")
		editor.setSelections(SelectionSet(caret: e7))
		(editor.window?.delegate as? DocumentWindow)?.nextProblem(nil)
		print("F2:", editor.rope.string(in: editor.caret..<min(editor.caret + 15, editor.rope.byteCount)), "popup:",
		      pane.hover?.debugText ?? "none")
		if let problems = project?.problems {
			RunLoop.main.run(until: Date().addingTimeInterval(0.3))
			print("problems:", problems.statusText, problems.rowsForSnapshot.filter { $0.contains("minoride") })
		}
		editor.undo(nil)
		editor.undo(nil)
		wait { !doc.diagnostics.contains { $0.message.contains("minorideMissing") } }
		print("diagnostic gone after undo:", !doc.diagnostics.contains { $0.message.contains("minorideMissing") }, "text restored:", editor.rope.byteCount == e7)
		for line in log.suffix(8) { print("  ", line) }
	}

	/// FSEvents paths of the project: the server learns about files changed outside the editor
	/// (`git checkout`, go.mod) when it asked for them.
	func filesChanged(_ paths: [String]) {
		guard let server, server.wantsFileEvents else { return }
		let events = paths.filter { !$0.contains("/.git/") }.map { path -> (URL, FileChangeType) in
			(URL(fileURLWithPath: path), FileManager.default.fileExists(atPath: path) ? .changed : .deleted)
		}
		if !events.isEmpty { server.filesChanged(events) }
	}

	// MARK: Server

	private func locate() {
		switch status {
		case .locating, .installing, .missing: return
		default: break
		}
		setStatus(.locating)
		Task {
			let (env, environment) = await ToolsModel.shared.processEnvironment()
			let found = await Task.detached(priority: .userInitiated) {
				(Gopls.locate(which: env.which, environment: environment, home: NSHomeDirectory()), env.which("go") != nil)
			}.value
			guard let project, project.isTrusted, !closed, server == nil else {
				if status == .locating { setStatus(.idle) }
				return
			}
			guard let path = found.0 else {
				append("gopls not found in PATH, $GOBIN, $GOPATH/bin or ~/go/bin")
				setStatus(.missing(goInstalled: found.1))
				return
			}
			launch(path, environment: environment, root: project.url)
			sync()
		}
	}

	/// Events of a stopped server arrive late; only the current generation's count.
	private var generation = 0

	private func launch(_ path: String, environment: [String: String], root: URL) {
		generation += 1
		let gen = generation
		var handlers = LanguageServerHandlers()
		handlers.log = { [weak self] line in Self.main { self?.append(line) } }
		handlers.state = { [weak self] state in
			Self.main {
				guard let self, gen == self.generation, self.server != nil else { return }
				if state != .running { self.progress.reset() }
				if case .failed = state { self.clearProblems() }
				self.setStatus(.server(state))
			}
		}
		handlers.progress = { [weak self] event in
			Self.main {
				guard let self, gen == self.generation, self.server != nil else { return }
				self.progress.apply(event)
				self.notify()
			}
		}
		handlers.diagnostics = { [weak self] report in
			Self.main {
				guard let self, gen == self.generation, self.server != nil else { return }
				self.received(report)
			}
		}
		handlers.notification = { [weak self] method, params in
			guard method == "window/logMessage" || method == "window/showMessage",
			      let message = params["message"]?.stringValue else { return }
			Self.main { self?.append(message) }
		}
		append("starting \(path)")
		let server = LanguageServer(command: ServerCommand(executable: URL(fileURLWithPath: path), environment: environment, directory: root),
		                            root: root, initializationOptions: Gopls.initializationOptions, settings: Gopls.settings,
		                            handlers: handlers)
		self.server = server
		server.start()
	}

	/// Starts again after crashes or a failed start; looks for gopls again when it was missing.
	func restart() {
		if let server {
			append("restart requested")
			server.restart()
		} else {
			if case .missing = status { setStatus(.idle) }
			sync()
		}
	}

	/// Runs `go install golang.org/x/tools/gopls@latest` in the home folder (the user agreed),
	/// then starts gopls.
	func installGopls() {
		guard case .missing(true) = status else { return }
		setStatus(.installing)
		Task {
			let (env, environment) = await ToolsModel.shared.processEnvironment()
			guard let go = env.which("go") else {
				setStatus(.missing(goInstalled: false))
				return
			}
			append("go " + Gopls.installArguments.joined(separator: " "))
			let ok = await Self.run(go, Gopls.installArguments, environment: environment) { [weak self] line in
				Self.main { self?.append(line) }
			}
			guard !closed else { return }
			append(ok ? "gopls installed" : "go install failed")
			ToolsModel.shared.refresh()
			setStatus(ok ? .idle : .missing(goInstalled: true))
			if ok { sync() }
		}
	}

	private func shutDown(log reason: String) {
		clearProblems()
		for entry in opened.values {
			entry.doc?.text.onTextEdit = nil
			entry.doc?.text.showsDiagnostics = false
		}
		opened = [:]
		edits = [:]
		progress.reset()
		if let server {
			self.server = nil
			append("stopping (\(reason))")
			Task { await server.stop() }
		}
		setStatus(.idle)
	}

	/// The project closes: the server shuts down.
	func close() {
		shutDown(log: "project closed")
		closed = true
		for observer in observers { NotificationCenter.default.removeObserver(observer) }
		observers = []
	}

	// MARK: Status and log

	private func setStatus(_ new: Status) {
		guard new != status else { return }
		status = new
		notify()
	}

	private func notify() {
		for handler in onUpdate { handler() }
	}

	private func append(_ line: String) {
		let entry = time.string(from: Date()) + "  " + line
		log.append(entry)
		if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
		onLog?(entry)
	}

	private nonisolated static func main(_ work: @escaping @MainActor @Sendable () -> Void) {
		DispatchQueue.main.async { MainActor.assumeIsolated(work) }
	}

	/// Runs a tool with an argument array in the home folder; output lines go to `line`.
	private static func run(_ path: String, _ arguments: [String], environment: [String: String],
	                        line: @escaping @Sendable (String) -> Void) async -> Bool {
		await withCheckedContinuation { continuation in
			let process = Process()
			process.executableURL = URL(fileURLWithPath: path)
			process.arguments = arguments
			process.environment = environment
			process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
			process.standardInput = FileHandle.nullDevice
			let pipe = Pipe()
			process.standardOutput = pipe
			process.standardError = pipe
			pipe.fileHandleForReading.readabilityHandler = { handle in
				let data = handle.availableData
				guard !data.isEmpty else {
					handle.readabilityHandler = nil
					return
				}
				for text in String(decoding: data, as: UTF8.self).split(separator: "\n") { line(String(text)) }
			}
			process.terminationHandler = { p in continuation.resume(returning: p.terminationStatus == 0) }
			do {
				try process.run()
			} catch {
				line("\(error)")
				continuation.resume(returning: false)
			}
		}
	}
}
