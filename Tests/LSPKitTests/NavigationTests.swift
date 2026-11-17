import Testing
import MinorCore
@testable import LSPKit

struct NavigationTests {
	let range: JSONValue = ["start": ["line": 1, "character": 2], "end": ["line": 1, "character": 5]]
	let name: JSONValue = ["start": ["line": 3, "character": 5], "end": ["line": 3, "character": 8]]

	@Test func locationsFromEveryResultShape() {
		let expected = Location(uri: "file:///a.go", range: LSPRange(range)!)
		#expect(Location.list(.null).isEmpty)
		#expect(Location.list(["uri": "file:///a.go", "range": range]) == [expected])
		#expect(Location.list([["uri": "file:///a.go", "range": range]]) == [expected])
		// A link points at the declaration's name.
		let link: JSONValue = ["targetUri": "file:///b.go", "targetRange": range, "targetSelectionRange": name]
		#expect(Location.list([link]) == [Location(uri: "file:///b.go", range: LSPRange(name)!)])
		#expect(Location.list([link]).first?.url?.path == "/b.go")
	}
}
