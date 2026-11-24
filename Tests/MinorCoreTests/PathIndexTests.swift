import Foundation
import XCTest
@testable import MinorIDE

final class PathIndexTests: XCTestCase {
	private func rank(_ query: String, _ paths: [String]) -> [String] {
		let q = FuzzyQuery(query)
		return paths.compactMap { p in q.score(FuzzyPath(p)).map { (p, $0) } }
			.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.count < $1.0.count }.map(\.0)
	}

	func testRanksWordStartsCamelCaseAndFileNames() {
		let paths = ["app/UI/Home/HomePresenter.php", "app/Model/UserRepository.php", "vendor/nette/http/src/Http/Request.php",
		             "src/prettyHelper.php", "app/UI/Home/default.latte"]
		XCTAssertEqual(rank("hp", paths).first, "app/UI/Home/HomePresenter.php")
		XCTAssertEqual(rank("userrepo", paths), ["app/Model/UserRepository.php"])
		XCTAssertEqual(rank("ur", paths).first, "app/Model/UserRepository.php")
		XCTAssertEqual(rank("home def", paths), ["app/UI/Home/default.latte"])
		XCTAssertTrue(rank("xyz", paths).isEmpty)
		XCTAssertEqual(PathIndex.positions(of: "hp", in: "app/UI/Home/HomePresenter.php"), [12, 16])
	}

	func testBuildsUpdatesAndPrefersRecentFiles() async throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("PathIndexTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let fm = FileManager.default
		try fm.createDirectory(at: root.appendingPathComponent("a/.git"), withIntermediateDirectories: true)
		try fm.createDirectory(at: root.appendingPathComponent("b"), withIntermediateDirectories: true)
		for f in ["a/main.go", "b/main.go", "a/.git/config"] { fm.createFile(atPath: root.appendingPathComponent(f).path, contents: Data()) }
		let index = PathIndex(root: root)
		index.build()
		await withCheckedContinuation { c in index.whenReady { c.resume() } }
		XCTAssertEqual(index.count, 2)
		XCTAssertEqual(index.search("main", recent: ["b/main.go"]).map(\.path), ["b/main.go", "a/main.go"])
		XCTAssertEqual(index.search("", recent: ["b/main.go", "gone.go"]).map(\.path), ["b/main.go"])

		try fm.removeItem(at: root.appendingPathComponent("a"))
		try fm.createDirectory(at: root.appendingPathComponent("c/d"), withIntermediateDirectories: true)
		fm.createFile(atPath: root.appendingPathComponent("c/d/x.php").path, contents: Data())
		index.update(changed: [root.appendingPathComponent("a").path, root.appendingPathComponent("c").path])
		await withCheckedContinuation { c in index.whenReady { c.resume() } }
		XCTAssertTrue(index.search("").isEmpty)
		XCTAssertEqual(index.search("m").map(\.path), ["b/main.go"])
		XCTAssertEqual(index.search("x").map(\.path), ["c/d/x.php"])
	}

	func testSearchesTwentyThousandPathsQuickly() {
		var paths: [FuzzyPath] = []
		for i in 0..<20_000 { paths.append(FuzzyPath("vendor/package\(i % 300)/src/Module\(i % 41)/SomeClassName\(i).php")) }
		let q = FuzzyQuery("modclass12")
		let start = Date()
		var hits = 0
		for p in paths where q.score(p) != nil { hits += 1 }
		XCTAssertTrue(hits > 0)
		// Debug build; the release budget (50 ms from key press) is checked in the benchmark.
		XCTAssertTrue(Date().timeIntervalSince(start) < 1)
	}

	func testGitIgnorePatterns() {
		let g = GitIgnore("""
		# build
		/build/
		*.log
		!keep.log
		docs/**/*.tmp
		a?c
		[Tt]emp
		""")
		XCTAssertEqual(g.match("build", isDirectory: true), true)
		XCTAssertEqual(g.match("src/build", isDirectory: true), nil) // anchored
		XCTAssertEqual(g.match("build", isDirectory: false), nil) // folders only
		XCTAssertEqual(g.match("x/y/error.log", isDirectory: false), true)
		XCTAssertEqual(g.match("keep.log", isDirectory: false), false)
		XCTAssertEqual(g.match("docs/a/b/c.tmp", isDirectory: false), true)
		XCTAssertEqual(g.match("docs/c.tmp", isDirectory: false), true)
		XCTAssertNil(g.match("other/c.tmp", isDirectory: false))
		XCTAssertEqual(g.match("abc", isDirectory: false), true)
		XCTAssertEqual(g.match("Temp", isDirectory: true), true)
		XCTAssertNil(g.match("tmp", isDirectory: true))
	}

	func testIgnoredFilesRankLowerAndHiddenIgnoredFoldersAreSkipped() async throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("PathIndexIgnore-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let fm = FileManager.default
		for d in ["vendor/lib", ".build/out", "src"] { try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
		try "vendor/\n.build/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
		for f in ["vendor/lib/Router.php", ".build/out/Router.o", "src/RouterFactory.php"] { fm.createFile(atPath: root.appendingPathComponent(f).path, contents: Data()) }
		let index = PathIndex(root: root)
		index.build()
		await withCheckedContinuation { c in index.whenReady { c.resume() } }
		XCTAssertEqual(index.search("router").map(\.path), ["src/RouterFactory.php", "vendor/lib/Router.php"])
	}
}
