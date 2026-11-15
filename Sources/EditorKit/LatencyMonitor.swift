import AppKit
import QuartzCore

/// Key-to-frame latency. A key event's time is kept until the run loop pass that handled it
/// has committed its Core Animation transaction; the view's display link (macOS 14) then
/// gives the frame that shows the change. Opt-in: the
/// editor reports to it only when `EditorView.latencyMonitor` is set.
@MainActor
public final class LatencyMonitor: NSObject {
	/// Key event to the end of the Core Animation commit: the app's own work.
	public private(set) var commits: [Double] = []
	/// Key event to the display frame that shows the change. Empty while the window is not
	/// on a lit, unlocked screen: display links pause for occluded windows.
	public private(set) var frames: [Double] = []
	/// Display frame duration seen by the display link (1/60 s until the first frame).
	public private(set) var frameInterval = 1.0 / 60
	/// Called with each key-to-frame latency.
	public var onFrame: ((Double) -> Void)?

	private weak var view: NSView?
	private var link: CADisplayLink?
	private var observer: CFRunLoopObserver?
	private var waiting: [TimeInterval] = []      // key events not yet committed
	private var committed: [(key: TimeInterval, commit: TimeInterval)] = []
	private static let limit = 10_000

	public init(view: NSView) {
		self.view = view
	}

	/// Called before the key event is handled. `timestamp` is NSEvent.timestamp (system uptime).
	func keyDown(at timestamp: TimeInterval) {
		if observer == nil {
			// Core Animation commits in a before-waiting observer of order 2 000 000; this one runs after it.
			observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_100_000) { [weak self] _, _ in
				MainActor.assumeIsolated { self?.didCommit() }
			}
			CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
		}
		waiting.append(timestamp)
	}

	isolated deinit {
		link?.invalidate()
		if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
	}

	private func didCommit() {
		guard !waiting.isEmpty else { return }
		let now = CACurrentMediaTime()
		committed.removeAll { now - $0.commit > 0.5 } // never shown: the window is occluded
		committed += waiting.map { ($0, now) }
		append(waiting.map { now - $0 }, to: &commits)
		waiting.removeAll()
		if link == nil, let view {
			link = view.displayLink(target: WeakTarget(self), selector: #selector(WeakTarget.frame(_:)))
			link?.add(to: .main, forMode: .common)
		}
		link?.isPaused = false
	}

	fileprivate func frame(_ link: CADisplayLink) {
		frameInterval = link.targetTimestamp - link.timestamp
		let latencies = committed.map { link.targetTimestamp - $0.key }
		append(latencies, to: &frames)
		latencies.forEach { onFrame?($0) }
		committed.removeAll()
		link.isPaused = true
	}

	private func append(_ values: [Double], to list: inout [Double]) {
		if list.count >= Self.limit { list.removeFirst(list.count / 2) }
		list += values
	}
}

/// The display link retains its target; this keeps the monitor itself free to go away.
@MainActor
private final class WeakTarget: NSObject {
	weak var monitor: LatencyMonitor?
	init(_ monitor: LatencyMonitor) { self.monitor = monitor }
	@objc func frame(_ link: CADisplayLink) { monitor?.frame(link) }
}
