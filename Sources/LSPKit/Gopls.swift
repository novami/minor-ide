import Foundation
import MinorCore

/// The Go language server (plan 3.3). gopls itself finds `go.work` and the modules of the
/// workspace (one view per module when there is no `go.work`), so the client only passes the
/// project folder.
public enum Gopls {
	public static let name = "gopls"
	/// Installs the newest release; run in the home folder so no project's go.mod applies.
	public static let installArguments = ["install", "golang.org/x/tools/gopls@latest"]

	/// Answer to `workspace/configuration` (section "gopls").
	public static let settings: JSONValue = ["gopls": initializationOptions]
	public static let initializationOptions: JSONValue = ["staticcheck": true, "semanticTokens": true]

	/// Language identifier of a file gopls handles, nil for other files.
	public static func languageID(forPath path: String) -> String? {
		let name = (path as NSString).lastPathComponent
		switch name {
		case "go.mod": return "go.mod"
		case "go.sum": return "go.sum"
		case "go.work": return "go.work"
		default: return name.hasSuffix(".go") ? "go" : nil
		}
	}

	/// gopls in the PATH, else where `go install` puts it: `$GOBIN`, the first `$GOPATH/bin`,
	/// `~/go/bin`.
	public static func locate(which: (String) -> String?, environment: [String: String], home: String,
	                          isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String? {
		if let path = which(name) { return path }
		var folders: [String] = []
		if let bin = environment["GOBIN"], bin.hasPrefix("/") { folders.append(bin) }
		if let first = environment["GOPATH"]?.split(separator: ":").first, first.hasPrefix("/") {
			folders.append(first + "/bin")
		}
		folders.append(home + "/go/bin")
		return folders.map { $0 + "/" + name }.first(where: isExecutable)
	}
}

/// Work-done progress of one server, reduced to one line for the status bar: the most recent
/// task still running.
public struct ProgressTracker: Sendable, Equatable {
	private struct Task: Sendable, Equatable {
		var title: String
		var message: String?
		var percentage: Int?
	}

	private var tasks: [(token: String, task: Task)] = []

	public init() {}

	public var isActive: Bool { !tasks.isEmpty }

	public mutating func apply(_ event: ProgressEvent) {
		let index = tasks.firstIndex { $0.token == event.token }
		switch event.kind {
		case .begin:
			let task = Task(title: event.title ?? "", message: event.message, percentage: event.percentage)
			if let index { tasks.remove(at: index) }
			tasks.append((event.token, task))
		case .report:
			guard let index else { return }
			if let message = event.message { tasks[index].task.message = message }
			if let percentage = event.percentage { tasks[index].task.percentage = percentage }
		case .end:
			if let index { tasks.remove(at: index) }
		}
	}

	public mutating func reset() { tasks = [] }

	/// "Title: message 40 %" of the newest task, nil when nothing runs.
	public var text: String? {
		guard let task = tasks.last?.task else { return nil }
		var text = task.title
		if let message = task.message, !message.isEmpty { text += text.isEmpty ? message : ": " + message }
		if let percentage = task.percentage { text += " \(percentage) %" }
		return text
	}

	public static func == (a: ProgressTracker, b: ProgressTracker) -> Bool {
		a.tasks.map(\.token) == b.tasks.map(\.token) && a.tasks.map(\.task) == b.tasks.map(\.task)
	}
}
