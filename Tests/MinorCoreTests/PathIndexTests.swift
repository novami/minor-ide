import Foundation
import Testing
@testable import MinorCore

struct PathIndexTests {
	private func rank(_ query: String, _ paths: [String]) -> [String] {
		let q = FuzzyQuery(query)
		return paths.compactMap { p in q.score(FuzzyPath(p)).map { (p, $0) } }
			.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.count < $1.0.count }.map(\.0)
	}

	@Test func ranksWordStartsCamelCaseAndFileNames() {
		let paths = ["app/UI/Home/HomePresenter.php", "app/Model/UserRepository.php", "vendor/nette/http/src/Http/Request.php",
		             "src/prettyHelper.php", "app/UI/Home/default.latte"]
		#expect(rank("hp", paths).first == "app/UI/Home/HomePresenter.php")
		#expect(rank("userrepo", paths) == ["app/Model/UserRepository.php"])
		#expect(rank("ur", paths).first == "app/Model/UserRepository.php")
		#expect(rank("home def", paths) == ["app/UI/Home/default.latte"])
		#expect(rank("xyz", paths).isEmpty)
		#expect(PathIndex.positions(of: "hp", in: "app/UI/Home/HomePresenter.php") == [12, 16])
	}

	@Test func buildsUpdatesAndPrefersRecentFiles() async throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("PathIndexTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let fm = FileManager.default
		try fm.createDirectory(at: root.appendingPathComponent("a/.git"), withIntermediateDirectories: true)
		try fm.createDirectory(at: root.appendingPathComponent("b"), withIntermediateDirectories: true)
		for f in ["a/main.go", "b/main.go", "a/.git/config"] { fm.createFile(atPath: root.appendingPathComponent(f).path, contents: Data()) }
		let index = PathIndex(root: root)
		index.build()
		await withCheckedContinuation { c in index.whenReady { c.resume() } }
		#expect(index.count == 2)
		#expect(index.search("main", recent: ["b/main.go"]).map(\.path) == ["b/main.go", "a/main.go"])
		#expect(index.search("", recent: ["b/main.go", "gone.go"]).map(\.path) == ["b/main.go"])

		try fm.removeItem(at: root.appendingPathComponent("a"))
		try fm.createDirectory(at: root.appendingPathComponent("c/d"), withIntermediateDirectories: true)
		fm.createFile(atPath: root.appendingPathComponent("c/d/x.php").path, contents: Data())
		index.update(changed: [root.appendingPathComponent("a").path, root.appendingPathComponent("c").path])
		await withCheckedContinuation { c in index.whenReady { c.resume() } }
		#expect(index.search("").isEmpty)
		#expect(index.search("m").map(\.path) == ["b/main.go"])
		#expect(index.search("x").map(\.path) == ["c/d/x.php"])
	}

	@Test func searchesTwentyThousandPathsQuickly() {
		var paths: [FuzzyPath] = []
		for i in 0..<20_000 { paths.append(FuzzyPath("vendor/package\(i % 300)/src/Module\(i % 41)/SomeClassName\(i).php")) }
		let q = FuzzyQuery("modclass12")
		let start = Date()
		var hits = 0
		for p in paths where q.score(p) != nil { hits += 1 }
		#expect(hits > 0)
		// Debug build; the release budget (50 ms from key press) is checked in the benchmark.
		#expect(Date().timeIntervalSince(start) < 1)
	}

	@Test func gitIgnorePatterns() {
		let g = GitIgnore("""
		# build
		/build/
		*.log
		!keep.log
		docs/**/*.tmp
		a?c
		[Tt]emp
		""")
		#expect(g.match("build", isDirectory: true) == true)
		#expect(g.match("src/build", isDirectory: true) == nil) // anchored
		#expect(g.match("build", isDirectory: false) == nil) // folders only
		#expect(g.match("x/y/error.log", isDirectory: false) == true)
		#expect(g.match("keep.log", isDirectory: false) == false)
		#expect(g.match("docs/a/b/c.tmp", isDirectory: false) == true)
		#expect(g.match("docs/c.tmp", isDirectory: false) == true)
		#expect(g.match("other/c.tmp", isDirectory: false) == nil)
		#expect(g.match("abc", isDirectory: false) == true)
		#expect(g.match("Temp", isDirectory: true) == true)
		#expect(g.match("tmp", isDirectory: true) == nil)
	}

	@Test func ignoredFilesRankLowerAndHiddenIgnoredFoldersAreSkipped() async throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("PathIndexIgnore-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let fm = FileManager.default
		for d in ["vendor/lib", ".build/out", "src"] { try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
		try "vendor/\n.build/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
		for f in ["vendor/lib/Router.php", ".build/out/Router.o", "src/RouterFactory.php"] { fm.createFile(atPath: root.appendingPathComponent(f).path, contents: Data()) }
		let index = PathIndex(root: root)
		index.build()
		await withCheckedContinuation { c in index.whenReady { c.resume() } }
		#expect(index.search("router").map(\.path) == ["src/RouterFactory.php", "vendor/lib/Router.php"])
	}
}
