import AppKit
import MinorCore
import ProjectKit
import QuartzCore

/// R3 benchmark: file catalog build, open by name and first Find in Files results on a real project.
/// Usage: `MinorIDE --bench-catalog <project>`.
@MainActor
enum CatalogBench {
	static func run(root: String) {
		let url = URL(fileURLWithPath: root)
		Task.detached {
			let index = PathIndex(root: url)
			let t0 = CACurrentMediaTime()
			await withCheckedContinuation { c in
				index.build()
				index.whenReady { c.resume() }
			}
			let build = (CACurrentMediaTime() - t0) * 1000
			print("files: \(index.count)")
			print(String(format: "catalog build (cold walk): %.0f ms", build))

			var times: [Double] = []
			for q in ["main", "usr", "readme", "ctrl", "servicephp", "a", "tests/foo", "config"] {
				let t = CACurrentMediaTime()
				_ = index.search(q)
				times.append((CACurrentMediaTime() - t) * 1000)
			}
			times.sort()
			print(String(format: "open by name: median %.1f ms, max %.1f ms", times[times.count / 2], times.last ?? 0))

			for query in ["function", "zzzqqq_no_match"] {
				let start = CACurrentMediaTime()
				nonisolated(unsafe) var first: Double?
				let summary = try? await FileSearcher.search(root: url, FileSearchOptions(query: query)) { _ in
					if first == nil { first = (CACurrentMediaTime() - start) * 1000 }
				}
				let total = (CACurrentMediaTime() - start) * 1000
				print(String(format: "find in files '%@': first result %@, total %.0f ms, files with matches %d", query,
				             first.map { String(format: "%.0f ms", $0) } ?? "none", total, summary?.files ?? 0))
			}
			exit(0)
		}
	}
}
