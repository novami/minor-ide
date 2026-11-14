# Závislosti: knihovna, nebo vlastní implementace

Cíl: co nejméně knihoven třetích stran. Vlastní implementace tam, kde to dává smysl.
Časy jsou hrubé odhady pro jednoho vývojáře s AI, včetně testů. „Oproti knihovně“ je práce navíc u vlastní varianty.

Systémové frameworky macOS (AppKit, Core Text, CryptoKit, Security/Keychain, FSEvents, libsqlite3) a standardní knihovna Go se nepočítají jako závislosti.

## A. Rozhodnuto uživatelem

| # | Oblast | Rozhodnutí | Práce | Oproti knihovně |
|---|---|---|---|---|
| A1 | Text editor | **vlastní, Core Text + rope** | 12–16 týdnů | +10 týdnů (místo CodeEditSourceEditor a ~6 tranzitivních balíčků) |
| A2 | Parsování a zvýraznění | **vše vlastní**: lexery ve Swiftu, parsery PHP, Latte, NEON v Go | +10–14 týdnů | bez tree-sitter, bez cgo v PHP serveru |
| A3 | Aktualizace | **vlastní updater** (GitHub API, Ed25519 přes CryptoKit, code signature, pomocný proces) | 2 týdny | +1,5 týdne (místo Sparkle) |
| A4 | Terminál | **SwiftTerm** | 2–3 dny | vlastní emulátor by byl +5–8 týdnů |

## B. Rozhodnuto bez dotazu (dá se přebít)

| # | Oblast | Volba | Proč |
|---|---|---|---|
| B1 | Typy LSP (Swift i Go) | **vlastní** (3–5 dní) | potřebujeme jen podmnožinu protokolu |
| B2 | Hledání v souborech | **vlastní v Go** (1–2 týdny místo přibaleného ripgrep) | Go regexp (RE2) je dost rychlý |
| B3 | Build | **SPM + vlastní skript** na sestavení `.app` (2 dny místo XcodeGen) | žádný nástroj navíc |
| B4 | Go helpery | **jedna binárka `minoride-server`** s podpříkazy `phpls`, `db`, `search`, `remote` | méně artefaktů k podepisování |
| B5 | JSON-RPC, fuzzy matcher, diff (Myers), Git, Markdown pro release notes | **vlastní** / Git přes CLI / `AttributedString(markdown:)` | malé a dobře testovatelné |
| B6 | SSH tunel pro DB | **systémové `ssh -W`** jako dialer ovladače místo `x/crypto/ssh` | 0 závislostí, respektuje `~/.ssh/config`, ProxyJump a ssh-agent; na rozdíl od `ssh -L` neotevírá lokální port |
| B7 | SQLite | **systémová `libsqlite3` přes vlastní tenký cgo binding** (2–3 dny) | `modernc.org/sqlite` je obří strom závislostí |
| B8 | MySQL/MariaDB ovladač | **knihovna `go-sql-driver/mysql`** (1 malá závislost) | vlastní protokol včetně auth pluginů MariaDB a TLS: +3–4 týdny |
| B9 | PostgreSQL ovladač | **knihovna `jackc/pgx/v5`** (závislosti jen jackc + `golang.org/x`) | vlastní wire protokol, SCRAM a typy: +3–4 týdny |
| B10 | Stuby PHP funkcí | **oficiální `*.stub.php` ze zdrojů PHP** + stuby z repozitářů PECL rozšíření (data; rozhodnutí uživatele, D25 v `PLAN.md`) | ručně tisíce funkcí, nereálné; data od výrobce konkurenčního IDE nechceme. Cena: vlastní tabulka dostupnosti funkcí pro PHP 7.2–7.4 |
| B11 | SSH | **systémové OpenSSH** (`ssh`, `ssh -s sftp`, `ssh -W`, ControlMaster) | 0 závislostí, plná kompatibilita s `~/.ssh/config`, agenty a ProxyJump; bezpečnostně citlivé věci (klíče, known_hosts) řeší OpenSSH |
| B12 | SFTP | **vlastní klient protokolu v3 v Go** (≈ 2 týdny) místo `pkg/sftp` + `x/crypto/ssh` | rozhodnutí uživatele; vlastní SSH stack by byl bezpečnostní riziko |
| B13 | FTPS | **vlastní klient v Go nad `crypto/tls`** (≈ 1,5 týdne) | knihovny pro FTP jsou málo udržované; nešifrované FTP se nepodporuje |
| B14 | rsync | systémový `openrsync` / Homebrew `rsync` 3.x | externí nástroj, ne knihovna |
| B15 | Debugger | **vlastní DAP klient** (Swift), Go přes externí `dlv dap`. PHP v MVP přes **Tracy** (URL schéma `minoride://open`), Xdebug až po MVP vlastním adaptérem DBGp → DAP | 0 závislostí; Tracy nevyžaduje rozšíření v PHP ani naslouchající port |
| B16 | JS/TS, CSS, HTML | **externí LSP servery podle nastavení uživatele**, nic se nepřibaluje | vlastní inteligence pro web by byla další roky práce |

## Výsledná sada závislostí

- **Swift**: SwiftTerm.
- **Go**: `go-sql-driver/mysql` (**MPL-2.0**: souborový copyleft, s MIT aplikací slučitelný, pokud jeho soubory neměníme; uvést v Poděkováních), `jackc/pgx/v5` (MIT), `golang.org/x/*` (BSD).
- **Data**: oficiální stuby PHP (php-src a PECL rozšíření, B10).
- **Cena minimalizace**: MVP se prodloužilo z 6–9 na zhruba 14–17 měsíců čisté práce (18–22 s rezervou, viz `PLAN.md`).
