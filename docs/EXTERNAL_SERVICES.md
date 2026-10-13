# External services

The requests and defaults below describe the current implementation. Service availability
and provider behavior may change; see `MicIngest/App/AppConfig.swift` for pinned model IDs.

**AssemblyAI**: `POST /v2/upload` → `POST /v2/transcript` → poll `GET /v2/transcript/{id}`.

```json
{ "speech_models": ["universal-3-5-pro"], "speaker_labels": true,
  "language_codes": ["de", "en"],
  "prompt": "<context from Settings>" }
```

- `universal-3-5-pro` is pinned with no fallback model. Provider-side behavior can still change.
- No `speakers_expected` and no speaker range: AssemblyAI's own defaults apply.
- `language_codes` tells Universal-3.5 Pro which languages to code-switch between. The API rejects it
  together with `language_detection` or `language_code`, so only this one is sent.
- The prompt *describes the audio*. AssemblyAI documents that behavioural instructions in the prompt
  are ignored, so the default does not contain any ("transcribe…", "distinguish speakers…").

**Groq**: `POST /openai/v1/chat/completions`, model `openai/gpt-oss-120b` (production, supports strict
JSON Schema output), `response_format: {type: "json_schema", json_schema: {strict: true, …}}`,
temperature 0. The model ID lives in `AppConfig.Groq.defaultModel` and Settings → Advanced.
