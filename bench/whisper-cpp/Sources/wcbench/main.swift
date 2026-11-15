// Ф0: whisper.cpp (Metal) с initial_prompt, как в dictate. Вывод JSONL.
import AVFoundation
import Foundation
import whisper

struct Row: Decodable { let id: Int; let prompt: String }
let a = CommandLine.arguments
let (manifest, audioDir, modelPath, out) = (a[1], a[2], a[3], a[4])
let limit = a.count > 5 ? Int(a[5])! : 0
let env = ProcessInfo.processInfo.environment
let usePrompt = env["NO_PROMPT"] == nil
var rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
if limit > 0 { rows = Array(rows.prefix(limit)) }

func loadWav(_ path: String) throws -> [Float] {
    let f = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: false)
    precondition(f.processingFormat.sampleRate == 16000)
    let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
    try f.read(into: buf)
    return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
}

whisper_log_set({ _, _, _ in }, nil)
let t0 = Date()
var cp = whisper_context_default_params()
cp.use_gpu = true
cp.flash_attn = env["NO_FA"] == nil
guard let ctx = whisper_init_from_file_with_params(modelPath, cp) else { fatalError("модель не загрузилась") }

func run(_ audio: [Float], prompt: String?) -> String {
    var p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
    p.print_progress = false; p.print_realtime = false; p.print_timestamps = false; p.print_special = false
    p.n_threads = 4
    p.no_context = true
    p.single_segment = false
    let lang = strdup("ru"); defer { free(lang) }
    p.language = UnsafePointer(lang)
    let pr = prompt.map { strdup($0) }; defer { if let pr { free(pr) } }
    if let pr { p.initial_prompt = UnsafePointer(pr) }
    let rc = audio.withUnsafeBufferPointer { whisper_full(ctx, p, $0.baseAddress, Int32($0.count)) }
    guard rc == 0 else { return "<ошибка \(rc)>" }
    var s = ""
    for i in 0..<whisper_full_n_segments(ctx) { s += String(cString: whisper_full_get_segment_text(ctx, i)) }
    return s.trimmingCharacters(in: .whitespaces)
}
_ = run([Float](repeating: 0, count: 8000), prompt: nil)  // прогрев
let loadS = Date().timeIntervalSince(t0)

FileManager.default.createFile(atPath: out, contents: nil)
let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: out))
for r in rows {
    let audio = try loadWav("\(audioDir)/\(r.id).wav")
    let t = Date()
    let text = run(audio, prompt: usePrompt && !r.prompt.isEmpty ? r.prompt : nil)
    let dt = Date().timeIntervalSince(t)
    let line = try JSONSerialization.data(withJSONObject: ["id": r.id, "sec": (dt * 1000).rounded() / 1000,
                                                            "dur": Double(audio.count) / 16000, "text": text])
    fh.write(line); fh.write("\n".data(using: .utf8)!)
}
try fh.close()
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/footprint")
p.arguments = ["\(ProcessInfo.processInfo.processIdentifier)"]
let pipe = Pipe(); p.standardOutput = pipe; try p.run(); p.waitUntilExit()
let fp = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
let foot = fp.range(of: #"Footprint: [\d.]+ [KMG]B"#, options: .regularExpression).map { String(fp[$0].dropFirst(11)) } ?? "?"
whisper_free(ctx)
print("{\"engine\": \"whisper.cpp\", \"model\": \"\((modelPath as NSString).lastPathComponent)\", \"load_s\": \(String(format: "%.2f", loadS)), \"footprint\": \"\(foot)\", \"prompt\": \(usePrompt)}")
