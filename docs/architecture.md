# Architecture

`AppModel` controls the macOS capture pipeline. The app uses upstream v2s capture and Apple Speech/Translation. Gemini Smart sends audio to Gemini Live; its finalized text and Apple Speech's finalized text enter the same `LectureSessionCoordinator`.

The coordinator journals each final, then `TranscriptAssembler` removes overlapping text and produces timestamped chunks. A bookmark captures up to 90 seconds of accepted French text independently of translation latency. The Obsidian writer appends the raw transcript and records bookmarks in the daily Lecture note.

Finish drains the speech pipeline and persists its remaining chunks. If enabled and configured, `GeminiReviewGenerator` submits one structured text request for that session. It sends only chunks from the current session, excluding recovered text from earlier same-day sessions. The writer appends a timestamped review section to the daily Lecture note after reading its latest version.

The separate Python CLI chunks dated Markdown by heading and timestamp. A local SQLite index stores metadata, excerpts and cached Gemini embeddings. FAISS retrieves semantically relevant excerpts. The Gemini answer supplies source IDs and quotations, which the CLI checks against the excerpts before printing citations.
