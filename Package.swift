// swift-tools-version:6.0
import PackageDescription

let package = Package(
	name: "MinorIDE",
	platforms: [.macOS(.v14)],
	products: [
		.executable(name: "MinorIDE", targets: ["MinorIDE"]),
	],
	targets: [
		.target(name: "MinorCore"),
		.target(name: "TextEngine"),
		.target(name: "Highlight", dependencies: ["TextEngine"]),
		.target(name: "EditorKit", dependencies: ["TextEngine", "MinorCore", "Highlight"]),
		.target(name: "DBKit", dependencies: ["MinorCore"]),
		.executableTarget(name: "MinorIDE", dependencies: ["MinorCore", "TextEngine", "EditorKit", "Highlight"]),
		.testTarget(name: "TextEngineTests", dependencies: ["TextEngine"]),
		.testTarget(name: "MinorCoreTests", dependencies: ["MinorCore"]),
		.testTarget(name: "DBKitTests", dependencies: ["DBKit"]),
		.testTarget(name: "EditorKitTests", dependencies: ["EditorKit", "MinorCore"]),
		.testTarget(name: "HighlightTests", dependencies: ["Highlight", "TextEngine"], exclude: ["Golden"]),
	]
)
