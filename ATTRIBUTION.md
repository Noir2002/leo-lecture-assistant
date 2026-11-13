# Attribution

Leo Lecture Assistant is derived from [v2s](https://github.com/franklioxygen/v2s) by
Frank Li Oxygen, cloned at commit `3aaaaa199bccddddb354bd9d2ee1a17e6b1f714c`.

The upstream README states that v2s is MIT licensed. The cloned upstream tree did not
contain a root `LICENSE` file at that commit, so this fork preserves the upstream MIT
statement without inventing a copyright line. Existing third-party notices remain in
`THIRD_PARTY_NOTICES.md`.

Substantial reused components include application-audio process taps, microphone capture,
Apple SpeechAnalyzer and legacy Speech adapters, Apple Translation integration, Silero VAD,
and the subtitle overlay.

## Leo Lecture Assistant additions

1. Course sessions, glossary configuration, and 90-second confusion bookmarks for review.
2. Gemini Live streaming with fallback to the inherited Apple Speech and Translation path.
3. A journal-first pipeline with transcript deduplication, timestamped paragraphs, and Obsidian recovery.
4. A post-class Gemini request that produces a bilingual outline, key concepts, and explanations for bookmarks.
5. A Python RAG CLI with multilingual Gemini embeddings, FAISS retrieval, and verified Markdown citations.
