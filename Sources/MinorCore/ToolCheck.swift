import Foundation

/// Whether an external tool (plan: Externí nástroje) is installed and new enough. The tool
/// runs only with a version argument, through an argument array, with the given environment.
public struct ToolCheck: Sendable, Equatable {
	public enum Status: Sendable, Equatable {
		case ok
		case tooOld
		case missing
		/// Found, but the version could not be read (the tool is still used).
		case unknownVersion
	}

	public let tool: String
	public let path: String?
	public let version: String?
	public let status: Status

	/// Finds `tool` with `which`, runs it with `arguments` (output and errors) and compares
	/// the first version number in the output with `minimum` (nil: any version).
	public static func run(_ tool: String, arguments: [String], minimum: String?, environment: [String: String],
	                       which: (String) -> String?, timeout: TimeInterval = 5) -> ToolCheck {
		guard let path = which(tool) else { return ToolCheck(tool: tool, path: nil, version: nil, status: .missing) }
		let output = runProcess(path, arguments, environment: environment, timeout: timeout)
		guard let version = output.flatMap(firstVersion) else {
			return ToolCheck(tool: tool, path: path, version: nil, status: .unknownVersion)
		}
		let old = minimum.map { compare(version, $0) < 0 } ?? false
		return ToolCheck(tool: tool, path: path, version: version, status: old ? .tooOld : .ok)
	}

	/// The first number like 2.39 or 1.22.5 (a leading "v" or "go" is skipped).
	public static func firstVersion(in text: String) -> String? {
		guard let range = text.range(of: #"[0-9]+\.[0-9]+(\.[0-9]+)?"#, options: .regularExpression) else { return nil }
		return String(text[range])
	}

	/// Compares dotted versions numerically (1.10 > 1.9); missing parts count as 0.
	public static func compare(_ a: String, _ b: String) -> Int {
		let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
		for i in 0..<max(x.count, y.count) {
			let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
			if p != q { return p < q ? -1 : 1 }
		}
		return 0
	}

	private static func runProcess(_ path: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval) -> String? {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: path)
		process.arguments = arguments
		process.environment = environment
		process.standardInput = FileHandle.nullDevice
		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = pipe // ssh -V writes to stderr
		let done = DispatchSemaphore(value: 0)
		process.terminationHandler = { _ in done.signal() }
		guard (try? process.run()) != nil else { return nil }
		if done.wait(timeout: .now() + timeout) == .timedOut {
			process.terminate()
			return nil
		}
		// The tool has exited; what it wrote is in the pipe (version output is small).
		let data = (try? pipe.fileHandleForReading.readToEnd()) ?? nil
		return data.map { String(decoding: $0, as: UTF8.self) }
	}
}
