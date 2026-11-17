import Testing
@testable import MinorCore

struct NavigationHistoryTests {
	/// Places are "file:line"; the same string is the same place.
	let same: (String, String) -> Bool = { $0 == $1 }

	@Test func backAndForwardLikeABrowser() {
		var h = NavigationHistory<String>()
		_ = h.record("a:1", same: same) // a:1 → b:5
		_ = h.record("b:5", same: same) // b:5 → c:9
		#expect(h.goBack(from: "c:9", same: same).place == "b:5")
		#expect(h.goBack(from: "b:5", same: same).place == "a:1")
		#expect(h.goBack(from: "a:1", same: same).place == nil)
		#expect(h.goForward(from: "a:1", same: same).place == "b:5")
		#expect(h.goForward(from: "b:5", same: same).place == "c:9")
		// A new jump clears Forward and hands back what it dropped.
		_ = h.goBack(from: "c:9", same: same)
		#expect(h.record("b:5", same: same) == ["c:9"])
		#expect(!h.canGoForward)
	}

	@Test func samePlacesCountOnceAndTheLimitHolds() {
		var h = NavigationHistory<String>(limit: 3)
		_ = h.record("a:1", same: same)
		#expect(h.record("a:1", same: same) == ["a:1"]) // a jump from where the last one started
		#expect(h.goBack(from: "a:1", same: same).place == nil) // back to where you are: nothing
		for p in ["b", "c", "d"] { _ = h.record(p, same: same) }
		#expect(h.back == ["b", "c", "d"])
	}
}
