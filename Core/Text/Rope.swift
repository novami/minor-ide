import Foundation

/// Aggregated metrics of a text span. Counting works on raw UTF-8 bytes, so a span may
/// start or end inside a multi-byte sequence and the sums stay correct.
nonisolated public struct TextSummary: Sendable, Equatable {
	public var bytes = 0
	public var newlines = 0
	public var utf16 = 0

	public static let zero = TextSummary()

	init(bytes: some Sequence<UInt8>) {
		for b in bytes {
			self.bytes += 1
			if b == 0x0A { newlines += 1 }
			if b & 0xC0 != 0x80 { utf16 += b >= 0xF0 ? 2 : 1 } // 4-byte sequences are surrogate pairs
		}
	}

	init() {}

	static func += (a: inout TextSummary, b: TextSummary) { a = a + b }
	static func -= (a: inout TextSummary, b: TextSummary) { a = a - b }

	static func - (a: TextSummary, b: TextSummary) -> TextSummary {
		var r = a
		r.bytes -= b.bytes
		r.newlines -= b.newlines
		r.utf16 -= b.utf16
		return r
	}

	static func + (a: TextSummary, b: TextSummary) -> TextSummary {
		var r = a
		r.bytes += b.bytes
		r.newlines += b.newlines
		r.utf16 += b.utf16
		return r
	}
}

/// B-tree node. Leaves hold UTF-8 bytes; all leaves are at height 0.
/// Nodes are mutated in place only while uniquely referenced (no snapshot shares them),
/// otherwise copied first, so every Rope value behaves as an immutable snapshot.
nonisolated final class Node: @unchecked Sendable {
	static let maxLeaf = 1024
	static let maxChildren = 16

	var summary: TextSummary
	let height: Int
	var bytes: [UInt8]
	var children: [Node]

	private init(copying n: Node) {
		summary = n.summary
		height = n.height
		bytes = n.bytes
		children = n.children
	}

	func copy() -> Node { Node(copying: self) }

	func recomputeSummary() {
		summary = isLeaf ? TextSummary(bytes: bytes) : children.dropFirst().reduce(children[0].summary) { $0 + $1.summary }
	}

	init(leaf: [UInt8]) {
		summary = TextSummary(bytes: leaf)
		height = 0
		bytes = leaf
		children = []
	}

	init(children: [Node]) {
		precondition(!children.isEmpty)
		summary = children.dropFirst().reduce(children[0].summary) { $0 + $1.summary }
		height = children[0].height + 1
		bytes = []
		self.children = children
	}

	var isLeaf: Bool { height == 0 }
}

/// Persistent rope over UTF-8 text. Copies are O(1) and share structure, so a snapshot
/// can be handed to a background thread while the editor keeps editing.
nonisolated public struct Rope: Sendable {
	var root: Node

	public init() { root = Node(leaf: []) }

	public init(_ string: String) {
		root = Rope.build(Array(string.utf8))
	}

	public init(bytes: [UInt8]) {
		root = Rope.build(bytes)
	}

	public var summary: TextSummary { root.summary }
	public var byteCount: Int { root.summary.bytes }
	public var utf16Count: Int { root.summary.utf16 }
	public var lineCount: Int { root.summary.newlines + 1 }
	public var isEmpty: Bool { byteCount == 0 }

	public var string: String { string(in: 0..<byteCount) }

	public func string(in range: Range<Int>) -> String {
		String(decoding: bytes(in: range), as: UTF8.self)
	}

	public func bytes(in range: Range<Int>) -> [UInt8] {
		precondition(range.lowerBound >= 0 && range.upperBound <= byteCount, "range out of bounds")
		var out: [UInt8] = []
		out.reserveCapacity(range.count)
		Rope.collect(root, range, base: 0, into: &out)
		return out
	}

	public func byte(at offset: Int) -> UInt8 {
		precondition(offset >= 0 && offset < byteCount, "offset out of bounds")
		var node = root
		var o = offset
		while !node.isLeaf {
			for c in node.children {
				if o < c.summary.bytes { node = c; break }
				o -= c.summary.bytes
			}
		}
		return node.bytes[o]
	}

	// MARK: Editing

	public mutating func replace(_ range: Range<Int>, with text: String) {
		replace(range, with: text.utf8) // no intermediate array: typing must not allocate
	}

	public mutating func replace<C: Collection>(_ range: Range<Int>, with bytes: C) where C.Element == UInt8 {
		precondition(range.lowerBound >= 0 && range.upperBound <= byteCount, "range out of bounds")
		if !range.isEmpty {
			if Rope.delete(&root, range) { root = Node(leaf: []) }
			while !root.isLeaf && root.children.count == 1 { root = root.children[0] }
		}
		if !bytes.isEmpty {
			let extra = Rope.insert(&root, at: range.lowerBound, bytes, TextSummary(bytes: bytes))
			if !extra.isEmpty { root = Rope.join([root] + extra) }
		}
	}

	// MARK: Lines

	/// Byte offset where the given 0-based line starts.
	public func offset(ofLine line: Int) -> Int {
		precondition(line >= 0 && line < lineCount, "line out of bounds")
		if line == 0 { return 0 }
		var node = root
		var remaining = line // newlines to pass
		var base = 0
		while !node.isLeaf {
			for c in node.children {
				if remaining <= c.summary.newlines { node = c; break }
				remaining -= c.summary.newlines
				base += c.summary.bytes
			}
		}
		let found: Int? = node.bytes.withUnsafeBufferPointer { buf in
			guard let start = buf.baseAddress else { return nil }
			var p = UnsafeRawPointer(start)
			let end = p + buf.count
			while p < end, let hit = memchr(p, 0x0A, end - p) {
				remaining -= 1
				if remaining == 0 { return UnsafeRawPointer(hit) - UnsafeRawPointer(start) }
				p = UnsafeRawPointer(hit) + 1
			}
			return nil
		}
		guard let i = found else { preconditionFailure("newline index inconsistent") }
		return base + i + 1
	}

	/// 0-based line containing the byte offset.
	public func line(containing offset: Int) -> Int {
		precondition(offset >= 0 && offset <= byteCount, "offset out of bounds")
		var node = root
		var o = offset
		var line = 0
		while !node.isLeaf {
			var next: Node?
			for c in node.children {
				if o < c.summary.bytes { next = c; break }
				o -= c.summary.bytes
				line += c.summary.newlines
			}
			guard let n = next else { return line } // offset == byteCount
			node = n
		}
		for b in node.bytes[0..<o] where b == 0x0A { line += 1 }
		return line
	}

	/// Byte range of a line without its trailing "\n".
	public func lineRange(_ line: Int) -> Range<Int> {
		let start = offset(ofLine: line)
		let end = line + 1 < lineCount ? offset(ofLine: line + 1) - 1 : byteCount
		return start..<end
	}

	/// Number of UTF-16 code units before the byte offset.
	public func utf16Offset(ofByte offset: Int) -> Int {
		precondition(offset >= 0 && offset <= byteCount, "offset out of bounds")
		var node = root
		var o = offset
		var units = 0
		while !node.isLeaf {
			var next: Node?
			for c in node.children {
				if o < c.summary.bytes { next = c; break }
				o -= c.summary.bytes
				units += c.summary.utf16
			}
			guard let n = next else { return units }
			node = n
		}
		return units + TextSummary(bytes: node.bytes[0..<o]).utf16
	}

	/// Byte offset of a UTF-16 offset; one inside a surrogate pair maps to the start of its scalar.
	public func byteOffset(ofUTF16 units: Int) -> Int {
		var node = root
		var u = min(max(units, 0), utf16Count)
		var base = 0
		while !node.isLeaf {
			var next: Node?
			for c in node.children {
				if u < c.summary.utf16 { next = c; break }
				u -= c.summary.utf16
				base += c.summary.bytes
			}
			guard let n = next else { return byteCount }
			node = n
		}
		// Leaves may split a UTF-8 sequence; count lead bytes like TextSummary does.
		var i = 0
		let bytes = node.bytes
		while i < bytes.count {
			let b = bytes[i]
			if b & 0xC0 != 0x80 {
				let width = b >= 0xF0 ? 2 : 1
				if u < width { break }
				u -= width
			}
			i += 1
		}
		return base + i
	}

	/// Moves an offset back to the start of the UTF-8 sequence it points into.
	public func scalarBoundary(atOrBefore offset: Int) -> Int {
		var o = min(max(offset, 0), byteCount)
		while o > 0 && o < byteCount && byte(at: o) & 0xC0 == 0x80 { o -= 1 }
		return o
	}

	// MARK: Tree algorithms

	static func build(_ bytes: [UInt8]) -> Node {
		if bytes.count <= Node.maxLeaf { return Node(leaf: bytes) }
		return join(leaves(bytes))
	}

	/// Splits bytes into evenly sized leaves of at most `maxLeaf` bytes.
	static func leaves(_ bytes: [UInt8]) -> [Node] {
		let n = (bytes.count + Node.maxLeaf - 1) / Node.maxLeaf
		let size = (bytes.count + n - 1) / n
		return stride(from: 0, to: bytes.count, by: size).map {
			Node(leaf: Array(bytes[$0..<min($0 + size, bytes.count)]))
		}
	}

	/// Groups equal-height nodes into parents until a single root remains.
	static func join(_ nodes: [Node]) -> Node {
		var level = nodes
		while level.count > 1 { level = group(level) }
		return level[0]
	}

	static func group(_ nodes: [Node]) -> [Node] {
		if nodes.count <= Node.maxChildren { return [Node(children: nodes)] }
		let n = (nodes.count + Node.maxChildren - 1) / Node.maxChildren
		let size = (nodes.count + n - 1) / n
		return stride(from: 0, to: nodes.count, by: size).map {
			Node(children: Array(nodes[$0..<min($0 + size, nodes.count)]))
		}
	}

	static func makeUnique(_ node: inout Node) {
		if !isKnownUniquelyReferenced(&node) { node = node.copy() }
	}

	/// Inserts in place; returns overflow siblings (same height) to place right of `node`.
	static func insert<C: Collection>(_ node: inout Node, at offset: Int, _ bytes: C, _ added: TextSummary) -> [Node]
		where C.Element == UInt8 {
		makeUnique(&node)
		if node.isLeaf {
			node.bytes.insert(contentsOf: bytes, at: offset)
			node.summary += added
			guard node.bytes.count > Node.maxLeaf else { return [] }
			var parts = leaves(node.bytes)
			node.bytes = parts[0].bytes
			node.summary = parts[0].summary
			parts.removeFirst()
			return parts
		}
		var o = offset
		var index = node.children.count - 1
		for i in node.children.indices {
			let size = node.children[i].summary.bytes
			if o <= size { index = i; break }
			o -= size
		}
		let extra = insert(&node.children[index], at: o, bytes, added)
		node.summary += added
		guard !extra.isEmpty else { return [] }
		node.children.insert(contentsOf: extra, at: index + 1)
		guard node.children.count > Node.maxChildren else { return [] }
		var groups = group(node.children)
		node.children = groups[0].children
		node.recomputeSummary()
		groups.removeFirst()
		return groups
	}

	/// Deletes in place; returns true when the node became empty.
	static func delete(_ node: inout Node, _ range: Range<Int>) -> Bool {
		makeUnique(&node)
		if node.isLeaf {
			node.summary -= TextSummary(bytes: node.bytes[range])
			node.bytes.removeSubrange(range)
			return node.bytes.isEmpty
		}
		var base = 0
		var i = 0
		while i < node.children.count {
			let size = node.children[i].summary.bytes
			let end = base + size
			if end <= range.lowerBound {
				base = end
				i += 1
				continue
			}
			if base >= range.upperBound { break }
			let local = max(range.lowerBound, base) - base..<min(range.upperBound, end) - base
			if local.count == size || delete(&node.children[i], local) {
				node.children.remove(at: i)
			} else {
				i += 1
			}
			base = end
		}
		if node.children.isEmpty { return true }
		if node.height == 1, node.children.contains(where: { $0.bytes.count < Node.maxLeaf / 4 }) {
			node.children = mergeSmallLeaves(node.children)
		}
		node.recomputeSummary()
		return false
	}

	/// Joins neighbouring leaves that fit together, so deletions do not leave dust.
	static func mergeSmallLeaves(_ leaves: [Node]) -> [Node] {
		var out: [Node] = []
		for leaf in leaves {
			if let last = out.last, last.bytes.count + leaf.bytes.count <= Node.maxLeaf,
			   last.bytes.count < Node.maxLeaf / 4 || leaf.bytes.count < Node.maxLeaf / 4 {
				out[out.count - 1] = Node(leaf: last.bytes + leaf.bytes)
			} else {
				out.append(leaf)
			}
		}
		return out
	}

	static func collect(_ node: Node, _ range: Range<Int>, base: Int, into out: inout [UInt8]) {
		if node.isLeaf {
			let lo = max(range.lowerBound - base, 0)
			let hi = min(range.upperBound - base, node.bytes.count)
			if lo < hi { out.append(contentsOf: node.bytes[lo..<hi]) }
			return
		}
		var b = base
		for c in node.children {
			let end = b + c.summary.bytes
			if end > range.lowerBound && b < range.upperBound {
				collect(c, range, base: b, into: &out)
			}
			if end >= range.upperBound { return }
			b = end
		}
	}

	/// Checks structural invariants; used by tests.
	func validate() -> Bool {
		func check(_ n: Node) -> Bool {
			if n.isLeaf { return n.bytes.count <= Node.maxLeaf && n.summary == TextSummary(bytes: n.bytes) }
			guard n.children.count <= Node.maxChildren,
			      n.summary == n.children.dropFirst().reduce(n.children[0].summary, { $0 + $1.summary })
			else { return false }
			return n.children.allSatisfy { $0.height == n.height - 1 && check($0) }
		}
		return check(root)
	}
}
