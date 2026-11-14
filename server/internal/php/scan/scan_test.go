package scan

import (
	"fmt"
	"strings"
	"testing"
)

func TestFile(t *testing.T) {
	src := `<?php
declare(strict_types=1);

namespace App\Model;

use Nette\Database\Explorer;
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
`
	r := File([]byte(src))
	var got []string
	for _, d := range r.Decls {
		got = append(got, fmt.Sprintf("%s %s", d.Kind, d.Name))
	}
	want := []string{
		`class App\Model\UserRepository`,
		`const App\Model\UserRepository::TABLE`,
		`const App\Model\UserRepository::OTHER`,
		`property App\Model\UserRepository::$db`,
		`property App\Model\UserRepository::$count`,
		`method App\Model\UserRepository::__construct`,
		`method App\Model\UserRepository::find`,
		`enum App\Model\Status`,
		`case App\Model\Status::Active`,
		`case App\Model\Status::Off`,
		`const App\Model\Status::DEFAULT`,
		`interface App\Model\Repo`,
		`method App\Model\Repo::find`,
		`function App\Model\helper`,
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("decls\n got:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	if r.Namespace != `App\Model` || len(r.Uses) != 2 || r.Uses[1] != "function strlen" {
		t.Fatalf("namespace/uses: %q %q", r.Namespace, r.Uses)
	}
	if r.Unbalanced {
		t.Fatal("unexpected unbalanced braces")
	}
}

// A top-level closure with use() must not be read as an import (found in nette/neon examples).
func TestTopLevelClosureUse(t *testing.T) {
	r := File([]byte("<?php\n$f = function () use (&$x): void {\n};\nforeach ($a as $b) {\n}\nfunction g() {}\n"))
	if r.Unbalanced || len(r.Uses) != 0 || len(r.Decls) != 1 || r.Decls[0].Name != "g" {
		t.Fatalf("%+v", r)
	}
}

func TestBracedNamespaces(t *testing.T) {
	r := File([]byte(`<?php namespace A { class X {} } namespace B { function f() {} }`))
	if len(r.Decls) != 2 || r.Decls[0].Name != `A\X` || r.Decls[1].Name != `B\f` {
		t.Fatalf("%+v", r.Decls)
	}
}
