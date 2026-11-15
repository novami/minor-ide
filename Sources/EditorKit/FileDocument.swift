import AppKit
import Highlight
import MinorCore
import TextEngine

/// One file open in the app: its text (shared by every editor showing it, in any window)
/// and what is needed to save it back in its own conventions. One instance per path,
/// found through `FileDocument.load`.
@MainActor
public final class FileDocument {
	/// Why the file on disk no longer matches the editor while it has unsaved changes.
	public enum DiskNotice: Equatable { case changed, deleted }

	/// Posted (object: the document) when the URL, format, edited flag or disk notice changes.
	public static let stateDidChange = Notification.Name("FileDocumentStateDidChange")

	/// Posted (object: the old document, `replacementKey`: the new one) when a document is
	/// saved over the path of another open one; editors of the old one switch to the new one.
	public static let didReplace = Notification.Name("FileDocumentDidReplace")
	public static let replacementKey = "replacement"

	public let text: TextDocument
	public private(set) var url: URL?
	/// Indentation, line ending and charset used when saving.
	public var format: FormatSettings {
		didSet {
			text.format = format
			post()
		}
	}
	public private(set) var resolved: ResolvedFormat?
	/// What the file itself showed when loaded (indentation, line endings), for re-resolving.
	private var detected: DetectedFormat?
	/// Set by Format menu changes: settings files no longer change this document's format.
	public var formatChosenByUser = false
	public private(set) var mixedLineEndings = false
	public private(set) var isEdited = false {
		didSet { if oldValue && !isEdited { removeBackup() } } // saved, reloaded or discarded
	}
	public private(set) var diskNotice: DiskNotice?
	private var originalLines: Set<Substring> = []
	/// Modification date and size of the file as last loaded or saved.
	private var diskStamp: FileStamp?

	/// An untitled document.
	public init(text: String = "", format: FormatSettings = FormatSettings()) {
		self.text = TextDocument(text: text)
		self.format = format
		self.text.format = format
		self.text.onChange = { [weak self] in
			self?.markEdited()
			self?.scheduleBackup()
		}
	}

	// MARK: One document per file

	private struct Entry { weak var document: FileDocument? }
	private static var registry: [String: Entry] = [:]

	private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

	/// Open documents with a file.
	public static var all: [FileDocument] { registry.values.compactMap(\.document) }

	public static func document(for url: URL) -> FileDocument? { registry[key(url)]?.document }

	/// The document of `url`: the open one, or the file decoded with its line endings kept and
	/// indentation resolved from language defaults, user and project settings, .editorconfig
	/// and the file itself.
	public static func load(_ url: URL) throws -> FileDocument {
		if let open = document(for: url) { return open }
		let data = try Data(contentsOf: url)
		let loaded = TextFile.load(data)
		let resolved = resolve(path: url.path, detected: loaded.detected)
		var format = resolved.settings
		format.charset = loaded.charset
		let doc = FileDocument(text: loaded.text, format: format)
		// Large and minified files open without colouring (plan: simplified mode).
		doc.text.language = TextFile.needsSimplifiedMode(data) ? nil : Languages.language(forPath: url.path)
		doc.url = url
		doc.resolved = resolved
		doc.detected = loaded.detected
		doc.originalLines = loaded.originalLines
		doc.diskStamp = FileStamp(url)
		doc.mixedLineEndings = loaded.detected.mixedLineEndings
		doc.register()
		return doc
	}

	private func register() {
		guard let url else { return }
		Self.registry = Self.registry.filter { $0.value.document != nil && $0.value.document !== self }
		let replaced = Self.registry[Self.key(url)]?.document
		Self.registry[Self.key(url)] = Entry(document: self)
		if let replaced {
			replaced.url = nil
			replaced.isEdited = false // its file now holds this document's text
			NotificationCenter.default.post(name: Self.didReplace, object: replaced, userInfo: [Self.replacementKey: self])
		}
	}

	public static func resolve(path: String, detected: DetectedFormat?) -> ResolvedFormat {
		let project = projectRoot(for: path).flatMap {
			SettingsFile.load(URL(fileURLWithPath: $0).appendingPathComponent(".minoride/settings.json"))
		}
		return FormatResolver.resolve(path: path, user: SettingsFile.load(SettingsFile.userURL), project: project,
		                              editorConfig: EditorConfig.properties(forFile: path), detected: detected)
	}

	/// Nearest parent with .git, composer.json or go.mod.
	public static func projectRoot(for path: String) -> String? {
		var dir = (path as NSString).deletingLastPathComponent
		let fm = FileManager.default
		while dir != "/" && !dir.isEmpty {
			for marker in [".git", "composer.json", "go.mod", ".minoride"] where fm.fileExists(atPath: dir + "/" + marker) {
				return dir
			}
			dir = (dir as NSString).deletingLastPathComponent
		}
		return nil
	}

	// MARK: State

	private func post() {
		NotificationCenter.default.post(name: Self.stateDidChange, object: self)
	}

	/// Runs on every keystroke: post only on the first change.
	private func markEdited() {
		guard !isEdited else { return }
		isEdited = true
		post()
	}

	/// The user chose not to save (closing): the text is dropped with its last editor.
	public func discardChanges() {
		isEdited = false
		post()
	}

	/// The file was renamed or its folder moved: follow it without touching the text.
	public func fileMoved(to newURL: URL) {
		url = newURL
		diskStamp = FileStamp(newURL)
		register()
		post()
	}

	public func setLineEnding(_ eol: LineEnding) {
		guard format.lineEnding != eol || mixedLineEndings else { return }
		mixedLineEndings = false
		isEdited = true
		formatChosenByUser = true
		format.lineEnding = eol
	}

	/// Status bar: the encoding the file is saved in (the text is converted when saving).
	public func setCharset(_ charset: Charset) {
		guard format.charset != charset else { return }
		isEdited = true
		formatChosenByUser = true
		format.charset = charset
	}

	/// settings.json or .editorconfig changed: resolve the format again (charset stays),
	/// unless the user chose it in the Format menu.
	public func settingsChanged() {
		guard let url, !formatChosenByUser else { return }
		let resolved = Self.resolve(path: url.path, detected: detected)
		self.resolved = resolved
		var format = resolved.settings
		format.charset = self.format.charset
		if format != self.format { self.format = format }
	}

	// MARK: Changes on disk

	/// Compares the file with the version loaded or saved: an unchanged document reloads
	/// quietly (keeping carets and scroll positions), an edited one gets a notice.
	public func checkDisk() {
		guard let url else { return }
		guard let now = FileStamp(url) else {
			guard diskStamp != nil else { return }
			diskStamp = nil
			isEdited = true // saving recreates the file
			diskNotice = .deleted
			post()
			return
		}
		guard now != diskStamp else { return }
		if isEdited {
			diskNotice = .changed
			post()
		} else {
			reload()
		}
	}

	/// Keeps the editor's text over the changed file (until it changes again).
	public func keepMine() {
		if let url { diskStamp = FileStamp(url) }
		diskNotice = nil
		post()
	}

	public func dismissDiskNotice() {
		diskNotice = nil
		post()
	}

	/// The file on disk decoded with this document's charset as the fallback.
	public func diskText() -> String? {
		guard let url, let data = try? Data(contentsOf: url) else { return nil }
		return TextFile.load(data, fallback: format.charset).text
	}

	/// Replaces the text with the file on disk as one undoable step.
	public func reload() {
		guard let url, let data = try? Data(contentsOf: url) else { return }
		let loaded = TextFile.load(data, fallback: format.charset)
		replaceText(loaded.text)
		originalLines = loaded.originalLines
		mixedLineEndings = loaded.detected.mixedLineEndings
		diskStamp = FileStamp(url)
		diskNotice = nil
		isEdited = false
		text.history.seal()
		post()
	}

	/// Replaces the whole text as one undoable step, keeping carets and scroll positions of
	/// every editor where they still fit. Needs an editor showing the document.
	private func replaceText(_ string: String) {
		let views = text.views
		guard string != text.rope.string, let source = views.first else { return }
		let states = views.map { ($0.selections, $0.visibleRect.origin) }
		source.replace([(0..<text.rope.byteCount, string)])
		let rope = text.rope
		for (view, (selections, origin)) in zip(views, states) {
			view.setSelections(selections.map { s in
				Selection(anchor: rope.scalarBoundary(atOrBefore: min(s.anchor, rope.byteCount)),
				          head: rope.scalarBoundary(atOrBefore: min(s.head, rope.byteCount)))
			})
			view.scroll(origin)
		}
	}

	// MARK: Crash recovery

	/// Where unsaved text is backed up; nil (tests, benchmark) keeps none.
	public static var backups: BackupStore?
	/// Backups are written and removed in order, off the main thread.
	private static let backupQueue = DispatchQueue(label: "MinorIDE.backups", qos: .utility)
	private let backupID = UUID().uuidString
	private var backupPending = false
	private var hasBackup = false

	/// Backs up the text at most every 2 seconds while it is being edited.
	private func scheduleBackup() {
		guard Self.backups != nil, !backupPending else { return }
		backupPending = true
		Task { @MainActor [weak self] in
			try? await Task.sleep(for: .seconds(2))
			self?.backUpNow()
		}
	}

	/// Writes the backup now (also right after recovering text).
	public func backUpNow() {
		backupPending = false
		guard isEdited, let store = Self.backups else { return }
		let rope = text.rope, id = backupID, path = url.map(Self.key)
		hasBackup = true
		Self.backupQueue.async { try? store.save(DocumentBackup(id: id, path: path, text: rope.string)) }
	}

	private func removeBackup() {
		guard hasBackup, let store = Self.backups else { return }
		hasBackup = false
		let id = backupID
		Self.backupQueue.async { store.remove(id) }
	}

	/// Waits until queued backups are written or removed (quitting).
	public static func flushBackups() { backupQueue.sync {} }

	/// Puts text recovered after a crash into the editor; the document stays unsaved and
	/// is backed up again at once.
	public func recover(_ string: String) {
		replaceText(string)
		if !isEdited { // the text equals the file: nothing was lost
			return
		}
		backUpNow()
	}

	// MARK: Local History

	/// Where saved versions are copied; nil (tests, benchmark) keeps no history.
	public static var history: LocalHistory?

	/// Saved versions of this file, newest first.
	public var versions: [LocalHistory.Version] {
		guard let url, let history = Self.history else { return [] }
		return history.versions(of: Self.key(url))
	}

	/// The text of a saved version, decoded like the file.
	public func text(of version: LocalHistory.Version) -> String? {
		guard let data = try? Data(contentsOf: version.url) else { return nil }
		return TextFile.load(data, fallback: format.charset).text
	}

	/// Puts a saved version into the editor as one undoable step; saving is up to the user.
	public func restore(_ version: LocalHistory.Version) {
		guard let string = text(of: version) else { return }
		replaceText(string)
	}

	// MARK: Saving

	/// Saves an edited file in place without asking (auto-save). Skipped for untitled files
	/// and while the file changed on disk, which would overwrite someone else's changes.
	@discardableResult
	public func autoSave() -> Bool {
		guard isEdited, diskNotice == nil, let url,
		      TextFile.firstUnencodable(text.rope.string, charset: format.charset) == nil else { return false }
		return (try? write(to: url)) != nil
	}

	/// Writes the text with the document's line ending, charset and trimming; the document
	/// takes `url` (Save As).
	public func write(to url: URL) throws {
		let string = text.rope.string
		let data = TextFile.save(string, settings: format, originalLines: originalLines)
		let key = Self.key(url)
		// The first save also keeps the version that was on disk before.
		if let history = Self.history, history.versions(of: key).isEmpty, let old = try? Data(contentsOf: url) {
			try? history.record(old, for: key, date: FileStamp(url)?.date ?? Date())
		}
		try TextFile.write(data, to: url)
		try? Self.history?.record(data, for: key)
		// Saved content becomes the new baseline for "trim modified lines".
		originalLines = Set(string.split(separator: "\n", omittingEmptySubsequences: false))
		if url.standardizedFileURL != self.url?.standardizedFileURL {
			self.url = url
			register()
		}
		mixedLineEndings = false
		isEdited = false
		diskStamp = FileStamp(url)
		diskNotice = nil
		text.history.seal()
		post()
	}
}

/// Identity of a file version on disk: modification date and size.
struct FileStamp: Equatable {
	let date: Date?
	let size: Int?

	/// Read from the file system each time (URL resource values are cached per URL).
	init?(_ url: URL) {
		guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
		      let date = attributes[.modificationDate] as? Date else { return nil }
		self.date = date
		size = (attributes[.size] as? NSNumber)?.intValue
	}
}
