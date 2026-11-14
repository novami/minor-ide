import Foundation

public struct RPCError: Error, Codable, Sendable, CustomStringConvertible {
	public let code: Int
	public let message: String
	public var description: String { "JSON-RPC \(code): \(message)" }
	public init(code: Int, message: String) {
		self.code = code
		self.message = message
	}
	static let processExited = RPCError(code: -32099, message: "server process exited")
}

/// JSON-RPC 2.0 client over a child process's stdio with Content-Length framing.
/// Shared by the DB helper, PHP server and LSP servers.
public final class JSONRPCClient: @unchecked Sendable {
	private let process = Process()
	private let stdin = Pipe()
	private let stdout = Pipe()
	private let lock = NSLock() // pending requests and read buffer
	private let writeLock = NSLock() // separate, so a blocked write never stalls reading
	private var nextID = 1
	private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
	private var buffer = Data()
	private var exited = false

	/// Called for server notifications (method, params). Runs on a background queue.
	public var onNotification: (@Sendable (String, JSONValue) -> Void)?

	public init(executable: URL, arguments: [String]) throws {
		process.executableURL = executable
		process.arguments = arguments
		process.standardInput = stdin
		process.standardOutput = stdout
		process.standardError = FileHandle.standardError
		stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
			let data = handle.availableData
			if data.isEmpty {
				handle.readabilityHandler = nil
			} else {
				self?.receive(data)
			}
		}
		process.terminationHandler = { [weak self] _ in self?.failAll() }
		try process.run()
	}

	deinit { terminate() }

	public func terminate() {
		if process.isRunning { process.terminate() }
	}

	public func request(_ method: String, _ params: JSONValue = .null) async throws -> JSONValue {
		try await withCheckedThrowingContinuation { cont in
			lock.lock()
			if exited {
				lock.unlock()
				cont.resume(throwing: RPCError.processExited)
				return
			}
			let id = nextID
			nextID += 1
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

	private struct Incoming: Decodable {
		let id: Int?
		let method: String?
		let params: JSONValue?
		let result: JSONValue?
		let error: RPCError?
	}

	private func send(_ message: Outgoing) throws {
		let body = try JSONEncoder().encode(message)
		var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
		frame.append(body)
		writeLock.lock()
		defer { writeLock.unlock() }
		try stdin.fileHandleForWriting.write(contentsOf: frame)
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
		if let method = msg.method, msg.id == nil {
			onNotification?(method, msg.params ?? .null)
			return
		}
		guard let id = msg.id else { return }
		lock.lock()
		let cont = pending.removeValue(forKey: id)
		lock.unlock()
		if let error = msg.error {
			cont?.resume(throwing: error)
		} else {
			cont?.resume(returning: msg.result ?? .null)
		}
	}

	private func failAll() {
		lock.lock()
		exited = true
		let all = pending
		pending = [:]
		lock.unlock()
		for c in all.values { c.resume(throwing: RPCError.processExited) }
	}
}
