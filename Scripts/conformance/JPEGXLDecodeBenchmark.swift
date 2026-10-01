import Foundation
import CryptoKit
import DicomJPEGXL

let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let repeats = Int(CommandLine.arguments[2])!
var times: [Double] = []
var hashes: Set<String> = []
for index in 0...repeats {
    let started = DispatchTime.now().uptimeNanoseconds
    let frame = try JXLDecoder().decode(data)
    let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    if index > 0 { times.append(ms) }
    hashes.insert(SHA256.hash(data: frame.data).map { String(format: "%02x", $0) }.joined())
}
print(String(data: try JSONSerialization.data(withJSONObject: ["milliseconds": times,
    "outputSHA256": hashes.sorted()], options: [.sortedKeys]), encoding: .utf8)!)
