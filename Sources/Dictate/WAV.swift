import AVFoundation

/// Чтение wav в 16 кГц моно float32 (для проверочного режима --transcribe).
enum WAV {
    /// 16 кГц моно PCM16 (как save_audio Python-версии).
    static func write(_ samples: [Float], to url: URL) throws {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let n = UInt32(samples.count * 2)
        d.append("RIFF".data(using: .ascii)!); u32(36 + n); d.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(n)
        var pcm = samples.map { Int16(max(-1, min(1, $0)) * 32767).littleEndian }
        d.append(Data(bytes: &pcm, count: pcm.count * 2))
        try d.write(to: url)
    }

    static func read(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    }
}
