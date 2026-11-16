import AppKit
import Highlight
import MinorCore
import TextEngine

/// The text of one file shared by its editors (split view): rope, undo history, anchors,
/// colouring and format. Selections, folds and scrolling belong to each `EditorView`.
@MainActor
public final class TextDocument {
	public private(set) var rope: Rope
	public internal(set) var history = EditHistory()
	/// Positions that follow edits, undo and redo included.
	public var anchors = AnchorSet()
	/// Called once after every text change, whichever view made it (dirty tracking).
	public var onChange: (() -> Void)?
	/// Shown but not editable (files too large to edit safely); editors refuse every change.
	public var isReadOnly = false
	/// Large or minified file (simplified mode): no colouring and no soft wrapping.
	public var isSimplified = false {
		didSet { if isSimplified != oldValue { for view in views { view.wrapSettingsChanged() } } }
	}

	/// Indentation and tab display. The buffer always uses "\n"; line endings and charset
	/// apply when saving.
	public var format = FormatSettings() {
		didSet {
			if format.tabWidth != oldValue.tabWidth {
				for view in views { view.tabWidthDidChange() }
				measureWidth()
			} else if format.maxLineLength != oldValue.maxLineLength {
				for view in views { view.wrapSettingsChanged() }
			}
		}
	}

	/// Language of the document: colouring, comments, brackets; nil for plain text.
	public var language: SyntaxLanguage? {
		didSet { highlighter = language.map { SyntaxHighlighter(lexer: $0.lexer, lineCount: rope.lineCount) } }
	}
	public var highlighter: SyntaxHighlighter? {
		didSet {
			for view in views { view.needsDisplay = true }
			scheduleBackgroundHighlight()
		}
	}
	private var backgroundHighlightRunning = false

	private struct WeakView { weak var view: EditorView? }
	private var viewRefs: [WeakView] = []
	/// Editors showing this document, in the order they were attached.
	public var views: [EditorView] { viewRefs.compactMap(\.view) }

	public init(text: String) {
		rope = Rope(text)
		measureWidth()
	}

	/// Replaces the text of a document no editor shows (rewriting a file that is not open).
	func setText(_ new: Rope) {
		precondition(views.isEmpty, "use an editor to change a shown document")
		rope = new
	}

	/// Columns of the widest line (horizontal scrolling). Edits widen it at once; narrowing
	/// waits for a full measure off the main thread after a pause in editing.
	public private(set) var maxColumns = 0
	private var widthGeneration = 0
	/// One waiting measure at a time; edits only move its due time (typing must stay cheap).
	private var widthDue: ContinuousClock.Instant = .now
	private var widthWaiting = false

	func measureWidth(after delay: Duration = .zero) {
		widthGeneration += 1
		widthDue = .now + delay
		guard !widthWaiting else { return }
		widthWaiting = true
		Task { [weak self] in
			while let due = self?.widthDue, due > .now { try? await Task.sleep(until: due) }
			guard let self else { return }
			widthWaiting = false
			let generation = widthGeneration, rope = rope, tabWidth = format.tabWidth
			let columns = await Task.detached(priority: .utility) { rope.maxColumns(tabWidth: tabWidth) }.value
			guard widthGeneration == generation else { return } // edited meanwhile: measured again later
			setMaxColumns(columns)
		}
	}

	private func setMaxColumns(_ columns: Int) {
		guard columns != maxColumns else { return }
		maxColumns = columns
		for view in views { view.updateSize() }
	}

	func attach(_ view: EditorView) {
		viewRefs.removeAll { $0.view == nil || $0.view === view }
		viewRefs.append(WeakView(view: view))
	}

	/// Stops `view` from following edits (a closed split pane).
	public func detach(_ view: EditorView) {
		viewRefs.removeAll { $0.view == nil || $0.view === view }
	}

	/// Lines touched by an edit, measured before it; every view repaints from it.
	struct Edit {
		var firstLine: Int
		var lastLine: Int
		var oldLines: Int
		/// No line breaks removed or inserted: every line keeps its number.
		var sameLines: Bool
		var editedLines: [Int]
		var newLastLine = 0
		var syntaxDirty: ClosedRange<Int>?
	}

	/// Applies an edit made in `source`. The source gets `selectionsAfter`, other views map
	/// their selections through the change.
	func apply(_ changes: ChangeSet, from source: EditorView, selectionsAfter: (ChangeSet) -> SelectionSet) {
		guard let firstChange = changes.changes.first, let lastChange = changes.changes.last else { return }
		let lastLine = rope.line(containing: lastChange.range.upperBound)
		let sameLines = changes.changes.allSatisfy { c in
			!c.text.contains(0x0A) && rope.line(containing: c.range.lowerBound) == rope.line(containing: c.range.upperBound)
		}
		var edit = Edit(firstLine: rope.line(containing: firstChange.range.lowerBound), lastLine: lastLine,
		                oldLines: rope.lineCount, sameLines: sameLines,
		                editedLines: sameLines ? changes.changes.map { rope.line(containing: $0.range.lowerBound) } : [])
		let editors = views
		for view in editors { view.willEdit() }

		changes.apply(to: &rope)
		anchors.apply(changes)
		edit.newLastLine = lastLine + rope.lineCount - edit.oldLines
		edit.syntaxDirty = highlighter?.edit(firstLine: edit.firstLine, oldLastLine: lastLine, newLastLine: edit.newLastLine, in: rope)
		let edited = rope.maxColumns(tabWidth: format.tabWidth, lines: edit.firstLine...edit.newLastLine)
		if edited > maxColumns { setMaxColumns(edited) }
		measureWidth(after: .seconds(1))

		for view in editors where view !== source {
			view.didEdit(changes, edit, selections: view.selections.mapped(through: changes), isSource: false)
		}
		source.didEdit(changes, edit, selections: selectionsAfter(changes), isSource: true)
		onChange?()
		if gitBase != nil { scheduleGitDiff(delay: .milliseconds(200)) }
		if let highlighter, highlighter.validUpTo < rope.lineCount - 1 { scheduleBackgroundHighlight(delay: .milliseconds(300)) }
	}

	/// Lexes the rest of the file off the main thread after an edit stopped short of it.
	func scheduleBackgroundHighlight(delay: Duration = .zero) {
		guard let highlighter, !backgroundHighlightRunning, highlighter.backgroundJob(rope: rope) != nil else { return }
		backgroundHighlightRunning = true
		Task { [weak self] in
			if delay > .zero { try? await Task.sleep(for: delay) }
			guard let self, let job = highlighter.backgroundJob(rope: rope) else {
				self?.backgroundHighlightRunning = false
				return
			}
			let states = await Task.detached(priority: .utility) { SyntaxHighlighter.lexStates(job) }.value
			backgroundHighlightRunning = false
			guard self.highlighter === highlighter else { return }
			if !highlighter.finishBackgroundJob(job, states: states) { scheduleBackgroundHighlight(delay: .milliseconds(300)) }
		}
	}

	// MARK: Git changes

	/// Lines of the file at Git HEAD; nil hides the change gutter (no repository, untracked
	/// file, Restricted Mode).
	public var gitBase: [Substring]? {
		didSet {
			if gitBase == nil { gitChanges = [] }
			scheduleGitDiff(delay: .zero)
		}
	}

	/// Changed lines against `gitBase`, recomputed off the main thread shortly after edits.
	public private(set) var gitChanges: [LineChange] = []
	private var gitGeneration = 0

	private func scheduleGitDiff(delay: Duration) {
		gitGeneration += 1
		let generation = gitGeneration
		guard let base = gitBase else { return views.forEach { $0.gutter?.needsDisplay = true } }
		Task { [weak self] in
			if delay > .zero { try? await Task.sleep(for: delay) }
			guard let self, generation == gitGeneration else { return }
			let rope = rope
			let changes = await Task.detached(priority: .utility) {
				LineChanges.compute(base: base, current: LineChanges.lines(rope.string))
			}.value
			guard generation == gitGeneration else { return }
			gitChanges = changes
			for view in views { view.gutter?.needsDisplay = true }
		}
	}
}
