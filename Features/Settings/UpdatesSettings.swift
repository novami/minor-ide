import MinorUpdater
import SwiftUI

struct UpdatesSettingsView: View {
	@Bindable var updater: Updater

	private var status: String {
		switch updater.state {
		case .unavailable: Strings.updates.statusNotConfigured
		case .idle: Strings.updates.statusIdle
		case .checking: Strings.updates.statusChecking
		case .upToDate: Strings.updates.statusUpToDate
		case .available: Strings.updates.statusAvailable
		case .downloading: Strings.updates.statusDownloading
		case .failed: Strings.updates.statusFailed
		}
	}

	var body: some View {
		Form {
			Section {
				Toggle(Strings.updates.automaticCheck, isOn: $updater.automaticChecks)
					.disabled(!updater.isAvailable)
			}
			Section {
				LabeledContent(Strings.updates.currentVersion,
				               value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
				if case .available(let version, _) = updater.state {
					LabeledContent(Strings.updates.availableVersion, value: "\(version)")
				}
				Text(status).font(.callout).foregroundStyle(.secondary)
				if case .failed(let message) = updater.state { Text(message).font(.callout).foregroundStyle(.red) }
				if case .unavailable(let reason) = updater.state { Text(reason).font(.callout).foregroundStyle(.secondary) }
				HStack {
					Button(Strings.updates.checkNow) { Task { await updater.checkForUpdates() } }
						.disabled(!updater.isAvailable || updater.state == .checking)
					if case .available = updater.state {
						Button(Strings.updates.installNow) { Task { await updater.installUpdate() } }
					}
				}
			}
			if case .available(_, let notes?) = updater.state, !notes.isEmpty {
				Section(Strings.updates.releaseNotes) {
					Text((try? AttributedString(markdown: notes)) ?? AttributedString(notes))
				}
			}
		}
		.formStyle(.grouped)
	}
}
