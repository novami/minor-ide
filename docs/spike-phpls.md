# Spike 0.3: rychlost parsování PHP

Měřeno 2026-11-14 na M2 / 16 GB (8 jader), Go 1.27.4.
Nástroj: `minoride-server phpscan <dir>`: vlastní lexer PHP + skener deklarací (namespace, use, třídy, rozhraní, traity, enumy, funkce, metody, vlastnosti, konstanty, case), paralelně přes všechna jádra.

## Korpusy
- **nette/web-project** (`composer create-project`, Nette 3.2 + Latte + Tracy + PHPStan): 774 souborů, 2,9 MB.
- **Syntetický**: `go run ./cmd/phpcorpus -n 30000 -out <dir>`. 30 000 souborů, 173,5 MB, napodobuje vendor kód.
- **PEAR** z Homebrew PHP: 108 souborů.

## Výsledky (teplá cache souborů)

| Korpus | Před optimalizací | Po optimalizaci | Paměť | Neuzavřené závorky |
|---|---|---|---|---|
| nette/web-project | 23 ms | **12 ms** | 6 MB | 0 (předtím 2, viz níže) |
| Syntetický, 30 000 souborů | 0,99 s | **0,38 s** (460 MB/s) | 18–23 MB | 0 |
| Jedno vlákno, Nette (`go test -bench`) | 83 MB/s, 35 MB alokací | **220 MB/s, 1,4 MB alokací** | | |

Rozpočet „30 000 souborů pod 10 s“ je splněný **26×**.

## Co přineslo zrychlení
1. Znovupoužití bufferu tokenů mezi soubory (`sync.Pool`); alokace tokenů byly 12× větší než vstup.
2. Rozpoznání klíčových slov bez `strings.ToLower` (alokace u každého identifikátoru).
3. Operátory indexované podle prvního bajtu, jednoznakové porovnávané jako bajt.
4. Tabulka tříd znaků místo řetězců porovnání v lexeru.

## Chyba nalezená na Nette projektu
`$f = function () use (&$x) { … };` na úrovni souboru skener četl jako import `use` a ztratil složenou závorku (2 soubory v `nette/neon/examples`). Opraveno: import `use` jen na začátku příkazu. Má regresní test.

## Lexer
- Pokrývá PHP 7.2–8.4: inline HTML, `<?php`/`<?=`/`<?`, `?>` včetně ukončení řádkového komentáře, `#[`, heredoc/nowdoc (flexibilní syntaxe 7.3), `?->`, `??=`, kvalifikovaná jména, čísla s `_`, `0o`, Unicode identifikátory.
- Nikdy neselže: každý bajt patří právě jednomu tokenu. Fuzzing 20 s + 10 s po optimalizaci bez nálezu.
- Zjednodušení pro fázi 4a: interpolace v `"…"` a heredocu je zatím uvnitř jednoho tokenu; `1.` bez číslic za tečkou se lexuje jako `1` a `.`.
