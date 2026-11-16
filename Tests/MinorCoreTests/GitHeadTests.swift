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
}
