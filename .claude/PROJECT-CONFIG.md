# Project Config – AHXImporter

Renoise tool (Lua) that imports AHX/THX songs (Amiga chiptune format by Dexter/Abyss, revisions THX0/THX1) into
Renoise: waveforms become samples, instrument modulation becomes instrument phrases, tracks and the position list
become patterns and the pattern sequence.

## Environment

- Target host: **Renoise 3.5.4**, Lua API version **6.2** (`renoise.API_VERSION`).
- Language: **Lua 5.1 (LuaJIT)** as embedded in Renoise. No external runtimes (Node, Python, …) may be required at
  runtime. The tool must work on macOS, Windows and Linux.
- Tool bundle: `ai.claude.AHXImporter.xrnx/` (symlinked into the Renoise tools folder by the user). Renoise expects
  tool folders to end in `.xrnx`; the tool id in `manifest.xml` is `ai.claude.AHXImporter`.
  - `manifest.xml` – tool metadata (`<ApiVersion>6.2</ApiVersion>`, id `ai.claude.AHXImporter`).
  - `main.lua` – entry point (menu entries, file import hook, tool lifecycle).
  - Further modules live in subfolders and are loaded with `require`.
- Test songs: `testdata/*.ahx` (read-only input; never modify these files).

## API reference

- Online: https://renoise.github.io/xrnx/API/index.html
- Local LuaCATS definitions (authoritative for autocompletion and signatures):
  `~/Workdocs/renoise/definitions/library/renoise/`.
- Before using an API function or property, verify it exists in the definitions. Do not invent API calls.
- Mark every assumption about undocumented behavior (e.g. how the instrument column in phrases selects samples, which
  sample rates `create_sample_data` accepts) with a `-- ASSUMPTION:` comment so it can be verified in Renoise.

## Reference implementation

- The AHX replayer to port lives in the mixstation-chiptunes project:
  `~/Workdocs/webdev/cracktros/mixstation-chiptunes/shared/tracker-pack/ahx/ahxEngine.ts`
  (TypeScript, based on bryc's JS port of the original AHX replayer by Dexter/Abyss).
- Treat it as read-only. Never edit files in that project.
- Port behavior faithfully (integer arithmetic, shifts, clamping, revision-dependent commands). Where the port must
  deviate, comment why. Live-manipulation additions of that engine (cutoff factor, pitch-down low-pass, speed factor,
  seeking, length probe) are not needed.
- Lua is 1-based, the replayer is 0-based: keep AHX data 0-based inside the parser/simulator tables where it mirrors
  the original (document it), and convert at the Renoise boundary.

## Working rules for Claude

- **Never** run `git commit`, `git push`, `git add`, `git reset`, `git checkout`, `git switch`, `git restore`,
  `git rebase`, `git merge`, `git stash`, `git tag` or any other git command that changes repository state. The user
  does all version control. Read-only git commands (`git status`, `git diff`, `git log`) are fine.
- **Never** start Renoise or test the tool on your own. The user tests. When a change needs testing, describe briefly
  what to test and what to look for.
- Static checks never execute tool code and are allowed after code changes: run `sh scripts/check.sh` (LuaJIT syntax
  check + luacheck with `.luacheckrc`, luacheck runs under LuaJIT because the Homebrew build for Lua 5.5 does not
  start). Running the parser or other tool modules on the test songs counts as testing and needs the user's OK.
- Development-only code is wrapped in `-- @build:skip-start` / `-- @build:skip-end` lines. The release workflow
  (`.github/workflows/build-xrnx.yml`, on every push to `main` or manually) removes these blocks, runs a LuaJIT syntax
  check, zips the contents of the tool folder (without `preferences.xml` and `.DS_Store`) as
  `<id>_v<version>.xrnx` and publishes it as a GitHub release `v<version>` (version from `manifest.xml`; the same
  version replaces the package of the existing release). Raise `<Version>` in `manifest.xml` for a new release.
- All rules, documentation in this repo and code comments are written in **English**.
- Code follows [CODE-FORMATTING.md](CODE-FORMATTING.md).
- Keep the tool free of global state leaks: one module table per file, `local` everywhere.
- Song objects (`renoise.song()` and everything derived from it) become invalid when another song is loaded. Never keep
  references to song objects across song loads.
- Long-running work (wave generation, sample creation, pattern writing) must run sliced over idle calls with a progress
  dialog so Renoise stays responsive.
- Keep the AHX side (parser, wave generator, frame simulator) free of any `renoise.*` access so it stays testable in
  plain LuaJIT. Only the importer/writer modules talk to the Renoise API.

## Architecture

- `ahx/` – pure Lua, no Renoise API:
  - `parser.lua` – port of `AHXSong.parse` (header, subsongs, position list, tracks, instruments, performance lists).
  - `waves.lua` – port of `AHXWaves`: base waveforms (filter set 31) plus the 31 low-pass (0..30) and 31 high-pass
    (32..62) filter sets, generated lazily per set. Also builds the 0x280-frame voice buffer of a waveform state
    (like `SetAudio`).
  - `noise_data.lua` – the static white-noise table of the original replayer (generated from the TS source).
  - `tables.lua` – period table, vibrato table, Paula clock.
  - `sequence.lua` – flattens position list + jumps/breaks (0, B, D, F00) into segments (position, first/last row);
    detects the loop point.
  - `pattern_converter.lua` – converts the steps of a segment into neutral cell data (Renoise values) with
    per-channel state; collects commands that are not converted yet.
  - `timing.lua` – timing plan: constant BPM + phrase LPB for the whole song, LPB/TPL per AHX speed.
  - `simulator.lua` – port of the instrument part of `ProcessFrame` / `PListCommandParse` without audio: one record
    per frame from note-on (waveform state, performance note, performance portamento, envelope volume) plus the loop
    found by comparing the complete voice state. Max 512 frames (phrase limit).
  - `wave_states.lua` – distinct waveform states of a simulation (= samples, max 255 because the phrase instrument
    column addresses 00..FE; the filter resolution is coarsened when needed).
  - `phrase_builder.lua` – neutral phrase data from a simulation for one triggered note: one line per frame, only
    changes written, phase-continuous sample offsets.
  - `filter_path.lua` – Renoise-filter path decision and AHX cutoff per frame.
  - `resolution.lua` – automatic pattern resolution and the 0Vxy vibrato speed.
  - `band_limit.lua` – band-limited resynthesis of a waveform cycle.
  - `note_usage.lua` – the notes each instrument is triggered with (one phrase per note) and its variants (9xx
    square offset and/or baked pitch slide), from the triggers the pattern converter records in play order.
  - `instrument_slots.lua` – instrument layout: grouped by track behind separators, one instance per track, unused
    instruments last.
  - `portamento.lua` – port of the track portamento (1xx/2xx/3xx/5xx/E1x/E2x, `PeriodSlide*`).
- `importer/` – everything that touches the Renoise API:
  - `controller.lua` – workflow: parse → `ui/options_dialog.lua` → `song_creator.lua` (new song without template) →
    `process_slicer.lua` (sliced build with progress dialog, ported from SongMerger) → summary.
  - `preferences.lua` – import options (interpolation, oversample, bit depth, sample rate, rendering, band-limit roll-off, filter
    resonance, pattern resolution, PWM crossfade) in the tool's `preferences.xml`.
  - `ui/widgets.lua` – shared dialog look (ported from SongMerger), `ui/options_dialog.lua` – import options.
  - `song_setup.lua` – four sequencer tracks (LRRL panning), no send/group tracks, Maximizer on the master, one
    instrument, one sequence slot.
  - `instrument_writer.lua` (simulation → samples + phrase; the instrument slot is loaded from a template first),
    `sample_writer.lua`, `phrase_writer.lua`, `pattern_writer.lua`.
  - `xrni_writer.lua` – instrument template (.xrni = uncompressed ZIP with `Instrument.xml`, written in Lua) with
    macros mapped to inputs of all its modulation sets, loaded with `renoise.app():load_instrument` (the API cannot
    create macro mappings); `modulation_sets.lua` – hands out the template's sets to the writers, removes unused ones.
  - `macro_writer.lua` – *Instr. Macros device per track and instrument, lines-mode automation of the volume and
    cutoff macros.
  - `macro_prototype.lua` – development only (`@build:skip`): menu Tools › AHX Importer › Macro Prototype.
  - `filter_writer.lua` – low-/high-pass filter and resonance in every modulation set, Hz → cutoff macro value by
    probing the cutoff input (failures reported, instrument stays unfiltered).
  - `release_writer.lua` – volume AHDSR for the PWM crossfade; failures are reported, not fatal, and the device is removed again. Modulation device parameters are
    set via `device.parameters` by name: the typed fields (`amount`, …) do not exist at runtime in Renoise 3.5.4
    (LFO names: Frequency, Amplitude, Dephase, Delay; values accept strings in Hz / ms).
  - `util.lua` – tool name, console logging, dialog close watcher, device parameter lookup by name.
- `main.lua` – menu entry and file import hook.

## Product decisions

- **Filters: automatic hybrid per instrument.**
  - PWM (square positions) is always baked: one sample per used pulse width.
  - Renoise-filter path (`ahx/filter_path.lua`, `importer/filter_writer.lua`): when all simulated filter positions
    stay on one side (low-pass 1..32 or high-pass 32..63, 32 = open), the samples are unfiltered (shared by all
    phrases) and every modulation set gets the low-/high-pass filter (`LP Clean` etc.) with the resonance from the
    import options (0..0.3, default 0.136). The template's macro 2 "Cutoff" is mapped (linear 0..1) to the cutoff
    input (mixer parameter 4, checked by name after loading) of all sets, and the pattern converter writes the cutoff
    of every frame as its automation (lines mode, like the volume; open filter = 1 for low-pass, 0 for high-pass).
    The cutoff per frame is the AHX filter's: fc = fs · asin(f / 2) / π with f = (8 + 3 · step) · 1.25 / 100 and
    fs = Paula rate of the frame's period (performance note + track note with transpose, performance and track
    portamento). Hz are mapped to the macro value by probing the cutoff input's value strings.
    Reason: baked sweeps retrigger the sample on every filter step, which sounds rough (syphus - returns, AHX 01).
    The automation does not restart with sample switches, so (unlike the former cutoff envelope per sample, max
    1 s) waveform / pulse width changes and slides no longer exclude an instrument from this path.
  - Otherwise (sweep crossing position 32) the used filter positions are baked.
- Samples hold the waveform cycle repeated to 256 frames (the replayer uses 0x280) as a forward loop; interpolation
  and bit depth come from the import options. (Tried and reverted: upsampling short cycles for a finer 0Sxx phase;
  barely audible, did not fix rough PWM/filter steps.)
- Pitch: AHX note n (1..60, C-1..B-5) maps to Renoise note n + 11 (C-1 = 12). Samples use the NTSC Paula rate of
  AHX note C-3 (3579545.25 / 856 ≈ 4181.7 Hz) one octave up, i.e. 8363 Hz at base note C-4.
- An import always creates a new song (`new_song_no_template`, Renoise asks to save the current one). The song name
  is the AHX song name (trimmed; the file name without extension when empty), set at the start and again at the end
  of the build. The progress dialog says 'Importing "<file name>"...'. Instrument
  layout (`ahx/instrument_slots.lua`): grouped by track, each group behind an empty separator instrument
  "---- AHX n ----", the instruments of a track in the order of their first use (pre-pass), then a group
  "---- unused ----" with the instruments the song never plays. Every track plays its own instances (the macros
  belong to the instrument): the first instance of an AHX instrument is built, the others are `instrument:copy_from`
  copies with the same name (phrases, 0Zxx indices and macro mappings stay). The instrument names keep the AHX
  number ("AHX 03 …"). More than 255 instruments stop the import with an error (no fallback). The *Instr. Macros
  devices of a track are created before the patterns, in the order of the track's instruments, and carry the
  instrument's name. The song's default instrument is reused.
- Each sequence segment becomes one pattern (lines = played rows); identical patterns are reused in the sequence.
  The sequence loop range is set to the song's loop point.
- Timing: one phrase line = one AHX frame, one pattern line = one AHX row, one tick = one frame. A phrase's line rate
  depends only on the BPM, so the BPM is constant for the whole song: phrase LPB = 3000 · speed multiplier / BPM
  (a multiple of all used speeds, preferably 24 → 125 BPM), song LPB = phrase LPB / speed, TPL = speed. Speed changes
  become ZL/ZK commands. A speed command applies to the frame timing of all four channels of its row (the replayer
  runs all steps of a row before its frames), so the converter sets the row speed before converting the channels.
- Instruments are played by phrases: **one phrase per triggered note** (keymapped to exactly that key, key tracking
  off, absolute pitches). The phrase instrument column selects the sample (waveform state) per frame, the note column
  carries the pitch (fixed notes exact), the volume column the envelope · performance volume. Pitch-only changes use
  0GFF instead of a retrigger.
- Fine pitch: the phrase pitch is computed exactly from the AHX period (performance note + performance portamento,
  including the tuning of the period table) as a fractional Renoise note. The note column takes the semitone, the
  rest is a sample fine tune: each sample is a waveform state × fine tune pair (1/16 semitone, `sample.fine_tune` with
  128 steps per semitone), coarsened (8, 4, 2, 1) when the pairs exceed 255 samples. A fine tune change is a sample
  switch (retrigger with phase-continuous 0Sxx).
  Pitch jumps of at least half a semitone with an unchanged waveform state (arpeggios) keep the playing sample: only
  the note changes (0GFF) and the fine tune of that sample stays (a few cents off), until the waveform state changes
  or the pitch moves in small steps again. Otherwise every arpeggio step was a sample switch, which the PWM crossfade
  smeared (xeron - 64k is all you need, AHX 1 / instrument 02).
- Phase continuity: AHX keeps the playback position when the waveform changes, Renoise restarts a triggered sample.
  The phrase builder follows the playback position (from each frame's pitch) and starts switched samples with 0Sxx
  at that position. Cycle samples are therefore 256 frames (a whole number of cycles for every wave length, 0Sxx
  addresses each frame). Loops longer than one frame are unrolled up to 512 lines so the phase stays right; only the
  repeats of the last loop pass can drift. This is why phrases are per note: the position depends on the pitch.
- A phrase ends at a steady state (one-frame simulation loop, after a baked slide is over): the sample plays on and
  the volume comes from the automation. (Before the volume automation, a phrase had to keep running to keep its
  volume: loud noise after the snare of pink - sometimes.)
- Instrument vibrato: pattern vibrato 0Vxy on every line after the vibrato delay until the next trigger (it starts
  on the first line whose middle lies behind the delay; a whole row at once was too early in thanatos).
  x = vibrato speed · song speed / (6 · lines per row) (Renoise's vibrato rate follows the lines; verified by ear:
  xeron - 64k is all you need at speed 3 / 1×, pink - thanatos remix at speed 16 / 2×), y = depth in 1/8 semitones at
  the current note; E4x supported. x above F is clamped and reported (that was why thanatos sounded too slow at 1×:
  x = 24). Rejected: an instrument LFO (restarts with every sample switch) and baking the vibrato into the phrase via
  fine tune samples (too many sample switches).
- Volume: every instrument is loaded from a template (`importer/xrni_writer.lua`) whose macro 1 "Volume" is mapped
  (linear 0..1) to the volume input (mixer device 0, parameter 1; verified with the prototype) of all modulation sets
  (set 1 + note start set + one per sample on the filter path; unused ones removed, missing mappings reported); every
  sample uses a set. The pattern converter computes the AHX output volume per frame and channel
  (`PatternConverter:advance_volume`): envelope · performance volume (instrument simulation, restarted by an
  instrument, not by a note without instrument) · note volume (instrument volume, Cxx, EAx/EBx, slides A/5 per
  frame) · voice master volume (C50..C90 all voices, CA0..CE0 one voice), with the step's changes in the step's frame
  (note delay). Note cut ECx and hard cut (that many frames before the next row of the channel that triggers an
  instrument, look-ahead into the next position regardless of jumps) set the note volume to 0; with the instrument's
  release flag the hard cut releases the envelope to the release volume over the rest of the row, like the
  replayer. The value (output / 64) is written as lines-mode automation of the volume parameter of an *Instr.
  Macros device per track and instrument (`importer/macro_writer.lua`; a new device links to the selected
  instrument, its parameters are named like the macros); a change after a constant stretch gets a point on the
  previous frame too, so the line only ramps between neighboring frames; every pattern gets a point on line 1 for
  the playing instrument and every instrument it sets. Phrases have no volume column, the pattern has no 0Mxx and no
  note-offs. The volume macro belongs to the instrument, so every track plays its own instances (see the instrument
  layout; before, two tracks fought over one macro and the PWM sounded chopped: syphus - galactic olympics).
- All samples use new note action "note cut": every sample switch of a phrase is a new note, and the old one must stop
  at once (with "note off", the AHDSR release let old notes fade underneath and modulated the volume; verified).
- Variant phrases: a trigger with a 9xx square offset and/or a pitch slide after it gets an unmapped variant phrase,
  selected with 0Zxx on the trigger row (one per distinct note / offset / slide; key = `NoteUsage.variant_key`).
  9xx: simulated with that start square position (the next performance list 3xx is ignored once, like the replayer;
  only used on trigger rows). Max 126 phrases per instrument: the most used variants are kept, the notes of dropped
  ones get a plain phrase (reported).
- Not converted yet (reported in the scripting console): 9xx without trigger.
- Instruments get a default volume of -6 dB (four full-scale voices clip otherwise). The master gets a Renoise
  Maximizer with threshold -0.5 dB.
- Every import starts with the options dialog: sample interpolation (none / linear / cubic / sinc, default none),
  the sample option "Oversample" (checkbox, default on) and
  sample resolution (8 / 16 / 32 bit, default 8) and sample rate (8363 / 16726 / 33452 Hz = 1× / 2× / 4×, default
  4×; higher rates repeat every frame, so waveform, pitch and 0Sxx offsets stay the same).
  Rendering Original / Smoothed / Band-limited (default Smoothed, by ear): Original repeats every frame (sample and
  hold, like Paula); Smoothed interpolates between the frames (Catmull-Rom, wrapping around the loop); Band-limited
  (`ahx/band_limit.lua`) resynthesizes each cycle from its harmonics below 18 kHz at the highest pitch the sample is
  played at, with a raised-cosine roll-off over the top harmonics (option "Roll-off" 0..100 %, default 50 %;
  a hard cut rang like a steep resonant filter), DC kept, one sample per octave of the played notes (one per sample when
  that exceeds 255 samples; noise stays smoothed). Smoothed and band-limited render at least at 4×. Rejected for now: an Amiga output filter emulation (A500 RC / LED filter).
  Filter resonance slider 0..0.3 (default 0.136) for the Renoise-filter path.
  PWM crossfade slider 0..20 ms (0 = off, default 10 ms by ear): a volume AHDSR with attack = release = the crossfade time and new
  note action "note off", so every sample switch of a phrase crossfades (against the ring-modulation-like roughness of
  PWM). Only for instruments whose phrases switch samples. The note start must not fade in: the sample of each phrase's first line is a copy
  ("(start)") with modulation set "Note start" (copy of set 1 without attack).
  Pattern resolution Auto / 1× / 2× / 4× pattern lines per AHX row (default Auto = the smallest resolution at which
  no vibrato needs 0Vxy speed above F, `ahx/resolution.lua`): LPB × factor, TPL / factor (a tick stays
  a frame when the speed is divisible, otherwise approximated and reported), a note delay goes to the sub line of
  its frame, 0Vxy is repeated on every line; reduced when a pattern would exceed 512 lines.
  Observed: the 0Vxy rate follows the line rate (rate ∝ x · lines per second); x is clamped at F. The dialog starts with the saved options; Import uses the current
  choice, Save stores it (while the choice equals the saved options, the Save button shows "✔ Save" (bold) and is disabled).
- Keyzones keep "Vel->Vol" enabled: extra samples use velocity range 0..0, which is then never triggered.
- Pitch slides (1xx/2xx/3xx/5xx/E1x/E2x) are baked into variant phrases. Pattern slides (0U/0D/0G) and an automated
  instrument pitchbend (tried: *Instr. MIDI Control, pitchbend macro mapped via a generated .xrni) change the pitch
  behind the phrase's back, so every sample switch (PWM) starts at the wrong 0Sxx phase (stuttering slide, mobby -
  good day, AHX 1 / instrument 02). The pattern converter runs the replayer's portamento per frame
  (`ahx/portamento.lua`; reset by an instrument, kept by a note without instrument; the step's part runs after a note
  delay) and records for every trigger the slide period per frame until the channel's next trigger
  (`PatternConverter.scan_triggers`, a pre-pass over the sequence; triggers are identified by segment index, row and
  channel). The phrase adds it to the period of every frame except fixed performance notes (exact pitch, fine tune
  samples, correct phase); an audible steady state is repeated until the slide is over before it loops. Instruments
  with slides do not use the Renoise-filter path. A tone portamento note does not trigger (like the replayer); with
  an instrument on the row, it retriggers at the current note.
- A note without instrument is retriggered with the channel's current instrument (AHX only changes the pitch; a 0GFF
  glide fought with the absolute phrase pitches and sounded distorted with PWM, syphus - galactic olympics); the note
  volume and the running vibrato stay. Those notes get phrases too (`NoteUsage`). An instrument without note
  retriggers at the current pitch.
