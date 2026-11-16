import AVFoundation
import CoreImage
import Foundation
import ImageIO
import SimbiaCore
import UniformTypeIdentifiers

// simbia — the app's engine without the window, for Claude and scripts.
//
//   simbia check <project.simbia>                       summary + everything that would render wrongly (exit 1 if any)
//   simbia frame <project.simbia> <t,t,...> <out-prefix> [--no-overlay]
//                                                       composed frames as PNG: <out-prefix>_<t>.png
//   simbia export <project.simbia> <out.mp4>            the finished video (captions, titles, mix at -14 LUFS)
//   simbia overlay <project.simbia> <t,...> <prefix> [--style sN]
//                                                       captions + titles only (transparent PNG + layout JSON)
//   simbia restyle <project.simbia> <sN>                caption style for the whole video (regroups between 1- and 2-line)
//   simbia fix <project.simbia> [kind ...]              fixes what check lists (all kinds, or those named) and saves
//   simbia pauses <project.simbia> [seconds] [--apply]  the pauses between words; --apply takes them out and saves
//   simbia suggest <project.simbia> <shot #>            footage from the library's index for what is said over a shot
//   simbia cuts <video> [from to]                       every sharp change of picture in a clip (calibrates the cut search)
//   simbia tempo <audio | project.simbia>               the music's tempo and first downbeat (a project: its beat grid)
//   simbia covers <project.simbia> <shot #> [--apply]   burned-in text found on a shot by Vision; --apply covers it and saves
//   simbia words <media> [from to] [--locale en-US] [--hint word]... [--json out]
//                                                       what the Mac hears, word by word: {path, words: [{w, t0, t1}]}
//   simbia workspace init <folder> […] | info [path]   a new workspace (folders, settings, CLAUDE.md, .mcp.json) / its settings
//   simbia projects [workspace]                         the workspace's projects, one line each
//   simbia mcp                                          the MCP server for Claude, on stdin/stdout

let usage = """
usage:
  simbia check <project.simbia>
  simbia frame <project.simbia> <t,t,...> <out-prefix> [--no-overlay]
  simbia export <project.simbia> <out.mp4>
  simbia overlay <project.simbia> <t,t,...> <out-prefix> [--style sN]
  simbia fix <project.simbia> [overlap|repeated|brand|voice|nearCut|gap|fast|small|shortTitle|hiddenCut ...]
  simbia pauses <project.simbia> [seconds] [--apply]
  simbia suggest <project.simbia> <shot #>
  simbia cuts <video> [from to]
  simbia tempo <audio | project.simbia>
  simbia covers <project.simbia> <shot #> [--apply]
  simbia words <media> [from to] [--locale en-US] [--hint word]... [--json out]
  simbia workspace init <folder> [--name N] [--brand B] [--key k] [--author A]
  simbia workspace info [path]
  simbia projects [workspace]
  simbia mcp
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func load(_ path: String) -> (Project, URL) {
    let url = URL(fileURLWithPath: path)
    Workspace.activate(near: url)
    do { return (try Project.load(from: url), url) } catch { fail(error.localizedDescription) }
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "simbia", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot write \(url.path)"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "simbia", code: 2) }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail(usage) }

switch command {
case "covers":                                     // the text burned into a shot's footage, as zones to paint over
    guard args.count >= 3, let n = Int(args[2]) else { fail(usage) }
    var (project, url) = load(args[1])
    let order = project.shots.sorted { $0.start < $1.start }
    guard order.indices.contains(n - 1) else { fail("no shot \(n)") }
    let shot = order[n - 1]
    let zones = await Covers.findText(in: Project.resolve(shot.src, relativeTo: url), from: shot.inPoint, to: shot.inPoint + shot.footage,
                                      rotation: shot.rotation, aspect: Double(project.canvas.width) / Double(project.canvas.height))
    for z in zones { print(String(format: "x %.3f y %.3f w %.3f h %.3f", z.x, z.y, z.w, z.h)) }
    if args.contains("--apply"), let i = project.shots.firstIndex(where: { $0.id == shot.id }) {
        project.shots[i].covers = zones
        project.revision += 1; project.savedBy = "claude"
        do { try project.encoded().write(to: url, options: .atomic); print("saved \(zones.count) zone(s) on shot \(n)") } catch { fail(error.localizedDescription) }
    }

case "words":                                      // the Mac's own recogniser (as the app's captions use it), in seconds of the file
    guard args.count >= 2 else { fail(usage) }
    let url = URL(fileURLWithPath: args[1])
    func option(_ name: String) -> [String] { args.indices.filter { args[$0] == name && $0 + 1 < args.count }.map { args[$0 + 1] } }
    let valued: Set<String> = ["--locale", "--hint", "--json"]
    let plain = args.indices.dropFirst(2).filter { !args[$0].hasPrefix("--") && !valued.contains(args[$0 - 1]) }.map { args[$0] }
    let from = plain.count > 0 ? Double(plain[0]) ?? 0 : 0
    do {
        let to = plain.count > 1 ? Double(plain[1]) ?? 0 : try await SpeechAudio.length(of: url)
        let locale = option("--locale").first.map { Locale(identifier: $0) } ?? Locale(identifier: "en-US")
        let work = FileManager.default.temporaryDirectory.appending(path: "simbia-words-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? FileManager.default.removeItem(at: work) }
        let words = try await MacSpeech.words(in: url, from: from, to: to, locale: locale, hints: option("--hint"), work: work)
        let out: [String: Any] = ["path": url.path, "words": words.map { ["w": $0.text, "t0": ($0.start * 1000).rounded() / 1000, "t1": ($0.end * 1000).rounded() / 1000] }]
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .withoutEscapingSlashes])
        if let json = option("--json").first { try data.write(to: URL(fileURLWithPath: json)); print("\(words.count) words → \(json)") }
        else { print(String(decoding: data, as: UTF8.self)) }
    } catch { fail("words: \(error.localizedDescription)") }

case "voice":                                   // simbia voice <project>: every voice clip's loudness before/after the voice chain
    guard args.count == 2 else { fail(usage) }
    let (project, url) = load(args[1])
    let rows = await VoiceRender.report(project, projectURL: url)
    func f(_ v: Double?) -> String { v.map { String(format: "%6.1f", $0) } ?? "   -  " }
    for r in rows { print("\(String(format: "%7.2f", r.start))  \(f(r.before)) → \(f(r.after)) LUFS  peak \(String(format: "%5.1f", r.peak))  \(r.label.prefix(40))") }
    let b = rows.compactMap(\.before), a = rows.compactMap(\.after)
    if let b0 = b.min(), let b1 = b.max(), let a0 = a.min(), let a1 = a.max() {
        print(String(format: "spread before %.1f dB (%.1f…%.1f), after %.1f dB (%.1f…%.1f), max peak %.1f dBFS", b1 - b0, b0, b1, a1 - a0, a0, a1, rows.map(\.peak).max() ?? 0))
    }
case "check":
    guard args.count == 2 else { fail(usage) }
    let (project, url) = load(args[1])
    let words = project.captions.chunks.reduce(0) { $0 + $1.words.count }
    print("\(project.name): \(String(format: "%.2f", project.duration)) s, \(project.canvas.width)x\(project.canvas.height) @ \(project.canvas.fps) fps")
    print("  \(project.shots.count) shots, \(project.audio.count) audio, \(project.overlays.count) overlays")
    print("  captions \(project.captions.style): \(project.captions.chunks.count) chunks, \(words) words, \(project.captions.chunks.flatMap(\.words).filter(\.accent).count) accents")
    print("  titles: " + project.titles.map { "\($0.style) \"\($0.text)\" @\(String(format: "%.2f", $0.start))" }.joined(separator: ", "))
    print("  revision \(project.revision) by \(project.savedBy)")
    let problems = project.problems(relativeTo: url)
    // worth fixing before delivery, but nothing that stops a render (missing files are problems already)
    let voice = await VoiceActivity.of(project, projectURL: url)
    await SourceCuts.scan(project, projectURL: url)
    for issue in project.issues(voice: voice, glossary: .load(), projectURL: url) where issue.kind != .missing {
        print("  ~ \(String(format: "%6.2f", issue.time))  \(issue.kind.rawValue): \(issue.detail)")
    }
    if problems.isEmpty { print("OK") } else {
        problems.forEach { print("  ! " + $0) }
        exit(1)
    }

case "colourmatch":                                 // a shot's colour matched to another's: colourmatch <project> <shot> <reference> [--apply]
    guard args.count >= 4 else { fail("simbia colourmatch <project.simbia> <shot id> <reference shot id> [--apply]") }
    var (project, url) = load(args[1])
    guard let i = project.shots.firstIndex(where: { $0.id == args[2] }), let ref = project.shots.first(where: { $0.id == args[3] })
    else { fail("no such shot") }
    guard let grade = await ColourMatch.grade(for: project.shots[i], like: ref, projectURL: url) else { fail("clips not readable") }
    print("gain \(grade.gain), contrast \(grade.contrast), saturation \(grade.saturation), scene \(grade.scene ?? "-")")
    if args.contains("--apply") {
        project.shots[i].grade = grade
        project.revision += 1; project.savedBy = "claude"
        do { try project.save(to: url); print("saved, revision \(project.revision)") } catch { fail(error.localizedDescription) }
    }

case "tempo":                                       // what the timeline's bars are found from
    guard args.count >= 2 else { fail("simbia tempo <audio | project.simbia>") }
    do {
        if args[1].hasSuffix(".simbia") {
            let (project, url) = load(args[1])
            guard let grid = try await project.detectGrid(projectURL: url) else { fail("no music, or no beat found") }
            print(String(format: "%.2f bpm, first bar at %.3f s on the edit (from %@)", grid.bpm, grid.offset, grid.source ?? "-"))
        } else {
            guard let found = try await Tempo.detect(URL(fileURLWithPath: args[1])) else { fail("no beat found") }
            print(String(format: "%.2f bpm, first downbeat %.3f s", found.bpm, found.downbeat))
        }
    } catch { fail(error.localizedDescription) }

case "play":                                        // what the app's preview player does with the project: ready or failed, and a frame
    guard args.count >= 2 else { fail("simbia play <project.simbia> [t]") }
    let (project, url) = load(args[1])
    let t = args.count > 2 ? Double(args[2]) ?? 1 : 1
    do {
        let built = try await project.composition(projectURL: url, overlay: false)
        final class Checker: NSObject, AVVideoCompositionValidationHandling {
            func videoComposition(_ c: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidValueForKey key: String) -> Bool { print("invalid value:", key); return true }
            func videoComposition(_ c: AVVideoComposition, shouldContinueValidatingAfterFindingEmptyTimeRange r: CMTimeRange) -> Bool {
                print("empty time range:", r.start.seconds, "-", r.end.seconds); return true }
            func videoComposition(_ c: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidTimeRangeIn i: any AVVideoCompositionInstructionProtocol) -> Bool {
                print("invalid instruction range:", i.timeRange.start.seconds, "-", i.timeRange.end.seconds); return true }
            func videoComposition(_ c: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidTrackIDIn i: any AVVideoCompositionInstructionProtocol, layerInstruction: AVVideoCompositionLayerInstruction, asset: AVAsset) -> Bool {
                print("invalid track in instruction at", i.timeRange.start.seconds); return true }
        }
        let checker = Checker()
        let valid = built.video.isValid(for: built.asset, timeRange: CMTimeRange(start: .zero, duration: built.asset.duration), validationDelegate: checker)
        print("video composition valid:", valid, "asset duration", built.asset.duration.seconds, "last instruction ends", (built.video.instructions.last?.timeRange.end.seconds) ?? -1)
        var reach = CMTime.zero
        for ins in built.video.instructions {
            if ins.timeRange.start != reach { print("instruction gap/overlap at", reach.seconds, "->", ins.timeRange.start.seconds, ins.timeRange.start, reach) }
            reach = ins.timeRange.end
        }
        let item = built.playerItem()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        print("tracks: video \(built.asset.tracks(withMediaType: .video).count), audio \(built.asset.tracks(withMediaType: .audio).count)")
        for _ in 0..<100 where item.status == .unknown { try await Task.sleep(nanoseconds: 100_000_000) }
        print("item status:", item.status == .readyToPlay ? "ready" : item.status == .failed ? "FAILED" : "unknown")
        if let error = item.error as NSError? { print("error:", error.domain, error.code, error.localizedDescription, error.userInfo) }
        await player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        var frames = 0
        let started = Date()
        while Date().timeIntervalSince(started) < 2 {
            let now = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: now), output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil) != nil { frames += 1 }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        print("played 2 s from \(t): \(frames) frames out, player at \(String(format: "%.2f", player.currentTime().seconds)) s, rate \(player.rate), status \(player.timeControlStatus.rawValue)")
        if let log = item.errorLog() { for e in log.events { print("errorLog:", e.errorStatusCode, e.errorDomain, e.errorComment ?? "") } }
    } catch { fail("\(error)") }

case "playtap":                                     // what the preview player really plays (see PlayTap.swift)
    guard args.count >= 3 else { fail("simbia playtap <project.simbia> <out.wav> [from] [seconds]") }
    let (project, url) = load(args[1])
    let from = args.count > 3 ? Double(args[3]) ?? 0 : 0
    let retarget = args.count > 7 && args[5] == "--retarget" ? (load(args[6]).0, Double(args[7]) ?? 0) : nil
    do { try await playTap(project, url: url, out: URL(fileURLWithPath: args[2]), from: from,
                           seconds: args.count > 4 ? Double(args[4]) ?? project.duration - from : project.duration - from, retarget: retarget) }
    catch { fail("playtap: \(error.localizedDescription)") }

case "frame":
    guard args.count >= 4 else { fail(usage) }
    let (project, url) = load(args[1])
    let times = args[2].split(separator: ",").compactMap { Double($0) }
    let prefix = args[3]
    let overlay = !args.contains("--no-overlay")
    do {
        let built = try await project.composition(projectURL: url, overlay: overlay)
        await built.context.prepareEdges()                  // stills show the blur across cuts as the export does
        if overlay {
            let renderer = OverlayRenderer(project: project)
            let canvas = CGSize(width: project.canvas.width, height: project.canvas.height)
            built.context.overlay = { cg, t in renderer.draw(in: cg, size: canvas, time: t, flipped: false) }
        }
        if !built.missing.isEmpty { FileHandle.standardError.write(Data("  missing: \(built.missing.joined(separator: ", "))\n".utf8)) }
        let generator = AVAssetImageGenerator(asset: built.asset)
        generator.videoComposition = built.video
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for t in times {
            let (image, actual) = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600))
            let out = URL(fileURLWithPath: "\(prefix)_\(String(format: "%.2f", t)).png")
            try writePNG(image, to: out)
            print("\(out.path)  (t=\(String(format: "%.3f", actual.seconds)))")
        }
    } catch { fail("frame: \(error.localizedDescription)") }

case "audio":                                      // the mix as 48 kHz stereo WAV (before loudness normalisation)
    guard args.count == 3 else { fail("audio <project.simbia> <out.wav>") }
    let (project, url) = load(args[1])
    do {
        let built = try await project.composition(projectURL: url, overlay: false)
        let reader = try AVAssetReader(asset: built.asset)
        let tracks = try await built.asset.loadTracks(withMediaType: .audio)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2])
        output.audioMix = built.audio
        output.audioTimePitchAlgorithm = .spectral
        guard !tracks.isEmpty, reader.canAdd(output) else { fail("audio: the project has no readable sound") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "simbia", code: 3) }
        var pcm = Data()
        var expected = CMTime.zero
        while let buffer = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer), dur = CMSampleBufferGetDuration(buffer)
            if abs((pts - expected).seconds) > 0.0005 {
                FileHandle.standardError.write(Data("  gap at \(String(format: "%.4f", expected.seconds)) -> \(String(format: "%.4f", pts.seconds))\n".utf8))
            }
            expected = pts + dur
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var chunk = Data(count: CMBlockBufferGetDataLength(block))
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            pcm += chunk
        }
        if reader.status == .failed { throw reader.error ?? NSError(domain: "simbia", code: 4) }   // never a cut-short file
        var header = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header += $0 } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header += $0 } }
        header += "RIFF".data(using: .ascii)!; u32(UInt32(36 + pcm.count)); header += "WAVEfmt ".data(using: .ascii)!
        u32(16); u16(1); u16(2); u32(48_000); u32(48_000 * 4); u16(4); u16(16)
        header += "data".data(using: .ascii)!; u32(UInt32(pcm.count))
        try (header + pcm).write(to: URL(fileURLWithPath: args[2]))
        print("\(args[2]): \(String(format: "%.2f", Double(pcm.count) / 4 / 48_000)) s")
    } catch { fail("audio: \(error.localizedDescription)") }

case "export":                                     // the finished video: picture, captions, titles, mix at -14 LUFS
    guard args.count == 3 else { fail("export <project.simbia> <out.mp4>") }
    let (project, url) = load(args[1])
    let out = URL(fileURLWithPath: args[2])
    let start = Date()
    final class Last: @unchecked Sendable { var shown = -1 }
    let last = Last()
    do {
        try await Exporter.export(project, projectURL: url, to: out) { p in
            let pct = Int(p * 100)
            if pct / 5 != last.shown / 5 { last.shown = pct; FileHandle.standardError.write(Data("  \(pct)%\n".utf8)) }
        }
        print("\(out.path)  (\(String(format: "%.1f", Date().timeIntervalSince(start))) s)")
    } catch { fail(error.localizedDescription) }

case "overlay":                                    // captions + titles only, transparent PNGs + layout JSON
    guard args.count >= 4 else { fail("overlay <project.simbia> <t,t,...> <out-prefix> [--style sN]") }
    var (project, _) = load(args[1])
    let times = args[2].split(separator: ",").compactMap { Double($0) }
    let prefix = args[3]
    let style = args.firstIndex(of: "--style").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    if args.contains("--no-titles") { project.titles = [] }
    let renderer = OverlayRenderer(project: project, style: style)
    let (w, h) = (project.canvas.width, project.canvas.height)
    var layouts: [String: [[String: Any]]] = [:]
    for t in times {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("context") }
        renderer.draw(in: ctx, size: CGSize(width: w, height: h), time: t)
        let name = String(format: "%.2f", t)
        try writePNG(ctx.makeImage()!, to: URL(fileURLWithPath: "\(prefix)_\(name).png"))
        layouts[name] = renderer.wordBoxes(at: t).map { ["t": $0.text, "x": $0.box.minX, "y": $0.box.minY, "w": $0.box.width, "h": $0.box.height, "fs": $0.size] }
        print("\(prefix)_\(name).png")
    }
    let json = try JSONSerialization.data(withJSONObject: layouts, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: URL(fileURLWithPath: "\(prefix)_layout.json"))

case "shadowtest":                                 // calibration: a 200 px white square with a CG shadow of CSS radius r
    guard args.count == 4, let r = Double(args[1]), let k = Double(args[2]) else { fail("shadowtest <css radius> <scale> <out.png>") }
    guard let ctx = CGContext(data: nil, width: 600, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("context") }
    ctx.setShadow(offset: .zero, blur: r * k, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 200, y: 200, width: 200, height: 200))
    try writePNG(ctx.makeImage()!, to: URL(fileURLWithPath: args[3]))

case "bench":                                      // ms per overlay frame at a preview scale
    guard args.count == 5, let t0 = Double(args[2]), let scale = Double(args[3]), let n = Int(args[4]) else { fail("bench <project> <t> <scale> <frames>") }
    let (project, _) = load(args[1])
    let renderer = OverlayRenderer(project: project)
    let w = Int(1080 * scale), h = Int(1920 * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("context") }
    let start = Date()
    for i in 0..<n {
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        renderer.draw(in: ctx, size: CGSize(width: w, height: h), time: t0 + Double(i) / 60)
    }
    print(String(format: "%.1f ms/frame", Date().timeIntervalSince(start) * 1000 / Double(n)))

case "blurtest":                                   // calibration: CIGaussianBlur(radius) over a PNG
    guard args.count == 4, let radius = Double(args[2]), let src = CIImage(contentsOf: URL(fileURLWithPath: args[1]),
                                                                          options: [.colorSpace: NSNull()]) else { fail("blurtest in.png radius out.png") }
    let ci = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    let out = src.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: src.extent)
    guard let cg = ci.createCGImage(out, from: src.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { fail("render") }
    try writePNG(cg, to: URL(fileURLWithPath: args[3]))

case "fix":                                        // what check lists, fixed the way the app's "Fix all" does
    guard args.count >= 2 else { fail(usage) }
    var (project, url) = load(args[1])
    let kinds = args.dropFirst(2).map { name in Issue.Kind(rawValue: name) ?? { fail("unknown kind \(name)") }() }
    let voice = await VoiceActivity.of(project, projectURL: url)
    let glossary = Glossary.load()
    await SourceCuts.scan(project, projectURL: url)
    let before = project.issues(voice: voice, glossary: glossary, projectURL: url).filter(\.fixable).count
    project = kinds.isEmpty ? project.fixingAll(voice: voice, glossary: glossary, projectURL: url)
                            : kinds.reduce(project) { $0.fixing($1, voice: voice, glossary: glossary, projectURL: url) }
    await SourceCuts.scan(project, projectURL: url)             // the stretches the fix moved to
    let after = project.issues(voice: voice, glossary: glossary, projectURL: url).filter(\.fixable).count
    project.revision += 1; project.savedBy = "claude"
    do { try project.save(to: url) } catch { fail(error.localizedDescription) }
    print("\(before) to fix, \(after) left; saved revision \(project.revision)")

case "restyle":                                    // a caption style for the whole video; moving between the one-line and
    guard args.count >= 3, let after = CaptionStyle(id: args[2]) else { fail(usage) }      // two-line families regroups
    var (project, url) = load(args[1])                                                       // paragraph by paragraph, as the app does
    let before = CaptionStyle(id: project.captions.style)
    project.captions.style = after.id
    if before?.twoLine != after.twoLine || before == nil {
        let ordered = project.captions.chunks.sorted { $0.start < $1.start }
        let marked = ordered.contains(where: \.paragraph)
        var paragraphs: [[ChunkWord]] = []
        for (i, chunk) in ordered.enumerated() {
            var starts = i == 0 || marked && chunk.paragraph
            if !marked, i > 0, let last = ordered[i - 1].words.last, let next = chunk.words.first {
                starts = CaptionGrouping.startsParagraph(after: last.text, end: last.end, nextStart: next.start)
            }
            if starts || paragraphs.isEmpty { paragraphs.append(chunk.words) } else { paragraphs[paragraphs.count - 1] += chunk.words }
        }
        project.captions.chunks = CaptionGrouping.regroup(paragraphs, twoLine: after.twoLine, mark: marked).map { chunk in
            var c = chunk
            c.id = "c" + UUID().uuidString.prefix(8).lowercased()
            return c
        }
    }
    project.revision += 1; project.savedBy = "claude"
    do { try project.save(to: url) } catch { fail(error.localizedDescription) }
    print("\(project.captions.style): \(project.captions.chunks.count) captions; saved revision \(project.revision)")

case "pauses":                                     // silences between words; --apply takes them out
    guard args.count >= 2 else { fail(usage) }
    var (project, url) = load(args[1])
    let minimum = args.dropFirst(2).compactMap(Double.init).first ?? 0.4
    let voice = await VoiceActivity.of(project, projectURL: url)
    let pauses = project.pauses(minimum: minimum, voice: voice)
    for r in pauses { print(String(format: "  %7.2f – %7.2f  (%.2f s)", r.lowerBound, r.upperBound, r.upperBound - r.lowerBound)) }
    let total = pauses.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
    print(String(format: "%d pauses, %.2f s of %.2f s", pauses.count, total, project.duration))
    if args.contains("--apply"), !pauses.isEmpty {
        project = project.removing(pauses)
        project.revision += 1; project.savedBy = "claude"
        do { try project.save(to: url) } catch { fail(error.localizedDescription) }
        print(String(format: "saved: %.2f s, %d shots, %d sound clips", project.duration, project.shots.count, project.audio.count))
    }

case "cuts":                                       // cuts inside a clip: every frame that changes a lot, and what counts as a cut
    guard args.count >= 2 else { fail("cuts <video> [from to]") }
    let numbers = args.dropFirst(2).compactMap(Double.init)
    let range = numbers.count == 2 ? numbers[0]...numbers[1] : 0...1e9
    let start = Date()
    guard let scan = await SourceCuts.changes(in: URL(fileURLWithPath: args[1]), range: range) else { fail("cannot read \(args[1])") }
    let cuts = Set(SourceCuts.cuts(scan.frames))
    for (t, g, h) in scan.frames where g > 0.05 || h > 0.25 {
        print(String(format: "  %7.3f  grid %.3f  hist %.3f%@", t, g, h, cuts.contains(t) ? "  CUT" : ""))
    }
    print(String(format: "%d frames in %.1f s (clip %.1f s)", scan.frames.count, Date().timeIntervalSince(start), scan.length))

case "suggest":                                    // the library's best moments for what is said over a shot
    guard args.count == 3, let n = Int(args[2]) else { fail(usage) }
    let (project, url) = load(args[1])
    let shots = project.shots.sorted { $0.start < $1.start }
    guard shots.indices.contains(n) else { fail("shots are 0…\(shots.count - 1)") }
    guard let folder = FootageIndex.find(near: url) else { fail("no _ASSETS/_index above the project") }
    let index = try FootageIndex.load(folder)
    let shot = shots[n]
    let said = project.captions.chunks.flatMap(\.words).filter { $0.start >= shot.start - 0.05 && $0.start < shot.end }.map(\.text).joined(separator: " ")
    let taken = Set(project.shots.filter { $0.id != shot.id }.map { Project.resolve($0.src, relativeTo: url).path })
    print("shot \(n) \(String(format: "%.2f–%.2f", shot.start, shot.end)): \"\(said)\"  (\(index.clips.count) clips indexed)")
    for s in index.suggest(for: said, length: shot.duration, taken: taken) {
        print(String(format: "  %@ @%.1f–%.1f  %@ · %@%@\n    %@", s.clip, s.from, s.to, s.tag, s.who, s.usedIn.isEmpty ? "" : " · used in \(s.usedIn.joined(separator: ", "))", s.note))
    }

case "workspace":                                 // workspace init <folder> [--name …] [--brand …] [--key …] [--author …] | workspace info [path]
    func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
    switch args.dropFirst().first {
    case "init":
        guard args.count >= 3 else { fail("simbia workspace init <folder> [--name N] [--brand B] [--key k] [--author A]") }
        let root = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath, isDirectory: true)
        let brandName = option("--brand") ?? ""
        let brand = Brand(name: brandName, key: option("--key") ?? (brandName.isEmpty ? "product" : brandName.lowercased().filter(\.isLetter)))
        do {
            let w = try Workspace.create(at: root, name: option("--name") ?? root.lastPathComponent, brand: brand,
                                         author: option("--author"), simbia: Bundle.main.executableURL?.resolvingSymlinksInPath())
            print("workspace «\(w.settings.name)» in \(w.root.path): \(Workspace.fileName), CLAUDE.md, .mcp.json, Projects/, Library/, Exports/")
        } catch { fail(error.localizedDescription) }
    case "info", nil:
        let at = args.count >= 3 ? URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath) : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard let w = Workspace.find(near: at) else { fail("no \(Workspace.fileName) in \(at.path) or above") }
        print(MCPServer.json(MCPServer.info(w)))
    default:
        fail("simbia workspace init <folder> … | simbia workspace info [path]")
    }

case "projects":                                  // the workspace's projects: status, revision, who saved, length, open tasks
    let at = args.count >= 2 ? URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath) : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    guard let w = Workspace.find(near: at) else { fail("no \(Workspace.fileName) in \(at.path) or above") }
    for p in w.summaries() {
        print("\(p.file)\t\(p.status)\trev \(p.revision) \(p.savedBy)\t\(String(format: "%.1f", p.duration)) s\t\(p.shots) shots\t\(p.openTasks.count) open")
    }

case "mcp":                                       // the MCP server on stdin/stdout, for Claude (see MCP.swift)
    await MCPServer.run()

default:
    fail(usage)
}
