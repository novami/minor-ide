import CoreServices
import Foundation

/// FSEvents on a set of folders (recursively), reporting changed paths on the main queue.
@MainActor
final class FileWatcher {
	private var stream: FSEventStreamRef?
	private let handler: ([String]) -> Void

	init?(paths: [String], latency: Double = 0.3, handler: @escaping ([String]) -> Void) {
		self.handler = handler
		guard !paths.isEmpty else { return nil }
		var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
		let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
			guard let info else { return }
			let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
			let list = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]) ?? []
			MainActor.assumeIsolated { watcher.handler(Array(list.prefix(count))) }
		}
		let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
		guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
		                                       FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
		FSEventStreamSetDispatchQueue(stream, .main)
		FSEventStreamStart(stream)
		self.stream = stream
	}

	/// Must be called before the watcher goes away (the stream holds an unretained pointer).
	func stop() {
		guard let stream else { return }
		FSEventStreamStop(stream)
		FSEventStreamInvalidate(stream)
		FSEventStreamRelease(stream)
		self.stream = nil
	}
}
