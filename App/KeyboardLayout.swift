import AppKit
import Carbon

/// Punctuation shortcuts by physical key: the menu item takes the character the key of the
/// US layout's punctuation types in the current layout (Czech: "/" key types "-"), so the
/// menu shows the real key and pressing it works. Letters stay by character (HIG).
@MainActor
enum KeyboardLayout {
	private static var items: [(item: NSMenuItem, keyCode: UInt16, fallback: String)] = []
	private static var observing = false

	/// Binds a menu item to a physical key (kVK_ANSI_… code).
	static func bind(_ item: NSMenuItem, keyCode: UInt16) {
		item.allowsAutomaticKeyEquivalentLocalization = false
		items.append((item, keyCode, item.keyEquivalent))
		update(item, keyCode: keyCode, fallback: item.keyEquivalent)
		guard !observing else { return }
		observing = true
		DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
		                                                    object: nil, queue: .main) { _ in
			MainActor.assumeIsolated { for entry in items { update(entry.item, keyCode: entry.keyCode, fallback: entry.fallback) } }
		}
	}

	private static func update(_ item: NSMenuItem, keyCode: UInt16, fallback: String) {
		item.keyEquivalent = character(forKeyCode: keyCode) ?? fallback
	}

	/// What the key types in the current layout without modifiers.
	static func character(forKeyCode code: UInt16) -> String? {
		guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
		      let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
		let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
		var deadKeys: UInt32 = 0
		var chars = [UniChar](repeating: 0, count: 4)
		var length = 0
		let status = data.withUnsafeBytes { buffer -> OSStatus in
			guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
			return UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
			                      OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
		}
		guard status == noErr, length > 0 else { return nil }
		let s = String(utf16CodeUnits: chars, count: length)
		return s.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) ? nil : s
	}
}
