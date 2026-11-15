import AVFoundation
import CoreImage
import UniformTypeIdentifiers

/// The edit as something AVFoundation can play and export: shots on two alternating video
/// tracks, the sound with its ducking as volume automation, and a custom compositor that draws
/// every frame — fill, push, dim, title blur, motion graphics and (when asked) captions and titles.
public struct BuiltComposition: @unchecked Sendable {
    public let asset: AVMutableComposition
    public let video: AVMutableVideoComposition
    public let audio: AVMutableAudioMix
    public let context: RenderContext
    /// Media that could not be read (moved, deleted, no picture or sound): shown as black / left silent.
    public let missing: [String]
    /// The app's preview (`live`): each sound track's levels, put on its samples by a tap (`LevelTap`), by track id.
    public var taps: [CMPersistentTrackID: LevelTap] = [:]

    public func playerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = video
        item.audioMix = audio
        item.audioTimePitchAlgorithm = .spectral         // sound at another speed keeps its pitch
        return item
    }
}

public enum CompositionError: LocalizedError {
    case empty
    case missing([String])
    public var errorDescription: String? {
        switch self {
        case .empty: return "The project has no shots"
        case .missing(let paths): return "Files not found or unreadable: " + paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        }
    }
}

extension Project {
    /// The look asks for motion blur: the build carries the footage a second time, one frame late.
    public var wantsPreviousFrame: Bool { (look?.on ?? false) && (look?.motionBlur ?? 0) > 0.001 }

    public static let stillTypes: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "tif", "tiff"]

    /// The footage is HDR (an iPhone's HLG, or PQ).
    static func isHDR(_ track: AVAssetTrack) async -> Bool {
        guard let descriptions = try? await track.load(.formatDescriptions) else { return false }
        return descriptions.contains { d in
            let tf = CMFormatDescriptionGetExtension(d, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
            return tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) || tf == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
        }
    }

    /// Builds the playable/exportable edit. `overlay` draws captions and titles into the frames —
    /// on for export and stills, off for the app's preview, which draws them live over the player.
    /// `live` (the app's preview): the sound's levels go on its samples through taps (`LevelTap`) instead of the
    /// player's volume ramps, which stepped a buffer at a time and clicked where a fade starts or ends.
    public func composition(projectURL: URL?, overlay: Bool, live: Bool = false) async throws -> BuiltComposition {
        guard !shots.isEmpty, duration > 0 else { throw CompositionError.empty }
        let comp = AVMutableComposition()
        let fps = canvas.fps
        func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
        let total = time(duration)
        var missing: [String] = []

        let tracks = [comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!,
                      comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!]
        var assets: [String: AVURLAsset] = [:]
        func asset(_ path: String) -> AVURLAsset {
            if let a = assets[path] { return a }
            let a = AVURLAsset(url: Self.resolve(path, relativeTo: projectURL),
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            assets[path] = a
            return a
        }

        let context = RenderContext(project: self, projectURL: projectURL, drawsOverlay: overlay)
        // motion blur: every shot again on a third track, one source frame late — the compositor measures how
        // every pixel moved between the two and blurs along it
        let previous = wantsPreviousFrame ? comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        // and one source frame early: some generators repeat a frame (Seedance: every 4th), and where the frame
        // before is a copy the motion is measured towards the next one instead; a slowed-down shot draws the frames
        // between its source's from this one and its own (made with the first such shot when there is no blur)
        var ahead = wantsPreviousFrame ? comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        // the overlay track: each video on a track of its own lane (a lane holds clips that don't overlap); every
        // instruction asks for these tracks, and the compositor draws whichever plays now over the picture
        var layerLanes: [(track: AVMutableCompositionTrack, end: Double)] = []
        var layerInstructions: [ShotInstruction] = []
        for layer in layers.sorted(by: { $0.start < $1.start }) {
            let range = CMTimeRange(start: time(max(0, layer.start)), end: time(min(layer.end, duration)))
            guard range.duration > .zero else { continue }
            if Self.stillTypes.contains((layer.src as NSString).pathExtension.lowercased()) {
                layerInstructions.append(ShotInstruction(range: range, shot: layer, track: kCMPersistentTrackID_Invalid, orientation: .identity,
                                                         context: context))
                continue
            }
            do {
                guard let sourceTrack = try await asset(layer.src).loadTracks(withMediaType: .video).first else { missing.append(layer.src); continue }
                let picture = try await sourceTrack.load(.timeRange)
                let first = picture.start.seconds, last = picture.end.seconds
                let want = range.duration.seconds * layer.speed               // its footage, at its speed
                let available = max(0.05, min(want, last - max(first, layer.inPoint)))
                let inPoint = max(first, min(layer.inPoint, last - available))
                let lane = layerLanes.firstIndex { $0.end <= range.start.seconds + 0.0005 } ?? {
                    layerLanes.append((comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!, 0))
                    return layerLanes.count - 1
                }()
                let track = layerLanes[lane].track
                try track.insertTimeRange(CMTimeRange(start: time(inPoint), duration: time(available)), of: sourceTrack, at: range.start)
                if abs(available - range.duration.seconds) > 0.001 {
                    track.scaleTimeRange(CMTimeRange(start: range.start, duration: time(available)), toDuration: range.duration)
                }
                layerLanes[lane].end = range.end.seconds
                layerInstructions.append(ShotInstruction(range: range, shot: layer, track: track.trackID,
                                                         orientation: try await sourceTrack.load(.preferredTransform), context: context))
            } catch {
                missing.append(layer.src)
            }
        }
        context.layers = layerInstructions
        let layerTracks = layerLanes.map(\.track.trackID)

        let ordered = shots.sorted(by: { $0.start < $1.start })
        // transitions by the shot before the cut (only cuts that have a shot after them)
        let cuts = Dictionary(transitions.filter { $0.duration > 0.01 }.map { ($0.after, $0) }, uniquingKeysWith: { a, _ in a })

        // 1. every shot on its track; a cut with a transition gets footage past it on both sides (the file's own,
        //    never over the next shot on the same track): `pre` before the shot's start, `post` after its end
        struct Placed { let shot: Shot; let instruction: ShotInstruction; var pre = 0.0; var post = 0.0; var warmed = false }
        var placed: [Placed] = []
        for (index, shot) in ordered.enumerated() {
            let media = CMTimeRange(start: time(max(0, shot.start)), end: time(min(shot.end, duration)))
            func black() -> Placed {
                Placed(shot: shot, instruction: ShotInstruction(range: media, shot: shot, track: kCMPersistentTrackID_Invalid,
                                                                orientation: .identity, layers: layerTracks, context: context))
            }
            if Self.stillTypes.contains((shot.src as NSString).pathExtension.lowercased()) || media.duration <= .zero {
                placed.append(black())                       // a still is drawn by the compositor
                continue
            }
            do {
                let source = asset(shot.src)
                guard let sourceTrack = try await source.loadTracks(withMediaType: .video).first else {
                    // an image in a format not listed as a still is drawn as one; anything else stays black
                    if context.still(shot) == nil { missing.append(shot.src) }
                    placed.append(black())
                    continue
                }
                // the picture's own time range: phone files often carry sound past their last frame
                let picture = try await sourceTrack.load(.timeRange)
                let first = picture.start.seconds, last = picture.end.seconds
                let track = tracks[index % 2]
                // The shot plays `duration · speed` of its footage, squeezed (or spread) into its length. A source
                // shorter than that is stretched to fit rather than leaving black frames.
                let speed = shot.speed
                let want = media.duration.seconds * speed
                let available = max(0.05, min(want, last - max(first, shot.inPoint)))
                let inPoint = max(first, min(shot.inPoint, last - available))
                let stretched = available < want - 0.001
                let rate = Double(try await sourceTrack.load(.nominalFrameRate))
                let sourceFrame = rate > 1 ? 1 / rate : 1 / fps
                // footage seconds per second of the edit: the speed, or less where a source too short is stretched to
                // fit. Slowed so far that source frames would show twice, the frames between are drawn from the
                // optical flow instead (`Tween`).
                let pace = stretched ? available / media.duration.seconds : speed
                let tweened = pace < 0.999 && pace / sourceFrame < fps - 0.001
                // footage for the transitions on either side of the shot: the file's own past the cut, and what it
                // lacks held as a still of its edge frame (as editors do) — so a transition always gets its length
                var pre = 0.0, post = 0.0
                if !stretched {
                    if index > 0, let t = cuts[ordered[index - 1].id] {
                        let trackEnd = track.timeRange.duration > .zero ? track.timeRange.end.seconds : 0
                        pre = max(0, min(t.duration / 2, media.start.seconds - trackEnd))
                    }
                    if index + 1 < ordered.count, let t = cuts[shot.id] {
                        post = max(0, min(t.duration / 2, ordered[index + 1].duration - 0.1))
                    }
                }
                // An HDR (HLG / PQ) phone clip: the first frame AVFoundation converts to SDR on a stretch of track comes
                // out washed out. So its footage starts two frames early on its track, where the
                // shot before still holds the picture and asks for these frames too (`warming`) — the washed-out one is
                // never shown.
                var roll = 0.0
                if !stretched, pre == 0, index > 0, await Self.isHDR(sourceTrack) {
                    let trackEnd = track.timeRange.duration > .zero ? track.timeRange.end.seconds : 0
                    roll = max(0, min(2 * sourceFrame, media.start.seconds - trackEnd - 0.001))
                }
                // (`pre` / `post` are on the edit's clock, `realPre` / `realPost` the footage's: at speed 2 a second of
                // transition takes two of footage)
                let realPre = min((pre + roll) * speed, inPoint - first), realPost = min(post * speed, last - (inPoint + available))
                if pre - realPre / speed > 0.005 {          // the first frame held before the footage starts
                    let hold = CMTimeRange(start: time(media.start.seconds - pre), duration: time(sourceFrame))
                    try track.insertTimeRange(CMTimeRange(start: time(inPoint - realPre), duration: time(sourceFrame)), of: sourceTrack, at: hold.start)
                    track.scaleTimeRange(hold, toDuration: time(pre - realPre / speed))
                }
                let footage = CMTimeRange(start: time(media.start.seconds - realPre / speed), duration: time(available + realPre + realPost))
                try track.insertTimeRange(CMTimeRange(start: time(inPoint - realPre), duration: footage.duration), of: sourceTrack, at: footage.start)
                if stretched {
                    track.scaleTimeRange(CMTimeRange(start: media.start, duration: time(available)), toDuration: media.duration)
                } else if speed != 1 {
                    track.scaleTimeRange(footage, toDuration: time((available + realPre + realPost) / speed))
                }
                if post - realPost / speed > 0.005 {        // the last frame held after the footage ends
                    let at = time(media.end.seconds + realPost / speed)
                    try track.insertTimeRange(CMTimeRange(start: time(inPoint + available + realPost - sourceFrame), duration: time(sourceFrame)),
                                              of: sourceTrack, at: at)
                    track.scaleTimeRange(CMTimeRange(start: at, duration: time(sourceFrame)), toDuration: time(post - realPost / speed))
                }
                // (one source frame: a 24 fps clip on a 30 fps edit would otherwise repeat a frame and lose its blur;
                // not under a stretched source. Sped up, the frame shown before is `speed / fps` of footage back; slowed
                // down, still one source frame — the same frame shown twice has no motion. `back` is footage, `step`
                // the edit's clock; both tracks are squeezed like the shot's own.)
                let back = speed == 1 ? sourceFrame : max(sourceFrame, speed / fps)
                func squeezed(_ track: AVMutableCompositionTrack, from: Double, length: Double, at: CMTime) throws {
                    try track.insertTimeRange(CMTimeRange(start: time(from), duration: time(length)), of: sourceTrack, at: at)
                    if pace != 1 { track.scaleTimeRange(CMTimeRange(start: at, duration: time(length)), toDuration: time(length / pace)) }
                }
                var late = kCMPersistentTrackID_Invalid
                var step = 1 / fps
                if let previous {
                    step = back / speed
                    if !stretched, available > back * 2 {
                        if inPoint - back >= first - 0.0001 {
                            // the source has a frame before the in-point: even the shot's first frame gets its blur
                            try squeezed(previous, from: inPoint - back, length: available, at: media.start)
                        } else {
                            try squeezed(previous, from: inPoint, length: available - back, at: time(media.start.seconds + step))
                        }
                        late = previous.trackID
                    }
                }
                var early = kCMPersistentTrackID_Invalid
                if tweened, ahead == nil { ahead = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) }
                if let ahead, !stretched || tweened, available > back * 2 {
                    let lead = tweened ? sourceFrame : back                  // for the in-betweens exactly the next frame
                    let length = min(available, last - (inPoint + lead))     // the last frame has none after it
                    if length > lead {
                        try squeezed(ahead, from: inPoint + lead, length: length, at: media.start)
                        early = ahead.trackID
                    }
                }
                // the in-betweens: both tracks' clocks as built (AVFoundation picks frames by them) and the footage's
                // frame times, so the compositor knows which two frames it got and where between them it is
                var tween: Tween?
                if tweened, let ahead, early != kCMPersistentTrackID_Invalid {
                    let probe = time(media.start.seconds + 0.5 / fps)
                    func mapping(_ t: AVMutableCompositionTrack) -> Tween.Mapping? {
                        guard let m = t.segments.first(where: { !$0.isEmpty && $0.timeMapping.target.containsTime(probe) })?.timeMapping,
                              m.target.duration.seconds > 0 else { return nil }
                        return Tween.Mapping(target: m.target.start.seconds, source: m.source.start.seconds,
                                             rate: m.source.duration.seconds / m.target.duration.seconds)
                    }
                    let frames = await Tween.frames(of: sourceTrack, from: inPoint - realPre - 2 * sourceFrame,
                                                    to: inPoint + available + realPost + 2 * sourceFrame)
                    if let own = mapping(track), let next = mapping(ahead), frames.count > 1 { tween = Tween(own: own, ahead: next, frames: frames) }
                }
                let transform = try await sourceTrack.load(.preferredTransform)
                placed.append(Placed(shot: shot, instruction: ShotInstruction(range: media, shot: shot, track: track.trackID, previous: late, next: early,
                                                                              step: step, tween: tween, orientation: transform, layers: layerTracks,
                                                                              context: context),
                                     pre: pre, post: post, warmed: roll > 0 && realPre > 0.001))
            } catch {
                missing.append(shot.src)
                placed.append(black())
            }
        }

        // 2. Instructions must tile the timeline exactly: each starts where the one before ends (the first at 0),
        //    a shot runs to the next one's start (the last to the end) — or to where its transition begins, which
        //    runs to where the footage before the next shot ends. A gap shows black, an overlap the later shot.
        var instructions: [any AVVideoCompositionInstructionProtocol] = []
        var reached = CMTime.zero
        for (k, item) in placed.enumerated() {
            let next = k + 1 < placed.count ? placed[k + 1] : nil
            let cut = next.map { min(time($0.shot.start), total) } ?? total
            var window: CMTimeRange?
            if let next, let clip = cuts[item.shot.id], item.post > 0.02 || next.pre > 0.02 {
                let from = max(reached, time(cut.seconds - next.pre)), to = min(total, time(cut.seconds + item.post))
                if to - from > CMTime(value: 1, timescale: CMTimeScale(fps.rounded())) {
                    window = CMTimeRange(start: from, end: to)
                    let end = window!.start
                    if end > reached { instructions.append(item.instruction.covering(CMTimeRange(start: reached, end: end))); reached = end }
                    instructions.append(TransitionInstruction(range: window!, from: item.instruction, to: next.instruction, clip: clip,
                                                              context: context))
                    reached = window!.end
                    continue
                }
            }
            if cut > reached {
                let warm = next.flatMap { $0.warmed ? $0.instruction.track : nil } ?? kCMPersistentTrackID_Invalid
                instructions.append(item.instruction.covering(CMTimeRange(start: reached, end: cut), warming: warm)); reached = cut
            }
        }
        guard !instructions.isEmpty else { throw CompositionError.empty }

        let mix = AVMutableAudioMix()
        var parameters: [AVMutableAudioMixInputParameters] = []
        // the voice through its chain (levelled, compressed, limited — rendered once into a cache)
        var audio = self.audio
        if let chain = master.voice { audio = await VoiceRender.processed(audio, chain: chain, projectURL: projectURL) }
        // and clips at another speed rendered at it (pitch kept), laid in as they are
        audio = await SpeedRender.sped(audio, projectURL: projectURL)
        let voice = audio.filter { $0.role == .voice }
        let envelope = await DuckEnvelope.from(voice: voice, projectURL: projectURL, until: duration)
        // Clips of one file that don't overlap share a track — a track per clip stalled the preview past ~140 clips
        // (a voice cut into its lines); each clip's level, fades and ducking ride on that track at its own time.
        struct Lane { let key: String; var end: Double; let track: AVMutableCompositionTrack; let source: String; let panLaw: Double
                      var clips: [(clip: AudioClip, span: Double)]; var endSample: Int64? = nil }
        var lanes: [Lane] = []
        for clip in audio.sorted(by: { $0.start < $1.start }) {
            do {
                let source = asset(clip.src)
                guard let sourceTrack = try await source.loadTracks(withMediaType: .audio).first else { missing.append(clip.src); continue }
                let length = try await source.load(.duration).seconds
                // a clip starting before 0 loses its head; one starting after the end is left out (`skip` and `span`
                // on the edit's clock; at another speed the source runs `speed` times as fast, pitch kept)
                let speed = clip.speed
                let skip = max(0, -clip.start)
                let rest = (length - clip.inPoint) / speed - skip
                let span = min(clip.duration.map { $0 - skip } ?? rest, rest, duration - max(0, clip.start))
                guard span > 0.01 else { continue }
                var placed = clip
                placed.start = max(0, clip.start); placed.inPoint += skip * speed
                let key = "\(clip.role.rawValue)|\(clip.src)"
                let k: Int
                if let free = lanes.firstIndex(where: { $0.key == key && $0.end <= placed.start + 0.0005 }) {
                    k = free
                } else {
                    // fixed ids, so the volume automation of an unchanged track carries over to the next build
                    let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: CMPersistentTrackID(1000 + lanes.count))
                        ?? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
                    let file = Self.resolve(clip.src, relativeTo: projectURL)
                    let stamp = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    lanes.append(Lane(key: key, end: 0, track: track, source: "\(file.path)@\(stamp)",
                                      panLaw: try await Volume.panLaw(sourceTrack), clips: []))
                    k = lanes.count - 1
                }
                // in whole samples: on the edit's 1/600 s clock a piece cut off a longer one landed up to 1.7 ms off its
                // neighbour, and a piece overlapping the one before by a sample pushes everything after it along (an
                // insert, not an overwrite) — so each piece starts at the sample where the one before ended
                let rate = 48_000.0
                var at = Int64((placed.start * rate).rounded())
                // never past the edit's end as the picture counts it (1/600 s): sound even a sample longer makes the
                // video composition invalid — the player then shows no picture at all
                let end = min(Int64(((placed.start + span) * rate).rounded()), Int64((total.seconds * rate).rounded(.down)))
                if let last = lanes[k].endSample, at < last { at = last }
                guard end - at > 0 else { continue }
                let from = Int64((placed.inPoint * rate).rounded())
                let used = speed == 1 ? end - at : min(Int64((Double(end - at) * speed).rounded()), Int64((length * rate).rounded(.down)) - from)
                guard used > 0 else { continue }
                try lanes[k].track.insertTimeRange(CMTimeRange(start: CMTime(value: from, timescale: 48_000),
                                                               duration: CMTime(value: used, timescale: 48_000)),
                                                   of: sourceTrack, at: CMTime(value: at, timescale: 48_000))
                if used != end - at {
                    lanes[k].track.scaleTimeRange(CMTimeRange(start: CMTime(value: at, timescale: 48_000), duration: CMTime(value: used, timescale: 48_000)),
                                                  toDuration: CMTime(value: end - at, timescale: 48_000))
                }
                lanes[k].endSample = end
                lanes[k].end = placed.start + span
                lanes[k].clips.append((placed, span))
            } catch {
                missing.append(clip.src)
            }
        }
        var taps: [CMPersistentTrackID: LevelTap] = [:]
        for lane in lanes {
            if live {
                let levels = LevelTap.Levels(clips: lane.clips.map { ($0.clip, $0.span, $0.clip.duck ? envelope?.curve($0.clip) : nil) },
                                             panLaw: lane.panLaw)
                let tap = LevelTap(levels)
                let made = AVMutableAudioMixInputParameters()
                made.trackID = lane.track.trackID
                made.audioTapProcessor = tap.takeProcessor()
                taps[lane.track.trackID] = tap
                parameters.append(made)
                continue
            }
            parameters.append(MixCache.parameters(track: lane.track.trackID, source: lane.source, clips: lane.clips, duck: envelope,
                                                  panLaw: lane.panLaw))
        }
        mix.inputParameters = parameters

        // Stills and black put no media on the tracks, so without this the edit would end at the last movie.
        if comp.duration < total, let track = tracks.first {
            track.insertEmptyTimeRange(CMTimeRange(start: track.timeRange.end, end: total))
        }

        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = SimbiaCompositor.self
        video.renderSize = CGSize(width: canvas.width, height: canvas.height)
        video.frameDuration = CMTime(value: 1000, timescale: CMTimeScale((fps * 1000).rounded()))
        video.instructions = instructions
        var built = BuiltComposition(asset: comp, video: video, audio: mix, context: context, missing: missing)
        built.taps = taps
        return built
    }
}

// MARK: - Instructions

/// One shot's stretch of the timeline. Carries what the compositor needs to draw it.
final class ShotInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let shot: Shot
    let track: CMPersistentTrackID
    /// The same footage one source frame late (motion blur), or invalid; `step` = that frame's length.
    let previous: CMPersistentTrackID
    /// The same footage one source frame early (motion blur where the frame before is a repeat), or invalid.
    let next: CMPersistentTrackID
    let step: Double
    /// A slowed-down shot: where between its frame and `next` each frame of the edit falls (optical-flow in-betweens).
    let tween: Tween?
    let orientation: CGAffineTransform
    /// The overlay track's tracks: their frames come along, so a video laid over this stretch can be drawn.
    let layers: [CMPersistentTrackID]
    let context: RenderContext

    init(range: CMTimeRange, shot: Shot, track: CMPersistentTrackID, previous: CMPersistentTrackID = kCMPersistentTrackID_Invalid,
         next: CMPersistentTrackID = kCMPersistentTrackID_Invalid, step: Double = 1 / 30, tween: Tween? = nil, orientation: CGAffineTransform,
         layers: [CMPersistentTrackID] = [], context: RenderContext) {
        timeRange = range
        self.shot = shot
        self.track = track
        self.previous = previous
        self.next = next
        self.step = step
        self.tween = tween
        self.orientation = orientation
        self.layers = layers
        self.context = context
        requiredSourceTrackIDs = ([track, previous, next] + layers).filter { $0 != kCMPersistentTrackID_Invalid }.map { NSNumber(value: $0) }
    }

    /// The same shot over another stretch of the timeline; `warming`: the next shot's track, whose first frames
    /// (laid early on it, an HDR clip) come along unseen so that its first shown frame is converted right.
    func covering(_ range: CMTimeRange, warming: CMPersistentTrackID = kCMPersistentTrackID_Invalid) -> ShotInstruction {
        ShotInstruction(range: range, shot: shot, track: track, previous: previous, next: next, step: step, tween: tween, orientation: orientation,
                        layers: layers + (warming == kCMPersistentTrackID_Invalid || warming == track ? [] : [warming]), context: context)
    }
}

/// A transition's stretch: both shots drawn and put together by `TransitionRender`.
final class TransitionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let from: ShotInstruction
    let to: ShotInstruction
    let clip: TransitionClip
    let context: RenderContext

    init(range: CMTimeRange, from: ShotInstruction, to: ShotInstruction, clip: TransitionClip, context: RenderContext) {
        timeRange = range
        self.from = from; self.to = to; self.clip = clip; self.context = context
        requiredSourceTrackIDs = ([from.track, to.track] + from.layers).filter { $0 != kCMPersistentTrackID_Invalid }.map { NSNumber(value: $0) }
    }
}
