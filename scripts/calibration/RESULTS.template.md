# Speaker-ID threshold calibration on German speech (Core ML FBank + Embedding, WeSpeaker ResNet34-LM)

Everything below is measured by `embed.py` → `eval.py` (full output: `results_raw.md`); tables are copied from it by `make_results.py`.

## Recommended thresholds

| band | value | measured basis |
|---|---|---|
| `strong` | **0.78** | Open-set false-ID 0 in all 5 conditions x 2 corpora x gallery sizes 5/15/~100 x 1- and 3-sample profiles. Highest best-impostor score seen: 0.694 with clean profiles, 0.759 degraded-vs-degraded. |
| `enroll` | **0.82** | 0.06 above the highest impostor score in any condition; 0 impostors above it. 75–90% of clean 8-excerpt true matches qualify (MLS, 1 / 3 samples). |
| `borderline` | **0.50** | Inside the range of EER thresholds (MLS 0.38–0.57, VoxPopuli 0.46–0.65). Below it lie 0–0.4% of clean true matches, 3.3% (MLS) / 0% (VoxPopuli) of degraded 8-excerpt ones and 12.3% / 2.4% of degraded 2-excerpt ones. |
| `margin` | **0.10** | Apply inside the band [borderline, strong); it changes nothing at >= 0.78. |

Miss rate of `strong` (enrolled speaker not auto-assigned; these fall into the transcript-evidence band, not to "unknown"), MLS / VoxPopuli:
clean 8 excerpts 14.1% / 3.6% with 1 enrolled sample, 6.0% / 2.1% with 3; clean 2 excerpts 25.5% / 11.6% (1), 13.2% / 8.3% (3);
degraded 8 excerpts vs clean profile 76.6% / 67.4% (1), 66.2% / 60.8% (3); degraded 2 excerpts 95.7% / 88.2% (1), 92.6% / 83.1% (3);
degraded vs degraded 35.1% / 14.9% (1), 16.7% / 9.9% (3).

A lower `strong` is only safe if profiles never contain noisy samples: at 0.72 false-ID is 0 in the four clean-profile conditions (miss 6.0% clean, 48% degraded, MLS 1 sample) but 1.0–1.5% degraded-vs-degraded with a ~100-person gallery; at 0.70, 2–4%.

Outcome at these thresholds (columns: unenrolled probe shown as band candidate for gallery 5/15/~100; false-ID; impostor >= enroll; enrolled probe auto-assigned / in band / lost; eligible for profile; wrong person passes):

{rec}

## Data

| | MLS German | VoxPopuli German |
|---|---|---|
| Source | `huggingface.co/datasets/facebook/multilingual_librispeech`, config `german`: `dev` + `test` parquet in full, plus 151 row groups of `train` (40 speakers with >= 3 books) fetched by HTTP range request | `huggingface.co/datasets/facebook/voxpopuli`, `de/test-00000-of-00001.parquet` |
| Licence | CC BY 4.0 | CC0 |
| Speech | read audiobooks (LibriVox), opus 16 kHz | European Parliament plenary speeches, 16 kHz wav |
| Speakers | 100 (gender estimated: 53 f / 47 m) | 110 (labels; 101 enrolment-capable: 31 f / 70 m) |
| Sessions | 272 (one more excluded as mislabelled); session = one LibriVox chapter mp3; 74 speakers with >= 2, 41 with 4; 52 speakers span >= 2 books | 222 (187 with >= 3 excerpts, usable as profile samples); session = speaker x plenary date; 49 speakers with >= 2 enrolment-capable sessions, 7 with >= 4 |
| Utterances embedded | 4,269 (x4 variants) | 1,500 (x4 variants) |

No conversational German corpus was used: VoxPopuli is prepared/semi-spontaneous speech. I did not search further for one.
Downloads kept on disk: 2.37 GB. An earlier remote metadata scan of the train shards was aborted after 10 minutes; it saved nothing and its transfer volume was not measured, so total transfer may have exceeded 3 GB.

Protocol: a profile sample is the cluster of 8 excerpts of one session (VoxPopuli: 3–8). Test clusters are 8 excerpts (up to two disjoint per session) or 2 excerpts (up to four per session). MLS utterances are all 10–20 s, so excerpts were cut to a random 3–10 s (mean 6.5 s) to mimic diarised turns; VoxPopuli keeps natural length (>= 3 s, capped at 10 s, mean 7.7 s). Degraded = per-session synthetic room (exponentially decaying noise IR, RT60 0.4–0.6 s, direct-to-reverberant ratio −7..0 dB), babble of 4–6 other speakers plus pink noise at 5–10 dB SNR, −20 dB gain.

## Score distributions (1-sample profile, cosine)

{dist}

## Open-set: best impostor score when the true speaker is not enrolled

3-sample profiles with max scoring (the upper envelope; 1-sample profiles are about 0.02 lower at p50). 20 random galleries per probe.

{openset}

## Margin (best − second-best person), 1-sample profile

{margin}

The margin separates well only in large galleries: false best-matches have median margin 0.03 at ~100 people but 0.08 at 5 (p95 0.27), versus 0.38 (clean) / 0.26 (degraded) for correct matches. In the band it cuts candidates for unenrolled speakers at gallery ~100 from 39% to 5% (MLS clean, threshold 0.50) and costs 0.3% of clean and 4% of degraded true matches.

## 1 vs 3 enrolled samples, centroid vs max

Three samples help: MLS EER 0.15% → 0.02% (clean), 1.18% → 0.94% (degraded vs clean); target mean 0.855 → 0.895; impostor p99 0.472 → 0.499 with max.
Centroid and max separate equally well: EER 0.02% vs 0.02% (clean), 0.28% vs 0.30% (2 excerpts), 0.97% vs 0.94% (degraded), 2.12% vs 2.11% (degraded, 2 excerpts), 0.28% vs 0.32% (degraded vs degraded). Centroid impostor scores are about 0.02 lower (p99 0.482 vs 0.499). Verdict: no measurable advantage either way; keep max.

{cen}

## Amount of speech (MLS, clean test cluster vs clean 8-excerpt sample)

{speech}

Less speech lowers target scores but does not raise impostor scores, so little speech causes misses, not false identifications. One 3 s excerpt is unreliable (target p1 0.41 on MLS, 0.04 on VoxPopuli). From about 12 s of speech (4 x 3 s or 2 x ~6 s) the mean target score is within 0.04 of the full 8-excerpt cluster (0.82 vs 0.85).
Suggested minimum: >= 2 excerpts and >= 10 s total for any decision; >= 4 excerpts for adding to a profile (not separately tested as an enrolment rule; 2-vs-2-excerpt EER is 0.60% vs 0.22% for 8-vs-8).

## Caveats

Measured:
- Noisy profile samples inflate impostor scores: degraded-vs-degraded impostor median 0.22 vs 0.11 clean, best-of-~100 median 0.58–0.60 vs 0.48–0.50, max 0.759 vs 0.675. This is what sets `strong`. At `enroll` 0.82, 8–19% of degraded 8-excerpt clusters still qualify for the profile.
- "0 false-ID" means 0 of 520 / 1,088 (MLS) and 202 / 584 (VoxPopuli) distinct probe clusters from ~100 speakers per corpus. It cannot resolve rates below roughly 0.5% per probe.
- One MLS session was mislabelled (speaker 3503, `kriton_1_platon`: 0.79–0.89 against all sessions of speaker 2422, 0.36–0.42 against its own speaker) and is excluded. With it included the impostor maximum is 0.928.
- VoxPopuli separates more easily than MLS (clean EER 0.00% vs 0.22%); all its sessions come from the same parliament sound system.
- MLS gender is estimated from the embedding (93.6% leave-one-out agreement with VoxPopuli labels), so the same-gender rows for MLS are approximate.
- Core ML batch 32 and batch 1 embeddings differ by up to 6e-4.

Not measured (speculation):
- Real clip-on-mic recordings, overlapping speech and diarisation errors (impure clusters) will behave differently from the synthetic degradation; expect lower target scores.
- Same-room recordings of different people may inflate impostor scores more than the per-session synthetic rooms did.
- Galleries of related people (family, same dialect) and voice changes over months or years were not tested.
