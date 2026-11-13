# Course Q&A with source citations

The CLI indexes dated Obsidian lecture notes and timestamped transcripts for one course at a time. Gemini Embedding 2 maps Chinese and French into the same vector space. FAISS ranks the stored vectors by cosine similarity. Gemini generates answers from the retrieved excerpts and the CLI checks each quoted passage against its source before printing it.

## Run locally

Python 3.11+ and a Gemini API key are required. The CLI reads `GEMINI_API_KEY` from the environment. On zsh, the following prompts for the key without adding it to shell history.

```zsh
cd rag-study-assistant
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
read -rs 'GEMINI_API_KEY?Gemini API key: '
export GEMINI_API_KEY
```

Index a course or start with a single day. Use `--date` on either command when you know the lecture date. Each answer includes the course, date, vault-relative file, line number, exact excerpt, and any timestamp available in the source.

```sh
python study.py index --vault "/path/to/vault" --course IFT-7022 --date 2026-09-29
python study.py ask --course IFT-7022 --date 2026-09-29 '课堂如何解释注意力权重？'
python study.py ask --course IFT-7022 --date 2026-09-29 'Quels passages ai-je marqués comme difficiles ?'
```

The index reads `10_Courses/<term>/<course>/Lectures/` and the dated `Resources/* - Transcript*.md` files. It handles French-only transcripts and the French section of older bilingual exports. Bookmark excerpts and AI-generated reviews are tagged with their source type. When a source has a date but lacks a timestamp, the citation gives the original heading and line number.

Indexing sends the selected Markdown chunks to Google's embeddings API. Asking sends the question and retrieved excerpts to Google Gemini. Choose a vault, course, and date you can send to that service. The local SQLite index contains note excerpts and vectors. Keep it private, or pass `--db` before the command to choose a separate index for another vault. Index the same scope again after notes change. Unchanged chunks reuse their embeddings and removed chunks are dropped from that scope.

[Gemini embeddings documentation](https://ai.google.dev/gemini-api/docs/embeddings)
