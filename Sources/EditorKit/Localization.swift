import Foundation

/// Localized UI text of the editor (same tables as the app: keys are the English strings).
func L(_ key: String) -> String {
	NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: "")
}
