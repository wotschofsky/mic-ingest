# Architecture

One app target, no layers of protocols. Each folder under `MicIngest/` is one concern:

| Folder | Contents |
|---|---|
| `Source/` | `DJIFilename` (name parsing), `SourceScanner` (discovery + header inspection), `SourceModel` (volume watching, grouping overrides, selection) |
| `Sessions/` | `SessionGrouper`, `RecordingSession` |
| `Audio/` | `AudioInspector` (format, exact frame count), `AudioMerger` (lossless merge + verification, upload rendition) |
| `Import/` | `ImportPipeline` (stages), `ImportCoordinator` (queue, progress, library list), `LibraryFolder` (layout, people file, restore), `SessionFiles` (naming, collisions), `SessionStore` (library files ↔ database) |
| `Services/` | `AssemblyAIClient`, `GroqClient`, shared error mapping. The only code that touches the network |
| `Identity/` | `SpeakerEmbedder` (Core ML), `VoiceMatcher`, `SpeakerNameInference` (Groq prompt, schema, validation, reconciliation), `IdentityResolver`, `IdentityService`, `PeopleModel` |
| `Transcript/` | `Transcript` (view of the raw response), `SessionMetadata` (sidecar schema), `SessionTimeline`, `MarkdownRenderer` |
| `Persistence/` | `AppDatabase` (GRDB/SQLite), `KeychainStore` |
| `UI/` | SwiftUI views and their two view models (`TranscriptModel`, `PlayerModel`) |
| `App/` | `AppConfig` (names, model IDs, tunables), `AppSettings` (UserDefaults), `AppEnvironment` (wiring) |

Blocking work (merging, hashing, Core ML) runs off the main actor; view models are `@MainActor @Observable`.

## Session grouping

`SessionGrouper` works per transmitter and file rendition, on recordings sorted by the timestamp in
the filename. For each consecutive pair:

```
expectedNextStart = previous.start + previous.actualDuration        (duration from the audio header)

|next.start − expectedNextStart| ≤ 2 s  and  previous.duration ≥ 30 min − 15 s   → same session
|next.start − expectedNextStart| ≤ 2 s  but  previous was shorter                → separate, flagged
otherwise                                                                        → separate
```

"Flagged" sessions show "Starts right after the previous recording" with a one-click **Merge**:
stopping and immediately restarting is usually a new session, but not always.

Checked against a real DJI mic charging case (100 files, two transmitters): full chunks are exactly
1800.15 s of 48 kHz / 24-bit mono, and the next chunk's name is stamped 0.15 s early to 0.85 s late
relative to the expected start. Both sit well inside the tolerances.

Manual **Split Here** / **Merge with Previous** are stored as overrides keyed by the fingerprint of the
chunk the boundary sits in front of, so they survive rescans and reconnects.

A source chunk's fingerprint is `filename | byte size | frame count`; a session's fingerprint is the
SHA-256 of its chunks' fingerprints. Hashing gigabytes of audio on every scan buys nothing on top.
The fingerprint does not depend on the recorder-clock setting.

On the import screen, sessions under 10 s (button-press fragments, most of what a real recorder
holds) are tucked behind "Show N recordings shorter than 10 seconds"; sessions under 2 minutes start
unselected.

## Time

The recorder writes its own clock into filenames and no time zone anywhere (the `bext`/`iXML`
chunks are empty). `AppSettings.recorderTimeZone` says which zone that clock runs in; start times
become absolute instants at scan time and everything shown or written uses the Mac's zone at import.
The metadata records both zones.

Transcript positions are converted to clock time per source chunk (`SessionTimeline`): each chunk
contributes its own filename timestamp, so a hand-merged session with a gap between takes still
shows true times after the gap.

## Import pipeline

`Preparing → Merging → Uploading → Transcribing → Analyzing speakers → Generating transcript → Complete`
(or `Failed`, with the stage it stopped in).

Every stage first checks what already exists and skips finished work, so `run` is safe to repeat:

| Stage | Skipped when | Persisted |
|---|---|---|
| Merging | the audio file and metadata exist | audio (written under a hidden `.partial` name, verified, renamed), `metadata.json` |
| Uploading | a transcript ID exists | transcript ID in the database and metadata, immediately after job creation |
| Transcribing | the raw response exists | `*.assemblyai.json`, exactly as received |
| Analyzing speakers | metadata stage is past `transcribed` | speakers + evidence in `metadata.json` |
| Generating transcript | never (cheap, deterministic) | `*.md` |

- Sessions interrupted by quitting are marked "not finished" at launch and continue with **Resume**.
- A failed AssemblyAI job clears the transcript ID so the retry submits a new one; network errors,
  5xx and 429 are retried with backoff before a stage fails.
- Speaker analysis cannot fail an import. Voice or Groq problems become warnings in the metadata and a
  banner in the transcript with **Retry Speaker Analysis**, which reruns only that step.
- Imports run one at a time.
- Progress bars are shown only where a real fraction exists (merging, uploading).

### Audio

| Source | Archive |
|---|---|
| Integer PCM up to 24 bit | FLAC, same sample rate / channels / bit depth |
| Floating-point PCM, 32-bit integer | WAV in the source sample format (RF64 above 4 GB) |
| Chunks with differing formats | refused with an explanation; split the session instead |

Encoding is Apple's own FLAC encoder via AVFoundation. After writing, the file is decoded again and
the SHA-256 of its samples is compared with the hash of the source samples; a mismatch discards the
file. The hash is stored in the metadata (`audio.pcmSHA256`).

What is uploaded is not the archive but a temporary **16 kHz / 16-bit FLAC rendition** of it.
AssemblyAI converts everything it receives to 16 kHz before transcribing, so the rendition carries the
same information the service would use, at about a quarter of the size (a real 30-minute chunk: 247 MB
WAV, 139 MB archive FLAC, 31 MB rendition; 64 kbit/s AAC would be 14 MB but is lossy). The archive in
the library stays untouched and lossless; local voice embeddings are computed from the archive. The
metadata records what was sent (`transcription.uploadedAudio`).

### Trimming

A session's ends can be trimmed on the import screen (`Trim`, seconds from the session's first
sample; stored per session fingerprint in `sessionTrim`, and on the import record once queued).
`MergePlan` turns the trim into per-file frame ranges, files entirely outside it are skipped, and
the merger reads exactly those frames, so the cut is sample-exact and the read-back check covers
precisely what was kept. Metadata uses the same plan: each source records where its first kept
sample lands in the merged audio (`offsetSeconds`) and how much of its start was cut
(`skippedSeconds`), so clock times stay right; `session.trim` records the trim itself. The session's
fingerprint does not change, so a trimmed import still counts as that recording for duplicate detection.

### Duplicates and collisions

- A session whose fingerprint is already in the database is not imported again; the import screen
  shows it as **Imported** (or "Imported in <other library>": a recording lives in one library).
- If the database does not know a session but the library folder holds its `metadata.json`, it is adopted.
- A basename taken by anything else gets a `-2`, `-3`… suffix. Unrelated files are never overwritten.

## Library folder

`LibraryFolder` defines the layout: Markdown transcripts at the top, `Data/` with audio, raw response,
metadata and `People.json`. Only plain files, because the folder is meant to sit in a sync service; the
SQLite index stays in Application Support.

- **Restore** (`restoreSessions`): every `Data/*.metadata.json` the database does not know becomes a
  session record again, complete or resumable. Runs at launch, when a library is selected, and on
  *Reload from Folder*. Source-chunk fingerprints are rebuilt from the metadata, so the recorder's
  files show as imported again.
- **People** (`mergePeople` / `writePeople`): on selecting or reloading a library, people and voice
  samples in its `People.json` that the database lacks are added (matched by ID); after that the file
  is rewritten from the database whenever people or samples change. Merge always happens before the
  first write, so a fresh database never overwrites an existing file. Known gap: with two Macs
  writing the same library, a person deleted on one can come back from the other's copy.
- **People are scoped to a library** (`person.library`): voice matching, the people menu and
  auto-created people only ever involve the session's own library.
- **Several libraries**: the list is kept in preferences by path and bookmark; removing one from the
  app forgets its index rows and leaves the folder untouched.
- **Move to Trash** removes a session's four files via the Trash and its index row. (Merely forgetting
  the row would be undone by the next restore.)
- Sessions written by the first builds (all files loose in the folder) are moved into this layout at launch.

## Speaker identity

Three separate things: the **diarized cluster** (AssemblyAI's `A`, `B`…), the **known person**
(database row with voice samples) and the **display name**. `metadata.json` maps label → optional
person ID + display name + state + evidence. The raw response is never edited.

Evidence sources: `manual`, `voice_match`, `self_identification`, `transcript_context`. Each piece
records whether it was applied; unapplied evidence is kept so the speaker menu can explain a near miss.

`IdentityResolver`, in order:

1. Manual decision (a person, or "keep unidentified") wins outright.
2. Strong voice match → that person. If the speaker explicitly introduces themselves as someone
   else, neither is trusted and the speaker stays unidentified.
3. Borderline voice match → only if the transcript independently points at the same person.
4. Explicit, high-confidence self-identification → that name: a new person if nobody has it, the
   existing person otherwise (without touching an existing voice profile the voice did not match).
5. Anything else (closest voice, being addressed, being mentioned) → unidentified.

### Transcript evidence (Groq)

The transcript is cut into chunks of about 12,000 characters with three utterances of overlap; each
request carries utterance IDs and returns structured findings (speaker, name or null, confidence,
basis, evidence with utterance ID + verbatim quote + reason).

The model only proposes. Code then drops anything not anchored in the text: unknown speaker labels,
citations outside the chunk, quotes that are not in the cited utterance, names that do not occur in
the cited text, and "self-identification" not spoken by that speaker. Timestamps are taken from the
transcript by utterance ID, not from the model. Reconciliation across chunks is deterministic code
that only selects among validated findings, so it cannot add evidence.

## Persistence

SQLite (GRDB): `person`, `voiceSample`, `importedSession` (state, transcript ID, a copy of the
metadata), `importedSource` (chunk fingerprints), `boundaryOverride`. No audio in the database.
Everything except in-progress state and grouping overrides can be rebuilt from the library folders.
Preferences (prompt, Groq model, thresholds, bookmarks, recorder clock) are in UserDefaults; API keys
only in the Keychain.

The app is not sandboxed, so that it can notice a recorder on any volume without being pointed at
it first. Hardened runtime is on. Folder bookmarks are kept so a moved destination is still found.

## Notable decisions

- **Plain-file libraries for LLM context**: the point of the app is to have conversations available
  as LLM context, so the library top level holds only Markdown (with a YAML header); no custom
  package or binary container. Voice profiles live in the library too, so recognition survives a
  move to another Mac; they are kept per library because a library may be shared.
- **One library per recording**: duplicate detection is global, so a recording can't be imported
  into two libraries or re-imported with another trim without trashing the first import.
- **`language_codes` only**: AssemblyAI rejects it together with `language_detection`; the cost is
  losing `on_no_speech_detected`, so a speech-free recording may fail instead of coming back empty.
- **16 kHz FLAC upload, not lossy**: AssemblyAI works at 16 kHz anyway; AAC/Opus would save seconds
  per hour of audio at the cost of possible diarization accuracy. The archive stays full quality.
- **Pinned model, no fallback**: `universal-3-5-pro` only, so results never change silently.
- **No automatic resume, no auto-selection of short recordings**: anything that uploads (costs
  money) needs an explicit click.
- **Explicit notarization profile**: `scripts/release.sh` notarizes and staples the app and DMG
  when `NOTARY_PROFILE` is supplied.
- **GRDB instead of raw SQLite or SwiftData**: typed records, migrations and change observation in a
  small MIT-licensed package.
- **Core ML model bundled** rather than downloaded: 15 MB, works offline, no first-run step.
- **Deterministic reconciliation** instead of a second LLM pass: nothing to fabricate, testable.
- **Keychain**: the classic login keychain via `SecItem` (the data-protection keychain needs a
  provisioning profile). With a stable signing identity the items are readable without prompts.
- **Unreadable recordings** (for example one whose header was never finalised by the recorder) are
  listed under "Unreadable Files" and left alone; no guessing from file size.
