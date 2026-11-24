import XCTest
@testable import MinorIDE

final class NavigationHistoryTests: XCTestCase {
	/// Places are "file:line"; the same string is the same place.
	let same: (String, String) -> Bool = { $0 == $1 }

	func testBackAndForwardLikeABrowser() {
		var h = NavigationHistory<String>()
		_ = h.record("a:1", same: same) // a:1 → b:5
		_ = h.record("b:5", same: same) // b:5 → c:9
		XCTAssertEqual(h.goBack(from: "c:9", same: same).place, "b:5")
		XCTAssertEqual(h.goBack(from: "b:5", same: same).place, "a:1")
		XCTAssertNil(h.goBack(from: "a:1", same: same).place)
		XCTAssertEqual(h.goForward(from: "a:1", same: same).place, "b:5")
		XCTAssertEqual(h.goForward(from: "b:5", same: same).place, "c:9")
		// A new jump clears Forward and hands back what it dropped.
		_ = h.goBack(from: "c:9", same: same)
		XCTAssertEqual(h.record("b:5", same: same), ["c:9"])
		XCTAssertFalse(h.canGoForward)
	}

	func testSamePlacesCountOnceAndTheLimitHolds() {
		var h = NavigationHistory<String>(limit: 3)
		_ = h.record("a:1", same: same)
		XCTAssertEqual(h.record("a:1", same: same), ["a:1"]) // a jump from where the last one started
		XCTAssertEqual(h.goBack(from: "a:1", same: same).place, nil) // back to where you are: nothing
		for p in ["b", "c", "d"] { _ = h.record(p, same: same) }
		XCTAssertEqual(h.back, ["b", "c", "d"])
	}
}
