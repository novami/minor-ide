# UI Guidelines

MinorIDE behaves like a native Mac app. Binding source: [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/).

## macOS standards

| Area | Rule |
|---|---|
| **Menu bar** | Order: *MinorIDE, File, Edit, Format, View, Navigate, Code, Window, Help*. App menu: About, Settings… (⌘,), Services, Hide (⌘H), Hide Others (⌥⌘H), Show All, Quit (⌘Q). Edit always has Undo/Redo, Cut/Copy/Paste, Select All and Find. Window: Minimize (⌘M), Zoom, Bring All to Front. Help has the system menu search. Every IDE action is reachable from a menu, even when it has a shortcut. |
| **Shortcuts** | System shortcuts are never overridden (⌘Q, ⌘H, ⌘M, ⌘Tab, ⌘Space, ⌘\`, ⌃⌘F). Standard text shortcuts always work (⌘Z, ⇧⌘Z, ⌘X/C/V, ⌘A, ⌘F, ⌘G, ⌘S, ⌘W, ⌘N, ⌘O, ⌘,). IDE shortcuts ([keymap.md](keymap.md)) only where they do not collide: ⌘E and ⇧⌘E stay "Use Selection for Find / Replace" (Recent Files is ⌃⌘E); ⌃Space often switches input sources, so completion also has ⌥Esc. Letter shortcuts follow the **character** (as the system does); only punctuation follows the physical key. Custom key bindings are checked for conflicts. |
| **Windows** | Project window: navigator on the left, editor in the center, hideable panels on the right and bottom, unified toolbar. Full screen, window restoration, Open Recent (`NSDocumentController`), open by drag onto the Dock or window and from Finder. Native window tabs. |
| **Dialogs** | Window-related questions are *sheets*, not app-modal dialogs. Save changes: *Save / Cancel / Don't Save* with standard texts. Standard `NSOpenPanel` and `NSSavePanel`. |
| **Settings** | Separate *Settings* window (⌘,) with toolbar tabs; changes apply immediately, without OK/Cancel. Same data as `settings.json`. |
| **Appearance** | System colors and accent color, light and dark mode, system font in the UI, SF Symbols, context menus on right click, two-finger swipe for back and forward in navigation. |
| **Accessibility** | VoiceOver, Increase Contrast, Reduce Motion, Reduce Transparency, full keyboard control. |
| **Permissions** | `Info.plist` describes system prompts (`NSLocalNetworkUsageDescription` for databases and SSH on the local network, `NSDocumentsFolderUsageDescription`, `NSDesktopFolderUsageDescription`, `NSDownloadsFolderUsageDescription`), localized through generated `InfoPlist.strings`. |
| **Language** | English (US) by default, Czech always complete, more languages by adding one file ([LOCALIZATION.md](LOCALIZATION.md)). No hard-coded UI text. |

## Experience

| Area | Rule |
|---|---|
| **Dashboard (welcome window)** | Recent projects and files, health of tools, runtimes and Docker, last test results, quick actions (open folder, clone, new connection). |
| **First launch** | Tool check with one button per missing tool; no multi-step wizard. |
| **Status bar** | Language, line endings, indentation, encoding (click to change), caret position, Git branch, indexing state, project trust mode. |
| **Background work** | Indexing, analysis, tests and Docker actions never block the UI: progress in the status bar and a Tasks panel with cancel. Modal progress is forbidden. |
| **Errors** | Human and in the UI language: what happened, why, what to do (an action button). Technical detail is expandable. Never just "Error -1". |
| **Empty states** | Every empty panel says what belongs there and how to fill it. |
| **Font size** | ⌘+ / ⌘− / ⌘0 in the editor, optional ligatures, choice of monospaced font. |
| **Safe actions** | Destructive operations (delete file, replace in files, `DELETE` without `WHERE`, `docker compose down -v`, `composer update`) always have a preview and confirmation. Deleted files go to the Trash. |
| **Production** | A database marked as production shows a red bar, confirms writes and opens read-only by default. |
| **Discoverability** | Advanced features are reachable from menus and the command search; defaults are sensible; nothing in the main navigation exposes internal subsystems. |
