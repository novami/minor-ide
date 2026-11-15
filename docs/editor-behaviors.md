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
