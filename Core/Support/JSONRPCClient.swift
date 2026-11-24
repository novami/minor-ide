import Foundation

nonisolated public struct RPCError: Error, Codable, Sendable, CustomStringConvertible {
	public let code: Int
	public let message: String
	public var description: String { "JSON-RPC \(code): \(message)" }
	public init(code: Int, message: String) {
		self.code = code
		self.message = message
	}
	public static let processExited = RPCError(code: -32099, message: "server process exited")
	public static func methodNotFound(_ method: String) -> RPCError { RPCError(code: -32601, message: "method not found: \(method)") }
}

/// Request id: numbers from us, numbers or strings from the other side.
nonisolated public enum RPCID: Codable, Hashable, Sendable {
	case int(Int)
	case string(String)

	public init(from decoder: Decoder) throws {
		let c = try decoder.singleValueContainer()
		if let i = try? c.decode(Int.self) { self = .int(i) } else { self = .string(try c.decode(String.self)) }
	}

	public func encode(to encoder: Encoder) throws {
		var c = encoder.singleValueContainer()
		switch self {
		case .int(let i): try c.encode(i)
		case .string(let s): try c.encode(s)
		}
	}
}

/// JSON-RPC 2.0 peer over stdio of a child process (or any pair of file handles) with Content-Length framing.
/// Shared by the DB helper, the search helper and LSP servers. Set the handlers before the first message.
nonisolated public final class JSONRPCClient: @unchecked Sendable {
	private let process: Process?
	private let input: FileHandle // we read
	private let output: FileHandle // we write
	private let lock = NSLock() // pending requests, read buffer, exit state
	private let writeLock = NSLock() // separate, so a blocked write never stalls reading
	private var nextID = 1
	private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
	private var buffer = Data()
	private var exited = false

	/// Called for notifications (method, params). Runs on a background queue.
	public var onNotification: (@Sendable (String, JSONValue) -> Void)?
	/// Answers requests from the other side; without it they get "method not found".
	public var onRequest: (@Sendable (String, JSONValue) async throws -> JSONValue)?
	/// Called once when the other side goes away (process exit or end of input).
	public var onExit: (@Sendable () -> Void)?
	/// Notification sent when a request's task is cancelled, e.g. "$/cancelRequest" (params `{id}`).
	public var cancelMethod: String?

	/// Starts the process. `stderr` gets its error output; without it the output goes to ours.
	public init(executable: URL, arguments: [String], environment: [String: String]? = nil,
	            directory: URL? = nil, stderr: (@Sendable (Data) -> Void)? = nil) throws {
		let process = Process()
		let stdin = Pipe(), stdout = Pipe()
		process.executableURL = executable
		process.arguments = arguments
		if let environment { process.environment = environment }
		if let directory { process.currentDirectoryURL = directory }
		process.standardInput = stdin
		process.standardOutput = stdout
		if let stderr {
			let err = Pipe()
			process.standardError = err
			err.fileHandleForReading.readabilityHandler = { handle in
				let data = handle.availableData
				if data.isEmpty { handle.readabilityHandler = nil } else { stderr(data) }
			}
		} else {
			process.standardError = FileHandle.standardError
		}
		self.process = process
		input = stdout.fileHandleForReading
		output = stdin.fileHandleForWriting
		startReading()
		process.terminationHandler = { [weak self] _ in self?.failAll() }
		try process.run()
	}

	/// A peer over existing handles (tests, in-process servers).
	public init(reading: FileHandle, writing: FileHandle) {
		process = nil
		input = reading
		output = writing
		startReading()
	}

	deinit { terminate() }

	public var processIdentifier: Int32? { process?.processIdentifier }

	public func terminate() {
		if let process {
			if process.isRunning { process.terminate() }
		} else {
			try? output.close()
		}
	}

	private func startReading() {
		// A write to a server that died must fail with EPIPE, not kill the app with SIGPIPE.
		_ = fcntl(output.fileDescriptor, F_SETNOSIGPIPE, 1)
		input.readabilityHandler = { [weak self] handle in
			let data = handle.availableData
			if data.isEmpty {
				handle.readabilityHandler = nil
				self?.failAll()
			} else {
				self?.receive(data)
			}
		}
	}

	public func request(_ method: String, _ params: JSONValue = .null) async throws -> JSONValue {
		let id = lock.withLock {
			let id = nextID
			nextID += 1
			return id
		}
		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { cont in
				lock.lock()
				if exited || Task.isCancelled {
					lock.unlock()
					cont.resume(throwing: exited ? RPCError.processExited : CancellationError())
					return
				}
				pending[id] = cont
				lock.unlock()
				do {
					try send(Outgoing(id: id, method: method, params: params))
				} catch {
					lock.lock()
					let c = pending.removeValue(forKey: id)
					lock.unlock()
					c?.resume(throwing: error)
				}
			}
		} onCancel: {
			lock.lock()
			let c = pending.removeValue(forKey: id)
			lock.unlock()
			guard let c else { return }
			c.resume(throwing: CancellationError())
			if let m = cancelMethod { try? notify(m, ["id": .number(Double(id))]) }
		}
	}

	public func notify(_ method: String, _ params: JSONValue = .null) throws {
		try send(Outgoing(id: nil, method: method, params: params))
	}

	private struct Outgoing: Encodable {
		let jsonrpc = "2.0"
		let id: Int?
		let method: String
		let params: JSONValue
	}

	private struct Response: Encodable {
		let jsonrpc = "2.0"
		let id: RPCID
		let result: JSONValue?
		let error: RPCError?
	}

	private struct Incoming: Decodable {
		let id: RPCID?
		let method: String?
		let params: JSONValue?
		let result: JSONValue?
		let error: RPCError?
	}

	private func send(_ message: some Encodable) throws {
		let body = try JSONEncoder().encode(message)
		var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
		frame.append(body)
		writeLock.lock()
		defer { writeLock.unlock() }
		try output.write(contentsOf: frame)
	}

	private func receive(_ data: Data) {
		lock.lock()
		buffer.append(data)
		var messages: [Data] = []
		while let body = nextFrame() { messages.append(body) }
		lock.unlock()
		for body in messages { dispatch(body) }
	}

	/// Extracts one complete frame from the buffer. Caller holds the lock.
	private func nextFrame() -> Data? {
		guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
		let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
		guard let lengthLine = header.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
		      let length = Int(lengthLine.split(separator: ":")[1].trimmingCharacters(in: .whitespaces))
		else {
			buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound) // skip a malformed header
			return nil
		}
		guard buffer.distance(from: headerEnd.upperBound, to: buffer.endIndex) >= length else { return nil }
		let bodyEnd = buffer.index(headerEnd.upperBound, offsetBy: length)
		let body = Data(buffer[headerEnd.upperBound..<bodyEnd])
		buffer.removeSubrange(buffer.startIndex..<bodyEnd)
		return body
	}

	private func dispatch(_ body: Data) {
		guard let msg = try? JSONDecoder().decode(Incoming.self, from: body) else { return }
		if let method = msg.method {
			if let id = msg.id {
				answer(id, method, msg.params ?? .null)
			} else {
				onNotification?(method, msg.params ?? .null)
			}
			return
		}
		guard case .int(let id) = msg.id else { return }
		lock.lock()
		let cont = pending.removeValue(forKey: id)
		lock.unlock()
		if let error = msg.error {
			cont?.resume(throwing: error)
		} else {
			cont?.resume(returning: msg.result ?? .null)
		}
	}

	private func answer(_ id: RPCID, _ method: String, _ params: JSONValue) {
		guard let handler = onRequest else {
			try? send(Response(id: id, result: nil, error: .methodNotFound(method)))
			return
		}
		Task {
			let response: Response
			do {
				response = Response(id: id, result: try await handler(method, params), error: nil)
			} catch let error as RPCError {
				response = Response(id: id, result: nil, error: error)
			} catch {
				response = Response(id: id, result: nil, error: RPCError(code: -32603, message: "\(error)"))
			}
			try? self.send(response)
		}
	}

	private func failAll() {
		lock.lock()
		let first = !exited
		exited = true
		let all = pending
		pending = [:]
		lock.unlock()
		for c in all.values { c.resume(throwing: RPCError.processExited) }
		if first { onExit?() }
	}
}
