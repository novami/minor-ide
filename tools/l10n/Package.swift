// swift-tools-version:6.2
import PackageDescription

// Developer tool, not part of the app: generates and validates the localization accessors.
// Run through tools/l10n.sh from the repository root.
let package = Package(
	name: "l10n",
	platforms: [.macOS(.v26)],
	targets: [
		.target(name: "L10nKit", path: "L10nKit"),
		.executableTarget(name: "l10n", dependencies: ["L10nKit"], path: ".", exclude: ["Package.swift"], sources: ["main.swift"]),
	]
)
