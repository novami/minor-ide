// Command phpcorpus generates a synthetic PHP project for benchmarks:
//
//	go run ./cmd/phpcorpus -n 30000 -out /tmp/corpus
//
// Files mimic typical vendor code: namespaces, imports, PHPDoc, attributes,
// methods with bodies, closures, strings, heredocs and enums.
package main

import (
	"flag"
	"fmt"
	"math/rand/v2"
	"os"
	"path/filepath"
	"strings"
)

func main() {
	n := flag.Int("n", 30000, "number of files")
	out := flag.String("out", "", "output directory")
	flag.Parse()
	if *out == "" {
		fmt.Fprintln(os.Stderr, "-out is required")
		os.Exit(2)
	}
	r := rand.New(rand.NewPCG(1, 2))
	for i := 0; i < *n; i++ {
		ns := fmt.Sprintf("Vendor%d\\Package%d\\Module%d", i%40, i%300, i%7)
		dir := filepath.Join(*out, strings.ReplaceAll(ns, `\`, "/"))
		if err := os.MkdirAll(dir, 0o755); err != nil {
			panic(err)
		}
		name := fmt.Sprintf("Class%d", i)
		if err := os.WriteFile(filepath.Join(dir, name+".php"), []byte(file(r, ns, name, i)), 0o644); err != nil {
			panic(err)
		}
	}
}

func file(r *rand.Rand, ns, name string, i int) string {
	var b strings.Builder
	fmt.Fprintf(&b, "<?php\n\ndeclare(strict_types=1);\n\nnamespace %s;\n\n", ns)
	uses := 3 + r.IntN(6)
	for j := 0; j < uses; j++ {
		fmt.Fprintf(&b, "use Vendor%d\\Package%d\\Module%d\\Class%d;\n", r.IntN(40), r.IntN(300), r.IntN(7), r.IntN(30000))
	}
	if i%25 == 0 {
		fmt.Fprintf(&b, "\nenum %sStatus: string\n{\n\tcase Active = 'active';\n\tcase Disabled = 'disabled';\n\n\tpublic function label(): string\n\t{\n\t\treturn match ($this) {\n\t\t\tself::Active => 'Aktivní',\n\t\t\tself::Disabled => 'Vypnuto',\n\t\t};\n\t}\n}\n", name)
	}
	fmt.Fprintf(&b, "\n/**\n * %s handles things.\n *\n * @template T of object\n * @implements \\IteratorAggregate<int, T>\n */\n#[\\Attribute(\\Attribute::TARGET_CLASS)]\nfinal class %s extends Base%d implements \\IteratorAggregate, \\Countable\n{\n", name, name, i%50)
	fmt.Fprintf(&b, "\tuse SmartObject;\n\n\tpublic const VERSION = '1.%d', LIMIT = %d;\n\n", i%10, r.IntN(1000))
	props := 2 + r.IntN(5)
	for j := 0; j < props; j++ {
		fmt.Fprintf(&b, "\t/** @var array<string, int> */\n\tprivate array $items%d = [];\n\n", j)
	}
	fmt.Fprintf(&b, "\tpublic function __construct(\n\t\tprivate readonly Explorer $db,\n\t\tprotected ?Cache $cache = null,\n\t) {\n\t}\n\n")
	methods := 4 + r.IntN(14)
	for j := 0; j < methods; j++ {
		fmt.Fprintf(&b, "\t/**\n\t * @param int $id\n\t * @return list<T>\n\t */\n\tpublic function method%d(int $id, string ...$rest): array\n\t{\n", j)
		fmt.Fprintf(&b, "\t\t$result = [];\n\t\tforeach ($this->items%d as $key => $value) {\n\t\t\tif ($value > $id && isset($rest[0])) {\n\t\t\t\t$result[] = sprintf(\"%%s-%%d {$key}\", $rest[0], $value);\n\t\t\t}\n\t\t}\n", r.IntN(2))
		fmt.Fprintf(&b, "\t\t$fn = fn(int $x): int => $x * %d;\n\t\t$cb = function ($y) use ($id) {\n\t\t\treturn $y?->value ?? $id;\n\t\t};\n", r.IntN(9)+1)
		if j%5 == 0 {
			fmt.Fprintf(&b, "\t\t$sql = <<<SQL\n\t\t\tSELECT * FROM table_%d WHERE id = {$id}\n\t\t\tSQL;\n", j)
		}
		fmt.Fprintf(&b, "\t\treturn array_map($fn, $result ?: [self::LIMIT, static::class]);\n\t}\n\n")
	}
	fmt.Fprintf(&b, "\tpublic function getIterator(): \\Traversable\n\t{\n\t\tyield from $this->items0;\n\t}\n\n\tpublic function count(): int\n\t{\n\t\treturn \\count($this->items0);\n\t}\n}\n")
	if i%10 == 0 {
		fmt.Fprintf(&b, "\nfunction helper_%d(mixed $v): string\n{\n\treturn (string) $v;\n}\n", i)
	}
	return b.String()
}
