import Foundation
import Testing
@testable import MinorCore

struct GitHeadTests {
	@Test func parsesBranchAndDetachedHead() {
		#expect(GitHead.parse("ref: refs/heads/feature/x\n") == .branch("feature/x"))
		let hash = "3aac2b8f0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f"
		#expect(GitHead.parse(hash + "\n")?.label == "3aac2b8")
		#expect(GitHead.parse("garbage") == nil)
	}

	@Test func findsRepositoryAboveAndThroughGitFile() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitHeadTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let sub = root.appendingPathComponent("repo/app/src")
		try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
		let git = root.appendingPathComponent("repo/.git")
		try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
		try "ref: refs/heads/main\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
		#expect(GitHead.read(for: sub) == .branch("main"))

		// Worktree: `.git` is a file pointing to the real Git directory.
		let worktree = root.appendingPathComponent("wt")
		let wtGit = git.appendingPathComponent("worktrees/wt")
		try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: wtGit, withIntermediateDirectories: true)
		try "ref: refs/heads/topic\n".write(to: wtGit.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
		try "gitdir: ../repo/.git/worktrees/wt\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
		#expect(GitHead.read(for: worktree) == .branch("topic"))
	}

	@Test func stopsAtTheRootOutsideRepositories() {
		// The temporary folder is not in a repository; its URL's parents end in "/..".
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("no-repo-\(UUID().uuidString)")
		#expect(GitHead.gitDirectory(for: folder) == nil)
	}
}

struct GitAddressTests {
	@Test func acceptsRemoteAddressesOnly() {
		for ok in ["https://github.com/a/b.git", "ssh://git@host:22/a/b", "git@github.com:a/b.git", "host:repo"] { #expect(GitAddress.isValid(ok)) }
		for bad in ["", "-uhttps://x", "ext::sh -c touch", "file:///tmp/x", "/tmp/repo", "https://", "a b:c"] { #expect(!GitAddress.isValid(bad)) }
		#expect(GitAddress.folderName(for: "https://github.com/a/minor-ide.git/") == "minor-ide")
		#expect(GitAddress.folderName(for: "git@github.com:a/b.git") == "b")
	}
}

struct GitToolTests {
	@Test func readsCommittedContentsAndNothingForUntrackedFiles() throws {
		guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return }
		let git = GitTool(path: "/usr/bin/git", environment: ProcessInfo.processInfo.environment)
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitToolTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
		let file = root.appendingPathComponent("src/a.txt")
		try "committed\n".write(to: file, atomically: true, encoding: .utf8)
		for args in [["init", "-q"], ["add", "."], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "x"]] {
			#expect(git.run(args, in: root)?.status == 0)
		}
		try "changed\n".write(to: file, atomically: true, encoding: .utf8)
		#expect(git.headContents(of: file) == Data("committed\n".utf8))
		let untracked = root.appendingPathComponent("src/new.txt")
		try "x".write(to: untracked, atomically: true, encoding: .utf8)
		#expect(git.headContents(of: untracked) == nil)
	}
}
