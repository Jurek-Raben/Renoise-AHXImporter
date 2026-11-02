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
  - `note_usage.lua` – the notes each instrument is triggered with (one phrase per note) and its 9xx note/offset
    variants.
- `importer/` – everything that touches the Renoise API:
  - `controller.lua` – workflow: parse → `ui/options_dialog.lua` → `song_creator.lua` (new song without template) →
    `process_slicer.lua` (sliced build with progress dialog, ported from SongMerger) → summary.
  - `preferences.lua` – import options (interpolation, bit depth, sample rate, rendering, filter resonance, pattern
    resolution, PWM crossfade) in the tool's `preferences.xml`.
  - `ui/widgets.lua` – shared dialog look (ported from SongMerger), `ui/options_dialog.lua` – import options.
  - `song_setup.lua` – four sequencer tracks (LRRL panning), no send/group tracks, Maximizer on the master, one
    instrument, one sequence slot.
  - `instrument_writer.lua` (simulation → samples + phrase), `sample_writer.lua`, `phrase_writer.lua`,
    `pattern_writer.lua`.
  - `filter_writer.lua` – modulation set with filter + cutoff envelope per sample (failures reported, sample stays
    unfiltered).
  - `release_writer.lua` – volume AHDSR (full level until note-off, then release) for the hard cut release or the
    PWM crossfade; failures are reported, not fatal, and the device is removed again. Modulation device parameters are
    set via `device.parameters` by name: the typed fields (`amount`, …) do not exist at runtime in Renoise 3.5.4
    (LFO names: Frequency, Amplitude, Dephase, Delay; values accept strings in Hz / ms).
  - `util.lua` – tool name, console logging, dialog close watcher, device parameter lookup by name.
- `main.lua` – menu entry and file import hook.

## Product decisions

- **Filters: automatic hybrid per instrument.**
  - PWM (square positions) is always baked: one sample per used pulse width.
  - Renoise-filter path (`ahx/filter_path.lua`, `importer/filter_writer.lua`): when all simulated filter positions
    stay on one side (low-pass 1..32 or high-pass 32..63, 32 = open) and nothing else changes the sample during a
    note (waveform, pulse width, performance portamento), the samples are unfiltered and every phrase gets a sample of
    its own with its own modulation set: low-/high-pass filter (`LP Clean` etc.), resonance from the import options (0..0.3, default 0.136), cutoff input at maximum and a
    cutoff envelope (operator multiply, points mode, one point per frame, loop = simulation loop). The cutoff per
    frame is the AHX filter's: fc = fs · asin(f / 2) / π with f = (8 + 3 · step) · 1.25 / 100 and fs = Paula rate of
    the frame's pitch. Hz are mapped to the normalized cutoff by probing the cutoff parameter's value strings.
    Reason: baked sweeps retrigger the sample on every filter step, which sounds rough (syphus - returns, AHX 01).
  - Otherwise (sweep crossing position 32, or sample changes anyway) the used filter positions are baked.
- Samples hold the waveform cycle repeated to 256 frames (the replayer uses 0x280) as a forward loop; interpolation
  and bit depth come from the import options. (Tried and reverted: upsampling short cycles for a finer 0Sxx phase;
  barely audible, did not fix rough PWM/filter steps.)
- Pitch: AHX note n (1..60, C-1..B-5) maps to Renoise note n + 11 (C-1 = 12). Samples use the NTSC Paula rate of
  AHX note C-3 (3579545.25 / 856 ≈ 4181.7 Hz) one octave up, i.e. 8363 Hz at base note C-4.
- An import always creates a new song (`new_song_no_template`, Renoise asks to save the current one). No empty
  instrument slots: AHX instrument n is Renoise instrument n, the song's default instrument is reused.
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
- A phrase must keep running to keep its volume: after a one-shot phrase ends, the sample plays on at the pattern
  volume (observed in Renoise: loud noise after the snare of pink - sometimes). Steady states therefore end with a
  note-off when silent, or become a two-line loop when audible.
- Instrument vibrato: pattern vibrato 0Vxy on every line after the vibrato delay until the next trigger (it starts
  on the first line whose middle lies behind the delay; a whole row at once was too early in thanatos).
  x = vibrato speed · song speed / (6 · lines per row) (Renoise's vibrato rate follows the lines; verified by ear:
  xeron - 64k is all you need at speed 3 / 1×, pink - thanatos remix at speed 16 / 2×), y = depth in 1/8 semitones at
  the current note; E4x supported. x above F is clamped and reported (that was why thanatos sounded too slow at 1×:
  x = 24). Rejected: an instrument LFO (restarts with every sample switch) and baking the vibrato into the phrase via
  fine tune samples (too many sample switches).
- Every phrase note line (also 0GFF glides) carries its volume: a note with an empty volume column plays at full
  volume, so the envelope would be lost on every retrigger or glide.
- Hard cut (instrument hard cut frames): like the replayer, the note ends that many frames before the next row of
  the channel that triggers an instrument (look-ahead into the next position of the list, regardless of jumps), as a
  note-off with delay; not possible on a row with its own note. With the instrument's release flag a volume AHDSR
  releases over the hard cut frames, otherwise the note-off cuts.
- All samples use new note action "note cut": every sample switch of a phrase is a new note, and the old one must stop
  at once (with "note off", the AHDSR release let old notes fade underneath and modulated the volume; verified).
- 9xx square offset (only used on trigger rows): each used note/offset pair gets an unmapped variant phrase
  (simulated with that start square position, the next performance list 3xx is ignored once, like the replayer),
  selected with 0Zxx on the trigger row. Max 126 phrases per instrument.
- Not converted yet (reported in the scripting console): E1x/E2x fine slides (pattern level), 9xx without trigger.
- Instruments get a default volume of -6 dB (four full-scale voices clip otherwise). The master gets a Renoise
  Maximizer with threshold -0.5 dB.
- Every import starts with the options dialog: sample interpolation (none / linear / cubic / sinc, default none) and
  sample resolution (8 / 16 / 32 bit, default 8) and sample rate (8363 / 16726 / 33452 Hz = 1× / 2× / 4×, default
  1×; higher rates repeat every frame, so waveform, pitch and 0Sxx offsets stay the same).
  Rendering Original / Smoothed / Band-limited (default Smoothed, by ear): Original repeats every frame (sample and
  hold, like Paula); Smoothed interpolates between the frames (Catmull-Rom, wrapping around the loop); Band-limited
  (`ahx/band_limit.lua`) resynthesizes each cycle from its harmonics below 18 kHz at the highest pitch the sample is
  played at (Lanczos sigma against ringing only when harmonics are cut, DC kept), one sample per octave of the played notes (one per sample when
  that exceeds 255 samples; noise stays smoothed). Smoothed and band-limited render at least at 4×. Rejected for now: an Amiga output filter emulation (A500 RC / LED filter).
  Filter resonance slider 0..0.3 (default 0.136) for the Renoise-filter path.
  PWM crossfade slider 0..20 ms (0 = off, default 10 ms by ear): a volume AHDSR with attack = release = the crossfade time and new
  note action "note off", so every sample switch of a phrase crossfades (against the ring-modulation-like roughness of
  PWM). Only for instruments whose phrases switch samples, not for instruments with hard cut release (they keep
  "note cut"; reported). The note start must not fade in: the sample of each phrase's first line is a copy
  ("(start)") with modulation set "Note start" (copy of set 1 without attack).
  Pattern resolution Auto / 1× / 2× / 4× pattern lines per AHX row (default Auto = the smallest resolution at which
  no vibrato needs 0Vxy speed above F, `ahx/resolution.lua`): LPB × factor, TPL / factor (a tick stays
  a frame when the speed is divisible, otherwise approximated and reported), note delay / note cut / hard cut go to
  the sub line of their frame, 0Vxy is repeated on every line; reduced when a pattern would exceed 512 lines.
  Observed: the 0Vxy rate follows the line rate (rate ∝ x · lines per second); x is clamped at F. The dialog starts with the saved options; Import uses the current
  choice, Save stores it (while the choice equals the saved options, the Save button shows "✔ Save" (bold) and is disabled).
- Volume: the phrase's volume column carries envelope · performance volume (0..64 → 0..0x80) and overwrites the
  pattern's note volume on every phrase note line. The AHX note volume (instrument volume, Cxx, EAx/EBx, volume
  slides A/5) therefore goes into the channel volume 0Mxx (0..64 → 0..0xFF): written on every trigger (AHX resets it)
  and whenever it changes; slides are applied per row (value after the row's first frame). Sample volume stays 1.
  The channel volume also includes the voice master volume (C50..C90 all voices, CA0..CE0 one voice; used e.g. for
  echo voices in syphus - returns).
- Note cut ECx: a volume cut (0Cxy) does not last because the phrase rewrites the note volume, so a row without note
  gets a note-off with delay (x frames); only with a note on the same row 0Cxy is used.
- Keyzones keep "Vel->Vol" enabled: extra samples use velocity range 0..0, which is then never triggered.
- Pitch slides (1xx/2xx/3xx/5xx): AHX period steps per frame are converted to semitones at the current note;
  Renoise 0U/0D slide by xx/32 semitones per tick, 0G glides by xx/64 semitones per tick (both verified by ear).
- A note without instrument changes the pitch without retrigger (0GFF); an instrument without note retriggers at the
  current pitch.
