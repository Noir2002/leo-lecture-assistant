# Privacy and cost

Apple Local is the default. It uses the macOS speech and translation frameworks. Speech recognition prefers an installed on-device model and can use Apple's service when the selected language and Mac do not support on-device recognition.

Gemini Smart sends selected audio, course terms, and the transcript context needed for live translation to Google Gemini. Its post-class review sends the complete deduplicated transcript of the session, glossary, and bookmark excerpts. Apple Local can opt in to the same text-only post-class review. The macOS app stores its credential in Keychain.

Cloud review requires the app's billing-disabled confirmation and a configured key. The app cannot verify a project's billing status. The review uses a single non-streaming request with no automatic retry. If cloud review fails, the transcript and bookmark files remain available.

The Python RAG CLI sends the selected Markdown chunks to the Gemini embeddings API and the question and retrieved excerpts to the Gemini text API. Its local index contains note excerpts and embeddings. See the [CLI guide](../rag-study-assistant/README.md) for date and course scoping.
