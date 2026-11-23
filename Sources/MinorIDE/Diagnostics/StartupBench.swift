import AppKit
import QuartzCore

/// Spike S3 (`--bench-startup`): time from process start to the first window, time to render
/// the welcome window (stand-in for the Dashboard until it exists), and the idle memory
/// footprint. Prints one `key: value` line per metric, then quits.
@MainActor
enum StartupBench {
	private static var finishedLaunching: Double?
	private static var setupDone: Double?

	/// Start of applicationDidFinishLaunching: dyld, static init and AppKit launch are behind.
	static func markFinishedLaunching() { finishedLaunching = secondsSinceProcessStart() }
	/// End of the app's own setup (menu, settings, watchers) before the first window.
	static func markSetupDone() { setupDone = secondsSinceProcessStart() }

	static func run(_ app: AppDelegate) {
		// The welcome window is what a launch without a session shows first.
		let welcomeStart = CACurrentMediaTime()
		app.showWelcome(nil)
		flush()
		let welcome = CACurrentMediaTime() - welcomeStart
		if let finishedLaunching { print(String(format: "launch_to_did_finish_ms: %.1f", finishedLaunching * 1000)) }
		if let setupDone { print(String(format: "launch_to_setup_done_ms: %.1f", setupDone * 1000)) }
		if let launch = secondsSinceProcessStart() { print(String(format: "launch_to_window_ms: %.1f", launch * 1000)) }
		print(String(format: "welcome_render_ms: %.1f", welcome * 1000))

		let editorStart = CACurrentMediaTime()
		app.openWindow(text: "", title: "bench")
		flush()
		print(String(format: "editor_window_ms: %.1f", (CACurrentMediaTime() - editorStart) * 1000))
		print(String(format: "footprint_after_launch_mb: %.1f", footprintMB()))

		// Idle: let timers, deferred work and autorelease pools settle before sampling.
		let idle = ProcessInfo.processInfo.environment["MINORIDE_IDLE_SECONDS"].flatMap(Double.init) ?? 5
		RunLoop.main.run(until: Date().addingTimeInterval(idle))
		print(String(format: "footprint_idle_mb: %.1f", footprintMB()))
		NSApp.terminate(nil)
	}

	/// Layout and drawing of every visible window, and the Core Animation commit.
	private static func flush() {
		for window in NSApp.windows where window.isVisible { window.displayIfNeeded() }
		CATransaction.flush()
	}

	/// Wall time since the kernel started this process (includes dyld and static init).
	private static func secondsSinceProcessStart() -> Double? {
		var info = kinfo_proc()
		var size = MemoryLayout<kinfo_proc>.stride
		var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
		guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
		let start = info.kp_proc.p_un.__p_starttime
		var now = timeval()
		gettimeofday(&now, nil)
		return Double(now.tv_sec - start.tv_sec) + Double(now.tv_usec - start.tv_usec) / 1e6
	}

	/// Memory the system charges to the process (Activity Monitor's "Memory" column).
	private static func footprintMB() -> Double {
		var info = task_vm_info_data_t()
		var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
		let kr = withUnsafeMutablePointer(to: &info) {
			$0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
		}
		return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
	}
}
