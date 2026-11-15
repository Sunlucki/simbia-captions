import AVFoundation
import Foundation
import Speech

/// The Mac's own speech recognition — the engine Final Cut and dictation use, on the device, no model to load: a
/// stretch of a sound file becomes its words with their times (the file's own seconds) and punctuation. 12 s of
/// voice take under a second. SpeechTranscriber for the languages it knows (English), the dictation engine for the
/// rest (Russian, Ukrainian…). Its times are a tenth to a few tenths of a second off, so captions get exact timing
/// from their anchors (the editor's `WordSync`), not from here.
public enum MacSpeech {
    /// The language the editor listens for (Settings: «Язык речи»), en-US until another is picked.
    public static var locale: Locale {
        get { Locale(identifier: UserDefaults.standard.string(forKey: "speechLocale") ?? "en-US") }
        set { UserDefaults.standard.set(newValue.identifier, forKey: "speechLocale") }
    }

    /// Every language the Mac can turn into text, by its name in Russian.
    public static func languages() async -> [Locale] {
        let all = await SpeechTranscriber.supportedLocales + DictationTranscriber.supportedLocales
        var seen = Set<String>()
        return all.filter { seen.insert($0.identifier(.bcp47)).inserted }
            .sorted { name($0) < name($1) }
    }

    /// The language's name in the interface's language (`ru`, `en`, `fr`); Russian by default.
    public static func name(_ locale: Locale, in language: String = "ru") -> String {
        Locale(identifier: language).localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// `from`…`to` of the file in `locale`, with `hints` (the glossary) as words to expect. `progress` gets 0…1 as
    /// the words come in. A language the Mac has not downloaded yet is downloaded first (`downloading` is told).
    public static func words(in url: URL, from: Double, to: Double, locale: Locale = MacSpeech.locale, hints: [String] = [], work: URL,
                             downloading: (@MainActor @Sendable () -> Void)? = nil, progress: (@MainActor @Sendable (Double) -> Void)? = nil) async throws -> [ChunkWord] {
        let pcm = try await SpeechAudio.samples(of: url, from: from, to: to)
        guard !pcm.isEmpty else { return [] }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let wav = work.appending(path: "speech.wav")
        try SpeechAudio.wav(pcm).write(to: wav)
        let length = Double(pcm.count) / SpeechAudio.sampleRate

        let module: any SpeechModule
        let results: AsyncThrowingStream<(AttributedString, Double), Error>
        if let known = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let t = SpeechTranscriber(locale: known, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            module = t
            results = stream(t.results.map { ($0.text, $0.range.end.seconds) })
        } else if let known = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let t = DictationTranscriber(locale: known, contentHints: [], transcriptionOptions: [.punctuation], reportingOptions: [],
                                         attributeOptions: [.audioTimeRange])
            module = t
            results = stream(t.results.map { ($0.text, $0.range.end.seconds) })
        } else {
            // In the interface's language: the one picked in the app's Language menu, else the Mac's.
            let ui = UserDefaults.standard.string(forKey: "language") ?? String(Locale.preferredLanguages.first?.prefix(2) ?? "en")
            let message = ui == "ru" || ui == "uk" || ui == "be" ? "Mac не распознаёт язык \(name(locale))"
                : ui == "fr" ? "Le Mac ne reconnaît pas la langue \(name(locale, in: "fr"))" : "The Mac can't recognise \(name(locale, in: "en"))"
            throw NSError(domain: "Simbia", code: 10, userInfo: [NSLocalizedDescriptionKey: message])
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            await downloading?()
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        if !hints.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = hints
            try await analyzer.setContext(context)
        }
        let file = try AVAudioFile(forReading: wav)
        let heard = Task {
            var out: [ChunkWord] = []
            for try await (text, end) in results {
                for run in text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let word = String(text[run.range].characters).trimmingCharacters(in: .whitespaces)
                    guard !word.isEmpty else { continue }
                    out.append(ChunkWord(text: word, start: from + range.start.seconds, end: from + range.end.seconds))
                }
                if let progress { await progress(min(1, end / max(length, 0.01))) }
            }
            return out
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await heard.value
    }

    /// Either transcriber's results as one kind of stream.
    private static func stream<S: AsyncSequence & Sendable>(_ results: S) -> AsyncThrowingStream<(AttributedString, Double), Error>
    where S.Element == (AttributedString, Double) {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await r in results { continuation.yield(r) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
