# Local voice recognition

## Selected model

**WeSpeaker ResNet34-LM**, as converted to Core ML for pyannote "community-1" by Fluid Inference
(`huggingface.co/FluidInference/speaker-diarization-coreml`: `FBank.mlmodelc` + `Embedding.mlmodelc`).

| | |
|---|---|
| Embedding | 256 dimensions, L2-normalised, compared by cosine similarity |
| Input | 16 kHz mono, fixed 10 s window (shorter excerpts are repeated to fill it) |
| Size | 15 MB, bundled in the app (`MicIngest/Resources/VoiceModels.bundle`) |
| Runtime | Core ML only. No Python, no ONNX Runtime, no download on first use |
| Licence | CC-BY-4.0 (see `THIRD_PARTY_NOTICES.md` for the required attribution) |
| Published accuracy | 0.80 % EER on VoxCeleb1-O (0.94 % on Vox1-E, 1.70 % on Vox1-H) |
| Version string | `wespeaker-resnet34-lm.pyannote-community-1.coreml-1` (stored with every embedding) |

Why this one:

- It is the only strong candidate with a ready Core ML build whose feature frontend (Kaldi fbank,
  scaling, mean normalisation) is inside the model, so the app needs no DSP code or extra runtime.
- Trained on VoxCeleb2 (celebrity interviews, speakers of many nationalities). No candidate publishes
  German numbers, so it was measured on German speech here (below).
- Licence allows redistribution with attribution.

Considered and not chosen:

| Candidate | Why not |
|---|---|
| WeSpeaker ResNet221/293-LM (0.58 / 0.53 % EER) | ONNX only: needs ONNX Runtime (90 MB static library) plus a Swift fbank implementation. Accuracy gain is small next to the acoustic mismatch of real recordings |
| 3D-Speaker ERes2Net / CAM++ | ONNX only; CAM++ gave unusable scores in a sanity test through sherpa-onnx; ERes2NetV2's released ONNX is trained on Mandarin |
| NVIDIA TitaNet-Large (0.66 %) | 101 MB, English-heavy training data, needs the NeMo mel frontend |
| SpeechBrain ECAPA-TDNN (0.80 %) | No official ONNX or Core ML export |
| ReDimNet2 (0.29 %) | PyTorch only; the best variants are trained on VoxBlink2 (non-commercial) |
| FluidAudio Swift package | Its public embedding call uses an older model outside the licence confirmation and needs the segmentation model loaded |
| sherpa-onnx + WeSpeaker | Skips mean normalisation for these models; same- and different-speaker scores overlapped |

Embeddings are computed on the Mac and never sent to AssemblyAI or Groq. They are stored per library:
in the app database (`voiceSample` table) and in the library folder's `Data/People.json`, so they travel
with the library (and with whatever syncs that folder). They are keyed by model version, so a future
model change simply starts fresh profiles instead of mixing vector spaces.

## How a speaker is embedded

1. From AssemblyAI's diarization, take up to 8 utterances of that speaker which are at least 3 s long,
   have confidence ≥ 0.6 and do not overlap a neighbouring speaker (`ExcerptSelector`). An utterance
   longer than 10 s contributes its first 10 s.
2. Fewer than 2 such excerpts, or less than 10 s in total: the speaker is not compared at all.
3. Each excerpt is embedded; the speaker's embedding is the normalised mean.

A person's profile is a list of such embeddings from different recordings (up to 24), each with its
provenance. A probe is scored against the *closest* sample, so samples from different acoustic
conditions (clip-on, across a table, outdoors) all remain useful instead of being averaged away.

## Thresholds

Measured on German speech with exactly this pipeline: Multilingual LibriSpeech German (100 speakers,
272 sessions) and VoxPopuli German (110 speakers), clean and with synthetic reverb + babble noise at
5–10 dB SNR. Full tables: [voice-threshold-calibration.md](voice-threshold-calibration.md).

| Setting | Default | Meaning |
|---|---|---|
| `strong` | 0.78 | At or above (and ≥ `margin` ahead of the next person): the voice alone identifies the person |
| `enroll` | 0.82 | At or above: the automatic match may also be added to the profile (needs ≥ 4 excerpts) |
| `borderline` | 0.50 | Between this and `strong`: only counts if the transcript independently names the same person |
| `margin` | 0.10 | Required lead over the second-closest known person |

What the measurements showed:

- Different-speaker scores peaked at 0.69 against clean profiles and 0.76 when both sides were noisy.
  With `strong` at 0.78 no unenrolled speaker was auto-identified in any condition (0 of 202–1,088
  probes per condition, so rates below about 0.5 % cannot be ruled out).
- The price is misses: 6–14 % of clean same-speaker comparisons fall below 0.78, and 60–77 % of noisy,
  reverberant ones against a clean profile. Those land in the borderline band (named only with
  transcript evidence), which is the intended trade: a missing name is much better than a wrong one.
- Less speech lowers same-speaker scores but does not raise impostor scores.
- Closest-sample scoring and centroid scoring separated equally well.

Not measured, and the reason the thresholds are adjustable under Settings → Advanced: real clip-on
recordings with overlapping speech, people recorded in the same room, related voices, and voices
changing over months. Retune once a few dozen real sessions with confirmed speakers exist.

## What may enter a profile

| Provenance | When |
|---|---|
| `manual_confirmation` | The user assigned or confirmed the speaker |
| `explicit_self_identification` | High-confidence "ich bin X" by that speaker, quote verified in the transcript; not when a person of that name already has a profile that this voice does not match |
| `high_confidence_voice_match` | Similarity ≥ `enroll` to an existing profile, from at least 4 excerpts |

Nothing else is enrolled. Changing or removing a speaker's identity removes the sample that speaker
contributed; a session never scores against its own samples; when a profile is full the oldest
automatic samples go first and manual ones last. A person's voice data can be removed in
Settings → Speakers.
