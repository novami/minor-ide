/// Spike S1: top-level declarations of a PHP file without a full parse, stored in flat arrays
/// (one byte pool for names, plain structs for declarations) so that tens of thousands of files
/// cost little memory and no reference counting. The real parser (roadmap R5a) replaces it.
public enum PHPDeclKind: UInt8, Sendable, CaseIterable {
	case `class`, interface, trait, `enum`, function, method, property, const, enumCase

	public var label: String {
		switch self {
		case .class: "class"
		case .interface: "interface"
		case .trait: "trait"
		case .enum: "enum"
		case .function: "function"
		case .method: "method"
		case .property: "property"
		case .const: "const"
		case .enumCase: "case"
		}
	}
}

/// A range in `PHPFileDecls.pool`.
public struct PoolRange: Equatable, Sendable {
	public var start: Int32
	public var length: Int32
	static let empty = PoolRange(start: 0, length: 0)
}

public struct PHPDecl: Equatable, Sendable {
	public var kind: PHPDeclKind
	/// Index of the class-like declaration that owns a member, or -1.
	public var owner: Int32
	/// Byte offset of the name in the source.
	public var offset: Int32
	public var name: PoolRange
	public var namespace: PoolRange
}

public struct PHPFileDecls: Sendable {
	public var pool: [UInt8] = []
	public var decls: [PHPDecl] = []
	public var uses: [PoolRange] = []
	/// True when braces did not close, a sign of a lexer or source problem.
	public var unbalanced = false

	public init() {}

	public func string(_ r: PoolRange) -> String {
		let start = Int(r.start), end = start + Int(r.length)
		guard start >= 0, end <= pool.count, start <= end else { return "" }
		return String(decoding: pool[start..<end], as: UTF8.self)
	}

	/// `Ns\Name` for types and functions, `Ns\Type::member` for members.
	public func qualifiedName(_ i: Int) -> String {
		guard decls.indices.contains(i) else { return "" }
		let d = decls[i]
		if d.owner >= 0 { return qualifiedName(Int(d.owner)) + "::" + string(d.name) }
		let ns = string(d.namespace)
		return ns.isEmpty ? string(d.name) : ns + "\\" + string(d.name)
	}

	/// Approximate heap bytes held by this result.
	public var memoryBytes: Int {
		pool.capacity + decls.capacity * MemoryLayout<PHPDecl>.stride + uses.capacity * MemoryLayout<PoolRange>.stride
	}

	mutating func intern(_ src: UnsafeBufferPointer<UInt8>, _ start: Int32, _ end: Int32) -> PoolRange {
		let s = max(0, Int(start)), e = min(src.count, Int(end))
		guard s < e else { return .empty }
		let r = PoolRange(start: Int32(truncatingIfNeeded: pool.count), length: Int32(truncatingIfNeeded: e - s))
		pool.append(contentsOf: UnsafeBufferPointer(rebasing: src[s..<e]))
		return r
	}
}

public struct PHPDeclarationScanner {
	/// Reused between files; token buffers dominated allocations in the Go spike.
	var tokens: [PHPToken] = []

	public init() {}

	public mutating func scan(_ bytes: [UInt8]) -> PHPFileDecls {
		bytes.withUnsafeBufferPointer { scan($0) }
	}

	public mutating func scan(_ src: UnsafeBufferPointer<UInt8>) -> PHPFileDecls {
		significantTokens(src)
		return tokens.withUnsafeBufferPointer {
			var pass = Pass(src: src, toks: $0)
			return pass.run()
		}
	}

	/// Drops whitespace, comments, inline HTML and open tags; `?>` becomes `;`.
	mutating func significantTokens(_ src: UnsafeBufferPointer<UInt8>) {
		tokens.removeAll(keepingCapacity: true)
		var lexer = PHPLexer(src)
		while true {
			var t = lexer.next()
			switch t.kind {
			case .eof: return
			case .whitespace, .comment, .docComment, .inlineHTML, .openTag: continue
			case .closeTag: t = PHPToken(kind: .op, op: UInt8(ascii: ";"), start: t.start, end: t.start)
			default: break
			}
			tokens.append(t)
		}
	}
}

/// One scan over the significant tokens of a file.
private struct Pass {
	let src: UnsafeBufferPointer<UInt8>
	let toks: UnsafeBufferPointer<PHPToken>
	var r = PHPFileDecls()
	var depth = 0
	var nsDepth = 0          // brace depth of the current namespace body
	var namespace = PoolRange.empty
	var classDecl: Int32 = -1 // current class-like declaration
	var classBody = -1       // brace depth inside the current class body
	var pending: Int32 = -1  // class-like declaration waiting for its "{"
	var paren = 0

	init(src: UnsafeBufferPointer<UInt8>, toks: UnsafeBufferPointer<PHPToken>) {
		self.src = src
		self.toks = toks
	}

	func at(_ i: Int) -> PHPToken { i >= 0 && i < toks.count ? toks[i] : PHPToken(kind: .eof, op: 0, start: 0, end: 0) }

	func isOp(_ t: PHPToken, _ c: Unicode.Scalar) -> Bool { t.op == UInt8(ascii: c) }

	func word(_ t: PHPToken) -> Keyword? {
		guard t.kind == .ident else { return nil }
		return Keyword.match(src, Int(t.start), Int(t.end))
	}

	mutating func add(_ kind: PHPDeclKind, name t: PHPToken, owner: Int32) {
		let name = r.intern(src, t.start, t.end)
		r.decls.append(PHPDecl(kind: kind, owner: owner, offset: t.start, name: name, namespace: owner >= 0 ? .empty : namespace))
	}

	mutating func run() -> PHPFileDecls {
		var i = 0
		while i < toks.count {
			defer { i += 1 }
			let t = toks[i]
			let prev = at(i - 1)
			if t.kind == .op {
				switch t.op {
				case UInt8(ascii: "{"):
					depth += 1
					if pending >= 0 { classDecl = pending; classBody = depth; pending = -1 }
				case UInt8(ascii: "}"):
					if depth == classBody { classDecl = -1; classBody = -1 }
					depth -= 1
					if depth < nsDepth { nsDepth = depth }
				case UInt8(ascii: "("): paren += 1
				case UInt8(ascii: ")"): paren -= 1
				default: break
				}
				continue
			}
			if t.kind == .variable {
				if depth == classBody, paren == 0, classDecl >= 0 { add(.property, name: t, owner: classDecl) }
				continue
			}
			guard let kw = word(t) else { continue }
			if prev.op == PHPOp.doubleColon || prev.op == PHPOp.arrow || prev.op == PHPOp.nullsafe { continue } // Foo::class, $x->class
			switch kw {
			case .namespace:
				let next = at(i + 1)
				if depth != nsDepth || isOp(next, "\\") { continue }
				if next.kind == .ident || next.kind == .name {
					var s = next.start
					if s < next.end, src[Int(s)] == UInt8(ascii: "\\") { s += 1 }
					namespace = r.intern(src, s, next.end)
					i += 1
				} else if isOp(next, "{") {
					namespace = .empty
				}
				if isOp(at(i + 1), "{") { nsDepth = depth + 1 }
			case .use:
				let atStatementStart = prev.kind == .eof || isOp(prev, ";") || isOp(prev, "{") || isOp(prev, "}")
				if depth != nsDepth || classDecl >= 0 || !atStatementStart { continue } // closure use(...) or trait use
				let start = Int32(truncatingIfNeeded: r.pool.count)
				var j = i + 1
				while j < toks.count, !isOp(toks[j], ";") {
					let u = toks[j]
					_ = r.intern(src, u.start, u.end)
					if u.kind == .ident, at(j + 1).kind == .ident { r.pool.append(UInt8(ascii: " ")) }
					j += 1
				}
				r.uses.append(PoolRange(start: start, length: Int32(truncatingIfNeeded: r.pool.count) - start))
				i = j
			case .class, .interface, .trait, .enum:
				let name = at(i + 1)
				if name.kind != .ident || (prev.kind == .ident && word(prev) == .new) || pending >= 0 { continue } // anonymous class
				if kw == .enum {
					let after = at(i + 2)
					if !(isOp(after, "{") || isOp(after, ":") || word(after) == .implements) { continue } // "enum" as a name
				}
				let kind: PHPDeclKind = switch kw {
				case .interface: .interface
				case .trait: .trait
				case .enum: .enum
				default: .class
				}
				add(kind, name: name, owner: -1)
				pending = Int32(truncatingIfNeeded: r.decls.count - 1)
				i += 1
			case .function:
				var j = i + 1
				if isOp(at(j), "&") { j += 1 }
				let name = at(j)
				if name.kind != .ident || !isOp(at(j + 1), "(") { continue } // closure
				if classDecl >= 0, depth == classBody {
					add(.method, name: name, owner: classDecl)
				} else if classDecl < 0, depth == nsDepth {
					add(.function, name: name, owner: -1)
				}
				i = j
			case .const:
				if classDecl >= 0 ? depth != classBody : depth != nsDepth { continue }
				// const [type] NAME = …, NAME2 = …; the name is the identifier before "=".
				var j = i + 1
				while j < toks.count, !isOp(toks[j], ";") {
					if isOp(toks[j], "="), toks[j - 1].kind == .ident { add(.const, name: toks[j - 1], owner: classDecl) }
					j += 1
				}
			case .case:
				let name = at(i + 1)
				if classDecl >= 0, depth == classBody, name.kind == .ident { add(.enumCase, name: name, owner: classDecl) }
			case .new, .implements:
				break
			}
		}
		r.unbalanced = depth != 0 || pending >= 0
		return r
	}
}

enum Keyword: CaseIterable {
	case namespace, use, `class`, interface, trait, `enum`, function, const, `case`, new, implements

	static let spellings: [(Keyword, [UInt8])] = allCases.map { ($0, Array("\($0)".utf8)) }

	/// Case-insensitive match without allocation.
	static func match(_ src: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Keyword? {
		let n = end - start
		guard n >= 3, n <= 10, start >= 0, end <= src.count else { return nil }
		outer: for (kw, s) in spellings where s.count == n {
			for k in 0..<n where src[start + k] | 0x20 != s[k] { continue outer }
			return kw
		}
		return nil
	}
}
