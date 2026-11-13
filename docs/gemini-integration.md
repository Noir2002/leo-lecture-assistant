# Gemini integration

Gemini Smart uses `gemini-3.5-transcribe-live` with SMART input transcription. Capture is
converted to little-endian signed PCM16, mono, 16 kHz and declared as
`audio/pcm;rate=16000`. Interim input transcription updates only the faded preview. Final
input transcription is authoritative and enters the journal, translation and persistence
pipeline.

The app requests a single-use, model-constrained ephemeral token with the long-lived Auth
Key, then uses that token for the Live WebSocket. The long-lived key is sent only in the
`x-goog-api-key` REST header and is held in macOS Keychain under
`com.leo.lectureassistant.gemini`. It is never placed in a URL, config file, Markdown, Vault,
diagnostic JSON or log.

Sessions preconnect at 8:15 and rotate at 8:30. The old stream receives `audioStreamEnd` and
drains final events for up to two seconds. New-session final events are buffered during the
drain, then emitted in timestamp order; the coordinator also suppresses a repeated boundary
final.

Translation and outline use `gemini-3.5-flash-lite` with strict structured JSON. Translation
receives only the selected course metadata, up to 100 Core Terms, recent final context and the
current final segment. A single JSON-object extraction fallback handles fenced/wrapped output.

References:

- https://ai.google.dev/gemini-api/docs/live-api/live-transcribe
- https://ai.google.dev/gemini-api/docs/models/gemini-3.5-flash-lite
- https://ai.google.dev/gemini-api/docs/api-key
- https://ai.google.dev/gemini-api/docs/pricing

The real integration test is intentionally disabled unless
`LEO_RUN_GEMINI_INTEGRATION=1` and a Keychain credential is configured.

## Post-class review

Gemini 3.5 Flash-Lite receives one structured `generateContent` request after the Obsidian transcript is saved. The request includes the full current session, course glossary and the recorded confusion markers. Each bookmark explanation is matched to its original bookmark number and time before the bilingual review is appended to the daily Lecture note.

Apple Local can opt in to this text request without streaming audio to Gemini. The integration test uses synthetic text. It requires the Keychain key only when the test is explicitly enabled.
