# Nastavení formátu: konce řádků, odsazení, kódování

## Výchozí hodnoty podle standardů

Všechny jazyky: **LF, UTF-8 bez BOM, prázdný řádek na konci souboru**, mezery na konci řádků se odstraní jen na řádcích, které jste změnili (staré soubory tak nedostanou diff přes celý soubor).

| Jazyk | Odsazení | Šířka tabulátoru | Zdroj |
|---|---|---|---|
| PHP | 4 mezery, řádek max. 120 | 4 | PSR-12 / PER-CS (preset `psr12`) |
| PHP s presetem `nette` | tabulátor | 4 | Nette Coding Standard |
| Go | tabulátor | 4 | gofmt |
| Latte, NEON | tabulátor | 4 | konvence Nette |
| JS, TS, Vue, CSS, SCSS, HTML, YAML | 2 mezery | 2 | Prettier; YAML tabulátory zakazuje |
| JSON | 2 mezery (`composer.json`/`.lock`: 4) | | Composer zapisuje 4 |
| Markdown | 2 mezery, mezery na konci se **nemažou** | | dvě mezery = zalomení řádku |
| Makefile | tabulátor | 8 | recepty musí začínat tabulátorem |
| `.bat`, `.cmd` | | | CRLF |
| ostatní | 4 mezery | 4 | |

## Pořadí priorit (pozdější vyhrává)

1. výchozí hodnoty jazyka (tabulka výše, případně zvolený preset),
2. uživatelské nastavení `~/Library/Application Support/MinorIDE/settings.json` (menu **MinorIDE → Nastavení…**),
3. nastavení projektu `<kořen projektu>/.minoride/settings.json`,
4. `.editorconfig` (standard https://editorconfig.org, hledá se od souboru nahoru až k `root = true`).

U **existujícího souboru** navíc:
- **konce řádků** zůstávají, jaké soubor má (CRLF zůstane CRLF). Smíšené konce se sjednotí na převažující a v titulku je „Mixed→…“;
- **odsazení** se rozpozná ze souboru (tabulátory vs. mezery a jejich počet), pokud ho neurčuje projekt ani `.editorconfig`. Vypíná se `"detect_indent": false`;
- **kódování** se rozpozná (BOM, UTF-8, jinak Windows-1250 pro starší české projekty) a při uložení se zachová.

Kořen projektu je nejbližší nadřazená složka s `.git`, `composer.json`, `go.mod` nebo `.minoride`.

## settings.json

Klíče jsou stejné jako v `.editorconfig`, sekce `"*"` platí pro všechny soubory, ostatní pro jazyk.

```json
{
  "detect_indent": true,
  "format": {
    "*":          { "end_of_line": "lf", "insert_final_newline": true, "trim_trailing_whitespace": "modified" },
    "php":        { "preset": "nette" },
    "go":         { "tab_width": 8 },
    "javascript": { "indent_size": 4 }
  }
}
```

| Klíč | Hodnoty |
|---|---|
| `indent_style` | `tab`, `space` |
| `indent_size` | 1–16, nebo `tab` (= šířka tabulátoru) |
| `tab_width` | 1–16 (výchozí = `indent_size`, když je zadané jen to) |
| `end_of_line` | `lf`, `crlf`, `cr` |
| `charset` | `utf-8`, `utf-8-bom`, `latin1`, `utf-16be`, `utf-16le`, `windows-1250`, `iso-8859-2` |
| `insert_final_newline` | `true`, `false` |
| `trim_trailing_whitespace` | `true` (celý soubor), `modified` (jen změněné řádky), `false` |
| `max_line_length` | číslo nebo `off` |
| `preset` | jen u `php`: `psr12`, `nette` |

Jazyky: `php`, `go`, `latte`, `neon`, `javascript`, `typescript`, `vue`, `json`, `css`, `scss`, `html`, `xml`, `yaml`, `markdown`, `sql`, `shell`, `batch`, `makefile`, `dockerfile`, `dotenv`, `text`.

## Rychlá změna pro otevřený soubor

Menu **Formát**: konce řádků (LF / CRLF / CR), odsazení (tabulátor / 2 / 4 mezery), šířka tabulátoru (2 / 4 / 8). Titulek okna ukazuje, jak se soubor uloží, např. `User.php — LF · 4 spaces · UTF-8`.

Změna konců řádků se projeví při uložení. Změna odsazení určuje, co vloží Tab a Enter. Stávající odsazení se zatím nepřevádí (příkaz „Převést odsazení“ přijde ve fázi 1c).

## Chování kláves
- **Tab**: tabulátor, nebo mezery k další zarážce podle `indent_size`.
- **Shift+Tab**: ubere jednu úroveň odsazení na začátku řádku.
- **Enter**: nový řádek převezme odsazení aktuálního řádku.
