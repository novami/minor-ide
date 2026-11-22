// Spike S1 benchmark: scans every .php file under a directory in parallel and keeps all
// declaration results in memory, as an index would.
//
//	swift run -c release phpscan <dir>
import Darwin
import Dispatch
import Foundation
import os
import PHPKit

guard CommandLine.arguments.count == 2 else {
	FileHandle.standardError.write(Data("usage: phpscan <dir>\n".utf8))
	exit(2)
}
let root = CommandLine.arguments[1]

func footprintMB() -> Double {
	var info = task_vm_info_data_t()
	var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
	let kr = withUnsafeMutablePointer(to: &info) {
		$0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
	}
	return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

@Sendable func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

let walkStart = now()
var paths: [String] = []
if let e = FileManager.default.enumerator(atPath: root) {
	while let p = e.nextObject() as? String {
		let name = (p as NSString).lastPathComponent
		if name == ".git" || name == "node_modules" { e.skipDescendants(); continue }
		if p.hasSuffix(".php") { paths.append(root + "/" + p) }
	}
}
let walkTime = now() - walkStart
let baseline = footprintMB()

/// Per-worker results; each worker writes only its own slot.
final class Slots: @unchecked Sendable {
	var results: [[PHPFileDecls]]
	var bytes: [Int]
	var slowest: [(Double, String)]
	var unbalanced: [[String]]
	init(_ n: Int) {
		results = Array(repeating: [], count: n)
		bytes = Array(repeating: 0, count: n)
		slowest = Array(repeating: (0, ""), count: n)
		unbalanced = Array(repeating: [], count: n)
	}
}

let workers = ProcessInfo.processInfo.activeProcessorCount
let slots = Slots(workers)
let next = OSAllocatedUnfairLock(initialState: 0)
let allPaths = paths

let scanStart = now()
DispatchQueue.concurrentPerform(iterations: workers) { w in
	var scanner = PHPDeclarationScanner()
	var buffer = [UInt8](repeating: 0, count: 1 << 16)
	var results: [PHPFileDecls] = []
	var bytes = 0
	var slowest: (Double, String) = (0, "")
	var unbalanced: [String] = []
	while true {
		let i = next.withLock { n in defer { n += 1 }; return n }
		guard i < allPaths.count else { break }
		let path = allPaths[i]
		let fd = open(path, O_RDONLY)
		guard fd >= 0 else { continue }
		var st = stat()
		guard fstat(fd, &st) == 0, st.st_size >= 0, Int(st.st_size) < phpMaxSourceSize else { close(fd); continue }
		let size = Int(st.st_size)
		if buffer.count < size { buffer = [UInt8](repeating: 0, count: size) }
		let read = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, size) }
		close(fd)
		guard read >= 0 else { continue }
		let t0 = now()
		let r = buffer.withUnsafeBufferPointer { scanner.scan(UnsafeBufferPointer(rebasing: $0[0..<read])) }
		let d = now() - t0
		if d > slowest.0 { slowest = (d, path) }
		bytes += read
		if r.unbalanced { unbalanced.append(path) }
		results.append(r)
	}
	slots.results[w] = results
	slots.bytes[w] = bytes
	slots.slowest[w] = slowest
	slots.unbalanced[w] = unbalanced
}
let scanTime = now() - scanStart

let results = slots.results.flatMap { $0 }
let totalBytes = slots.bytes.reduce(0, +)
let slowest = slots.slowest.max { $0.0 < $1.0 } ?? (0, "")
let unbalanced = slots.unbalanced.flatMap { $0 }
var kinds = [PHPDeclKind: Int]()
var declCount = 0, resultBytes = 0
for r in results {
	resultBytes += r.memoryBytes
	declCount += r.decls.count
	for d in r.decls { kinds[d.kind, default: 0] += 1 }
}
let mb = Double(totalBytes) / 1_048_576
func f(_ x: Double, _ digits: Int = 0) -> String { String(format: "%.\(digits)f", x) }

print("files:      \(results.count) (\(f(mb, 1)) MB), \(workers) workers")
print("walk:       \(f(walkTime * 1000)) ms")
print("scan:       \(f(scanTime * 1000)) ms (\(f(mb / scanTime)) MB/s)")
print("slowest:    \(f(slowest.0 * 1e6)) µs \(slowest.1)")
print("decls:      \(declCount): " + PHPDeclKind.allCases.map { "\($0.label)=\(kinds[$0, default: 0])" }.joined(separator: " "))
print("results:    \(f(Double(resultBytes) / 1_048_576, 1)) MB held (\(results.isEmpty ? 0 : resultBytes / results.count) B per file)")
print("footprint:  \(f(baseline)) MB before scan, \(f(footprintMB())) MB after")
print("unbalanced: \(unbalanced.count)")
for p in unbalanced.prefix(10) { print("  \(p)") }
