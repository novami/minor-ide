// Spike S2 (docs/spike-tls.md): TLS upgrade inside an open TCP connection with Network.framework only.
// A framer sends the protocol's TLS request, then prepends TLS above itself and passes bytes through.
// Usage: TLSSpike <ca.der> [pg-port] [mysql-port]
import Foundation
import Network
import Security

enum SpikeError: Error, CustomStringConvertible {
	case failed(String)
	var description: String { if case .failed(let m) = self { return m }; return "" }
}

enum Wire: Sendable { case postgres, mysql }

/// Shared state between the app and the framer instance (passed through the framer options).
final class StartTLSContext: @unchecked Sendable {
	let wire: Wire
	let tls: NWProtocolTLS.Options
	/// MySQL server greeting payload, read before TLS.
	var greeting = Data()
	init(wire: Wire, tls: NWProtocolTLS.Options) { self.wire = wire; self.tls = tls }
}

final class StartTLSFramer: NWProtocolFramerImplementation {
	static let definition = NWProtocolFramer.Definition(implementation: StartTLSFramer.self)
	static let label = "StartTLS"
	static let contextKey = "ctx"

	init(framer: NWProtocolFramer.Instance) {}

	func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
		guard let ctx = framer.options[Self.contextKey] as? StartTLSContext else { return .ready }
		if ctx.wire == .postgres {
			// SSLRequest: length 8, code 80877103.
			var req = Data()
			req.appendBE32(8)
			req.appendBE32(80877103)
			framer.writeOutput(data: req)
		}
		return .willMarkReady
	}

	func handleInput(framer: NWProtocolFramer.Instance) -> Int {
		guard let ctx = framer.options[Self.contextKey] as? StartTLSContext else { return 0 }
		switch ctx.wire {
		case .postgres:
			var answer: UInt8 = 0
			var extra = false
			_ = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 64) { buf, _ in
				guard let buf, buf.count >= 1 else { return 0 }
				answer = buf[0]
				extra = buf.count > 1
				return 1
			}
			if answer == 0 { return 1 }
			// Bytes after 'S' and before the TLS handshake would be injected plaintext.
			guard answer == UInt8(ascii: "S"), !extra else {
				framer.markFailed(error: .posix(.EPROTO))
				return 0
			}
		case .mysql:
			var payload: Data?
			var needed = 4
			var extra = false
			_ = framer.parseInput(minimumIncompleteLength: 4, maximumLength: 1 << 16) { buf, _ in
				guard let buf, buf.count >= 4 else { return 0 }
				let len = Int(buf[0]) | Int(buf[1]) << 8 | Int(buf[2]) << 16
				needed = 4 + len
				guard buf.count >= needed else { return 0 }
				payload = Data(buf[4 ..< needed])
				// Anything after the greeting would be unauthenticated plaintext.
				extra = buf.count > needed
				return needed
			}
			guard let payload else { return needed }
			guard !extra, let caps = MySQL.greetingCapabilities(payload), caps & MySQL.clientSSL != 0 else {
				framer.markFailed(error: .posix(.EPROTO))
				return 0
			}
			ctx.greeting = payload
			framer.writeOutput(data: MySQL.packet(seq: 1, MySQL.sslRequest(serverCaps: caps)))
		}
		do {
			try framer.prependApplicationProtocol(options: ctx.tls)
		} catch {
			framer.markFailed(error: .posix(.EPROTO))
			return 0
		}
		framer.passThroughOutput()
		framer.passThroughInput()
		framer.markReady()
		return 0
	}

	func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
		try? framer.writeOutputNoCopy(length: messageLength)
	}

	func wakeup(framer: NWProtocolFramer.Instance) {}
	func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
	func cleanup(framer: NWProtocolFramer.Instance) {}
}

// MARK: Connection

final class Conn: @unchecked Sendable {
	let nw: NWConnection
	let queue = DispatchQueue(label: "spike.conn")
	private var buffer = Data()
	private var opened = false // touched only on `queue`

	init(host: String, port: UInt16, ctx: StartTLSContext) {
		let framer = NWProtocolFramer.Options(definition: StartTLSFramer.definition)
		framer[StartTLSFramer.contextKey] = ctx
		let params = NWParameters.tcp
		params.defaultProtocolStack.applicationProtocols = [framer]
		nw = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
	}

	func open() async throws {
		try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
			nw.stateUpdateHandler = { [self] state in
				guard !opened else { return }
				switch state {
				case .ready: opened = true; cont.resume()
				case .failed(let e), .waiting(let e): opened = true; cont.resume(throwing: e)
				case .cancelled: opened = true; cont.resume(throwing: SpikeError.failed("cancelled"))
				default: break
				}
			}
			nw.start(queue: queue)
		}
	}

	func send(_ data: Data) async throws {
		try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
			nw.send(content: data, completion: .contentProcessed { e in
				if let e { cont.resume(throwing: e) } else { cont.resume() }
			})
		}
	}

	func read(_ n: Int) async throws -> Data {
		while buffer.count < n {
			let chunk: Data = try await withCheckedThrowingContinuation { cont in
				nw.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, e in
					if let e { cont.resume(throwing: e) }
					else if let data, !data.isEmpty { cont.resume(returning: data) }
					else if isComplete { cont.resume(throwing: SpikeError.failed("connection closed")) }
					else { cont.resume(returning: Data()) }
				}
			}
			buffer.append(chunk)
		}
		let out = Data(buffer.prefix(n))
		buffer.removeFirst(n)
		return out
	}

	/// Negotiated TLS version, read from the TLS metadata on the connection.
	func tlsVersion() -> String {
		guard let meta = nw.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return "none" }
		switch sec_protocol_metadata_get_negotiated_tls_protocol_version(meta.securityProtocolMetadata) {
		case .TLSv13: return "TLS 1.3"
		case .TLSv12: return "TLS 1.2"
		default: return "other"
		}
	}
}

func tlsOptions(anchor: SecCertificate?) -> NWProtocolTLS.Options {
	let tls = NWProtocolTLS.Options()
	let sec = tls.securityProtocolOptions
	sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
	sec_protocol_options_set_tls_server_name(sec, "localhost")
	if let anchor {
		sec_protocol_options_set_verify_block(sec, { _, trust, complete in
			let t = sec_trust_copy_ref(trust).takeRetainedValue()
			SecTrustSetPolicies(t, SecPolicyCreateSSL(true, "localhost" as CFString))
			SecTrustSetAnchorCertificates(t, [anchor] as CFArray)
			SecTrustSetAnchorCertificatesOnly(t, true)
			complete(SecTrustEvaluateWithError(t, nil))
		}, DispatchQueue(label: "spike.verify"))
	}
	return tls
}

// MARK: PostgreSQL

enum Postgres {
	static func query(port: UInt16, anchor: SecCertificate?) async throws -> String {
		let ctx = StartTLSContext(wire: .postgres, tls: tlsOptions(anchor: anchor))
		let c = Conn(host: "127.0.0.1", port: port, ctx: ctx)
		defer { c.nw.cancel() }
		try await c.open()
		var body = Data()
		body.appendBE32(196608)
		for s in ["user", "postgres", "database", "postgres", ""] { body.append(contentsOf: Array(s.utf8) + [0]) }
		var startup = Data()
		startup.appendBE32(UInt32(body.count + 4))
		startup.append(body)
		try await c.send(startup)
		try await waitReady(c)
		let sql = "SELECT version(), (SELECT version FROM pg_stat_ssl WHERE pid = pg_backend_pid())"
		var q = Data([UInt8(ascii: "Q")])
		q.appendBE32(UInt32(sql.utf8.count + 5))
		q.append(contentsOf: Array(sql.utf8) + [0])
		try await c.send(q)
		var row: [String] = []
		while true {
			let (type, payload) = try await message(c)
			if type == "D" {
				var i = 2
				for _ in 0 ..< Int(payload.be16(0)) {
					let len = Int(Int32(bitPattern: payload.be32(i))); i += 4
					if len < 0 { row.append("NULL"); continue }
					row.append(String(decoding: payload[payload.startIndex + i ..< payload.startIndex + i + len], as: UTF8.self)); i += len
				}
			} else if type == "E" {
				throw SpikeError.failed("server error: \(String(decoding: payload, as: UTF8.self))")
			} else if type == "Z" { break }
		}
		return "client \(c.tlsVersion()), server reports \(row.joined(separator: " | "))"
	}

	static func waitReady(_ c: Conn) async throws {
		while true {
			let (type, payload) = try await message(c)
			switch type {
			case "R": guard payload.be32(0) == 0 else { throw SpikeError.failed("auth method \(payload.be32(0)) not in the spike") }
			case "E": throw SpikeError.failed("server error: \(String(decoding: payload, as: UTF8.self))")
			case "Z": return
			default: continue
			}
		}
	}

	static func message(_ c: Conn) async throws -> (Character, Data) {
		let head = try await c.read(5)
		let len = Int(head.be32(1))
		guard len >= 4, len < 1 << 24 else { throw SpikeError.failed("bad message length") }
		return (Character(UnicodeScalar(head[head.startIndex])), try await c.read(len - 4))
	}
}

// MARK: MySQL / MariaDB

enum MySQL {
	static let clientLongPassword: UInt32 = 0x1
	static let clientProtocol41: UInt32 = 0x200
	static let clientSSL: UInt32 = 0x800
	static let clientTransactions: UInt32 = 0x2000
	static let clientSecureConnection: UInt32 = 0x8000
	static let clientPluginAuth: UInt32 = 0x80000
	static let wanted = clientLongPassword | clientProtocol41 | clientSSL | clientTransactions | clientSecureConnection | clientPluginAuth

	static func greetingCapabilities(_ p: Data) -> UInt32? {
		let b = [UInt8](p)
		guard b.first == 10, let nul = b.dropFirst().firstIndex(of: 0) else { return nil }
		var i = nul + 1 + 4 + 8 + 1 // connection id, scramble part 1, filler
		guard b.count >= i + 2 + 1 + 2 + 2 else { return nil }
		let low = UInt32(b[i]) | UInt32(b[i + 1]) << 8
		i += 2 + 1 + 2
		let high = UInt32(b[i]) | UInt32(b[i + 1]) << 8
		return low | high << 16
	}

	static func caps(_ server: UInt32) -> UInt32 { wanted & server }

	static func sslRequest(serverCaps: UInt32) -> Data {
		var d = Data()
		d.appendLE32(caps(serverCaps))
		d.appendLE32(1 << 24)
		d.append(45) // utf8mb4_general_ci
		d.append(Data(count: 23))
		return d
	}

	static func packet(seq: UInt8, _ payload: Data) -> Data {
		let n = payload.count
		return Data([UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), seq]) + payload
	}

	static func read(_ c: Conn) async throws -> (UInt8, Data) {
		let h = try await c.read(4)
		let b = [UInt8](h)
		let len = Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16
		return (b[3], try await c.read(len))
	}

	static func query(port: UInt16, anchor: SecCertificate?) async throws -> String {
		let ctx = StartTLSContext(wire: .mysql, tls: tlsOptions(anchor: anchor))
		let c = Conn(host: "127.0.0.1", port: port, ctx: ctx)
		defer { c.nw.cancel() }
		try await c.open()
		guard let serverCaps = greetingCapabilities(ctx.greeting) else { throw SpikeError.failed("no greeting") }
		// HandshakeResponse41 over TLS, root with an empty password (auth is not part of the spike).
		var r = sslRequest(serverCaps: serverCaps)
		r.append(contentsOf: Array("root".utf8) + [0])
		r.append(0) // empty auth response
		if caps(serverCaps) & clientPluginAuth != 0 { r.append(contentsOf: Array("mysql_native_password".utf8) + [0]) }
		try await c.send(packet(seq: 2, r))
		var (seq, reply) = try await read(c)
		if reply.first == 0xFE { // auth switch: answer with an empty password again
			try await c.send(packet(seq: seq &+ 1, Data()))
			(seq, reply) = try await read(c)
		}
		guard reply.first == 0x00 else { throw SpikeError.failed("auth failed: \(String(decoding: reply.dropFirst(3), as: UTF8.self))") }
		let sql = "SELECT VERSION(), (SELECT VARIABLE_VALUE FROM information_schema.SESSION_STATUS WHERE VARIABLE_NAME = 'Ssl_version')"
		try await c.send(packet(seq: 0, Data([0x03]) + Data(sql.utf8)))
		var row: [String] = []
		var eofs = 0
		while eofs < 2 {
			let (_, p) = try await read(c)
			let b = [UInt8](p)
			if b.first == 0xFF { throw SpikeError.failed("query failed: \(String(decoding: b.dropFirst(9), as: UTF8.self))") }
			if b.first == 0xFE, b.count < 9 { eofs += 1; continue }
			if eofs == 1 { row = lenencStrings(b) }
		}
		return "client \(c.tlsVersion()), server reports \(row.joined(separator: " | "))"
	}

	static func lenencStrings(_ b: [UInt8]) -> [String] {
		var out: [String] = []
		var i = 0
		while i < b.count {
			var len = Int(b[i]); i += 1
			if len == 0xFB { out.append("NULL"); continue }
			if len == 0xFC, i + 2 <= b.count { len = Int(b[i]) | Int(b[i + 1]) << 8; i += 2 }
			guard i + len <= b.count else { break }
			out.append(String(decoding: b[i ..< i + len], as: UTF8.self)); i += len
		}
		return out
	}
}

// MARK: Helpers

extension Data {
	mutating func appendBE32(_ v: UInt32) { append(contentsOf: [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
	mutating func appendLE32(_ v: UInt32) { append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)]) }
	func be32(_ at: Int) -> UInt32 {
		let i = startIndex + at
		return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
	}
	func be16(_ at: Int) -> UInt16 { UInt16(self[startIndex + at]) << 8 | UInt16(self[startIndex + at + 1]) }
}

// MARK: Main

let args = CommandLine.arguments
guard args.count >= 2, let der = FileManager.default.contents(atPath: args[1]),
      let ca = SecCertificateCreateWithData(nil, der as CFData) else {
	print("usage: TLSSpike <ca.der> [pg-port] [mysql-port]")
	exit(2)
}
let pgPort = args.count > 2 ? UInt16(args[2]) ?? 5432 : 5432
let myPort = args.count > 3 ? UInt16(args[3]) ?? 3306 : 3306

func run(_ name: String, _ body: () async throws -> String) async {
	let start = Date()
	do {
		let r = try await body()
		print("OK   \(name): \(r) (\(Int(Date().timeIntervalSince(start) * 1000)) ms)")
	} catch {
		print("FAIL \(name): \(error)")
	}
}

await run("PostgreSQL, test CA") { try await Postgres.query(port: pgPort, anchor: ca) }
await run("MariaDB, test CA") { try await MySQL.query(port: myPort, anchor: ca) }
// Without the test CA the system trust store must reject the self-signed chain.
await run("PostgreSQL, system trust (must fail)") { try await Postgres.query(port: pgPort, anchor: nil) }
await run("MariaDB, system trust (must fail)") { try await MySQL.query(port: myPort, anchor: nil) }
