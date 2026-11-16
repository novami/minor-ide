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

	private var server: LanguageServer?
	private struct Opened {
		weak var doc: FileDocument?
		let uri: String
	}
	private var opened: [ObjectIdentifier: Opened] = [:]
	private var observers: [NSObjectProtocol] = []
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
			guard let url = doc.url, project.contains(url), !doc.text.views.isEmpty else { return false }
			return Gopls.languageID(forPath: url.path) != nil
		}
		for (id, entry) in opened {
			if let doc = entry.doc, wanted.contains(where: { $0 === doc }), doc.url.map(Self.uri) == entry.uri { continue }
			server?.close(uri: entry.uri)
			entry.doc?.text.onTextEdit = nil
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
			text.onTextEdit = { [weak server] changes, rope, version in
				server?.change(uri: uri, version: version, changes: changes, text: rope)
			}
			opened[ObjectIdentifier(doc)] = Opened(doc: doc, uri: uri)
		}
	}

	static func uri(_ url: URL) -> String { url.standardizedFileURL.absoluteString }

	/// A request to the server about an open file (features of 3.4–3.7 build on this).
	func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
		guard let server else { throw LSPError.notRunning }
		return try await server.request(method, params)
	}

	/// Snapshot check: waits for gopls to settle, edits `editor` in memory and asks for its
	/// symbols; prints the state, the symbols and the end of the log.
	func checkForSnapshot(_ editor: EditorView, url: URL) {
		let deadline = Date().addingTimeInterval(30)
		func wait(_ done: () -> Bool) {
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
		for entry in opened.values { entry.doc?.text.onTextEdit = nil }
		opened = [:]
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
