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
		.target(name: "EditorKit", dependencies: ["TextEngine"]),
		.target(name: "DBKit", dependencies: ["MinorCore"]),
		.executableTarget(name: "MinorIDE", dependencies: ["MinorCore", "TextEngine", "EditorKit"]),
		.testTarget(name: "TextEngineTests", dependencies: ["TextEngine"]),
		.testTarget(name: "DBKitTests", dependencies: ["DBKit"]),
	]
)
