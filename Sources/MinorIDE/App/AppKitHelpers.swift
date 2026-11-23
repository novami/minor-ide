import AppKit

/// The string AppKit uses for a function or arrow key (NSF1FunctionKey, NSUpArrowFunctionKey…).
func functionKeyString(_ code: Int) -> String {
	UnicodeScalar(code).map { String(Character($0)) } ?? ""
}

extension NSImage {
	/// An SF Symbol; an empty image when the name is unknown to this macOS version.
	static func symbol(_ name: String, _ description: String?) -> NSImage {
		NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
	}
}

extension NSMenuItem {
	/// The submenu, or an empty menu for an item without one (menus are built in code, so this is never hit).
	var menuOrEmpty: NSMenu { submenu ?? NSMenu() }
}
