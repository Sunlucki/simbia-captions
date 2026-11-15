import Foundation

/// Stretches of sound files for the speech engine: 16 kHz mono 16-bit PCM, from the same once-read 48 kHz
/// copy the voice analysis uses.
public enum SpeechAudio {
    public static let sampleRate = 16_000.0

    /// The file's sound in seconds (0 without any).
    public static func length(of url: URL) async throws -> Double {
        Double(try await SourceAudio.mono(url).count) / DuckEnvelope.sampleRate
    }

    /// `from`…`to` seconds of the file, every three 48 kHz samples averaged into one.
    public static func samples(of url: URL, from: Double, to: Double) async throws -> [Int16] {
        let whole = try await SourceAudio.mono(url)
        let a = max(0, min(whole.count, Int(from * DuckEnvelope.sampleRate)))
        let b = max(a, min(whole.count, Int(to * DuckEnvelope.sampleRate)))
        var out: [Int16] = []
        out.reserveCapacity((b - a) / 3 + 1)
        var i = a
        while i + 3 <= b {
            let v = (whole[i] + whole[i + 1] + whole[i + 2]) / 3
            out.append(Int16(max(-1, min(1, v)) * 32767))
            i += 3
        }
        return out
    }

    /// The samples as a WAV file.
    public static func wav(_ samples: [Int16]) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(sampleRate)); put(UInt32(sampleRate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(bytes)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
