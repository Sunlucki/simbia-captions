import AVFoundation
import MediaToolbox

/// The preview's sound levels — gain, fades and their arcs, ducking — put on every sample of a sound track by our own
/// code as the player plays it (an audio processing tap), by the very curve the export's volume ramps follow
/// (`Volume.level`). The player's own volume ramps changed the level a buffer at a time, which clicked where a fade
/// starts or ends; the export reads the same ramps sample by sample and never did. A change made while it plays
/// (`retarget`) glides over 20 ms instead of jumping.
public final class LevelTap: @unchecked Sendable {
    /// One track's levels: its clips (in time order, not overlapping) with the length each plays and its ducking.
    public struct Levels: @unchecked Sendable {
        let clips: [(clip: AudioClip, span: Double, dip: [Float]?)]
        let panLaw: Double

        /// The level at `t` on the edit's clock; `k` is where the last look ended (a buffer goes forward). Between clips
        /// the one before holds its last level, before the first the first holds its first — as the ramps did.
        func value(at t: Double, from k: inout Int) -> Float {
            guard !clips.isEmpty else { return 1 }
            if k >= clips.count || clips[k].clip.start > t { k = 0 }
            while k + 1 < clips.count, clips[k + 1].clip.start <= t { k += 1 }
            let c = clips[k]
            return Volume.level(c.clip, span: c.span, dip: c.dip, panLaw: panLaw, at: min(max(t - c.clip.start, 0), c.span))
        }
    }

    /// The tap for the track's mix parameters — handed over once (`takeProcessor`): it keeps this object alive for as
    /// long as the player uses it, so this one must not keep it in turn.
    private var processor: MTAudioProcessingTap?
    public func takeProcessor() -> MTAudioProcessingTap? { defer { processor = nil }; return processor }
    public private(set) var levels: Levels
    private var gliding: Levels?
    private var glide = 1.0
    private var generation = 0
    private let lock = NSLock()
    // the render thread's own
    private var rate = 48_000.0, channels = 2, interleaved = false
    /// For `simbia playtap`: what the tap let through (the left channel), with the edit time of its first sample.
    public var record = false
    private var recorded: [(start: Double, samples: [Float])] = []
    public func takeRecorded() -> [(start: Double, samples: [Float])] { lock.withLock { recorded } }
    public var sampleRate: Double { rate }

    init(_ levels: Levels) {
        self.levels = levels
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
            init: { _, info, storage in storage.pointee = info },
            finalize: { tap in Unmanaged<LevelTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                let me = Unmanaged<LevelTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                me.rate = format.pointee.mSampleRate
                me.channels = Int(format.pointee.mChannelsPerFrame)
                me.interleaved = format.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                let me = Unmanaged<LevelTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                var range = CMTimeRange()
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, &range, framesOut) == noErr else { return }
                me.apply(buffers, frames: Int(framesOut.pointee), reported: range.start)
            })
        var tap: MTAudioProcessingTap?
        if MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap) == noErr {
            processor = tap
        } else {
            Unmanaged.passUnretained(self).release()                 // the tap never took it
        }
    }

    /// New levels for the track while it plays (a level edit): they take over within 20 ms.
    public func retarget(_ new: Levels) {
        lock.withLock { gliding = levels; levels = new; glide = 0; generation += 1 }
    }

    private func apply(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames n: Int, reported: CMTime) {
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        // A buffer without a time (the first after a start or a seek: the player's silent preroll) stays silent. (A tap
        // after the mix's effects is told the buffer before's time; this one, before them, its own — measured.)
        let known = reported.isNumeric
        let start = reported.seconds
        guard known else {
            for b in list { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            return
        }
        let (now, before, from, made) = lock.withLock { (levels, gliding, glide, generation) }
        var g = from
        let step = 1 / (0.02 * rate)
        var k = 0, kb = 0
        var gains = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = start + Double(i) / rate
            var v = now.value(at: t, from: &k)
            if g < 1, let before {
                let w = before.value(at: t, from: &kb)
                v = w + (v - w) * Float(g)
                g = min(1, g + step)
            }
            gains[i] = v
        }
        if before != nil { lock.withLock { if generation == made { glide = g; if g >= 1 { gliding = nil } } } }
        if interleaved {
            guard let d = list[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            for i in 0..<n { for c in 0..<channels { d[i * channels + c] *= gains[i] } }
        } else {
            for b in list { guard let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }; for i in 0..<n { d[i] *= gains[i] } }
        }
        if record, let d = list[0].mData?.assumingMemoryBound(to: Float.self) {
            let step = interleaved ? channels : 1
            let left = (0..<n).map { d[$0 * step] }
            lock.withLock { recorded.append((start, left)) }
        }
    }
}
