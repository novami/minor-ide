import XCTest
@testable import MinorIDE

final class NavigationTests: XCTestCase {
	let range: JSONValue = ["start": ["line": 1, "character": 2], "end": ["line": 1, "character": 5]]
	let nameRange: JSONValue = ["start": ["line": 3, "character": 5], "end": ["line": 3, "character": 8]]

	func testLocationsFromEveryResultShape() {
		let expected = Location(uri: "file:///a.go", range: LSPRange(range)!)
		XCTAssertTrue(Location.list(.null).isEmpty)
		XCTAssertEqual(Location.list(["uri": "file:///a.go", "range": range]), [expected])
		XCTAssertEqual(Location.list([["uri": "file:///a.go", "range": range]]), [expected])
		// A link points at the declaration's name.
		let link: JSONValue = ["targetUri": "file:///b.go", "targetRange": range, "targetSelectionRange": nameRange]
		XCTAssertEqual(Location.list([link]), [Location(uri: "file:///b.go", range: LSPRange(nameRange)!)])
		XCTAssertEqual(Location.list([link]).first?.url?.path, "/b.go")
	}
}
