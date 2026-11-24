import Foundation

/// Runs the user's `git` (path and environment from the login shell). Arguments are always
/// an array, never a shell string. Callers check the project's trust first (Restricted Mode
/// runs no Git).
nonisolated public struct GitTool: Sendable {
	public let path: String
	public let environment: [String: String]

	public init(path: String, environment: [String: String]) {
		self.path = path
		var env = environment
		env["GIT_TERMINAL_PROMPT"] = "0" // no hidden password prompt on a missing terminal
		env["GIT_OPTIONAL_LOCKS"] = "0" // reading must not take the index lock
		// SSH only with a known host key, and no prompts (keys come from ssh-agent).
		if env["GIT_SSH_COMMAND"] == nil { env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o StrictHostKeyChecking=yes" }
		self.environment = env
	}

	public struct Output: Sendable {
		public let status: Int32
		public let stdout: Data
		public let stderr: Data
	}

	/// Runs git in `directory` and waits (call off the main thread). `onStderr` gets error
	/// output as it comes (clone progress). nil when git could not start or timed out.
	public func run(_ arguments: [String], in directory: URL, timeout: TimeInterval = 30,
	                onStderr: (@Sendable (Data) -> Void)? = nil, cancel: CancelToken? = nil) -> Output? {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: path)
		process.arguments = arguments
		process.currentDirectoryURL = directory
		process.environment = environment
		process.standardInput = FileHandle.nullDevice
		let out = Pipe(), err = Pipe()
		process.standardOutput = out
		process.standardError = err
		let collected = Collector()
		let done = DispatchSemaphore(value: 0)
		process.terminationHandler = { _ in done.signal() }
		guard (try? process.run()) != nil else { return nil }
		// Both pipes are drained while git runs (a full pipe would block it).
		let readers = DispatchGroup()
		DispatchQueue.global(qos: .userInitiated).async(group: readers) {
			collected.add(out.fileHandleForReading.readDataToEndOfFile(), toError: false)
		}
		DispatchQueue.global(qos: .userInitiated).async(group: readers) {
			while true {
				let d = err.fileHandleForReading.availableData
				if d.isEmpty { break }
				collected.add(d, toError: true)
				onStderr?(d)
			}
		}
		cancel?.onCancel { process.terminate() }
		if done.wait(timeout: .now() + timeout) == .timedOut {
			process.terminate()
			return nil
		}
		// A helper started by git (ssh connection sharing) may keep the pipes open.
		_ = readers.wait(timeout: .now() + 2)
		let (o, e) = collected.value
		return Output(status: process.terminationStatus, stdout: o, stderr: e)
	}

	/// The committed content of `file` at HEAD; nil when it is untracked, outside a repository
	/// or git fails.
	public func headContents(of file: URL) -> Data? {
		let dir = file.deletingLastPathComponent()
		guard let r = run(["cat-file", "blob", "HEAD:./" + file.lastPathComponent], in: dir), r.status == 0 else { return nil }
		return r.stdout
	}

	private final class Collector: @unchecked Sendable {
		private let lock = NSLock()
		private var out = Data(), err = Data()
		func add(_ d: Data, toError: Bool) { lock.withLock { if toError { err.append(d) } else { out.append(d) } } }
		var value: (Data, Data) { lock.withLock { (out, err) } }
	}
}

/// Lets another thread stop a running process (Cancel in a progress sheet).
nonisolated public final class CancelToken: @unchecked Sendable {
	private let lock = NSLock()
	private var cancelled = false
	private var handlers: [@Sendable () -> Void] = []

	public init() {}

	public var isCancelled: Bool { lock.withLock { cancelled } }

	public func cancel() {
		let list = lock.withLock {
			cancelled = true
			defer { handlers = [] }
			return handlers
		}
		list.forEach { $0() }
	}

	func onCancel(_ body: @escaping @Sendable () -> Void) {
		let now = lock.withLock {
			if cancelled { return true }
			handlers.append(body)
			return false
		}
		if now { body() }
	}
}

/// Addresses accepted by Clone Git Repository.
nonisolated public enum GitAddress {
	/// https, ssh, git and scp-like `user@host:path` addresses; never an option ("-…") or a
	/// transport that runs commands (`ext::`).
	public static func isValid(_ text: String) -> Bool {
		let s = text.trimmingCharacters(in: .whitespaces)
		guard !s.isEmpty, !s.hasPrefix("-"), !s.contains(" "), !s.contains("::") else { return false }
		if ["https://", "http://", "ssh://", "git://"].contains(where: { s.lowercased().hasPrefix($0) }) {
			return URL(string: s)?.host?.isEmpty == false
		}
		// scp-like: [user@]host:path (other schemes, file:// included, are not offered)
		guard !s.contains("://"), let colon = s.firstIndex(of: ":"), colon != s.startIndex, !s[..<colon].contains("/") else { return false }
		return s.index(after: colon) < s.endIndex
	}

	/// "https://host/owner/repo.git" → "repo".
	public static func folderName(for address: String) -> String {
		var s = address.trimmingCharacters(in: .whitespaces)
		while s.hasSuffix("/") { s.removeLast() }
		var last = s.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
		if last.hasSuffix(".git") { last.removeLast(4) }
		return last
	}
}
