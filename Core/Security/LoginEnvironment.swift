import Foundation

/// Environment for the tools MinorIDE starts (D22). An app opened from the Finder does not
/// get the PATH of the Terminal (no /opt/homebrew/bin), so it is read once from the user's
/// login interactive shell. The command is a constant without user data; the output is
/// taken between random markers because .zshrc may print. On failure or timeout the app's
/// own PATH gets the usual tool folders appended.
nonisolated public struct LoginEnvironment: Sendable, Equatable {
	/// Variables taken over from the shell.
	public static let keys = ["PATH", "GOPATH", "GOPRIVATE", "GOFLAGS", "SSH_AUTH_SOCK"]

	public var values: [String: String]
	/// False when the shell failed or timed out and the fallback was used.
	public var fromShell: Bool

	public static func load(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
	                        environment: [String: String] = ProcessInfo.processInfo.environment,
	                        timeout: TimeInterval = 5) -> LoginEnvironment {
		let marker = "MINORIDE-ENV-" + UUID().uuidString
		let process = Process()
		process.executableURL = URL(fileURLWithPath: shell)
		process.arguments = ["-l", "-i", "-c", "printf '%s' \(marker); /usr/bin/env -0; printf '%s' \(marker)"]
		process.environment = environment
		process.standardInput = FileHandle.nullDevice
		process.standardError = FileHandle.nullDevice
		let pipe = Pipe()
		process.standardOutput = pipe
		let done = DispatchSemaphore(value: 0)
		process.terminationHandler = { _ in done.signal() }
		let output = OutputBuffer()
		let read = DispatchSemaphore(value: 0)
		let reading = Thread {
			output.data = pipe.fileHandleForReading.readDataToEndOfFile()
			read.signal()
		}
		do {
			try process.run()
		} catch {
			return fallback(environment)
		}
		reading.start()
		if done.wait(timeout: .now() + timeout) == .timedOut {
			process.terminate()
			return fallback(environment)
		}
		// A background job started by .zshrc may keep the pipe open: don't wait for it long.
		guard read.wait(timeout: .now() + 1) == .success else { return fallback(environment) }
		guard process.terminationStatus == 0, let values = parse(output.data, marker: marker) else { return fallback(environment) }
		return LoginEnvironment(values: values, fromShell: true)
	}

	/// The `env -0` output between the two markers, reduced to `keys`.
	static func parse(_ data: Data, marker: String) -> [String: String]? {
		let text = String(decoding: data, as: UTF8.self)
		guard let start = text.range(of: marker),
		      let end = text.range(of: marker, range: start.upperBound..<text.endIndex) else { return nil }
		var values: [String: String] = [:]
		for entry in text[start.upperBound..<end.lowerBound].split(separator: "\0") {
			guard let eq = entry.firstIndex(of: "=") else { continue }
			let key = String(entry[..<eq])
			if keys.contains(key) { values[key] = String(entry[entry.index(after: eq)...]) }
		}
		return values["PATH"] == nil ? nil : values
	}

	static func fallback(_ environment: [String: String]) -> LoginEnvironment {
		var values = environment.filter { keys.contains($0.key) }
		let home = FileManager.default.homeDirectoryForCurrentUser.path
		var path = (values["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
		for extra in ["/opt/homebrew/bin", "/usr/local/bin", home + "/go/bin"] where !path.contains(extra) { path.append(extra) }
		values["PATH"] = path.joined(separator: ":")
		return LoginEnvironment(values: values, fromShell: false)
	}

	/// The full path of `tool` in this PATH, or nil.
	public func which(_ tool: String) -> String? {
		for dir in (values["PATH"] ?? "").split(separator: ":") where dir.hasPrefix("/") { // never "." or relative
			let candidate = String(dir) + "/" + tool
			if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
		}
		return nil
	}
}

/// Output of the shell, written by the reader thread once.
nonisolated private final class OutputBuffer: @unchecked Sendable {
	private let lock = NSLock()
	private var _data = Data()
	var data: Data {
		get { lock.withLock { _data } }
		set { lock.withLock { _data = newValue } }
	}
}
