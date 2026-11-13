# Testing

```sh
swift test
xcodebuild -project v2s.xcodeproj -scheme v2s -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Swift tests cover transcript chunking, deduplication, recovery, legacy transcript preservation, bookmark capture, full-session review input, preservation of user notes, and review failure after a successful transcript save.

With a Gemini credential already in Keychain, run the opt-in Gemini tests on model metadata and a synthetic French lecture:

```sh
LEO_RUN_GEMINI_INTEGRATION=1 swift test --filter ObsidianSessionWriterTests
```

After installing the Python dependencies, test the Markdown parser, index reuse, retrieval, and citation checks:

```sh
python -m unittest discover -s rag-study-assistant -v
```
