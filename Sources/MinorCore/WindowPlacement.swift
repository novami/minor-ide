import CoreGraphics
import Foundation

/// Where a window was: its normal frame (not zoomed, not full screen), whether it was zoomed
/// or in full screen, and on which display. Frames are in global screen coordinates.
public struct WindowPlacement: Codable, Sendable, Equatable {
	public var frame: CGRect
	public var zoomed: Bool
	public var fullScreen: Bool
	/// Stable display UUID, and that display's frame when saved (the arrangement may change).
	public var display: String?
	public var displayFrame: CGRect?
	public var used: Date

	public init(frame: CGRect, zoomed: Bool = false, fullScreen: Bool = false, display: String? = nil, displayFrame: CGRect? = nil, used: Date = Date()) {
		self.frame = frame
		self.zoomed = zoomed
		self.fullScreen = fullScreen
		self.display = display
		self.displayFrame = displayFrame
		self.used = used
	}

	public struct Display: Sendable, Equatable {
		public var id: String?
		public var frame: CGRect
		/// Without the menu bar and the Dock.
		public var visible: CGRect

		public init(id: String?, frame: CGRect, visible: CGRect) {
			self.id = id
			self.frame = frame
			self.visible = visible
		}
	}

	/// The frame to use on the displays connected now (the first is the main one): on the same
	/// display, wherever it is in the arrangement; without it centred on the main display.
	/// Always fits the visible area of its display.
	public func frame(on displays: [Display]) -> CGRect {
		guard let main = displays.first else { return frame }
		var rect = frame
		let target: Display
		if let same = displays.first(where: { $0.id != nil && $0.id == display }) {
			target = same
			if let old = displayFrame {
				rect.origin.x += same.frame.minX - old.minX
				rect.origin.y += same.frame.minY - old.minY
			}
		} else {
			target = main
			rect.origin = CGPoint(x: main.visible.midX - rect.width / 2, y: main.visible.midY - rect.height / 2)
		}
		let area = target.visible
		rect.size.width = min(rect.width, area.width)
		rect.size.height = min(rect.height, area.height)
		rect.origin.x = min(max(rect.minX, area.minX), area.maxX - rect.width)
		rect.origin.y = min(max(rect.minY, area.minY), area.maxY - rect.height)
		return rect.integral
	}
}

/// Window placements by key (a project's path, the welcome window), kept in user defaults;
/// the least recently used go beyond `limit`.
public struct WindowPlacements: @unchecked Sendable { // UserDefaults is thread-safe
	public let defaults: UserDefaults
	public let limit: Int
	static let key = "WindowPlacements"

	public init(defaults: UserDefaults = .standard, limit: Int = 100) {
		self.defaults = defaults
		self.limit = limit
	}

	public func placement(for name: String) -> WindowPlacement? {
		all()[name]
	}

	public func save(_ placement: WindowPlacement, for name: String) {
		var list = all()
		list[name] = placement
		if list.count > limit {
			for old in list.sorted(by: { $0.value.used < $1.value.used }).prefix(list.count - limit) { list[old.key] = nil }
		}
		if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: Self.key) }
	}

	private func all() -> [String: WindowPlacement] {
		guard let data = defaults.data(forKey: Self.key) else { return [:] }
		return (try? JSONDecoder().decode([String: WindowPlacement].self, from: data)) ?? [:]
	}
}
