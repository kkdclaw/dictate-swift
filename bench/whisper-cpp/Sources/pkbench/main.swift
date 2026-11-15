// Ф0: Parakeet TDT v3 через whisper.cpp (parakeet.h, Metal). Словаря-подсказки у Parakeet нет. Вывод JSONL.
import AVFoundation
import Foundation
import whisper

struct Row: Decodable { let id: Int }
let a = CommandLine.arguments
let (manifest, audioDir, modelPath, out) = (a[1], a[2], a[3], a[4])
let limit = a.count > 5 ? Int(a[5])! : 0
var rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
if limit > 0 { rows = Array(rows.prefix(limit)) }

func loadWav(_ path: String) throws -> [Float] {
    let f = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
    try f.read(into: buf)
    return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
}

parakeet_log_set({ _, _, _ in }, nil)
let t0 = Date()
var cp = parakeet_context_default_params()
cp.use_gpu = ProcessInfo.processInfo.environment["NO_GPU"] == nil
guard let ctx = parakeet_init_from_file_with_params(modelPath, cp) else { fatalError("модель не загрузилась") }

func run(_ audio: [Float]) -> (String, Float) {
    var p = parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY)
    p.n_threads = 4
    p.no_context = true
    let rc = audio.withUnsafeBufferPointer { parakeet_full(ctx, p, $0.baseAddress, Int32($0.count)) }
    guard rc == 0 else { return ("<ошибка \(rc)>", 0) }
    var s = "", minP: Float = 1
    for i in 0..<parakeet_full_n_segments(ctx) {
        s += String(cString: parakeet_full_get_segment_text(ctx, i))
        for j in 0..<parakeet_full_n_tokens(ctx, i) { minP = min(minP, parakeet_full_get_token_data(ctx, i, j).p) }
    }
    return (s.trimmingCharacters(in: .whitespaces), minP)
}
_ = run([Float](repeating: 0, count: 8000))
let loadS = Date().timeIntervalSince(t0)

FileManager.default.createFile(atPath: out, contents: nil)
let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: out))
for r in rows {
    let audio = try loadWav("\(audioDir)/\(r.id).wav")
    let t = Date()
    let (text, minP) = run(audio)
    let dt = Date().timeIntervalSince(t)
    let line = try JSONSerialization.data(withJSONObject: ["id": r.id, "sec": (dt * 1000).rounded() / 1000,
                                                            "dur": Double(audio.count) / 16000, "text": text, "min_p": minP])
    fh.write(line); fh.write("\n".data(using: .utf8)!)
}
try fh.close()
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/footprint")
p.arguments = ["\(ProcessInfo.processInfo.processIdentifier)"]
let pipe = Pipe(); p.standardOutput = pipe; try p.run(); p.waitUntilExit()
let fp = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
let foot = fp.range(of: #"Footprint: [\d.]+ [KMG]B"#, options: .regularExpression).map { String(fp[$0].dropFirst(11)) } ?? "?"
parakeet_free(ctx)
print("{\"engine\": \"parakeet\", \"model\": \"\((modelPath as NSString).lastPathComponent)\", \"load_s\": \(String(format: "%.2f", loadS)), \"footprint\": \"\(foot)\"}")
