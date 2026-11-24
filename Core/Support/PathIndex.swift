import Foundation

/// All file paths of a project in memory (relative to the root), for opening a file by name.
/// Built on a background queue, then kept current from file system events. Searching is
/// synchronous and thread-safe; call it off the main thread.
///
/// Files ignored by Git stay findable (`vendor/` sources) but rank lower; ignored hidden
/// folders (`.build`, `.idea`) and `node_modules` are not read at all.
nonisolated public final class PathIndex: @unchecked Sendable {
	public struct Match: Sendable, Equatable {
		public let path: String
		public let score: Int
	}

	struct Entry: Sendable {
		let fuzzy: FuzzyPath
		let ignored: Bool
	}

	public let root: URL
	/// Projects bigger than this are cut off (a home folder opened by mistake).
	public static let limit = 300_000
	/// Score taken from files ignored by Git.
	static let ignoredPenalty = 40

	private let lock = NSLock()
	private var paths: [String: Entry] = [:]
	private var snapshot: [Entry]?
	private var ready = false
	private var waiting: [@Sendable () -> Void] = []
	private let queue = DispatchQueue(label: "MinorIDE.PathIndex", qos: .userInitiated)
	private let ignore: GitIgnoreSet

	public init(root: URL) {
		self.root = root.standardizedFileURL
		ignore = GitIgnoreSet(root: self.root)
	}

	public var isReady: Bool { lock.withLock { ready } }
	public var count: Int { lock.withLock { paths.count } }

	/// Reads the whole tree in the background.
	public func build() {
		queue.async { [self] in
			ignore.reset()
			var found: [String: Entry] = [:]
			walk("", ignored: false) { found[$0.fuzzy.path] = $0 }
			let callbacks = lock.withLock {
				paths = found
				snapshot = nil
				ready = true
				defer { waiting = [] }
				return waiting
			}
			callbacks.forEach { $0() }
		}
	}

	/// Calls `body` (on a background queue) once the first build and pending updates finished.
	public func whenReady(_ body: @escaping @Sendable () -> Void) {
		let now = lock.withLock {
			if ready { return true }
			waiting.append(body)
			return false
		}
		if now { queue.async(execute: body) }
	}

	/// Applies changed absolute paths (FSEvents): added files, removed files or folders,
	/// new or renamed folders (read again). A changed `.gitignore` rebuilds everything.
	public func update(changed absolute: [String]) {
		if absolute.contains(where: { $0.hasSuffix("/.gitignore") }) { return build() }
		queue.async { [self] in
			let fm = FileManager.default
			for path in absolute {
				guard let rel = relative(path), !rel.isEmpty, !isHidden(rel) else { continue }
				var isDir: ObjCBool = false
				let exists = fm.fileExists(atPath: path, isDirectory: &isDir)
				lock.withLock {
					paths[rel] = nil
					if !exists || isDir.boolValue {
						let prefix = rel + "/"
						for key in paths.keys where key.hasPrefix(prefix) { paths[key] = nil }
					}
					snapshot = nil
				}
				guard exists else { continue }
				let ignored = ignore.isIgnored(rel, isDirectory: isDir.boolValue)
				if isDir.boolValue {
					guard !(ignored && skipsIgnored(rel)) else { continue }
					var found: [String: Entry] = [:]
					walk(rel, ignored: ignored) { found[$0.fuzzy.path] = $0 }
					lock.withLock {
						paths.merge(found) { a, _ in a }
						snapshot = nil
					}
				} else {
					lock.withLock {
						if paths.count < Self.limit { paths[rel] = Entry(fuzzy: FuzzyPath(rel), ignored: ignored) }
					}
				}
			}
		}
	}

	/// Best matches for `query`, best first. `recent` are relative paths of recently used files,
	/// most recent first: they rank higher, and alone fill the result for an empty query.
	public func search(_ query: String, recent: [String] = [], limit: Int = 100) -> [Match] {
		let q = FuzzyQuery(query)
		let list = lock.withLock {
			let current = snapshot ?? Array(paths.values)
			snapshot = current
			return current
		}
		if q.isEmpty {
			let known = lock.withLock { Set(recent.filter { paths[$0] != nil }) }
			return recent.filter(known.contains).prefix(limit).map { Match(path: $0, score: 0) }
		}
		let rank = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
		// Chunks in parallel, each with its own scoring rows.
		let chunk = 2048, chunks = (list.count + chunk - 1) / chunk
		nonisolated(unsafe) let parts = UnsafeMutableBufferPointer<[Match]>.allocate(capacity: max(chunks, 1))
		parts.initialize(repeating: [])
		defer { parts.deallocate() }
		DispatchQueue.concurrentPerform(iterations: chunks) { c in
			var scratch = FuzzyQuery.Scratch()
			var found: [Match] = []
			for e in list[(c * chunk)..<min(list.count, (c + 1) * chunk)] {
				guard var s = q.score(e.fuzzy, &scratch) else { continue }
				if let r = rank[e.fuzzy.path] { s += max(4, 24 - 2 * r) }
				if e.ignored { s -= Self.ignoredPenalty }
				found.append(Match(path: e.fuzzy.path, score: s))
			}
			parts[c] = found
		}
		var matches = parts.flatMap { $0 }
		matches.sort { a, b in
			if a.score != b.score { return a.score > b.score }
			if a.path.utf8.count != b.path.utf8.count { return a.path.utf8.count < b.path.utf8.count }
			return a.path < b.path
		}
		return Array(matches.prefix(limit))
	}

	/// Matched byte offsets in `path` for highlighting.
	public static func positions(of query: String, in path: String) -> [Int] {
		FuzzyQuery(query).positions(FuzzyPath(path))
	}

	public func relative(_ absolute: String) -> String? {
		let base = root.path
		if absolute == base { return "" }
		guard absolute.hasPrefix(base + "/") else { return nil }
		return String(absolute.dropFirst(base.count + 1))
	}

	private func isHidden(_ rel: String) -> Bool {
		rel.split(separator: "/").contains { ExclusionPolicy.neverRead(String($0)) }
	}

	/// Ignored folders not worth reading: hidden ones (build output, tool caches) and
	/// JavaScript packages.
	private func skipsIgnored(_ rel: String) -> Bool {
		ExclusionPolicy.skipsIgnoredFolder(String(rel.split(separator: "/").last ?? ""))
	}

	/// Reads the folder `rel` recursively with `readdir` (types without a `stat` per file).
	/// Symbolic links to folders are not followed (cycles).
	private func walk(_ rel: String, ignored: Bool, _ add: (Entry) -> Void) {
		var count = 0
		var stack: [(String, Bool)] = [(rel, ignored)]
		let base = root.path
		while let (folder, folderIgnored) = stack.popLast() {
			let abs = folder.isEmpty ? base : base + "/" + folder
			guard let dir = opendir(abs) else { continue }
			defer { closedir(dir) }
			while let ent = readdir(dir) {
				let name = withUnsafePointer(to: ent.pointee.d_name) {
					$0.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) { String(cString: $0) }
				}
				if name == "." || name == ".." || ExclusionPolicy.neverRead(name) { continue }
				let child = folder.isEmpty ? name : folder + "/" + name
				var type = ent.pointee.d_type
				if type == DT_LNK || type == DT_UNKNOWN {
					var st = stat()
					guard stat(base + "/" + child, &st) == 0 else { continue }
					type = (st.st_mode & S_IFMT) == S_IFDIR ? (ent.pointee.d_type == DT_LNK ? UInt8(DT_LNK) : UInt8(DT_DIR)) : UInt8(DT_REG)
					if type == DT_LNK { continue } // link to a folder
				}
				if type == DT_DIR {
					let ign = folderIgnored || ignore.matches(child, isDirectory: true)
					if ign && skipsIgnored(child) { continue }
					stack.append((child, ign))
				} else if type == DT_REG {
					let ign = folderIgnored || ignore.matches(child, isDirectory: false)
					add(Entry(fuzzy: FuzzyPath(child), ignored: ign))
					count += 1
					if count >= Self.limit { return }
				}
			}
		}
	}
}
