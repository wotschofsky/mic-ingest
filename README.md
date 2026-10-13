# MicIngest

Turn recordings from a DJI microphone into searchable, speaker-labeled Markdown transcripts.
MicIngest is a native macOS app that groups the recorder’s WAV chunks into sessions, merges
lossless audio, and exports transcripts with real clock times.

Transcription uses AssemblyAI. Optional speaker-name inference uses Groq. Voice matching runs
locally using a bundled Core ML model.

## What it does

- Groups consecutive 30-minute recording chunks into sessions.
- Previews recordings directly from the recorder and trims the beginning and end before import.
- Exports lossless audio, speaker-labeled transcripts, and session metadata.
- Lets you name speakers manually and recognize known voices across recordings.
- Keeps separate people and voice profiles for each library.
- Reads the recorder without modifying or deleting its files.

## Requirements

- Apple Silicon Mac running macOS 15 or later.
- Xcode 26 to build from source; development and CI use Xcode 26.3.
- An AssemblyAI API key for transcription.
- A Groq API key if you want names inferred from transcript text.

Importing with transcription requires an internet connection and your own service accounts.

## Build and run

Open `MicIngest.xcodeproj` in Xcode, select the **MicIngest** scheme, and run it.

For a signed development build, create your local signing configuration:

```sh
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
```

Replace `YOUR_TEAM_ID` in that file with your Apple development team ID. Git ignores the file;
the setting applies to both the app and tests.

To build locally without an Apple developer account, use ad hoc signing:

```sh
xcodebuild -project MicIngest.xcodeproj -scheme MicIngest \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

This builds a local development app, not a notarized distribution release.

## Import your first recording

1. Open **Settings → Integrations** and enter your AssemblyAI key. Add a Groq key if desired.
2. Under **Transcription → Recorder clock**, choose the time zone used by the recorder’s clock.
   Its filenames contain timestamps without a time zone.
3. Connect the recorder, or use **Choose Source Folder…** to select a folder of recordings.
4. Select sessions and choose a library folder for the imported files.
5. Preview a session with ▷. Use **Set Start** and **Set End** to trim it, then choose **Import**.

Only the selected portion is merged and uploaded. To name or correct a speaker, click their name
in the transcript. Voice recognition can miss or misidentify speakers; review automatic names
when accuracy matters.

## Your library is plain files

A library can live in a local folder or a synced folder. Transcripts are Markdown, so you can
read and use them without MicIngest.

```text
My Library/
  2026-10-01_20-43-49.md
  Data/
    2026-10-01_20-43-49.flac
    2026-10-01_20-43-49.assemblyai.json
    2026-10-01_20-43-49.metadata.json
    People.json
```

Audio is lossless FLAC, or WAV for floating-point sources. The AssemblyAI response is preserved
as received; the metadata sidecar records sources, speakers, and identity evidence.

Each transcript includes a date, start and end times, duration, speakers, and an audio path,
followed by timestamped turns:

```markdown
## 20:44:03 · Alex

Ich glaube, wir sollten morgen früher losfahren.
```

To reopen a library on another Mac, choose **Add Library Folder…**. **Reload from Folder** picks
up changes made outside the app. The app’s local SQLite index is rebuildable and stays outside
the library. Switching libraries also switches the people and voice profiles used for matching.

## Privacy and data flow

| Data | Where it goes |
| --- | --- |
| Selected audio | Your library; a 16 kHz FLAC rendition is uploaded to AssemblyAI |
| Transcript text | Your library; sent to Groq for name inference when configured |
| Names and voice profiles | The library’s `Data/People.json`; voice profiles are not sent to either API |
| API keys | macOS Keychain |
| App index | `~/Library/Application Support/MicIngest/MicIngest.sqlite` |
| Original recordings | Stay on the recorder or in the source folder |

There is no analytics, telemetry, or crash reporting. Sharing a library also shares its audio,
transcripts, names, and voice profiles. You can remove voice data under **Settings → Speakers**.

## Development

Run the tests with the same ad hoc signing settings used in CI:

```sh
xcodebuild -project MicIngest.xcodeproj -scheme MicIngest \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test
```

GitHub Actions builds and tests on pushes to `main`, pull requests, and manual runs, using
macOS 26 on Apple Silicon with Xcode 26.3. It uploads test results and the build log for diagnosis.
Tests use synthetic data and mocked APIs; no service keys or signing credentials are needed.
The speech-based voice test skips when its required macOS system voices are unavailable.

Development helpers:

- `scripts/make_fixtures.py <output-folder>` creates synthetic DJI-style recordings and transcripts
  using macOS system voices. Allow about 1.7 GB of disk space.
- `scripts/mock_services.py <output-folder>/transcripts.json` runs local mock APIs. Its header
  documents the Debug environment variables for connecting the app.
- `MicIngest/Resources/AppIcon.icon` is editable with Icon Composer.

The app uses AVFoundation and AudioToolbox for audio, GRDB.swift for SQLite, and bundled
WeSpeaker Core ML models for embeddings. Python is only used by development helpers.

Keep pull requests focused, include a description of the behavior change, and run the tests.
Use synthetic examples rather than personal recordings, transcripts, or voice profiles.

## Distribution builds

Signed releases require your own Developer ID certificate and a `notarytool` Keychain profile:

```sh
NOTARY_PROFILE=<your-keychain-profile> scripts/release.sh
```

The script writes `build/MicIngest.app`, `build/MicIngest-<version>.zip`, and a signed
`build/MicIngest-<version>.dmg` with an Applications shortcut and license notices. With a
profile, it notarizes and staples both the app and the DMG. Without
`NOTARY_PROFILE`, it skips notarization. GitHub Actions only builds and tests; it does not publish
or notarize releases.

## Technical documentation

- [Architecture](docs/ARCHITECTURE.md): pipeline, session grouping, storage, and identity rules.
- [Speaker embeddings](docs/SPEAKER_EMBEDDINGS.md): model, matching, and enrollment.
- [Voice calibration](docs/voice-threshold-calibration.md): measurements and threshold limitations.
- [External services](docs/EXTERNAL_SERVICES.md): request formats and model defaults.

## Licensing

The application source is licensed under the [MIT License](LICENSE).
Third-party components retain their own licenses: GRDB.swift is MIT-licensed and the bundled
speaker models are CC-BY-4.0. See [third-party notices](THIRD_PARTY_NOTICES.md) for attribution.
