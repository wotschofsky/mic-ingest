# Third-party notices

## Speaker embedding model (bundled)

`MicIngest/Resources/VoiceModels.bundle/FBank.mlmodelc` and `Embedding.mlmodelc` are modified
Core ML conversions of the speaker-embedding part of pyannote "speaker-diarization-community-1",
published by Fluid Inference at <https://huggingface.co/FluidInference/speaker-diarization-coreml>.

- Licence: Creative Commons Attribution 4.0 International (<https://creativecommons.org/licenses/by/4.0/>)
- Model: WeSpeaker ResNet34-LM (<https://github.com/wenet-e2e/wespeaker>), trained on VoxCeleb2
- Credits: pyannote (Hervé Bredin et al.), WeSpeaker (Hongji Wang et al.), BUT Speech@FIT, Fluid Inference
- The files are unmodified copies of Fluid Inference's Core ML conversions of the original models.

Citations:

- H. Wang et al., "WeSpeaker: A Research and Production oriented Speaker Embedding Learning Toolkit", ICASSP 2023.
- H. Bredin, "pyannote.audio 2.1 speaker diarization pipeline: principle, benchmark, and recipe", Interspeech 2023.

## GRDB.swift (Swift Package dependency)

SQLite toolkit by Gwendal Roué, <https://github.com/groue/GRDB.swift>. MIT licence.
Linked statically; no extra signing or distribution requirements.
