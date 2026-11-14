/// Aggregated metrics of a text span. Counting works on raw UTF-8 bytes, so a span may
/// start or end inside a multi-byte sequence and the sums stay correct.
public struct TextSummary: Sendable, Equatable {
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

	static func + (a: TextSummary, b: TextSummary) -> TextSummary {
		var r = a
		r.bytes += b.bytes
		r.newlines += b.newlines
		r.utf16 += b.utf16
		return r
	}
}

/// Immutable B-tree node. Leaves hold UTF-8 bytes; all leaves are at height 0.
final class Node: Sendable {
	static let maxLeaf = 1024
	static let maxChildren = 16

	let summary: TextSummary
	let height: Int
	let bytes: [UInt8]
	let children: [Node]

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
public struct Rope: Sendable {
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
		replace(range, with: Array(text.utf8))
	}

	public mutating func replace(_ range: Range<Int>, with bytes: [UInt8]) {
		precondition(range.lowerBound >= 0 && range.upperBound <= byteCount, "range out of bounds")
		if !range.isEmpty {
			root = Rope.delete(root, range) ?? Node(leaf: [])
			while !root.isLeaf && root.children.count == 1 { root = root.children[0] }
		}
		if !bytes.isEmpty {
			root = Rope.join(Rope.insert(root, at: range.lowerBound, bytes))
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
		for (i, b) in node.bytes.enumerated() where b == 0x0A {
			remaining -= 1
			if remaining == 0 { return base + i + 1 }
		}
		preconditionFailure("newline index inconsistent")
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

	/// Returns one or more nodes of the same height as `node`.
	static func insert(_ node: Node, at offset: Int, _ bytes: [UInt8]) -> [Node] {
		if node.isLeaf {
			var b = node.bytes
			b.insert(contentsOf: bytes, at: offset)
			return b.count <= Node.maxLeaf ? [Node(leaf: b)] : leaves(b)
		}
		var o = offset
		var index = node.children.count - 1
		for (i, c) in node.children.enumerated() {
			if o <= c.summary.bytes { index = i; break }
			o -= c.summary.bytes
		}
		var children = node.children
		children.replaceSubrange(index...index, with: insert(node.children[index], at: o, bytes))
		return children.count <= Node.maxChildren ? [Node(children: children)] : group(children)
	}

	/// Returns nil when the whole node was deleted.
	static func delete(_ node: Node, _ range: Range<Int>) -> Node? {
		if node.isLeaf {
			var b = node.bytes
			b.removeSubrange(range)
			return b.isEmpty ? nil : Node(leaf: b)
		}
		var children: [Node] = []
		var base = 0
		for c in node.children {
			let end = base + c.summary.bytes
			defer { base = end }
			if end <= range.lowerBound || base >= range.upperBound {
				children.append(c)
				continue
			}
			let local = max(range.lowerBound, base) - base..<min(range.upperBound, end) - base
			if local.count == c.summary.bytes { continue }
			if let kept = delete(c, local) { children.append(kept) }
		}
		if children.isEmpty { return nil }
		if node.height == 1 { children = mergeSmallLeaves(children) }
		return Node(children: children)
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
			if n.isLeaf { return n.bytes.count <= Node.maxLeaf }
			guard n.children.count <= Node.maxChildren else { return false }
			return n.children.allSatisfy { $0.height == n.height - 1 && check($0) }
		}
		return check(root)
	}
}
