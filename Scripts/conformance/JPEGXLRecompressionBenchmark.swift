import Foundation
import CryptoKit
import DicomJPEGXL

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let data = try Data(contentsOf: input)
let repeats = Int(CommandLine.arguments[2])!
let mode = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "both"
func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
var encode: [Double] = [], decode: [Double] = []
var encodedHashes: Set<String> = [], decodedHashes: Set<String> = []
var encoded = Data()
for i in 0...repeats {
    let begin = DispatchTime.now().uptimeNanoseconds
    encoded = try JXLEncoder().encodeLosslessJPEG(data).data
    let encodedAt = DispatchTime.now().uptimeNanoseconds
    let reconstructed = mode == "encode" ? data : try JXLDecoder().decodeLosslessJPEG(encoded)
    let decodedAt = DispatchTime.now().uptimeNanoseconds
    if i > 0 {
        encode.append(Double(encodedAt - begin) / 1_000_000)
        decode.append(Double(decodedAt - encodedAt) / 1_000_000)
    }
    encodedHashes.insert(hash(encoded))
    decodedHashes.insert(hash(reconstructed))
}
if CommandLine.arguments.count > 4 { try encoded.write(to: URL(fileURLWithPath: CommandLine.arguments[4])) }
let output: [String: Any] = ["encodeMilliseconds": encode, "decodeMilliseconds": decode,
 "inputSHA256": hash(data), "encodedSHA256": encodedHashes.sorted(), "reconstructedSHA256": decodedHashes.sorted(),
 "inputBytes": data.count, "encodedBytes": encoded.count]
print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), encoding: .utf8)!)
