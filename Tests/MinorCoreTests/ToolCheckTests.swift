import Foundation
import XCTest
@testable import MinorIDE

final class ToolCheckTests: XCTestCase {
	func testReadsAndComparesVersions() {
		XCTAssertEqual(ToolCheck.firstVersion(in: "go version go1.22.5 darwin/arm64"), "1.22.5")
		XCTAssertEqual(ToolCheck.firstVersion(in: "OpenSSH_9.8p1, LibreSSL 3.3.6"), "9.8")
		XCTAssertEqual(ToolCheck.compare("1.10", "1.9"), 1)
		XCTAssertEqual(ToolCheck.compare("2.30", "2.30.0"), 0)

		let env = ["PATH": "/usr/bin:/bin"]
		let old = ToolCheck.run("fake", arguments: ["-c", "echo fake version 1.9.2 >&2"], minimum: "1.22", environment: env) { _ in "/bin/sh" }
		XCTAssertEqual(old.status, .tooOld)
		XCTAssertEqual(old.version, "1.9.2")
		XCTAssertEqual(ToolCheck.run("none", arguments: [], minimum: nil, environment: env) { _ in nil }.status, .missing)
	}
}
