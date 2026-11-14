# Spike 0.3: rychlost parsování PHP

Měřeno 2026-11-14 na M2 / 16 GB (8 jader), Go 1.27.4.
Nástroj: `minoride-server phpscan <dir>`: vlastní lexer PHP + skener deklarací (namespace, use, třídy, rozhraní, traity, enumy, funkce, metody, vlastnosti, konstanty, case), paralelně přes všechna jádra.

## Korpus
- **Syntetický**: `go run ./cmd/phpcorpus -n 30000 -out <dir>`. 30 000 souborů, 173,5 MB, napodobuje vendor kód (PHPDoc, atributy, generika v PHPDoc, closure, arrow funkce, heredoc, enumy, `?->`, `static::class`).
- **Reálný**: PEAR knihovny přibalené k Homebrew PHP, 108 souborů. Veřejné projekty (Nette `web-project`, Laravel) zatím nebyly staženy, čeká se na souhlas.

## Výsledky

| Korpus | Čas | Propustnost | Paměť (heap) | Neuzavřené závorky |
|---|---|---|---|---|
| Syntetický, 30 000 souborů | 0,99 s | 175 MB/s | 14 MB | 0 |
| PEAR, 108 souborů | 11 ms | 155 MB/s | 2 MB | 0 |

Nejpomalejší soubor: 1,2–2,5 ms. Nalezené deklarace sedí s generátorem (406 060 metod, 120 034 vlastností).

Rozpočet „30 000 souborů pod 10 s“ je splněný **10×**. Plný parser s AST bude pomalejší, ale rezerva stačí.

## Lexer
- Pokrývá PHP 7.2–8.4: inline HTML, `<?php`/`<?=`/`<?`, `?>` včetně ukončení řádkového komentáře, `#[`, heredoc/nowdoc (flexibilní syntaxe 7.3), `?->`, `??=`, kvalifikovaná jména, čísla s `_`, `0o`, Unicode identifikátory.
- Nikdy neselže: každý bajt patří právě jednomu tokenu. Ověřeno fuzzingem (6,6 mil. vstupů / 20 s).
- Zjednodušení pro fázi 4a: interpolace v `"…"` a heredocu je zatím uvnitř jednoho tokenu; `1.` bez číslic za tečkou se lexuje jako `1` a `.`.
