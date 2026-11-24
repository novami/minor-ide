import Foundation
import XCTest
@testable import MinorIDE

final class LoginEnvironmentTests: XCTestCase {
	func testReadsChosenVariablesFromTheShellBetweenMarkers() throws {
		// An empty ZDOTDIR keeps the user's own startup files out; .zshrc printing is simulated.
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LoginEnvironmentTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		try Data("echo welcome\nexport PATH=/custom/bin:$PATH\nexport GOFLAGS=-mod=mod\nexport SECRET=x\n".utf8).write(to: dir.appendingPathComponent(".zshrc"))
		let env = LoginEnvironment.load(shell: "/bin/zsh", environment: ["ZDOTDIR": dir.path, "HOME": dir.path, "PATH": "/usr/bin:/bin"])
		XCTAssertTrue(env.fromShell)
		XCTAssertEqual(env.values["PATH"]?.hasPrefix("/custom/bin:"), true)
		XCTAssertEqual(env.values["GOFLAGS"], "-mod=mod")
		XCTAssertNil(env.values["SECRET"])
		XCTAssertEqual(env.which("ls"), "/bin/ls")
	}

	func testFallsBackWhenTheShellFails() {
		let env = LoginEnvironment.load(shell: "/nonexistent/shell", environment: ["PATH": "/usr/bin"])
		XCTAssertFalse(env.fromShell)
		XCTAssertEqual(env.values["PATH"]?.hasPrefix("/usr/bin:/opt/homebrew/bin"), true)
	}
}
