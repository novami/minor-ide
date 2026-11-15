import Testing
@testable import TextEngine

struct ScopeTests {
	@Test func headersOfEnclosingBlocks() {
		let php = """
		class A
		{
		    public function f(
		        int $a,
		    ) {
		        if ($a) {
		            x();
		        } else {

		            y();
		        }
		    }
		}
		"""
		let rope = Rope(php)
		#expect(rope.scopeHeaders(around: 6, tabWidth: 4) == [0, 2, 5]) // the `{` line is skipped
		#expect(rope.scopeHeaders(around: 9, tabWidth: 4) == [0, 2, 5]) // past `} else {`
		#expect(rope.scopeHeaders(around: 8, tabWidth: 4) == [0, 2, 5]) // blank line: the next one's indent
		#expect(rope.scopeHeaders(around: 11, tabWidth: 4) == [0]) // closing brace of f
		#expect(rope.scopeHeaders(around: 0, tabWidth: 4) == [])
		#expect(rope.scopeHeaders(around: 12, tabWidth: 4) == [])
		#expect(rope.scopeHeaders(around: 6, tabWidth: 4, maxScan: 2) == [5])
	}
}
