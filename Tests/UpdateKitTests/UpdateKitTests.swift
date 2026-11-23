import CryptoKit
import Foundation
import Testing
@testable import UpdateKit

private struct FakeTransport: UpdateTransport {
	let feed: Data
	let archive: Data
	func fetchFeed(_ url: URL) async throws -> Data { feed }
	func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
		let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try archive.write(to: file)
		return file
	}
}

private func signedFeed(version: String, archive: Data, key: Curve25519.Signing.PrivateKey, appID: String = "app.test", url: String = "https://example.com/a.zip") -> Data {
	let digest = Data(SHA256.hash(data: archive))
	let hex = digest.map { String(format: "%02x", $0) }.joined()
	let message = UpdateVerifier.signedMessage(appID: appID, version: version, sha256Hex: hex)
	let signature = (try? key.signature(for: message).base64EncodedString()) ?? ""
	return Data(#"{"version":"\#(version)","url":"\#(url)","sha256":"\#(hex)","signature":"\#(signature)"}"#.utf8)
}

@Test func versionsCompareNumerically() {
	let a = AppVersion("1.10.0"), b = AppVersion("1.9.9"), c = AppVersion("1.2"), d = AppVersion("1.2.0")
	#expect(a != nil && b != nil && a.map { x in b.map { x > $0 } } == true)
	#expect(c == d)
	#expect(AppVersion("1.x") == nil)
}

@Test func feedRejectsHTTP() {
	let data = Data(#"{"version":"1.0","url":"http://example.com/a.zip","sha256":"\#(String(repeating: "a", count: 64))","signature":""}"#.utf8)
	#expect(throws: UpdateInfo.FeedError.insecureURL) { try UpdateInfo.parse(data) }
}

@Test func defaultsAreOn() {
	let p = UpdatePreferences()
	#expect(p.autoCheck && p.autoDownload)
}

@MainActor @Test func autoDownloadVerifiesAndIsReady() async throws {
	let key = Curve25519.Signing.PrivateKey()
	let archive = Data("archive".utf8)
	let c = UpdateController(appID: "app.test", currentVersion: "0.1.0", feedURL: URL(string: "https://example.com/feed.json"),
	                         publicKey: key.publicKey.rawRepresentation,
	                         transport: FakeTransport(feed: signedFeed(version: "0.2.0", archive: archive, key: key), archive: archive))
	await c.check()
	guard case .ready(let info, _) = c.state else { Issue.record("state \(c.state)"); return }
	#expect(info.version == "0.2.0")
}

@MainActor @Test func withoutAutoDownloadWaitsForUser() async throws {
	let key = Curve25519.Signing.PrivateKey()
	let archive = Data("archive".utf8)
	let c = UpdateController(appID: "app.test", currentVersion: "0.1.0", feedURL: URL(string: "https://example.com/feed.json"),
	                         publicKey: key.publicKey.rawRepresentation, preferences: .init(autoCheck: true, autoDownload: false),
	                         transport: FakeTransport(feed: signedFeed(version: "0.2.0", archive: archive, key: key), archive: archive))
	await c.check()
	guard case .available = c.state else { Issue.record("state \(c.state)"); return }
	await c.downloadAvailable()
	guard case .ready = c.state else { Issue.record("state \(c.state)"); return }
}

@MainActor @Test func tamperedArchiveIsRejected() async throws {
	let key = Curve25519.Signing.PrivateKey()
	let c = UpdateController(appID: "app.test", currentVersion: "0.1.0", feedURL: URL(string: "https://example.com/feed.json"),
	                         publicKey: key.publicKey.rawRepresentation,
	                         transport: FakeTransport(feed: signedFeed(version: "0.2.0", archive: Data("good".utf8), key: key), archive: Data("evil".utf8)))
	await c.check()
	guard case .failed = c.state else { Issue.record("state \(c.state)"); return }
}

@MainActor @Test func wrongKeyIsRejected() async throws {
	let archive = Data("archive".utf8)
	let c = UpdateController(appID: "app.test", currentVersion: "0.1.0", feedURL: URL(string: "https://example.com/feed.json"),
	                         publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
	                         transport: FakeTransport(feed: signedFeed(version: "0.2.0", archive: archive, key: Curve25519.Signing.PrivateKey()), archive: archive))
	await c.check()
	guard case .failed = c.state else { Issue.record("state \(c.state)"); return }
}

@MainActor @Test func notConfiguredDoesNothing() async {
	let c = UpdateController(appID: "app.test", currentVersion: "0.1.0", feedURL: nil, publicKey: Data(), transport: FakeTransport(feed: Data(), archive: Data()))
	await c.check()
	#expect(c.state == .notConfigured)
}

@MainActor @Test func archiveSignedForAnotherAppIsRejected() async throws {
	let key = Curve25519.Signing.PrivateKey()
	let archive = Data("archive".utf8)
	let c = UpdateController(appID: "app.test", currentVersion: "0.1.0", feedURL: URL(string: "https://example.com/feed.json"),
	                         publicKey: key.publicKey.rawRepresentation,
	                         transport: FakeTransport(feed: signedFeed(version: "0.2.0", archive: archive, key: key, appID: "app.other"), archive: archive))
	await c.check()
	guard case .failed = c.state else { Issue.record("state \(c.state)"); return }
}

// MARK: Installer

private func makeApp(at dir: URL, id: String, version: String, marker: String) throws -> URL {
	let app = dir.appendingPathComponent("T.app")
	try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
	let plist: NSDictionary = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version]
	plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
	try Data(marker.utf8).write(to: app.appendingPathComponent("Contents/marker"))
	return app
}

private func zip(_ app: URL, to zip: URL) throws {
	let p = Process()
	p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
	p.arguments = ["-c", "-k", "--keepParent", app.path, zip.path]
	try p.run(); p.waitUntilExit()
}

private func info(_ version: String) -> UpdateInfo {
	let json = #"{"version":"\#(version)","url":"https://example.com/a.zip","sha256":"\#(String(repeating: "a", count: 64))","signature":""}"#
	return (try? UpdateInfo.parse(Data(json.utf8))) ?? { fatalError() }()
}

@Test func installSwapsTheBundle() throws {
	let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
	let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
	try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
	try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
	let fresh = try makeApp(at: src, id: "app.test", version: "0.2.0", marker: "new")
	let current = try makeApp(at: dst, id: "app.test", version: "0.1.0", marker: "old")
	let archive = root.appendingPathComponent("a.zip")
	try zip(fresh, to: archive)
	try UpdateInstaller.install(archive: archive, info: info("0.2.0"), appID: "app.test", currentVersion: "0.1.0",
	                            currentApp: current, checkCodeSignature: false)
	#expect(try String(contentsOf: current.appendingPathComponent("Contents/marker"), encoding: .utf8) == "new")
	#expect(try FileManager.default.contentsOfDirectory(atPath: dst.path) == ["T.app"]) // no backup left behind
}

@Test func installRejectsWrongAppAndKeepsCurrent() throws {
	let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
	let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
	try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
	try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
	let other = try makeApp(at: src, id: "app.other", version: "0.2.0", marker: "evil")
	let current = try makeApp(at: dst, id: "app.test", version: "0.1.0", marker: "old")
	let archive = root.appendingPathComponent("a.zip")
	try zip(other, to: archive)
	#expect(throws: UpdateInstaller.Failure.wrongApp) {
		try UpdateInstaller.install(archive: archive, info: info("0.2.0"), appID: "app.test", currentVersion: "0.1.0",
		                            currentApp: current, checkCodeSignature: false)
	}
	#expect(try String(contentsOf: current.appendingPathComponent("Contents/marker"), encoding: .utf8) == "old")
}

@Test func installRejectsNotNewer() {
	#expect(throws: UpdateInstaller.Failure.notNewer) {
		try UpdateInstaller.install(archive: URL(fileURLWithPath: "/x"), info: info("0.1.0"), appID: "a", currentVersion: "0.1.0",
		                            currentApp: URL(fileURLWithPath: "/y"))
	}
}
