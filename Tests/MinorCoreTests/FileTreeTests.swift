import Foundation
import XCTest
@testable import MinorIDE

final class FileTreeTests: XCTestCase {
	func testChildrenSortedHiddenSkippedAndNodesKeptOnReload() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("minoride-tree-\(UUID().uuidString)")
		let fm = FileManager.default
		for dir in ["src", "vendor", ".git"] { try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true) }
		for file in ["b.php", "a10.php", "a2.php", ".env", ".DS_Store", "src/User.php"] {
			try Data().write(to: root.appendingPathComponent(file))
		}
		defer { try? fm.removeItem(at: root) }
		let tree = FileNode(url: root, isDirectory: true)
		XCTAssertEqual(tree.children.map(\.name), ["src", "vendor", ".env", "a2.php", "a10.php", "b.php"])
		let src = tree.children[0]
		_ = src.children
		try Data().write(to: root.appendingPathComponent("c.php"))
		XCTAssertTrue(tree.reload())
		XCTAssertTrue(tree.children[0] === src && src.isLoaded)
		XCTAssertEqual(tree.node(for: root.appendingPathComponent("src/User.php"))?.name, "User.php")
		XCTAssertNil(tree.loadedNode(for: root.appendingPathComponent("vendor/x")))
		XCTAssertFalse(tree.reload())
	}
}
