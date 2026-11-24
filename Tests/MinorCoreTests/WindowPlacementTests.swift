import CoreGraphics
import Foundation
import XCTest
@testable import MinorIDE

final class WindowPlacementTests: XCTestCase {
	let main = WindowPlacement.Display(id: "A", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
	                                   visible: CGRect(x: 0, y: 0, width: 1920, height: 1050))
	let side = WindowPlacement.Display(id: "B", frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440),
	                                   visible: CGRect(x: 1920, y: 0, width: 2560, height: 1440))

	func testStaysOnItsDisplayWhereverTheArrangementPutsIt() {
		let placement = WindowPlacement(frame: CGRect(x: 2020, y: 100, width: 1200, height: 900), display: "B", displayFrame: side.frame)
		XCTAssertEqual(placement.frame(on: [main, side]), CGRect(x: 2020, y: 100, width: 1200, height: 900))
		var left = side
		left.frame.origin.x = -2560
		left.visible.origin.x = -2560
		XCTAssertEqual(placement.frame(on: [main, left]), CGRect(x: -2460, y: 100, width: 1200, height: 900))
	}

	func testMissingDisplayMovesToMainAndFits() {
		let placement = WindowPlacement(frame: CGRect(x: 2020, y: 100, width: 2400, height: 1300), display: "B", displayFrame: side.frame)
		XCTAssertEqual(placement.frame(on: [main]), main.visible)
		let small = WindowPlacement(frame: CGRect(x: 2020, y: 100, width: 1000, height: 600), display: "B", displayFrame: side.frame)
		XCTAssertEqual(small.frame(on: [main]), CGRect(x: 460, y: 225, width: 1000, height: 600))
	}

	func testStoreKeepsTheMostRecentlyUsed() throws {
		let defaults = try XCTUnwrap(UserDefaults(suiteName: "WindowPlacementTests"))
		defaults.removePersistentDomain(forName: "WindowPlacementTests")
		let store = WindowPlacements(defaults: defaults, limit: 2)
		for (i, name) in ["a", "b", "c"].enumerated() {
			store.save(WindowPlacement(frame: CGRect(x: i, y: 0, width: 10, height: 10), zoomed: i == 2, used: Date(timeIntervalSince1970: Double(i))), for: name)
		}
		XCTAssertNil(store.placement(for: "a"))
		XCTAssertEqual(store.placement(for: "c")?.zoomed, true)
		defaults.removePersistentDomain(forName: "WindowPlacementTests")
	}
}
