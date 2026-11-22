import Testing
@testable import PHPKit

struct DeclarationScannerTests {
	static func scan(_ src: String) -> PHPFileDecls {
		var s = PHPDeclarationScanner()
		return s.scan(Array(src.utf8))
	}

	static func names(_ r: PHPFileDecls) -> [String] {
		r.decls.indices.map { "\(r.decls[$0].kind.label) \(r.qualifiedName($0))" }
	}

	@Test func declarations() {
		let r = Self.scan("""
		<?php
		declare(strict_types=1);

		namespace App\\Model;

		use Nette\\Database\\Explorer;
		use function strlen;

		#[Attr]
		final class UserRepository extends Base implements Repo
		{
			use SmartObject;
			public const TABLE = 'user', OTHER = 2;
			private ?Explorer $db = null;
			public static int $count;

			public function __construct(private Explorer $explorer) {}

			public function &find(int $id): ?array
			{
				$fn = function ($x) use ($id) { return $x; };
				$cls = new class { public function inner() {} };
				$name = self::class;
				return $this->db->table(static::TABLE)->get($id) ?: null;
			}
		}

		enum Status: string
		{
			case Active = 'a';
			case Off = 'o';
			const DEFAULT = self::Active;
		}

		interface Repo { function find(int $id); }

		function helper(): void {}
		$enum = 1;

		""")
		#expect(Self.names(r) == [
			"class App\\Model\\UserRepository",
			"const App\\Model\\UserRepository::TABLE",
			"const App\\Model\\UserRepository::OTHER",
			"property App\\Model\\UserRepository::$db",
			"property App\\Model\\UserRepository::$count",
			"method App\\Model\\UserRepository::__construct",
			"method App\\Model\\UserRepository::find",
			"enum App\\Model\\Status",
			"case App\\Model\\Status::Active",
			"case App\\Model\\Status::Off",
			"const App\\Model\\Status::DEFAULT",
			"interface App\\Model\\Repo",
			"method App\\Model\\Repo::find",
			"function App\\Model\\helper",
		])
		#expect(r.uses.map { r.string($0) } == ["Nette\\Database\\Explorer", "function strlen"])
		#expect(!r.unbalanced)
	}

	/// A top-level closure with use() is not an import (found in nette/neon examples).
	@Test func topLevelClosureUse() {
		let r = Self.scan("<?php\n$f = function () use (&$x): void {\n};\nforeach ($a as $b) {\n}\nfunction g() {}\n")
		#expect(!r.unbalanced && r.uses.isEmpty && Self.names(r) == ["function g"])
	}

	@Test func bracedNamespaces() {
		let r = Self.scan("<?php namespace A { class X {} } namespace B { function f() {} }")
		#expect(Self.names(r) == ["class A\\X", "function B\\f"])
	}
}
