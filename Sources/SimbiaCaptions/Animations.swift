import Foundation

/// Turns animation presets into ASS override runs.
///
/// A cue is emitted as up to two Dialogue events: the entrance-and-hold, then the exit over
/// the tail. Splitting them is what lets any entrance pair with any exit — `\move` can only
/// appear once per event, so SLIDE UP + SLIDE DOWN would be impossible in a single one.
///
/// Every string here was checked by rendering frames with ffmpeg and measuring the drawn
/// bounding box, because libass has traps that fail silently:
///   • `\t()` cannot animate `\pos`, `\move`, `\org` or `\fad` — those snap at parse time.
///   • Outline width does NOT scale with `\fscx/\fscy`, so scale presets ride `\bord` along
///     or the stroke visibly fattens as the text shrinks.
///   • `\alpha` writes all four alpha channels, so it must precede `\3a`/`\4a`.
///   • A drawing's bounding box is measured from the path origin, so plate paths stay positive.
@MainActor extension Anim {

    // MARK: Entrance

    /// Position plus the entrance, as one override run. Shared by the text and the backplate
    /// so they move as a single object.
    func lineMotion(centre: CGPoint, layout: CaptionLayout, duration: Double, job: Job,
                    outline: Bool = true, fadeOut: Int) -> String {
        let anchorX = outline ? job.look.alignment.anchorX(centre: centre.x, width: layout.textWidth)
                              : centre.x
        let x = fmt(anchorX), y = fmt(centre.y)
        let pos = "\\pos(\(x),\(y))"
        let size = layout.size
        // The plate is a \p1 drawing: a border would grow it by 2*bord on every side.
        let bord = (outline && job.look.outlineOn) ? job.look.outlineWidth * size : 0
        func ride(_ from: Double) -> (String, String) {
            guard bord > 0 else { return ("", "") }
            return ("\\bord\(fmt(bord * from))", "\\bord\(fmt(bord))")
        }
        let fade = "\\fad(\(entranceFade),\(fadeOut))"

        switch self {
        case .none:
            return pos + (fadeOut > 0 ? "\\fad(0,\(fadeOut))" : "")

        case .pop:
            let (b0, b1) = ride(0.6)
            return pos + fade + "\\fscx60\\fscy60\(b0)\\t(0,130,0.6,\\fscx100\\fscy100\(b1))"

        case .fade:
            return pos + "\\fad(180,\(fadeOut))"

        case .slideUp:
            let from = fmt(centre.y + size * 0.55)
            return "\\fad(110,\(fadeOut))\\move(\(x),\(from),\(x),\(y),0,170)"

        case .bounce:
            let (b0, b1) = ride(0.55)
            return pos + fade + "\\fscx55\\fscy55\(b0)"
                + "\\t(0,110,0.6,\\fscx112\\fscy112\(b1))\\t(110,190,\\fscx97\\fscy97)\\t(190,250,\\fscx100\\fscy100)"

        case .zoomOut:
            let (b0, b1) = ride(1.4)
            return pos + fade + "\\fscx140\\fscy140\(b0)\\t(0,170,0.7,\\fscx100\\fscy100\(b1))"

        case .shake:
            return pos + fade + "\\frz-5"
                + "\\t(0,70,\\frz4)\\t(70,140,\\frz-3)\\t(140,210,\\frz2)\\t(210,280,\\frz0)"

        case .glitch, .typewriter, .wave:
            return pos + fade
        }
    }

    private var entranceFade: Int {
        switch self {
        case .none: return 0
        case .fade: return 180
        case .slideUp: return 110
        case .bounce: return 40
        case .glitch: return 20
        default: return 50
        }
    }

    /// What the backplate does during the entrance. Glyph-splitting presets leave it still.
    func plateMotion(centre: CGPoint, layout: CaptionLayout, duration: Double, job: Job,
                     fadeOut: Int) -> String {
        guard splitsGlyphs else {
            return lineMotion(centre: centre, layout: layout, duration: duration, job: job,
                              outline: false, fadeOut: fadeOut)
        }
        return "\\pos(\(fmt(centre.x)),\(fmt(centre.y)))\\fad(60,\(fadeOut))"
    }

    /// Text events for the entrance-and-hold segment, ending at `end`.
    func textLines(cue: Cue, layout: CaptionLayout, duration: Double, job: Job,
                   end: Double, fadeOut: Int) -> [String] {
        let body = Job.escapeASS(job.displayText(cue.text))
        let glow = job.look.glow > 0 ? "\\blur\(fmt(job.look.glow))" : ""
        let anchor = "\\an\(job.look.alignment.assAnchor)"

        switch self {
        case .glitch:
            return glitchLines(cue: cue, layout: layout, duration: duration, job: job,
                               body: body, glow: glow, end: end, fadeOut: fadeOut)
        case .typewriter:
            return typewriterLines(cue: cue, layout: layout, duration: duration, job: job,
                                   glow: glow, end: end, fadeOut: fadeOut)
        case .wave:
            return waveLines(cue: cue, layout: layout, duration: duration, job: job,
                             glow: glow, end: end, fadeOut: fadeOut)
        default:
            let motion = lineMotion(centre: layout.centre, layout: layout, duration: duration,
                                    job: job, fadeOut: fadeOut)
            return [job.event(layer: 1, cue: cue, style: job.styleName(accent: cue.accent), override: anchor + job.accentTag(cue.accent) + motion + glow,
                              body: body, end: end)]
        }
    }

    // MARK: Per-character entrances

    /// Characters arrive one after another; each stays put once it lands.
    private func typewriterLines(cue: Cue, layout: CaptionLayout, duration: Double,
                                 job: Job, glow: String, end: Double, fadeOut: Int) -> [String] {
        let count = max(1, layout.glyphs.count)
        let step = min(0.06, duration * 0.55 / Double(count))
        return layout.glyphs.enumerated().map { index, glyph in
            let x = fmt(layout.centre.x + glyph.dx)
            let y = fmt(layout.centre.y + glyph.dy)
            return job.event(layer: 1, cue: cue, style: job.styleName(accent: cue.accent),
                             override: "\\an5" + job.accentTag(cue.accent) + "\\pos(\(x),\(y))\\fad(0,\(fadeOut))" + glow,
                             body: Job.escapeASS(glyph.text),
                             start: cue.start + Double(index) * step, end: end)
        }
    }

    /// A cascade: each character rises into place a beat after the one before it. The stagger
    /// has to fit inside the cue, or a short caption is still assembling when it disappears.
    private func waveLines(cue: Cue, layout: CaptionLayout, duration: Double,
                           job: Job, glow: String, end: Double, fadeOut: Int) -> [String] {
        let rise = 190.0
        let budget = max(0, duration * 1000 * 0.55 - rise)
        let stagger = min(42, budget / Double(max(1, layout.glyphs.count - 1)))
        return layout.glyphs.enumerated().map { index, glyph in
            let x = fmt(layout.centre.x + glyph.dx)
            let y = layout.centre.y + glyph.dy
            let lift = fmt(y + layout.size * 0.45)
            let delay = Int(Double(index) * stagger)
            return job.event(layer: 1, cue: cue, style: job.styleName(accent: cue.accent),
                             override: "\\an5" + job.accentTag(cue.accent) + "\\fad(40,\(fadeOut))"
                                 + "\\move(\(x),\(lift),\(x),\(fmt(y)),\(delay),\(delay + Int(rise)))" + glow,
                             body: Job.escapeASS(glyph.text), end: end)
        }
    }

    /// RGB split that converges, plus two clipped slices that jump sideways.
    private func glitchLines(cue: Cue, layout: CaptionLayout, duration: Double, job: Job,
                             body: String, glow: String, end: Double, fadeOut: Int) -> [String] {
        let x = layout.centre.x, y = layout.centre.y
        let kick = layout.size * 0.14
        let settle = Int(min(220, duration * 1000 * 0.35))
        let anchor = "\\an\(job.look.alignment.assAnchor)"
        var lines: [String] = []

        for (colour, direction) in [("#FF0044", -1.0), ("#00E5FF", 1.0)] {
            let from = fmt(x + kick * direction)
            let override = "\\an5\\move(\(from),\(fmt(y)),\(fmt(x)),\(fmt(y)),0,\(settle))"
                + "\\1c\(assOverrideColor(colour))\\alpha&H60&\\3a&HFF&\\4a&HFF&"
                + "\\t(0,\(settle),\\alpha&HFF&)"
            lines.append(job.event(layer: 1, cue: cue, style: job.styleName(accent: cue.accent), override: override, body: body,
                                   end: min(end, cue.start + Double(settle) / 1000)))
        }

        let motion = lineMotion(centre: layout.centre, layout: layout, duration: duration,
                                job: job, fadeOut: fadeOut)
        lines.append(job.event(layer: 2, cue: cue, style: job.styleName(accent: cue.accent),
                               override: anchor + job.accentTag(cue.accent) + motion + glow, body: body, end: end))

        let half = layout.box.height / 2
        for (index, band) in [(0.12, 0.34, -kick * 1.3, 0.0), (0.52, 0.74, kick * 1.6, 0.06)].enumerated() {
            let top = y - half + layout.box.height * band.0
            let bottom = y - half + layout.box.height * band.1
            let begin = cue.start + duration * band.3
            let stop = min(end, begin + 0.07)
            guard stop > begin else { continue }
            let clip = "\\clip(\(fmt(x - layout.box.width)),\(fmt(top)),\(fmt(x + layout.box.width)),\(fmt(bottom)))"
            let override = "\\an5\\pos(\(fmt(x + band.2)),\(fmt(y)))" + clip + glow
                + (index == 0 ? "\\1c\(assOverrideColor("#FFFFFF"))" : "")
            lines.append(job.event(layer: 3, cue: cue, style: job.styleName(accent: cue.accent), override: override, body: body,
                                   start: begin, end: stop))
        }
        return lines
    }
}

// MARK: - Exits

@MainActor extension Outro {

    /// The exit as one override run, for an event that starts where the hold ended.
    func motion(centre: CGPoint, layout: CaptionLayout, milliseconds: Int, job: Job,
                outline: Bool = true) -> String {
        let anchorX = outline ? job.look.alignment.anchorX(centre: centre.x, width: layout.textWidth)
                              : centre.x
        let x = fmt(anchorX), y = fmt(centre.y)
        let pos = "\\pos(\(x),\(y))"
        let size = layout.size
        let bord = (outline && job.look.outlineOn) ? job.look.outlineWidth * size : 0
        // Ride the outline down with any shrink, or the stroke swallows the glyphs.
        func ride(_ to: Double) -> String { bord > 0 ? "\\bord\(fmt(bord * to))" : "" }
        let d = milliseconds

        switch self {
        case .none:
            return pos
        case .fade:
            return pos + "\\fad(0,\(d))"
        case .shrink:
            return pos + "\\t(0,\(d),\\fscx55\\fscy55\\alpha&HFF&\(ride(0.55)))"
        case .grow:
            return pos + "\\t(0,\(d),\\fscx145\\fscy145\\alpha&HFF&\(ride(1.45)))"
        case .slideDown:
            let to = fmt(centre.y + size * 0.8)
            return "\\move(\(x),\(y),\(x),\(to),0,\(d))\\t(0,\(d),\\alpha&HFF&)"
        case .riseUp:
            let to = fmt(centre.y - size * 0.8)
            return "\\move(\(x),\(y),\(x),\(to),0,\(d))\\t(0,\(d),\\alpha&HFF&)"
        case .blurOut:
            return pos + "\\t(0,\(d),\\blur12\\alpha&HFF&)"
        case .spin:
            return pos + "\\t(0,\(d),\\frz30\\fscx35\\fscy35\\alpha&HFF&\(ride(0.35)))"
        case .particles, .glitchOut:
            return pos + "\\fad(0,\(max(60, d / 3)))"
        }
    }

    /// Backplate behaviour during the exit — it must leave with the text, not linger.
    func plateMotion(centre: CGPoint, layout: CaptionLayout, milliseconds: Int, job: Job) -> String {
        switch self {
        case .particles:
            return "\\pos(\(fmt(centre.x)),\(fmt(centre.y)))\\t(0,\(milliseconds),\\alpha&HFF&\\blur4)"
        case .glitchOut:
            return "\\pos(\(fmt(centre.x)),\(fmt(centre.y)))\\fad(0,\(milliseconds))"
        default:
            return motion(centre: centre, layout: layout, milliseconds: milliseconds,
                          job: job, outline: false)
        }
    }

    /// Text events for the exit segment, starting at `start`.
    func textLines(cue: Cue, layout: CaptionLayout, seconds: Double, job: Job,
                   start: Double) -> [String] {
        let body = Job.escapeASS(job.displayText(cue.text))
        let glow = job.look.glow > 0 ? "\\blur\(fmt(job.look.glow))" : ""
        let ms = Int(seconds * 1000)
        let anchor = "\\an\(job.look.alignment.assAnchor)"

        switch self {
        case .particles:
            return particleLines(cue: cue, layout: layout, milliseconds: ms, job: job,
                                 glow: glow, start: start)
        case .glitchOut:
            return glitchOutLines(cue: cue, layout: layout, milliseconds: ms, job: job,
                                  body: body, glow: glow, start: start)
        default:
            let motion = motion(centre: layout.centre, layout: layout, milliseconds: ms, job: job)
            return [job.event(layer: 1, cue: cue, style: job.styleName(accent: cue.accent), override: anchor + job.accentTag(cue.accent) + motion + glow,
                              body: body, start: start)]
        }
    }

    /// Every character flies off, spinning, blurring and fading.
    private func particleLines(cue: Cue, layout: CaptionLayout, milliseconds: Int, job: Job,
                               glow: String, start: Double) -> [String] {
        layout.glyphs.enumerated().map { index, glyph in
            let x = layout.centre.x + glyph.dx
            let y = layout.centre.y + glyph.dy
            let angle = stableNoise(index * 7 + 1) * 2 * .pi
            let reach = layout.size * (0.7 + stableNoise(index * 13 + 5) * 1.1)
            let spin = (stableNoise(index * 31 + 3) - 0.5) * 160
            let toX = fmt(x + cos(angle) * reach)
            let toY = fmt(y + sin(angle) * reach - layout.size * 0.3)
            let override = "\\an5" + job.accentTag(cue.accent)
                + "\\move(\(fmt(x)),\(fmt(y)),\(toX),\(toY),0,\(milliseconds))"
                + glow
                + "\\t(0,\(milliseconds),\\alpha&HFF&\\frz\(fmt(spin))\\fscx30\\fscy30\\blur6)"
            return job.event(layer: 1, cue: cue, style: job.styleName(accent: cue.accent), override: override,
                             body: Job.escapeASS(glyph.text), start: start)
        }
    }

    /// The entrance glitch in reverse: ghosts pull apart as the caption dies.
    private func glitchOutLines(cue: Cue, layout: CaptionLayout, milliseconds: Int, job: Job,
                                body: String, glow: String, start: Double) -> [String] {
        let x = layout.centre.x, y = layout.centre.y
        let kick = layout.size * 0.18
        var lines: [String] = []
        for (colour, direction) in [("#FF0044", -1.0), ("#00E5FF", 1.0)] {
            let to = fmt(x + kick * direction)
            lines.append(job.event(layer: 1, cue: cue, style: job.styleName(accent: cue.accent),
                override: "\\an5\\move(\(fmt(x)),\(fmt(y)),\(to),\(fmt(y)),0,\(milliseconds))"
                    + "\\1c\(assOverrideColor(colour))\\alpha&H50&\\3a&HFF&\\4a&HFF&"
                    + "\\t(0,\(milliseconds),\\alpha&HFF&)",
                body: body, start: start))
        }
        lines.append(job.event(layer: 2, cue: cue, style: job.styleName(accent: cue.accent),
            override: "\\an\(job.look.alignment.assAnchor)\\pos(\(fmt(x)),\(fmt(y)))" + glow
                + "\\t(0,\(milliseconds),\\alpha&HFF&)",
            body: body, start: start))
        return lines
    }
}
