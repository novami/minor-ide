import Foundation

/// Localized UI text. Keys are the English strings; translations live in
/// Resources/<lang>.lproj/Localizable.strings (copied into the app bundle by tools/bundle.sh).
/// Outside the bundle (swift run, tests) the English key is shown.
func L(_ key: String) -> String {
	NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: "")
}

/// Localized format string, e.g. L("Do you want to save the changes made to the document “%@”?", name).
func L(_ key: String, _ args: CVarArg...) -> String {
	String(format: L(key), arguments: args)
}
