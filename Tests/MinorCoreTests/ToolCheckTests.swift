import Foundation
import Testing
@testable import MinorCore

struct ToolCheckTests {
	@Test func readsAndComparesVersions() {
		#expect(ToolCheck.firstVersion(in: "go version go1.22.5 darwin/arm64") == "1.22.5")
		#expect(ToolCheck.firstVersion(in: "OpenSSH_9.8p1, LibreSSL 3.3.6") == "9.8")
		#expect(ToolCheck.compare("1.10", "1.9") == 1)
		#expect(ToolCheck.compare("2.30", "2.30.0") == 0)

		let env = ["PATH": "/usr/bin:/bin"]
		let old = ToolCheck.run("fake", arguments: ["-c", "echo fake version 1.9.2 >&2"], minimum: "1.22", environment: env) { _ in "/bin/sh" }
		#expect(old.status == .tooOld)
		#expect(old.version == "1.9.2")
		#expect(ToolCheck.run("none", arguments: [], minimum: nil, environment: env) { _ in nil }.status == .missing)
	}
}
