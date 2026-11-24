import AppKit

/// Keeps a window's position, size, zoom and full screen under a name, and puts the window
/// back there the next time (also after quitting). Tabs of a group share one name.
@MainActor final class WindowFrameKeeper: NSObject {
	static let store = WindowPlacements()
	/// Off for the benchmark and snapshots, which must not move or remember windows.
	static var enabled = true

	let name: String
	private weak var window: NSWindow?
	/// The frame without zoom and full screen.
	private var normal: NSRect
	private var zoomed = false
	private var fullScreen = false
	private var enterFullScreen = false

	init(_ window: NSWindow, name: String) {
		self.window = window
		self.name = name
		normal = window.frame
		super.init()
		let center = NotificationCenter.default // selector observers go away with the object
		center.addObserver(self, selector: #selector(moved), name: NSWindow.didMoveNotification, object: window)
		center.addObserver(self, selector: #selector(resized), name: NSWindow.didResizeNotification, object: window)
		center.addObserver(self, selector: #selector(moved), name: NSWindow.didEndLiveResizeNotification, object: window)
		center.addObserver(self, selector: #selector(willEnterFullScreen), name: NSWindow.willEnterFullScreenNotification, object: window)
		center.addObserver(self, selector: #selector(didExitFullScreen), name: NSWindow.didExitFullScreenNotification, object: window)
	}

	@objc private func moved() { note() }
	@objc private func resized() { if window?.inLiveResize == false { note() } }
	@objc private func willEnterFullScreen() {
		fullScreen = true
		save()
	}
	@objc private func didExitFullScreen() {
		fullScreen = false
		note()
	}

	/// Moves the not yet shown window where it was last; false when nothing is saved.
	/// A window whose display is gone goes to the main display.
	func restore() -> Bool {
		guard Self.enabled, let window, var placement = Self.store.placement(for: name) else { return false }
		let resizable = window.styleMask.contains(.resizable)
		if !resizable { placement.frame.size = window.frame.size } // its content sets the size
		window.setFrame(placement.frame(on: Self.displays), display: false)
		normal = window.frame
		if placement.zoomed && resizable { window.zoom(nil) }
		zoomed = window.isZoomed
		enterFullScreen = placement.fullScreen && resizable
		return true
	}

	/// After the window is on screen: back to full screen if it was.
	func finishRestore() {
		guard enterFullScreen, let window, !window.styleMask.contains(.fullScreen) else { return }
		enterFullScreen = false
		// Right after ordering front the transition can stall halfway.
		DispatchQueue.main.async { [weak window] in
			if let window, !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
		}
	}

	private func note() {
		// A tab in the background has the group's frame but is not on screen.
		guard let window, window.isVisible, !fullScreen, !window.styleMask.contains(.fullScreen) else { return }
		zoomed = window.isZoomed
		if !zoomed { normal = window.frame }
		save()
	}

	private func save() {
		guard Self.enabled, let window else { return }
		let screen = window.screen ?? NSScreen.main
		Self.store.save(WindowPlacement(frame: normal, zoomed: zoomed, fullScreen: fullScreen,
		                                display: screen.flatMap(Self.id), displayFrame: screen?.frame), for: name)
	}

	/// Connected displays, the main one (with the menu bar) first.
	static var displays: [WindowPlacement.Display] {
		NSScreen.screens.map { WindowPlacement.Display(id: id($0), frame: $0.frame, visible: $0.visibleFrame) }
	}

	/// The display's UUID, which stays the same across launches and arrangements.
	static func id(_ screen: NSScreen) -> String? {
		guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
		      let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
		return CFUUIDCreateString(nil, uuid) as String
	}
}
