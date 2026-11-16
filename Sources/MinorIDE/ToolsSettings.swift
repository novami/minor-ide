import AppKit
import MinorCore
import SecretsKit
import SwiftUI

/// A tool from the plan's table of external tools.
struct ToolSpec: Sendable {
	let name: String
	let arguments: [String]
	let minimum: String?
	let purpose: String
	/// What to do when it is missing or too old.
	let hint: String

	static var all: [ToolSpec] {
		[
			ToolSpec(name: "git", arguments: ["--version"], minimum: "2.30", purpose: L("Git integration"),
			         hint: L("Install the Command Line Tools: xcode-select --install")),
			ToolSpec(name: "go", arguments: ["version"], minimum: "1.22", purpose: L("Go language features"),
			         hint: L("Install Go from go.dev or with Homebrew: brew install go")),
			ToolSpec(name: "gopls", arguments: ["version"], minimum: "0.16", purpose: L("Go code intelligence"),
			         hint: "go install golang.org/x/tools/gopls@latest"),
			ToolSpec(name: "dlv", arguments: ["version"], minimum: "1.22", purpose: L("Go debugging"),
			         hint: "go install github.com/go-delve/delve/cmd/dlv@latest"),
			ToolSpec(name: "php", arguments: ["--version"], minimum: "7.2", purpose: L("PHPStan and formatters"),
			         hint: L("Optional: PHP code intelligence in MinorIDE works without it.")),
			ToolSpec(name: "ssh", arguments: ["-V"], minimum: nil, purpose: L("SSH, SFTP and tunnels"), hint: L("Part of macOS.")),
			ToolSpec(name: "rsync", arguments: ["--version"], minimum: nil, purpose: L("Synchronization with servers"), hint: L("Part of macOS.")),
			ToolSpec(name: "docker", arguments: ["--version"], minimum: "24", purpose: L("PHP in a container"), hint: L("Optional.")),
		]
	}
}

/// The login shell environment (D22), loaded once at launch, and the tool checks.
@MainActor @Observable
final class ToolsModel {
	static let shared = ToolsModel()
	private(set) var environment: LoginEnvironment?
	private(set) var checks: [String: ToolCheck] = [:]
	private(set) var checking = false
	private var loading: Task<LoginEnvironment, Never>?

	/// Starts reading the shell environment in the background (at launch).
	func loadEnvironment() {
		guard loading == nil else { return }
		let task = Task.detached(priority: .utility) { LoginEnvironment.load() }
		loading = task
		Task { environment = await task.value }
	}

	/// Git with the login shell's PATH and environment; nil when git is not installed.
	func gitTool() async -> GitTool? {
		loadEnvironment()
		guard let env = await loading?.value, let path = env.which("git") else { return nil }
		var environment = ProcessInfo.processInfo.environment
		environment.merge(env.values) { $1 }
		return GitTool(path: path, environment: environment)
	}

	/// Checks every tool again, off the main thread.
	func refresh() {
		guard !checking else { return }
		checking = true
		loadEnvironment()
		let specs = ToolSpec.all.map { ($0.name, $0.arguments, $0.minimum) }
		Task {
			guard let env = await loading?.value else { return }
			environment = env
			var environment = ProcessInfo.processInfo.environment
			environment.merge(env.values) { $1 }
			let found = await Task.detached(priority: .userInitiated) { [environment] in
				specs.map { ToolCheck.run($0.0, arguments: $0.1, minimum: $0.2, environment: environment, which: env.which) }
			}.value
			checks = Dictionary(uniqueKeysWithValues: found.map { ($0.tool, $0) })
			checking = false
		}
	}
}

struct ToolsSettingsView: View {
	let model: ToolsModel

	var body: some View {
		Form {
			Section {
				ForEach(ToolSpec.all, id: \.name) { spec in
					ToolRow(spec: spec, check: model.checks[spec.name], checking: model.checking)
				}
			} footer: {
				if let env = model.environment, !env.fromShell {
					Text(L("Your shell’s PATH could not be read, so MinorIDE looks in /opt/homebrew/bin, /usr/local/bin and ~/go/bin too."))
				} else {
					Text(L("Tools are found with the PATH of your login shell. A missing tool only turns off what needs it."))
				}
			}
			Section {
				HStack {
					Spacer()
					Button(L("Check Again")) { model.refresh() }.disabled(model.checking)
				}
			}
		}
		.formStyle(.grouped)
		.frame(width: 520)
		.fixedSize(horizontal: false, vertical: true)
	}
}

struct ToolRow: View {
	let spec: ToolSpec
	let check: ToolCheck?
	let checking: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 3) {
			HStack {
				VStack(alignment: .leading, spacing: 1) {
					Text(spec.name).font(.body.monospaced())
					Text(spec.purpose).font(.callout).foregroundStyle(.secondary)
				}
				Spacer()
				status
			}
			if let check, check.status == .missing || check.status == .tooOld {
				Text(spec.hint).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
			}
		}
		.help(check?.path ?? "")
	}

	@ViewBuilder private var status: some View {
		switch check?.status {
		case nil:
			if checking { ProgressView().controlSize(.small) } else { Text("—").foregroundStyle(.secondary) }
		case .ok?:
			Label(check?.version ?? "", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
		case .unknownVersion?:
			Label(L("Installed"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
		case .tooOld?:
			Label(L("%@ (needs %@)", check?.version ?? "", spec.minimum ?? ""), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
		case .missing?:
			Label(L("Not found"), systemImage: "xmark.circle").foregroundStyle(.secondary)
		}
	}
}
