import Foundation

/// Модель Whisper из формата MLX (кэш Python-версии, ~/.cache/huggingface) → ggml для whisper.cpp.
/// Порт tools/mlx2ggml.py, результат совпадает с ним побайтно. Отличия MLX от весов OpenAI:
/// свёртки (out, k, in) вместо (out, in, k); mlp1/mlp2 вместо mlp.0/mlp.2; encoder.positional_embedding
/// не хранится — считаем синусоиды сами. Квантованные MLX-модели (есть .scales) не поддерживаются.
public enum MLXConverter {
    public struct ConvError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        init(_ m: String) { message = m }
    }

    enum DType { case f16, f32, bf16, i64, other }

    struct Tensor {
        let dtype: DType
        let shape: [Int]
        let data: Data  // срез отображённого в память файла
    }

    /// Папка snapshot модели MLX в кэше HF (config.json + weights.safetensors/weights.npz) или nil.
    public static func cachedModel(repo: String, hub: URL = FileManager.default.homeDirectoryForCurrentUser
                                    .appendingPathComponent(".cache/huggingface/hub")) -> URL? {
        let dir = hub.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"))
            .appendingPathComponent("snapshots")
        let snaps = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for s in snaps.sorted() {
            let d = dir.appendingPathComponent(s)
            let fm = FileManager.default
            guard fm.fileExists(atPath: d.appendingPathComponent("config.json").path) else { continue }
            if fm.fileExists(atPath: d.appendingPathComponent("weights.safetensors").path)
                || fm.fileExists(atPath: d.appendingPathComponent("weights.npz").path) {
                return d
            }
            // языковые модели: model.safetensors или model-0000N-of-0000M.safetensors (+ токенизатор)
            let files = (try? fm.contentsOfDirectory(atPath: d.path)) ?? []
            if files.contains(where: { $0.hasPrefix("model") && $0.hasSuffix(".safetensors") }),
               files.contains("tokenizer.json") || files.contains("tokenizer_config.json") || files.contains("vocab.json") {
                return d
            }
        }
        return nil
    }

    /// Любой snapshot модели в кэше HF (без проверки состава) — для CoreML-моделей и т. п.
    public static func cachedSnapshot(repo: String, hub: URL = FileManager.default.homeDirectoryForCurrentUser
                                        .appendingPathComponent(".cache/huggingface/hub")) -> URL? {
        let dir = hub.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--")).appendingPathComponent("snapshots")
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted().first.map { dir.appendingPathComponent($0) }
    }

    public static func convert(modelDir: URL, assets: URL, output: URL) throws {
        let cfgData = try Data(contentsOf: modelDir.appendingPathComponent("config.json"))
        guard let hp = try JSONSerialization.jsonObject(with: cfgData) as? [String: Any] else { throw ConvError("config.json не прочитан") }
        if hp["d_model"] != nil { return try convertHF(modelDir: modelDir, hp: hp, assets: assets, output: output) }
        func h(_ k: String) throws -> Int {
            guard let v = hp[k] as? Int else { throw ConvError("в config.json нет \(k)") }
            return v
        }
        var w = try loadWeights(modelDir)
        if w.keys.contains(where: { $0.hasSuffix(".scales") }) {
            throw ConvError("квантованная модель MLX (есть .scales) — нужна fp16")
        }
        w.removeValue(forKey: "alignment_heads")

        let nMels = try h("n_mels")
        let mel = try Data(contentsOf: assets.appendingPathComponent("mel_\(nMels).f32"))
        let tik = try String(contentsOf: assets.appendingPathComponent("multilingual.tiktoken"), encoding: .utf8)

        let tmp = output.appendingPathExtension("part")
        defer { try? FileManager.default.removeItem(at: tmp) }  // недоделанный файл не оставляем
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let out = try FileHandle(forWritingTo: tmp)
        var buf = Data()
        func flush() { out.write(buf); buf.removeAll(keepingCapacity: true) }
        func i32(_ v: Int) { var x = Int32(v).littleEndian; withUnsafeBytes(of: &x) { buf.append(contentsOf: $0) } }

        i32(0x67676D6C)
        for k in ["n_vocab", "n_audio_ctx", "n_audio_state", "n_audio_head", "n_audio_layer",
                  "n_text_ctx", "n_text_state", "n_text_head", "n_text_layer", "n_mels"] { i32(try h(k)) }
        i32(1)  // f16
        i32(nMels); i32(mel.count / 4 / nMels)
        buf.append(mel)
        let lines = tik.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        i32(lines.count)
        for l in lines {
            let b64 = String(l.split(separator: " ").first ?? "")
            // «= 50256» — токен из пустой строки: Python b64decode("=") даёт b"", Foundation — nil
            guard let tok = Data(base64Encoded: b64) ?? (b64.allSatisfy { $0 == "=" } ? Data() : nil) else {
                throw ConvError("битая строка словаря токенов: \(l.prefix(40))")
            }
            i32(tok.count); buf.append(tok)
        }
        flush()

        // encoder.positional_embedding — синусоиды, в MLX не хранятся
        let posName = "encoder.positional_embedding"
        let (pctx, pstate) = (try h("n_audio_ctx"), try h("n_audio_state"))

        var names = Array(w.keys); names.append(posName); names.sort()
        for name in names {
            var gname = name.replacingOccurrences(of: ".mlp1.", with: ".mlp.0.").replacingOccurrences(of: ".mlp2.", with: ".mlp.2.")
            if name == posName { gname = posName }
            var shape: [Int]
            var floats: [Float]? = nil  // путь с преобразованием
            var raw: Data? = nil        // быстрый путь: f16 как есть
            if name == posName {
                shape = [pctx, pstate]
                floats = sinusoids(pctx, pstate)
            } else {
                let t = w[name]!
                shape = t.shape
                if gname == "encoder.conv1.weight" || gname == "encoder.conv2.weight" {
                    // (out, k, in) → (out, in, k)
                    let (o, k, i) = (shape[0], shape[1], shape[2])
                    let src = try toFloats(t)
                    var dst = [Float](repeating: 0, count: src.count)
                    for a in 0..<o { for b in 0..<k { for c in 0..<i { dst[(a * i + c) * k + b] = src[(a * k + b) * i + c] } } }
                    floats = dst; shape = [o, i, k]
                } else if t.dtype == .f16 {
                    raw = t.data
                } else {
                    floats = try toFloats(t)
                }
            }
            if shape.count > 1 { shape = shape.filter { $0 != 1 } }  // squeeze
            if gname == "encoder.conv1.bias" || gname == "encoder.conv2.bias" { shape = [shape[0], 1] }
            let small = shape.count < 2 || ["encoder.conv1.bias", "encoder.conv2.bias",
                                             "encoder.positional_embedding", "decoder.positional_embedding"].contains(gname)
            let nameBytes = Data(gname.utf8)
            i32(shape.count); i32(nameBytes.count); i32(small ? 0 : 1)
            for d in shape.reversed() { i32(d) }
            buf.append(nameBytes)
            flush()
            if small {
                var f = floats ?? (raw.map { f16ToFloats($0) } ?? [])
                if f.isEmpty, let t = w[name] { f = try toFloats(t) }
                f.withUnsafeBytes { out.write(Data($0)) }
            } else if let raw {
                out.write(raw)
            } else if let floats {
                var h16 = [UInt16](repeating: 0, count: floats.count)
                for (j, v) in floats.enumerated() { h16[j] = Float16(v).bitPattern }
                h16.withUnsafeBytes { out.write(Data($0)) }
            }
        }
        try out.close()
        _ = try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: tmp, to: output)
    }

    // MARK: Whisper в формате Hugging Face transformers (coriollon codeswitch, bond005 podlodka и т. п.)

    static let hfMap: [String: String] = [
        "self_attn.k_proj": "attn.key", "self_attn.q_proj": "attn.query", "self_attn.v_proj": "attn.value",
        "self_attn.out_proj": "attn.out", "self_attn_layer_norm": "attn_ln", "encoder_attn.q_proj": "cross_attn.query",
        "encoder_attn.v_proj": "cross_attn.value", "encoder_attn.out_proj": "cross_attn.out",
        "encoder_attn_layer_norm": "cross_attn_ln", "fc1": "mlp.0", "fc2": "mlp.2", "final_layer_norm": "mlp_ln",
        "encoder.layer_norm.bias": "encoder.ln_post.bias", "encoder.layer_norm.weight": "encoder.ln_post.weight",
        "encoder.embed_positions.weight": "encoder.positional_embedding", "decoder.layer_norm.bias": "decoder.ln.bias",
        "decoder.layer_norm.weight": "decoder.ln.weight", "decoder.embed_positions.weight": "decoder.positional_embedding",
        "decoder.embed_tokens.weight": "decoder.token_embedding.weight",
    ]

    /// Порт convert-h5-to-ggml.py whisper.cpp: имена HF → OpenAI, словарь vocab.json в байтах GPT-2, f16 (мелкое — f32
    /// после округления через f16, как в оригинале). Веса читаются из model.safetensors (f32/f16/bf16).
    static func convertHF(modelDir: URL, hp: [String: Any], assets: URL, output: URL) throws {
        func h(_ k: String) throws -> Int { guard let v = hp[k] as? Int else { throw ConvError("в config.json нет \(k)") }; return v }
        let w = try loadSafetensors(modelDir.appendingPathComponent("model.safetensors"))
        let nMels = try h("num_mel_bins")
        let mel = try Data(contentsOf: assets.appendingPathComponent("mel_\(nMels).f32"))
        guard let vocab = try JSONSerialization.jsonObject(with: Data(contentsOf: modelDir.appendingPathComponent("vocab.json"))) as? [String: Int]
        else { throw ConvError("vocab.json не прочитан") }
        // GPT-2 bytes_to_unicode: символ → байт
        var bs = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs, n = 0
        for b in 0..<256 where !bs.contains(b) { bs.append(b); cs.append(256 + n); n += 1 }
        var byteOf: [Character: UInt8] = [:]
        for (b, c) in zip(bs, cs) { byteOf[Character(UnicodeScalar(c)!)] = UInt8(b) }

        let tmp = output.appendingPathExtension("part")
        defer { try? FileManager.default.removeItem(at: tmp) }
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let out = try FileHandle(forWritingTo: tmp)
        var buf = Data()
        func flush() { out.write(buf); buf.removeAll(keepingCapacity: true) }
        func i32(_ v: Int) { var x = Int32(v).littleEndian; withUnsafeBytes(of: &x) { buf.append(contentsOf: $0) } }
        i32(0x67676D6C)
        let maxLen = (hp["max_length"] as? Int) ?? (hp["max_target_positions"] as? Int) ?? 448
        for v in [try h("vocab_size"), try h("max_source_positions"), try h("d_model"), try h("encoder_attention_heads"), try h("encoder_layers"),
                  maxLen, try h("d_model"), try h("decoder_attention_heads"), try h("decoder_layers"), nMels, 1] { i32(v) }
        i32(nMels); i32(mel.count / 4 / nMels); buf.append(mel)
        let toks = vocab.sorted { $0.value < $1.value }
        i32(toks.count)
        for (t, _) in toks {
            let bytes = t.compactMap { byteOf[$0] }
            i32(bytes.count); buf.append(contentsOf: bytes)
        }
        flush()
        for name in w.keys.sorted() where name != "proj_out.weight" {
            var nn = name.split(separator: ".").map(String.init)
            nn.removeFirst()  // "model."
            var gname: String
            if nn.count > 3 && nn[1] == "layers" {
                nn[1] = "blocks"
                let mid = nn[3..<(nn.count - 1)].joined(separator: ".")
                let mapped = mid == "encoder_attn.k_proj" ? (nn[0] == "encoder" ? "attn.key" : "cross_attn.key") : (hfMap[mid] ?? mid)
                gname = (nn[0..<3] + [mapped, nn.last!]).joined(separator: ".")
            } else {
                gname = nn.joined(separator: ".")
                gname = hfMap[gname] ?? gname
            }
            let t = w[name]!
            var shape = t.shape.count > 1 ? t.shape.filter { $0 != 1 } : t.shape
            if gname == "encoder.conv1.bias" || gname == "encoder.conv2.bias" { shape = [shape[0], 1] }
            let small = shape.count < 2 || ["encoder.conv1.bias", "encoder.conv2.bias", "encoder.positional_embedding", "decoder.positional_embedding"].contains(gname)
            let s = Data(gname.utf8)
            i32(shape.count); i32(s.count); i32(small ? 0 : 1)
            for d in shape.reversed() { i32(d) }
            buf.append(s); flush()
            let h16: [UInt16] = t.dtype == .f16 ? copyArray(t.data, UInt16.self) : try toFloats(t).map { Float16($0).bitPattern }
            if small {
                let f = h16.map { Float(Float16(bitPattern: $0)) }  // округление через f16, как astype(float16) в оригинале
                f.withUnsafeBytes { out.write(Data($0)) }
            } else {
                h16.withUnsafeBytes { out.write(Data($0)) }
            }
        }
        try out.close()
        _ = try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: tmp, to: output)
    }

    static func sinusoids(_ length: Int, _ channels: Int) -> [Float] {
        let half = channels / 2
        let inc = log(10000.0) / Double(half - 1)
        var out = [Float](repeating: 0, count: length * channels)
        for t in 0..<length {
            for j in 0..<half {
                let v = Double(t) * exp(-inc * Double(j))
                out[t * channels + j] = Float(sin(v))
                out[t * channels + half + j] = Float(cos(v))
            }
        }
        return out
    }

    static func copyArray<T: FixedWidthInteger>(_ d: Data, _: T.Type) -> [T] {
        var a = [T](repeating: 0, count: d.count / MemoryLayout<T>.size)
        _ = a.withUnsafeMutableBytes { d.copyBytes(to: $0) }  // срез файла может быть невыровнен
        return a
    }

    static func f16ToFloats(_ d: Data) -> [Float] {
        copyArray(d, UInt16.self).map { Float(Float16(bitPattern: UInt16(littleEndian: $0))) }
    }

    static func toFloats(_ t: Tensor) throws -> [Float] {
        switch t.dtype {
        case .f16: return f16ToFloats(t.data)
        case .f32: return copyArray(t.data, UInt32.self).map { Float(bitPattern: UInt32(littleEndian: $0)) }
        case .bf16: return copyArray(t.data, UInt16.self).map { Float(bitPattern: UInt32(UInt16(littleEndian: $0)) << 16) }
        default: throw ConvError("неподдерживаемый тип тензора")
        }
    }

    // MARK: чтение весов

    static func loadWeights(_ dir: URL) throws -> [String: Tensor] {
        let st = dir.appendingPathComponent("weights.safetensors")
        if FileManager.default.fileExists(atPath: st.path) { return try loadSafetensors(st) }
        return try loadNPZ(dir.appendingPathComponent("weights.npz"))
    }

    static func u16(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 }
    static func u32(_ d: Data, _ o: Int) -> Int { u16(d, o) | u16(d, o + 2) << 16 }
    static func u64(_ d: Data, _ o: Int) -> Int { u32(d, o) | u32(d, o + 4) << 32 }

    static func loadSafetensors(_ url: URL) throws -> [String: Tensor] {
        let d = try Data(contentsOf: url, options: .alwaysMapped)
        let n = u64(d, 0)
        guard let header = try JSONSerialization.jsonObject(with: d.subdata(in: 8..<(8 + n))) as? [String: Any] else {
            throw ConvError("заголовок safetensors не прочитан")
        }
        var out: [String: Tensor] = [:]
        for (name, meta) in header where name != "__metadata__" {
            guard let m = meta as? [String: Any], let dt = m["dtype"] as? String,
                  let shape = m["shape"] as? [Int], let off = m["data_offsets"] as? [Int] else { continue }
            let type: DType = ["F16": .f16, "F32": .f32, "BF16": .bf16, "I64": .i64][dt] ?? .other
            out[name] = Tensor(dtype: type, shape: shape, data: d[(8 + n + off[0])..<(8 + n + off[1])])
        }
        return out
    }

    /// npz = zip из .npy без сжатия (так сохраняет mlx); сжатые записи не поддерживаются.
    static func loadNPZ(_ url: URL) throws -> [String: Tensor] {
        let d = try Data(contentsOf: url, options: .alwaysMapped)
        var eocd = -1
        var i = d.count - 22
        while i >= max(0, d.count - 70000) {
            if u32(d, i) == 0x06054B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ConvError("npz: нет конца zip-каталога") }
        let entries = u16(d, eocd + 10)
        var p = u32(d, eocd + 16)
        var out: [String: Tensor] = [:]
        for _ in 0..<entries {
            guard u32(d, p) == 0x02014B50 else { throw ConvError("npz: битый каталог") }
            let method = u16(d, p + 10)
            var size = u32(d, p + 20), usize = u32(d, p + 24)
            let nl = u16(d, p + 28), el = u16(d, p + 30), cl = u16(d, p + 32)
            var local = u32(d, p + 42)
            let name = String(decoding: d[(p + 46)..<(p + 46 + nl)], as: UTF8.self)
            // zip64 (numpy пишет его для больших архивов): поля 0xFFFFFFFF лежат в extra 0x0001
            // в порядке: несжатый размер, сжатый размер, смещение локального заголовка
            var x = p + 46 + nl
            while x + 4 <= p + 46 + nl + el {
                let id = u16(d, x), len = u16(d, x + 2)
                if id == 0x0001 {
                    var q = x + 4
                    if usize == 0xFFFF_FFFF { usize = u64(d, q); q += 8 }
                    if size == 0xFFFF_FFFF { size = u64(d, q); q += 8 }
                    if local == 0xFFFF_FFFF { local = u64(d, q); q += 8 }
                }
                x += 4 + len
            }
            _ = usize
            p += 46 + nl + el + cl
            guard method == 0 else { throw ConvError("npz: запись \(name) сжата") }
            let lnl = u16(d, local + 26), lel = u16(d, local + 28)
            let start = local + 30 + lnl + lel
            let npy = d[start..<(start + size)]
            out[name.replacingOccurrences(of: ".npy", with: "")] = try parseNPY(npy)
        }
        return out
    }

    static func parseNPY(_ d: Data) throws -> Tensor {
        let b = d.startIndex
        guard d.count > 10, d[b] == 0x93 else { throw ConvError("не npy") }
        let major = Int(d[b + 6])
        let (hl, hs) = major >= 2 ? (u32(d, 8), 12) : (u16(d, 8), 10)
        let header = String(decoding: d[(b + hs)..<(b + hs + hl)], as: UTF8.self)
        func grab(_ pat: String) -> String? {
            guard let r = header.range(of: pat, options: .regularExpression) else { return nil }
            return String(header[r])
        }
        let descr = grab(#"'descr':\s*'[^']+'"#) ?? ""
        let type: DType = descr.contains("<f2") ? .f16 : descr.contains("<f4") ? .f32 : descr.contains("<i8") ? .i64 : .other
        let shapeStr = grab(#"'shape':\s*\([^)]*\)"#) ?? "()"
        let shape = shapeStr.drop(while: { $0 != "(" }).dropFirst().dropLast()
            .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if header.contains("'fortran_order': True") { throw ConvError("npy в порядке Fortran") }
        return Tensor(dtype: type, shape: shape, data: d[(b + hs + hl)...])
    }
}
