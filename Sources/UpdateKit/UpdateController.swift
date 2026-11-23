import Foundation
import Observation

/// What the user chose in Settings › Updates. Both default to on.
public struct UpdatePreferences: Sendable, Equatable {
	public var autoCheck: Bool
	public var autoDownload: Bool
	public init(autoCheck: Bool = true, autoDownload: Bool = true) {
		self.autoCheck = autoCheck
		self.autoDownload = autoDownload
	}
}

public enum UpdateState: Sendable, Equatable {
	case idle
	case checking
	case upToDate
	case available(UpdateInfo)
	case downloading(UpdateInfo, progress: Double)
	/// Archive downloaded and its signature verified.
	case ready(UpdateInfo, file: URL)
	case installing(UpdateInfo)
	/// The new version is in place; the app must restart to use it.
	case installed(UpdateInfo)
	case notConfigured
	case failed(String)
}

/// Network access behind the controller, replaced in tests.
public protocol UpdateTransport: Sendable {
	func fetchFeed(_ url: URL) async throws -> Data
	/// Downloads to a temporary file and reports progress in 0...1.
	func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

@MainActor @Observable
public final class UpdateController {
	public private(set) var state: UpdateState = .idle
	public var preferences: UpdatePreferences
	public let currentVersion: String
	public let appID: String
	public private(set) var lastChecked: Date?

	private let feedURL: URL?
	private let publicKey: Data
	private let transport: UpdateTransport
	private var loop: Task<Void, Never>?

	/// `feedURL` or `publicKey` empty means the release infrastructure is not set up: nothing is
	/// checked and the state is `.notConfigured`.
	public init(appID: String, currentVersion: String, feedURL: URL?, publicKey: Data, preferences: UpdatePreferences = .init(), transport: UpdateTransport) {
		self.appID = appID
		self.currentVersion = currentVersion
		self.feedURL = feedURL
		self.publicKey = publicKey
		self.preferences = preferences
		self.transport = transport
		if feedURL == nil || publicKey.isEmpty { state = .notConfigured }
	}

	public var isConfigured: Bool { feedURL != nil && !publicKey.isEmpty }

	/// Checks the feed. Automatic checks also download when allowed; a manual check
	/// downloads only when the user later asks (`downloadAvailable`) or the preference is on.
	public func check() async {
		guard let feedURL, isConfigured else { state = .notConfigured; return }
		if case .checking = state { return }
		if case .downloading = state { return }
		state = .checking
		do {
			let info = try UpdateInfo.parse(try await transport.fetchFeed(feedURL))
			lastChecked = Date()
			guard let latest = AppVersion(info.version), let current = AppVersion(currentVersion), current < latest else {
				state = .upToDate
				return
			}
			state = .available(info)
			if preferences.autoDownload { await downloadAvailable() }
		} catch {
			state = .failed("\(error)")
		}
	}

	/// Downloads and verifies the offered update.
	public func downloadAvailable() async {
		guard case .available(let info) = state else { return }
		state = .downloading(info, progress: 0)
		do {
			let file = try await transport.download(info.url) { [weak self] value in
				Task { @MainActor in
					if case .downloading(let i, _)? = self?.state { self?.state = .downloading(i, progress: value) }
				}
			}
			do {
				try UpdateVerifier.verify(file: file, info: info, appID: appID, publicKey: publicKey)
			} catch {
				try? FileManager.default.removeItem(at: file)
				throw error
			}
			state = .ready(info, file: file)
		} catch {
			state = .failed("\(error)")
		}
	}

	/// Replaces `currentApp` with the downloaded, verified update. The caller restarts the app.
	@discardableResult
	public func install(currentApp: URL, checkCodeSignature: Bool = true) -> Bool {
		guard case .ready(let info, let file) = state else { return false }
		state = .installing(info)
		do {
			try UpdateInstaller.install(archive: file, info: info, appID: appID, currentVersion: currentVersion,
			                            currentApp: currentApp, checkCodeSignature: checkCodeSignature)
			try? FileManager.default.removeItem(at: file)
			state = .installed(info)
			return true
		} catch {
			state = .failed("\(error)")
			return false
		}
	}

	/// Starts the periodic check: shortly after launch, then every `interval`. The preference is
	/// read on every round, so turning it off takes effect without a restart.
	public func startAutomaticChecks(delay: Duration = .seconds(30), interval: Duration = .seconds(24 * 3600)) {
		loop?.cancel()
		loop = Task { [weak self] in
			try? await Task.sleep(for: delay)
			while !Task.isCancelled {
				if let self, self.preferences.autoCheck { await self.check() }
				try? await Task.sleep(for: interval)
			}
		}
	}

	public func stopAutomaticChecks() { loop?.cancel(); loop = nil }
}

/// HTTPS-only transport over URLSession.
public struct URLSessionTransport: UpdateTransport {
	public init() {}

	public func fetchFeed(_ url: URL) async throws -> Data {
		guard url.scheme == "https" else { throw UpdateInfo.FeedError.insecureURL }
		var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		let (data, response) = try await URLSession.shared.data(for: request)
		guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1 << 20 else { throw UpdateInfo.FeedError.invalid }
		return data
	}

	public func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
		guard url.scheme == "https" else { throw UpdateInfo.FeedError.insecureURL }
		let (temp, response) = try await URLSession.shared.download(from: url)
		guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateInfo.FeedError.invalid }
		let target = FileManager.default.temporaryDirectory.appendingPathComponent("minoride-update-\(UUID().uuidString)")
		try FileManager.default.moveItem(at: temp, to: target)
		progress(1)
		return target
	}
}
