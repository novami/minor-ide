// swift-tools-version:6.0
import PackageDescription

let package = Package(
	name: "MinorIDE",
	platforms: [.macOS(.v14)],
	products: [
		.executable(name: "MinorIDE", targets: ["MinorIDE"]),
	],
	dependencies: [
		// Pinned exactly (security: dependencies are updated by hand after reading the changes).
		.package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
	],
	targets: [
		.target(name: "MinorCore"),
		.target(name: "TextEngine"),
		.target(name: "Highlight", dependencies: ["TextEngine"]),
		.target(name: "EditorKit", dependencies: ["TextEngine", "MinorCore", "Highlight"]),
		.target(name: "DBKit", dependencies: ["MinorCore"]),
		.target(name: "SecretsKit"),
		.target(name: "RemoteKit", dependencies: ["MinorCore"]),
		.target(name: "LSPKit", dependencies: ["MinorCore", "TextEngine"]),
		.executableTarget(name: "MinorIDE", dependencies: ["MinorCore", "TextEngine", "EditorKit", "Highlight", "SecretsKit", "DBKit", "RemoteKit",
		                                                .product(name: "SwiftTerm", package: "SwiftTerm")]),
		.testTarget(name: "TextEngineTests", dependencies: ["TextEngine"]),
		.testTarget(name: "MinorCoreTests", dependencies: ["MinorCore"]),
		.testTarget(name: "DBKitTests", dependencies: ["DBKit"]),
		.testTarget(name: "SecretsKitTests", dependencies: ["SecretsKit"]),
		.testTarget(name: "RemoteKitTests", dependencies: ["RemoteKit"]),
		.testTarget(name: "LSPKitTests", dependencies: ["LSPKit", "MinorCore", "TextEngine"]),
		.testTarget(name: "EditorKitTests", dependencies: ["EditorKit", "MinorCore"]),
		.testTarget(name: "HighlightTests", dependencies: ["Highlight", "TextEngine"], exclude: ["Golden"]),
	]
)
