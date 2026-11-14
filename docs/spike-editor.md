# Spike 0.2: vlastní editor (rope + Core Text)

Měřeno 2026-11-14 na M2 / 16 GB, macOS 27.2, release build, `make bench`.
Dokument: 10 MB syntetického Go kódu s diakritikou, tabulátory a emoji, 234 530 řádků.

| Měření | Výsledek | Rozpočet | Stav |
|---|---|---|---|
| Otevření + první vykreslení | 48 ms (163 ms za studena) | < 300 ms | ✔ |
| Psaní znaku (p50 / p99 / max) | 0,76 / 1,34 / 1,36 ms | < 8 ms, max 16 ms | ✔ |
| Enter (posun řádků) | 0,19 / 0,30 / 0,30 ms | < 8 ms | ✔ |
| Backspace | 0,45 / 1,36 / 1,76 ms | < 8 ms | ✔ |
| Scroll po 40 px | 0,20 / 0,30 / 0,35 ms | snímek < 8 ms (120 Hz) | ✔ |
| Skok na náhodné místo (překreslení 43 řádků) | 0,72 / 0,90 / 0,90 ms | snímek < 8 ms | ✔ |
| 1 000 000 náhodných editací ropu (10 MB) | 2,46 s (2,5 µs/editace) | < 2 s | ✘ o 23 % |

## Jak se měří
- Čas = synchronní `displayIfNeeded()` po editaci nebo posunu. Každý krok opravdu kreslí (počítadlo `drawCount` / `drawnLines` v `EditorView`).
- Je to **dolní mez** latence na obrazovce. Skládání okna (compositing) přidá zhruba jeden snímek (8 ms při 120 Hz, 16 ms při 60 Hz). Měření keyDown → zobrazený snímek přes `displayLink` přijde ve fázi 1b.
- První verze skoku skákala mezi dvěma pozicemi a NSScrollView je bral z cache (2 kreslení z 200). Opraveno na různé pozice.

## Závěr
- Vlastní editor nad Core Text má **velkou rezervu**: překreslení obrazovky pod 1 ms, rozpočet je 8 ms. Volba D2 se potvrzuje.
- Rope je o 23 % nad cílem. Na psaní to vliv nemá (2,5 µs na editaci), jde o hromadné operace (nahradit vše, multi-cursor přes tisíce míst). Úkol pro 1a: měnit uzly na místě, když na ně neukazuje žádný snapshot (`isKnownUniquelyReferenced`), místo kopírování listu a cesty při každé editaci.

## Co spike neřeší (patří do fáze 1)
Selekce, undo, zvýraznění, cache layoutu při posunu řádků (teď se po Enteru zahodí cache od editovaného řádku dál), horizontální scroll, široké znaky v pozicích kurzoru (taby jsou zjednodušeně 4 mezery).
