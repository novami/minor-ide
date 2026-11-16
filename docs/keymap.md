# Keymapa

Zkratky jsou položky standardního menu (Apple HIG); vazby mimo menu jdou přes systémové
`doCommandBySelector` (⌃A, ⌃E, ⌥←, `DefaultKeyBinding.dict`).

**Rozložení klávesnice:** písmenné zkratky platí podle znaku (QWERTZ i QWERTY). Interpunkční
(`/ [ ] \ ;` …) přemapuje macOS sám podle fyzické klávesy amerického rozložení
(`NSMenuItem.allowsAutomaticKeyEquivalentLocalization`, výchozí od macOS 12) a menu ukazuje
skutečnou klávesu aktuálního rozložení. Na české klávesnici je tedy „Zakomentovat výběr“ ⌘ +
klávesa vpravo od tečky. Ruční ověření na české klávesnici zbývá.

| Akce | Zkratka | Menu |
|---|---|---|
| Nový / Otevřít… / Zavřít | ⌘N / ⌘O / ⌘W | Soubor |
| Rychle otevřít… (soubor projektu podle jména, `název:řádek`; ⌥Return do druhé části) | ⇧⌘O | Soubor |
| Uložit / Uložit jako… | ⌘S / ⇧⌘S | Soubor |
| Nastavení… | ⌘, | MinorIDE |
| Zpět / Znovu | ⌘Z / ⇧⌘Z | Úpravy |
| Vyjmout / Kopírovat / Vložit / Vybrat vše | ⌘X / ⌘C / ⌘V / ⌘A | Úpravy |
| Vybrat další výskyt / všechny výskyty | ⌃G / ⌃⌘G | Úpravy |
| Duplikovat řádek | ⇧⌘D | Úpravy |
| Přesunout řádek nahoru / dolů | ⌥⌘↑ / ⌥⌘↓ | Úpravy |
| Zakomentovat výběr | ⌘/ | Úpravy |
| Najít… / Najít a nahradit… | ⌘F / ⌥⌘F | Úpravy › Najít |
| Najít v projektu… (spodní panel Hledat; Return otevře výsledek, Delete ho vyřadí) | ⇧⌘F | Úpravy › Najít |
| Najít další / předchozí | ⌘G / ⇧⌘G | Úpravy › Najít |
| Použít výběr pro hledání / nahrazení | ⌘E / ⇧⌘E | Úpravy › Najít |
| Přejít na výběr | ⌘J | Úpravy › Najít |
| Sbalit / Rozbalit | ⌥⌘← / ⌥⌘→ | Zobrazení › Sbalování kódu |
| Sbalit vše / Rozbalit vše | ⌥⇧⌘← / ⌥⇧⌘→ | Zobrazení › Sbalování kódu |
| Nový panel terminálu (víc shellů ve spodním panelu) | ⌃⇧` | Zobrazení |
| Rozdělit editor vedle sebe / pod sebe | — | Zobrazení |
| Otevřít soubor ze stromu ve druhé části | ⌥+klik, ⌥Return | kontextové menu stromu |
| Zavřít část rozděleného editoru | ⌘W (zavírací tlačítko zavře okno) | Soubor › Zavřít |
| Celá obrazovka | ⌃⌘F | Zobrazení |
| Minimalizovat | ⌘M | Okno |
| Uvítací okno | ⇧⌘1 | Okno |
| Nápověda | ⌘? | Nápověda |

Taby jsou nativní taby oken macOS (rozhodnutí 2026-11-15): Zobrazit další/předchozí tab
⌃Tab / ⌃⇧Tab, Sloučit všechna okna a Zobrazit všechny taby dodá systém v menu Okno.
