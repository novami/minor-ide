import Foundation
import MinorCore
import TextEngine

public struct ServerCommand: Sendable {
	public var executable: URL
	public var arguments: [String]
	public var environment: [String: String]?
	public var directory: URL?

	public init(executable: URL, arguments: [String] = [], environment: [String: String]? = nil, directory: URL? = nil) {
		self.executable = executable
		self.arguments = arguments
		self.environment = environment
		self.directory = directory
	}
}

public enum ServerState: Sendable, Equatable {
	case starting
	case running
	case restarting(attempt: Int)
	case stopped
	case failed(String)
}

public struct ProgressEvent: Sendable, Equatable {
	public enum Kind: String, Sendable { case begin, report, end }
	public var token: String
	public var kind: Kind
	public var title: String?
	public var message: String?
	public var percentage: Int?
}

public enum FileChangeType: Int, Sendable {
	case created = 1, changed = 2, deleted = 3
}

public struct CompletionSupport: Sendable, Equatable {
	/// Single-byte trigger characters (".", ">", …).
	public var triggerCharacters: Set<UInt8>
	public var resolves: Bool
	public var encoding: PositionEncoding
}

public enum LSPError: Error, Sendable {
	case notRunning
}

/// What the app does for the server. Closures run on background threads.
public struct LanguageServerHandlers: Sendable {
	public var log: @Sendable (String) -> Void = { _ in }
	public var state: @Sendable (ServerState) -> Void = { _ in }
	public var progress: @Sendable (ProgressEvent) -> Void = { _ in }
	/// `textDocument/publishDiagnostics`, with byte ranges for open documents.
	public var diagnostics: @Sendable (PublishedDiagnostics) -> Void = { _ in }
	/// Notifications not handled here (showMessage…).
	public var notification: @Sendable (String, JSONValue) -> Void = { _, _ in }
	/// `workspace/applyEdit`: the WorkspaceEdit; returns whether it was applied.
	public var applyEdit: @Sendable (JSONValue) async -> Bool = { _ in false }
	/// `window/showMessageRequest`: type, message, action titles; returns the chosen title.
	public var showMessageRequest: @Sendable (Int, String, [String]) async -> String? = { _, _, _ in nil }
	/// `window/showDocument`: a file (with the line to show) or a web page; returns whether it was shown.
	public var showDocument: @Sendable (URL, _ line: Int?) async -> Bool = { _, _ in false }

	public init() {}
}

/// One language server for one workspace: start, initialize, document sync, requests both ways,
/// watched files, progress and restart after a crash (at most `maxRestarts` per `restartWindow`).
public final class LanguageServer: @unchecked Sendable {
	public typealias Connect = @Sendable (_ stderr: @escaping @Sendable (Data) -> Void) throws -> JSONRPCClient

	public static let maxRestarts = 3
	public static let restartWindow: TimeInterval = 60

	private struct Doc {
		var languageID: String
		var version: Int
		var text: Rope
		/// Recent earlier texts by version: diagnostics may come for a version already edited.
		var earlier: [(version: Int, text: Rope)] = []

		func text(of v: Int) -> Rope? { v == version ? text : earlier.last { $0.version == v }?.text }
	}

	static let keptVersions = 32

	private struct Watcher {
		var glob: LSPGlob
		var base: String?
		var kind: Int

		func matches(_ path: String, _ type: FileChangeType) -> Bool {
			guard kind & (1 << (type.rawValue - 1)) != 0 else { return false }
			guard let base else { return glob.matches(path) }
			guard path.hasPrefix(base + "/") else { return false }
			return glob.matches(String(path.dropFirst(base.count + 1)))
		}
	}

	private let connect: Connect
	private let root: URL
	private let initializationOptions: JSONValue
	private let settings: JSONValue
	private let handlers: LanguageServerHandlers
	private let now: @Sendable () -> Date
	private let queue = DispatchQueue(label: "MinorIDE.LanguageServer")

	// Confined to `queue`.
	private var rpc: JSONRPCClient?
	private var generation = 0
	private var ready = false
	private var stopping = false
	private var docs: [String: Doc] = [:]
	private var restarts: [Date] = []
	private var watcherRegistrations: [String: [Watcher]] = [:]
	private var activeProgress: Set<String> = []
	private var caps: JSONValue = .null
	private var encoding: PositionEncoding = .utf16
	private var completion: CompletionSupport?
	private var syncKind = 2
	private var saveIncludesText = false
	private var stderrTail = Data()

	public init(root: URL, initializationOptions: JSONValue = .null, settings: JSONValue = [:],
	            handlers: LanguageServerHandlers = LanguageServerHandlers(),
	            now: @escaping @Sendable () -> Date = Date.init, connect: @escaping Connect) {
		self.root = root
		self.initializationOptions = initializationOptions
		self.settings = settings
		self.handlers = handlers
		self.now = now
		self.connect = connect
	}

	public convenience init(command: ServerCommand, root: URL, initializationOptions: JSONValue = .null,
	                        settings: JSONValue = [:], handlers: LanguageServerHandlers = LanguageServerHandlers()) {
		self.init(root: root, initializationOptions: initializationOptions, settings: settings, handlers: handlers) { stderr in
			try JSONRPCClient(executable: command.executable, arguments: command.arguments,
			                  environment: command.environment, directory: command.directory, stderr: stderr)
		}
	}

	deinit { rpc?.terminate() }

	// MARK: Lifecycle

	public func start() {
		queue.async { [self] in
			guard rpc == nil else { return }
			stopping = false
			launch()
		}
	}

	/// Starts again after `failed` (the user asked), with a fresh restart budget.
	public func restart() {
		queue.async { [self] in
			restarts = []
			stopping = false
			if let rpc { rpc.terminate() } else { launch() }
		}
	}

	/// `shutdown` + `exit`; kills the process when it does not answer within `timeout`.
	public func stop(timeout: TimeInterval = 2) async {
		let client: JSONRPCClient? = queue.sync {
			stopping = true
			ready = false
			return rpc
		}
		guard let client else {
			handlers.state(.stopped)
			return
		}
		let answered = await withTaskGroup(of: Bool.self) { group in
			group.addTask { (try? await client.request("shutdown")) != nil }
			group.addTask {
				try? await Task.sleep(for: .seconds(timeout))
				return false
			}
			let first = await group.next() ?? false
			group.cancelAll()
			return first
		}
		if answered { try? client.notify("exit") }
		try? await Task.sleep(for: .milliseconds(answered ? 300 : 0))
		client.terminate()
	}

	public var capabilities: JSONValue { queue.sync { caps } }
	public var positionEncoding: PositionEncoding { queue.sync { encoding } }
	public var isRunning: Bool { queue.sync { ready } }
	/// What the running server offers for completion; nil when it is not running or has no completion.
	public var completionSupport: CompletionSupport? { queue.sync { ready ? completion : nil } }
	public var processIdentifier: Int32? { queue.sync { rpc?.processIdentifier } }

	private func launch() {
		generation += 1
		let gen = generation
		ready = false
		handlers.state(restarts.isEmpty ? .starting : .restarting(attempt: restarts.count))
		let client: JSONRPCClient
		do {
			client = try connect { [weak self] data in
				guard let self else { return }
				queue.async { self.stderr(data) }
			}
		} catch {
			handlers.log("cannot start: \(error)")
			handlers.state(.failed("\(error)"))
			return
		}
		client.cancelMethod = "$/cancelRequest"
		client.onNotification = { [weak self] method, params in self?.handleNotification(method, params) }
		client.onRequest = { [weak self] method, params in
			guard let self else { throw RPCError.processExited }
			return try await self.handleRequest(method, params)
		}
		client.onExit = { [weak self] in
			guard let self else { return }
			queue.async { self.exited(gen) }
		}
		rpc = client
		Task { await initialize(client, gen) }
	}

	private func initialize(_ client: JSONRPCClient, _ gen: Int) async {
		let rootURI = root.absoluteString
		let params: JSONValue = [
			"processId": .number(Double(ProcessInfo.processInfo.processIdentifier)),
			"clientInfo": ["name": "MinorIDE"],
			"rootUri": .string(rootURI),
			"workspaceFolders": [["uri": .string(rootURI), "name": .string(root.lastPathComponent)]],
			"initializationOptions": initializationOptions,
			"capabilities": Self.clientCapabilities,
		]
		do {
			let result = try await client.request("initialize", params)
			try client.notify("initialized", [:])
			queue.async { self.didInitialize(result, gen) }
		} catch {
			queue.async {
				guard gen == self.generation else { return }
				self.handlers.log("initialize failed: \(error)")
				client.terminate()
			}
		}
	}

	private func didInitialize(_ result: JSONValue, _ gen: Int) {
		guard gen == generation, let client = rpc else { return }
		caps = result["capabilities"] ?? .null
		encoding = caps["positionEncoding"]?.stringValue == PositionEncoding.utf8.rawValue ? .utf8 : .utf16
		switch caps["textDocumentSync"] {
		case .number(let n):
			syncKind = Int(n)
			saveIncludesText = false
		case .object(let o):
			syncKind = o["change"]?.doubleValue.map { Int($0) } ?? 0
			saveIncludesText = o["save"]?["includeText"] == .bool(true)
		default:
			syncKind = 0
		}
		completion = caps["completionProvider"].flatMap { p in
			guard case .object = p else { return nil }
			let triggers = p["triggerCharacters"]?.arrayValue?.compactMap(\.stringValue) ?? []
			return CompletionSupport(triggerCharacters: Set(triggers.compactMap { $0.utf8.count == 1 ? $0.utf8.first : nil }),
			                         resolves: p["resolveProvider"] == .bool(true), encoding: encoding)
		}
		ready = true
		handlers.log("running (\(encoding.rawValue))")
		handlers.state(.running)
		for (uri, doc) in docs.sorted(by: { $0.key < $1.key }) { sendOpen(client, uri, doc) }
	}

	private func exited(_ gen: Int) {
		guard gen == generation else { return }
		rpc = nil
		ready = false
		watcherRegistrations = [:]
		for token in activeProgress { handlers.progress(ProgressEvent(token: token, kind: .end)) }
		activeProgress = []
		if stopping {
			handlers.log("stopped")
			handlers.state(.stopped)
			return
		}
		let t = now()
		restarts.removeAll { t.timeIntervalSince($0) >= Self.restartWindow }
		guard restarts.count < Self.maxRestarts else {
			let reason = "the server crashed \(Self.maxRestarts) times within a minute"
			handlers.log(reason)
			handlers.state(.failed(reason))
			return
		}
		restarts.append(t)
		handlers.log("exited, restarting (\(restarts.count)/\(Self.maxRestarts))")
		launch()
	}

	private func stderr(_ data: Data) {
		stderrTail.append(data)
		while let nl = stderrTail.firstIndex(of: 0x0A) {
			let line = String(decoding: stderrTail[stderrTail.startIndex..<nl], as: UTF8.self)
			stderrTail.removeSubrange(stderrTail.startIndex...nl)
			if !line.isEmpty { handlers.log(line) }
		}
	}

	// MARK: Documents

	public func open(uri: String, languageID: String, version: Int, text: Rope) {
		queue.async { [self] in
			let doc = Doc(languageID: languageID, version: version, text: text)
			docs[uri] = doc
			if ready, let rpc { sendOpen(rpc, uri, doc) }
		}
	}

	/// `text` is the document after `changes`; ranges in `changes` refer to the text before.
	public func change(uri: String, version: Int, changes: ChangeSet, text: Rope) {
		queue.async { [self] in
			guard var doc = docs[uri] else { return }
			let old = doc.text
			doc.earlier.append((doc.version, old))
			if doc.earlier.count > Self.keptVersions { doc.earlier.removeFirst() }
			doc.version = version
			doc.text = text
			docs[uri] = doc
			guard ready, let rpc else { return }
			let events: [JSONValue]
			switch syncKind {
			case 1:
				events = [["text": .string(text.string)]]
			case 2:
				// Back to front: each range stays valid in the text the server has at that point.
				events = changes.changes.reversed().map {
					["range": old.lspRange($0.range, encoding: encoding).json, "text": .string(String(decoding: $0.text, as: UTF8.self))]
				}
			default:
				return
			}
			try? rpc.notify("textDocument/didChange", [
				"textDocument": ["uri": .string(uri), "version": .number(Double(version))],
				"contentChanges": .array(events),
			])
		}
	}

	public func save(uri: String) {
		queue.async { [self] in
			guard let doc = docs[uri], ready, let rpc else { return }
			var params: JSONValue = ["textDocument": ["uri": .string(uri)]]
			if saveIncludesText, case .object(var o) = params {
				o["text"] = .string(doc.text.string)
				params = .object(o)
			}
			try? rpc.notify("textDocument/didSave", params)
		}
	}

	public func close(uri: String) {
		queue.async { [self] in
			guard docs.removeValue(forKey: uri) != nil, ready, let rpc else { return }
			try? rpc.notify("textDocument/didClose", ["textDocument": ["uri": .string(uri)]])
		}
	}

	private func sendOpen(_ rpc: JSONRPCClient, _ uri: String, _ doc: Doc) {
		try? rpc.notify("textDocument/didOpen", ["textDocument": [
			"uri": .string(uri), "languageId": .string(doc.languageID),
			"version": .number(Double(doc.version)), "text": .string(doc.text.string),
		]])
	}

	// MARK: Messages

	/// A request to the server; cancelling the task sends `$/cancelRequest`.
	/// Document changes made before the call reach the server first.
	public func request(_ method: String, _ params: JSONValue = .null) async throws -> JSONValue {
		guard let client = queue.sync(execute: { ready ? rpc : nil }) else { throw LSPError.notRunning }
		return try await client.request(method, params)
	}

	public func notify(_ method: String, _ params: JSONValue = .null) {
		queue.async { [self] in
			if ready, let rpc { try? rpc.notify(method, params) }
		}
	}

	/// Whether the server registered for file events (FSEvents are only worth forwarding then).
	public var wantsFileEvents: Bool { queue.sync { !watcherRegistrations.isEmpty } }

	/// Forwards the events matching the server's registered watchers as `workspace/didChangeWatchedFiles`.
	public func filesChanged(_ events: [(URL, FileChangeType)]) {
		queue.async { [self] in
			guard ready, let rpc else { return }
			let watchers = watcherRegistrations.values.flatMap { $0 }
			let matched: [JSONValue] = events.compactMap { url, type in
				let path = url.standardizedFileURL.path
				guard watchers.contains(where: { $0.matches(path, type) }) else { return nil }
				return ["uri": .string(URL(fileURLWithPath: path).absoluteString), "type": .number(Double(type.rawValue))]
			}
			if !matched.isEmpty { try? rpc.notify("workspace/didChangeWatchedFiles", ["changes": .array(matched)]) }
		}
	}

	private func handleNotification(_ method: String, _ params: JSONValue) {
		switch method {
		case "$/progress":
			guard let token = params["token"].map(Self.tokenString), let value = params["value"],
			      let kind = value["kind"]?.stringValue.flatMap(ProgressEvent.Kind.init) else { return }
			let event = ProgressEvent(token: token, kind: kind, title: value["title"]?.stringValue,
			                          message: value["message"]?.stringValue,
			                          percentage: value["percentage"]?.doubleValue.map { Int($0) })
			queue.async { [self] in
				if kind == .end { activeProgress.remove(token) } else { activeProgress.insert(token) }
				handlers.progress(event)
			}
		case "window/logMessage":
			handlers.log(params["message"]?.stringValue ?? "")
		case "textDocument/publishDiagnostics":
			guard let report = PublishedDiagnostics(params) else { return }
			queue.async { [self] in
				var published = report
				// Positions become bytes in the text the server saw.
				if let doc = docs[published.uri] {
					let version = published.version ?? doc.version
					if let text = doc.text(of: version) {
						published.version = version
						published.ranges = published.diagnostics.map { text.range(of: $0.range, encoding: encoding) }
					}
				}
				handlers.diagnostics(published)
			}
		default:
			if method == "window/showMessage" { handlers.log(params["message"]?.stringValue ?? "") }
			handlers.notification(method, params)
		}
	}

	private func handleRequest(_ method: String, _ params: JSONValue) async throws -> JSONValue {
		switch method {
		case "client/registerCapability":
			queue.sync {
				for r in params["registrations"]?.arrayValue ?? [] where r["method"]?.stringValue == "workspace/didChangeWatchedFiles" {
					guard let id = r["id"]?.stringValue else { continue }
					watcherRegistrations[id] = (r["registerOptions"]?["watchers"]?.arrayValue ?? []).compactMap(Self.watcher)
				}
			}
			return .null
		case "client/unregisterCapability":
			queue.sync {
				// The spec keeps the misspelled key for compatibility.
				for u in params["unregisterations"]?.arrayValue ?? [] {
					if let id = u["id"]?.stringValue { watcherRegistrations[id] = nil }
				}
			}
			return .null
		case "workspace/configuration":
			return .array((params["items"]?.arrayValue ?? []).map { item in
				guard let section = item["section"]?.stringValue else { return settings }
				var value: JSONValue? = settings
				for part in section.split(separator: ".") { value = value?[String(part)] }
				return value ?? .null
			})
		case "workspace/workspaceFolders":
			return [["uri": .string(root.absoluteString), "name": .string(root.lastPathComponent)]]
		case "workspace/applyEdit":
			return ["applied": .bool(await handlers.applyEdit(params["edit"] ?? .null))]
		case "window/showMessageRequest":
			let titles = (params["actions"]?.arrayValue ?? []).compactMap { $0["title"]?.stringValue }
			let type = params["type"]?.doubleValue.map { Int($0) } ?? 4
			let chosen = await handlers.showMessageRequest(type, params["message"]?.stringValue ?? "", titles)
			return chosen.map { ["title": .string($0)] } ?? .null
		case "window/showDocument":
			guard let url = params["uri"]?.stringValue.flatMap(URL.init(string:)) else { return ["success": false] }
			let line = Position(params["selection"]?["start"]).map(\.line)
			return ["success": .bool(await handlers.showDocument(url, line))]
		case "window/workDoneProgress/create":
			return .null
		default:
			throw RPCError.methodNotFound(method)
		}
	}

	private static func tokenString(_ token: JSONValue) -> String {
		switch token {
		case .string(let s): s
		case .number(let n): String(Int(n))
		default: ""
		}
	}

	private static func watcher(_ json: JSONValue) -> Watcher? {
		let kind = json["kind"]?.doubleValue.map { Int($0) } ?? 7
		switch json["globPattern"] {
		case .string(let pattern):
			return Watcher(glob: LSPGlob(pattern), base: nil, kind: kind)
		case .some(let rel):
			// RelativePattern: baseUri is a URI or a WorkspaceFolder.
			guard let pattern = rel["pattern"]?.stringValue,
			      let base = rel["baseUri"]?.stringValue ?? rel["baseUri"]?["uri"]?.stringValue,
			      let url = URL(string: base), url.isFileURL else { return nil }
			return Watcher(glob: LSPGlob(pattern), base: url.standardizedFileURL.path, kind: kind)
		case nil:
			return nil
		}
	}

	static let clientCapabilities: JSONValue = [
		"general": ["positionEncodings": ["utf-8", "utf-16"]],
		"workspace": [
			"applyEdit": true,
			"configuration": true,
			"workspaceFolders": true,
			"workspaceEdit": ["documentChanges": true],
			"didChangeWatchedFiles": ["dynamicRegistration": true, "relativePatternSupport": true],
		],
		"textDocument": [
			"synchronization": ["dynamicRegistration": false, "didSave": true],
			"completion": [
				"contextSupport": true,
				"completionItem": [
					"snippetSupport": true,
					"documentationFormat": ["plaintext"],
					"deprecatedSupport": true,
					"tagSupport": ["valueSet": [1]],
					"preselectSupport": true,
					"labelDetailsSupport": true,
					"commitCharactersSupport": true,
					"resolveSupport": ["properties": ["documentation", "detail", "additionalTextEdits"]],
				],
				"completionList": ["itemDefaults": ["editRange", "insertTextFormat", "commitCharacters"]],
			],
			"definition": ["linkSupport": true],
			"implementation": ["linkSupport": true],
			"typeDefinition": ["linkSupport": true],
			"references": [:],
			"codeAction": [
				"codeActionLiteralSupport": ["codeActionKind": ["valueSet": [
					"", "quickfix", "refactor", "refactor.extract", "refactor.inline", "refactor.rewrite",
					"source", "source.organizeImports", "source.fixAll",
				]]],
				"isPreferredSupport": true,
				"disabledSupport": true,
				"dataSupport": true,
				"resolveSupport": ["properties": ["edit"]],
			],
			"rename": ["prepareSupport": true],
			"formatting": [:],
			"rangeFormatting": [:],
			"publishDiagnostics": ["relatedInformation": true, "versionSupport": true, "tagSupport": ["valueSet": [1, 2]], "codeDescriptionSupport": true],
			"hover": ["contentFormat": ["markdown", "plaintext"]],
			"signatureHelp": [
				"contextSupport": true,
				"signatureInformation": [
					"documentationFormat": ["markdown", "plaintext"],
					"parameterInformation": ["labelOffsetSupport": true],
					"activeParameterSupport": true,
				],
			],
		],
		"window": ["workDoneProgress": true, "showDocument": ["support": true]],
	]
}
