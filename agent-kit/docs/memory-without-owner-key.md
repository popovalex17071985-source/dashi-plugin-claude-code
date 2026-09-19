# Long-term memory without asking the owner for a key

Tried on gorbot (144.124.224.216, 2 cores / 3.9 GB) 19.09.2026. No OpenAI key,
no card, no owner action. Two containers, both bound to loopback.

1. Embeddings -- OpenAI-compatible server, local:

```
docker run -d --name tei-embed --restart unless-stopped \
  -p 127.0.0.1:1934:80 -v ~/.cache/hf:/data \
  ghcr.io/huggingface/text-embeddings-inference:cpu-1.8 \
  --model-id intfloat/multilingual-e5-small --auto-truncate
```

   `--auto-truncate` is mandatory: OpenViking chunks run ~2100 tokens and the
   model takes 512, otherwise every add fails with HTTP 413.
   `Alibaba-NLP/gte-multilingual-base` (8k ctx) OOMs on a 4 GB box -- it restarts
   in a loop. Use it only where RAM is free.

2. Summaries -- any OpenAI-compatible chat API the box ALREADY holds a key for
   (gorbot: Groq, `openai/gpt-oss-20b`). Never copy a key between servers.

3. `~/.openviking/ov.conf` (mode 600): `embedding.dense` -> the local endpoint,
   `provider: openai`, `dimension` = what `/v1/embeddings` actually returns
   (384 for e5-small); `vlm` -> the Groq base + model; `server.host: 127.0.0.1`.

4. Run OpenViking with `--network host` AND `-e OPENVIKING_SERVER_HOST=127.0.0.1`
   -- without the env it binds 0.0.0.0 and dev auth mode refuses to start.

5. The kit's `flush-to-openviking.sh` delegates to
   `~/.claude-lab/<agent>/scripts/ov-session-sync.sh` -- on a copied kit both the
   path and `AGENT_NAME` still said `jarvis`, so the flush silently did nothing
   even with the service up. Check both before declaring memory alive.

Ask the owner for a key (`bin/memory-key-ask.py`) only when neither a local
embedder nor an existing provider key can be used -- see [memory-key-install.md].
