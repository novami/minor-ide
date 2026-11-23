import Localization
import MinorCore
import SwiftUI
import UpdateKit

struct UpdatesSettingsView: View {
	let store: SettingsStore
	let updater: UpdateController

	private var availableInfo: UpdateInfo? {
		switch updater.state {
		case .available(let i), .downloading(let i, _), .ready(let i, _): i
		default: nil
		}
	}

	private var status: String {
		switch updater.state {
		case .idle: Strings.updates.statusIdle
		case .checking: Strings.updates.statusChecking
		case .upToDate: Strings.updates.statusUpToDate
		case .available: Strings.updates.statusAvailable
		case .downloading: Strings.updates.statusDownloading
		case .ready: Strings.updates.statusReady
		case .notConfigured: Strings.updates.statusNotConfigured
		case .failed: Strings.updates.statusFailed
		}
	}

	var body: some View {
		Form {
			Section {
				Toggle(Strings.updates.automaticCheck, isOn: Binding(
					get: { store.file.autoCheckUpdates ?? true },
					set: { store.set(nil, "auto_check_updates", .bool($0)); AppUpdater.reloadPreferences() }))
				Toggle(Strings.updates.automaticDownload, isOn: Binding(
					get: { store.file.autoDownloadUpdates ?? true },
					set: { store.set(nil, "auto_download_updates", .bool($0)); AppUpdater.reloadPreferences() }))
				Text(Strings.updates.automaticInfo).font(.callout).foregroundStyle(.secondary)
			}
			.disabled(store.unreadable)
			Section {
				LabeledContent(Strings.updates.currentVersion, value: updater.currentVersion)
				if let info = availableInfo {
					LabeledContent(Strings.updates.availableVersion, value: info.version)
				}
				if let date = updater.lastChecked {
					LabeledContent(Strings.updates.lastChecked, value: date.formatted(date: .abbreviated, time: .shortened))
				}
				if case .downloading(_, let progress) = updater.state {
					ProgressView(value: progress)
				}
				Text(status).font(.callout).foregroundStyle(.secondary)
				HStack {
					Button(Strings.updates.checkNow) { Task { await updater.check() } }
						.disabled(!updater.isConfigured || updater.state == .checking)
					if case .available = updater.state {
						Button(Strings.updates.downloadNow) { Task { await updater.downloadAvailable() } }
					}
				}
			}
			if let notes = availableInfo?.notes, !notes.isEmpty {
				Section(Strings.updates.releaseNotes) {
					Text((try? AttributedString(markdown: notes)) ?? AttributedString(notes))
				}
			}
		}
		.formStyle(.grouped)
	}
}
