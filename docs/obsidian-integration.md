# Obsidian integration

Choose a vault containing `AGENTS.md`, `Home.md`, `10_Courses`, `20_Concepts` and `50_Maps`. A single discovered vault is selected automatically. Configure a path in Settings if there are several candidates.

For the selected course, the app works with three files:

- `Resources/Glossary.md` supplies course terms. The app creates the template if missing.
- `Resources/YYYY-MM-DD - Transcript.md` receives timestamped, final French text. Existing transcripts are preserved and a filename collision with a user file gets a numbered suffix. Multiple sessions on a day can append to the same transcript.
- `Lectures/YYYY-MM-DD - Lecture.md` receives confusion markers and the optional Gemini review. The review is appended once per session, with a start time and an AI attribution. Existing Raw Notes and user edits are preserved.

The local recovery journal records each final before it reaches the Markdown archive. Acknowledgments are written after a chunk is durable or after its text is recognized as a duplicate. See [recovery](recovery.md).
