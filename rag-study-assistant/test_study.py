from contextlib import closing
from pathlib import Path
import tempfile
import unittest

import numpy as np

from study import DIMENSIONS, chunk_note, open_index, retrieve, update_index, verified_claims


class FakeEmbeddings:
    def __init__(self):
        self.requests = []

    def embed(self, texts):
        self.requests.extend(texts)
        vectors = np.zeros((len(texts), DIMENSIONS), dtype="float32")
        for i, text in enumerate(texts):
            vectors[i, 0 if "moyenne" in text or "平均" in text else 1] = 1
        return vectors


class StudyTests(unittest.TestCase):
    def test_legacy_transcript_skips_chinese_and_preserves_lines(self):
        note = """---
type: source
---

# IFT-7022
<!-- event -->
## 19:10:01–19:11:02

### FR

La moyenne macro équilibre les classes.

### ZH

这是旧字幕。
"""
        chunks = list(chunk_note(note, "IFT-7022", "2026-09-29", "2026-09-29 - Transcript.md"))
        self.assertEqual(len(chunks), 1)
        self.assertEqual(chunks[0].time, "19:10:01–19:11:02")
        self.assertEqual(chunks[0].kind, "transcript")
        self.assertEqual(chunks[0].text, note.splitlines()[chunks[0].line - 1])

    def test_index_reuses_embeddings_and_retrieves_bookmark(self):
        note = "# Class\n\n## Confusion Markers\n\n### 19:10:01\n\nLa moyenne macro donne le même poids.\n"
        path = "2026-09-29 - Lecture.md"
        chunks = list(chunk_note(note, "IFT-7022", "2026-09-29", path))
        self.assertEqual(len(chunks), 1)
        self.assertEqual(chunks[0].kind, "bookmark")
        fake = FakeEmbeddings()
        with tempfile.TemporaryDirectory() as tmp, closing(open_index(Path(tmp) / "index.sqlite")) as database:
            self.assertEqual(update_index(database, "IFT-7022", None, chunks, fake), 1)
            self.assertEqual(update_index(database, "IFT-7022", "2026-09-29", chunks, fake), 0)
            result = retrieve(database, "IFT-7022", None, "我在哪里标记没听懂宏平均？", 5, fake)
            self.assertEqual(result, chunks)
            self.assertEqual(len(fake.requests), 2)
            self.assertEqual(update_index(database, "IFT-7022", "2026-09-29", [], fake), 0)
            with self.assertRaisesRegex(ValueError, "Run index first"):
                retrieve(database, "IFT-7022", None, "macro", 3, fake)

    def test_rejects_fabricated_quotes_and_source_ids(self):
        note = "# Class\n\n## 09:00:01–09:00:30\n\nLe rappel compare les positifs retrouvés.\n"
        chunks = list(chunk_note(note, "IFT-7022", "2026-09-29", "2026-09-29 - Transcript.md"))
        valid = {"id": 1, "text": "涉及召回率", "quote": "Le rappel compare"}
        self.assertEqual(list(verified_claims([
            dict(valid, quote="Citation inventée"), dict(valid, id=2), valid,
        ], chunks)), [("涉及召回率", "Le rappel compare", chunks[0])])


if __name__ == "__main__":
    unittest.main()
