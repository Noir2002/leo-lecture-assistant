# Recovery

Each authoritative final from Gemini or Apple is appended to a local JSONL recovery journal. The app acknowledges its event IDs after writing the deduplicated French paragraph to the vault. The writer checks whether the same timestamped text already exists before appending again.

On the next session for the same course and day, unacknowledged finals are replayed in capture-time order. An existing legacy bilingual transcript stays intact. The raw transcript and recovery journal are the source records for any generated explanation.

Network, authentication, and quota failures can switch live capture to Apple Local without closing the logical lecture session. Finish saves the transcript before the optional cloud review, so a review failure leaves the transcript available.

Local journals and diagnostic summaries are under `~/Library/Application Support/LeoLectureAssistant/Sessions/`. Journals contain transcript text. The summaries contain status, counts, times and file paths.
