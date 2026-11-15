import Foundation

/// The tools the editor runs besides itself: ffmpeg, for the export's loudness and the classic captions burn.
/// Speech is recognised by the Mac itself (`MacSpeech`).
extension Job {

    // MARK: Tool resolution

    /// Searched in order. The first that is present *and* actually runs wins.
    static let ffmpegCandidates = [
        "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg",
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/opt/local/bin/ffmpeg",
    ]

    /// Picks working binaries before a long run starts.
    ///
    /// Being executable is not the same as being runnable: a Homebrew ffmpeg whose libx265 was
    /// upgraded out from under it is still `-x`, but dies in dyld with SIGABRT. Checking only
    /// the file mode meant that install was chosen and the failure surfaced as "exit code 134"
    /// halfway through a job.
    func resolveTools() async throws {
        if resolvedFFmpeg == nil {
            resolvedFFmpeg = try await firstRunnable(Self.ffmpegCandidates, arguments: ["-version"],
                                                     name: "ffmpeg",
                                                     hint: s.installFFmpeg)
        }
    }

    private func firstRunnable(_ paths: [String], arguments: [String],
                               name: String, hint: String) async throws -> String {
        var broken: [String] = []
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            if await Self.runs(path, arguments) { return path }
            broken.append((path as NSString).lastPathComponent + " (" + path + ")")
            appendLog("\(path) is installed but will not run — skipping.")
        }
        let detail = broken.isEmpty ? hint : "\(broken.joined(separator: ", ")) — \(hint)"
        throw NSError(domain: "Simbia", code: 7,
                      userInfo: [NSLocalizedDescriptionKey: fill(s.cannotRun, name) + " " + detail])
    }

    private static func runs(_ path: String, _ arguments: [String]) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
    }

    // MARK: Grouping

    /// Turns the engine's per-word segments back into readable, editable lines while keeping
    /// each word's measured timing attached.
    func group(words: [Word]) -> [Cue] {
        var cues: [Cue] = []
        var current: [Word] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            cues.append(Cue(start: first.start, end: last.end,
                            text: current.map(\.text).joined(separator: " "),
                            words: current))
            current = []
        }

        for word in words {
            if let previous = current.last, word.start - previous.end > 0.7 { flush() }
            current.append(word)

            let spanning = word.end - (current.first?.start ?? word.start)
            let length = current.reduce(0) { $0 + $1.text.count + 1 }
            let sentenceEnd = word.text.last.map { ".!?…".contains($0) } ?? false
            if sentenceEnd || length >= 44 || spanning >= 3.5 { flush() }
        }
        flush()
        // a word left alone at the end of a phrase (the line had just run past its length) goes back onto that line
        var out: [Cue] = []
        for cue in cues {
            if cue.words.count == 1, let last = out.last, last.end > cue.start - 0.3,
               !(last.text.last.map { ".!?…".contains($0) } ?? false) {
                out[out.count - 1].words += cue.words
                out[out.count - 1].end = cue.end
                out[out.count - 1].text += " " + cue.text
            } else {
                out.append(cue)
            }
        }
        return out
    }
}
