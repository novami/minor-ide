# Chování editoru (checklist)

Každý bod má test (soubor v `Tests/`) nebo je označen jako ruční kontrola. Doplňuje se s každým novým příkazem.

## Psaní a mazání
- [x] Psaní nahradí každý výběr, víc kurzorů píše najednou — `SelectionEditingTests.typingReplacesEverySelection`
- [x] Sousední kurzory se při mazání sloučí — `SelectionEditingTests.adjacentCaretsMergeWhenDeleting`
- [x] Česká diakritika, mrtvé klávesy ˇ ´ °, nahrazení rozsahu (IME) — `TextInputTests`; ruční kontrola na skutečné klávesnici zbývá
- [x] Systémové vazby (⌥←/→, ⌥⌫, ⌘⌫, ⌃A/⌃E/⌃K/⌃Y/⌃T) — `TextInputTests`
- [x] Tab po zarážku, Shift+Tab ubere úroveň, Enter převezme odsazení — `IndentTests`

## Výběr a myš
- [x] Shift+šipky rozšiřují, šipky sbalí výběr — `SelectionEditingTests.shiftArrowsExtendAndArrowsCollapse`
- [x] Esc ponechá jen hlavní kurzor — `SelectionEditingTests.escapeKeepsPrimaryOnly`
- [x] Klik, dvojklik, trojklik, tažení, Shift/⌥+klik, ⌥+tažení — `MouseTests`

## Řádky (⇧⌘D, ⌥⌘↑, ⌥⌘↓)
- [x] Duplikace zkopíruje řádky výběrů pod ně, kurzory přejdou do kopie; jeden krok Zpět — `LineCommandTests.duplicateMovesCaretsToCopy`
- [x] Přesun prohodí blok s řádkem nad/pod, výběr jde s ním; na okraji dokumentu nic neudělá (položka menu je vypnutá) — `LineCommandTests.moveLinesKeepsSelectionAndStopsAtEdges`
- [x] Výběr končící na začátku řádku ten řádek nezahrnuje (i u Shift+Tab)

## Výskyty (⌃G, ⌃⌘G)
- [x] ⌃G bez výběru vybere slovo u kurzoru, dál přidá další výskyt (dokola, vybrané přeskočí) — `LineCommandTests.nextOccurrenceMatchesWholeWordsAndWraps`
- [x] Celé slovo hledá jen celá slova („id“ nenajde „idx“), část slova hledá i uvnitř slov — `LineCommandTests.occurrencesOfPartialSelectionMatchInsideWords`
- [x] Rozlišuje velikost písmen

## Odsazení
- [x] „Převést odsazení“ (Formát › Odsazení): tabulátor = úroveň, `indentSize` mezer = úroveň, zbylé mezery zůstanou (zarovnání) — `LineCommandTests.convertIndentationBothWays`

## Hledat a nahradit (⌘F, ⌥⌘F, ⌘G, ⇧⌘G, ⌘E, ⇧⌘E, ⌘J)
- [x] Prostý text bez rozlišení velikosti písmen, volby Aa (velikost), W (celá slova), .* (regex; ^ a $ na hranicích řádků) — `FindTests`
- [x] Neplatný regex hlásí „Neplatný výraz“, prázdné shody se přeskočí — `FindTests.regexAnchorsAtLinesAndReportsErrors`
- [x] Nahrazení regexem rozvine $1 a \n, \t; prostý text bere šablonu doslova — `FindTests.replacementsExpandGroupsAndEscapes`
- [x] Zachování velikosti písmen (VELKÁ, Velká, malá) — `FindTests.preserveCaseFollowsMatch`
- [x] Psaní do pole vybere první shodu od místa, kde hledání začalo; ⌘G/⇧⌘G jdou dokola — `FindControllerTests.incrementalFindSelectsFromOriginAndWraps`
- [x] Nahradit vybranou shodu a přejít na další; Nahradit vše je jeden krok Zpět — `FindControllerTests.replaceAndFindThenReplaceAllIsOneUndo`
- [x] Zvýraznění shod jdou s editací, se zavřenou lištou zmizí — `FindControllerTests.highlightsFollowTypingAndHideWithBar`
- [x] Hledá se mimo hlavní vlákno nad snímkem ropu; novější dotaz nebo editace starší výsledek zahodí
- [ ] Sdílená schránka hledání macOS (⌘E v jiné aplikaci → ⌘G tady) — ruční kontrola (zbývá)
- [ ] Lišta: Return další, Shift+Return předchozí, Esc zavře a vrátí fokus editoru — ruční kontrola (zbývá)
