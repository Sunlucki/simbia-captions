# Simbia Captions — features

A native macOS editor for vertical UGC ads (9:16): shots, captions, titles, motion graphics, colour, sound and export in one window, with a project file that Claude can edit at the same time as you. Interface in **English, Russian and French** (menu *Language*).



Contents: [Start screen](#start-screen) · [Projects](#project-browser) · [Brief and tasks](#brief-and-tasks) · [Editor window](#editor-window) · [Timeline](#timeline) · [Shots](#shots) · [Overlay videos and keying](#overlay-videos-chroma-key-and-transform) · [Crop and covers](#crop-crop-keys-and-cover-text) · [Colour](#colour) · [Transitions](#transitions) · [Captions](#captions) · [Caption styles](#caption-styles) · [Titles](#titles) · [Graphics and reviews](#graphics-kit-scenes-and-reviews) · [Sound](#sound) · [Music library](#music-library) · [Footage](#footage-project-videos-and-the-footage-library) · [Checks](#checks-before-export) · [Text tools](#text-tools) · [Export](#export) · [Sync with Claude](#project-file-and-live-sync-with-claude) · [Command line](#command-line-binsimbia) · [Shortcuts](#keyboard-shortcuts) · [Languages](#languages)

---

## Start screen


- **Recent projects**: batches of the folder of the last opened project, newest batch first. Each row shows the number range ("VD 12–15"), the category, counts per status and one tile per video (still of the first shot, ringed in its status colour). Click a tile to open it.
- **All projects** opens the project browser.
- **Upload video** opens a video (or drop a file anywhere on the window). Speech is recognised by the Mac itself, on the device; **Speech: <language>** picks the language.
- **Load an existing SRT** after choosing a video, if you already have captions.
- While working: looping logo, progress in %, the status line and a glow around the window.

## Project browser


- Full-window grid of every `.simbia` project in the folder, grouped into batches (consecutive VD numbers of one category, up to 4), newest first.
- Filter chips **All / New / In review / Done** with counts; **Search…** by name; Esc closes.
- Tile: 9:16 still, status badge, "OPEN" on the open project, VD number, length, open tasks ("left: N").
- Click selects and shows the detail panel; double-click opens. Right-click: set status, Open, Show in Finder.
- Detail panel: poster, name, length · shots · captions, revision and who saved it, **status buttons**, the **To do** list (tick, add with "New task…", right-click to delete) and the **edit journal** (last 30 entries, you in blue, Claude in orange).
- Status and task changes to a closed project are written into its file as a new revision, with a journal entry.

## Brief and tasks


Click the project's name in the header.

- Status control (New / Review / Done), **Card** (opens the brief's card link), **All projects**, close (Esc).
- **References**: links and files with an icon per type; web links open in the browser, files in their app.
- **What we are making**, **This video's hook**, **What is asked of us**.
- **The scenes in order**: who, gist, the exact spoken words, and a yellow **In the edit:** line where the edit differs from the brief.
- **To check** (yellow): tasks marked for review with a **Checked** button, the number of export checks with **Open**, flagged shots and sounds.
- **Left to do** and **Done**; add tasks with "New task…"; right-click deletes.
- **Latest edits**: the last 12 journal entries, yours and Claude's.

## Editor window

- One window, one project. Opening another project replaces it (menu **Projects**: *Open Project…* ⇧⌘O, *In this folder*, *Recent*, *Show Project in Finder*).
- Header: projects grid button, project name (opens the brief) with its status, frame size · length · shots · captions · paragraphs · titles, the **sync pill** ("Claude · in sync", or "Updated by Claude · ⌘Z" after an outside change; "Not linked to Claude" → *Save as project…*), Undo, Redo, **SRT**, **Checks**, **Export**.
- Player: the same renderer as the export (captions, titles and graphics drawn live at the video's frame rate). Transport: time, previous caption, play/pause, next caption.
- **Preview as**: TikTok / Instagram Reels / No frame — a see-through mock of the app's interface with the unsafe bands shaded.
- **Drag on the picture** to move captions, titles, review cards, kit scenes, overlay videos and emoji. The safe zone and centre lines show while dragging; pieces snap to the centre, the safe-zone edges and their home place (⌘ turns the magnet off); a piece outside the safe zone gets an orange outline. Double-click puts a piece back.
- **Align all titles to this one** (right-click a title, ⇧⌘A): every other title gets this title's height, one undo step.
- Edge preview: while trimming, slipping or rolling a cut, the frames that will be on the edges show over the picture ("first frame · 33.75 s"), like Final Cut.
- Notices at the top of the picture; progress overlay during long operations. Undo history: 120 steps over everything.

## Timeline


- Tracks, top to bottom: ruler, **Bars**, **Titles**, **Graphics**, **Overall** filter, **Filters**, **Overlay**, crop **Keys**, **Shots**, voice pivots, **Voice**, **Captions**, **Music**.
- Scrub on the ruler or any empty track. Zoom: pinch, ⌥-scroll, or the zoom control (*Zoom out*, *Zoom in*, *The whole edit*); two-finger scroll pans.
- **Snap**: cuts, titles, captions and shot edges stick to the music's beats. Tempo label "N BPM"; the Bars track shows numbered bars and beat ticks.
- **Make captions**: the Mac captions every voice clip (or the whole video), each clip its own paragraph.
- **Remove pauses** opens the pauses tool.
- Track labels open that track's settings drawer underneath (Titles, Graphics, Filters, Transitions, Captions: *Paragraph / Whole text / Styles*). The *Music* label opens the music library.
- Hovering an empty stretch of a thin track offers: **+ Title**, **+ Graphics** (pick a review), **+ Video over the picture**, **+ Crop with keys**, **+ Captions from the voice** (only that stretch), **+ Overall filter**, **+ Filter for this clip**.

## Shots

- Cells show a thumbnail and name; flagged shots get a red dot, shots darkened under graphics a blue outline.
- Click selects and moves the playhead; **double-click** replaces the video (project videos or the footage library); **right-click** opens the shot window.
- **Drag to reorder** → *With the voice and captions* (its voice, sounds, captions, titles, scenes and filters move with it) or *Video only*.
- **Slip** (gold strip on top): show another moment of the clip; place, length and the shot's own sound follow.
- **Roll** (upper gold knob): move the cut between two shots. **Ripple** (lower white knob): this shot only, everything after slides; shortening keeps every word.
- Cut knob: **+** on the selected shot's cuts → *Clip* (insert up to 5 s, everything ripples) or *Transition*.
- **S** splits at the playhead (snapped to the beat; the second half gets the opposite push).
- **Shot window**:
  - *Clip*: start in the clip (±0.5 s), *Replace clip…*, *Split · S*, *Show in Finder*.
  - *Speed*: ×0.25…×4 (log slider, presets ×1/×1.5/×2/×3, exact value). The shot keeps its place and length, its sound follows with the pitch kept; slowed shots get **optical-flow in-between frames** (no repeated frames).
  - *Camera*: Push in / Pull out / None, *Mirror*, *Darken under graphics*, *Crop…*, *Cover text…*, *No crop*, *Remove covers*.
  - *Colour* (see [Colour](#colour)).
  - *What's wrong — Claude will see it*: Wrong face, Wardrobe · hair, Artifacts · morphing, Wrong framing, Eyeline, Lip sync, Voice · line, Background moves, Story unclear, Soft · low quality, Redo the shot, plus a note. Saved in the project for Claude.
  - *Library*: *Project videos…*, *Whole library…*, and three automatic suggestions from the footage index for what is said over the shot.
  - *Delete shot · ⌫* (ripple: its voice and captions go too) or *Delete the picture* (neighbours stretch over it, voice and length stay).

## Overlay videos, chroma key and transform

- The **Overlay** track holds videos over the picture: drag to move (snaps to cuts and beats), drag edges to trim, double-click to swap, ⌫ removes, drop a file from Finder to place it. **S** splits.
- Without settings a layer covers the picture while it plays; with a key or a transform it is composited over it, like Keyer + Transform on a connected clip in Final Cut.
- **Remove the background** (green / blue screen): colour swatch (auto or *Eyedropper*), *Strength*, *Spill*, *Edges*, *Soften*, **Show the matte** (viewer only).
- Size 10–100 %, rotation ±180° (catches upright), move X/Y in px, *Full frame*; or drag the video and its corner handle on the picture.

## Crop, crop keys and cover text


- **Crop** (on the paused picture): the whole source frame with the used part as a white box; drag to move, drag a corner or pinch to resize (up to 400 %), zoom slider, turn 90° left/right and ±45° fine turn, *No crop*, *Cancel* (Esc), *Done* (Return).
- **Key here**: keeps the box as a crop key; between keys the frame glides (push-in or pan). Keys sit on the Keys track: drag them in time, right-click to delete, drag the arc between two keys up or down to ease in or out.
- **Cover text**: paint over burned-in captions or logos. *Find text* (Vision finds the text on the shot and adds zones), *+ Zone*, move and resize zones, *Fill* (from the zone's edges, grain matched) or *Blur*, *Edge* softness.

## Colour


- **Per-shot colour** (shot window): on/off (off = the shot as filmed), *Brightness*, *Contrast*, *Saturation*, *Warmth*, *Tint*, *Match to scene*. Changes show live, without rebuilding the preview. Double-click a value to reset.
- **Match colour**: *Like the previous*, *Like the next*, *To the reference*, *Make the reference*.
- **Lipstick** (shot or filter): lips found on every frame from face landmarks, *strength*, *Lip edge softness*, *Lipstick colour*, *Keep off teeth*, *Half of the mouth* (whole / left / right for split-face before-after).
- **Filters tab**: the **Overall filter** for the whole video (*Contrast · curve*, *Saturation*, *Warmth*, *Tint*, *Teal shadows · warm highlights*, *Lifted blacks*, *Vignette*, *Grain*), **Motion blur · shutter** 0–360° (pixel motion blur, 180° = film) and **Blur across cuts** (whip-style smear into the next shot).
- **Filter clips** on the Filters track over a stretch of the edit: name, brightness, contrast, saturation, warmth, tint, lipstick. *Compare with original* toggles before/after.

## Transitions


- On any cut: **Dissolve, Through black, Flash, Whip, Zoom in, Zoom out, Through blur, Push**.
- *Length* 0.1–2 s; direction for Whip and Push; footage past the cut is used (or the edge frame is held). *Delete transition · ⌫*.

## Captions


- **Recognition** on the Mac, on the device: the language is set on the start screen; missing language files download by themselves. Words from the **glossary** are passed as hints and near-misses are corrected (the brand first).
- After recognition captions snap to the voice's real start and end, and blinks between them are closed.
- Words are grouped into captions by style family: one line (up to 3 words, split at punctuation) or two lines (one sentence). Paragraphs start after a sentence or a pause of 0.7 s, until you set one by hand.
- **Timeline**: click, ⇧-click range, ⌘-click add; drag a caption (neighbours give way and come back), trim its edges, drag word separators inside it (by frames).
- Right-click menu: *Join selected · M*, *Make one paragraph*, *Split before word ▸*, *Join with previous / next*, *Re-time to the words*, *Re-time all captions to the words*, *Start a paragraph here · ↩*, *Select paragraph*, *Delete · ⌫*.
- **Whole text** tab: the transcript as numbered paragraphs; the caption under the playhead is outlined; words grow under the pointer. Click a word for **word tools**: edit the word, *Accent*, *Break* (a new caption starts here), *Paragraph*, *Delete*, *Heard* (start/end ±1 frame), the caption's Start/End, *Join with previous / next*, *Extend to next*, *Delete caption*.
- **Paragraph** tab: the picked captions on a mini ruler with the voice waveform; drag words to move their start, drag the cell to slide the caption, Start/End fields.
- Retyping keeps the timing of unchanged words; a word typed as several shares its time; time fields accept 1:02.5, 62.5 and 62,5.
- **Re-time to the words**: words go back to where their voice is now (saved voice anchors, or recognition again).
- **Make captions from the sound** on a voice clip; **+ Captions from the voice** on a stretch.

## Caption styles


| Style | Look |
|---|---|
| s1 Gold Script | Montserrat 800 white; accents in Playfair Display Italic with a moving gold gradient |
| s2 Highlighter | Archivo Black capitals, white with a dark stroke; accents get a rose marker wipe |
| s3 Editorial | DM Sans 700 cream rising from its box; accents in DM Serif Display Italic, rose |
| s4 Handwritten Note | Poppins 700 sliding in; accents in Caveat, red with a hand-drawn underline |
| s5 Clean Box | Inter Tight 800 on white rounded cards; accents gold on a dark card |
| s6–s10 | the same five looks as a whole sentence on two balanced lines |
| s11 Plain / s12 Plain · 2 | Montserrat 800 white, thin outline, soft shadow; one or two lines |
| s13 Film / s14 Film Bold | Inter 48 px subtitles with Netflix-style line breaks |

- For the whole video: **ALL CAPS**, **Italic**, **Accent words** on/off, **Line spacing**, and for Plain styles **Comes in**: Pop, Word by word, Rise, Fade, Karaoke.
- Switching one-line ↔ two-line regroups words inside paragraphs; timing and accents stay.
- The native renderer is a rule-for-rule port of the web reference (`Reference/overlay_ref.html`): same fonts, layout, keyframes and shadow order.
- **Classic** (the app's earlier libass styles): presets PLATE, HORMOZI, BEAST, CLEAN, NEON, POSTER, RETRO, MONO, HIGHLIGHT, SOFT; 10 entrances and 10 exits with live previews; font, size, tracking, alignment, split (1 word / 2 words / 2 lines), colours for text, background, outline, shadow and glow, accent font, tilt and colour.

## Titles


| Style | Look |
|---|---|
| T1 Swipe & Blur | a waxy lipstick stroke swipes across; Playfair Italic headline lands with blur |
| T2 Lipstick Writes | the text is written by a lipstick stroke, the real tube riding the pen |
| T3 Smear Band | a tilted waxy band with white Archivo Black capitals |
| T4 Kiss Stamp | a lip print stamps in, Fraunces Italic headline rises |
| T5 Swatch Stack | nude, rose and berry swatches, letters drop in one by one |
| T6 Plain Text | white Montserrat capitals with a kicker line ("7 REASONS") |
| T7 Pill | black capitals on a white pill ("BUY 1 GET 1 FREE") |
| T8 Trustpilot Review | real Trustpilot card: photo, name, date, stars, text |
| T9 Review Collage | up to 4 cards fanned |
| T10 Review Slider | "Reviews shaping this summary" panel sliding card by card |
| T11 TikTok Text | black text on white plates, TikTok style |
| T12 Comment Reply | TikTok "Reply to …'s comment" bubble |
| T13 Comments | up to 8 TikTok comments dropping in and floating |

- Click a style to add a title at the playhead (or restyle the selected one). Settings window: text ("|" = new line), line underneath, start, duration, *Blur behind*, *Replace*, *Duplicate*, *Back in place*, *Delete*. A live rule check says whether it is fully visible for 2 s.
- **Animated emoji** on titles: packs Noto (fine for ads) or Telegram; *+ Emoji* picker with search and categories; size, turn, drag and rotate on the picture.

## Graphics, kit scenes and reviews


- **Review collage**, **Review slider**, **Comments** buttons add those graphics at the playhead.
- **Kit scenes** (folders of PNG frames from `RENDER_KIT/motion/frames`): click to place at the playhead; on the track drag to move, drag the right edge to change the length (it holds, then fades out); *Replace with…* swaps a scene for a sibling at the same time and place.
- **Glass** under a scene: the picture under it blurred, brighter and refracted at the edge, like frosted glass.
- **Trustpilot reviews** from `_ASSETS/TRUSTPILOT/reviews.json`: click to add a review card, or to swap or add reviews on the selected card, collage or slider. *Your own review* starts a blank card; *Save to library* adds it to reviews.json.

## Sound


- **Voice** and **Music** tracks with waveforms; music shows its dips under the voice.
- Drag a clip to move, drag edges to trim; **fade knobs** in the corners, drag the fade slope to bend it; **S** splits; ⌫ deletes; drop an audio file from Finder on the Music track.
- Pivot under each voice clip: hooked to its shot (moves with it) or free.
- **Sound window**: volume −45…+12 dB (*As recorded*, *Mute*); for voice *Make captions from the sound*; for music **Sidechain** (*Duck when the voice speaks*, how much lower, down/back times); *Another track…*.
- **Voice processing · every voice**: level to a LUFS target, compress (gentle / medium / firm, modelled on FabFilter Pro-C 2 "Pro Voice Over") and a true-peak limiter (like Pro-L 2).
- *What's wrong — Claude will see it*: Glitch · click, Word cut off, Wrong voice, Out of sync, Level, Pause too long, Record again, plus a note.
- The preview applies gain, fades, curves and ducking on every sample, so it sounds exactly like the export; level changes apply while playing.

## Music library


- Every track under `_ASSETS/MUSIC` (with subfolders): name, folder, length, waveform, loudness (LUFS) and where it is already used ("unused", "in VD 12, 17"); *Unused first*.
- Click to listen, double-click or **Put in** to swap: place, length, fades and ducking stay, the gain is matched so it plays as loud as before. One undo step.
- No music yet: the track goes over the whole edit at the house level and fades out.
- Tempo and bars are found in the music itself; the beat grid drives Snap.

## Footage: project videos and the footage library


- **Project videos**: the project's video folder by subfolder, newest first, hover to play, *Add videos…*, *Connect a folder…*, search; *Put into the shot*, *Lay over the picture*, *Put onto the cut*. For our AI generations it also shows the prompt and the model.
- **Footage library** (the `_ASSETS/_index`): every usable moment by category — Applying it, Tube to camera, Lips close-up, Smile, Talking to camera, Dry lips, Other lipsticks, Product alone, B-roll; filters Ambassadors / AI / Stock & product; sort Best / Newest / Oldest; search. Starts in the category that fits what is said over the shot.
- *Hide from the library* (pink tip / bad shot / not our product) removes a moment for good. Moments with burned-in text, "avoid" and the pink tip are left out of the gallery and the suggestions.

## Checks before export


The **Checks** button (and **Export**, which runs them first) lists, with **Fix** per row, **Fix all** per group and overall:

- overlapping captions; recogniser repeats; spelling (glossary); text shrunk to fit; captions off the voice; flicker at a cut (1–3 frames); flicker between captions (gap under 0.3 s); too fast to read (under 0.3 s, or over 25 letters/s); titles under 2 s; a cut inside a shot (the source clip jumps to another picture); missing files.
- Export offers *Export as it is* or *Fix all, then export*.

## Text tools

- **Find and replace** (whole words, word timing kept), **Glossary** (words always spelt one way; used by recognition and the spelling check), **Remove pauses** (longer than 0.25–1.5 s; the speaker's picture and voice are jump-cut with 20 ms fades, the rest moves up, music plays on).

## Export

- **Export** (⌘E): the native engine renders exactly what the preview shows — H.264 High 10 Mbps, BT.709 — then ffmpeg normalises the sound to **−14 LUFS**, true peak −1.5 dBTP, AAC 192k.
- A missing file stops the export with the list of files.
- **Save SRT** (⌘S), **Import SRT** (⇧⌘I). A plain video with classic captions only is burned in with ffmpeg/libass.

## Project file and live sync with Claude

- The whole edit is one JSON `.simbia` file (shots, layers, sound, overlays, captions, titles, filters, transitions, brief, tasks, status). Double-click opens it in the app.
- **Live two-way sync**: your edits are saved 0.3 s after you stop; a change made on disk (by Claude) loads in place as one undo step — ⌘Z returns to your version. The app never writes over a file changed elsewhere since it last read it.
- Every save raises `revision` and records who saved (`app` / `claude`); the shared **edit journal** (`_journal.jsonl`) says in plain words what each of you changed.
- A transcribed video without a project becomes one in Application Support and continues next time.
- **MCP server** (`simbia mcp`, found by Claude Code through the workspace's `.mcp.json`): workspace_info, list/read/save/create_project, check/fix_project, frames, export_project, journal, suggest_footage, words, captions_from_voice. Its built-in instructions give Claude the order of work.

## Command line: `bin/simbia`

The engine without the window, for Claude and scripts. Every command that saves raises `revision` and sets `savedBy: "claude"`.

| Command | What it does |
|---|---|
| `check <project>` | summary and everything that would render wrongly; `~` lines are worth fixing |
| `fix <project> [kind …]` | fix all (or the named) check kinds and save |
| `pauses <project> [s] [--apply]` | pauses in the voice; `--apply` cuts them |
| `suggest <project> <shot #>` | library moments for what is said over a shot (shots from 0) |
| `cuts <video> [from to]` | hard cuts inside a clip |
| `tempo <audio or project>` | bpm and first downbeat |
| `covers <project> <shot #> [--apply]` | burned-in text zones (shots from 1) |
| `words <media> [from to] [--locale] [--hint] [--json]` | Mac speech recognition, word by word |
| `frame <project> <t,…> <prefix> [--no-overlay]` | composed frames as PNG |
| `overlay <project> <t,…> <prefix> [--style sN] [--no-titles]` | captions and titles only, transparent PNG |
| `export <project> <out.mp4>` | the finished video |
| `audio <project> <out.wav>` | the mix before loudness |
| `restyle <project> <sN>` | caption style for the whole video |
| `captions <project> [--clip id] [--style sN] [--script file] [--locale]` | captions from the voice clips, saved and journalled; `--script`: exactly those words, timed by the voice (missing words listed) |
| `voice <project>` | loudness of every voice clip before and after the voice chain |
| `colourmatch <project> <shot id> <ref id> [--apply]` | grade a shot like the reference |
| `play`, `playtap`, `bench`, `shadowtest`, `blurtest` | preview and calibration diagnostics |

## Keyboard shortcuts

Single keys work by key position (also in the Russian layout) and are ignored while typing.

| Key | Action |
|---|---|
| Space | play / pause |
| ← / → | one frame |
| J / K / L | shuttle back / stop / forward (1×, 2×, 4×) |
| S | split at the playhead (caption, shot or sound clip) |
| M | join captions |
| ↩ | start or join a paragraph |
| ⌫ | delete what is selected |
| Esc | close a full-window screen, fold the drawer, collapse the selection |
| ⌘A | select all captions |
| ⌘O / ⇧⌘O | open video / open project |
| ⌘S / ⇧⌘S | save SRT / save project as |
| ⇧⌘I | import SRT |
| ⌘E | export video |
| ⌘Z / ⇧⌘Z | undo / redo |
| ⇧⌘A | align all titles to the selected one |

## Languages

The interface is in **English, Russian and French**: menu **Language** → English / Русский / Français. The first launch follows the system language; the choice is remembered. The speech-recognition language is separate (start screen, *Speech: …*).

The project journal is written in Russian (it is data shared with Claude, not interface text).
