# Spike 0.2: vlastní editor (rope + Core Text)

Měřeno 2026-11-14 na M2 / 16 GB, macOS 27.2, release build, `make bench` (3 běhy, uvedený typický).
Dokument: 10 MB syntetického Go kódu s diakritikou, tabulátory a emoji, 234 530 řádků.

| Měření (p50 / p99 / max) | První verze | Po optimalizaci | Rozpočet |
|---|---|---|---|
| Otevření + první vykreslení | 48 ms | 45 ms | < 300 ms |
| Psaní znaku | 0,76 / 1,34 / 1,36 ms | **0,06 / 0,08 / 0,45 ms** | < 8 ms |
| Enter (posun řádků) | 0,19 / 0,30 / 0,30 ms | 0,16 / 0,26 / 0,27 ms | < 8 ms |
| Backspace | 0,45 / 1,36 / 1,76 ms | **0,14 / 0,26 / 0,30 ms** | < 8 ms |
| Scroll po 40 px | 0,20 / 0,30 / 0,35 ms | **0,10 / 0,17 / 0,38 ms** | snímek < 8 ms |
| Skok na náhodné místo (43 nových řádků) | 0,72 / 0,90 / 0,90 ms | **0,41 / 0,69 / 0,73 ms** | snímek < 8 ms |
| 1 000 000 editací ropu (10 MB) | 2,46 s | **0,90 s** | < 2 s |

Rozklad jednoho stisku po optimalizaci: editace ropu 0,003 ms, vlastní kreslení 0,037 ms, režie AppKit/Core Animation 0,020 ms.

## Co přineslo zrychlení
1. **Rychlá cesta pro glyfy** (`LineLayout`): znaky řádku se mapují přímo na glyfy monospace fontu a kreslí jedním `CTFontDrawGlyphs`. `CTLine` (plná sazba) zůstává jen pro řádky s emoji, kombinujícími znaky nebo písmy mimo latinku, řečtinu a cyrilici. Ověřeno: glyfy, šířky i pixely jsou s `CTLine` identické (čeština včetně).
2. **Pozice kurzoru** z ropu (`utf16Offset`) a z předpočítaných pozic řádku, bez kopírování textu.
3. **Rope upravuje uzly na místě**, pokud na ně neukazuje žádný snapshot (`isKnownUniquelyReferenced`), a souhrny přepočítává přírůstkově místo procházení celého listu. Snapshoty zůstávají neměnné (test s 10 snapshoty během 4 000 náhodných editací).
4. **Cache rozvržení řádků**: po Enteru se posune místo zahození a je omezená na okolí viditelné oblasti. Vyřazené položky se uvolňují na pozadí (jinak 2 ms špičky).

## Chyby nalezené kontrolou snímku (`--snapshot`)
- Převrácení přes text matrix posouvalo akcenty a po řádku s `CTLine` kreslilo další řádky jinde (Core Text přičítá pozici textu). Opraveno převrácením CTM a nulováním pozice textu.

## Jak se měří
- Čas = synchronní `displayIfNeeded()` po editaci nebo posunu. Počítadla `drawCount` / `drawnLines` ověřují, že se opravdu kreslí.
- Je to **dolní mez** latence. Skládání okna přidá zhruba jeden snímek (8 ms při 120 Hz). Měření stisk → zobrazený snímek přes `displayLink` přijde ve fázi 1b.
- „Psaní znaku“ píše 2 000 znaků do jednoho řádku (zátěžový případ, řádek roste).

## Co spike neřeší (fáze 1)
Selekce, undo, zvýraznění syntaxe (barevné běhy do rychlé cesty), horizontální scroll, šířka tabulátoru podle nastavení.
