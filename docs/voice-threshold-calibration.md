# Speaker-ID threshold calibration on German speech (Core ML FBank + Embedding, WeSpeaker ResNet34-LM)

Everything below is measured by `scripts/calibration/embed.py` → `eval.py`; tables are copied from their output by `make_results.py`.
The scripts are development tooling (Python with coremltools, numpy, scipy, soundfile, pyarrow); they expect the two `.mlmodelc`
folders from `MicIngest/Resources/VoiceModels.bundle` one directory up and download the corpora themselves.

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

| corpus | condition | profile | cand g=5 | cand g=15 | cand g=all | false-ID | false-enrol | auto | band | lost | enrol-ok | wrong |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| MLS | (a) clean, 8 exc vs clean | 1 max | 3.2% | 6.0% | 5.4% | 0.00% | 0.00% | 85.9% | 13.8% | 0.3% | 74.6% | 0.00% |
| MLS | (a) clean, 8 exc vs clean | 3 max | 4.1% | 7.6% | 5.6% | 0.00% | 0.00% | 94.0% | 6.0% | 0.0% | 89.5% | 0.00% |
| MLS | (b) clean, 2 exc vs clean | 1 max | 2.1% | 4.4% | 4.4% | 0.00% | 0.00% | 74.5% | 24.4% | 1.1% | 57.4% | 0.02% |
| MLS | (b) clean, 2 exc vs clean | 3 max | 3.0% | 5.8% | 5.3% | 0.00% | 0.00% | 86.8% | 12.5% | 0.7% | 74.9% | 0.00% |
| MLS | (c) degraded, 8 exc vs clean | 1 max | 1.3% | 3.1% | 3.8% | 0.00% | 0.00% | 23.4% | 69.1% | 7.5% | 7.7% | 0.00% |
| MLS | (c) degraded, 8 exc vs clean | 3 max | 2.5% | 4.6% | 3.4% | 0.00% | 0.00% | 33.8% | 62.7% | 3.5% | 12.6% | 0.00% |
| MLS | (c2) degraded, 2 exc vs clean | 1 max | 0.9% | 2.0% | 3.1% | 0.00% | 0.00% | 4.3% | 75.6% | 20.2% | 0.9% | 0.02% |
| MLS | (c2) degraded, 2 exc vs clean | 3 max | 1.2% | 2.6% | 3.6% | 0.00% | 0.00% | 7.4% | 78.2% | 14.4% | 1.9% | 0.00% |
| MLS | (c3) degraded, 8 exc vs degraded | 1 max | 13.3% | 15.1% | 4.7% | 0.00% | 0.00% | 64.9% | 24.7% | 10.4% | 43.1% | 0.04% |
| MLS | (c3) degraded, 8 exc vs degraded | 3 max | 16.9% | 14.9% | 2.8% | 0.00% | 0.00% | 83.3% | 14.1% | 2.6% | 63.9% | 0.00% |
| VP | (a) clean, 8 exc vs clean | 1 max | 2.8% | 6.3% | 10.3% | 0.00% | 0.00% | 96.4% | 3.6% | 0.0% | 84.1% | 0.00% |
| VP | (a) clean, 8 exc vs clean | 3 max | 4.5% | 8.6% | 10.4% | 0.00% | 0.00% | 97.9% | 2.1% | 0.0% | 88.7% | 0.00% |
| VP | (b) clean, 2 exc vs clean | 1 max | 2.6% | 6.2% | 8.6% | 0.00% | 0.00% | 88.4% | 11.6% | 0.0% | 77.8% | 0.00% |
| VP | (b) clean, 2 exc vs clean | 3 max | 3.4% | 7.3% | 8.3% | 0.00% | 0.00% | 91.7% | 8.3% | 0.0% | 84.1% | 0.00% |
| VP | (c) degraded, 8 exc vs clean | 1 max | 2.1% | 4.6% | 5.0% | 0.00% | 0.00% | 32.6% | 67.1% | 0.4% | 11.3% | 0.00% |
| VP | (c) degraded, 8 exc vs clean | 3 max | 2.1% | 5.2% | 4.5% | 0.00% | 0.00% | 39.2% | 60.1% | 0.7% | 16.5% | 0.00% |
| VP | (c2) degraded, 2 exc vs clean | 1 max | 1.2% | 3.0% | 3.5% | 0.00% | 0.00% | 11.8% | 82.0% | 6.2% | 2.4% | 0.00% |
| VP | (c2) degraded, 2 exc vs clean | 3 max | 1.6% | 3.7% | 3.3% | 0.00% | 0.00% | 16.9% | 77.7% | 5.5% | 3.3% | 0.00% |
| VP | (c3) degraded, 8 exc vs degraded | 1 max | 11.7% | 18.5% | 7.1% | 0.00% | 0.00% | 85.1% | 14.0% | 0.9% | 64.3% | 0.00% |
| VP | (c3) degraded, 8 exc vs degraded | 3 max | 13.5% | 18.6% | 5.5% | 0.00% | 0.00% | 90.1% | 9.2% | 0.7% | 76.7% | 0.00% |

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

| corpus | condition (test vs profile, 1 sample) | EER | set | n | mean | std | min | p0.1 | p1 | p5 | p50 | p95 | p99 | p99.9 | max |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| MLS | (a) clean, 8 exc vs clean | 0.22% @ 0.551 | target  | 1179 | 0.854 | 0.075 | 0.549 | 0.550 | 0.600 | 0.710 | 0.871 | 0.943 | 0.958 | 0.968 | 0.969 |
| MLS | (a) clean, 8 exc vs clean | 0.22% @ 0.551 | impostor | 139741 | 0.137 | 0.128 | -0.226 | -0.141 | -0.091 | -0.039 | 0.114 | 0.380 | 0.472 | 0.567 | 0.675 |
| MLS | (a) clean, 8 exc vs clean | 0.22% @ 0.551 | impostor (same gender) | 69069 | 0.211 | 0.126 | -0.226 | -0.133 | -0.058 | 0.015 | 0.205 | 0.426 | 0.508 | 0.582 | 0.675 |
| MLS | (a) clean, 8 exc vs clean | 0.22% @ 0.551 | target, same book / other chapter | 263 | 0.862 | 0.080 | 0.551 | 0.551 | 0.578 | 0.710 | 0.881 | 0.955 | 0.962 | 0.968 | 0.968 |
| MLS | (a) clean, 8 exc vs clean | 0.22% @ 0.551 | target, different book | 916 | 0.851 | 0.073 | 0.549 | 0.550 | 0.604 | 0.711 | 0.869 | 0.938 | 0.952 | 0.968 | 0.969 |
| MLS | (b) clean, 2 exc vs clean | 0.40% @ 0.503 | target  | 2488 | 0.816 | 0.080 | 0.393 | 0.444 | 0.543 | 0.666 | 0.832 | 0.912 | 0.935 | 0.952 | 0.959 |
| MLS | (b) clean, 2 exc vs clean | 0.40% @ 0.503 | impostor | 292360 | 0.130 | 0.125 | -0.283 | -0.145 | -0.094 | -0.042 | 0.109 | 0.368 | 0.462 | 0.554 | 0.684 |
| MLS | (b) clean, 2 exc vs clean | 0.40% @ 0.503 | impostor (same gender) | 144520 | 0.201 | 0.124 | -0.283 | -0.139 | -0.064 | 0.006 | 0.196 | 0.413 | 0.494 | 0.576 | 0.684 |
| MLS | (c) degraded, 8 exc vs clean | 1.26% @ 0.450 | target  | 1179 | 0.703 | 0.093 | 0.339 | 0.378 | 0.437 | 0.523 | 0.721 | 0.828 | 0.854 | 0.876 | 0.877 |
| MLS | (c) degraded, 8 exc vs clean | 1.26% @ 0.450 | impostor | 139741 | 0.145 | 0.122 | -0.202 | -0.124 | -0.070 | -0.022 | 0.123 | 0.371 | 0.459 | 0.543 | 0.694 |
| MLS | (c) degraded, 8 exc vs clean | 1.26% @ 0.450 | impostor (same gender) | 69069 | 0.218 | 0.115 | -0.199 | -0.093 | -0.027 | 0.037 | 0.215 | 0.414 | 0.486 | 0.560 | 0.694 |
| MLS | (c2) degraded, 2 exc vs clean | 2.85% @ 0.381 | target  | 2488 | 0.627 | 0.107 | 0.240 | 0.279 | 0.335 | 0.423 | 0.641 | 0.773 | 0.816 | 0.839 | 0.842 |
| MLS | (c2) degraded, 2 exc vs clean | 2.85% @ 0.381 | impostor | 292360 | 0.129 | 0.116 | -0.246 | -0.136 | -0.082 | -0.033 | 0.110 | 0.346 | 0.434 | 0.519 | 0.690 |
| MLS | (c2) degraded, 2 exc vs clean | 2.85% @ 0.381 | impostor (same gender) | 144520 | 0.195 | 0.113 | -0.244 | -0.113 | -0.045 | 0.017 | 0.191 | 0.388 | 0.463 | 0.541 | 0.690 |
| MLS | (c3) degraded, 8 exc vs degraded | 1.28% @ 0.568 | target  | 1179 | 0.792 | 0.081 | 0.456 | 0.480 | 0.564 | 0.630 | 0.807 | 0.900 | 0.915 | 0.922 | 0.926 |
| MLS | (c3) degraded, 8 exc vs degraded | 1.28% @ 0.568 | impostor | 139741 | 0.244 | 0.137 | -0.145 | -0.063 | 0.000 | 0.054 | 0.220 | 0.496 | 0.578 | 0.655 | 0.759 |
| MLS | (c3) degraded, 8 exc vs degraded | 1.28% @ 0.568 | impostor (same gender) | 69069 | 0.330 | 0.124 | -0.093 | -0.005 | 0.063 | 0.131 | 0.327 | 0.536 | 0.606 | 0.673 | 0.759 |
| VP | (a) clean, 8 exc vs clean | 0.00% @ 0.654 | target  | 304 | 0.890 | 0.052 | 0.654 | 0.654 | 0.729 | 0.794 | 0.902 | 0.953 | 0.959 | 0.963 | 0.963 |
| VP | (a) clean, 8 exc vs clean | 0.00% @ 0.654 | impostor | 37268 | 0.153 | 0.126 | -0.210 | -0.141 | -0.083 | -0.024 | 0.134 | 0.385 | 0.484 | 0.576 | 0.645 |
| VP | (a) clean, 8 exc vs clean | 0.00% @ 0.654 | impostor (same gender) | 22570 | 0.201 | 0.124 | -0.210 | -0.123 | -0.061 | 0.007 | 0.195 | 0.419 | 0.504 | 0.596 | 0.645 |
| VP | (b) clean, 2 exc vs clean | 0.11% @ 0.564 | target  | 910 | 0.862 | 0.058 | 0.544 | 0.602 | 0.659 | 0.751 | 0.876 | 0.931 | 0.943 | 0.950 | 0.953 |
| VP | (b) clean, 2 exc vs clean | 0.11% @ 0.564 | impostor | 107749 | 0.150 | 0.124 | -0.238 | -0.142 | -0.085 | -0.025 | 0.132 | 0.377 | 0.473 | 0.565 | 0.655 |
| VP | (b) clean, 2 exc vs clean | 0.11% @ 0.564 | impostor (same gender) | 65894 | 0.195 | 0.123 | -0.238 | -0.132 | -0.065 | 0.003 | 0.189 | 0.409 | 0.496 | 0.577 | 0.655 |
| VP | (c) degraded, 8 exc vs clean | 0.27% @ 0.525 | target  | 304 | 0.746 | 0.068 | 0.525 | 0.536 | 0.576 | 0.625 | 0.748 | 0.846 | 0.865 | 0.886 | 0.888 |
| VP | (c) degraded, 8 exc vs clean | 0.27% @ 0.525 | impostor | 37268 | 0.147 | 0.119 | -0.198 | -0.130 | -0.071 | -0.019 | 0.129 | 0.366 | 0.458 | 0.548 | 0.626 |
| VP | (c) degraded, 8 exc vs clean | 0.27% @ 0.525 | impostor (same gender) | 22570 | 0.194 | 0.116 | -0.198 | -0.121 | -0.048 | 0.013 | 0.189 | 0.394 | 0.478 | 0.562 | 0.626 |
| VP | (c2) degraded, 2 exc vs clean | 0.56% @ 0.464 | target  | 910 | 0.695 | 0.077 | 0.390 | 0.402 | 0.494 | 0.558 | 0.704 | 0.808 | 0.842 | 0.862 | 0.870 |
| VP | (c2) degraded, 2 exc vs clean | 0.56% @ 0.464 | impostor | 107749 | 0.137 | 0.115 | -0.224 | -0.139 | -0.080 | -0.026 | 0.121 | 0.350 | 0.440 | 0.526 | 0.634 |
| VP | (c2) degraded, 2 exc vs clean | 0.56% @ 0.464 | impostor (same gender) | 65894 | 0.179 | 0.114 | -0.224 | -0.128 | -0.061 | 0.001 | 0.174 | 0.378 | 0.459 | 0.536 | 0.634 |
| VP | (c3) degraded, 8 exc vs degraded | 0.04% @ 0.650 | target  | 304 | 0.837 | 0.058 | 0.650 | 0.650 | 0.684 | 0.700 | 0.843 | 0.910 | 0.932 | 0.949 | 0.949 |
| VP | (c3) degraded, 8 exc vs degraded | 0.04% @ 0.650 | impostor | 37268 | 0.225 | 0.134 | -0.139 | -0.066 | -0.011 | 0.039 | 0.206 | 0.468 | 0.563 | 0.645 | 0.734 |
| VP | (c3) degraded, 8 exc vs degraded | 0.04% @ 0.650 | impostor (same gender) | 22570 | 0.283 | 0.125 | -0.139 | -0.046 | 0.017 | 0.088 | 0.277 | 0.498 | 0.582 | 0.655 | 0.734 |

## Open-set: best impostor score when the true speaker is not enrolled

3-sample profiles with max scoring (the upper envelope; 1-sample profiles are about 0.02 lower at p50). 20 random galleries per probe.

| corpus | condition | profile | gallery size | n draws (probes) | p50 | p95 | p99 | p99.9 | max |
|---|---|---|---|---|---|---|---|---|---|
| MLS | (a) clean, 8 exc vs clean | 3 samples max | 5 | 10400 (520 probes) | 0.319 | 0.498 | 0.565 | 0.631 | 0.675 |
| MLS | (a) clean, 8 exc vs clean | 3 samples max | 15 | 10400 (520 probes) | 0.404 | 0.547 | 0.592 | 0.655 | 0.675 |
| MLS | (a) clean, 8 exc vs clean | 3 samples max | all (99-100) | 10400 (520 probes) | 0.501 | 0.601 | 0.655 | 0.675 | 0.675 |
| MLS | (b) clean, 2 exc vs clean | 3 samples max | 5 | 21760 (1088 probes) | 0.304 | 0.485 | 0.551 | 0.623 | 0.684 |
| MLS | (b) clean, 2 exc vs clean | 3 samples max | 15 | 21760 (1088 probes) | 0.389 | 0.530 | 0.587 | 0.653 | 0.684 |
| MLS | (b) clean, 2 exc vs clean | 3 samples max | all (99-100) | 21760 (1088 probes) | 0.484 | 0.592 | 0.640 | 0.672 | 0.684 |
| MLS | (c) degraded, 8 exc vs clean | 3 samples max | 5 | 10400 (520 probes) | 0.312 | 0.480 | 0.540 | 0.617 | 0.694 |
| MLS | (c) degraded, 8 exc vs clean | 3 samples max | 15 | 10400 (520 probes) | 0.391 | 0.519 | 0.567 | 0.641 | 0.694 |
| MLS | (c) degraded, 8 exc vs clean | 3 samples max | all (99-100) | 10400 (520 probes) | 0.478 | 0.569 | 0.615 | 0.694 | 0.694 |
| MLS | (c2) degraded, 2 exc vs clean | 3 samples max | 5 | 21760 (1088 probes) | 0.288 | 0.453 | 0.513 | 0.582 | 0.648 |
| MLS | (c2) degraded, 2 exc vs clean | 3 samples max | 15 | 21760 (1088 probes) | 0.362 | 0.495 | 0.549 | 0.615 | 0.690 |
| MLS | (c2) degraded, 2 exc vs clean | 3 samples max | all (99-100) | 21760 (1088 probes) | 0.451 | 0.550 | 0.600 | 0.648 | 0.690 |
| MLS | (c3) degraded, 8 exc vs degraded | 3 samples max | 5 | 10400 (520 probes) | 0.439 | 0.601 | 0.656 | 0.723 | 0.759 |
| MLS | (c3) degraded, 8 exc vs degraded | 3 samples max | 15 | 10400 (520 probes) | 0.518 | 0.635 | 0.693 | 0.738 | 0.759 |
| MLS | (c3) degraded, 8 exc vs degraded | 3 samples max | all (99-100) | 10400 (520 probes) | 0.600 | 0.682 | 0.724 | 0.759 | 0.759 |
| VP | (a) clean, 8 exc vs clean | 3 samples max | 5 | 4040 (202 probes) | 0.310 | 0.500 | 0.562 | 0.633 | 0.645 |
| VP | (a) clean, 8 exc vs clean | 3 samples max | 15 | 4040 (202 probes) | 0.400 | 0.549 | 0.602 | 0.642 | 0.645 |
| VP | (a) clean, 8 exc vs clean | 3 samples max | all (100-101) | 4040 (202 probes) | 0.507 | 0.604 | 0.633 | 0.645 | 0.645 |
| VP | (b) clean, 2 exc vs clean | 3 samples max | 5 | 11680 (584 probes) | 0.305 | 0.488 | 0.558 | 0.613 | 0.655 |
| VP | (b) clean, 2 exc vs clean | 3 samples max | 15 | 11680 (584 probes) | 0.394 | 0.539 | 0.592 | 0.631 | 0.655 |
| VP | (b) clean, 2 exc vs clean | 3 samples max | all (100-101) | 11680 (584 probes) | 0.497 | 0.600 | 0.625 | 0.655 | 0.655 |
| VP | (c) degraded, 8 exc vs clean | 3 samples max | 5 | 4040 (202 probes) | 0.293 | 0.469 | 0.541 | 0.606 | 0.626 |
| VP | (c) degraded, 8 exc vs clean | 3 samples max | 15 | 4040 (202 probes) | 0.374 | 0.519 | 0.572 | 0.625 | 0.626 |
| VP | (c) degraded, 8 exc vs clean | 3 samples max | all (100-101) | 4040 (202 probes) | 0.482 | 0.578 | 0.606 | 0.626 | 0.626 |
| VP | (c2) degraded, 2 exc vs clean | 3 samples max | 5 | 11680 (584 probes) | 0.280 | 0.454 | 0.520 | 0.578 | 0.622 |
| VP | (c2) degraded, 2 exc vs clean | 3 samples max | 15 | 11680 (584 probes) | 0.359 | 0.501 | 0.548 | 0.602 | 0.634 |
| VP | (c2) degraded, 2 exc vs clean | 3 samples max | all (100-101) | 11680 (584 probes) | 0.458 | 0.548 | 0.598 | 0.634 | 0.634 |
| VP | (c3) degraded, 8 exc vs degraded | 3 samples max | 5 | 4040 (202 probes) | 0.399 | 0.580 | 0.637 | 0.689 | 0.734 |
| VP | (c3) degraded, 8 exc vs degraded | 3 samples max | 15 | 4040 (202 probes) | 0.487 | 0.625 | 0.660 | 0.734 | 0.734 |
| VP | (c3) degraded, 8 exc vs degraded | 3 samples max | all (100-101) | 4040 (202 probes) | 0.587 | 0.676 | 0.724 | 0.734 | 0.734 |

## Margin (best − second-best person), 1-sample profile

| corpus | condition | profile samples | gallery | case | n | p1 | p5 | p50 | p95 | p99 | max |
|---|---|---|---|---|---|---|---|---|---|---|---|
| MLS | (a) clean, 8 exc vs clean | 1 | 5 | correct best-match (true speaker enrolled) | 9360 | 0.238 | 0.336 | 0.567 | 0.771 | 0.837 | 0.959 |
| MLS | (a) clean, 8 exc vs clean | 1 | 5 | false best-match (true speaker NOT enrolled) | 10400 | 0.001 | 0.006 | 0.080 | 0.266 | 0.354 | 0.533 |
| MLS | (a) clean, 8 exc vs clean | 1 | 15 | correct best-match (true speaker enrolled) | 9360 | 0.193 | 0.279 | 0.481 | 0.664 | 0.749 | 0.918 |
| MLS | (a) clean, 8 exc vs clean | 1 | 15 | false best-match (true speaker NOT enrolled) | 10400 | 0.001 | 0.004 | 0.054 | 0.185 | 0.252 | 0.363 |
| MLS | (a) clean, 8 exc vs clean | 1 | all | correct best-match (true speaker enrolled) | 9360 | 0.137 | 0.197 | 0.380 | 0.536 | 0.599 | 0.709 |
| MLS | (a) clean, 8 exc vs clean | 1 | all | false best-match (true speaker NOT enrolled) | 10400 | 0.000 | 0.003 | 0.032 | 0.114 | 0.152 | 0.230 |
| MLS | (c) degraded, 8 exc vs clean | 1 | 5 | correct best-match (true speaker enrolled) | 9348 | 0.107 | 0.195 | 0.419 | 0.631 | 0.697 | 0.810 |
| MLS | (c) degraded, 8 exc vs clean | 1 | 5 | false best-match (true speaker enrolled; 0.13% of probes) | 12 | 0.007 | 0.009 | 0.032 | 0.087 | 0.087 | 0.087 |
| MLS | (c) degraded, 8 exc vs clean | 1 | 5 | false best-match (true speaker NOT enrolled) | 10400 | 0.001 | 0.006 | 0.073 | 0.249 | 0.331 | 0.573 |
| MLS | (c) degraded, 8 exc vs clean | 1 | 15 | correct best-match (true speaker enrolled) | 9334 | 0.066 | 0.150 | 0.342 | 0.530 | 0.598 | 0.708 |
| MLS | (c) degraded, 8 exc vs clean | 1 | 15 | false best-match (true speaker enrolled; 0.28% of probes) | 26 | 0.005 | 0.007 | 0.029 | 0.050 | 0.078 | 0.087 |
| MLS | (c) degraded, 8 exc vs clean | 1 | 15 | false best-match (true speaker NOT enrolled) | 10400 | 0.001 | 0.004 | 0.048 | 0.163 | 0.223 | 0.324 |
| MLS | (c) degraded, 8 exc vs clean | 1 | all | correct best-match (true speaker enrolled) | 9253 | 0.041 | 0.094 | 0.256 | 0.418 | 0.470 | 0.546 |
| MLS | (c) degraded, 8 exc vs clean | 1 | all | false best-match (true speaker enrolled; 1.14% of probes) | 107 | 0.002 | 0.005 | 0.022 | 0.066 | 0.105 | 0.105 |
| MLS | (c) degraded, 8 exc vs clean | 1 | all | false best-match (true speaker NOT enrolled) | 10400 | 0.000 | 0.002 | 0.029 | 0.106 | 0.136 | 0.216 |
| MLS | (c3) degraded, 8 exc vs degraded | 1 | 5 | correct best-match (true speaker enrolled) | 9333 | 0.087 | 0.166 | 0.391 | 0.611 | 0.680 | 0.810 |
| MLS | (c3) degraded, 8 exc vs degraded | 1 | 5 | false best-match (true speaker enrolled; 0.29% of probes) | 27 | 0.002 | 0.004 | 0.029 | 0.088 | 0.111 | 0.118 |
| MLS | (c3) degraded, 8 exc vs degraded | 1 | 5 | false best-match (true speaker NOT enrolled) | 10400 | 0.001 | 0.007 | 0.078 | 0.260 | 0.354 | 0.550 |
| MLS | (c3) degraded, 8 exc vs degraded | 1 | 15 | correct best-match (true speaker enrolled) | 9302 | 0.050 | 0.123 | 0.309 | 0.504 | 0.575 | 0.656 |
| MLS | (c3) degraded, 8 exc vs degraded | 1 | 15 | false best-match (true speaker enrolled; 0.62% of probes) | 58 | 0.003 | 0.006 | 0.033 | 0.082 | 0.122 | 0.139 |
| MLS | (c3) degraded, 8 exc vs degraded | 1 | 15 | false best-match (true speaker NOT enrolled) | 10400 | 0.001 | 0.004 | 0.050 | 0.167 | 0.227 | 0.351 |
| MLS | (c3) degraded, 8 exc vs degraded | 1 | all | correct best-match (true speaker enrolled) | 9183 | 0.022 | 0.074 | 0.227 | 0.393 | 0.463 | 0.535 |
| MLS | (c3) degraded, 8 exc vs degraded | 1 | all | false best-match (true speaker enrolled; 1.89% of probes) | 177 | 0.001 | 0.002 | 0.024 | 0.081 | 0.119 | 0.129 |
| MLS | (c3) degraded, 8 exc vs degraded | 1 | all | false best-match (true speaker NOT enrolled) | 10400 | 0.000 | 0.002 | 0.027 | 0.099 | 0.141 | 0.191 |
| VP | (a) clean, 8 exc vs clean | 1 | 5 | correct best-match (true speaker enrolled) | 2840 | 0.313 | 0.392 | 0.587 | 0.774 | 0.849 | 0.933 |
| VP | (a) clean, 8 exc vs clean | 1 | 5 | false best-match (true speaker NOT enrolled) | 4040 | 0.001 | 0.006 | 0.077 | 0.255 | 0.354 | 0.534 |
| VP | (a) clean, 8 exc vs clean | 1 | 15 | correct best-match (true speaker enrolled) | 2840 | 0.266 | 0.331 | 0.502 | 0.666 | 0.717 | 0.807 |
| VP | (a) clean, 8 exc vs clean | 1 | 15 | false best-match (true speaker NOT enrolled) | 4040 | 0.001 | 0.005 | 0.054 | 0.192 | 0.255 | 0.374 |
| VP | (a) clean, 8 exc vs clean | 1 | all | correct best-match (true speaker enrolled) | 2840 | 0.213 | 0.262 | 0.390 | 0.528 | 0.579 | 0.630 |
| VP | (a) clean, 8 exc vs clean | 1 | all | false best-match (true speaker NOT enrolled) | 4040 | 0.001 | 0.003 | 0.034 | 0.128 | 0.152 | 0.225 |
| VP | (c) degraded, 8 exc vs clean | 1 | 5 | correct best-match (true speaker enrolled) | 2840 | 0.194 | 0.257 | 0.452 | 0.645 | 0.723 | 0.843 |
| VP | (c) degraded, 8 exc vs clean | 1 | 5 | false best-match (true speaker NOT enrolled) | 4040 | 0.001 | 0.005 | 0.069 | 0.248 | 0.343 | 0.517 |
| VP | (c) degraded, 8 exc vs clean | 1 | 15 | correct best-match (true speaker enrolled) | 2840 | 0.155 | 0.207 | 0.373 | 0.539 | 0.622 | 0.752 |
| VP | (c) degraded, 8 exc vs clean | 1 | 15 | false best-match (true speaker NOT enrolled) | 4040 | 0.001 | 0.004 | 0.051 | 0.185 | 0.273 | 0.397 |
| VP | (c) degraded, 8 exc vs clean | 1 | all | correct best-match (true speaker enrolled) | 2840 | 0.116 | 0.146 | 0.281 | 0.415 | 0.474 | 0.508 |
| VP | (c) degraded, 8 exc vs clean | 1 | all | false best-match (true speaker NOT enrolled) | 4040 | 0.000 | 0.003 | 0.036 | 0.110 | 0.143 | 0.199 |
| VP | (c3) degraded, 8 exc vs degraded | 1 | 5 | correct best-match (true speaker enrolled) | 2840 | 0.179 | 0.251 | 0.445 | 0.655 | 0.732 | 0.878 |
| VP | (c3) degraded, 8 exc vs degraded | 1 | 5 | false best-match (true speaker NOT enrolled) | 4040 | 0.001 | 0.006 | 0.079 | 0.275 | 0.368 | 0.576 |
| VP | (c3) degraded, 8 exc vs degraded | 1 | 15 | correct best-match (true speaker enrolled) | 2840 | 0.151 | 0.205 | 0.359 | 0.526 | 0.590 | 0.736 |
| VP | (c3) degraded, 8 exc vs degraded | 1 | 15 | false best-match (true speaker NOT enrolled) | 4040 | 0.001 | 0.004 | 0.057 | 0.193 | 0.266 | 0.445 |
| VP | (c3) degraded, 8 exc vs degraded | 1 | all | correct best-match (true speaker enrolled) | 2840 | 0.110 | 0.147 | 0.265 | 0.416 | 0.441 | 0.478 |
| VP | (c3) degraded, 8 exc vs degraded | 1 | all | false best-match (true speaker NOT enrolled) | 4040 | 0.000 | 0.002 | 0.030 | 0.113 | 0.144 | 0.200 |

The margin separates well only in large galleries: false best-matches have median margin 0.03 at ~100 people but 0.08 at 5 (p95 0.27), versus 0.38 (clean) / 0.26 (degraded) for correct matches. In the band it cuts candidates for unenrolled speakers at gallery ~100 from 39% to 5% (MLS clean, threshold 0.50) and costs 0.3% of clean and 4% of degraded true matches.

## 1 vs 3 enrolled samples, centroid vs max

Three samples help: MLS EER 0.15% → 0.02% (clean), 1.18% → 0.94% (degraded vs clean); target mean 0.855 → 0.895; impostor p99 0.472 → 0.499 with max.
Centroid and max separate equally well: EER 0.02% vs 0.02% (clean), 0.28% vs 0.30% (2 excerpts), 0.97% vs 0.94% (degraded), 2.12% vs 2.11% (degraded, 2 excerpts), 0.28% vs 0.32% (degraded vs degraded). Centroid impostor scores are about 0.02 lower (p99 0.482 vs 0.499). Verdict: no measurable advantage either way; keep max.

| corpus | condition | profile | cand g=5 | cand g=15 | cand g=all | false-ID | false-enrol | auto | band | lost | enrol-ok | wrong |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| MLS | (a) clean, 8 exc vs clean | 3 max | 4.1% | 7.6% | 5.6% | 0.00% | 0.00% | 94.0% | 6.0% | 0.0% | 89.5% | 0.00% |
| MLS | (a) clean, 8 exc vs clean | 3 centroid | 3.3% | 6.4% | 5.6% | 0.00% | 0.00% | 94.7% | 5.3% | 0.0% | 90.6% | 0.00% |
| MLS | (b) clean, 2 exc vs clean | 3 max | 3.0% | 5.8% | 5.3% | 0.00% | 0.00% | 86.8% | 12.5% | 0.7% | 74.9% | 0.00% |
| MLS | (b) clean, 2 exc vs clean | 3 centroid | 2.5% | 4.9% | 5.0% | 0.00% | 0.00% | 87.5% | 11.8% | 0.7% | 75.0% | 0.00% |
| MLS | (c) degraded, 8 exc vs clean | 3 max | 2.5% | 4.6% | 3.4% | 0.00% | 0.00% | 33.8% | 62.7% | 3.5% | 12.6% | 0.00% |
| MLS | (c) degraded, 8 exc vs clean | 3 centroid | 1.9% | 3.8% | 4.2% | 0.00% | 0.00% | 34.0% | 62.8% | 3.2% | 15.6% | 0.00% |
| MLS | (c2) degraded, 2 exc vs clean | 3 max | 1.2% | 2.6% | 3.6% | 0.00% | 0.00% | 7.4% | 78.2% | 14.4% | 1.9% | 0.00% |
| MLS | (c2) degraded, 2 exc vs clean | 3 centroid | 1.1% | 2.5% | 3.3% | 0.00% | 0.00% | 7.7% | 78.4% | 13.9% | 1.9% | 0.04% |
| MLS | (c3) degraded, 8 exc vs degraded | 3 max | 16.9% | 14.9% | 2.8% | 0.00% | 0.00% | 83.3% | 14.1% | 2.6% | 63.9% | 0.00% |
| MLS | (c3) degraded, 8 exc vs degraded | 3 centroid | 16.1% | 15.5% | 4.5% | 0.00% | 0.00% | 85.0% | 13.2% | 1.8% | 71.4% | 0.00% |
| VP | (a) clean, 8 exc vs clean | 3 max | 4.5% | 8.6% | 10.4% | 0.00% | 0.00% | 97.9% | 2.1% | 0.0% | 88.7% | 0.00% |
| VP | (a) clean, 8 exc vs clean | 3 centroid | 3.2% | 6.9% | 8.4% | 0.00% | 0.00% | 97.9% | 2.1% | 0.0% | 88.0% | 0.00% |
| VP | (b) clean, 2 exc vs clean | 3 max | 3.4% | 7.3% | 8.3% | 0.00% | 0.00% | 91.7% | 8.3% | 0.0% | 84.1% | 0.00% |
| VP | (b) clean, 2 exc vs clean | 3 centroid | 2.9% | 6.2% | 8.7% | 0.00% | 0.00% | 92.2% | 7.8% | 0.0% | 85.3% | 0.00% |
| VP | (c) degraded, 8 exc vs clean | 3 max | 2.1% | 5.2% | 4.5% | 0.00% | 0.00% | 39.2% | 60.1% | 0.7% | 16.5% | 0.00% |
| VP | (c) degraded, 8 exc vs clean | 3 centroid | 2.2% | 4.8% | 4.0% | 0.00% | 0.00% | 39.8% | 60.2% | 0.0% | 19.0% | 0.00% |
| VP | (c2) degraded, 2 exc vs clean | 3 max | 1.6% | 3.7% | 3.3% | 0.00% | 0.00% | 16.9% | 77.7% | 5.5% | 3.3% | 0.00% |
| VP | (c2) degraded, 2 exc vs clean | 3 centroid | 1.2% | 2.9% | 2.9% | 0.00% | 0.00% | 16.4% | 79.1% | 4.5% | 4.3% | 0.00% |
| VP | (c3) degraded, 8 exc vs degraded | 3 max | 13.5% | 18.6% | 5.5% | 0.00% | 0.00% | 90.1% | 9.2% | 0.7% | 76.7% | 0.00% |
| VP | (c3) degraded, 8 exc vs degraded | 3 centroid | 12.5% | 16.8% | 6.1% | 0.00% | 0.00% | 89.4% | 9.9% | 0.7% | 81.7% | 0.00% |

## Amount of speech (MLS, clean test cluster vs clean 8-excerpt sample)

| excerpt length | #excerpts | EER | target mean | target p1 | target p5 | impostor p99 | impostor p99.9 | impostor max |
|---|---|---|---|---|---|---|---|---|
| 3 s | 1 | 1.21% | 0.710 | 0.409 | 0.527 | 0.429 | 0.522 | 0.671 |
| 3 s | 2 | 0.56% | 0.776 | 0.504 | 0.618 | 0.450 | 0.543 | 0.690 |
| 3 s | 4 | 0.26% | 0.817 | 0.551 | 0.664 | 0.463 | 0.558 | 0.698 |
| 3 s | 8 | 0.34% | 0.840 | 0.565 | 0.687 | 0.469 | 0.564 | 0.701 |
| mixed 3-10 s | 1 | 0.70% | 0.773 | 0.485 | 0.604 | 0.447 | 0.540 | 0.721 |
| mixed 3-10 s | 2 | 0.40% | 0.816 | 0.543 | 0.666 | 0.462 | 0.554 | 0.684 |
| mixed 3-10 s | 4 | 0.32% | 0.841 | 0.571 | 0.697 | 0.470 | 0.562 | 0.691 |
| mixed 3-10 s | 8 | 0.22% | 0.854 | 0.600 | 0.710 | 0.472 | 0.567 | 0.675 |
| 10 s | 1 | 0.51% | 0.802 | 0.529 | 0.646 | 0.456 | 0.549 | 0.742 |
| 10 s | 2 | 0.29% | 0.832 | 0.563 | 0.688 | 0.466 | 0.558 | 0.694 |
| 10 s | 4 | 0.23% | 0.849 | 0.586 | 0.708 | 0.471 | 0.564 | 0.676 |
| 10 s | 8 | 0.16% | 0.858 | 0.608 | 0.719 | 0.473 | 0.568 | 0.669 |
| 2 excerpts vs 2 excerpts (weak enrolment sample) | 2 | 0.60% | 0.779 | 0.502 | 0.624 | 0.449 | 0.541 | 0.698 |

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
